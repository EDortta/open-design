#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${ALT_CLAUDE_OPENCODE_DIR:-$ROOT_DIR/.local/alt-claude}"
CONFIG_FILE="$CONFIG_DIR/opencode.json"

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "Configuração do alt-claude-slave ainda não existe; criando agora."
  bash "$ROOT_DIR/scripts/setup-alt-claude-slave.sh"
fi

export OPENCODE_CONFIG="$CONFIG_FILE"
export ALT_CLAUDE_API_KEY="${ALT_CLAUDE_API_KEY:-local-no-auth}"

cd "$ROOT_DIR"

echo "OpenDesign -> OpenCode -> alt-claude-slave"
echo "OPENCODE_CONFIG=$OPENCODE_CONFIG"

if [[ "$#" -eq 0 ]]; then
  exec pnpm tools-dev
else
  exec pnpm tools-dev "$@"
fi
