#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")"

docker compose up -d --build

echo
echo "Aguardando open-design ficar healthy..."
for _ in $(seq 1 60); do
  status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' open-design 2>/dev/null || true)"
  if [[ "$status" == "healthy" ]]; then
    break
  fi
  sleep 2
done

status="$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' open-design 2>/dev/null || true)"
if [[ "$status" != "healthy" ]]; then
  echo "open-design não ficou healthy. Status atual: ${status:-desconhecido}" >&2
  docker compose ps
  exit 1
fi

echo
docker compose ps
echo

if curl -fsS http://127.0.0.1:7456/api/health >/dev/null 2>&1; then
  echo "Acesso local: http://127.0.0.1:7456"
else
  echo "Aviso: open-design healthy, mas /api/health em 127.0.0.1:7456 não respondeu." >&2
fi

if docker inspect --format '{{.State.Status}}' open-design-lan-proxy >/dev/null 2>&1; then
  proxy_status="$(docker inspect --format '{{.State.Status}}' open-design-lan-proxy 2>/dev/null || true)"
  if [[ "$proxy_status" == "running" ]]; then
    echo "Proxy LAN configurado em: http://192.168.7.18:7456"
  else
    echo "Proxy LAN não está operacional. Status: ${proxy_status:-desconhecido}"
  fi
fi
