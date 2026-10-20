#!/usr/bin/env bash
#
# One-shot NanoClaw install against a local Ollama — no Anthropic account.
#
#   bash setup/ollama.sh <model> [nanoclaw.sh flags...]
#
# Ollama serves the Anthropic Messages API, so agents point ANTHROPIC_BASE_URL
# at it and no key is ever stored. This script checks Ollama, makes sure the
# model is present, seeds .env, then runs the normal setup (nanoclaw.sh) with
# every question answered. Add a messaging channel afterwards (/add-slack, …).
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

# ─── Ollama is up ──────────────────────────────────────────────────────
if ! curl -fsS -m 5 "$OLLAMA_URL/api/version" >/dev/null; then
  die "Ollama is not answering at $OLLAMA_URL. Install/start it (https://ollama.com/download) and retry."
fi
say "Ollama is running at $OLLAMA_URL"

# ─── Linux: containers can reach it ────────────────────────────────────
# Docker Desktop / OrbStack forward host.docker.internal to the host's
# loopback; on Linux it is the docker bridge, which a 127.0.0.1 bind refuses.
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
    for _ in $(seq 20); do curl -fsS -m 1 "$OLLAMA_URL/api/version" >/dev/null 2>&1 && break; sleep 0.5; done
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
