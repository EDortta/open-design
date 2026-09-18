#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSPORT="${ALT_CLAUDE_TRANSPORT:-ssh-incus}"
MODEL="${ALT_CLAUDE_MODEL:-qwen-coder-3b}"
API_KEY="${ALT_CLAUDE_API_KEY:-local-no-auth}"
CONFIG_DIR="${ALT_CLAUDE_OPENCODE_DIR:-$ROOT_DIR/.local/alt-claude}"
CONFIG_FILE="$CONFIG_DIR/opencode.json"
BRIDGE_PORT="${ALT_CLAUDE_BRIDGE_PORT:-}"
BRIDGE_PORT_FILE="$CONFIG_DIR/bridge.port"
BRIDGE_HOST="${ALT_CLAUDE_BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PID=""

cleanup() {
  if [[ -n "$BRIDGE_PID" ]]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

find_working_opencode() {
  local candidate resolved
  for candidate in opencode-cli opencode; do
    resolved="$(command -v "$candidate" 2>/dev/null || true)"
    [[ -n "$resolved" ]] || continue

    if [[ ! -e "$resolved" ]]; then
      echo "AVISO: ignorando $candidate quebrado em $resolved" >&2
      continue
    fi

    if "$resolved" --version >/dev/null 2>&1; then
      printf '%s\n' "$resolved"
      return 0
    fi

    echo "AVISO: ignorando $candidate não funcional em $resolved" >&2
  done
  return 1
}

if ! OPENCODE_BIN="$(find_working_opencode)"; then
  cat >&2 <<'EOF'
ERRO: nenhum OpenCode funcional foi encontrado no PATH.

Diagnóstico rápido:
  command -v opencode-cli || true
  command -v opencode || true
  ls -l ~/.local/bin/opencode-cli ~/.local/bin/opencode 2>/dev/null || true

O script não usa links quebrados. Instale/repare o OpenCode e execute novamente:
  pnpm alt-claude:setup
EOF
  exit 1
fi

echo "==> OpenCode: $OPENCODE_BIN"

for cmd in node curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERRO: comando obrigatório não encontrado: $cmd" >&2; exit 1; }
done

mkdir -p "$CONFIG_DIR"

if [[ -z "$BRIDGE_PORT" ]]; then
  BRIDGE_PORT="$(python3 - <<'PY'
import socket
s = socket.socket()
s.bind(("127.0.0.1", 0))
print(s.getsockname()[1])
s.close()
PY
)"
fi
printf '%s\n' "$BRIDGE_PORT" > "$BRIDGE_PORT_FILE"

if [[ "$TRANSPORT" == "ssh-incus" ]]; then
  command -v ssh >/dev/null 2>&1 || { echo "ERRO: cliente SSH não encontrado." >&2; exit 1; }

  echo "==> Garantindo llama-server via SSH + Incus"
  python3 "$ROOT_DIR/scripts/alt-claude-http-bridge.py" \
    --ensure-server \
    --model "$MODEL"

  BASE_URL="http://$BRIDGE_HOST:$BRIDGE_PORT/v1"
  echo "==> Iniciando bridge local temporário em $BASE_URL"
  python3 "$ROOT_DIR/scripts/alt-claude-http-bridge.py" \
    --listen-host "$BRIDGE_HOST" \
    --listen-port "$BRIDGE_PORT" \
    >"$CONFIG_DIR/bridge.log" 2>&1 &
  BRIDGE_PID=$!

  ready=0
  for _ in {1..20}; do
    if curl -fsS --max-time 2 "$BASE_URL/models" >/dev/null 2>&1; then
      ready=1
      break
    fi
    if ! kill -0 "$BRIDGE_PID" 2>/dev/null; then
      cat "$CONFIG_DIR/bridge.log" >&2 || true
      echo "ERRO: bridge SSH/Incus encerrou antes de responder." >&2
      exit 2
    fi
    sleep 0.5
  done
  [[ "$ready" == "1" ]] || { cat "$CONFIG_DIR/bridge.log" >&2 || true; echo "ERRO: bridge não ficou pronto." >&2; exit 2; }
else
  BASE_URL="${ALT_CLAUDE_BASE_URL:-http://127.0.0.1:8080/v1}"
fi

echo "==> Verificando alt-claude-slave em $BASE_URL"
curl -fsS --max-time 5 "$BASE_URL/models" >/dev/null || { echo "ERRO: não foi possível alcançar $BASE_URL/models" >&2; exit 2; }

ALT_CLAUDE_BASE_URL="$BASE_URL" ALT_CLAUDE_MODEL="$MODEL" node --input-type=module <<'NODE' > "$CONFIG_FILE"
const baseURL = process.env.ALT_CLAUDE_BASE_URL;
const model = process.env.ALT_CLAUDE_MODEL;
const config = {
  "$schema": "https://opencode.ai/config.json",
  model: `alt-claude/${model}`,
  provider: {
    "alt-claude": {
      npm: "@ai-sdk/openai-compatible",
      name: "alt-claude-slave",
      options: { baseURL, apiKey: "{env:ALT_CLAUDE_API_KEY}" },
      models: { [model]: { name: `alt-claude-slave (${model})` } }
    }
  }
};
process.stdout.write(JSON.stringify(config, null, 2) + "\n");
NODE

echo "==> Configuração criada em $CONFIG_FILE"
echo "==> Verificando catálogo do OpenCode"
MODELS_OUTPUT="$(ALT_CLAUDE_API_KEY="$API_KEY" OPENCODE_CONFIG="$CONFIG_FILE" "$OPENCODE_BIN" models 2>&1)" || {
  echo "$MODELS_OUTPUT" >&2
  echo "ERRO: OpenCode não conseguiu carregar a configuração." >&2
  exit 3
}
grep -Fq "alt-claude/$MODEL" <<<"$MODELS_OUTPUT" || {
  echo "$MODELS_OUTPUT" >&2
  echo "ERRO: modelo alt-claude/$MODEL não apareceu em 'opencode models'." >&2
  exit 4
}

echo "==> OK: alt-claude/$MODEL detectado pelo OpenCode."

if [[ "${1:-}" == "--smoke" ]]; then
  echo "==> Executando smoke test"
  printf 'Responda apenas: ALT_CLAUDE_OK\n' | \
    ALT_CLAUDE_API_KEY="$API_KEY" OPENCODE_CONFIG="$CONFIG_FILE" \
    "$OPENCODE_BIN" run --format json -m "alt-claude/$MODEL"
fi

cat <<EOF

Pronto.
Transporte: $TRANSPORT
Modelo:     alt-claude/$MODEL
Endpoint:   $BASE_URL

Para iniciar:
  pnpm alt-claude:run
EOF
