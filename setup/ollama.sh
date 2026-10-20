#!/usr/bin/env bash
#
# One-shot NanoClaw install against a local Ollama — no Anthropic account.
#
#   bash setup/ollama.sh <model> [nanoclaw.sh flags...]
#
# Ollama serves the Anthropic Messages API, so agents point ANTHROPIC_BASE_URL
# at it and no key is ever stored. This script gets Ollama and the model ready,
# seeds .env, then runs the normal setup (nanoclaw.sh) with every question
# answered. Add a messaging channel afterwards (/add-slack, …).
#
#   macOS: needs Homebrew. Installs OrbStack as the Docker runtime (selected
#          even if Docker Desktop is present) and Ollama when missing; setup
#          itself installs Node and pnpm.
#   Linux: expects Ollama running; offers to rebind it beyond loopback so
#          agent containers can reach it. Setup installs Docker if missing.
#
# Env:
#   OLLAMA_URL  where this host reaches Ollama (default http://127.0.0.1:11434)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MODEL="${1:-}"
if [ -z "$MODEL" ] || [ "${MODEL#-}" != "$MODEL" ]; then
  echo "Usage: bash setup/ollama.sh <model> [nanoclaw.sh flags...]" >&2
  echo "  <model> is any tag Ollama can serve, e.g. qwen3-coder:30b or gpt-oss:120b-cloud" >&2
  exit 1
fi
shift

OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OLLAMA_PORT="${OLLAMA_URL##*:}"
OLLAMA_PORT="${OLLAMA_PORT%%/*}"
# What agents use from inside their containers. NanoClaw maps
# host.docker.internal to the host on every platform.
AGENT_URL="http://host.docker.internal:${OLLAMA_PORT}"

die() { echo "error: $*" >&2; exit 1; }
say() { echo "==> $*"; }
# wait_for <seconds> <command...>: poll until the command succeeds.
wait_for() {
  local n="$1"
  shift
  for _ in $(seq "$n"); do
    "$@" >/dev/null 2>&1 && return 0
    sleep 1
  done
  return 1
}
ollama_up() { curl -fsS -m 2 "$OLLAMA_URL/api/version"; }

# ─── macOS: OrbStack + Ollama via Homebrew ─────────────────────────────
if [ "$(uname -s)" = "Darwin" ]; then
  command -v brew >/dev/null || die "Homebrew is required on macOS: https://brew.sh"
  export PATH="$HOME/.orbstack/bin:$PATH"

  # OrbStack, never Docker Desktop. Setup would install Docker Desktop when no
  # docker CLI exists and only knows how to start that one, so OrbStack must be
  # installed, selected and running before setup looks.
  if [ ! -d /Applications/OrbStack.app ]; then
    say "Installing OrbStack…"
    brew install --cask orbstack
  fi
  # Probe OrbStack by name: a running Docker Desktop would answer a bare
  # `docker info` through its own context.
  if ! docker --context orbstack info >/dev/null 2>&1; then
    say "Starting OrbStack…"
    orb start >/dev/null 2>&1 || open -a OrbStack
    if ! wait_for 120 docker --context orbstack info; then
      die "OrbStack did not start. Open it once from Applications, then retry."
    fi
  fi
  # The docker CLI (and the NanoClaw service) follow the current context.
  docker context use orbstack >/dev/null 2>&1
  say "Docker runtime: OrbStack"

  if ! ollama_up >/dev/null 2>&1; then
    if ! command -v ollama >/dev/null; then
      say "Installing Ollama…"
      brew install ollama
    fi
    say "Starting Ollama…"
    if [ -d /Applications/Ollama.app ]; then open -a Ollama; else brew services start ollama; fi
    wait_for 30 ollama_up || die "Ollama did not start at $OLLAMA_URL."
  fi
fi

# ─── Ollama is up ──────────────────────────────────────────────────────
if ! ollama_up >/dev/null 2>&1; then
  die "Ollama is not answering at $OLLAMA_URL. Install/start it (https://ollama.com/download) and retry."
fi
say "Ollama is running at $OLLAMA_URL"

# ─── Linux: containers can reach it ────────────────────────────────────
# OrbStack forwards host.docker.internal to the host's loopback; on Linux it
# is the docker bridge, which a 127.0.0.1 bind refuses.
if [ "$(uname -s)" = "Linux" ] && command -v ss >/dev/null &&
  ! ss -ltnH "sport = :$OLLAMA_PORT" | awk '{print $4}' | grep -qvE '^(127\.0\.0\.1|\[::1\]):'; then
  echo "Ollama listens on loopback only, so agent containers cannot reach it."
  if systemctl cat ollama >/dev/null 2>&1; then
    read -r -p "Rebind it to 0.0.0.0:$OLLAMA_PORT via a systemd drop-in (uses sudo)? [Y/n] " ans </dev/tty || ans=n
    case "$ans" in [nN]*) die "Set OLLAMA_HOST=0.0.0.0:$OLLAMA_PORT for the Ollama service and retry." ;; esac
    # Own drop-in file: `systemctl edit` writes override.conf, leave that alone.
    printf '[Service]\nEnvironment="OLLAMA_HOST=0.0.0.0:%s"\n' "$OLLAMA_PORT" |
      sudo install -D -m 644 /dev/stdin /etc/systemd/system/ollama.service.d/nanoclaw.conf
    sudo systemctl daemon-reload
    sudo systemctl restart ollama
    wait_for 15 ollama_up || die "Ollama did not come back after the restart."
    say "Ollama rebound to 0.0.0.0:$OLLAMA_PORT. It has no auth: firewall port $OLLAMA_PORT to trusted networks."
  else
    die "Start Ollama with OLLAMA_HOST=0.0.0.0:$OLLAMA_PORT and retry."
  fi
fi

# ─── model is present ──────────────────────────────────────────────────
show() { curl -sS -m 10 -o /dev/null -w '%{http_code}' "$OLLAMA_URL/api/show" -d "{\"model\":\"$MODEL\"}"; }
if [ "$(show)" != "200" ]; then
  say "Pulling ${MODEL}…"
  if command -v ollama >/dev/null; then
    OLLAMA_HOST="$OLLAMA_URL" ollama pull "$MODEL"
  else
    curl -fsS "$OLLAMA_URL/api/pull" -d "{\"model\":\"$MODEL\",\"stream\":false}" >/dev/null
  fi
  [ "$(show)" = "200" ] || die "Ollama still has no model '$MODEL' (cloud models need \`ollama signin\`)."
fi
say "Model $MODEL is available"

# ─── seed .env ─────────────────────────────────────────────────────────
touch .env
chmod 600 .env
set_env() {
  local tmp
  tmp="$(mktemp)"
  grep -v "^$1=" .env >"$tmp" || true
  echo "$1=$2" >>"$tmp"
  cat "$tmp" >.env
  rm -f "$tmp"
}
set_env ANTHROPIC_BASE_URL "$AGENT_URL"
set_env NANOCLAW_DEFAULT_MODEL "$MODEL"
# Setup would otherwise stop to confirm the detected timezone.
if ! grep -q '^TZ=' .env; then
  tz="$(timedatectl show -p Timezone --value 2>/dev/null || true)"
  [ -n "$tz" ] || tz="$(readlink /etc/localtime 2>/dev/null | sed 's|.*zoneinfo/||')"
  set_env TZ "${tz:-UTC}"
fi
say ".env: ANTHROPIC_BASE_URL=$AGENT_URL NANOCLAW_DEFAULT_MODEL=$MODEL $(grep '^TZ=' .env)"

# ─── run setup, unattended ─────────────────────────────────────────────
exec bash nanoclaw.sh \
  --yes \
  --gateway-provider onecli \
  --agent-provider claude \
  --anthropic-base-url "$AGENT_URL" \
  --display-name "${USER:-Operator}" \
  --skip timezone,channel,slack-reminder,echo-reminder \
  "$@"
