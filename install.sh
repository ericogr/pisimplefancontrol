#!/bin/bash
set -euo pipefail

RAW_BASE="https://raw.githubusercontent.com/ericogr/pisimplefancontrol/main"
BIN_PATH="/usr/local/bin/pisimplefancontrol.sh"
CONF_PATH="/etc/pisimplefancontrol.conf"
SERVICE_PATH="/etc/systemd/system/pisimplefancontrol.service"

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1"
    exit 1
  fi
}

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    echo "Please run this installer as root (e.g., sudo bash install.sh)."
    exit 1
  fi
}

download() {
  local src=$1
  local dst=$2
  echo "Downloading $src -> $dst"
  curl -fsSL "$src" -o "$dst"
}

install_script() {
  download "$RAW_BASE/pisimplefancontrol.sh" "$BIN_PATH"
  chmod +x "$BIN_PATH"
}

install_config() {
  if [ -f "$CONF_PATH" ]; then
    echo "Config already exists at $CONF_PATH (keeping existing file)."
  else
    download "$RAW_BASE/pisimplefancontrol.conf.example" "$CONF_PATH"
    echo "Wrote default config to $CONF_PATH"
  fi
}

install_service() {
  download "$RAW_BASE/pisimplefancontrol.service" "$SERVICE_PATH"
  systemctl daemon-reload
  systemctl enable --now pisimplefancontrol.service
}

main() {
  require_root
  require_cmd curl
  require_cmd systemctl
  install_script
  install_config
  install_service

  echo ""
  echo "pisimplefancontrol installed."
  echo "Edit $CONF_PATH to tune thresholds and PWM settings."
  echo "Service status: systemctl status pisimplefancontrol.service"
  echo "Logs: journalctl -u pisimplefancontrol.service -f"
}

main "$@"
