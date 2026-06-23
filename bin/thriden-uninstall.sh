#!/usr/bin/env bash
#
# thriden-uninstall.sh — tear down the ENTIRE Thriden stack on a host.
#
# The full-stack inverse of the deploy: ONE command removes every Thriden
# container, its named volumes (Mongo, Engram brains, local backups,
# workspaces), and the Digital-Heresy images. Scoped strictly to the
# `thriden` compose project (by container label + `<proj>_` volume prefix) —
# any OTHER Docker stacks on the host are left untouched.
#
#   /srv/thriden/bin/thriden-uninstall.sh [--dry-run] [--yes] [--keep-images]
#
#     --dry-run      list what would be removed; change nothing
#     --yes, -y      skip the interactive confirmation (required for
#                    non-interactive / scripted runs)
#     --keep-images  remove containers + volumes but leave the GHCR images
#                    (faster if you plan to redeploy the same versions soon)
#
# DESTRUCTIVE: removing the volumes deletes ALL Scion state on this host —
# Mongo config + sessions + memory, the Engram brains, AND the local backup
# copies. VERIFY AN OFF-HOST BACKUP FIRST (forge-web Backups page, or
# `personaforge-admin scion backup <id>`, shipped to R2). Once the volumes are
# gone, R2 is the only lifeline.
#
# Intentionally LEFT in place (the host may use these for non-Thriden things):
#   - $STACK_DIR                      git checkout + compose files + bin/
#   - $STACK_DIR/secrets/...          SOPS secrets + the age key
#   - $STACK_DIR/.docker/config.json  the GHCR login
# Remove those by hand for a total wipe — see the "Thriden ‐ Uninstall" wiki
# page for the list of Thriden-specific SOPS keys.
#
# Uses direct `docker rm` / `docker volume rm` — NOT `docker compose down`,
# which can't interpolate the SOPS env / Mongo-sourced per-Scion vars and
# errors out before removing anything. Self-elevates to `deploy`. Idempotent:
# anything already gone is a no-op.
#
# Overridable via THRIDEN_STACK_DIR / THRIDEN_DEPLOY_USER / COMPOSE_PROJECT_NAME.
#
set -euo pipefail

STACK_DIR="${THRIDEN_STACK_DIR:-/srv/thriden}"
DEPLOY_USER="${THRIDEN_DEPLOY_USER:-deploy}"
proj="${COMPOSE_PROJECT_NAME:-$(basename "$STACK_DIR")}"

DRY_RUN=0; ASSUME_YES=0; KEEP_IMAGES=0
for arg in "$@"; do
  case "$arg" in
    --dry-run)     DRY_RUN=1 ;;
    --yes|-y)      ASSUME_YES=1 ;;
    --keep-images) KEEP_IMAGES=1 ;;
    -h|--help)     grep '^#' "$0" | sed '1d;s/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    *) echo "unknown arg: $arg  (try --help)" >&2; exit 2 ;;
  esac
done

if [ "$(id -un)" != "$DEPLOY_USER" ]; then
  echo ">> elevating to '$DEPLOY_USER' ..." >&2
  exec sudo -u "$DEPLOY_USER" -H "$0" "$@"
fi

count() { if [ -z "$1" ]; then echo 0; else printf '%s\n' "$1" | wc -l | tr -d ' '; fi; }

# Enumerate — containers by compose-project label, volumes by `<proj>_` name
# prefix, images by the Digital-Heresy GHCR namespace. Each defaults to empty.
containers="$(docker ps -aq --filter "label=com.docker.compose.project=${proj}" 2>/dev/null || true)"
volumes="$(docker volume ls --format '{{.Name}}' 2>/dev/null | grep -E "^${proj}_" || true)"
images="$(docker images --format '{{.Repository}}:{{.Tag}}' 2>/dev/null | grep -E '^ghcr\.io/digital-heresy/' || true)"

echo ">> Thriden uninstall — compose project '${proj}' on $(hostname)" >&2
echo "   containers=$(count "$containers")  volumes=$(count "$volumes")  DH-images=$(count "$images")" >&2
[ -n "$volumes" ] && printf '   - volume %s\n' $volumes >&2 || true
[ -n "$images" ] && printf '   - image  %s\n' $images >&2 || true

if [ "$DRY_RUN" = 1 ]; then
  echo ">> --dry-run: nothing removed." >&2
  exit 0
fi

if [ -z "${containers}${volumes}${images}" ]; then
  echo ">> already clean — nothing to do." >&2
  exit 0
fi

if [ "$ASSUME_YES" != 1 ]; then
  if [ ! -t 0 ]; then
    echo "ERROR: refusing to run non-interactively without --yes." >&2
    echo "       This DELETES all Scion volumes (Mongo, Engram brains, local" >&2
    echo "       backups). Verify an off-host (R2) backup, then pass --yes." >&2
    exit 1
  fi
  echo "" >&2
  echo "!! DESTRUCTIVE: deletes ALL Thriden volumes on this host — Mongo config" >&2
  echo "!! + sessions + memory, the Engram brains, and the LOCAL backup copies." >&2
  echo "!! R2 is your only lifeline afterward." >&2
  read -r -p "   Type 'thriden' to confirm: " ans
  [ "$ans" = "thriden" ] || { echo ">> aborted." >&2; exit 1; }
fi

if [ -n "$containers" ]; then
  echo ">> stopping + removing containers ..." >&2
  printf '%s\n' "$containers" | xargs -r docker stop >/dev/null 2>&1 || true
  printf '%s\n' "$containers" | xargs -r docker rm   >/dev/null 2>&1 || true
fi

if [ -n "$volumes" ]; then
  echo ">> removing volumes ..." >&2
  for v in $volumes; do
    docker volume rm "$v" >/dev/null 2>&1 && echo "   removed $v" >&2 \
      || echo "   (skip $v — in use or already gone)" >&2
  done
fi

if [ "$KEEP_IMAGES" = 1 ]; then
  echo ">> --keep-images: Digital-Heresy images left in place." >&2
elif [ -n "$images" ]; then
  echo ">> removing Digital-Heresy images ..." >&2
  printf '%s\n' "$images" | xargs -r docker rmi -f >/dev/null 2>&1 || true
fi

cat >&2 <<EOF

>> Thriden uninstall complete on $(hostname).
   Intentionally LEFT in place (remove by hand for a total wipe — they may
   serve non-Thriden purposes):
     - ${STACK_DIR}                      git checkout + compose + bin/
     - ${STACK_DIR}/secrets/...          SOPS secrets + the age key
     - ${STACK_DIR}/.docker/config.json  GHCR login
   Thriden-specific SOPS keys you can drop from stack.enc.env if fully retiring:
     FORGE_WEB_ADMIN_TOKEN, MONGO_ROOT_PASSWORD, NOOSCOPE_ADMIN_PASSWORD,
     SESSION_SECRET, VOYAGE_API_KEY (+ the now-defunct CLOUDFLARE_DNS_API_TOKEN).
     ANTHROPIC_API_KEY may be shared with other tools — your call. R2 creds were
     Mongo-managed, so they're already gone with the volumes.
   Full guide: MindHive wiki -> "Thriden ‐ Uninstall".
EOF
