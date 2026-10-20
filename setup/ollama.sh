#!/usr/bin/env bash
#
# One-shot NanoClaw install against Ollama — no Anthropic account.
#
#   bash setup/ollama.sh [model] [nanoclaw.sh flags...]
#
# Ollama serves the Anthropic Messages API, so agents point ANTHROPIC_BASE_URL
# at it and no key is ever stored. This script installs and starts Ollama when
# missing, picks a model (Ollama Cloud, or a local one sized to this machine's
# GPU memory) unless one is given, seeds .env, then runs the normal setup
# (nanoclaw.sh) with every question answered. Add a messaging channel
# afterwards (/add-slack, …).
#
#   macOS: needs Homebrew. Installs OrbStack as the Docker runtime (selected
#          even if Docker Desktop is present) and Ollama when missing; setup
#          itself installs Node and pnpm.
#   Linux: installs Ollama with its official installer when missing and
#          offers to rebind it beyond loopback so agent containers can reach
#          it. Setup installs Docker if missing.
#
# Env:
#   OLLAMA_URL  where this host reaches Ollama (default http://127.0.0.1:11434)

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$PROJECT_ROOT"

MODEL=""
if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
  MODEL="$1"
  shift
fi

CLOUD_MODEL="gpt-oss:120b-cloud"
# Local picks, largest first: tag, GB of GPU memory it needs with a 32k
# context, description. Revisit as models move.
LOCAL_MODELS=(
  "gpt-oss:120b|70|OpenAI gpt-oss 120B"
  "qwen3-coder:30b|24|Qwen3-Coder 30B, strong at tool use"
  "gpt-oss:20b|16|OpenAI gpt-oss 20B"
  "qwen3:8b|10|Qwen3 8B"
  "qwen3:4b|6|Qwen3 4B, light; weak at long tasks"
)

OLLAMA_URL="${OLLAMA_URL:-http://127.0.0.1:11434}"
OLLAMA_PORT="${OLLAMA_URL##*:}"
OLLAMA_PORT="${OLLAMA_PORT%%/*}"
# What agents use from inside their containers. NanoClaw maps
# host.docker.internal to the host on every platform.
AGENT_URL="http://host.docker.internal:${OLLAMA_PORT}"
OS="$(uname -s)"

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
api() { curl -sS -m "${TIMEOUT:-30}" "$OLLAMA_URL/api/$1" -d "$2"; }
api_status() { curl -sS -m "${TIMEOUT:-30}" -o /dev/null -w '%{http_code}' "$OLLAMA_URL/api/$1" -d "$2"; }

# GPU memory a model can use, in GB. 0 means CPU only.
gpu_gb() {
  if [ "$OS" = "Darwin" ]; then
    # Apple silicon shares RAM with the GPU. Budget half of it: the machine
    # is usually also someone's desktop.
    [ "$(uname -m)" = "arm64" ] && echo $(($(sysctl -n hw.memsize) / 1073741824 / 2)) || echo 0
  elif command -v nvidia-smi >/dev/null; then
    nvidia-smi --query-gpu=memory.total --format=csv,noheader,nounits | awk '{s += $1} END {print int(s / 1024)}'
  elif ls /sys/class/drm/card*/device/mem_info_vram_total >/dev/null 2>&1; then
    cat /sys/class/drm/card*/device/mem_info_vram_total | awk '{s += $1} END {print int(s / 1073741824)}'
  else
    echo 0
  fi
}

# ─── macOS: OrbStack via Homebrew ──────────────────────────────────────
if [ "$OS" = "Darwin" ]; then
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
fi

# ─── Ollama installed and running ──────────────────────────────────────
if ! ollama_up >/dev/null 2>&1; then
  if ! command -v ollama >/dev/null; then
    say "Installing Ollama…"
    if [ "$OS" = "Darwin" ]; then
      brew install ollama
    else
      # /bin/sh by absolute path, https only (see setup/installer-shell.test.ts).
      curl --proto '=https' --proto-redir '=https' -fsSL https://ollama.com/install.sh | /bin/sh
    fi
  fi
  say "Starting Ollama…"
  if [ "$OS" = "Darwin" ]; then
    if [ -d /Applications/Ollama.app ]; then open -a Ollama; else brew services start ollama; fi
  else
    sudo systemctl enable --now ollama
  fi
  wait_for 30 ollama_up || die "Ollama is not answering at $OLLAMA_URL."
fi
say "Ollama is running at $OLLAMA_URL"

# ─── Linux: containers can reach it ────────────────────────────────────
# OrbStack forwards host.docker.internal to the host's loopback; on Linux it
# is the docker bridge, which a 127.0.0.1 bind refuses.
if [ "$OS" = "Linux" ] && command -v ss >/dev/null &&
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

# ─── pick a model ──────────────────────────────────────────────────────
if [ -z "$MODEL" ]; then
  gb="$(gpu_gb)"
  echo
  echo "Which model should your agents run on? (GPU memory available: ~${gb} GB)"
  choices=("$CLOUD_MODEL")
  echo "  1) $CLOUD_MODEL — Ollama Cloud, recommended: fast, needs a free ollama.com sign-in"
  for entry in "${LOCAL_MODELS[@]}"; do
    IFS='|' read -r tag need desc <<<"$entry"
    [ "$gb" -ge "$need" ] || continue
    choices+=("$tag")
    echo "  ${#choices[@]}) $tag — local: $desc (needs ~${need} GB)"
  done
  [ ${#choices[@]} -gt 1 ] || echo "     (no local model fits this machine's GPU memory; local inference would be very slow)"
  echo "  or type any Ollama model tag"
  read -r -p "Choice [1]: " pick </dev/tty || die "No terminal to ask on. Pass the model: bash setup/ollama.sh <model>"
  pick="${pick:-1}"
  if [[ "$pick" =~ ^[0-9]+$ ]]; then
    [ "$pick" -ge 1 ] && [ "$pick" -le ${#choices[@]} ] || die "No choice $pick."
    MODEL="${choices[$((pick - 1))]}"
  else
    MODEL="$pick"
  fi
fi

# ─── model present, signed in, sized, answering ────────────────────────
is_cloud() { [[ "$MODEL" == *cloud* ]]; }
if [ "$(api_status show "{\"model\":\"$MODEL\"}")" != "200" ]; then
  say "Pulling ${MODEL}…"
  if command -v ollama >/dev/null; then
    OLLAMA_HOST="$OLLAMA_URL" ollama pull "$MODEL"
  else
    TIMEOUT=0 api pull "{\"model\":\"$MODEL\",\"stream\":false}" >/dev/null
  fi
  [ "$(api_status show "{\"model\":\"$MODEL\"}")" = "200" ] || die "Ollama has no model '$MODEL'."
fi

# Local models default to a context far below the ~16k-token base prompt.
# Wrap one that doesn't set num_ctx; cloud models size context server side.
if ! is_cloud && [[ "$(api show "{\"model\":\"$MODEL\"}")" != *num_ctx* ]]; then
  ctx=32768
  [ "$(gpu_gb)" -lt 32 ] || ctx=65536
  wrapped="nanoclaw-${MODEL//[:\/]/-}"
  say "Creating $wrapped ($MODEL with a ${ctx}-token context)"
  body="{\"model\":\"$wrapped\",\"from\":\"$MODEL\",\"parameters\":{\"num_ctx\":$ctx},\"stream\":false}"
  [ "$(api_status create "$body")" = "200" ] || die "Could not create $wrapped."
  MODEL="$wrapped"
fi

chat() { TIMEOUT=600 api_status chat "{\"model\":\"$MODEL\",\"messages\":[{\"role\":\"user\",\"content\":\"hi\"}],\"stream\":false,\"options\":{\"num_predict\":1}}"; }
say "Checking $MODEL answers (a local model's first load can take a few minutes)…"
code="$(chat)"
if [[ "$code" == 40[13] ]] && is_cloud && command -v ollama >/dev/null; then
  say "Ollama Cloud needs a sign-in. Open the link below and approve this device."
  OLLAMA_HOST="$OLLAMA_URL" ollama signin </dev/tty
  code="$(chat)"
fi
[ "$code" = "200" ] || die "$MODEL did not answer (HTTP $code)."
say "Model $MODEL is ready"

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
