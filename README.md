# OpenClawOllama

WSL2-native automation for running a local fine-tuned Qwen GGUF model with Ollama and exposing it through OpenClaw.

The pipeline keeps OpenClaw pointed at one stable model reference:

```text
ollama/qwen-local:latest
```

You can drop a newer `.gguf` file into the project root, rebuild the stable Ollama model tag, and keep the OpenClaw gateway using the updated local model without manually editing OpenClaw config.

## Status

This repository is a local workstation pipeline for Ubuntu on WSL2. Paths in the scripts currently target:

```text
/home/kgaer/code/OpenclawOllama
```

If you move the project, update `BASE_DIR` in `scripts/00-env.sh` before running the scripts.

## What This Project Does

- Installs or starts Ollama inside Ubuntu on WSL2.
- Detects the newest `.gguf` model file in the repository root.
- Rebuilds the stable Ollama model tag `qwen-local:latest`.
- Preserves the official `qwen2.5:3b` Ollama Modelfile template while swapping in the local GGUF.
- Installs and configures OpenClaw for local Ollama.
- Starts the OpenClaw gateway on `http://127.0.0.1:18789/`.
- Verifies Ollama inference, Ollama chat/tool support, OpenClaw model config, gateway health, and an end-to-end OpenClaw agent smoke test.
- Provides a Windows PowerShell launcher that starts the WSL2 services and opens the OpenClaw chat URL.

## Repository Layout

```text
OpenclawOllama/
|-- README.md
|-- CODE_WALKTHROUGH.md
|-- Start-OpenClaw.ps1
|-- Pipeline.png
|-- FineTuningPipeLineOpenClaw.pptx
|-- QnA.docx
|-- sft-qwen2-5-3b-instruct.ipynb
|-- scripts/
|   |-- 00-env.sh
|   |-- 01-install-ollama.sh
|   |-- 02-install-openclaw.sh
|   |-- 03-update-model.sh
|   |-- 04-verify.sh
|   |-- 05-reset-openclaw.sh
|   |-- 06-uninstall-all.sh
|   |-- 10-run-ollama-serve.sh
|   |-- 11-run-openclaw-gateway.sh
|   |-- 12-start-openclaw.sh
|   `-- lib/
|       `-- common.sh
|-- generated/
|-- logs/
|-- run/
|-- state/
|-- workspace/
|-- openclaw-speed-backup/
`-- openclaw-startup-backup/
```

Important notes:

- `generated/`, `logs/`, `run/`, `state/`, and `workspace/` are runtime directories.
- `.gguf` files are intentionally ignored by Git because they are large local model artifacts.
- `openclaw-*-backup/` directories contain archived OpenClaw session/workspace state created by startup cleanup scripts.

## Requirements

- Windows with WSL2 and an Ubuntu distro.
- Bash, `curl`, `python3`, and standard Linux utilities in Ubuntu.
- A local Qwen-compatible `.gguf` model in the repository root.
- Optional but recommended: WSL systemd support.
- Optional: passwordless `sudo` for system-wide Ollama installation.
- Optional: Node.js 22+ and npm. If Node.js 22+ is unavailable, the OpenClaw installer path is used.

The checked-in fine-tuning notebook targets `unsloth/Qwen2.5-3B-Instruct`, trains with LoRA, and exports a Q4_K_M GGUF artifact for this runtime pipeline.

## Quick Start

From Windows PowerShell:

```powershell
cd \\wsl.localhost\Ubuntu\home\kgaer\code\OpenclawOllama
.\Start-OpenClaw.ps1
```

The launcher runs this command inside Ubuntu:

```bash
cd /home/kgaer/code/OpenclawOllama
chmod +x scripts/*.sh scripts/lib/*.sh
./scripts/12-start-openclaw.sh
```

Then it opens:

```text
http://127.0.0.1:18789/chat?session=agent%3Amain%3Amain
```

To skip startup cleanup of OpenClaw prompt/session state:

```powershell
.\Start-OpenClaw.ps1 -SkipCleanup
```

## Manual First-Time Setup

Run these commands inside Ubuntu:

```bash
cd /home/kgaer/code/OpenclawOllama
chmod +x scripts/*.sh scripts/lib/*.sh
```

Install or refresh Ollama:

```bash
./scripts/01-install-ollama.sh
```

Install or refresh OpenClaw, import the newest GGUF, configure the local model, and start the gateway:

```bash
./scripts/02-install-openclaw.sh
```

Verify the complete setup:

```bash
./scripts/04-verify.sh
```

## Normal Model Update

Copy the newest fine-tuned `.gguf` file into:

```text
/home/kgaer/code/OpenclawOllama
```

Then run:

```bash
./scripts/03-update-model.sh
```

The update script:

- Selects the newest `.gguf` by modification time.
- Updates `generated/current-model.gguf`.
- Regenerates `generated/Modelfile` from the `qwen2.5:3b` Ollama template.
- Recreates `qwen-local:latest`.
- Verifies direct Ollama inference and tool-capable chat.
- Refreshes OpenClaw to use `ollama/qwen-local:latest` when OpenClaw is configured.
- Restarts and verifies the gateway.

Useful flags:

```bash
./scripts/03-update-model.sh --ollama-only
./scripts/03-update-model.sh --skip-verify
./scripts/03-update-model.sh --ollama-only --skip-verify
```

## Startup Script Behavior

`scripts/12-start-openclaw.sh` is the main convenience entrypoint. It:

- Archives noisy OpenClaw session/debug files into `openclaw-startup-backup/`.
- Rewrites workspace prompt files to a minimal local-assistant profile unless `OPENCLAW_SKIP_STARTUP_CLEANUP=1` is set.
- Installs Ollama if missing.
- Starts Ollama.
- Installs and onboards OpenClaw if missing or not configured.
- Imports the latest GGUF if the stable Ollama model is missing.
- Ensures OpenClaw uses `ollama/qwen-local:latest`.
- Enables OpenClaw local-model lean mode.
- Disables default OpenClaw skills for faster local-model startup.
- Warm-loads the Ollama model for 30 minutes.
- Starts and verifies the OpenClaw gateway.

Run it directly from Ubuntu:

```bash
./scripts/12-start-openclaw.sh
```

Skip cleanup:

```bash
OPENCLAW_SKIP_STARTUP_CLEANUP=1 ./scripts/12-start-openclaw.sh
```

## Script Reference

| Script | Purpose |
| --- | --- |
| `scripts/00-env.sh` | Shared paths, ports, model tags, test prompts, and generated file locations. |
| `scripts/01-install-ollama.sh` | Installs or refreshes Ollama, then starts it through systemd, user systemd, or a manual background runner. |
| `scripts/02-install-openclaw.sh` | Installs or refreshes OpenClaw, imports the latest GGUF, runs non-interactive onboarding, and starts the gateway. |
| `scripts/03-update-model.sh` | Rebuilds `qwen-local:latest` from the newest GGUF and refreshes OpenClaw when available. |
| `scripts/04-verify.sh` | Checks active GGUF state, Ollama health, model registration, chat/tool support, OpenClaw config, gateway health, and agent smoke behavior. |
| `scripts/05-reset-openclaw.sh` | Removes OpenClaw service/config/workspace state while preserving Ollama and GGUF files. |
| `scripts/06-uninstall-all.sh` | Best-effort removal of OpenClaw, Ollama, generated state, logs, runtime files, and workspace data managed by this pipeline. |
| `scripts/10-run-ollama-serve.sh` | Manual background runner for `ollama serve` when systemd is unavailable. |
| `scripts/11-run-openclaw-gateway.sh` | Manual background runner for the OpenClaw gateway when systemd is unavailable. |
| `scripts/12-start-openclaw.sh` | One-command startup, repair, warm-load, and gateway launch entrypoint. |

## Key Configuration

The main values live in `scripts/00-env.sh`:

```bash
BASE_DIR="/home/kgaer/code/OpenclawOllama"
GGUF_SEARCH_DIR="$BASE_DIR"
OLLAMA_MODEL_TAG="qwen-local:latest"
OLLAMA_TEMPLATE_BASE_MODEL="qwen2.5:3b"
OLLAMA_BIND_HOST="127.0.0.1"
OLLAMA_PORT="11434"
OPENCLAW_PORT="18789"
OPENCLAW_BIND_MODE="loopback"
OPENCLAW_WORKSPACE="$BASE_DIR/workspace"
OPENCLAW_MODEL_REF="ollama/${OLLAMA_MODEL_TAG}"
```

## Useful Commands

Check versions:

```bash
ollama --version
openclaw --version
```

List Ollama models:

```bash
ollama list
```

Run a direct Ollama smoke test:

```bash
ollama run qwen-local:latest "Reply with exactly: OPENCLAW_OLLAMA_OK"
```

Verify only:

```bash
./scripts/04-verify.sh
```

Reset OpenClaw only:

```bash
./scripts/05-reset-openclaw.sh
```

Uninstall everything managed by this pipeline:

```bash
./scripts/06-uninstall-all.sh
```

## Paths and URLs

| Item | Value |
| --- | --- |
| GGUF drop folder | `/home/kgaer/code/OpenclawOllama` |
| Stable Ollama model | `qwen-local:latest` |
| OpenClaw model reference | `ollama/qwen-local:latest` |
| Generated Modelfile | `/home/kgaer/code/OpenclawOllama/generated/Modelfile` |
| Stable GGUF symlink | `/home/kgaer/code/OpenclawOllama/generated/current-model.gguf` |
| Active GGUF marker | `/home/kgaer/code/OpenclawOllama/state/current.gguf` |
| Ollama endpoint | `http://127.0.0.1:11434` |
| OpenClaw Control UI | `http://127.0.0.1:18789/` |
| Ollama log | `/home/kgaer/code/OpenclawOllama/logs/ollama.log` |
| OpenClaw gateway log | `/home/kgaer/code/OpenclawOllama/logs/openclaw-gateway.log` |
| OpenClaw gateway token | `/home/kgaer/code/OpenclawOllama/state/openclaw-gateway.token` |

## Troubleshooting

If verification says the newest GGUF is not active, run:

```bash
./scripts/03-update-model.sh
```

If the OpenClaw UI is reachable but browser auth is stale, run:

```bash
openclaw dashboard
```

If OpenClaw config or workspace state is broken but Ollama and the GGUF should remain:

```bash
./scripts/05-reset-openclaw.sh
./scripts/02-install-openclaw.sh
```

If WSL2 systemd is unavailable, the pipeline falls back to manual PID-controlled background runners under `run/`.

If passwordless `sudo` is unavailable, Ollama is installed under:

```text
~/.local/share/ollama-app
```

with a user systemd service when possible.

## Security and Reproducibility Notes

- The install scripts use remote installers for Ollama and OpenClaw in some paths. For production use, pin versions and verify checksums or signatures.
- `npm install -g openclaw@latest` intentionally tracks the latest OpenClaw CLI. Pin a version if you need reproducible builds.
- The newest GGUF is selected by modification time. Use clear file names or a stricter manifest if multiple model versions live in the directory.
- The OpenClaw gateway token is stored in `state/openclaw-gateway.token` with mode `600`. Do not commit runtime state.
- There is no `LICENSE` file in this repository at the moment. Add one before distributing the code publicly.

## Additional Documentation

- See `CODE_WALKTHROUGH.md` for a detailed source-level walkthrough.
- See `sft-qwen2-5-3b-instruct.ipynb` for the fine-tuning and GGUF export workflow.
- See `Pipeline.png` and `FineTuningPipeLineOpenClaw.pptx` for the visual pipeline materials.
