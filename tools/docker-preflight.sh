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
