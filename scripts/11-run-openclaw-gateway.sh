#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

load_nvm_if_present
ensure_dirs
require_cmd openclaw

gateway_token="$(ensure_gateway_token)"

log "Launching OpenClaw Gateway on ${OPENCLAW_UI_URL}."
exec openclaw gateway run \
  --port "$OPENCLAW_PORT" \
  --bind "$OPENCLAW_BIND_MODE" \
  --auth token \
  --token "$gateway_token"
