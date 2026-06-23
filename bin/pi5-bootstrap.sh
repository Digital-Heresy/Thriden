#!/usr/bin/env bash
#
# pi5-bootstrap.sh -- bring a fresh Pi5 from "Docker installed" to "ready for
# Thriden compose deploy". Idempotent: safe to re-run after partial completion.
#
# Automates Phases 1 (apt hygiene) and 2 (identity layer) of docs/pi5-bootstrap.md.
# Phases 3 (SOPS host key), 4 (network hardening), 5 (smoke validation) are
# operator-driven and stay manual -- see the doc for the procedures.
#
# Usage (on the Pi5 itself, as the operator account):
#   curl -fL https://raw.githubusercontent.com/Digital-Heresy/MindHive/main/bin/pi5-bootstrap.sh -o /tmp/bootstrap.sh
#   bash /tmp/bootstrap.sh
#
# Or after `git clone` of the MindHive repo:
#   bash bin/pi5-bootstrap.sh
#
# Exit codes:
#   0  -- all phases completed (or already done) successfully
#   1  -- a pre-flight check failed (not Pi5, not Linux, no sudo, etc.)
#   2  -- apt operation failed
#   3  -- docker / compose not installed (operator must install manually first)

set -euo pipefail

# ── Pre-flight ────────────────────────────────────────────────────────────

require() {
  command -v "$1" >/dev/null 2>&1 || {
    echo "[!] required command not found: $1" >&2
    return 1
  }
}

echo "[*] pi5-bootstrap.sh -- pre-flight checks"

if [[ "$(uname -m)" != "aarch64" ]]; then
  echo "[!] expected aarch64 (Pi5), got $(uname -m). Aborting." >&2
  exit 1
fi

# We need sudo. Use -n (non-interactive) so the script fails fast on a
# host where sudo would prompt -- the script is meant to run unattended
# (e.g. piped from curl). If sudo wants a password, run the operator's
# `sudo -v` once interactively before invoking this script.
if ! sudo -n true 2>/dev/null; then
  echo "[!] sudo refused. Either the operator account lacks sudo, or sudo" >&2
  echo "    wants a password. Run 'sudo -v' once first, then re-run." >&2
  exit 1
fi

# Docker + compose must be pre-installed. Bootstrap doesn't manage Docker
# install because the upstream apt repo dance is distro/version-specific
# and the install script Docker publishes is the operator's call.
require docker || { echo "[!] install Docker CE first -- see https://docs.docker.com/engine/install/ubuntu/"; exit 3; }
docker compose version >/dev/null 2>&1 || { echo "[!] docker compose plugin missing -- 'sudo apt install docker-compose-plugin'"; exit 3; }

echo "[+] pre-flight OK -- $(docker --version), $(docker compose version --short 2>/dev/null || echo 'compose: present')"

# ── Phase 1: Box hygiene ──────────────────────────────────────────────────

echo
echo "[*] Phase 1 -- apt update + upgrade"

sudo apt-get update
sudo DEBIAN_FRONTEND=noninteractive apt-get -y \
  -o Dpkg::Options::='--force-confold' \
  -o Dpkg::Options::='--force-confdef' \
  upgrade

if [[ -f /var/run/reboot-required ]]; then
  echo "[!] /var/run/reboot-required is set -- kernel or microcode advanced."
  echo "    Reboot manually when ready (not from inside this script):"
  echo "      sudo systemd-run --on-active=2 systemctl reboot"
  echo "    Then re-run bin/pi5-bootstrap.sh to complete the remaining phases."
  exit 0
fi

echo "[+] Phase 1 complete -- no reboot pending"

# ── Phase 2: Identity layer ───────────────────────────────────────────────

echo
echo "[*] Phase 2 -- deploy user + /srv/thriden/"

if getent passwd deploy >/dev/null; then
  echo "[=] deploy user already exists"
else
  sudo useradd --system --shell /usr/sbin/nologin deploy
  echo "[+] deploy user created"
fi

if id -nG deploy | tr ' ' '\n' | grep -qx docker; then
  echo "[=] deploy already in docker group"
else
  sudo usermod -aG docker deploy
  echo "[+] deploy added to docker group"
fi

if [[ -d /srv/thriden ]]; then
  echo "[=] /srv/thriden already exists"
  # Idempotent ownership fixup: ensure deploy owns it even if re-run with
  # the dir created by a previous owner.
  sudo chown deploy:deploy /srv/thriden
else
  sudo install -d -o deploy -g deploy -m 0755 /srv/thriden
  echo "[+] /srv/thriden created (deploy:deploy)"
fi

echo "[+] Phase 2 complete"

# ── Summary + next steps ──────────────────────────────────────────────────

echo
echo "[+] pi5-bootstrap.sh DONE -- Phases 1 and 2 applied"
echo
echo "Next (operator-driven, see docs/pi5-bootstrap.md):"
echo "  Phase 3 -- SOPS host age key (docs/secrets-ops.md § 6 or § 6a)"
echo "  Phase 4 -- ufw configuration + sshd verification"
echo "  Phase 5 -- mongo smoke compose validation"
echo "  Then -- Thriden stack deploy"
