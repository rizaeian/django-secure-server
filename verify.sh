#!/usr/bin/env bash
# verify.sh - Check that the server is still secure. Changes nothing.
# Usage: sudo ./verify.sh

set -uo pipefail   # no -e: we want to run ALL checks, even if one fails

ADMIN_USER="javid"
APP_USER="django"
APP_DIR="/srv/django"
APP_PORT="8001"
SERVER_NAME="django.local"

PASS=0
FAIL=0

# check "description" "command" -> PASS if the command succeeds
check() {
  if bash -c "$2" >/dev/null 2>&1; then
    echo -e "  \033[1;32m[PASS]\033[0m $1"; PASS=$((PASS + 1))
  else
    echo -e "  \033[1;31m[FAIL]\033[0m $1"; FAIL=$((FAIL + 1))
  fi
}

if [[ $EUID -ne 0 ]]; then echo "Please run with sudo" >&2; exit 1; fi

echo "Users"
check "$ADMIN_USER is in the sudo group"      "id -nG $ADMIN_USER | grep -qw sudo"
check "$ADMIN_USER has an SSH key"             "test -s /home/$ADMIN_USER/.ssh/authorized_keys"
check "$APP_USER is NOT in the sudo group"     "! id -nG $APP_USER | grep -qw sudo"
check "$APP_USER cannot log in (nologin)"      "getent passwd $APP_USER | grep -q nologin"

echo "SSH"
check "root login disabled"                    "sshd -T | grep -qx 'permitrootlogin no'"
check "password login disabled"                "sshd -T | grep -qx 'passwordauthentication no'"
check "max 3 auth tries"                       "sshd -T | grep -qx 'maxauthtries 3'"

echo "Firewall"
check "ufw is active"                          "ufw status | grep -q 'Status: active'"
check "only 3 IPv4 rules (22, 80, 443)"        "[ \$(ufw status | grep -v v6 | grep -c ALLOW) -eq 3 ]"

echo "App"
check "django service is running"              "systemctl is-active --quiet django"
check "app runs as $APP_USER, not root"        "[ \"\$(ps -o user= -p \$(systemctl show -p MainPID --value django))\" = $APP_USER ]"
check "app listens only on 127.0.0.1:$APP_PORT" "ss -tln | grep -q '127.0.0.1:$APP_PORT' && ! ss -tln | grep -q '0.0.0.0:$APP_PORT'"
check "nginx answers for $SERVER_NAME"         "curl -s -o /dev/null -w '%{http_code}' -H 'Host: $SERVER_NAME' http://localhost | grep -qE '200|404'"

echo "Secrets"
check ".env is 600 and owned by $APP_USER"     "[ \"\$(stat -c '%a %U' $APP_DIR/.env)\" = '600 $APP_USER' ]"
check "$APP_DIR is not open to others"         "[ \"\$(stat -c '%a' $APP_DIR)\" = '750' ]"

echo "Monitoring"
check "fail2ban sshd jail is on"               "fail2ban-client status sshd"

echo
echo "Result: $PASS passed, $FAIL failed"
[[ $FAIL -eq 0 ]]   # exit code 0 only if everything passed
