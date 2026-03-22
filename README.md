# OpenClawOllama WSL2 Pipeline

This repository now contains a WSL2-native Bash pipeline for:

- installing Ollama inside Ubuntu
- importing the newest local GGUF into a stable Ollama tag
- installing OpenClaw inside Ubuntu
- keeping OpenClaw pointed at the same local Ollama model
- verifying that Ollama and the OpenClaw gateway are both live

The stable model tag is:

```text
qwen-local:latest
```

OpenClaw is pinned to:

```text
ollama/qwen-local:latest
```

That means your day-to-day workflow is:

1. Copy a newer `.gguf` file into `/home/kgaer/code/OpenclawOllama`
2. Run `./scripts/03-update-model.sh`
3. Ollama recreates `qwen-local:latest` from the newest GGUF
4. OpenClaw keeps using `ollama/qwen-local:latest`
5. Verification confirms the live setup

## Folder Structure

```text
/home/kgaer/code/OpenclawOllama
├── README.md
├── scripts
│   ├── 00-env.sh
│   ├── 01-install-ollama.sh
│   ├── 02-install-openclaw.sh
│   ├── 03-update-model.sh
│   ├── 04-verify.sh
│   ├── 05-reset-openclaw.sh
│   ├── 06-uninstall-all.sh
│   ├── 10-run-ollama-serve.sh
│   ├── 11-run-openclaw-gateway.sh
│   └── lib
│       └── common.sh
├── generated
├── logs
├── run
└── state
```

## What Each Script Does

`scripts/00-env.sh`

- shared settings for base directory, ports, model tag, Ollama base template model, test prompt, generated paths, and logs

`scripts/01-install-ollama.sh`

- installs or refreshes the Linux Ollama build inside WSL2
- uses the official system-wide installer when passwordless `sudo` is available
- otherwise installs Ollama under `~/.local/share/ollama-app` and registers a user `systemd` service
- uses `systemd` when available
- falls back to a manual background runner when `systemd` is not active
- verifies that Ollama responds on `http://127.0.0.1:11434`

`scripts/02-install-openclaw.sh`

- installs or refreshes OpenClaw inside WSL2
- imports the newest GGUF into Ollama first
- runs official non-interactive OpenClaw onboarding for local Ollama
- configures OpenClaw to use `ollama/qwen-local:latest`
- installs the OpenClaw gateway daemon when `systemd` is available
- falls back to a manual background gateway runner when `systemd` is not active

`scripts/03-update-model.sh`

- finds the newest `.gguf` in `/home/kgaer/code/OpenclawOllama` by modification time
- prints the exact file selected
- ensures the matching Ollama base template model is present, currently `qwen2.5:3b`
- creates a stable symlink at `generated/current-model.gguf`
- generates `generated/Modelfile` from the official Ollama base model template, replacing only the `FROM` line with the newest GGUF
- recreates Ollama model `qwen-local:latest`
- verifies both plain inference and Ollama tool-capability on the rebuilt model
- refreshes OpenClaw to keep using `ollama/qwen-local:latest`
- restarts the OpenClaw gateway cleanly if OpenClaw is already configured
- runs end-to-end verification unless you pass `--skip-verify`

`scripts/04-verify.sh`

- verifies that the newest GGUF in the folder is the active one
- verifies the Ollama model exists
- verifies direct Ollama inference
- verifies the rebuilt Ollama model still accepts tool-enabled chat requests
- verifies OpenClaw still points at `ollama/qwen-local:latest`
- verifies the OpenClaw gateway and Control UI are reachable
- runs an end-to-end OpenClaw agent smoke test and requires the expected exact reply through the gateway path

`scripts/05-reset-openclaw.sh`

- removes only OpenClaw local service/config/workspace state
- leaves Ollama and your GGUF files in place

`scripts/06-uninstall-all.sh`

- removes OpenClaw and Ollama from WSL2 as far as this pipeline can manage
- removes generated runtime state under this project

`scripts/10-run-ollama-serve.sh`

- manual no-`systemd` runner used by the pipeline to keep `ollama serve` alive in the background

`scripts/11-run-openclaw-gateway.sh`

- manual no-`systemd` runner used by the pipeline to keep the OpenClaw gateway alive in the background

## Initial Install

Make the scripts executable once:

```bash
cd /home/kgaer/code/OpenclawOllama
chmod +x scripts/*.sh scripts/lib/*.sh
```

Install Ollama:

```bash
./scripts/01-install-ollama.sh
```

Install OpenClaw and configure it against the newest GGUF already present in the folder:

```bash
./scripts/02-install-openclaw.sh
```

Run a standalone verification:

```bash
./scripts/04-verify.sh
```

## Normal Update Workflow

Copy your newest fine-tuned Qwen `.gguf` into:

```text
/home/kgaer/code/OpenclawOllama
```

Then run:

```bash
./scripts/03-update-model.sh
```

That one command will:

- detect the newest GGUF automatically
- print the selected file
- rebuild `qwen-local:latest`
- keep OpenClaw using `ollama/qwen-local:latest`
- restart the OpenClaw gateway if needed
- verify the whole pipeline

## Example Commands

Check versions:

```bash
ollama --version
openclaw --version
```

List Ollama models:

```bash
ollama list
```

Run a direct Ollama inference test:

```bash
ollama run qwen-local:latest "Reply with exactly: OPENCLAW_OLLAMA_OK"
```

Re-run verification only:

```bash
./scripts/04-verify.sh
```

Reset only OpenClaw:

```bash
./scripts/05-reset-openclaw.sh
```

Remove everything managed by this pipeline:

```bash
./scripts/06-uninstall-all.sh
```

## Key Paths and URLs

- GGUF drop folder: `/home/kgaer/code/OpenclawOllama`
- Generated Modelfile: `/home/kgaer/code/OpenclawOllama/generated/Modelfile`
- Stable GGUF symlink: `/home/kgaer/code/OpenclawOllama/generated/current-model.gguf`
- Ollama endpoint: `http://127.0.0.1:11434`
- OpenClaw Control UI: `http://127.0.0.1:18789/`
- Ollama log: `/home/kgaer/code/OpenclawOllama/logs/ollama.log`
- OpenClaw log: `/home/kgaer/code/OpenclawOllama/logs/openclaw-gateway.log`

## Notes

- The update logic always uses the newest `.gguf` in the base folder by modification time.
- Filenames with spaces are handled safely by importing through the stable symlink `generated/current-model.gguf`.
- The rebuild logic preserves the official Ollama prompt template for `qwen2.5:3b`, which is required for OpenClaw agent compatibility with tool-enabled Ollama chat.
- The stable Ollama tag prevents a pile-up of changing model names after each fine-tune refresh.
- OpenClaw is configured against the stable model reference, so repeated GGUF refreshes do not require manual config edits.
- If the Control UI ever gets stuck in a browser-side auth loop, run `openclaw dashboard` from WSL2 to reopen it with the current gateway token.
- If `openclaw onboard --install-daemon` warns that lingering is disabled, the gateway still works in the current login session. Run `sudo loginctl enable-linger kgaer` later if you want the user service to survive logouts.
