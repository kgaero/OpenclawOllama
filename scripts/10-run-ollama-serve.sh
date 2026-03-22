#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

load_nvm_if_present
ensure_dirs
require_cmd ollama

export OLLAMA_HOST="${OLLAMA_BIND_HOST}:${OLLAMA_PORT}"

log "Launching ollama serve with OLLAMA_HOST=${OLLAMA_HOST}."
exec ollama serve
