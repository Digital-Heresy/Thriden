#!/usr/bin/env bash
#
# thriden-scion-restore.sh — restore a Scion from a backup archive onto a
# (possibly fresh) Thriden host, in ONE command.
#
# A fresh-stack restore is inherently two-pass: the Engram brain import needs
# engram-<short> UP and bound to forge_soul_id, but that container can only
# boot AFTER the Scion's config (soul_id, raven_token) is in Mongo — which the
# restore itself provides. This wrapper hides the dance:
#
#   1. get the archive (R2 key -> download via forge-web, or a local path)
#   2. restore pass 1  -> Mongo + SOUL land (the brain is EXPECTED to skip:
#                         engram-<short> isn't up yet — reported honestly)
#   3. scion-up        -> boots engram-<short> + forge-<short> (now bound)
#   4. restore pass 2  -> the brain imports (idempotent re-run of the restore)
#   5. report any channel secrets to re-supply (backups REDACT them, so on a
#      fresh target discord_token/telegram_token land missing — re-attach from
#      1Password via forge-web Comms; data comes from R2, secrets from 1Password)
#
# Usage:
#   thriden-scion-restore.sh <r2-key|local.zip[.age]> [--scion-id <id>] [--identity <age-key>]
#
#     <r2-key>     object key under the configured R2 bucket (e.g.
#                  <scion>/<timestamp>_<hash>.zip), downloaded via
#                  forge-web's stored R2 config; OR a path to a LOCAL archive.
#     --scion-id   target Scion id (default: read from the archive manifest)
#     --identity   age secret-key file, for an encrypted .zip.age archive
#
# Self-elevates to deploy. For an IN-PLACE restore (the Scion's brain is
# already running) just use the forge-web restore wizard — it's single-pass.
# Idempotent: re-running re-upserts Mongo + re-imports the brain (no dupes).
#
# Overridable via THRIDEN_STACK_DIR / THRIDEN_DEPLOY_USER / COMPOSE_PROJECT_NAME.
#
set -euo pipefail

STACK_DIR="${THRIDEN_STACK_DIR:-/srv/thriden}"
DEPLOY_USER="${THRIDEN_DEPLOY_USER:-deploy}"
proj="${COMPOSE_PROJECT_NAME:-$(basename "$STACK_DIR")}"

ARCHIVE=""; SCION_ID=""; IDENTITY=""
while [ $# -gt 0 ]; do
  case "$1" in
    --scion-id) SCION_ID="${2:-}"; shift 2 ;;
    --identity) IDENTITY="${2:-}"; shift 2 ;;
    -h|--help)  grep '^#' "$0" | sed '1d;s/^#\{0,1\} \{0,1\}//'; exit 0 ;;
    -*) echo "unknown flag: $1  (try --help)" >&2; exit 2 ;;
    *)  ARCHIVE="$1"; shift ;;
  esac
done
[ -n "$ARCHIVE" ] || {
  echo "usage: $(basename "$0") <r2-key|local.zip[.age]> [--scion-id <id>] [--identity <age-key>]" >&2
  exit 2
}
# --scion-id is optional (the manifest carries it), but if supplied validate it
# before it reaches the in-container CLI args below.
case "$SCION_ID" in
  *[!A-Za-z0-9._-]*)
    echo "ERROR: invalid --scion-id '$SCION_ID' (allowed: letters, digits, . _ -)." >&2
    exit 2 ;;
esac

if [ "$(id -un)" != "$DEPLOY_USER" ]; then
  echo ">> elevating to '$DEPLOY_USER' ..." >&2
  exec sudo -u "$DEPLOY_USER" -H "$0" "$@"
fi

cd "$STACK_DIR"
web="${proj}-forge-web-1"
CPATH="/tmp/pf-restore-$$.zip"   # path INSIDE the forge-web container
case "$ARCHIVE" in *.age) CPATH="${CPATH}.age" ;; esac   # keep the suffix (restore sniffs it)

docker inspect "$web" >/dev/null 2>&1 || {
  echo "ERROR: $web isn't running — bring the substrate up first:" >&2
  echo "       bin/thriden-redeploy.sh forge-web" >&2
  exit 1
}

restore_cmd() {
  if [ -n "$IDENTITY" ]; then
    docker exec "$web" personaforge-admin scion restore "$CPATH" --scion-id "$SCION_ID" --identity "$IDENTITY"
  else
    docker exec "$web" personaforge-admin scion restore "$CPATH" --scion-id "$SCION_ID"
  fi
}

# --- 1. stage the archive into the forge-web container -----------------------
if [ -f "$ARCHIVE" ]; then
  echo ">> staging local archive into $web ..." >&2
  docker cp "$ARCHIVE" "${web}:${CPATH}"
else
  echo ">> downloading R2 object '$ARCHIVE' into $web ..." >&2
  docker exec -e PF_R2_KEY="$ARCHIVE" -e PF_DEST="$CPATH" "$web" python - <<'PY'
import asyncio, os
from forge.backup.r2_config import get_r2_config, download_backup
from forge.data.mongodb import MongoConnection
async def main():
    m = MongoConnection(uri=os.environ["MONGO_URI"], db_name=os.environ.get("MONGO_DB", "personaforge"))
    await m.connect()
    cfg = await get_r2_config(m)
    if not cfg:
        raise SystemExit("R2 is not configured — set it on the forge-web Backups page first")
    await asyncio.to_thread(download_backup, cfg, os.environ["PF_R2_KEY"], os.environ["PF_DEST"])
    await m.close()
    print("   downloaded ->", os.environ["PF_DEST"])
asyncio.run(main())
PY
fi

# --- 2. resolve scion_id from the manifest if not supplied ------------------
if [ -z "$SCION_ID" ]; then
  SCION_ID="$(docker exec -e PF_ZIP="$CPATH" -e PF_ID="$IDENTITY" "$web" python - <<'PY'
import os
from forge.admin.restore import inspect_backup
print(inspect_backup(os.environ["PF_ZIP"], identity_path=(os.environ.get("PF_ID") or None)).scion_id)
PY
)"
  SCION_ID="$(printf '%s' "$SCION_ID" | tr -d '[:space:]')"
  echo ">> target scion_id (from manifest): $SCION_ID" >&2
fi
[ -n "$SCION_ID" ] || { echo "ERROR: could not determine scion_id." >&2; exit 1; }

# --- 3. pass 1: Mongo + SOUL (brain skips — engram-<short> isn't up yet) -----
echo ">> restore pass 1/2: Mongo + SOUL (the brain is expected to skip here) ..." >&2
restore_cmd 2>&1 | sed 's/^/   /' \
  || echo "   (pass 1 reported the brain unrestored — expected; bringing it up next)" >&2

# --- 4. scion-up: boot engram-<short> + forge-<short> -----------------------
echo ">> bringing up the Scion runtime (engram + forge) ..." >&2
bin/thriden-scion-up.sh "$SCION_ID" 2>&1 | sed 's/^/   /'

short="$(docker exec "$web" personaforge-admin scion show "$SCION_ID" 2>/dev/null \
          | sed -n 's/^runtime_short:[[:space:]]*//p' | head -n1)"
eng="${proj}-engram-${short}-1"
echo ">> waiting for $eng to be healthy ..." >&2
_ready=0
for _ in $(seq 1 30); do
  st="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$eng" 2>/dev/null || true)"
  case "$st" in healthy|running) _ready=1; break ;; esac
  sleep 2
done
if [ "$_ready" -eq 0 ]; then
  echo "   WARNING: $eng did not reach healthy/running within 60s — proceeding anyway (check logs if pass 2 fails)" >&2
fi

# --- 5. pass 2: Engram brain import (engram is up now) ----------------------
echo ">> restore pass 2/2: Engram brain import ..." >&2
restore_cmd 2>&1 | sed 's/^/   /' \
  || echo "   (pass 2 had problems — see the lines above)" >&2

# --- 6. cleanup + report channel secrets that need re-supplying -------------
docker exec "$web" rm -f "$CPATH" 2>/dev/null || true

echo ">> checking for channel secrets to re-supply ..." >&2
docker exec -e PF_SID="$SCION_ID" "$web" python - <<'PY'
import asyncio, os
from forge.data.mongodb import MongoConnection
async def main():
    m = MongoConnection(uri=os.environ["MONGO_URI"], db_name=os.environ.get("MONGO_DB", "personaforge"))
    await m.connect()
    d = await m.db.scions.find_one({"scion_id": os.environ["PF_SID"]}) or {}
    missing = [f for f in ("discord_token", "telegram_token") if not d.get(f)]
    if missing:
        print("   !! channel secrets landed MISSING (backups redact them): " + ", ".join(missing))
        print("      Re-attach from 1Password — forge-web -> %s -> Comms, or:" % os.environ["PF_SID"])
        for f in missing:
            ch = f.split("_")[0]
            print("        personaforge-admin scion attach %s %s --token <%s-bot-token>"
                  % (ch, os.environ["PF_SID"], ch))
    else:
        print("   channel secrets present.")
    await m.close()
asyncio.run(main())
PY

echo ">> restore of '$SCION_ID' complete — track it in forge-web /scions." >&2
