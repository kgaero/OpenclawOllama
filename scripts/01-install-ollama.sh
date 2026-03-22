#!/usr/bin/env bash
set -Eeuo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck disable=SC1091
source "$SCRIPT_DIR/lib/common.sh"

trap 'on_error "$?" "$LINENO" "$BASH_COMMAND"' ERR

load_nvm_if_present
ensure_dirs
require_cmd curl
require_cmd python3

log "Installing or refreshing Ollama inside WSL2 Ubuntu."

install_user_local_ollama() {
  local bootstrap_venv="$BASE_DIR/.venv-ollama-bootstrap"
  local release_url="https://github.com/ollama/ollama/releases/latest/download/ollama-linux-amd64.tar.zst"
  local archive_path="$STATE_DIR/ollama-linux-amd64.tar.zst"

  log "Installing Ollama without sudo under ${LOCAL_OLLAMA_INSTALL_DIR}."
  mkdir -p "$LOCAL_BIN_DIR" "$LOCAL_OLLAMA_INSTALL_DIR" "$SYSTEMD_USER_DIR"

  if [[ ! -x "$bootstrap_venv/bin/python" ]]; then
    run python3 -m venv "$bootstrap_venv"
    run "$bootstrap_venv/bin/pip" install --quiet zstandard
  fi

  run curl -fsSL "$release_url" -o "$archive_path"
  rm -rf "$LOCAL_OLLAMA_INSTALL_DIR"
  mkdir -p "$LOCAL_OLLAMA_INSTALL_DIR"

  "$bootstrap_venv/bin/python" - <<PY
import tarfile
import zstandard as zstd

archive_path = r"${archive_path}"
install_dir = r"${LOCAL_OLLAMA_INSTALL_DIR}"

with open(archive_path, "rb") as fh:
    dctx = zstd.ZstdDecompressor()
    with dctx.stream_reader(fh) as reader:
        tf = tarfile.open(fileobj=reader, mode="r|")
        tf.extractall(path=install_dir, filter="data")
PY

  ln -sfn "$LOCAL_OLLAMA_INSTALL_DIR/bin/ollama" "$LOCAL_BIN_DIR/ollama"

  cat >"$SYSTEMD_USER_DIR/$OLLAMA_USER_SERVICE_NAME" <<EOF
[Unit]
Description=Ollama Service (User)
After=network-online.target

[Service]
ExecStart=${LOCAL_BIN_DIR}/ollama serve
Restart=always
RestartSec=3
Environment=OLLAMA_HOST=${OLLAMA_BIND_HOST}:${OLLAMA_PORT}
Environment=HOME=%h
Environment=PATH=${LOCAL_BIN_DIR}:/usr/local/bin:/usr/bin:/bin

[Install]
WantedBy=default.target
EOF
}

if have_passwordless_sudo; then
  run bash -lc 'curl -fsSL https://ollama.com/install.sh | sh'
  record_service_mode "$OLLAMA_SERVICE_MODE_FILE" "systemd"
  log "Installed Ollama with the official system-wide installer."
else
  install_user_local_ollama
  record_service_mode "$OLLAMA_SERVICE_MODE_FILE" "systemd-user"
  warn "Passwordless sudo is unavailable. Using a user-local Ollama install and user systemd service."
fi

ensure_ollama_cli
run ollama --version

if [[ "$(read_service_mode "$OLLAMA_SERVICE_MODE_FILE" "manual")" == "systemd" ]]; then
  log "Managing Ollama with the system service."
elif [[ "$(read_service_mode "$OLLAMA_SERVICE_MODE_FILE" "manual")" == "systemd-user" ]]; then
  log "Managing Ollama with the user systemd service."
else
  record_service_mode "$OLLAMA_SERVICE_MODE_FILE" "manual"
  warn "systemd is not active in this WSL2 distro. Falling back to a background runner."
fi

start_ollama

log "Ollama installation and startup completed."
print_debug_paths
