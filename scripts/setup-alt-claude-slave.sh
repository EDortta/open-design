#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BASE_URL="${ALT_CLAUDE_BASE_URL:-http://127.0.0.1:8080/v1}"
MODEL="${ALT_CLAUDE_MODEL:-qwen-coder-3b}"
API_KEY="${ALT_CLAUDE_API_KEY:-local-no-auth}"
CONFIG_DIR="${ALT_CLAUDE_OPENCODE_DIR:-$ROOT_DIR/.local/alt-claude}"
CONFIG_FILE="$CONFIG_DIR/opencode.json"

if command -v opencode-cli >/dev/null 2>&1; then
  OPENCODE_BIN="$(command -v opencode-cli)"
elif command -v opencode >/dev/null 2>&1; then
  OPENCODE_BIN="$(command -v opencode)"
else
  echo "ERRO: OpenCode não encontrado no PATH (opencode-cli/opencode)." >&2
  exit 1
fi

for cmd in node curl; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERRO: comando obrigatório não encontrado: $cmd" >&2
    exit 1
  fi
done

echo "==> Verificando alt-claude-slave em $BASE_URL"
if ! curl -fsS --max-time 5 "$BASE_URL/models" >/dev/null; then
  cat >&2 <<EOF
ERRO: não foi possível alcançar $BASE_URL/models

Se o llama-server estiver em outra máquina/container, informe o endpoint acessível
a partir deste computador, por exemplo:

  ALT_CLAUDE_BASE_URL=http://HOST:8080/v1 \
    bash scripts/setup-alt-claude-slave.sh

Não use o BYOK direto do OpenDesign para IP privado: esta integração passa pelo
OpenCode local deliberadamente.
EOF
  exit 2
fi

mkdir -p "$CONFIG_DIR"

ALT_CLAUDE_BASE_URL="$BASE_URL" \
ALT_CLAUDE_MODEL="$MODEL" \
node --input-type=module <<'NODE' > "$CONFIG_FILE"
const baseURL = process.env.ALT_CLAUDE_BASE_URL;
const model = process.env.ALT_CLAUDE_MODEL;

const config = {
  "$schema": "https://opencode.ai/config.json",
  model: `alt-claude/${model}`,
  provider: {
    "alt-claude": {
      npm: "@ai-sdk/openai-compatible",
      name: "alt-claude-slave",
      options: {
        baseURL,
        apiKey: "{env:ALT_CLAUDE_API_KEY}"
      },
      models: {
        [model]: {
          name: `alt-claude-slave (${model})`
        }
      }
    }
  }
};

process.stdout.write(JSON.stringify(config, null, 2) + "\n");
NODE

echo "==> Configuração criada em:"
echo "    $CONFIG_FILE"

echo "==> Verificando catálogo do OpenCode"
MODELS_OUTPUT="$(
  ALT_CLAUDE_API_KEY="$API_KEY" \
  OPENCODE_CONFIG="$CONFIG_FILE" \
  "$OPENCODE_BIN" models 2>&1
)" || {
  echo "$MODELS_OUTPUT" >&2
  echo "ERRO: OpenCode não conseguiu carregar a configuração." >&2
  exit 3
}

if ! grep -Fq "alt-claude/$MODEL" <<<"$MODELS_OUTPUT"; then
  echo "$MODELS_OUTPUT" >&2
  echo "ERRO: modelo alt-claude/$MODEL não apareceu em 'opencode models'." >&2
  exit 4
fi

echo "==> OK: alt-claude/$MODEL detectado pelo OpenCode."

if [[ "${1:-}" == "--smoke" ]]; then
  echo "==> Executando smoke test de geração local"
  printf 'Responda apenas: ALT_CLAUDE_OK\n' | \
    ALT_CLAUDE_API_KEY="$API_KEY" \
    OPENCODE_CONFIG="$CONFIG_FILE" \
    "$OPENCODE_BIN" run --format json -m "alt-claude/$MODEL"
fi

cat <<EOF

Pronto.

Para iniciar o OpenDesign usando esta configuração:

  bash scripts/run-with-alt-claude-slave.sh

Para validar também uma inferência real:

  bash scripts/setup-alt-claude-slave.sh --smoke

Modelo:   alt-claude/$MODEL
Endpoint: $BASE_URL
EOF
