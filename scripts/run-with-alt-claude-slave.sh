#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${ALT_CLAUDE_OPENCODE_DIR:-$ROOT_DIR/.local/alt-claude}"
CONFIG_FILE="$CONFIG_DIR/opencode.json"
TRANSPORT="${ALT_CLAUDE_TRANSPORT:-ssh-incus}"
BRIDGE_HOST="${ALT_CLAUDE_BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PORT="${ALT_CLAUDE_BRIDGE_PORT:-}"
BRIDGE_PORT_FILE="$CONFIG_DIR/bridge.port"
BRIDGE_PID=""

cleanup() {
  if [[ -n "$BRIDGE_PID" ]]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT INT TERM

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Configuração ausente; executando setup."
  bash "$ROOT_DIR/scripts/setup-alt-claude-slave.sh"
fi

if [[ -z "$BRIDGE_PORT" && -f "$BRIDGE_PORT_FILE" ]]; then
  BRIDGE_PORT="$(cat "$BRIDGE_PORT_FILE")"
fi

port_is_free() {
  python3 - "$BRIDGE_HOST" "$1" <<'PY'
import socket, sys
host, port = sys.argv[1], int(sys.argv[2])
s = socket.socket()
try:
    s.bind((host, port))
except OSError:
    raise SystemExit(1)
finally:
    s.close()
PY
}

if [[ -z "$BRIDGE_PORT" ]] || ! port_is_free "$BRIDGE_PORT"; then
  BRIDGE_PORT="$(python3 - "$BRIDGE_HOST" <<'PY'
import socket, sys
host = sys.argv[1]
s = socket.socket()
s.bind((host, 0))
print(s.getsockname()[1])
s.close()
PY
)"
  printf '%s\n' "$BRIDGE_PORT" > "$BRIDGE_PORT_FILE"

  python3 - "$CONFIG_FILE" "$BRIDGE_HOST" "$BRIDGE_PORT" <<'PY'
import json, sys
path, host, port = sys.argv[1], sys.argv[2], int(sys.argv[3])
with open(path, encoding="utf-8") as fh:
    data = json.load(fh)
data["provider"]["alt-claude"]["options"]["baseURL"] = f"http://{host}:{port}/v1"
with open(path, "w", encoding="utf-8") as fh:
    json.dump(data, fh, indent=2)
    fh.write("\n")
PY
fi

if [[ "$TRANSPORT" == "ssh-incus" ]]; then
  echo "==> Iniciando bridge SSH/Incus em http://$BRIDGE_HOST:$BRIDGE_PORT"
  python3 "$ROOT_DIR/scripts/alt-claude-http-bridge.py" \
    --listen-host "$BRIDGE_HOST" \
    --listen-port "$BRIDGE_PORT" &
  BRIDGE_PID=$!

  ready=0
  for _ in {1..20}; do
    if curl -fsS --max-time 2 "http://$BRIDGE_HOST:$BRIDGE_PORT/v1/models" >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      echo "ERRO: bridge SSH/Incus encerrou antes de responder." >&2
      exit 2
    fi
    sleep 0.5
  done
  [[ "$ready" == "1" ]] || { echo "ERRO: bridge não ficou pronto." >&2; exit 2; }
fi

export OPENCODE_CONFIG="$CONFIG_FILE"
export ALT_CLAUDE_API_KEY="${ALT_CLAUDE_API_KEY:-local-no-auth}"

cd "$ROOT_DIR"
echo "OpenDesign -> OpenCode -> SSH/Incus -> alt-claude-slave"

if [[ "$#" -eq 0 ]]; then
  pnpm tools-dev
else
  pnpm tools-dev "$@"
fi
