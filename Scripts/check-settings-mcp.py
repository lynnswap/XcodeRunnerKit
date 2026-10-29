#!/usr/bin/env python3
"""Check MCP discovery and settings updates against an isolated host directory."""
import argparse
import json
import os
from pathlib import Path
import select
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("executable", type=Path)
    args = parser.parse_args()
    executable = str(args.executable.resolve())
    with tempfile.TemporaryDirectory(prefix="XcodeRunnerSettingsMCP-") as temporary:
        home = Path(temporary)
        environment = {**os.environ, "HOME": str(home)}
        for name in ("XCODE_RUNNER_HOST_ROOT", "XCODE_RUNNER_HOST_STORAGE_DIRECTORY"):
            environment.pop(name, None)
        subprocess.run([executable, "pool", "configure", "--maximum-concurrent-jobs", "3", "--json"],
                       env=environment, check=True, capture_output=True, timeout=30)
        process = subprocess.Popen([executable, "mcp"], env=environment, stdin=subprocess.PIPE,
                                   stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        sequence = 0

        def send(message):
            process.stdin.write(json.dumps(message).encode() + b"\n")
            process.stdin.flush()

        def request(method, params):
            nonlocal sequence
            sequence += 1
            send({"jsonrpc": "2.0", "id": sequence, "method": method, "params": params})
            while True:
                assert select.select([process.stdout], [], [], 30)[0], f"Timed out waiting for {method}"
                line = process.stdout.readline()
                assert line, f"Server exited while waiting for {method}"
                response = json.loads(line)
                if response.get("id") == sequence:
                    assert "error" not in response, response
                    return response["result"]

        def call(name, arguments):
            return request("tools/call", {"name": name, "arguments": arguments})

        try:
            initialized = request("initialize", {
                "protocolVersion": "2025-11-25", "capabilities": {},
                "clientInfo": {"name": "settings-mcp-check", "version": "1"},
            })
            assert "tools" in initialized["capabilities"]
            send({"jsonrpc": "2.0", "method": "notifications/initialized"})
            tools = {tool["name"]: tool for tool in request("tools/list", {})["tools"]}
            assert set(tools) == {"get_settings", "update_settings"}, tools
            assert tools["get_settings"]["annotations"]["readOnlyHint"] is True
            assert tools["update_settings"]["annotations"]["readOnlyHint"] is False
            assert all("outputSchema" in tool for tool in tools.values())
            before = call("get_settings", {"scope": "pool"})["structuredContent"]
            settings = {item["key"]: item for item in before["settings"]}
            assert settings["maximumConcurrentJobs"]["value"] == 3
            assert settings["simulatorRetention"]["value"] == {"mode": "idleTimeout", "minutes": 20}
            updated = call("update_settings", {"scope": "pool", "simulatorRetention": {"mode": "forever"}})
            assert updated.get("isError") is False, updated
            assert updated["structuredContent"]["state"] == "saved", updated
            after = call("get_settings", {"scope": "pool"})["structuredContent"]
            settings = {item["key"]: item for item in after["settings"]}
            assert settings["maximumConcurrentJobs"]["value"] == 3
            assert settings["simulatorRetention"]["value"] == {"mode": "forever"}
            assert {choice["value"]["mode"] for choice in settings["simulatorRetention"]["choices"]} == {"forever", "idleTimeout"}
            invalid = call("update_settings", {"scope": "pool", "maximumConcurrentJobs": 8,
                                                "simulatorRetention": {"mode": "idleTimeout", "minutes": 0}})
            assert invalid.get("isError") is True, invalid
            assert "error" in invalid["structuredContent"]
            assert call("get_settings", {"scope": "pool"})["structuredContent"] == after
            cli = subprocess.run([executable, "host", "settings", "get", "--scope", "pool"],
                                 env=environment, capture_output=True, check=True, timeout=30)
            assert json.loads(cli.stdout) == after
            process.stdin.close()
            assert process.wait(timeout=30) == 0, process.stderr.read().decode()
        finally:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=10)
        print("MCP settings discovery, partial update, validation, and CLI agreement passed.")


if __name__ == "__main__":
    main()
