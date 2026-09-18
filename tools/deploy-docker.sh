#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p diagnostics
stamp="$(date +%Y%m%d-%H%M%S)"
deploy_log="diagnostics/deploy-$stamp.log"
failure_reported=0

exec > >(tee -a "$deploy_log") 2>&1

push_evidence() {
  git add "$deploy_log" 2>/dev/null || true
  if ! git diff --cached --quiet -- "$deploy_log"; then
    git commit --only "$deploy_log" -m "diagnostics: Docker deploy $stamp" || true
    git push origin "$(git branch --show-current)" || true
  fi
}

on_exit() {
  local rc=$?
  if [[ "$rc" -ne 0 && "$failure_reported" == "0" ]]; then
    failure_reported=1
    trap - ERR
    echo "ERRO: deploy terminou com exit=$rc"
    echo "==> Coletando diagnóstico complementar"
    bash tools/diagnose-docker.sh || true
    push_evidence
  elif [[ "$rc" -eq 0 ]]; then
    echo "==> Registrando evidência de deploy bem-sucedido"
    push_evidence
  fi
  exit "$rc"
}
trap on_exit EXIT


load_od_api_token() {
  local candidates=(
    ".credentials/open-design.env"
    ".credentials/open-design.conf"
    ".credentials/opendesign.env"
    ".credentials/opendesign.conf"
  )

  local f
  for f in "${candidates[@]}"; do
    [[ -f "$f" ]] || continue
    if grep -qE '^[[:space:]]*OD_API_TOKEN=' "$f"; then
      set -a
      # shellcheck disable=SC1090
      source "$f"
      set +a
      [[ -n "${OD_API_TOKEN:-}" ]] || continue
      echo "==> OD_API_TOKEN carregado de $f"
      export OD_API_TOKEN
      return 0
    fi
  done

  if [[ -n "${OD_API_TOKEN:-}" ]]; then
    echo "==> OD_API_TOKEN já presente no ambiente"
    export OD_API_TOKEN
    return 0
  fi

  if docker inspect open-design >/dev/null 2>&1; then
    existing_token="$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' open-design 2>/dev/null | sed -n 's/^OD_API_TOKEN=//p' | head -n1)"
    if [[ -n "$existing_token" ]]; then
      OD_API_TOKEN="$existing_token"
      export OD_API_TOKEN
      echo "==> OD_API_TOKEN reaproveitado do container atual"
      return 0
    fi
  fi

  echo "ERRO: OD_API_TOKEN não encontrado em .credentials nem no container atual." >&2
  echo "Verificados: open-design.env, open-design.conf, opendesign.env, opendesign.conf" >&2
  return 1
}

echo "==> OpenDesign Docker deploy"
echo "Date: $(date -Is)"
echo "Branch: $(git branch --show-current)"
echo "Commit: $(git rev-parse HEAD)"

echo "==> Preflight"
bash tools/docker-preflight.sh
load_od_api_token

echo "==> Removendo containers antigos da stack"
docker rm -f open-design open-design-alt-claude-bridge open-design-lan-proxy 2>/dev/null || true

echo "==> Build"
docker compose build --pull --no-cache

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
    echo "ERRO: bridge não estabilizou: $bridge_state"
    exit 20
  fi

  if [[ "$app_state" == exited* || "$app_state" == dead* ]]; then
    echo "ERRO: OpenDesign não estabilizou: $app_state"
    exit 21
  fi

  if [[ "$proxy_state" == exited* || "$proxy_state" == dead* ]]; then
    echo "ERRO: proxy não estabilizou: $proxy_state"
    exit 22
  fi

  sleep 3
done

bridge_state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' open-design-alt-claude-bridge 2>/dev/null || echo missing)"
app_state="$(docker inspect -f '{{.State.Status}} {{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}}' open-design 2>/dev/null || echo missing)"
proxy_state="$(docker inspect -f '{{.State.Status}}' open-design-lan-proxy 2>/dev/null || echo missing)"

[[ "$bridge_state" == "running healthy" ]] || { echo "ERRO: timeout aguardando bridge saudável: $bridge_state"; exit 30; }
[[ "$app_state" == "running healthy" ]] || { echo "ERRO: timeout aguardando OpenDesign saudável: $app_state"; exit 31; }
[[ "$proxy_state" == "running" ]] || { echo "ERRO: timeout aguardando proxy: $proxy_state"; exit 32; }

echo "==> Validando endpoints"
docker compose exec -T open-design node -e "fetch('http://alt-claude-bridge:8081/v1/models').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))"
curl -fsS --max-time 10 http://127.0.0.1:7456/api/health >/dev/null

echo "==> Estado final"
docker compose ps

echo "==> Deploy Docker concluído"
