#!/usr/bin/env python3
from __future__ import annotations

import argparse
import os
import shlex
import socket
import socketserver
import subprocess
import sys
import threading
import time

REMOTE_RELAY = r'''
import os, select, socket
s = socket.create_connection(("127.0.0.1", __PORT__), timeout=10)
s.settimeout(None)
watch_stdin = True
while True:
    readers = [s]
    if watch_stdin:
        readers.append(0)
    ready, _, _ = select.select(readers, [], [])
    if watch_stdin and 0 in ready:
        data = os.read(0, 65536)
        if data:
            s.sendall(data)
        else:
            watch_stdin = False
            try:
                s.shutdown(socket.SHUT_WR)
            except OSError:
                pass
    if s in ready:
        data = s.recv(65536)
        if not data:
            break
        os.write(1, data)
'''

def ssh_base(target: str) -> list[str]:
    return [
        "ssh", "-T",
        "-o", "LogLevel=ERROR",
        "-o", "BatchMode=yes",
        "-o", "ConnectTimeout=10",
        "-o", "ServerAliveInterval=30",
        "-o", "ServerAliveCountMax=3",
        target,
    ]

def check_remote(target: str, container: str, remote_port: int) -> int:
    code = (
        "import socket; "
        f"s=socket.create_connection(('127.0.0.1',{remote_port}),timeout=5); "
        "s.close(); print('ALT_CLAUDE_REMOTE_OK')"
    )
    result = subprocess.run(
        ssh_base(target) + [
            f"sudo -n incus exec {shlex.quote(container)} -- "
            f"python3 -c {shlex.quote(code)}"
        ],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        return result.returncode or 1
    print(result.stdout.strip(), flush=True)
    return 0

def ensure_remote_server(target: str, container: str, remote_port: int, model: str) -> int:
    if check_remote(target, container, remote_port) == 0:
        return 0

    repo_dir = "/srv/alt-claude/repos/alt-claude-slave"
    log_path = "/srv/alt-claude/state/llama-server.log"
    start = (
        "install -d -o slave -g slave -m 0750 /srv/alt-claude/state && "
        "runuser -u slave -- env "
        "HOME=/home/slave "
        "LLAMA_CACHE=/srv/alt-claude/models "
        "LLAMA_BIN=/home/slave/.local/opt/llama.cpp/bin "
        "bash -lc "
        + shlex.quote(
            f"cd {repo_dir} && "
            f"nohup ./slave serve {shlex.quote(model)} >{log_path} 2>&1 < /dev/null &"
        )
    )
    result = subprocess.run(
        ssh_base(target) + [
            f"sudo -n incus exec {shlex.quote(container)} -- bash -lc {shlex.quote(start)}"
        ],
        text=True,
        capture_output=True,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr or result.stdout)
        return result.returncode or 1

    print(f"ALT_CLAUDE_STARTING model={model}", flush=True)
    for _ in range(120):
        if check_remote(target, container, remote_port) == 0:
            return 0
        time.sleep(1)

    logs = subprocess.run(
        ssh_base(target) + [
            f"sudo -n incus exec {shlex.quote(container)} -- tail -n 80 {shlex.quote(log_path)}"
        ],
        text=True,
        capture_output=True,
    )
    sys.stderr.write("llama-server não ficou pronto em 120s. Último log remoto:\n")
    sys.stderr.write(logs.stdout or logs.stderr)
    return 1

def remote_command(container: str, remote_port: int) -> str:
    code = REMOTE_RELAY.replace("__PORT__", str(remote_port))
    return (
        f"sudo -n incus exec {shlex.quote(container)} -- "
        f"python3 -u -c {shlex.quote(code)}"
    )

class BridgeServer(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True

    def __init__(self, addr, handler, *, target: str, container: str, remote_port: int):
        self.target = target
        self.container = container
        self.remote_port = remote_port
        super().__init__(addr, handler)

class BridgeHandler(socketserver.BaseRequestHandler):
    def handle(self) -> None:
        server: BridgeServer = self.server  # type: ignore[assignment]
        proc = subprocess.Popen(
            ssh_base(server.target) + [remote_command(server.container, server.remote_port)],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            bufsize=0,
        )
        assert proc.stdin and proc.stdout and proc.stderr

        def client_to_ssh() -> None:
            try:
                while True:
                    data = self.request.recv(65536)
                    if not data:
                        break
                    proc.stdin.write(data)
                    proc.stdin.flush()
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass
            finally:
                try:
                    proc.stdin.close()
                except OSError:
                    pass

        def ssh_to_client() -> None:
            try:
                while True:
                    data = proc.stdout.read(65536)
                    if not data:
                        break
                    self.request.sendall(data)
            except (BrokenPipeError, ConnectionResetError, OSError):
                pass

        t1 = threading.Thread(target=client_to_ssh, daemon=True)
        t2 = threading.Thread(target=ssh_to_client, daemon=True)
        t1.start()
        t2.start()
        t1.join()
        t2.join()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.terminate()

def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--listen-host", default=os.getenv("ALT_CLAUDE_BRIDGE_HOST", "127.0.0.1"))
    parser.add_argument("--listen-port", type=int, default=int(os.getenv("ALT_CLAUDE_BRIDGE_PORT", "18080")))
    parser.add_argument("--ssh-target", default=os.getenv("DOM1_SSH_TARGET", "esteban@dom1.inovacaosistemas.com.br"))
    parser.add_argument("--container", default=os.getenv("CONTAINER_NAME", "alt-claude-slave"))
    parser.add_argument("--remote-port", type=int, default=int(os.getenv("SLAVE_PORT", "8080")))
    parser.add_argument("--model", default=os.getenv("ALT_CLAUDE_MODEL", "qwen-coder-3b"))
    args = parser.parse_args()

    rc = ensure_remote_server(args.ssh_target, args.container, args.remote_port, args.model)
    if rc != 0:
        return rc

    with BridgeServer(
        (args.listen_host, args.listen_port),
        BridgeHandler,
        target=args.ssh_target,
        container=args.container,
        remote_port=args.remote_port,
    ) as server:
        print(
            f"alt-claude bridge: http://{args.listen_host}:{args.listen_port} "
            f"-> {args.ssh_target} -> {args.container}:127.0.0.1:{args.remote_port}",
            flush=True,
        )
        server.serve_forever()

if __name__ == "__main__":
    raise SystemExit(main())
