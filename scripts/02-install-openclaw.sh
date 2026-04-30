#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

load_nvm_if_present
ensure_dirs
require_cmd curl
export npm_config_progress=false

ensure_ollama_cli
start_ollama

if command -v openclaw >/dev/null 2>&1; then
  log "OpenClaw is already installed; refreshing to the latest CLI package."
  run npm install -g openclaw@latest
else
  if [[ "$(node_major_version)" -ge 22 ]]; then
    log "Node.js 22+ detected; installing OpenClaw with npm."
    run npm install -g openclaw@latest
  else
    log "Node.js 22+ not detected; using the official OpenClaw installer."
    run bash -lc 'curl -fsSL https://openclaw.ai/install.sh | bash'
  fi
fi

ensure_openclaw_cli
run openclaw --version

if [[ -f "$OPENCLAW_CONFIG_FILE" ]]; then
  log "Existing OpenClaw config detected; running doctor before reconfiguration."
  run openclaw doctor --yes --non-interactive || true
fi

log "Importing the latest GGUF into Ollama before onboarding OpenClaw."
run "$SCRIPT_DIR/03-update-model.sh" --ollama-only --skip-verify

gateway_token="$(ensure_gateway_token)"

daemon_flag="--no-install-daemon"
if have_systemd; then
  daemon_flag="--install-daemon"
  record_service_mode "$OPENCLAW_SERVICE_MODE_FILE" "systemd"
  if command -v loginctl >/dev/null 2>&1 && have_passwordless_sudo; then
    run sudo loginctl enable-linger "$USER" || true
  elif command -v loginctl >/dev/null 2>&1; then
    warn "Passwordless sudo is unavailable; skipping loginctl enable-linger. Gateway will run for the current WSL user session."
  fi
else
  record_service_mode "$OPENCLAW_SERVICE_MODE_FILE" "manual"
fi

log "Running non-interactive OpenClaw onboarding for local Ollama."
run openclaw onboard \
  --non-interactive \
  --accept-risk \
  --mode local \
  --workspace "$OPENCLAW_WORKSPACE" \
  --auth-choice ollama \
  --custom-base-url "$OLLAMA_BASE_URL" \
  --custom-model-id "$OLLAMA_MODEL_TAG" \
  --secret-input-mode plaintext \
  --gateway-port "$OPENCLAW_PORT" \
  --gateway-bind "$OPENCLAW_BIND_MODE" \
  --gateway-auth token \
  --gateway-token "$gateway_token" \
  --daemon-runtime node \
  --node-manager npm \
  --skip-health \
  --skip-channels \
  --skip-skills \
  --skip-ui \
  $daemon_flag

run openclaw models scan >/dev/null 2>&1 || true
run openclaw models set "$OPENCLAW_MODEL_REF"

start_openclaw_gateway
verify_openclaw_model_target
verify_openclaw_gateway

run "$SCRIPT_DIR/04-verify.sh"
