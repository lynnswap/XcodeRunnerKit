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
import shutil
import sys
import tempfile
import threading
from urllib.parse import urlsplit

REPOSITORY = re.compile(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+")
GIT_PATH = re.compile(r"/([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(?:\.git)?/(info/refs|git-upload-pack)")


def request_body(stream, remaining):
    while remaining:
        chunk = stream.read(min(remaining, 65536))
        if not chunk:
            raise ConnectionError("Incomplete upload-pack request.")
        remaining -= len(chunk)
        yield chunk


class Packages(http.server.BaseHTTPRequestHandler):
    def log_message(self, *_):
        pass

    def do_GET(self):
        self.serve_git()

    def do_POST(self):
        self.serve_git()

    def serve_git(self):
        if not hmac.compare_digest(self.headers.get("Authorization", "").encode(), self.server.authorization.encode()):
            self.send_error(403)
            return
        url = urlsplit(self.path)
        match = GIT_PATH.fullmatch(url.path)
        repos = self.server.repositories
        if (not match or match[1].lower() not in repos or url.netloc or url.scheme
                or not self.path.startswith("/") or self.path.startswith("//")):
            self.send_error(404)
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
            try:
                count = int(self.headers["Content-Length"])
            except (TypeError, ValueError):
                self.send_error(411)
                return
            if count < 0 or self.headers.get("Transfer-Encoding"):
                self.send_error(400)
                return
            # A fetch request contains negotiation packets. The pack itself is the streamed response.
            body = request_body(self.rfile, count)
            headers["Content-Length"] = str(count)
            headers["Content-Type"] = "application/x-git-upload-pack-request"
            if self.headers.get("Content-Encoding") == "gzip":
                headers["Content-Encoding"] = "gzip"
        # Only the signed host answers this private pipe. Jobs receive the Git response.
        with self.server.credential_lock:
            print("credential", file=sys.stderr, flush=True)
            token = self.server.credentials.get()
        if not token:
            self.send_error(403)
            return
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
            shutil.copyfileobj(response, self.wfile)
        finally:
            upstream.close()


def write_atomic(path, content):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as out:
        out.write(content)
    os.replace(out.name, path)


def publish(config, port, authorization, names):
    origin = f"http://127.0.0.1:{port}/"
    write_atomic(config, f'[http "{origin}"]\n\textraHeader = Authorization: {authorization}\n')
    mirrors = [{"original": "https://github.com/" + spelling + suffix, "mirror": origin + name + ".git"}
               for name in sorted(names) for spelling in sorted({name, name.lower()}) for suffix in ("", ".git")]
    write_atomic(config.with_suffix(".json"), json.dumps({"version": 1, "object": mirrors}) + "\n")


def main(config):
    os.umask(0o077)
    with http.server.ThreadingHTTPServer(("127.0.0.1", 0), Packages) as server:
        server.authorization = "Bearer " + secrets.token_hex(32)
        server.repositories = {}
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
            publish(config, server.server_port, server.authorization, names)
            print("ready", flush=True)


if __name__ == "__main__":
    main(Path(sys.argv[1]))
