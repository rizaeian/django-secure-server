#!/usr/bin/env bash
# setup.sh - Secure Ubuntu server for a Django app
# Usage: sudo ./setup.sh
# Safe to run more than once: each step checks before it changes.

set -euo pipefail   # stop on errors, unset variables, and failed pipes

# ---------- Settings (change these) ----------
ADMIN_USER="javid"
APP_USER="django"
APP_DIR="/srv/django"
APP_PORT="8001"
SERVER_NAME="django.local"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ---------- Helpers ----------
log()  { echo -e "\n\033[1;34m==> $*\033[0m"; }
ok()   { echo -e "   \033[1;32m[OK]   $*\033[0m"; }
skip() { echo -e "   \033[1;33m[SKIP] $*\033[0m"; }

# ---------- 0. Safety checks ----------
check_root() {
  log "0. Safety checks"
  if [[ $EUID -ne 0 ]]; then
    echo "Please run with sudo: sudo ./setup.sh" >&2
    exit 1
  fi
  ok "running as root"
}

# ---------- 1. Packages ----------
install_packages() {
  log "1. Install packages"
  export DEBIAN_FRONTEND=noninteractive   # apt: never ask questions
  export NEEDRESTART_MODE=a               # needrestart: restart services automatically
  apt-get update -qq
  apt-get install -y -qq python3-venv python3-pip nginx ufw fail2ban git
  ok "packages installed"
}

# ---------- 2. Admin user ----------
create_admin_user() {
  log "2. Admin user: $ADMIN_USER"
  if id "$ADMIN_USER" &>/dev/null; then
    skip "user $ADMIN_USER already exists"
  else
    adduser --disabled-password --gecos "" "$ADMIN_USER"
    ok "user $ADMIN_USER created (set a password later: sudo passwd $ADMIN_USER)"
  fi
  usermod -aG sudo "$ADMIN_USER"
  ok "$ADMIN_USER is in the sudo group"
}

# ---------- Main ----------
main() {
  check_root
  install_packages
  create_admin_user
  log "Done (part 1)"
}

main "$@"
