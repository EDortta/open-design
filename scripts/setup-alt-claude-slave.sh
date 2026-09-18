#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TRANSPORT="${ALT_CLAUDE_TRANSPORT:-ssh-incus}"
MODEL="${ALT_CLAUDE_MODEL:-qwen-coder-3b}"
API_KEY="${ALT_CLAUDE_API_KEY:-local-no-auth}"
CONFIG_DIR="${ALT_CLAUDE_OPENCODE_DIR:-$ROOT_DIR/.local/alt-claude}"
CONFIG_FILE="$CONFIG_DIR/opencode.json"
BRIDGE_PORT="${ALT_CLAUDE_BRIDGE_PORT:-18080}"
BRIDGE_HOST="${ALT_CLAUDE_BRIDGE_HOST:-127.0.0.1}"
BRIDGE_PID=""

cleanup() {
  if [[ -n "$BRIDGE_PID" ]]; then
    kill "$BRIDGE_PID" 2>/dev/null || true
    wait "$BRIDGE_PID" 2>/dev/null || true
  fi
}
trap cleanup EXIT

if command -v opencode-cli >/dev/null 2>&1; then
  OPENCODE_BIN="$(command -v opencode-cli)"
elif command -v opencode >/dev/null 2>&1; then
  OPENCODE_BIN="$(command -v opencode)"
else
  echo "ERRO: OpenCode não encontrado no PATH (opencode-cli/opencode)." >&2
  exit 1
fi

for cmd in node curl python3; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "ERRO: comando obrigatório não encontrado: $cmd" >&2; exit 1; }
done

mkdir -p "$CONFIG_DIR"

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
