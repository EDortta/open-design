#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

mkdir -p diagnostics
stamp="$(date +%Y%m%d-%H%M%S)"
out="diagnostics/docker-${stamp}.md"

{
  echo "# OpenDesign Docker diagnostic"
  echo
  echo "- Date: $(date -Is)"
  echo "- Host: $(hostname)"
  echo "- Branch: $(git branch --show-current)"
  echo "- Commit: $(git rev-parse HEAD)"
  echo
  echo "## docker compose ps"
  echo "```text"
  docker compose ps || true
  echo "```"
  echo
  echo "## alt-claude bridge logs"
  echo "```text"
  docker compose logs --no-color --tail=200 alt-claude-bridge || true
  echo "```"
  echo
  echo "## open-design logs"
  echo "```text"
  docker compose logs --no-color --tail=120 open-design || true
  echo "```"
  echo
  echo "## health probes"
  echo "```text"
  printf "7456: "
  curl -fsS --max-time 5 http://127.0.0.1:7456/api/health || true
  echo
  printf "18080: "
  curl -fsS --max-time 5 http://127.0.0.1:18080/v1/models || true
  echo
  echo "```"
  echo
  echo "## selected container states"
  echo "```text"
  for c in open-design open-design-alt-claude-bridge open-design-lan-proxy; do
    if docker inspect "$c" >/dev/null 2>&1; then
      docker inspect -f '{{.Name}} status={{.State.Status}} health={{if .State.Health}}{{.State.Health.Status}}{{else}}n/a{{end}} exit={{.State.ExitCode}} error={{.State.Error}}' "$c" || true
    fi
  done
  echo "```"
  echo
  echo "## local versions"
  echo "```text"
  docker --version || true
  docker compose version || true
  git --version || true
  echo "```"
} > "$out"

echo "Diagnostic saved to $out"

git add "$out"

if git diff --cached --quiet; then
  echo "No diagnostic changes to commit."
  exit 0
fi

git commit -m "diagnostics: Docker failure $stamp"
git push origin "$(git branch --show-current)"

echo "Diagnostic committed and pushed."
