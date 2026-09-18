#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

node_major() {
  node -p 'process.versions.node.split(".")[0]' 2>/dev/null || true
}

activate_node24() {
  local major
  major="$(node_major)"
  if [[ "$major" == "24" ]]; then
    return 0
  fi

  if command -v fnm >/dev/null 2>&1; then
    eval "$(fnm env --shell bash)"
    fnm install 24
    fnm use 24
  elif [[ -s "$HOME/.nvm/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    source "$HOME/.nvm/nvm.sh"
    nvm install 24
    nvm use 24
  fi

  major="$(node_major)"
  if [[ "$major" != "24" ]]; then
    cat >&2 <<'EOF'
ERRO: OpenDesign exige Node 24.x.

Não encontrei um gerenciador Node que pudesse trocar automaticamente a versão.

Opção com fnm:
  fnm install 24
  fnm use 24

Opção com nvm:
  nvm install 24
  nvm use 24

Depois confirme:
  node --version

e execute novamente:
  pnpm alt-claude:run
EOF
    return 1
  fi
}

activate_node24

cd "$ROOT_DIR"

echo "==> Node: $(node --version)"

if command -v corepack >/dev/null 2>&1; then
  corepack enable
fi

if [[ ! -d node_modules ]]; then
  echo "==> Instalando dependências do OpenDesign"
  pnpm install
fi

if ! pnpm exec tools-dev --help >/dev/null 2>&1; then
  echo "ERRO: tools-dev não ficou disponível após pnpm install." >&2
  exit 2
fi

echo "==> Ambiente OpenDesign pronto"
