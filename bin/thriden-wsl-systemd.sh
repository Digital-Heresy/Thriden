#!/usr/bin/env bash
#
# thriden-wsl-systemd.sh — turn on the scheduled upgrade path on a WSL host.
#
# WHY YOU NEED THIS ()
# Scheduled "upgrade at next sleep" is executed by a systemd timer on your host.
# WSL ships with systemd OFF, so without it the Forge banner's schedule button
# has nothing listening. That is survivable right up until the first BRAIN
# (engram) upgrade, which `bin/thriden-upgrade.sh` refuses to do synchronously
# on purpose -- it needs the pre-flight export, post-swap canary and auto-revert
# that only the scheduled path carries. At that point a host with no dispatcher
# has no upgrade route at all.
#
# HOW TO RUN IT — two passes, because enabling systemd needs a WSL restart:
#
#   1. In your Ubuntu (bash) terminal:   bin/thriden-wsl-systemd.sh
#   2. In a Windows PowerShell terminal: bin\thriden-wsl-restart.ps1
#   3. Back in Ubuntu, run this again:   bin/thriden-wsl-systemd.sh
#
# It works out for itself which pass it is on, so you cannot run it in the wrong
# order -- and re-running it when everything is already correct changes nothing.
#
#   --dry-run   print what would change, touch nothing
#
set -euo pipefail

DRY=0
[ "${1:-}" = "--dry-run" ] && DRY=1

say()  { printf '%s\n' "$*"; }
step() { printf '\n>> %s\n' "$*"; }
run()  { if [ "$DRY" = 1 ]; then printf '   [dry-run] %s\n' "$*"; else eval "$@"; fi; }

# ── Sanity: are we actually on WSL? ────────────────────────────────────────
if ! grep -qi microsoft /proc/version 2>/dev/null; then
  say "This host is not WSL — you don't need this script."
  say "Install the units the normal way (beta-onboarding.md § 7b)."
  exit 0
fi

# ── Where is the stack? ────────────────────────────────────────────────────
STACK_DIR="${THRIDEN_STACK_DIR:-$HOME/thriden}"
if [ ! -f "$STACK_DIR/docker-compose.yml" ]; then
  say "ERROR: no Thriden stack at '$STACK_DIR'."
  say "       Set THRIDEN_STACK_DIR to your clone, e.g."
  say "         THRIDEN_STACK_DIR=~/thriden bin/thriden-wsl-systemd.sh"
  exit 1
fi

# systemd is PID 1 only once WSL has been restarted with it enabled.
systemd_live() { [ "$(ps -p 1 -o comm= 2>/dev/null)" = "systemd" ]; }

# ══ PASS 1 — enable systemd, then hand off to PowerShell ═══════════════════
if ! systemd_live; then
  step "Pass 1 of 2 — enabling systemd in /etc/wsl.conf"

  if grep -qE '^\s*systemd\s*=\s*true' /etc/wsl.conf 2>/dev/null; then
    say "   already set in /etc/wsl.conf (just not applied yet)"
  elif grep -qE '^\s*\[boot\]' /etc/wsl.conf 2>/dev/null; then
    # A [boot] section exists: insert into it rather than appending a second
    # one, which WSL would ignore.
    say "   /etc/wsl.conf already has a [boot] section — adding systemd=true to it"
    run "sudo sed -i '0,/^\\s*\\[boot\\]/s//[boot]\\nsystemd=true/' /etc/wsl.conf"
  else
    say "   adding a [boot] section with systemd=true"
    run "printf '[boot]\nsystemd=true\n' | sudo tee -a /etc/wsl.conf >/dev/null"
  fi

  cat <<'EOF'

   Done. systemd is configured but NOT running yet -- WSL has to restart, and
   that has to happen from WINDOWS, because a distro cannot shut itself down.

   NEXT: open a PowerShell window (Start menu -> type "PowerShell") and paste
   these two lines. There is no file to find and no folder to cd into:

       wsl --version
       wsl --shutdown

   The first prints your WSL version -- if it errors instead, your WSL predates
   systemd support, so run `wsl --update` and then `wsl --shutdown`.
   The second closes every WSL window, including this one. That is expected.

   THEN: reopen Ubuntu and run this script once more to finish:

       cd ~/thriden && bin/thriden-wsl-systemd.sh

EOF
  exit 0
fi

# ══ PASS 2 — install the dispatcher ════════════════════════════════════════
step "Pass 2 of 2 — systemd is running; installing the upgrade dispatcher"
cd "$STACK_DIR"

if [ ! -f deploy/systemd/thriden-deploy-dispatch.service ]; then
  say "ERROR: deploy/systemd/ units not found under $STACK_DIR."
  say "       Is this a full clone of the Thriden recipe? Try: git pull"
  exit 1
fi

run "sudo install -m 0644 deploy/systemd/thriden-deploy-dispatch.service \
     deploy/systemd/thriden-deploy-dispatch.timer /etc/systemd/system/"

# Docker Desktop provides docker from the Windows side, so a WSL host has NO
# docker.service unit. The shipped unit hard-Requires= it, and a Requires= on a
# unit that does not exist refuses the start outright ("Unit docker.service not
# found"), which then fails the timer.
#
# Patched in the INSTALLED COPY rather than via a drop-in on purpose:
# systemd.unit(5) states dependencies "cannot be reset to an empty list, so
# dependencies can only be added in drop-ins". An empty Requires= in a drop-in
# is silently ignored -- worse than not trying, because it looks like a fix and
# changes nothing. Patching here also repairs a clone whose shipped unit
# predates the Wants= change.
UNIT=/etc/systemd/system/thriden-deploy-dispatch.service
if ! systemctl cat docker.service >/dev/null 2>&1; then
  say "   no docker.service on this host (Docker Desktop) - softening the hard dependency"
  run "sudo sed -i 's/^Requires=docker[.]service/Wants=docker.service/' $UNIT"
fi

# The shipped unit targets a dedicated production host: it runs as a `deploy`
# service user out of /srv/thriden. A single-user install (the beta path) has
# neither, and WITHOUT this override the timer goes active while every firing
# fails -- a dispatcher that looks installed and does nothing, which is worse
# than one that was never installed, because `thriden-doctor.sh` check 6 sees an
# enabled+active timer and reports it as fine.
step "Overriding the unit for this single-user install"
say "   user=$(whoami)  stack=$STACK_DIR"
DROPIN=/etc/systemd/system/thriden-deploy-dispatch.service.d
run "sudo mkdir -p $DROPIN"
if [ "$DRY" = 1 ]; then
  printf '   [dry-run] write %s/single-user.conf\n' "$DROPIN"
else
  # The empty ExecStart= is required: systemd needs the shipped value cleared
  # before a replacement is accepted.
  sudo tee "$DROPIN/single-user.conf" >/dev/null <<EOF
[Service]
User=$(whoami)
Group=$(id -gn)
WorkingDirectory=$STACK_DIR
Environment=THRIDEN_STACK_DIR=$STACK_DIR
ExecStart=
ExecStart=$STACK_DIR/bin/thriden-deploy-dispatch.sh
EOF
fi

step "Enabling the timer"
run "sudo systemctl daemon-reload"
# Clear any failed state from a previous attempt, or enable --now inherits it.
run "sudo systemctl reset-failed thriden-deploy-dispatch.timer thriden-deploy-dispatch.service 2>/dev/null || true"
run "sudo systemctl enable --now thriden-deploy-dispatch.timer"

if [ "$DRY" = 1 ]; then
  say ""
  say "[dry-run] nothing was changed."
  exit 0
fi

# Run the service ONCE, now, rather than enabling a timer and declaring victory.
# A timer whose unit cannot load reports itself enabled and active while never
# firing -- the exact silent failure this script exists to prevent -- and the
# only way to know is to make it run. This also bootstraps OnUnitActiveSec,
# which has no reference point until the service has been activated once.
step "Test run (proves the unit actually works)"
if sudo systemctl start thriden-deploy-dispatch.service; then
  say "   service ran and exited cleanly"
else
  say ""
  say "PROBLEM: the dispatcher unit failed its first run. The timer is installed"
  say "but will not work until this is fixed. Show DH this:"
  say ""
  systemctl status thriden-deploy-dispatch.service --no-pager -l | sed 's/^/   /' || true
  journalctl -u thriden-deploy-dispatch.service -n 20 --no-pager | sed 's/^/   /' || true
  exit 1
fi

# A unit that failed once STAYS failed until cleared, so a timer that tripped
# on an earlier attempt keeps reporting failed even after the cause is fixed --
# which reads as "the fix did not work" (it is what the first participant hit:
# service starting fine while the timer still showed the failure from minutes
# earlier). Clear and restart it now that the unit is known-good.
if [ "$(systemctl is-active thriden-deploy-dispatch.timer 2>/dev/null)" != "active" ]; then
  step "Clearing a latched failure on the timer"
  run "sudo systemctl reset-failed thriden-deploy-dispatch.timer 2>/dev/null || true"
  run "sudo systemctl restart thriden-deploy-dispatch.timer"
fi

step "Checking it"
systemctl list-timers thriden-deploy-dispatch.timer --no-pager || true
if systemctl list-timers thriden-deploy-dispatch.timer --no-pager | grep -q '^- '; then
  say ""
  say "   NOTE: the timer shows no next elapse yet. That resolves once the"
  say "   service has run at least once, which the test run above just did."
fi
cat <<EOF

Installed. The timer runs every 60s and does nothing until a Scion schedules an
upgrade at sleep, so an idle log is the healthy state.

Give it two minutes, then confirm it is running rather than failing:

    journalctl -u thriden-deploy-dispatch.service -n 20 --no-pager

Then re-run the doctor — check 6 should read PASS instead of WARN:

    cd $STACK_DIR && bin/thriden-doctor.sh
EOF
