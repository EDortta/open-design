#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

bash tools/docker-preflight.sh

echo "==> Build"
docker compose build

echo "==> Subindo stack"
docker compose up -d

echo "==> Estado"
docker compose ps
