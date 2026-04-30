#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

load_nvm_if_present
ensure_dirs

OLLAMA_ONLY=0
SKIP_VERIFY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --ollama-only)
      OLLAMA_ONLY=1
      shift
      ;;
    --skip-verify)
      SKIP_VERIFY=1
      shift
      ;;
    *)
      die "Unknown argument: $1"
      ;;
  esac
done

ensure_ollama_cli
start_ollama
ensure_ollama_base_template_model

latest_gguf="$(detect_latest_gguf)"
log "Latest GGUF selected: ${latest_gguf}"

write_generated_modelfile "$latest_gguf"
log "Generated Modelfile written to ${GENERATED_MODELFILE}"

run ollama create "$OLLAMA_MODEL_TAG" -f "$GENERATED_MODELFILE"

ollama_model_exists || die "Ollama did not register ${OLLAMA_MODEL_TAG} after model creation."
run ollama list
verify_ollama_inference
verify_ollama_tool_support

if [[ "$OLLAMA_ONLY" -eq 0 ]] && command -v openclaw >/dev/null 2>&1 && [[ -f "$OPENCLAW_CONFIG_FILE" ]]; then
  log "Refreshing OpenClaw to keep it pointed at ${OPENCLAW_MODEL_REF}."
  run openclaw models scan >/dev/null 2>&1 || true
  run openclaw models set "$OPENCLAW_MODEL_REF"
  restart_openclaw_gateway
  verify_openclaw_model_target
  verify_openclaw_gateway
else
  log "Skipping OpenClaw refresh because the CLI/config is not available yet."
fi

if [[ "$SKIP_VERIFY" -eq 0 ]]; then
  run "$SCRIPT_DIR/04-verify.sh"
fi
