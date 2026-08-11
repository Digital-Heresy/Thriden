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
#     transition, and only ONCE per payload — see the STALE_AFTER_MIN note);
#   - the deployable check + swap/smoke/rollback is the wrapper's;
#   - the wrapper's atomic `pending -> in_progress` claim is the race guard and
#     stays UNCHANGED — once claimed a payload leaves the `pending` set, so it
#     cannot be re-dispatched.
# This script only bridges container->host via Mongo. Serial (flock).
#
# Exit 0 always on "nothing to do" so the systemd timer stays green; exit 1
# is informational (a wrapper failure this cycle). A POST-claim wrapper failure
# is recorded by the wrapper itself (status + logs + failure_kind); a PRE-claim
# failure leaves the doc untouched, so the dispatcher stamps dispatch_error /
# dispatch_error_at onto the still-pending doc so it's operator-visible without
# journalctl ().
#
# Bean:    (parent );  (pre-claim trace)
# Design: docs/design-upgrade-at-wake.md § Resolved boundary (host dispatcher)
# Seam:   schemas/deploy-payload-mongo.schema.json
#         (dispatch_scion, dispatch_ready_at, dispatch_error, dispatch_error_at)
set -euo pipefail

STACK_DIR="${THRIDEN_STACK_DIR:-/srv/thriden}"
BASE_COMPOSE=(docker compose -f docker-compose.yml -f compose.prod.yml)
# A dispatch signal older than this is treated as stale and skipped — defends
# against acting on a payload whose torpor window has long passed (the Scion
# may be awake again).
#
# ⚠ THERE IS CURRENTLY NO RECOVERY FROM A STALE SIGNAL ().
# This comment used to end "PF refreshes the signal each sleep cycle", which is
# FALSE and was load-bearing: it made the skip below look safe. PF arms only
# payloads where `dispatch_ready_at` does NOT exist
# (forge/core/scheduler.py — the query and the guarded update both assert
# `{"$exists": False}`), and nothing in either repo ever clears the field. So a
# payload armed and then missed for STALE_AFTER_MIN is stuck PERMANENTLY:
# PF will not re-arm it, this dispatcher will not act on it, its status stays
# `pending` forever, and no dispatch_error is stamped — the wrapper never ran,
# so there is nothing to record it. The operator sees an upgrade that is
# eternally "scheduled".
#
# Any 2h window with no dispatcher run does it: timer disabled, host suspended
# overnight, docker down, a wedged run holding the flock. Overnight is exactly
# when upgrade-at-wake intends to deploy.
#
# The real fix is PF-side (re-arm when the signal is absent OR stale). Do NOT
# "fix" it here by widening or removing the staleness guard — the guard is
# correct and is what stops a deploy landing on an awake Scion.
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

# ── Mongo helpers ──────────────────────────────────────────────────────────
# 5hxi injection-safety: values cross into the container as env vars, never
# embedded in JS source. The script runs via `mongosh --eval` (NOT piped to
# stdin) -- piping a multi-line script makes mongosh echo a `personaforge>`
# prompt before each printed line, which corrupts the parsed output.
mongo_eval() {
  # $1 = JS body; remaining args = extra "KEY=VALUE" env pairs forwarded in.
  local script="$1"; shift
  local env_flags=(-e "MONGO_QUERY_JS=$script") kv
  for kv in "$@"; do env_flags+=(-e "$kv"); done
  "${BASE_COMPOSE[@]}" exec -T "${env_flags[@]}" mongodb \
    sh -c 'mongosh "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/personaforge?authSource=admin" --quiet --eval "$MONGO_QUERY_JS"'
}

payload_status() {
  # Prints the doc's current status, or empty on read failure / missing doc.
  mongo_eval 'const d = db.deploy_payloads.findOne({_id: new ObjectId(process.env.MONGO_QUERY_OID)}, {status: 1}); print(d ? d.status : "");' \
    "MONGO_QUERY_OID=$1" 2>/dev/null | tr -d '[:space:]' || true
}

stamp_dispatch_error() {
  # Record an operator-visible pre-claim failure on the still-pending doc
  # (). $1 = oid, $2 = short reason string.
  mongo_eval 'db.deploy_payloads.updateOne({_id: new ObjectId(process.env.MONGO_QUERY_OID)}, {$set: {dispatch_error: process.env.MONGO_QUERY_ERRMSG, dispatch_error_at: new Date()}});' \
    "MONGO_QUERY_OID=$1" "MONGO_QUERY_ERRMSG=$2" >/dev/null
}

# ── Query Mongo for pending, dispatch-ready payloads for local Scions ──────
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
ready=$(mongo_eval "$dispatch_js" \
  "MONGO_QUERY_SCIONS=$scions_json" \
  "MONGO_QUERY_STALE_MIN=$STALE_AFTER_MIN")

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
  # No -S here: -i mode self-syncs unconditionally (). The
  # wrapper reads the payload's thriden_version pre-claim, checks out that
  # release tag, and re-execs before the atomic claim — so a structural
  # release deploys from a single Forge "schedule" click with no manual
  # pre-pull. The wrapper does the atomic claim; if another runner beat us
  # it exits CLAIM_FAILED, which we treat as benign.
  #
  # Capture the wrapper's combined output (still streamed to our stderr →
  # journalctl) so a PRE-CLAIM failure can be surfaced on the doc.
  wrapper_out=$(mktemp)
  set +e
  "$STACK_DIR/bin/thriden-deploy-payload.sh" -i "$oid" -s "$scion" 2>&1 | tee "$wrapper_out" >&2
  rc=${PIPESTATUS[0]}
  set -e
  if [[ "$rc" -eq 0 ]]; then
    echo "[dispatch] payload $oid completed (see doc for terminal status)" >&2
  else
    rc_any=1
    # Two failure classes. If the wrapper died AFTER the atomic claim the doc
    # already carries status + logs + failure_kind (and a benign CLAIM_FAILED
    # race leaves it in_progress under the winning runner) — nothing to add.
    # If it died BEFORE the claim (host.enc.env resolution, git self-sync to
    # thriden_version, mongo unreachable...) the doc is untouched: status stays
    # pending, no error, no operator notification — the old "status recorded in
    # the payload doc" log line was a lie for this class. Stamp it so Forge can
    # surface "your scheduled upgrade could not start" without journalctl
    # access ().
    status=$(payload_status "$oid")
    if [[ "$status" == "pending" ]]; then
      reason=$(grep -E 'ERROR:' "$wrapper_out" | tail -1 || true)
      [[ -z "$reason" ]] && reason=$(grep -vE '^[[:space:]]*$' "$wrapper_out" | tail -1 || true)
      reason="wrapper exited $rc before claiming: ${reason:-<no output captured>}"
      reason="${reason:0:500}"
      if stamp_dispatch_error "$oid" "$reason"; then
        echo "[dispatch] payload $oid FAILED PRE-CLAIM (still pending); stamped dispatch_error for operator visibility" >&2
      else
        echo "[dispatch] payload $oid failed pre-claim AND could not stamp dispatch_error (mongo unreachable?); see journalctl" >&2
      fi
    else
      echo "[dispatch] wrapper for $oid exited $rc; doc status='${status:-<unreadable>}' (wrapper recorded it)" >&2
    fi
  fi
  rm -f "$wrapper_out"
done <<< "$ready"

exit "$rc_any"
