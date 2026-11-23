"""Serve Git upload-pack for this host's GitHub App over authenticated loopback HTTP."""
import base64
import hmac
import http.client
import http.server
import json
import os
import queue
from pathlib import Path
import re
import secrets
import shlex
import subprocess
import sys
import tempfile
import threading
from urllib.parse import urlsplit

REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
GIT_PATH = re.compile(r"/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/(info/refs|git-upload-pack)")


def approved_repositories(config):
    try:
        names = json.loads(config.with_name("github-package-repositories.json").read_bytes())
    except (OSError, ValueError):
        return set()
    if not isinstance(names, list) or not all(isinstance(name, str) for name in names):
        return set()
    return {name.lower() for name in names}


def request_body(stream, remaining):
    while remaining:
        chunk = stream.read(min(remaining, 65536))
        if not chunk:
            raise ConnectionError("Incomplete upload-pack request.")
        remaining -= len(chunk)
        yield chunk


def chunked_body(stream):
    while True:
        line = stream.readline(8193)
        if len(line) > 8192 or not line.endswith(b"\r\n"):
            raise ValueError("Invalid chunk header.")
        size, _, _ = line[:-2].partition(b";")
        if not re.fullmatch(rb"[a-fA-F0-9]+", size):
            raise ValueError("Invalid chunk size.")
        length = int(size, 16)
        if not length:
            # Git does not send trailer fields.
            if stream.readline(3) != b"\r\n":
                raise ValueError("Unexpected upload-pack trailer.")
            return
        yield from request_body(stream, length)
        if stream.read(2) != b"\r\n":
            raise ValueError("Invalid chunk terminator.")


class Packages(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.serve_git()

    def do_POST(self):
        self.serve_git()

    def serve_git(self):
        if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), self.server.authorization.encode()):
            self.send_error(401)
            return
        url = urlsplit(self.path)
        match = GIT_PATH.fullmatch(url.path)
        repos = self.server.repositories
        if (not match or match[1].lower() not in repos or url.netloc or url.scheme
                or not self.path.startswith("/") or self.path.startswith("//")):
            self.send_error(404)
            return
        # Revocation applies to the next fetch even if registration synchronization is still busy.
        if self.server.manager is None and match[1].lower() not in approved_repositories(self.server.config):
            self.send_error(403)
            return
        discovery = self.command == "GET"
        if ((discovery and (match[2] != "info/refs" or url.query != "service=git-upload-pack")) or
                (not discovery and (match[2] != "git-upload-pack" or url.query))):
            self.send_error(403)
            return
        headers = {}
        if self.headers.get("Git-Protocol") == "version=2":
            headers["Git-Protocol"] = "version=2"
        body = None
        if not discovery:
            if self.headers.get("Content-Type") != "application/x-git-upload-pack-request":
                self.send_error(415)
                return
            encoding = self.headers.get("Transfer-Encoding", "").lower()
            if encoding == "chunked" and "Content-Length" not in self.headers:
                body = chunked_body(self.rfile)
            elif encoding:
                self.send_error(400)
                return
            else:
                try:
                    count = int(self.headers["Content-Length"])
                except (TypeError, ValueError):
                    self.send_error(411)
                    return
                if count < 0:
                    self.send_error(400)
                    return
                body = request_body(self.rfile, count)
                headers["Content-Length"] = str(count)
            headers["Content-Type"] = "application/x-git-upload-pack-request"
            if self.headers.get("Content-Encoding") == "gzip":
                headers["Content-Encoding"] = "gzip"
        if self.server.manager is not None:
            self.fetch_from_manager(repos[match[1].lower()], discovery, headers, body)
            return
        # Only the signed host answers this private pipe. Jobs receive the Git response.
        with self.server.credential_lock:
            print("credential", file=sys.stderr, flush=True)
            token = self.server.credentials.get()
        if token:
            headers["Authorization"] = "Basic " + base64.b64encode(("x-access-token:" + token).encode()).decode()
        upstream = http.client.HTTPSConnection("github.com", timeout=120)
        try:
            path = "/" + repos[match[1].lower()] + ".git/" + match[2]
            upstream.request(self.command, path + ("?" + url.query if discovery else ""), body=body, headers=headers)
            response = upstream.getresponse()
            self.send_response(response.status)
            for field in ("Content-Type", "Content-Length", "Cache-Control"):
                if response.getheader(field) is not None:
                    self.send_header(field, response.getheader(field))
            self.end_headers()
            while data := response.read1(65536):
                self.wfile.write(data)
        finally:
            upstream.close()

    def fetch_from_manager(self, repository, discovery, headers, body):
        request = {"repository": repository, "operation": "refs" if discovery else "uploadPack",
                   "protocolV2": "Git-Protocol" in headers, "gzip": "Content-Encoding" in headers}
        command = [self.server.app, "--fetch-package", json.dumps(request),
                   "--package-manager", self.server.manager, "--package-root", str(self.server.config.parent)]
        with subprocess.Popen(command, stdin=subprocess.PIPE, stdout=subprocess.PIPE) as child:
            try:
                if body is not None:
                    for chunk in body:
                        child.stdin.write(chunk)
                child.stdin.close()
            except BrokenPipeError:
                pass
            first = child.stdout.readline()
            if not first:
                self.send_error(502, "The managing host could not fetch this repository")
                return
            metadata = json.loads(first)
            length = metadata.get("length")
            chunked = length is None and self.request_version == "HTTP/1.1"
            self.protocol_version = self.request_version
            self.close_connection = True
            self.send_response(metadata["status"])
            if metadata.get("contentType"):
                self.send_header("Content-Type", metadata["contentType"])
            self.send_header("Connection", "close")
            if length is not None:
                self.send_header("Content-Length", str(length))
            elif chunked:
                self.send_header("Transfer-Encoding", "chunked")
            self.end_headers()
            try:
                while data := child.stdout.read1(65536):
                    if chunked:
                        self.wfile.write(f"{len(data):x}\r\n".encode())
                    self.wfile.write(data)
                    if chunked:
                        self.wfile.write(b"\r\n")
                if child.wait() == 0 and chunked:
                    self.wfile.write(b"0\r\n\r\n")
            finally:
                child.stdout.close()


def write_atomic(path, content):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as out:
        out.write(content)
    os.replace(out.name, path)


def publish(config, port, authorization, names, manager):
    origin = f"http://127.0.0.1:{port}/"
    # Git compares insteadOf prefixes. The remote helper compares the complete repository name.
    helper = shlex.join(["/usr/bin/python3", "-I", str(Path(__file__).resolve()), "--remote", str(config)])
    lines = [f'[http "{origin}"]', f'    extraHeader = Authorization: {authorization}', '    proxy =',
             '[alias]', '    remote-xcode-package = ' + json.dumps('!' + helper, ensure_ascii=False),
             '[protocol "xcode-package"]', '    allow = always']
    # Keep the original HTTPS URL in .git/config and in SwiftPM's bare repository cache.
    spellings = set()
    for name in names:
        owner, repo = name.split("/")
        for account in {owner, owner.lower()}:
            spellings.update(account + "/" + part for part in (repo, repo.lower()))
    for spelling in sorted(spellings):
        github = f"https://github.com/{spelling}"
        lines.extend([f'[url "xcode-package::{github}"]', f'    insteadOf = {github}',
                      f'[url "{github}"]', f'    pushInsteadOf = {github}'])
    write_atomic(config.with_suffix(".json"), json.dumps({"origin": origin, "port": port, "authorization": authorization,
                                                        "managed": manager is not None, "repositories": sorted(names)}))
    write_atomic(config, "\n".join(lines) + "\n")


def remote(config, name, url):
    # Use Git's own HTTP transport for both routes, including the caller's normal GitHub credentials.
    parsed = urlsplit(url)
    repository = parsed.path.strip("/").removesuffix(".git").lower()
    if parsed.netloc == "github.com" and not parsed.query and not parsed.fragment:
        try:
            settings = json.loads(config.with_suffix(".json").read_bytes())
        except FileNotFoundError:
            os.execlp("git", "git", "remote-https", name, url)
        allowed = {n.lower(): n for n in settings["repositories"]}
        if repository not in allowed or (not settings.get("managed") and repository not in approved_repositories(config)):
            os.execlp("git", "git", "remote-https", name, url)
        # Explicit push URLs bypass pushInsteadOf. Leave a remote with a matching explicit push URL to Git.
        push_urls = subprocess.run(["git", "config", "--get-all", "remote." + name + ".pushurl"],
                                   stdout=subprocess.PIPE, text=True, check=False).stdout.splitlines()
        if url not in push_urls:
            os.execlp("git", "git", "remote-http", name, settings["origin"] + allowed[repository] + ".git")
    os.execlp("git", "git", "remote-https", name, url)


def main(config, manager=None, app=None):
    os.umask(0o077)
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Packages) as server:
        server.authorization = "Bearer " + secrets.token_hex(32)
        server.repositories = {}
        server.manager = manager
        server.app = app
        server.config = config
        server.credential_lock = threading.Lock()
        server.credentials = queue.Queue()
        threading.Thread(target=server.serve_forever, daemon=True).start()
        for line in sys.stdin:
            message = json.loads(line)
            if "credential" in message:
                server.credentials.put(message["credential"])
                continue
            names = {n for n in message["repositories"] if REPOSITORY.fullmatch(n)
                     and all(part not in (".", "..") for part in n.split("/"))}
            server.repositories = {n.lower(): n for n in names}
            publish(config, server.server_port, server.authorization, names, server.manager)
            print("ready", flush=True)


if __name__ == "__main__":
    if sys.argv[1] == "--remote":
        remote(Path(sys.argv[2]), *sys.argv[3:])
    else:
        main(Path(sys.argv[1]), *sys.argv[2:])
