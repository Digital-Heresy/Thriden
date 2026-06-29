#!/usr/bin/env bash
# thriden-deploy-dispatch.sh — host-side receiver for scheduled upgrade-at-wake
# (, the host half of xluj's wake-path auto-claim).
#
# Why this exists: PF's Scion-side orchestrator runs INSIDE the forge-<scion>
# container and cannot invoke the on-host wrapper (thriden-deploy-payload.sh —
# it needs docker/sops/host paths). The boundary is the Mongo deploy_payloads
# doc. At the /admin/sleep -> /admin/torpor transition PF sets a dispatch signal
# on a still-`pending` payload scoped to this Scion:
#     dispatch_scion     : the Scion short (e.g. "dm")
#     dispatch_ready_at  : Date
# This dispatcher (a systemd timer running as the deploy user) polls for those
# and runs the wrapper, which does the atomic pending->in_progress claim + the
# deploy lifecycle.
#
# Thin by design:
#   - sleep-cycle gating is PF's (it only sets dispatch_ready_at at the sleep
#     transition);
#   - the deployable check + swap/smoke/rollback is the wrapper's;
#   - the wrapper's atomic `pending -> in_progress` claim is the race guard and
#     stays UNCHANGED — once claimed a payload leaves the `pending` set, so it
#     cannot be re-dispatched.
# This script only bridges container->host via Mongo. Serial (flock).
#
# Exit 0 always on "nothing to do" so the systemd timer stays green; exit 1
# is informational (wrapper failure or benign claim race, either way recorded in
# the payload doc).
#
# Bean:    (parent )
# Design: docs/design-upgrade-at-wake.md § Resolved boundary (host dispatcher)
# Seam:   schemas/deploy-payload-mongo.schema.json (dispatch_scion, dispatch_ready_at)
set -euo pipefail

STACK_DIR="${THRIDEN_STACK_DIR:-/srv/thriden}"
BASE_COMPOSE=(docker compose -f docker-compose.yml -f compose.prod.yml)
# A dispatch signal older than this is treated as stale and skipped — defends
# against acting on a payload whose torpor window has long passed (the Scion
# may be awake again). PF refreshes the signal each sleep cycle.
STALE_AFTER_MIN="${THRIDEN_DISPATCH_STALE_AFTER_MIN:-120}"

cd "$STACK_DIR"

for dep in docker jq sops; do
  command -v "$dep" >/dev/null || { echo "ERROR: '$dep' not in PATH" >&2; exit 1; }
done

# ── SOPS self-wrap ─────────────────────────────────────────────────────────
# The mongosh-in-container query below runs `docker compose exec mongodb`, which
# evaluates the compose files — and docker-compose.yml requires MONGO_ROOT_PASSWORD
# (${MONGO_ROOT_PASSWORD:?}). The systemd timer runs this bare (no decrypted
# secrets in the env), so re-exec under sops exec-env to supply the stack tier.
# Guard: on the re-exec MONGO_ROOT_PASSWORD is set, so we fall through (no loop).
STACK_ENV="secrets/prod/stack.enc.env"
if [[ -z "${MONGO_ROOT_PASSWORD:-}" && -f "$STACK_ENV" ]]; then
  exec sops exec-env "$STACK_ENV" "$0"
fi

# ── Single-instance lock (deploy-writable) ─────────────────────────────────
lock="${TMPDIR:-/tmp}/thriden-deploy-dispatch.lock"
exec 9>"$lock"
if ! flock -n 9; then
  echo "[dispatch] another run holds the lock; skipping" >&2
  exit 0
fi

# ── Scions local to this host (the compose drop-ins) ───────────────────────
# Only payloads whose dispatch_scion matches a Scion ON THIS HOST are eligible.
local_scions=()
shopt -s nullglob
for f in compose-*.yml; do
  s="${f#compose-}"; s="${s%.yml}"
  local_scions+=("$s")
done
shopt -u nullglob
if [[ ${#local_scions[@]} -eq 0 ]]; then
  echo "[dispatch] no compose-*.yml drop-ins on this host; nothing to dispatch" >&2
  exit 0
fi

# ── Query Mongo for pending, dispatch-ready payloads for local Scions ──────
# 5hxi injection-safety: the scion list + the script itself cross as env vars,
# never embedded in JS source. The script runs via `mongosh --eval` (NOT piped
# to stdin) -- piping a multi-line script makes mongosh echo a `personaforge>`
# prompt before each printed line, which corrupts the parsed output.
scions_json=$(printf '%s\n' "${local_scions[@]}" | jq -R . | jq -cs .)
read -r -d '' dispatch_js <<'JS' || true
const scions = JSON.parse(process.env.MONGO_QUERY_SCIONS);
const staleMin = parseInt(process.env.MONGO_QUERY_STALE_MIN, 10);
const cutoff = new Date(Date.now() - staleMin * 60 * 1000);
const docs = db.deploy_payloads.find({
  status: "pending",
  dispatch_ready_at: { $exists: true, $gte: cutoff },
  dispatch_scion: { $in: scions }
}).sort({ dispatch_ready_at: 1 }).toArray();
// One line per dispatchable payload: "<_id> <dispatch_scion>"
for (const d of docs) { print(`${d._id.toString()} ${d.dispatch_scion}`); }
JS
ready=$("${BASE_COMPOSE[@]}" exec -T \
  -e MONGO_QUERY_SCIONS="$scions_json" \
  -e MONGO_QUERY_STALE_MIN="$STALE_AFTER_MIN" \
  -e MONGO_QUERY_JS="$dispatch_js" \
  mongodb \
  sh -c 'mongosh "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/personaforge?authSource=admin" --quiet --eval "$MONGO_QUERY_JS"')

if [[ -z "${ready//[$'\n\r\t ']/}" ]]; then
  echo "[dispatch] no pending dispatch-ready payloads for local scions (${local_scions[*]})" >&2
  exit 0
fi

# ── Run the wrapper for each (serial; the wrapper claims + executes) ───────
rc_any=0
while read -r oid scion; do
  [[ -n "$oid" ]] || continue
  if [[ ! "$oid" =~ ^[a-fA-F0-9]{24}$ ]]; then
    echo "[dispatch] skipping malformed _id '$oid'" >&2
    continue
  fi
  echo "[dispatch] dispatching payload $oid for scion '$scion' -> wrapper" >&2
  # No -S here: the wrapper rejects -S in -i mode ("checkout-then-invoke is
  # the host harness's job"). A pre-dispatch git-sync step is deferred to
  # ; for now the operator ensures the tree is current before
  # the dispatch window opens. The wrapper does the atomic claim; if another
  # runner beat us it exits CLAIM_FAILED, which we treat as benign.
  if "$STACK_DIR/bin/thriden-deploy-payload.sh" -i "$oid" -s "$scion"; then
    echo "[dispatch] payload $oid completed (see doc for terminal status)" >&2
  else
    rc=$?
    echo "[dispatch] wrapper for $oid exited $rc (status recorded in the payload doc)" >&2
    rc_any=1
  fi
done <<< "$ready"

exit "$rc_any"
