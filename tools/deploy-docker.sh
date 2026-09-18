#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"
failure_reported=0

on_error() {
  local rc=$?
  local line="${BASH_LINENO[0]:-unknown}"
  if [[ "$failure_reported" == "0" ]]; then
    failure_reported=1
    trap - ERR
    echo "ERRO: deploy falhou na linha $line (exit=$rc)." >&2
    echo "==> Coletando e enviando diagnóstico automaticamente" >&2
    bash tools/diagnose-docker.sh || true
  fi
  exit "$rc"
}
trap on_error ERR

echo "==> Preflight"
bash tools/docker-preflight.sh

echo "==> Removendo containers antigos da stack"
docker compose rm -sf open-design alt-claude-bridge open-design-lan-proxy || true

echo "==> Build"
docker compose build --pull

echo "==> Subindo stack com recriação forçada"
docker compose up -d --force-recreate --remove-orphans

echo "==> Aguardando containers"
deadline=$((SECONDS + 120))
while (( SECONDS < deadline )); do
  bridge_state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' open-design-alt-claude-bridge 2>/dev/null || echo missing)"
  app_state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' open-design 2>/dev/null || echo missing)"
  proxy_state="$(docker inspect -f '{{.State.Status}}' open-design-lan-proxy 2>/dev/null || echo missing)"

  echo "    bridge: $bridge_state | open-design: $app_state | proxy: $proxy_state"

  if [[ "$bridge_state" == "running healthy" && "$app_state" == "running healthy" && "$proxy_state" == "running" ]]; then
    break
  fi

  if [[ "$bridge_state" == exited* || "$bridge_state" == restarting* || "$bridge_state" == dead* || "$bridge_state" == missing* ]]; then
    echo "ERRO: bridge não estabilizou: $bridge_state" >&2
    false
  fi

  if [[ "$app_state" == exited* || "$app_state" == dead* ]]; then
    echo "ERRO: OpenDesign não estabilizou: $app_state" >&2
    false
  fi

  if [[ "$proxy_state" == exited* || "$proxy_state" == dead* ]]; then
    echo "ERRO: proxy não estabilizou: $proxy_state" >&2
    false
  fi

  sleep 3
done

bridge_state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' open-design-alt-claude-bridge 2>/dev/null || echo missing)"
app_state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' open-design 2>/dev/null || echo missing)"
proxy_state="$(docker inspect -f '{{.State.Status}}' open-design-lan-proxy 2>/dev/null || echo missing)"

[[ "$bridge_state" == "running healthy" ]] || { echo "ERRO: timeout aguardando bridge saudável: $bridge_state" >&2; false; }
[[ "$app_state" == "running healthy" ]] || { echo "ERRO: timeout aguardando OpenDesign saudável: $app_state" >&2; false; }
[[ "$proxy_state" == "running" ]] || { echo "ERRO: timeout aguardando proxy: $proxy_state" >&2; false; }

echo "==> Validando endpoints"
curl -fsS --max-time 10 http://127.0.0.1:18081/v1/models >/dev/null
curl -fsS --max-time 10 http://127.0.0.1:7456/api/health >/dev/null

echo "==> Estado final"
docker compose ps
echo "==> Deploy Docker concluído"
