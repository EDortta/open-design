#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

required=(
  "Dockerfile"
  "docker/alt-claude-bridge.Dockerfile"
  "docker/open-design-lan-proxy.Dockerfile"
  "nginx/open-design-lan.conf"
  ".agents/opencode/opencode.json"
)

for path in "${required[@]}"; do
  if [[ ! -f "$path" ]]; then
    echo "==> Restaurando arquivo versionado ausente: $path"
    mkdir -p "$(dirname "$path")"
    git show "HEAD:$path" > "$path"
  fi
done

echo "==> Validando arquivos exigidos"
for path in "${required[@]}"; do
  [[ -f "$path" ]] || { echo "ERRO: $path não é arquivo regular." >&2; exit 1; }
done

echo "==> Validando configuração Docker"
docker compose config >/dev/null

echo "==> Preflight OK"
