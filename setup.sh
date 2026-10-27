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
ADMIN_PUBKEY_FILE="$SCRIPT_DIR/admin_key.pub"

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

# ---------- 3. Admin SSH key ----------
setup_admin_key() {
  log "3. SSH key for $ADMIN_USER"
  if [[ ! -f "$ADMIN_PUBKEY_FILE" ]]; then
    echo "Missing $ADMIN_PUBKEY_FILE - put the admin's PUBLIC key there first." >&2
    exit 1
  fi
  local ssh_dir="/home/$ADMIN_USER/.ssh"
  local auth="$ssh_dir/authorized_keys"
  local key
  key="$(cat "$ADMIN_PUBKEY_FILE")"

  install -d -m 700 -o "$ADMIN_USER" -g "$ADMIN_USER" "$ssh_dir"
  touch "$auth"
  if grep -qxF "$key" "$auth"; then
    skip "key already in authorized_keys"
  else
    echo "$key" >> "$auth"
    ok "key added"
  fi
  chown "$ADMIN_USER:$ADMIN_USER" "$auth"
  chmod 600 "$auth"
  ok "owner and permissions set (700 / 600)"
}

# ---------- 4. SSH hardening ----------
harden_ssh() {
  log "4. SSH hardening"
  local src="$SCRIPT_DIR/config/10-hardening.conf"
  local dst="/etc/ssh/sshd_config.d/10-hardening.conf"

  # Safety: never disable passwords if the admin has no key
  if [[ ! -s "/home/$ADMIN_USER/.ssh/authorized_keys" ]]; then
    echo "No SSH key for $ADMIN_USER - refusing to harden SSH (lockout risk)." >&2
    exit 1
  fi

  if cmp -s "$src" "$dst"; then
    skip "hardening file already up to date"
    return
  fi

  if [[ -f "$dst" ]]; then cp "$dst" "$dst.bak"; fi
  install -m 644 "$src" "$dst"

  if sshd -t; then
    systemctl reload ssh
    ok "SSH hardened and reloaded"
  else
    echo "sshd config test failed - restoring the old file" >&2
    if [[ -f "$dst.bak" ]]; then mv "$dst.bak" "$dst"; else rm -f "$dst"; fi
    exit 1
  fi
}

# ---------- 5. Firewall ----------
setup_firewall() {
  log "5. Firewall (ufw)"
  ufw default deny incoming  >/dev/null
  ufw default allow outgoing >/dev/null
  # Allow SSH FIRST, so enabling the firewall can't lock us out
  ufw allow OpenSSH >/dev/null
  ufw allow 80/tcp  >/dev/null
  ufw allow 443/tcp >/dev/null
  ok "rules: deny incoming, allow 22 (OpenSSH), 80, 443"

  if ufw status | grep -q "Status: active"; then
    skip "ufw already active"
  else
    ufw --force enable >/dev/null
    ok "ufw enabled"
  fi
}

# ---------- Main ----------
main() {
  check_root
  install_packages
  create_admin_user
  setup_admin_key
  harden_ssh
  setup_firewall
  log "Done (part 3)"
}

main "$@"
