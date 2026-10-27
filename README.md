# Django Secure Server

Bash scripts that turn a fresh Ubuntu server into a hardened host for a Django app, and then check that it stays secure.

- `setup.sh` applies the configuration. It is **safe to run more than once**: every step checks first and only changes what is missing.
- `verify.sh` checks 16 security rules and changes nothing. It exits with `0` only if all checks pass.

## Architecture

```
Internet -> ufw (22, 80, 443) -> nginx :80 -> gunicorn 127.0.0.1:8001 -> Django
                                              user "django": no login, no sudo
                                              secrets in .env (mode 600)
SSH:   key only, no root login, max 3 tries, watched by fail2ban
Admin: normal user with sudo, never root
```

## What it does

| # | Step | Why |
|---|------|-----|
| 0 | Safety checks (root, Ubuntu only) | stops early on the wrong system, changes nothing |
| 1 | Install only the needed packages | less software, fewer security holes |
| 2 | Create an admin user with sudo | never work as root |
| 3 | Install the admin's SSH key | keys are safer than passwords |
| 4 | Harden SSH (no root, no passwords, 3 tries) | refuses to run if the admin has no key, so you can't lock yourself out |
| 5 | Firewall: deny all, allow 22, 80, 443 | smallest possible attack surface |
| 6 | System user for the app | if the app is hacked, the attacker is not root |
| 7 | Django in a virtual environment | no system-wide pip |
| 8 | Secrets in `.env` (600), DEBUG off | secrets never live in the code |
| 9 | systemd service | auto-start at boot, restart on crash |
| 10 | nginx reverse proxy | the app is only reachable through nginx |
| 11 | fail2ban for SSH | blocks repeated failed logins |
| 12 | Final self-check | the script verifies its own work |

## Usage

```bash
git clone https://github.com/rizaeian/django-secure-server.git
cd django-secure-server

# Put the admin's PUBLIC key here (not committed to Git)
cp ~/.ssh/your_key.pub admin_key.pub

sudo ./setup.sh     # apply
sudo ./verify.sh    # check
```

Settings (admin name, app user, port, server name) are at the top of `setup.sh` and `verify.sh`.

## Example output

```
==> 4. SSH hardening
   [SKIP] hardening file already up to date
==> 12. Final check
   [OK]   app listens only on 127.0.0.1:8001
==> All done

Result: 16 passed, 0 failed
```

## Tested on

- Ubuntu 26.04 LTS: works; a second run only shows `[SKIP]` for finished steps
- Kali Linux: stops at the start with "Ubuntu only" and changes nothing

## Project structure

```
setup.sh        apply the configuration
verify.sh       read-only security checks
config/         sshd, systemd, nginx and fail2ban files
.env.example    template for the app secrets
```

## Ideas for next versions

- HTTPS with Let's Encrypt
- Config templates instead of fixed values (port, server name)
- GitHub Actions to run `shellcheck` on every push
