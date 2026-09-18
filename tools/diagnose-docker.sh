#!/usr/bin/env bash
set -u

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p diagnostics
stamp="$(date +%Y%m%d-%H%M%S)"
out="diagnostics/docker-${stamp}.md"

section() {
  printf '\n## %s\n\n' "$1"
  printf '%s\n' '~~~text'
}

end_section() {
  printf '%s\n' '~~~'
}

{
  printf '# OpenDesign Docker diagnostic\n\n'
  printf -- '- Date: %s\n' "$(date -Is)"
  printf -- '- Host: %s\n' "$(hostname)"
  printf -- '- Branch: %s\n' "$(git branch --show-current)"
  printf -- '- Commit: %s\n' "$(git rev-parse HEAD)"

  section "docker compose ps"
  docker compose ps -a 2>&1 || true
  end_section

  section "alt-claude bridge logs"
  docker compose logs --no-color --tail=250 alt-claude-bridge 2>&1 || true
  end_section

  section "open-design logs"
  docker compose logs --no-color --tail=150 open-design 2>&1 || true
  end_section

  section "lan proxy logs"
  docker compose logs --no-color --tail=150 open-design-lan-proxy 2>&1 || true
  end_section

  section "health probes"
  printf '7456: '
  curl -i -sS --max-time 5 http://127.0.0.1:7456/api/health 2>&1 || true
  printf '\n18080: '
  docker compose exec -T open-design node -e "fetch('http://alt-claude-bridge:8081/v1/models').then(async r=>{console.log(r.status, await r.text())}).catch(e=>{console.error(e);process.exit(1)})" 2>&1 || true
  printf '\n'
  end_section

  section "selected container states"
  for c in open-design open-design-alt-claude-bridge open-design-lan-proxy; do
    if docker inspect "$c" >/dev/null 2>&1; then
      docker inspect -f '{{.Name}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} exit={{.State.ExitCode}} error={{.State.Error}}' "$c" 2>&1 || true
    else
      printf '%s: not present\n' "$c"
    fi
  done
  end_section

  section "bridge healthcheck history"
  docker inspect -f '{{range .State.Health.Log}}{{println .Start " exit=" .ExitCode}}{{println .Output}}{{end}}' open-design-alt-claude-bridge 2>&1 || true
  end_section

  section "port listeners"
  ss -ltnp 2>&1 | grep -E '(:7456)' || true
  end_section

  section "LAN proxy image"
  docker inspect -f '{{.Config.Image}} status={{.State.Status}} exit={{.State.ExitCode}}' open-design-lan-proxy 2>&1 || true
  end_section

  section "local versions"
  docker --version 2>&1 || true
  docker compose version 2>&1 || true
  git --version 2>&1 || true
  end_section
} > "$out"

echo "Diagnostic saved to $out"

git add "$out"

if git diff --cached --quiet; then
  echo "No diagnostic changes to commit."
  exit 0
fi

git commit --only "$out" -m "diagnostics: Docker failure $stamp"
git push origin "$(git branch --show-current)"

echo "Diagnostic committed and pushed."
