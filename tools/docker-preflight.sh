#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LAN_CONF="nginx/open-design-lan.conf"

if [[ -d "$LAN_CONF" ]]; then
  stamp="$(date +%Y%m%d-%H%M%S)"
  backup="${LAN_CONF}.bad-dir-${stamp}"
  echo "==> Corrigindo $LAN_CONF: era diretório; movendo para $backup"
  mv "$LAN_CONF" "$backup"
  git checkout -- "$LAN_CONF"
fi

if [[ ! -f "$LAN_CONF" ]]; then
  echo "ERRO: $LAN_CONF não existe como arquivo." >&2
  exit 1
fi

echo "==> Validando configuração Docker"
docker compose config >/dev/null

echo "==> Preflight OK"
