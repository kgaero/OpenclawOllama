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
  run openclaw uninstall --all --yes --non-interactive || true
  if command -v npm >/dev/null 2>&1; then
    run npm uninstall -g openclaw || true
  fi
fi

if command -v ollama >/dev/null 2>&1; then
  stop_ollama || true

  if [[ "$(read_service_mode "$OLLAMA_SERVICE_MODE_FILE" "manual")" == "systemd" ]] && have_passwordless_sudo; then
    run sudo systemctl disable ollama || true
    run sudo rm -f /etc/systemd/system/ollama.service || true
    run sudo systemctl daemon-reload || true
  fi

  if [[ "$(read_service_mode "$OLLAMA_SERVICE_MODE_FILE" "manual")" == "systemd-user" ]]; then
    run systemctl --user disable --now "$OLLAMA_USER_SERVICE_NAME" || true
    run rm -f "$SYSTEMD_USER_DIR/$OLLAMA_USER_SERVICE_NAME" || true
    run systemctl --user daemon-reload || true
    run rm -rf "$LOCAL_OLLAMA_INSTALL_DIR" || true
    run rm -f "$LOCAL_BIN_DIR/ollama" || true
  fi

  ollama_bin="$(command -v ollama || true)"
  if [[ -n "$ollama_bin" ]] && have_passwordless_sudo; then
    run sudo rm -f "$ollama_bin" || true
  fi

  for candidate in /usr/local/lib/ollama /usr/lib/ollama /usr/share/ollama; do
    if [[ -e "$candidate" ]] && have_passwordless_sudo; then
      run sudo rm -rf "$candidate" || true
    fi
  done

  if have_passwordless_sudo; then
    run sudo userdel ollama || true
    run sudo groupdel ollama || true
  fi
fi

rm -rf "$GENERATED_DIR" "$LOG_DIR" "$RUN_DIR" "$STATE_DIR" "$OPENCLAW_WORKSPACE"

log "Ollama and OpenClaw have been removed from this WSL2 environment as far as this pipeline can manage."
