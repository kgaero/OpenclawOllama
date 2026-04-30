#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

load_nvm_if_present
ensure_dirs

cleanup_openclaw_prompt_state() {
  local stamp
  local backup_dir
  local sessions_dir

  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  backup_dir="$BASE_DIR/openclaw-startup-backup/$stamp"
  sessions_dir="$OPENCLAW_STATE_HOME/agents/main/sessions"

  mkdir -p "$backup_dir/sessions" "$backup_dir/workspace-md"

  log "Stopping any active OpenClaw agent CLI turns."
  pkill -f "openclaw agent" >/dev/null 2>&1 || true

  if [[ -d "$sessions_dir" ]]; then
    log "Archiving OpenClaw session/debug state to ${backup_dir}/sessions."
    find "$sessions_dir" -maxdepth 1 -type f \
      \( -name '*.trajectory.jsonl' \
        -o -name '*.trajectory-path.json' \
        -o -name '*.jsonl.reset.*' \
        -o -name '*.jsonl.deleted.*' \
        -o -name '*.lock' \) \
      -exec mv -t "$backup_dir/sessions" {} + 2>/dev/null || true
  fi

  log "Keeping workspace prompt files minimal for local model speed."

  for file_name in AGENTS.md SOUL.md TOOLS.md IDENTITY.md USER.md HEARTBEAT.md; do
    if [[ -f "$OPENCLAW_WORKSPACE/$file_name" ]]; then
      cp "$OPENCLAW_WORKSPACE/$file_name" "$backup_dir/workspace-md/$file_name"
    fi
  done

  cat >"$OPENCLAW_WORKSPACE/AGENTS.md" <<'EOF'
# AGENTS.md
Use concise plain-text answers. Do not call tools unless explicitly asked.
EOF

  cat >"$OPENCLAW_WORKSPACE/SOUL.md" <<'EOF'
# SOUL.md
Concise local assistant.
EOF

  cat >"$OPENCLAW_WORKSPACE/TOOLS.md" <<'EOF'
# TOOLS.md
No local tool notes.
EOF

  cat >"$OPENCLAW_WORKSPACE/IDENTITY.md" <<'EOF'
# IDENTITY.md
Assistant.
EOF

  cat >"$OPENCLAW_WORKSPACE/USER.md" <<'EOF'
# USER.md
Local user.
EOF

  cat >"$OPENCLAW_WORKSPACE/HEARTBEAT.md" <<'EOF'
# HEARTBEAT.md
Disabled.
EOF

  log "Cleanup backup directory: ${backup_dir}"
}

openclaw_config_value_matches() {
  local json_path="$1"
  local expected_json="$2"

  python3 - "$OPENCLAW_CONFIG_FILE" "$json_path" "$expected_json" <<'PY'
import json
import sys
from pathlib import Path

config_path = Path(sys.argv[1])
path = sys.argv[2].split(".")
expected = json.loads(sys.argv[3])

if not config_path.exists():
    raise SystemExit(1)

data = json.loads(config_path.read_text())
value = data
for key in path:
    if not isinstance(value, dict) or key not in value:
        raise SystemExit(1)
    value = value[key]

raise SystemExit(0 if value == expected else 1)
PY
}

ensure_openclaw_fast_local_config() {
  local changed=0

  if ! openclaw_config_value_matches "agents.defaults.model.primary" "\"$OPENCLAW_MODEL_REF\""; then
    log "Ensuring OpenClaw uses ${OPENCLAW_MODEL_REF}."
    run openclaw models scan >/dev/null 2>&1 || true
    run openclaw models set "$OPENCLAW_MODEL_REF"
    changed=1
  else
    log "OpenClaw already uses ${OPENCLAW_MODEL_REF}."
  fi

  if ! openclaw_config_value_matches "agents.defaults.experimental.localModelLean" "true"; then
    run openclaw config set agents.defaults.experimental.localModelLean true
    changed=1
  else
    log "OpenClaw local-model lean mode is already enabled."
  fi

  if ! openclaw_config_value_matches "agents.defaults.skills" "[]"; then
    run openclaw config set agents.defaults.skills '[]' --strict-json || true
    changed=1
  else
    log "OpenClaw default skills are already disabled for this local model."
  fi

  return "$changed"
}

warm_ollama_model() {
  local payload

  payload="$(
    python3 - <<PY
import json
print(json.dumps({
    "model": "${OLLAMA_MODEL_TAG}",
    "prompt": "Reply exactly: OK",
    "stream": False,
    "keep_alive": "30m",
    "options": {"num_predict": 4}
}))
PY
  )"

  log "Warm-loading Ollama model ${OLLAMA_MODEL_TAG}."
  curl --max-time 60 -fsS "$OLLAMA_BASE_URL/api/generate" \
    -H 'Content-Type: application/json' \
    -d "$payload" >/dev/null || warn "Ollama warm-load did not complete quickly; continuing startup."
}

if [[ "${OPENCLAW_SKIP_STARTUP_CLEANUP:-0}" != "1" ]]; then
  cleanup_openclaw_prompt_state
fi

if ! command -v ollama >/dev/null 2>&1; then
  log "Ollama is not installed; running the Ollama installer."
  run "$SCRIPT_DIR/01-install-ollama.sh"
else
  ensure_ollama_cli
  start_ollama
fi

if ! command -v openclaw >/dev/null 2>&1 || [[ ! -f "$OPENCLAW_CONFIG_FILE" ]]; then
  log "OpenClaw is not fully configured; running the OpenClaw installer/onboarding script."
  run "$SCRIPT_DIR/02-install-openclaw.sh"
else
  ensure_openclaw_cli

  if ! ollama_model_exists || [[ ! -f "$CURRENT_GGUF_FILE" ]]; then
    log "Stable Ollama model is missing; importing the latest GGUF."
    run "$SCRIPT_DIR/03-update-model.sh" --ollama-only --skip-verify
  fi

  ensure_openclaw_fast_local_config || true
  warm_ollama_model

  log "Starting OpenClaw gateway."
  start_openclaw_gateway
  verify_openclaw_model_target
  verify_openclaw_gateway
fi

log "OpenClaw is ready."
printf '%s\n' "$OPENCLAW_UI_URL"
