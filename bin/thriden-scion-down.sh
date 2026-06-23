#!/usr/bin/env bash
#
# thriden-scion-down.sh — fully tear down a Scion on the Thriden host.
# The inverse of thriden-scion-up.sh: ONE command removes everything.
#
#   /srv/thriden/bin/thriden-scion-down.sh <scion-id>
#       resolve runtime_short, cascade-delete the Scion from Mongo (via the
#       in-container CLI), then remove the engram-<short>/forge-<short>
#       containers, their <short>-data/<short>-workspace volumes, and the
#       rendered compose-<short>.yml.
#
#   /srv/thriden/bin/thriden-scion-down.sh --short <short>
#       host-only teardown, for an orphan whose Mongo doc is already gone
#       (e.g. nuked from the web Danger Zone first — which can't reach the host).
#
# Self-elevates to deploy. Idempotent: anything already gone is a no-op. ALL
# host removal is direct `docker rm` / `docker volume rm` — NOT `docker compose
# rm`, which silently no-ops when run without the decrypted compose env (the
# bug that left containers orphaned). Operator-side leftover: if you used the
# opt-in per-Scion SOPS overlay, `sops unset` its entries (the default
# Mongo-sourced flow has none).
#
# Overridable via THRIDEN_STACK_DIR / THRIDEN_DEPLOY_USER / COMPOSE_PROJECT_NAME.
#
set -euo pipefail

STACK_DIR="${THRIDEN_STACK_DIR:-/srv/thriden}"
DEPLOY_USER="${THRIDEN_DEPLOY_USER:-deploy}"
proj="${COMPOSE_PROJECT_NAME:-$(basename "$STACK_DIR")}"

scion_id=""; short=""
case "${1:-}" in
  --short) short="${2:-}" ;;
  "")      echo "usage: $(basename "$0") <scion-id>  |  --short <short>" >&2; exit 2 ;;
  *)       scion_id="$1" ;;
esac
# Reject ids/shorts carrying shell metacharacters before they reach the
# in-container CLI args + the short-derived container/volume names below.
for _v in "$scion_id" "$short"; do
  case "$_v" in
    *[!A-Za-z0-9._-]*)
      echo "ERROR: invalid scion id/short '$_v' (allowed: letters, digits, . _ -)." >&2
      exit 2 ;;
  esac
done

if [ "$(id -un)" != "$DEPLOY_USER" ]; then
  echo ">> elevating to '$DEPLOY_USER' ..." >&2
  exec sudo -u "$DEPLOY_USER" -H "$0" "$@"
fi

cd "$STACK_DIR"
web="${proj}-forge-web-1"

if [ -n "$scion_id" ]; then
  # Resolve the runtime short, then cascade-delete the doc — both via the
  # in-container CLI (forge-web already has MONGO_URI; no sops needed).
  short="$(docker exec "$web" personaforge-admin scion show "$scion_id" 2>/dev/null \
            | sed -n 's/^runtime_short:[[:space:]]*//p' | head -n1)"
  if [ -z "$short" ]; then
    echo "ERROR: '$scion_id' not found in Mongo (or it has no runtime_short)." >&2
    echo "       If its runtime is orphaned (doc already deleted), tear down the" >&2
    echo "       host side by short:  $(basename "$0") --short <short>" >&2
    exit 1
  fi
  echo ">> cascade-deleting $scion_id (short=$short) from Mongo ..." >&2
  docker exec "$web" personaforge-admin scion delete "$scion_id" --cascade --yes 2>&1 \
    | sed 's/^/   /' >&2 || true
fi

[ -n "$short" ] || { echo "ERROR: no runtime short resolved." >&2; exit 1; }

echo ">> removing containers ${proj}-engram-${short}-1 + ${proj}-forge-${short}-1 ..." >&2
docker rm -f "${proj}-engram-${short}-1" "${proj}-forge-${short}-1" 2>/dev/null \
  | sed 's/^/   removed /' >&2 || true

echo ">> removing volumes ${proj}_${short}-data + ${proj}_${short}-workspace ..." >&2
for v in "${proj}_${short}-data" "${proj}_${short}-workspace"; do
  if docker volume inspect "$v" >/dev/null 2>&1; then
    docker volume rm "$v" >/dev/null && echo "   removed volume $v" >&2
  fi
done

if [ -f "compose-${short}.yml" ]; then
  rm -f "compose-${short}.yml" && echo ">> removed $STACK_DIR/compose-${short}.yml" >&2
fi

echo ">> teardown of '${scion_id:-$short}' complete." >&2
