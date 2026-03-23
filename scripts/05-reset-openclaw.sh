#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

load_nvm_if_present
ensure_dirs

if command -v openclaw >/dev/null 2>&1; then
  stop_openclaw_gateway || true
  run openclaw gateway uninstall --json >/dev/null 2>&1 || true
  run openclaw uninstall --service --state --workspace --yes --non-interactive || true
fi

rm -f "$OPENCLAW_SERVICE_MODE_FILE" "$OPENCLAW_GATEWAY_TOKEN_FILE" "$OPENCLAW_PID_FILE"
rm -rf "$OPENCLAW_WORKSPACE"

log "OpenClaw local service state has been reset."
print_debug_paths
