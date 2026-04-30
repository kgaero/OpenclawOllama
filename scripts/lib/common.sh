#!/usr/bin/env bash

COMMON_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$COMMON_DIR/.." && pwd)"
PIPELINE_ROOT="$(cd "$SCRIPTS_DIR/.." && pwd)"

# shellcheck disable=SC1091
source "$SCRIPTS_DIR/00-env.sh"

timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[%s] %s\n' "$(timestamp_utc)" "$*"
}

warn() {
  printf '[%s] WARNING: %s\n' "$(timestamp_utc)" "$*" >&2
}

error() {
  printf '[%s] ERROR: %s\n' "$(timestamp_utc)" "$*" >&2
}

die() {
  error "$*"
  exit 1
}

on_error() {
  local exit_code="$1"
  local line_no="$2"
  local command_text="$3"
  error "Command failed at line ${line_no}: ${command_text}"
  print_debug_paths >&2 || true
  exit "$exit_code"
}

run() {
  log "+ $*"
  "$@"
}

ensure_dirs() {
  mkdir -p "$LOG_DIR" "$RUN_DIR" "$STATE_DIR" "$GENERATED_DIR" "$OPENCLAW_WORKSPACE"
  chmod 700 "$RUN_DIR" "$STATE_DIR"
}

load_nvm_if_present() {
  export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    # shellcheck disable=SC1090
    source "$NVM_DIR/nvm.sh"
  fi
}

require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || die "Missing required command: ${cmd}"
}

have_passwordless_sudo() {
  command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

have_systemd() {
  [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}

node_major_version() {
  if ! command -v node >/dev/null 2>&1; then
    echo 0
    return
  fi

  node -p 'process.versions.node.split(".")[0]' 2>/dev/null || echo 0
}

record_service_mode() {
  local file_path="$1"
  local mode="$2"
  printf '%s\n' "$mode" >"$file_path"
}

read_service_mode() {
  local file_path="$1"
  local fallback="$2"

  if [[ -f "$file_path" ]]; then
    cat "$file_path"
  else
    printf '%s\n' "$fallback"
  fi
}

is_pid_running() {
  local pid_file="$1"

  [[ -f "$pid_file" ]] || return 1

  local pid
  pid="$(<"$pid_file")"
  [[ -n "$pid" ]] || return 1

  kill -0 "$pid" >/dev/null 2>&1
}

start_background_process() {
  local name="$1"
  local script_path="$2"
  local pid_file="$3"
  local log_file="$4"

  if is_pid_running "$pid_file"; then
    log "${name} already running with PID $(<"$pid_file")."
    return 0
  fi

  log "Starting ${name} in background."
  nohup "$script_path" >>"$log_file" 2>&1 &
  echo "$!" >"$pid_file"
  sleep 1

  if ! is_pid_running "$pid_file"; then
    die "${name} did not stay running. Check ${log_file}."
  fi
}

stop_background_process() {
  local name="$1"
  local pid_file="$2"

  if ! [[ -f "$pid_file" ]]; then
    log "${name} is not running under manual PID control."
    return 0
  fi

  local pid
  pid="$(<"$pid_file")"

  if [[ -z "$pid" ]] || ! kill -0 "$pid" >/dev/null 2>&1; then
    rm -f "$pid_file"
    log "${name} PID file was stale and has been removed."
    return 0
  fi

  log "Stopping ${name} (PID ${pid})."
  kill "$pid" >/dev/null 2>&1 || true

  local waited=0
  while kill -0 "$pid" >/dev/null 2>&1; do
    if (( waited >= 20 )); then
      warn "${name} did not stop cleanly; sending SIGKILL."
      kill -9 "$pid" >/dev/null 2>&1 || true
      break
    fi

    sleep 1
    waited=$((waited + 1))
  done

  rm -f "$pid_file"
}

wait_for_ollama() {
  local attempts=30
  local i

  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS "$OLLAMA_BASE_URL/api/tags" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  die "Ollama is not responding at ${OLLAMA_BASE_URL}. Check ${OLLAMA_LOG_FILE}."
}

wait_for_openclaw_ui() {
  local attempts=45
  local i

  for ((i = 1; i <= attempts; i++)); do
    if curl -fsS "$OPENCLAW_UI_URL" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  die "OpenClaw Control UI is not responding at ${OPENCLAW_UI_URL}. Check ${OPENCLAW_LOG_FILE}."
}

ensure_gateway_token() {
  ensure_dirs

  if [[ -s "$OPENCLAW_GATEWAY_TOKEN_FILE" ]]; then
    cat "$OPENCLAW_GATEWAY_TOKEN_FILE"
    return 0
  fi

  local token
  if command -v openssl >/dev/null 2>&1; then
    token="$(openssl rand -hex 24)"
  else
    token="$(date +%s%N | sha256sum | awk '{print $1}' | cut -c1-48)"
  fi

  printf '%s\n' "$token" >"$OPENCLAW_GATEWAY_TOKEN_FILE"
  chmod 600 "$OPENCLAW_GATEWAY_TOKEN_FILE"
  printf '%s\n' "$token"
}

detect_latest_gguf() {
  local latest_record
  latest_record="$(
    find "$GGUF_SEARCH_DIR" -maxdepth 1 -type f -iname '*.gguf' -printf '%T@ %p\0' \
      | sort -z -n \
      | tail -z -n 1 \
      | tr -d '\0'
  )"

  [[ -n "$latest_record" ]] || die "No GGUF files were found in ${GGUF_SEARCH_DIR}."

  printf '%s\n' "${latest_record#* }"
}

ensure_ollama_base_template_model() {
  ensure_ollama_cli
  log "Ensuring Ollama base template model is available: ${OLLAMA_TEMPLATE_BASE_MODEL}"
  run ollama pull "$OLLAMA_TEMPLATE_BASE_MODEL"
}

write_generated_modelfile() {
  local source_gguf="$1"
  local base_modelfile
  local rewritten_modelfile

  ln -sfn "$source_gguf" "$GENERATED_GGUF_LINK"

  base_modelfile="$(ollama show --modelfile "$OLLAMA_TEMPLATE_BASE_MODEL")" || die "Failed to read Modelfile for base model ${OLLAMA_TEMPLATE_BASE_MODEL}."

  rewritten_modelfile="$(
    python3 -c '
import sys

target_from = sys.argv[1]
text = sys.argv[2]
lines = text.splitlines()
replaced = False
out = []

for line in lines:
    if line.startswith("FROM ") and not replaced:
        out.append(f"FROM {target_from}")
        replaced = True
    else:
        out.append(line)

if not replaced:
    raise SystemExit("No FROM line found in base Modelfile output")

sys.stdout.write("\n".join(out) + "\n")
' "$GENERATED_GGUF_LINK" "$base_modelfile"
  )" || die "Failed to rewrite base Modelfile for ${source_gguf}."

  cat >"$GENERATED_MODELFILE" <<EOF
# Generated automatically by ${SCRIPTS_DIR}/03-update-model.sh
# Source GGUF: ${source_gguf}
# Stable symlink: ${GENERATED_GGUF_LINK}
# Base Ollama template model: ${OLLAMA_TEMPLATE_BASE_MODEL}
${rewritten_modelfile}
EOF

  printf '%s\n' "$source_gguf" >"$CURRENT_GGUF_FILE"
  cp "$GENERATED_MODELFILE" "$CURRENT_MODELFILE_FILE"
}

start_ollama() {
  local mode
  mode="$(read_service_mode "$OLLAMA_SERVICE_MODE_FILE" "$(have_systemd && echo systemd-user || echo manual)")"

  if [[ "$mode" == "systemd" ]]; then
    run sudo systemctl enable --now ollama
    run sudo systemctl restart ollama
  elif [[ "$mode" == "systemd-user" ]]; then
    run systemctl --user daemon-reload
    run systemctl --user enable --now "$OLLAMA_USER_SERVICE_NAME"
    run systemctl --user restart "$OLLAMA_USER_SERVICE_NAME"
  else
    start_background_process "Ollama" "$SCRIPTS_DIR/10-run-ollama-serve.sh" "$OLLAMA_PID_FILE" "$OLLAMA_LOG_FILE"
  fi

  wait_for_ollama
}

stop_ollama() {
  local mode
  mode="$(read_service_mode "$OLLAMA_SERVICE_MODE_FILE" "$(have_systemd && echo systemd-user || echo manual)")"

  if [[ "$mode" == "systemd" ]]; then
    run sudo systemctl stop ollama || true
  elif [[ "$mode" == "systemd-user" ]]; then
    run systemctl --user stop "$OLLAMA_USER_SERVICE_NAME" || true
  else
    stop_background_process "Ollama" "$OLLAMA_PID_FILE"
  fi
}

restart_ollama() {
  stop_ollama
  start_ollama
}

start_openclaw_gateway() {
  local mode
  mode="$(read_service_mode "$OPENCLAW_SERVICE_MODE_FILE" "$(have_systemd && echo systemd || echo manual)")"

  if [[ "$mode" == "systemd" ]]; then
    run systemctl --user daemon-reload
    run systemctl --user enable --now "$OPENCLAW_SYSTEMD_SERVICE_NAME"
    run systemctl --user restart "$OPENCLAW_SYSTEMD_SERVICE_NAME"
  else
    start_background_process "OpenClaw Gateway" "$SCRIPTS_DIR/11-run-openclaw-gateway.sh" "$OPENCLAW_PID_FILE" "$OPENCLAW_LOG_FILE"
  fi

  wait_for_openclaw_ui
}

stop_openclaw_gateway() {
  local mode
  mode="$(read_service_mode "$OPENCLAW_SERVICE_MODE_FILE" "$(have_systemd && echo systemd || echo manual)")"

  if [[ "$mode" == "systemd" ]]; then
    run systemctl --user stop "$OPENCLAW_SYSTEMD_SERVICE_NAME" || true
  else
    stop_background_process "OpenClaw Gateway" "$OPENCLAW_PID_FILE"
  fi
}

restart_openclaw_gateway() {
  local mode
  mode="$(read_service_mode "$OPENCLAW_SERVICE_MODE_FILE" "$(have_systemd && echo systemd || echo manual)")"

  if [[ "$mode" == "systemd" ]]; then
    run systemctl --user restart "$OPENCLAW_SYSTEMD_SERVICE_NAME"
  else
    stop_openclaw_gateway
    start_openclaw_gateway
  fi

  wait_for_openclaw_ui
}

ensure_ollama_cli() {
  export PATH="$LOCAL_BIN_DIR:$PATH"
  command -v ollama >/dev/null 2>&1 || die "Ollama is not installed. Run scripts/01-install-ollama.sh first."
}

ensure_openclaw_cli() {
  command -v openclaw >/dev/null 2>&1 || die "OpenClaw is not installed. Run scripts/02-install-openclaw.sh first."
}

ollama_model_exists() {
  ollama list | awk 'NR > 1 { print $1 }' | grep -Fx "$OLLAMA_MODEL_TAG" >/dev/null 2>&1
}

verify_ollama_inference() {
  local payload
  local raw_response
  local text_response

  payload="$(
    python3 - <<PY
import json
print(json.dumps({
    "model": "${OLLAMA_MODEL_TAG}",
    "prompt": "${TEST_PROMPT}",
    "stream": False,
    "options": {"num_predict": 32}
}))
PY
  )"

  raw_response="$(curl -fsS "$OLLAMA_BASE_URL/api/generate" -H 'Content-Type: application/json' -d "$payload")" || die "Ollama API inference failed for ${OLLAMA_MODEL_TAG}."

  text_response="$(
    python3 -c 'import json,sys; data=json.loads(sys.argv[1]); print((data.get("response") or "").strip())' "$raw_response"
  )"

  [[ -n "$text_response" ]] || die "Ollama inference returned empty output for ${OLLAMA_MODEL_TAG}."
  log "Ollama inference output: ${text_response}"
}

verify_ollama_tool_support() {
  local payload
  local raw_response

  payload="$(
    python3 - <<PY
import json
print(json.dumps({
    "model": "${OLLAMA_MODEL_TAG}",
    "messages": [{"role": "user", "content": "Reply with exactly: TOOL_SUPPORT_OK"}],
    "stream": False,
    "tools": [{
        "type": "function",
        "function": {
            "name": "noop",
            "description": "No-op tool for capability verification.",
            "parameters": {
                "type": "object",
                "properties": {},
                "required": []
            }
        }
    }]
}))
PY
  )"

  raw_response="$(curl -fsS "$OLLAMA_BASE_URL/api/chat" -H 'Content-Type: application/json' -d "$payload")" || die "Ollama /api/chat tool-capability check failed for ${OLLAMA_MODEL_TAG}."

  python3 - "$raw_response" <<'PY'
import json
import sys

data = json.loads(sys.argv[1])
message = data.get("message") or {}
content = (message.get("content") or "").strip()
tool_calls = message.get("tool_calls") or []

if not content and not tool_calls:
    raise SystemExit("Tool-capability check returned neither text nor tool_calls")
PY

  log "Ollama tool-capability check passed for ${OLLAMA_MODEL_TAG}."
}

strip_surrounding_quotes() {
  local value="$1"
  value="${value#\"}"
  value="${value%\"}"
  printf '%s\n' "$value"
}

verify_openclaw_model_target() {
  [[ -f "$OPENCLAW_CONFIG_FILE" ]] || die "OpenClaw config file is missing: ${OPENCLAW_CONFIG_FILE}"

  local configured_model
  configured_model="$(
    python3 - <<PY
import json
from pathlib import Path

config_path = Path(r"${OPENCLAW_CONFIG_FILE}")
data = json.loads(config_path.read_text())
value = data.get("agents", {}).get("defaults", {}).get("model", {}).get("primary", "")
print(value)
PY
  )"

  [[ "$configured_model" == "$OPENCLAW_MODEL_REF" ]] || die "OpenClaw default model is '${configured_model}', expected '${OPENCLAW_MODEL_REF}'."
}

verify_openclaw_gateway() {
  local mode
  mode="$(read_service_mode "$OPENCLAW_SERVICE_MODE_FILE" "$(have_systemd && echo systemd || echo manual)")"

  if [[ "$mode" == "systemd" ]]; then
    systemctl --user is-active --quiet "$OPENCLAW_SYSTEMD_SERVICE_NAME" || die "OpenClaw systemd user service is not active: ${OPENCLAW_SYSTEMD_SERVICE_NAME}"
  elif [[ "$mode" == "manual" ]]; then
    is_pid_running "$OPENCLAW_PID_FILE" || die "OpenClaw manual gateway runner is not active."
  fi

  wait_for_openclaw_ui

  local canvas_attempt
  for ((canvas_attempt = 1; canvas_attempt <= 10; canvas_attempt++)); do
    if curl --max-time 2 -fsS "${OPENCLAW_UI_URL}__openclaw__/canvas/" >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done

  warn "OpenClaw gateway is running, but the canvas host did not respond quickly at ${OPENCLAW_UI_URL}__openclaw__/canvas/."
}

verify_openclaw_agent_smoke() {
  ensure_openclaw_cli

  local raw_output
  local json_payload
  local response_text

  raw_output="$(
    openclaw agent --json --timeout 120 --thinking off --to "$OPENCLAW_AGENT_SMOKE_TO" -m "$OPENCLAW_AGENT_SMOKE_PROMPT" 2>&1
  )" || die "OpenClaw agent smoke test failed to run. Output: ${raw_output}"

  if grep -Fq "Gateway agent failed; falling back to embedded" <<<"$raw_output"; then
    die "OpenClaw agent smoke test fell back away from the gateway. Output: ${raw_output}"
  fi

  json_payload="$(
    printf '%s\n' "$raw_output" | python3 -c '
import json
import sys

text = sys.stdin.read()
start = text.find("{")
if start < 0:
    raise SystemExit("No JSON payload found in OpenClaw agent output")

payload = json.loads(text[start:])
print(json.dumps(payload))
'
  )" || die "OpenClaw agent smoke test did not return parseable JSON. Output: ${raw_output}"

  response_text="$(
    python3 -c '
import json
import sys

payload = json.loads(sys.argv[1])
items = payload.get("payloads")
if items is None:
    items = payload.get("result", {}).get("payloads", [])

texts = [(item.get("text") or "").strip() for item in items if isinstance(item, dict)]
texts = [text for text in texts if text]
print(texts[0] if texts else "")
' "$json_payload"
  )"

  [[ "$response_text" == "$OPENCLAW_AGENT_SMOKE_EXPECT" ]] || die "OpenClaw agent smoke test returned '${response_text}', expected '${OPENCLAW_AGENT_SMOKE_EXPECT}'. Full output: ${raw_output}"
  log "OpenClaw agent smoke output: ${response_text}"
}

print_debug_paths() {
  cat <<EOF
Base directory:           ${BASE_DIR}
GGUF search directory:    ${GGUF_SEARCH_DIR}
Generated Modelfile:      ${GENERATED_MODELFILE}
Current GGUF marker:      ${CURRENT_GGUF_FILE}
Ollama base URL:          ${OLLAMA_BASE_URL}
OpenClaw model ref:       ${OPENCLAW_MODEL_REF}
OpenClaw UI URL:          ${OPENCLAW_UI_URL}
Ollama log:               ${OLLAMA_LOG_FILE}
OpenClaw log:             ${OPENCLAW_LOG_FILE}
OpenClaw config:          ${OPENCLAW_CONFIG_FILE}
EOF
}
