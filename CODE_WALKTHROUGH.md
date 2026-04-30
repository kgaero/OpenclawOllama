# OpenClawOllama Code Walkthrough

## 1. Project Purpose

This project is a WSL2-native automation pipeline for running a locally fine-tuned Qwen model through Ollama and exposing it to OpenClaw.

At a high level, the repository does four things:

1. Installs or starts Ollama inside Ubuntu on WSL2.
2. Detects the newest local `.gguf` model file.
3. Imports that GGUF into Ollama under a stable tag: `qwen-local:latest`.
4. Installs and configures OpenClaw to use `ollama/qwen-local:latest`.

The stable model tag is the main design decision. OpenClaw does not need to know the changing GGUF filename after each fine-tune. It always points to the same logical model reference.

## 2. Repository Structure

```text
OpenclawOllama/
|-- README.md
|-- CODE_WALKTHROUGH.md
|-- sft-qwen2-5-3b-instruct.ipynb
|-- qwen2.5-3b-instruct.Q4_K_M.gguf
|-- generated/
|   |-- Modelfile
|   `-- current-model.gguf
|-- logs/
|-- run/
|-- state/
|-- workspace/
`-- scripts/
    |-- 00-env.sh
    |-- 01-install-ollama.sh
    |-- 02-install-openclaw.sh
    |-- 03-update-model.sh
    |-- 04-verify.sh
    |-- 05-reset-openclaw.sh
    |-- 06-uninstall-all.sh
    |-- 10-run-ollama-serve.sh
    |-- 11-run-openclaw-gateway.sh
    `-- lib/
        `-- common.sh
```

## 3. Main Runtime Flow

The normal model update path is:

```text
New GGUF copied into repo root
        ↓
scripts/03-update-model.sh
        ↓
detect_latest_gguf
        ↓
generated/current-model.gguf symlink updated
        ↓
generated/Modelfile regenerated
        ↓
ollama create qwen-local:latest
        ↓
Ollama inference and tool support verified
        ↓
OpenClaw model target refreshed
        ↓
OpenClaw gateway verified
```

The first-time install path is:

```text
scripts/01-install-ollama.sh
        ↓
Ollama installed or refreshed
        ↓
Ollama service started
        ↓
scripts/02-install-openclaw.sh
        ↓
Latest GGUF imported into Ollama
        ↓
OpenClaw installed and onboarded
        ↓
Gateway started
        ↓
scripts/04-verify.sh
```

## 4. Shared Configuration: `scripts/00-env.sh`

`00-env.sh` centralizes all important values used by the pipeline.

Key settings:

```bash
BASE_DIR="/home/kgaer/code/OpenclawOllama"
GGUF_SEARCH_DIR="$BASE_DIR"
OLLAMA_MODEL_TAG="qwen-local:latest"
OLLAMA_TEMPLATE_BASE_MODEL="qwen2.5:3b"
OLLAMA_BIND_HOST="127.0.0.1"
OLLAMA_PORT="11434"
OPENCLAW_PORT="18789"
OPENCLAW_WORKSPACE="$BASE_DIR/workspace"
```

Important generated paths:

```bash
GENERATED_MODELFILE="$GENERATED_DIR/Modelfile"
GENERATED_GGUF_LINK="$GENERATED_DIR/current-model.gguf"
CURRENT_GGUF_FILE="$STATE_DIR/current.gguf"
CURRENT_MODELFILE_FILE="$STATE_DIR/current-modelfile.txt"
```

The script exports every variable so sourced scripts and child processes can use them consistently.

Critical design point:

```bash
OPENCLAW_MODEL_REF="ollama/${OLLAMA_MODEL_TAG}"
```

Ollama sees the model as `qwen-local:latest`, while OpenClaw refers to it as `ollama/qwen-local:latest`.

## 5. Shared Library: `scripts/lib/common.sh`

`common.sh` contains reusable functions for logging, error handling, service management, model generation, and verification.

### Logging and Errors

```bash
timestamp_utc() {
  date -u +"%Y-%m-%dT%H:%M:%SZ"
}

log() {
  printf '[%s] %s\n' "$(timestamp_utc)" "$*"
}
```

Logs use UTC timestamps, which makes troubleshooting easier across local machines and CI-like environments.

```bash
on_error() {
  local exit_code="$1"
  local line_no="$2"
  local command_text="$3"
  error "Command failed at line ${line_no}: ${command_text}"
  print_debug_paths >&2 || true
  exit "$exit_code"
}
```

Every main script installs this function as an `ERR` trap. When a command fails, the user gets the exact failing line and useful debug paths.

### Directory Setup

```bash
ensure_dirs() {
  mkdir -p "$LOG_DIR" "$RUN_DIR" "$STATE_DIR" "$GENERATED_DIR" "$OPENCLAW_WORKSPACE"
  chmod 700 "$RUN_DIR" "$STATE_DIR"
}
```

The runtime and state directories are created on demand. `run` and `state` are private because they contain PID files and gateway tokens.

### Environment Loading

```bash
load_nvm_if_present() {
  export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

  if [[ -s "$NVM_DIR/nvm.sh" ]]; then
    source "$NVM_DIR/nvm.sh"
  fi
}
```

This allows scripts to find user-local binaries and Node.js installed through `nvm`.

### Service Mode Detection

The pipeline supports three service styles:

1. System service with `sudo systemctl`.
2. User service with `systemctl --user`.
3. Manual background process with PID files.

```bash
have_passwordless_sudo() {
  command -v sudo >/dev/null 2>&1 && sudo -n true >/dev/null 2>&1
}

have_systemd() {
  [[ -d /run/systemd/system ]] && command -v systemctl >/dev/null 2>&1
}
```

This matters because WSL2 distributions may or may not have systemd enabled.

### Manual Background Process Management

```bash
start_background_process() {
  local name="$1"
  local script_path="$2"
  local pid_file="$3"
  local log_file="$4"

  if is_pid_running "$pid_file"; then
    log "${name} already running with PID $(<"$pid_file")."
    return 0
  fi

  nohup "$script_path" >>"$log_file" 2>&1 &
  echo "$!" >"$pid_file"
  sleep 1

  if ! is_pid_running "$pid_file"; then
    die "${name} did not stay running. Check ${log_file}."
  fi
}
```

If systemd is not available, the project still works by launching Ollama or OpenClaw through small runner scripts.

### GGUF Detection

```bash
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
```

This picks the newest `.gguf` file by modification time. Null-delimited sorting helps with filenames that contain spaces.

One tradeoff: modification time is not the same as model version. Accidentally copying an older GGUF later would make it the selected model.

### Modelfile Generation

```bash
write_generated_modelfile() {
  local source_gguf="$1"
  ln -sfn "$source_gguf" "$GENERATED_GGUF_LINK"

  base_modelfile="$(ollama show --modelfile "$OLLAMA_TEMPLATE_BASE_MODEL")"
  ...
}
```

The script reads the official Ollama Modelfile for `qwen2.5:3b`, replaces only the first `FROM` line, and writes the result to `generated/Modelfile`.

This is important because it preserves:

- Qwen chat template
- Tool-call formatting
- System prompt
- Model parameters
- License text

Only the model weight source changes.

### Ollama Verification

`verify_ollama_inference` sends a basic `/api/generate` request and checks that the model returns non-empty text.

`verify_ollama_tool_support` sends a `/api/chat` request with a dummy function tool and checks that the response contains either text content or tool calls.

The second check is important because OpenClaw depends on chat and tool-compatible behavior, not only raw generation.

### OpenClaw Verification

`verify_openclaw_model_target` reads `~/.openclaw/openclaw.json` and confirms:

```text
agents.defaults.model.primary == ollama/qwen-local:latest
```

`verify_openclaw_gateway` confirms that the gateway service or manual PID is active and that the UI and canvas host are reachable.

`verify_openclaw_agent_smoke` runs an actual OpenClaw agent request and checks that it goes through the gateway instead of silently falling back to embedded mode.

## 6. Ollama Installation: `scripts/01-install-ollama.sh`

This script installs or refreshes Ollama.

Startup sequence:

```bash
load_nvm_if_present
ensure_dirs
require_cmd curl
require_cmd python3
```

If passwordless sudo is available:

```bash
curl -fsSL https://ollama.com/install.sh | sh
record_service_mode "$OLLAMA_SERVICE_MODE_FILE" "systemd"
```

If sudo is unavailable, the script installs Ollama locally:

```bash
LOCAL_OLLAMA_INSTALL_DIR="$HOME/.local/share/ollama-app"
LOCAL_BIN_DIR="$HOME/.local/bin"
```

It downloads the Linux archive, extracts it with Python and `zstandard`, creates a symlink to the binary, and writes a user systemd service.

After installation:

```bash
ensure_ollama_cli
ollama --version
start_ollama
```

The script finishes only after Ollama responds on:

```text
http://127.0.0.1:11434/api/tags
```

## 7. OpenClaw Installation: `scripts/02-install-openclaw.sh`

This script installs OpenClaw and configures it against local Ollama.

First it ensures Ollama is available:

```bash
ensure_ollama_cli
start_ollama
```

Then it installs OpenClaw:

- If OpenClaw already exists, it refreshes with `npm install -g openclaw@latest`.
- If Node.js 22+ exists, it installs with npm.
- Otherwise it uses the official OpenClaw installer.

Before onboarding OpenClaw, it imports the model:

```bash
scripts/03-update-model.sh --ollama-only --skip-verify
```

This ensures the model exists before OpenClaw scans or selects it.

OpenClaw onboarding is non-interactive:

```bash
openclaw onboard \
  --non-interactive \
  --mode local \
  --workspace "$OPENCLAW_WORKSPACE" \
  --auth-choice ollama \
  --custom-base-url "$OLLAMA_BASE_URL" \
  --custom-model-id "$OLLAMA_MODEL_TAG" \
  --gateway-port "$OPENCLAW_PORT" \
  --gateway-bind "$OPENCLAW_BIND_MODE" \
  --gateway-auth token \
  --gateway-token "$gateway_token"
```

After onboarding, it explicitly sets:

```bash
openclaw models set "$OPENCLAW_MODEL_REF"
```

Then it starts and verifies the gateway.

## 8. Model Update: `scripts/03-update-model.sh`

This is the most important operational script.

It supports two flags:

```text
--ollama-only    Import model into Ollama but skip OpenClaw refresh
--skip-verify    Skip final full verification
```

Main sequence:

```bash
ensure_ollama_cli
start_ollama
ensure_ollama_base_template_model
latest_gguf="$(detect_latest_gguf)"
write_generated_modelfile "$latest_gguf"
ollama create "$OLLAMA_MODEL_TAG" -f "$GENERATED_MODELFILE"
verify_ollama_inference
verify_ollama_tool_support
```

If OpenClaw is already installed and configured, it also refreshes the OpenClaw model target:

```bash
openclaw models scan
openclaw models set "$OPENCLAW_MODEL_REF"
restart_openclaw_gateway
verify_openclaw_model_target
verify_openclaw_gateway
```

This lets repeated GGUF refreshes happen without manual OpenClaw configuration.

## 9. Verification: `scripts/04-verify.sh`

This script validates the whole runtime state.

Checks performed:

1. Finds the newest GGUF in the repo root.
2. Reads the active model marker from `state/current.gguf`.
3. Fails if the newest GGUF is not the active one.
4. Confirms Ollama is responding.
5. Confirms `qwen-local:latest` exists.
6. Tests Ollama text inference.
7. Tests Ollama chat/tool capability.
8. If OpenClaw is configured, verifies OpenClaw model target.
9. Verifies OpenClaw gateway.
10. Runs an end-to-end OpenClaw agent smoke test.

The strongest check is the agent smoke test because it validates the integration path, not just individual services.

## 10. Reset and Uninstall Scripts

### `scripts/05-reset-openclaw.sh`

This removes OpenClaw local service/config/workspace state while preserving Ollama and GGUF files.

Use this when OpenClaw config is broken but the local model should remain intact.

### `scripts/06-uninstall-all.sh`

This attempts to remove everything the pipeline manages:

- OpenClaw services and state
- OpenClaw global npm package
- Ollama service files
- user-local Ollama install
- generated files
- logs
- runtime PID files
- state files
- OpenClaw workspace

It is intentionally best-effort. Many operations are guarded with `|| true` because uninstall paths vary by environment.

## 11. Manual Runner Scripts

### `scripts/10-run-ollama-serve.sh`

Runs:

```bash
OLLAMA_HOST="${OLLAMA_BIND_HOST}:${OLLAMA_PORT}"
exec ollama serve
```

This is used when systemd is not available.

### `scripts/11-run-openclaw-gateway.sh`

Runs:

```bash
openclaw gateway run \
  --port "$OPENCLAW_PORT" \
  --bind "$OPENCLAW_BIND_MODE" \
  --auth token \
  --token "$gateway_token"
```

This is the manual fallback for the OpenClaw gateway.

## 12. Fine-Tuning Notebook

The notebook `sft-qwen2-5-3b-instruct.ipynb` is the training side of the workflow.

Main steps:

1. Installs Unsloth and related dependencies.
2. Loads `unsloth/Qwen2.5-3B-Instruct`.
3. Enables 4-bit loading for memory-efficient fine-tuning.
4. Adds LoRA adapters with rank `r = 16`.
5. Loads `ServiceNow-AI/R1-Distill-SFT`.
6. Formats rows using the `qwen-2.5` chat template.
7. Trains with `trl.SFTTrainer`.
8. Saves or pushes a GGUF model using Q4_K_M quantization.
9. Tests the exported model through Ollama.

Important training configuration:

```python
max_seq_length = 2048
load_in_4bit = True
r = 16
lora_alpha = 16
lora_dropout = 0
per_device_train_batch_size = 2
gradient_accumulation_steps = 4
max_steps = 60
learning_rate = 2e-4
optim = "adamw_8bit"
```

The notebook produces the GGUF artifact consumed by the Bash pipeline.

## 13. Generated Modelfile

`generated/Modelfile` is produced by `scripts/03-update-model.sh`.

Its first meaningful line is:

```text
FROM /home/kgaer/code/OpenclawOllama/generated/current-model.gguf
```

The rest is copied from the official `qwen2.5:3b` Ollama template.

This is the bridge between:

- fine-tuned GGUF weights
- official Qwen prompt formatting
- Ollama model registration
- OpenClaw agent compatibility

## 14. Strengths of the Implementation

- Centralized configuration.
- Clear separation between install, update, verify, reset, and uninstall scripts.
- Works with and without systemd.
- Uses a stable Ollama tag to simplify OpenClaw integration.
- Preserves the official Qwen Ollama template.
- Verifies both direct inference and tool-capable chat.
- Includes an end-to-end OpenClaw gateway smoke test.
- Handles user-local installation when sudo is unavailable.

## 15. Risks and Improvement Areas

### Remote install scripts

The project uses:

```bash
curl -fsSL https://ollama.com/install.sh | sh
curl -fsSL https://openclaw.ai/install.sh | bash
```

This is convenient but risky. A production-grade version should pin versions and verify checksums or signatures.

### Floating package versions

```bash
npm install -g openclaw@latest
```

This may change behavior over time. Pinning a known working OpenClaw version would make the pipeline more reproducible.

### Exact inference validation

`verify_ollama_inference` currently checks for non-empty output. It could be stricter by checking the exact expected text.

### Modification-time model selection

The newest `.gguf` is selected by filesystem modification time. This is simple, but a manifest file or versioned naming convention would be safer.

### Plaintext token argument

The OpenClaw gateway token is passed as a CLI argument. That can be visible in process listings. Environment variables or config-file based secret passing would reduce exposure.

### Hard-coded base path

`BASE_DIR` is hard-coded to `/home/kgaer/code/OpenclawOllama`. Making it relative to the script location would improve portability.

## 16. How to Explain This Project in an Interview

This project is best described as a local LLM deployment and agent integration pipeline.

Strong summary:

> I built a WSL2 automation pipeline that takes a locally fine-tuned Qwen GGUF model, imports it into Ollama under a stable tag, configures OpenClaw to use that local Ollama model, and verifies the full path from raw Ollama inference through OpenClaw gateway agent execution. The key design choice was preserving the official Qwen Ollama template while only swapping the GGUF source, so tool-compatible chat behavior remains intact after each fine-tune refresh.

Key technical themes to emphasize:

- Bash automation and defensive scripting.
- WSL2 service management.
- Ollama model import and Modelfile generation.
- GGUF deployment workflow.
- OpenClaw local agent configuration.
- Verification beyond basic health checks.
- QLoRA fine-tuning and quantized local inference.
