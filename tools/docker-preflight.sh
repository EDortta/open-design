#!/usr/bin/env bash
set -Eeuo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LAN_CONF="nginx/open-design-lan.conf"
stamp="$(date +%Y%m%d-%H%M%S)"
repair_notes=()

record() { repair_notes+=("$*"); echo "==> $*"; }
tracked_file_exists() { git cat-file -e "HEAD:$LAN_CONF" 2>/dev/null; }
restore_tracked_file() {
  tracked_file_exists || { echo "ERRO: $LAN_CONF não existe em HEAD." >&2; return 1; }
  mkdir -p "$(dirname "$LAN_CONF")"
  git show "HEAD:$LAN_CONF" > "$LAN_CONF"
}

if [[ -d "$LAN_CONF" ]]; then
  recovery_dir=".recovery/nginx-open-design-lan.conf.bad-dir-$stamp"
  mkdir -p "$(dirname "$recovery_dir")"
  record "$LAN_CONF era diretório; preservando em $recovery_dir"
  mv "$LAN_CONF" "$recovery_dir"
  restore_tracked_file
  record "$LAN_CONF restaurado a partir de HEAD"
elif [[ ! -e "$LAN_CONF" ]]; then
  record "$LAN_CONF estava ausente; restaurando a partir de HEAD"
  restore_tracked_file
elif [[ ! -f "$LAN_CONF" ]]; then
  recovery_path=".recovery/nginx-open-design-lan.conf.bad-node-$stamp"
  mkdir -p "$(dirname "$recovery_path")"
  record "$LAN_CONF não era arquivo regular; preservando em $recovery_path"
  mv "$LAN_CONF" "$recovery_path"
  restore_tracked_file
  record "$LAN_CONF restaurado a partir de HEAD"
fi

[[ -f "$LAN_CONF" ]] || { echo "ERRO: não foi possível garantir $LAN_CONF como arquivo regular." >&2; exit 1; }

echo "==> Validando configuração Docker"
docker compose config >/dev/null

if ((${#repair_notes[@]} > 0)); then
  mkdir -p diagnostics
  evidence="diagnostics/preflight-$stamp.md"
  {
    echo "# OpenDesign Docker preflight repair"
    echo
    echo "- Date: $(date -Is)"
    echo "- Host: $(hostname)"
    echo "- Branch: $(git branch --show-current)"
    echo "- Commit: $(git rev-parse HEAD)"
    echo
    echo "## Repairs"
    for note in "${repair_notes[@]}"; do printf -- "- %s\n" "$note"; done
    echo
    echo "## Resulting filesystem state"
    echo "~~~text"
    ls -ld nginx "$LAN_CONF" 2>&1 || true
    file "$LAN_CONF" 2>&1 || true
    echo "~~~"
    echo
    echo "## Git state"
    echo "~~~text"
    git status --short -- "$LAN_CONF" .recovery diagnostics 2>&1 || true
    echo "~~~"
  } > "$evidence"
  git add "$evidence"
  git commit --only "$evidence" -m "diagnostics: preflight repair $stamp" || true
  git push origin "$(git branch --show-current)" || true
  echo "==> Evidência registrada em $evidence"
fi

echo "==> Preflight OK"
