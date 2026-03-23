#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

load_nvm_if_present
ensure_dirs

latest_gguf="$(detect_latest_gguf)"
log "Latest GGUF in folder: ${latest_gguf}"

[[ -f "$CURRENT_GGUF_FILE" ]] || die "No active GGUF marker found. Run scripts/03-update-model.sh first."
active_gguf="$(<"$CURRENT_GGUF_FILE")"
log "Active GGUF recorded by pipeline: ${active_gguf}"

[[ "$latest_gguf" == "$active_gguf" ]] || die "Latest GGUF differs from the active one. Run scripts/03-update-model.sh to import the newest file."

ensure_ollama_cli
wait_for_ollama
run ollama --version
ollama_model_exists || die "Expected Ollama model ${OLLAMA_MODEL_TAG} is missing."
run ollama list
verify_ollama_inference
verify_ollama_tool_support

if command -v openclaw >/dev/null 2>&1 && [[ -f "$OPENCLAW_CONFIG_FILE" ]]; then
  run openclaw --version
  verify_openclaw_model_target
  verify_openclaw_gateway
  verify_openclaw_agent_smoke
else
  warn "OpenClaw CLI or config file is missing; skipping gateway verification."
fi

print_debug_paths
