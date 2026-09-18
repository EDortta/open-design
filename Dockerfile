FROM docker.io/vanjayak/open-design:latest

USER root

# gcompat: camada de compatibilidade glibc para Alpine (musl)
# python3: necessário para aider e outros CLIs Python
# curl/rg/zip: utilitários básicos esperados por agentes e fluxos de empacotamento
RUN apk add --no-cache gcompat libc6-compat libstdc++ python3 py3-pip bash su-exec zip curl ripgrep

# Criar diretório home para o usuário open-design (CLIs escrevem configs aqui)
RUN mkdir -p /home/open-design /home/open-design/.config/opencode \
    && chown -R open-design:open-design /home/open-design

# AMR in Open Design resolves to the packaged Vela ACP agent. The meta package
# pulls the platform binary plus the bundled OpenCode companion.
RUN npm install -g @powerformer/vela-cli@0.0.25 opencode-ai

# Expose the host-mounted Codex CLI in a PATH directory without forcing the app
# itself to start with the host Node binary. Codex needs a writable CODEX_HOME,
# so keep host credentials mounted read-only and point a writable runtime home at
# those canonical files.
RUN cat >/usr/local/bin/codex <<'EOF' && chmod 0755 /usr/local/bin/codex
#!/bin/sh
set -eu

HOST_CODEX_HOME="${HOST_CODEX_HOME:-/home/open-design/.codex}"
RUNTIME_CODEX_HOME="${CODEX_HOME:-/home/open-design/.codex-runtime}"

mkdir -p "$RUNTIME_CODEX_HOME"
if [ -L "$RUNTIME_CODEX_HOME/memories" ]; then
  rm -f "$RUNTIME_CODEX_HOME/memories"
fi
mkdir -p "$RUNTIME_CODEX_HOME/memories"

for name in config.toml auth.json AGENTS.md; do
  if [ -f "$HOST_CODEX_HOME/$name" ] && [ ! -r "$RUNTIME_CODEX_HOME/$name" ]; then
    rm -f "$RUNTIME_CODEX_HOME/$name"
    cp "$HOST_CODEX_HOME/$name" "$RUNTIME_CODEX_HOME/$name"
  fi
done

for name in rules skills plugins; do
  if [ -e "$HOST_CODEX_HOME/$name" ] && [ ! -e "$RUNTIME_CODEX_HOME/$name" ]; then
    ln -s "$HOST_CODEX_HOME/$name" "$RUNTIME_CODEX_HOME/$name"
  fi
done

export CODEX_HOME="$RUNTIME_CODEX_HOME"
exec /mnt/host-node/bin/codex "$@"
EOF

# Host Grok Build is a static Linux binary under ~/.grok. Mount that tree at
# /mnt/host-grok and keep credentials in a writable runtime home so the
# daemon user can read auth.json (host file is 0600, uid 1000).
RUN cat >/usr/local/bin/grok <<'EOF' && chmod 0755 /usr/local/bin/grok
#!/bin/sh
set -eu

HOST_GROK_HOME="${HOST_GROK_HOME:-/mnt/host-grok}"
RUNTIME_GROK_HOME="${GROK_HOME:-/home/open-design/.grok-runtime}"

mkdir -p "$RUNTIME_GROK_HOME"
for name in auth.json config.toml; do
  if [ -f "$HOST_GROK_HOME/$name" ] && [ ! -r "$RUNTIME_GROK_HOME/$name" ]; then
    rm -f "$RUNTIME_GROK_HOME/$name"
    cp "$HOST_GROK_HOME/$name" "$RUNTIME_GROK_HOME/$name"
  fi
done

export GROK_HOME="$RUNTIME_GROK_HOME"
exec "$HOST_GROK_HOME/bin/grok" "$@"
EOF

# Host Copilot CLI is a glibc npm loader; Alpine needs the musl native
# binary, mounted at /mnt/host-copilot. Keep this wrapper ahead of
# ~/.local/bin/copilot on PATH.
RUN cat >/usr/local/bin/copilot <<'EOF' && chmod 0755 /usr/local/bin/copilot
#!/bin/sh
set -eu
exec /mnt/host-copilot "$@"
EOF

RUN cat >/usr/local/bin/open-design-entrypoint <<'EOF' && chmod 0755 /usr/local/bin/open-design-entrypoint
#!/bin/sh
set -eu

HOST_CODEX_HOME="${HOST_CODEX_HOME:-/home/open-design/.codex}"
RUNTIME_CODEX_HOME="${CODEX_HOME:-/home/open-design/.codex-runtime}"
HOST_GROK_HOME="${HOST_GROK_HOME:-/mnt/host-grok}"
RUNTIME_GROK_HOME="${GROK_HOME:-/home/open-design/.grok-runtime}"

mkdir -p "$RUNTIME_CODEX_HOME" "$RUNTIME_CODEX_HOME/memories" "$RUNTIME_GROK_HOME"

# Copy sensitive host-mounted config into a writable runtime home with the
# correct ownership so the daemon-invoked Codex can read it as open-design.
for name in config.toml auth.json AGENTS.md; do
  if [ -f "$HOST_CODEX_HOME/$name" ]; then
    cp "$HOST_CODEX_HOME/$name" "$RUNTIME_CODEX_HOME/$name"
  fi
done

for name in rules skills plugins; do
  if [ -e "$HOST_CODEX_HOME/$name" ] && [ ! -e "$RUNTIME_CODEX_HOME/$name" ]; then
    ln -s "$HOST_CODEX_HOME/$name" "$RUNTIME_CODEX_HOME/$name"
  fi
done

for name in auth.json config.toml; do
  if [ -f "$HOST_GROK_HOME/$name" ]; then
    cp "$HOST_GROK_HOME/$name" "$RUNTIME_GROK_HOME/$name"
  fi
done

chown -R open-design:open-design "$RUNTIME_CODEX_HOME" "$RUNTIME_GROK_HOME"

export CODEX_HOME="$RUNTIME_CODEX_HOME"
export GROK_HOME="$RUNTIME_GROK_HOME"
export COPILOT_HOME="${COPILOT_HOME:-/home/open-design/.copilot}"
mkdir -p "$COPILOT_HOME" /home/open-design/.cache
chown open-design:open-design "$COPILOT_HOME" /home/open-design/.cache
export HOME="${HOME:-/home/open-design}"

# First Copilot launch unpacks the musl runtime (~10s). Do that before the
# daemon's 3s --version probe so Settings does not show version: null.
su-exec open-design copilot --version >/dev/null 2>&1 || true

exec su-exec open-design "$@"
EOF

ENTRYPOINT ["/usr/local/bin/open-design-entrypoint"]
CMD ["node", "apps/daemon/dist/cli.js", "--no-open"]

USER root
