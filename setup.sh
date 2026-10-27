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

# Run a command as the app user, from "/" (the app user can't enter our home)
as_app() { (cd / && sudo -u "$APP_USER" "$@"); }

# ---------- 6. App user ----------
create_app_user() {
  log "6. App user: $APP_USER"
  if id "$APP_USER" &>/dev/null; then
    skip "user $APP_USER already exists"
  else
    adduser --system --group --home "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
    ok "system user $APP_USER created (no login, no sudo)"
  fi
  chmod 750 "$APP_DIR"
  ok "$APP_DIR is private (750)"
}

# ---------- 7. Django app ----------
setup_django_app() {
  log "7. Django app"
  if [[ -x "$APP_DIR/venv/bin/python" ]]; then
    skip "venv already exists"
  else
    as_app python3 -m venv "$APP_DIR/venv"
    ok "venv created"
  fi

  as_app "$APP_DIR/venv/bin/pip" install -q django gunicorn
  ok "django and gunicorn installed in the venv"

  local settings="$APP_DIR/app/mysite/settings.py"
  if [[ -f "$APP_DIR/app/manage.py" ]]; then
    skip "Django project already exists"
  else
    as_app mkdir -p "$APP_DIR/app"
    as_app "$APP_DIR/venv/bin/django-admin" startproject mysite "$APP_DIR/app"
    as_app sed -i "s/^ALLOWED_HOSTS = \[\]/ALLOWED_HOSTS = ['localhost', '127.0.0.1', '$SERVER_NAME']/" "$settings"
    as_app sed -i 's/^from pathlib import Path/from pathlib import Path\nimport os/' "$settings"
    as_app sed -i "s/^SECRET_KEY = .*/SECRET_KEY = os.environ['DJANGO_SECRET_KEY']/" "$settings"
    as_app sed -i "s/^DEBUG = True/DEBUG = os.environ.get('DJANGO_DEBUG', 'False') == 'True'/" "$settings"
    ok "project created; secrets and DEBUG read from the environment"
  fi
}

# ---------- 8. Secrets (.env) ----------
create_env_file() {
  log "8. Secrets: $APP_DIR/.env"
  local env_file="$APP_DIR/.env"
  if [[ -f "$env_file" ]]; then
    skip ".env already exists (never overwrite secrets)"
  else
    local key
    key="$(python3 -c 'import secrets; print(secrets.token_urlsafe(50))')"
    ( umask 077; printf "DJANGO_SECRET_KEY=%s\nDJANGO_DEBUG=False\n" "$key" > "$env_file" )
    ok ".env created with a new random secret"
  fi
  chown "$APP_USER:$APP_USER" "$env_file"
  chmod 600 "$env_file"
  ok "owner $APP_USER, mode 600"
}

# Copy a config file only if it is different. Returns 0 if it changed.
install_if_changed() {
  local src="$1" dst="$2"
  if cmp -s "$src" "$dst"; then return 1; fi
  install -m 644 "$src" "$dst"
  return 0
}

# ---------- 9. systemd service ----------
setup_service() {
  log "9. systemd service: django"
  if install_if_changed "$SCRIPT_DIR/config/django.service" /etc/systemd/system/django.service; then
    systemctl daemon-reload
    systemctl restart django
    ok "service file installed and restarted"
  else
    skip "service file already up to date"
  fi
  systemctl enable --now django >/dev/null 2>&1
  if systemctl is-active --quiet django; then
    ok "django is running"
  else
    echo "django service failed - see: journalctl -u django -n 30" >&2
    exit 1
  fi
}

# ---------- 10. nginx ----------
setup_nginx() {
  log "10. nginx site: $SERVER_NAME"
  if install_if_changed "$SCRIPT_DIR/config/nginx-django.conf" /etc/nginx/sites-available/django; then
    ok "site file installed"
  else
    skip "site file already up to date"
  fi
  ln -sf /etc/nginx/sites-available/django /etc/nginx/sites-enabled/django
  if nginx -t -q; then
    systemctl reload nginx
    ok "nginx config OK and reloaded"
  else
    echo "nginx config test failed - not reloading" >&2
    exit 1
  fi
}

# ---------- 11. fail2ban ----------
setup_fail2ban() {
  log "11. fail2ban"
  if install_if_changed "$SCRIPT_DIR/config/jail.local" /etc/fail2ban/jail.local; then
    systemctl restart fail2ban
    ok "jail.local installed, fail2ban restarted"
  else
    skip "jail.local already up to date"
  fi
  systemctl enable --now fail2ban >/dev/null 2>&1
  ok "fail2ban is running"
}

# ---------- 12. Final check ----------
final_check() {
  log "12. Final check"
  if ss -tln | grep -q "127.0.0.1:$APP_PORT"; then
    ok "app listens only on 127.0.0.1:$APP_PORT"
  else
    echo "app is not listening on 127.0.0.1:$APP_PORT" >&2
    exit 1
  fi
  local code
  code="$(curl -s -o /dev/null -w '%{http_code}' -H "Host: $SERVER_NAME" http://localhost)"
  ok "http://$SERVER_NAME answered with HTTP $code (404 is expected: DEBUG is off, no pages yet)"
}

# ---------- Main ----------
main() {
  check_root
  install_packages
  create_admin_user
  setup_admin_key
  harden_ssh
  setup_firewall
  create_app_user
  setup_django_app
  create_env_file
  setup_service
  setup_nginx
  setup_fail2ban
  final_check
  log "All done"
}

main "$@"
