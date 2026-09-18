#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

required=(
  "Dockerfile"
  "docker/alt-claude-bridge.Dockerfile"
  "docker/open-design-lan-proxy.Dockerfile"
  ".agents/opencode/opencode.json"
)


CREDENTIALS_TARGET="${HOME}/.config/credentials/personal"
CREDENTIALS_LINK=".credentials"

if [[ -L "$CREDENTIALS_LINK" ]]; then
  current_target="$(readlink -f "$CREDENTIALS_LINK" 2>/dev/null || true)"
  expected_target="$(readlink -f "$CREDENTIALS_TARGET" 2>/dev/null || true)"
  if [[ "$current_target" != "$expected_target" ]]; then
    echo "==> Recriando symlink $CREDENTIALS_LINK -> $CREDENTIALS_TARGET"
    rm -f "$CREDENTIALS_LINK"
    ln -s "$CREDENTIALS_TARGET" "$CREDENTIALS_LINK"
  fi
elif [[ -e "$CREDENTIALS_LINK" ]]; then
  echo "ERRO: $CREDENTIALS_LINK existe, mas não é symlink." >&2
  exit 1
else
  echo "==> Criando symlink $CREDENTIALS_LINK -> $CREDENTIALS_TARGET"
  ln -s "$CREDENTIALS_TARGET" "$CREDENTIALS_LINK"
fi

[[ -d "$CREDENTIALS_TARGET" ]] || {
  echo "ERRO: diretório de credenciais não existe: $CREDENTIALS_TARGET" >&2
  exit 1
}

echo "==> Validando arquivos exigidos"
for path in "${required[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "ERRO: arquivo versionado ausente: $path" >&2
    exit 1
  fi
done

echo "==> Validando configuração Docker"
docker compose config >/dev/null

echo "==> Preflight OK"
