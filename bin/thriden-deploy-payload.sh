#!/usr/bin/env bash
# Phase 1 of : on-host execution layer for upgrade-at-wake
# payloads. Reads a manifest from a file, executes the full lifecycle
# (pre-flight backup → pin → swap → smoke → promote-or-rollback →
# torpor), writes a result file.
#
# Phase status (see docs/design-upgrade-at-wake.md):
#   - Two manifest sources (Phase 3): `-m <file>` reads from a JSON file
#     and writes status mirror to <file>.result.json; `-i <objectid>`
#     fetches the full doc from Mongo's deploy_payloads collection
#     (claimed atomically pending → in_progress), mirrors status +
#     logs back to the same doc as the wrapper progresses. Either form
#     is required; not both.
#   - /admin/deployable check (Phase 2): pre-flight verifies each
#     running engram-* service reports `deployable: true` via /health.
#     Refuses to proceed if any Scion has flipped its flag to false.
#   - Tier 2 canary smoke (``): post-swap, calls
#     /admin/canary on each engram-* container and verifies the planted
#     canary node round-trips. 404 = soft skip (operator hasn't planted
#     a canary for that Scion, or it went stale); other failures fail
#     the bundle.
#   - Engram-side operations (backup, import, torpor) are skipped with
#     a log entry if no engram-* services are running. This lets pi5-
#     smoke exercise the script with just forge-web/nooscope.
#   - Git self-sync to thriden_version (): -i (Mongo) mode
#     always checks out the payload's release tag before the claim (pre-claim
#     read → checkout → guarded re-exec); -m (file) mode does the same on
#     opt-in via -S. Lets a structural release deploy from one Forge
#     "schedule" click with no manual pre-pull. Leaves HEAD detached at the
#     tag; bin/thriden-upgrade.sh re-attaches to main before its next pull.
#   - Per-Scion drop-in support (2026-07-03, xluj integration bugs #4/#5):
#     compose-<short>.yml drop-ins join the compose file set for
#     discovery/ps/exec, so Scion brains are visible to backup/smoke/torpor;
#     Scion services are RECREATED via bin/thriden-scion-up.sh (re-fetches
#     the Mongo soul binding), never raw `up -d`. The wrapper self-wraps
#     under `sops exec-env` (stack tier) so bare manual file-mode runs see
#     the same env the dispatcher provides. The `forge` component pins both
#     FORGE_VERSION (substrate) and FORGE_RUNTIME_VERSION (Scion runtimes).
#
# The 5hxi injection-safety convention applies: nothing from the
# manifest or CLI args is interpolated into a `sh -c` command string.
# Compose-file paths cross to sops exec-env via env vars; component
# names + image tags cross to docker / sops via argv arrays.
#
# Background: docs/design-upgrade-at-wake.md
# Schema:     schemas/deploy-payload.schema.json
# Bean:        (parent )

set -euo pipefail

# ── CLI ────────────────────────────────────────────────────────────────

manifest=""
mongo_id=""
host_short=""
result_file=""
scion_label=""
do_sync=0

while getopts "m:i:h:r:s:S" opt; do
  case "$opt" in
    m) manifest="$OPTARG" ;;
    i) mongo_id="$OPTARG" ;;
    h) host_short="$OPTARG" ;;
    r) result_file="$OPTARG" ;;
    s) scion_label="$OPTARG" ;;
    S) do_sync=1 ;;
    *) echo "usage: $0 (-m <manifest-file> | -i <mongo-objectid>) [-h <host-short>] [-r <result-file>] [-s <scion-label>] [-S]" >&2; exit 2 ;;
  esac
done

# Resolve our own absolute path ONCE, up front, and re-exec through it instead of
# a bare "$0" ( hardening). The three re-execs below (sops self-wrap,
# -S file sync, -i mongo sync) are sound today — the dispatcher invokes us by
# absolute path and the wrapper never cd's — but `exec "$0"` would silently fail
# if a future refactor added a cd before a re-exec, or if we were invoked by a
# bare relative name from another cwd. BASH_SOURCE[0] is the script's own path
# even after a prior exec munges $0; passing $self (absolute) forward keeps every
# re-exec incarnation pointed at the same on-disk file.
self="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"

# -m and -i are mutually exclusive; exactly one must be set.
if [[ -n "$manifest" && -n "$mongo_id" ]]; then
  echo "ERROR: -m and -i are mutually exclusive (file-based vs Mongo-based manifest)" >&2
  exit 2
fi
if [[ -z "$manifest" && -z "$mongo_id" ]]; then
  echo "ERROR: one of -m <manifest-file> or -i <mongo-objectid> is required" >&2
  exit 2
fi

if [[ -n "$manifest" && ! -f "$manifest" ]]; then
  echo "ERROR: manifest $manifest not found" >&2
  exit 1
fi

# ── Git self-sync to the manifest's thriden_version () ─────
#
# Bring the stack tree to the payload's `thriden_version` BEFORE deploying,
# so a release that changes compose *structure* (new service / env var /
# per-Scion compose / bin script) rides a single Forge "schedule" click
# instead of needing a manual `git pull` first.
#
# Two entry points call git_sync_to_tag + re-exec, both guarded by
# THRIDEN_PAYLOAD_SYNCED so the sync runs exactly once:
#   - File mode (-S, below): thriden_version comes from the manifest file,
#     which is readable with zero machinery, so we sync early (before the
#     sops self-wrap). Opt-in — a dev may want to test a manifest against
#     the current tree without a checkout.
#   - Mongo mode (-i): the wake/production path ALWAYS self-syncs. The
#     target lives in Mongo, so the sync waits until after the sops
#     self-wrap + compose-file set are up (it needs mongosh in the mongodb
#     container), and runs BEFORE the atomic pending→in_progress claim so
#     the pre-claim read can't double-claim and a checkout failure leaves
#     the doc reclaimable (see the -i materialisation block below).
# Either way the checkout rewrites this very script + the compose files
# under the running process, so we `exec` the now-current version rather
# than letting bash read the rest of the lifecycle from bytes that no
# longer exist. Set THRIDEN_PAYLOAD_SYNCED=1 in the env to bypass entirely.

# git_sync_to_tag <tag>: no-op if already exactly at <tag>, else refuse a
# dirty tree, fetch, verify the tag exists, and checkout (detached HEAD at
# the release). Returns non-zero (with a reason on stderr) on any failure;
# callers abort before mutating deploy state, so a bail is always safe.
git_sync_to_tag() {
  local target="$1"
  [[ "$(git describe --tags --exact-match HEAD 2>/dev/null || true)" == "$target" ]] && return 0
  # A deploy host must be pristine -- refuse rather than clobber local work.
  # EXCEPT secrets/: every deploy runs `sops set`/`unset` on
  # secrets/prod/stack.enc.env, and SOPS re-encryption is non-deterministic (a
  # fresh nonce each time), so that file is left git-dirty after ANY deploy —
  # even a clean, fully-unpinned one. Excluding secrets/ from the guard stops
  # that self-inflicted noise from refusing the NEXT hop pre-claim, which bit
  # hosts mid-upgrade (). The guard still protects uncommitted
  # code/compose edits — the operator work it actually exists to defend.
  if ! git diff --quiet -- . ':(exclude)secrets/' \
     || ! git diff --cached --quiet -- . ':(exclude)secrets/'; then
    echo "ERROR: refusing to checkout '$target' over a dirty tree (non-secret changes); resolve local changes first" >&2
    return 1
  fi
  echo "[sync] fetching tags + checking out $target" >&2
  if ! git fetch --tags --quiet; then
    echo "ERROR: git fetch failed; refusing to deploy a possibly-stale tree" >&2
    return 1
  fi
  if ! git rev-parse -q --verify "refs/tags/${target}^{commit}" >/dev/null; then
    echo "ERROR: target tag '$target' not found after fetch" >&2
    return 1
  fi
  if ! git checkout --quiet "$target"; then
    # The only expected block is sops-dirtied secrets/ whose committed blob
    # differs between releases (j248): git refuses to overwrite the locally
    # re-encrypted file. Discarding that working-tree noise is safe — the target
    # tag carries the canonical secret base, and the live version pins are
    # re-applied by the pin step after sync. We touch secrets/ ONLY when the
    # checkout actually conflicts, never pre-emptively.
    echo "[sync] checkout blocked; discarding sops noise under secrets/ and retrying" >&2
    git restore --quiet --worktree --staged -- secrets/ 2>/dev/null \
      || git checkout --quiet -- secrets/ 2>/dev/null || true
    if ! git checkout --quiet "$target"; then
      echo "ERROR: checkout of '$target' failed" >&2
      return 1
    fi
  fi
  return 0
}

# ── min_upgrade_from guardrail () ─────────────────────────
#
# A payload MAY carry `min_upgrade_from` (a thriden-v* tag). Bundles are fully
# encapsulated (exact image pins, no deltas) so any forward jump is
# *installable*, but persisted state (engram WAL/snapshots, PF Mongo docs)
# makes "upgrade from anywhere" a convention, not an enforced contract —
# migrations are release-note warnings + schema_version stamps, and the
# validation gate has only ever exercised single-version (X→X+1) hops. When a
# release truly needs stepping through an intermediate version, it sets
# min_upgrade_from; the wrapper then REFUSES rather than perform the untested
# skip-hop that could corrupt a brain. The contract is MindHive-owned (this
# check + the schema field); PF writes the value into the payload.
#
# "Current umbrella version" = the tree's nearest thriden-v* tag, captured
# ONCE before any cry2 checkout moves the tree to the target (exported so it
# survives the sops-wrap and self-sync re-execs). Only thriden-v* tags count —
# the repo also carries engram `v*` tags, which must not be mistaken for the
# umbrella version.
export THRIDEN_RUN_FROM="${THRIDEN_RUN_FROM:-$(git describe --tags --abbrev=0 --match 'thriden-v*' 2>/dev/null || true)}"

# version_lt <a> <b>: true (0) iff a < b, comparing the X.Y.Z after an optional
# thriden-v prefix (semver order via sort -V).
version_lt() {
  local a="${1#thriden-v}" b="${2#thriden-v}"
  [[ "$a" == "$b" ]] && return 1
  [[ "$(printf '%s\n%s\n' "$a" "$b" | sort -V | head -n1)" == "$a" ]]
}

# enforce_min_upgrade_from <min>: return non-zero (with a reason on stderr) if
# the host's current umbrella version is below <min>. Empty <min> => no floor
# set, allow. Unknown current version => warn + allow (don't block a legit
# deploy on an underivable tag; the release notes + schema_version stamps are
# the backstop). Callers abort before mutating deploy state.
enforce_min_upgrade_from() {
  local min="$1" from="${THRIDEN_RUN_FROM:-}"
  [[ -z "$min" ]] && return 0
  if [[ -z "$from" ]]; then
    echo "WARN: min_upgrade_from=$min set but the host's current umbrella version is unknown (no thriden-v* tag on the tree); allowing the deploy" >&2
    return 0
  fi
  if version_lt "$from" "$min"; then
    echo "ERROR: refusing deploy — host is on $from but this release sets min_upgrade_from=$min. Persisted-state migrations only cover single-version steps; upgrade through the intermediate release(s) first." >&2
    return 1
  fi
  return 0
}

# File mode: enforce the floor up front (before the sops-wrap / any -S
# checkout / any swap). Cheap; re-passes harmlessly on the -S re-exec. In -i
# mode $manifest is still empty here — that path enforces in its own pre-claim
# sync block below, so a refusal surfaces via 7mwy's dispatch_error.
if [[ -n "$manifest" ]] && command -v jq >/dev/null; then
  enforce_min_upgrade_from "$(jq -r '.min_upgrade_from // empty' "$manifest")" || exit 1
fi

if [[ "$do_sync" == 1 && -z "${THRIDEN_PAYLOAD_SYNCED:-}" ]]; then
  if [[ -n "$mongo_id" ]]; then
    echo "ERROR: -S is redundant with -i (Mongo mode self-syncs unconditionally); drop it" >&2
    exit 2
  fi
  for t in git jq; do
    if ! command -v "$t" >/dev/null; then
      echo "ERROR: -S given but '$t' is not in PATH" >&2
      exit 1
    fi
  done
  sync_target=$(jq -r '.thriden_version // empty' "$manifest")
  if [[ -z "$sync_target" ]]; then
    echo "ERROR: -S given but manifest carries no thriden_version to sync to" >&2
    exit 2
  fi
  git_sync_to_tag "$sync_target" || exit 1
  # Re-exec the (now-current) script; guard prevents a sync loop.
  export THRIDEN_PAYLOAD_SYNCED=1
  exec "$self" "$@"
fi
if [[ -n "$mongo_id" && ! "$mongo_id" =~ ^[a-fA-F0-9]{24}$ ]]; then
  echo "ERROR: -i value '$mongo_id' is not a valid Mongo ObjectId (24 hex chars)" >&2
  exit 2
fi

# Phase 3 Mongo mode uses mongosh inside the mongodb container; file mode
# doesn't need it. Validate accordingly.
required_deps=(jq sops docker curl)
for dep in "${required_deps[@]}"; do
  if ! command -v "$dep" >/dev/null; then
    echo "ERROR: required tool '$dep' not in PATH" >&2
    exit 1
  fi
done

# shellcheck source=bin/thriden-host-short.lib.sh
. "$(dirname "$0")/thriden-host-short.lib.sh"
host_short="$(thriden_resolve_host_short "$host_short")"

host_env="secrets/prod/hosts/${host_short}/host.enc.env"
stack_env="secrets/prod/stack.enc.env"

for f in "$host_env" "$stack_env"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

# ── SOPS self-wrap (matches dispatcher/setup) ──────────────────────────
# Every docker compose call below evaluates the compose graph, which needs
# stack-tier vars (${MONGO_ROOT_PASSWORD:?} in docker-compose.yml). A manual
# file-mode run invoked bare would otherwise see EMPTY service discovery —
# the `ps --services 2>/dev/null` calls swallow the interpolation error and
# the wrapper refuses with "match no running compose services" (xluj
# integration bug #4, hit on the first Cairn brain-swap attempt). The
# dispatcher path never noticed: it self-wraps before invoking us. Re-exec
# under sops exec-env; the guard falls through on the re-exec. Args here are
# simple tokens (ObjectIds, paths, shorts), safe for %q re-quoting into the
# single command string sops exec-env expects.
if [[ -z "${MONGO_ROOT_PASSWORD:-}" ]]; then
  exec sops exec-env "$stack_env" "$(printf '%q ' "$self" "$@")"
fi

# ── Compose file set: base + prod + per-Scion drop-ins ─────────────────
# Per-Scion services (engram-<short>/forge-<short>) live in compose-<short>.yml
# drop-ins and are invisible to a base+prod-only file set (xluj integration
# gap #5: the wrapper could never discover, smoke, back up, or torpor a Scion
# brain — every prior validation ran against substrate services only). The
# drop-ins join the file set for discovery/exec/ps; RECREATION of Scion
# services is delegated to bin/thriden-scion-up.sh (which re-fetches the
# soul/raven binding from Mongo) — a raw `up -d` would boot them UNBOUND and
# trip the Scion-death guard on the next boot.
compose_files=(-f docker-compose.yml -f compose.prod.yml)
scion_shorts=()
shopt -s nullglob
for _f in compose-*.yml; do
  compose_files+=(-f "$_f")
  _s="${_f#compose-}"
  scion_shorts+=("${_s%.yml}")
done
shopt -u nullglob
compose_files_q="${compose_files[*]@Q}"
proj="${COMPOSE_PROJECT_NAME:-$(basename "$PWD")}"

is_scion_service() {
  local svc="$1" s
  for s in "${scion_shorts[@]}"; do
    [[ "$svc" == "engram-$s" || "$svc" == "forge-$s" ]] && return 0
  done
  return 1
}

# Mongo mode: payload manifest lives in Mongo (set by Forge). Fetch + claim
# atomically, materialise to a temp file for the rest of the wrapper to use,
# and set MONGO_PAYLOAD_ID so the log/set_result_field/finalize helpers
# mirror state changes back to the same doc.
MONGO_PAYLOAD_ID=""
mongo_manifest_tmp=""
if [[ -n "$mongo_id" ]]; then
  MONGO_PAYLOAD_ID="$mongo_id"
  # scion label defaults to the host short name in Mongo mode; the Scion-side
  # orchestrator (PF) will normally pass an explicit one via -s when it
  # invokes the wrapper from inside its forge-<scion> container.
  [[ -z "$scion_label" ]] && scion_label="$host_short"
fi

# Default result file path: alongside the input manifest (file mode), or a
# fixed location based on the Mongo ObjectId (mongo mode). The result file
# is always written -- it's a local operator-readable copy of the status
# the wrapper would (also) push back to Mongo.
if [[ -z "$result_file" ]]; then
  if [[ -n "$manifest" ]]; then
    result_file="${manifest%.json}.result.json"
  else
    result_file="/srv/thriden/payloads/${mongo_id}.result.json"
    mkdir -p "$(dirname "$result_file")"
  fi
fi

# ── Mongo helpers (Phase 3) ────────────────────────────────────────────
#
# All mongosh calls go through a single execution pattern: run mongosh
# inside the mongodb container, pass operator/manifest values via
# additional `-e VAR=value` flags to docker compose exec, and read them
# inside the script via process.env. Script bodies are single-quoted
# heredocs on the OUTER bash so $ signs don't get interpolated; sh -c on
# the INNER container uses double quotes so $MONGO_INITDB_ROOT_* expand
# to the credentials the mongo image set at init time. Operator values
# cross via env (typed inside JS via JSON.parse / new ObjectId) so the
# 5hxi injection-safety property holds end-to-end -- no operator string
# is ever embedded directly in JS source.
#
# Database: `personaforge` (where PF writes payloads).
# Collection: `deploy_payloads` (validated per
#   schemas/deploy-payload-mongo.schema.json).

mongo_eval() {
  # $1 = script body. Caller exports MONGO_QUERY_* env vars before
  # invoking; we forward them into the container so the script can read
  # via process.env. The script itself crosses as MONGO_QUERY_JS and runs
  # via `mongosh --eval` -- NOT piped to stdin: piping a multi-line script
  # makes mongosh echo a `personaforge>` prompt before each printed line,
  # which corrupts EJSON/line output the callers parse.
  local script="$1"
  local env_flags=(-e "MONGO_QUERY_JS=$script")
  while IFS='=' read -r -d $'\0' line; do
    name="${line%%=*}"
    [[ "$name" == MONGO_QUERY_* && "$name" != MONGO_QUERY_JS ]] && env_flags+=(-e "$line")
  done < <(env -0)

  docker compose "${compose_files[@]}" exec -T \
    "${env_flags[@]}" mongodb \
    sh -c 'mongosh "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/personaforge?authSource=admin" --quiet --eval "$MONGO_QUERY_JS"'
}

mongo_read_thriden_version() {
  # Pure read (no status filter, no mutation) so it works on a still-pending
  # doc and CANNOT claim it — this runs before the atomic claim during the
  # -i self-sync (). Prints the bare thriden_version, or empty.
  mongo_eval "$(cat <<'JS'
const _id = process.env.MONGO_QUERY_PAYLOAD_ID;
const doc = db.deploy_payloads.findOne({_id: new ObjectId(_id)}, {thriden_version: 1});
print(doc && doc.thriden_version ? doc.thriden_version : "");
JS
)"
}

mongo_read_min_upgrade_from() {
  # Pure read (same pre-claim contract as mongo_read_thriden_version) for the
  # optional min_upgrade_from floor (). Prints the bare value, or
  # empty when the payload sets no floor.
  mongo_eval "$(cat <<'JS'
const _id = process.env.MONGO_QUERY_PAYLOAD_ID;
const doc = db.deploy_payloads.findOne({_id: new ObjectId(_id)}, {min_upgrade_from: 1});
print(doc && doc.min_upgrade_from ? doc.min_upgrade_from : "");
JS
)"
}

mongo_claim_payload() {
  mongo_eval "$(cat <<'JS'
const _id = process.env.MONGO_QUERY_PAYLOAD_ID;
const scion = process.env.MONGO_QUERY_SCION;
const now = new Date();
const result = db.deploy_payloads.findOneAndUpdate(
  {_id: new ObjectId(_id), status: "pending"},
  {$set: {status: "in_progress", claimed_by_scion: scion, triggered_at: now}},
  {returnDocument: "after"}
);
if (!result) {
  const current = db.deploy_payloads.findOne({_id: new ObjectId(_id)});
  const status_now = current ? current.status : "(missing)";
  print(`CLAIM_FAILED status=${status_now}`);
  quit(1);
}
print(EJSON.stringify(result));
JS
)"
}

mongo_set_field() {
  # MONGO_QUERY_PATH = top-level field name; MONGO_QUERY_VALUE = JSON-
  # encoded value. Always overwrites (idempotent).
  mongo_eval "$(cat <<'JS'
const _id = process.env.MONGO_QUERY_PAYLOAD_ID;
const path = process.env.MONGO_QUERY_PATH;
const value = JSON.parse(process.env.MONGO_QUERY_VALUE);
const update = {$set: {}};
update.$set[path] = value;
db.deploy_payloads.updateOne({_id: new ObjectId(_id)}, update);
JS
)" >/dev/null
}

mongo_append_log() {
  # MONGO_QUERY_LOG_ENTRY = JSON-encoded {ts, level, msg}.
  mongo_eval "$(cat <<'JS'
const _id = process.env.MONGO_QUERY_PAYLOAD_ID;
const entry = JSON.parse(process.env.MONGO_QUERY_LOG_ENTRY);
db.deploy_payloads.updateOne({_id: new ObjectId(_id)}, {$push: {logs: entry}});
JS
)" >/dev/null
}

mongo_finalize() {
  # MONGO_QUERY_STATUS = succeeded / rolled_back / failed / in_progress.
  # in_progress is the wrapper-crashed marker; doc stays for manual review.
  mongo_eval "$(cat <<'JS'
const _id = process.env.MONGO_QUERY_PAYLOAD_ID;
const status = process.env.MONGO_QUERY_STATUS;
const now = new Date();
db.deploy_payloads.updateOne(
  {_id: new ObjectId(_id)},
  {$set: {status: status, completed_at: now}}
);
JS
)" >/dev/null
}

# ── Manifest materialisation ───────────────────────────────────────────

if [[ -n "$mongo_id" ]]; then
  # Self-sync the tree to the payload's thriden_version BEFORE the claim
  # (). We're now past the sops self-wrap + compose-file set,
  # so mongosh is reachable; the read is non-mutating (mongo_read_thriden_version
  # uses findOne, no status filter) so it can't claim the doc. On checkout
  # failure we exit before the atomic claim, leaving the doc pending and
  # reclaimable next window. The checkout rewrites this script under us, so
  # re-exec (guarded) to run the lifecycle — including the claim — from the
  # release's own bytes. THRIDEN_PAYLOAD_SYNCED=1 bypasses (dev/test) — note
  # this also skips the min_upgrade_from floor below, since the check lives in
  # this pre-claim block. Production never presets it (the dispatcher invokes
  # -i bare; the floor runs on the first pass before the wrapper self-sets it
  # on re-exec), so only a manual override loses the floor.
  if [[ -z "${THRIDEN_PAYLOAD_SYNCED:-}" ]]; then
    if ! command -v git >/dev/null; then
      echo "ERROR: -i self-sync needs 'git' in PATH" >&2
      exit 1
    fi
    export MONGO_QUERY_PAYLOAD_ID="$mongo_id"
    sync_target=$(mongo_read_thriden_version | tr -d '[:space:]')
    if [[ -z "$sync_target" ]]; then
      echo "ERROR: payload $mongo_id carries no thriden_version to sync to (doc left pending, reclaimable)" >&2
      exit 1
    fi
    # min_upgrade_from floor (), pre-claim + pre-checkout: refuse a
    # skip-hop BEFORE claiming or moving the tree. A non-zero exit here leaves
    # the doc pending, so the dispatcher stamps dispatch_error ()
    # and the operator sees why the scheduled upgrade won't start.
    enforce_min_upgrade_from "$(mongo_read_min_upgrade_from | tr -d '[:space:]')" \
      || { echo "ERROR: payload $mongo_id refused by min_upgrade_from floor; doc left pending" >&2; exit 1; }
    git_sync_to_tag "$sync_target" || { echo "ERROR: self-sync failed; payload $mongo_id left pending, reclaimable" >&2; exit 1; }
    export THRIDEN_PAYLOAD_SYNCED=1
    exec "$self" "$@"
  fi

  # Fetch + claim from Mongo. Write the input-shape subdoc out to a temp
  # file so the rest of the wrapper (which expects $manifest to be a JSON
  # file path) works unchanged.
  mongo_manifest_tmp=$(mktemp /tmp/thriden-payload-manifest.XXXXXX.json)
  trap 'rm -f "$mongo_manifest_tmp"' EXIT

  export MONGO_QUERY_PAYLOAD_ID="$mongo_id"
  export MONGO_QUERY_SCION="$scion_label"

  echo "[mongo] claiming payload $mongo_id for scion $scion_label" >&2
  claim_output=$(mongo_claim_payload 2>&1) || {
    echo "ERROR: $claim_output" >&2
    echo "  (a payload not in 'pending' status cannot be claimed -- check status via mongosh or re-run after cancelling)" >&2
    exit 1
  }

  echo "$claim_output" \
    | jq '{thriden_version: .thriden_version, components: .components, ordering: .ordering, smoke_tier_overrides: .smoke_tier_overrides}' \
    > "$mongo_manifest_tmp"
  manifest="$mongo_manifest_tmp"
fi

# Manifest ID: stable per file invocation. Used in backup filenames.
manifest_id=$(jq -r '.thriden_version' "$manifest" | tr -c 'A-Za-z0-9._-' '-')
run_id="$(date -u +%Y%m%dT%H%M%SZ)-${manifest_id}"

# ── Result file ────────────────────────────────────────────────────────

# Initialize the result file. Atomic append-via-jq throughout the run.
# In Mongo mode this is a local mirror; the source of truth is the Mongo
# doc, and helpers below push state changes there too when
# MONGO_PAYLOAD_ID is set.
jq -n \
  --arg started_at "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
  --arg run_id "$run_id" \
  --slurpfile manifest "$manifest" \
  '{
    run_id: $run_id,
    manifest: $manifest[0],
    started_at: $started_at,
    status: "in_progress",
    logs: []
  }' > "$result_file"

log() {
  local level="$1"; shift
  local msg="$*"
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "[$ts] [$level] $msg" >&2
  local tmp
  tmp=$(mktemp)
  jq --arg ts "$ts" --arg level "$level" --arg msg "$msg" \
    '.logs += [{ts: $ts, level: $level, msg: $msg}]' "$result_file" > "$tmp"
  mv "$tmp" "$result_file"

  # Mirror to Mongo. Best-effort: if mongo is unreachable mid-run we
  # don't want to crash the wrapper just because a log line couldn't be
  # appended; the local result file is still authoritative for the
  # operator-readable record.
  if [[ -n "$MONGO_PAYLOAD_ID" ]]; then
    local entry
    entry=$(jq -nc --arg ts "$ts" --arg level "$level" --arg msg "$msg" \
      '{ts: $ts, level: $level, msg: $msg}')
    MONGO_QUERY_PAYLOAD_ID="$MONGO_PAYLOAD_ID" \
    MONGO_QUERY_LOG_ENTRY="$entry" \
      mongo_append_log 2>/dev/null || true
  fi
}

finalize() {
  local final_status="$1"
  local tmp
  tmp=$(mktemp)
  jq --arg s "$final_status" --arg c "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    '.status = $s | .completed_at = $c' "$result_file" > "$tmp"
  mv "$tmp" "$result_file"

  if [[ -n "$MONGO_PAYLOAD_ID" ]]; then
    MONGO_QUERY_PAYLOAD_ID="$MONGO_PAYLOAD_ID" \
    MONGO_QUERY_STATUS="$final_status" \
      mongo_finalize 2>/dev/null || \
      echo "[mongo] WARN: finalize push to Mongo failed; local result file is authoritative" >&2
  fi
}

set_result_field() {
  local path="$1"
  local value="$2"
  local tmp
  tmp=$(mktemp)
  jq --argjson v "$value" "$path = \$v" "$result_file" > "$tmp"
  mv "$tmp" "$result_file"

  if [[ -n "$MONGO_PAYLOAD_ID" ]]; then
    # path comes in as ".foo" -- strip the leading dot for Mongo's
    # dotted-path field name. Nested paths (.a.b) survive intact.
    local mongo_path="${path#.}"
    MONGO_QUERY_PAYLOAD_ID="$MONGO_PAYLOAD_ID" \
    MONGO_QUERY_PATH="$mongo_path" \
    MONGO_QUERY_VALUE="$value" \
      mongo_set_field 2>/dev/null || \
      echo "[mongo] WARN: set_field $mongo_path push to Mongo failed; local result file is authoritative" >&2
  fi
}

trap 'rc=$?; if [[ $rc -ne 0 ]]; then log error "wrapper exited with code $rc; status left as in_progress for manual review"; set_result_field .failure_kind "\"wrapper_error\""; finalize in_progress; fi; [[ -n "$mongo_manifest_tmp" ]] && rm -f "$mongo_manifest_tmp"' EXIT

log info "wrapper started; manifest=$(realpath "$manifest"); run_id=$run_id"

# ── Manifest parsing ───────────────────────────────────────────────────

components=()
while IFS= read -r c; do components+=("$c"); done < <(jq -r '.ordering[]' "$manifest")

declare -A new_tag
for c in "${components[@]}"; do
  new_tag[$c]=$(jq -r --arg c "$c" '.components[$c]' "$manifest")
  if [[ "${new_tag[$c]}" == "null" || -z "${new_tag[$c]}" ]]; then
    log error "manifest 'components' missing entry for ordering component '$c'"
    finalize failed
    exit 1
  fi
done

log info "components in order: ${components[*]}"

# Map logical component → compose env var(s), one per line. `forge` pins BOTH
# the substrate (forge-web, FORGE_VERSION) and the Scion runtimes
# (forge-<short>, FORGE_RUNTIME_VERSION): the manifest is authoritative for a
# scheduled deploy, and pinning only the substrate var would leave runtimes on
# whatever the tree's deploy/versions.env happens to say (the thriden-v0.9.0
# recipe-skew class of bug).
env_vars_for() {
  case "$1" in
    engram)   echo ENGRAM_VERSION ;;
    forge)    printf '%s\n' FORGE_VERSION FORGE_RUNTIME_VERSION ;;
    nooscope) echo NOOSCOPE_VERSION ;;
    *) return 1 ;;
  esac
}

# Map logical component → compose service names (glob expanded later)
compose_services_for() {
  case "$1" in
    engram)   docker compose "${compose_files[@]}" ps --services 2>/dev/null | grep -E '^engram(-.+)?$' || true ;;
    forge)    docker compose "${compose_files[@]}" ps --services 2>/dev/null | grep -E '^forge(-.+)?$' || true ;;
    nooscope) echo nooscope ;;
  esac
}

smoke_tier_for() {
  local default=1
  if [[ "$1" == "engram" ]]; then default=2; fi
  jq -r --arg c "$1" --argjson d "$default" '.smoke_tier_overrides[$c] // $d' "$manifest"
}

# ── Pre-flight backup (engram only) ────────────────────────────────────

backup_dir_root="/srv/thriden/backups"
[[ -d "$backup_dir_root" ]] || mkdir -p "$backup_dir_root"

engram_services=()
while IFS= read -r s; do [[ -n "$s" ]] && engram_services+=("$s"); done < <(compose_services_for engram)

if [[ ${#engram_services[@]} -eq 0 ]]; then
  log info "no running engram-* services; pre-flight backup + deployable check + post-deploy torpor steps will be skipped"
else
  # Phase 2 deployable gate: refuse to proceed if any Scion has flipped
  # deployable: false (long consolidation, mid-cycle work). See
  # docs/design-upgrade-at-wake.md "Sleep-cycle alignment".
  for svc in "${engram_services[@]}"; do
    health_json=$(docker compose "${compose_files[@]}" exec -T "$svc" \
      sh -c 'curl -fsS http://localhost:3030/health' 2>/dev/null || echo '{}')
    deployable=$(echo "$health_json" | jq -r '.deployable // "unknown"')
    if [[ "$deployable" == "false" ]]; then
      log error "$svc reports deployable: false -- refusing to proceed"
      log error "this typically means the Scion is in a long consolidation or mid-cycle operation"
      log error "wait for the next sleep cycle's natural settle, then retry"
      set_result_field '.failure_kind' '"wrapper_error"'
      finalize failed
      exit 1
    elif [[ "$deployable" == "unknown" ]]; then
      log warn "$svc /health returned no deployable field (older engram?); proceeding without the gate"
    else
      log info "$svc deployable: true"
    fi
  done

  log info "engram services to back up: ${engram_services[*]}"
  declare -A backup_path
  for svc in "${engram_services[@]}"; do
    scion="${svc#engram-}"
    [[ "$scion" == "$svc" ]] && scion="default"
    sdir="${backup_dir_root}/${scion}"
    mkdir -p "$sdir"

    # Prune: keep most recent 7 OR within 30d, whichever yields more
    mapfile -t all < <(ls -1t "$sdir"/*.json 2>/dev/null || true)
    keep_count=7
    keep_days=30
    cutoff=$(date -u -d "$keep_days days ago" +%s 2>/dev/null || date -u -v-${keep_days}d +%s)
    keep=()
    for f in "${all[@]:0:$keep_count}"; do keep+=("$f"); done
    for f in "${all[@]:$keep_count}"; do
      mtime=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f")
      if (( mtime >= cutoff )); then keep+=("$f"); fi
    done
    for f in "${all[@]}"; do
      keep_this=false
      for k in "${keep[@]}"; do [[ "$f" == "$k" ]] && keep_this=true && break; done
      $keep_this || rm -f "$f"
    done

    out="${sdir}/${run_id}.json"
    log info "exporting $svc → $out"
    # /admin/export needs ENGRAM_RAVEN_TOKEN. Pull it from the
    # container's own env via docker exec, so we don't need to thread
    # secrets through the wrapper.
    if docker compose "${compose_files[@]}" exec -T "$svc" \
         sh -c 'curl -fsS -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" http://localhost:3030/admin/export' \
         > "$out" 2>/dev/null; then
      backup_path[$scion]="$out"
      log info "backup saved for $scion ($(stat -c %s "$out" 2>/dev/null || stat -f %z "$out") bytes)"
    else
      log error "pre-flight export failed for $svc"
      finalize failed
      exit 1
    fi
  done

  # Construct .pre_flight_backups: {scion: path, ...}
  backups_json="{}"
  for s in "${!backup_path[@]}"; do
    backups_json=$(echo "$backups_json" | jq --arg k "$s" --arg v "${backup_path[$s]}" '. + {($k): $v}')
  done
  set_result_field '.pre_flight_backups' "$backups_json"
fi

# ── Pin step: sops set per component ───────────────────────────────────

# Collect the compose service names we'll be operating on FIRST — the
# running-tag revert capture below needs to know which containers represent
# each env var. Split by class: substrate services go through `up -d`;
# Scion services (engram-<short> / forge-<short> from a drop-in) go through
# scion-up, which re-fetches the soul binding before recreate.
swap_services=()
scion_swap_shorts=()
for c in "${components[@]}"; do
  while IFS= read -r s; do
    [[ -n "$s" ]] || continue
    if is_scion_service "$s"; then
      short="${s#engram-}"
      short="${short#forge-}"
      case " ${scion_swap_shorts[*]-} " in
        *" $short "*) ;;
        *) scion_swap_shorts+=("$short") ;;
      esac
    else
      case " ${swap_services[*]-} " in
        *" $s "*) ;;
        *) swap_services+=("$s") ;;
      esac
    fi
  done < <(compose_services_for "$c")
done

# Runs pre-pin now, so a refusal needs no revert.
if [[ ${#swap_services[@]} -eq 0 && ${#scion_swap_shorts[@]} -eq 0 ]]; then
  log error "manifest components [${components[*]}] match no running compose services on this host"
  log error "refusing to proceed -- without an explicit swap target list, 'docker compose up -d' would recreate every service in the stack"
  log error "check that the expected services (e.g. engram-<short>, forge-<short>) are running, or correct the manifest"
  set_result_field '.failure_kind' '"wrapper_error"'
  finalize failed
  exit 1
fi

# Map env var → the running container that carries its CURRENT tag. This is
# the TRUE revert target (): on a post-tpo4 host the env
# override is usually unset, and by the time the wrapper runs the tree's
# deploy/versions.env already carries the NEW release — so "revert to the
# pre-pin env value" would materially re-deploy the new version. What the
# host was actually running is the only honest rollback destination.
running_tag_for_var() {
  local var="$1" cname="" s img
  case "$var" in
    ENGRAM_VERSION)
      for s in "${scion_swap_shorts[@]}"; do
        if docker inspect "${proj}-engram-${s}-1" >/dev/null 2>&1; then
          cname="${proj}-engram-${s}-1"; break
        fi
      done ;;
    FORGE_RUNTIME_VERSION)
      for s in "${scion_swap_shorts[@]}"; do
        if docker inspect "${proj}-forge-${s}-1" >/dev/null 2>&1; then
          cname="${proj}-forge-${s}-1"; break
        fi
      done ;;
    FORGE_VERSION)    cname="${proj}-forge-web-1" ;;
    NOOSCOPE_VERSION) cname="${proj}-nooscope-1" ;;
  esac
  [[ -n "$cname" ]] || return 0
  img=$(docker inspect "$cname" --format '{{.Config.Image}}' 2>/dev/null) || return 0
  [[ "$img" == *:* ]] || return 0
  printf '%s' "${img##*:}"
}

declare -A original_tag   # keyed by env var name; EFFECTIVE original: the
                          # pre-pin env override if set, else the running
                          # container's image tag (2wg6 true-revert target)
declare -A original_src   # env | running | none — for honest logging
declare -A pin_tag
pin_vars=()
log info "capturing revert targets before pin (env override, else running-container tag)"
for c in "${components[@]}"; do
  vars=$(env_vars_for "$c") || { log error "no env var mapping for component '$c'"; finalize failed; exit 1; }
  while IFS= read -r var; do
    [[ -n "$var" ]] || continue
    pin_vars+=("$var")
    pin_tag[$var]="${new_tag[$c]}"
    # Decrypt to inspect current value (in-memory only via process substitution)
    original_tag[$var]=$(sops -d --extract "[\"$var\"]" --output-type dotenv "$stack_env" 2>/dev/null \
      | grep "^${var}=" | cut -d= -f2- || echo "")
    if [[ -n "${original_tag[$var]}" ]]; then
      original_src[$var]="env"
    else
      original_tag[$var]="$(running_tag_for_var "$var")"
      if [[ -n "${original_tag[$var]}" ]]; then
        original_src[$var]="running"
      else
        original_src[$var]="none"
      fi
    fi
    log info "  $c: $var=${original_tag[$var]:-<none>} (${original_src[$var]}) → ${new_tag[$c]}"
  done <<< "$vars"
done

# Make the pin set visible in the result doc + logs. The 2026-07-06 Cairn
# v0.10.0 rollback left forge-dm stranded on the new version because
# FORGE_RUNTIME_VERSION never entered the pin/revert accounting for that run —
# and nothing logged its absence, so the split was invisible until an operator
# eyeballed `docker ps`. Log the resolved pin set so a missing scion var is
# caught immediately next time ().
log info "pin set: ${pin_vars[*]}"

# Belt-and-suspenders scion runtime/brain revert target (). The
# per-Scion runtime (forge-<short>) and brain (engram-<short>) are (re)rendered
# by bin/thriden-scion-up.sh, which sources deploy/versions.env — the TREE
# recipe — on every recreate. That export wins over any pin the generic loop
# above missed, so on a rollback scion-up drags the runtime back to the new
# release (exactly what stranded forge-dm on v0.12.0). Capture the pre-deploy
# scion tags directly here and force-pin them on revert so stack.enc.env (which
# scion-up's `sops exec-env "$SECRETS"` layers ON TOP of versions.env)
# authoritatively holds the runtime/brain at their pre-deploy versions, whatever
# the generic loop did. NOTE: FORGE_RUNTIME_VERSION / ENGRAM_VERSION are single
# vars shared across all in-scope scions; running_tag_for_var picks the first
# scion's container, so a heterogeneous-version fleet reverts all in-scope
# scions to that one tag (a pre-existing single-var-design limitation).
declare -A scion_pre_tag
if (( ${#scion_swap_shorts[@]} > 0 )); then
  for _v in FORGE_RUNTIME_VERSION ENGRAM_VERSION; do
    _t=$(running_tag_for_var "$_v")
    [[ -n "$_t" ]] && scion_pre_tag[$_v]="$_t"
  done
  # Self-diagnosing: scions are in scope, so running_tag_for_var MUST resolve at
  # least the forge runtime tag from a running forge-<short>. An empty result
  # means the revert force-pin below will silently no-op and the runtime could
  # strand again — the exact blind spot this fix exists to close — so make it
  # loud rather than trusting it worked (ru4g review follow-up).
  if (( ${#scion_pre_tag[@]} == 0 )); then
    log warn "ru4g: scion(s) in scope [${scion_swap_shorts[*]}] but captured NO pre-deploy runtime/brain tag — running_tag_for_var found no forge-<short>/engram-<short> container; rollback CANNOT hold the scion runtime down, manual review if this deploy reverts"
  else
    log info "scion runtime/brain pre-deploy tags: $(for k in "${!scion_pre_tag[@]}"; do printf '%s=%s ' "$k" "${scion_pre_tag[$k]}"; done)"
  fi
fi

# Save originals into result file so a re-run knows what to revert to
originals_json='{}'
for var in "${pin_vars[@]}"; do
  originals_json=$(echo "$originals_json" | jq --arg k "$var" --arg v "${original_tag[$var]}" '. + {($k): $v}')
done
set_result_field '.original_tags' "$originals_json"

log info "pinning new tags via sops set"
for var in "${pin_vars[@]}"; do
  sops set "$stack_env" "[\"$var\"]" "\"${pin_tag[$var]}\""
  log info "  pinned $var=${pin_tag[$var]}"
done

# ── Swap ───────────────────────────────────────────────────────────────

revert_pins() {
  log info "reverting tag pins"
  local var orig
  for var in "${pin_vars[@]}"; do
    orig="${original_tag[$var]}"
    case "${original_src[$var]}" in
      env)
        sops set "$stack_env" "[\"$var\"]" "\"$orig\""
        log info "  restored $var=$orig (pre-deploy override)"
        ;;
      running)
        sops set "$stack_env" "[\"$var\"]" "\"$orig\""
        log info "  pinned $var=$orig (running-container revert target; DELIBERATE shadow over deploy/versions.env — this host is intentionally NOT on the release the tree carries; clears on the next successful upgrade)"
        ;;
      *)
        if sops unset "$stack_env" "[\"$var\"]" >/dev/null 2>&1; then
          log info "  removed $var pin (no revert target known; deploy/versions.env resumes ownership)"
        else
          log warn "  $var had no revert target and sops unset failed/unavailable; leaving pinned (manual review recommended)"
        fi
        ;;
    esac
  done
  # : unconditionally pin the scion runtime/brain vars to their
  # captured pre-deploy tags. The generic loop above may never have processed
  # these (the v0.10.0 rollback proved it can be skipped), and even when it does,
  # scion-up re-sources deploy/versions.env on recreate — so this explicit pin is
  # the only thing that guarantees the recreate below cannot re-derive the new
  # release from the tree recipe. Idempotent with the loop when it did pin them.
  for var in "${!scion_pre_tag[@]}"; do
    sops set "$stack_env" "[\"$var\"]" "\"${scion_pre_tag[$var]}\""
    log info "  pinned $var=${scion_pre_tag[$var]} (scion runtime/brain revert target, ru4g; shadow over deploy/versions.env, clears on next successful upgrade)"
  done
}

log info "swap targets: substrate=[${swap_services[*]-}] scions=[${scion_swap_shorts[*]-}]"
log info "pulling new images via bin/thriden-compose-pull.sh"
if ! ./bin/thriden-compose-pull.sh -h "$host_short" "${compose_files[@]}" 2>&1 | tee -a /tmp/thriden-pull-$run_id.log >&2; then
  log error "compose pull failed; reverting pins"
  revert_pins
  set_result_field '.failure_kind' '"wrapper_error"'
  finalize rolled_back
  exit 1
fi

log info "recreating swap targets with new images"
# Compose up needs stack.enc.env loaded for var interpolation. We don't
# need host.enc.env here (no GHCR pull happens — images already local
# from the prior thriden-compose-pull step).
recreate_scions() {
  # Re-render + recreate each affected Scion via scion-up (binding-safe:
  # it re-fetches <SHORT>_SOUL_ID / <SHORT>_RAVEN_TOKEN from Mongo). Honors
  # whatever pins are currently in stack.enc.env, so it serves both the
  # forward swap and the rollback recreate. SCION_ID derivation mirrors
  # bin/thriden-upgrade.sh step 6.
  local short cname scion_id rc_all=0
  for short in "${scion_swap_shorts[@]}"; do
    cname="${proj}-forge-${short}-1"
    scion_id=$(docker inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
      | sed -n 's/^SCION_ID=//p' | head -n1)
    if [[ -z "$scion_id" ]]; then
      log error "  cannot derive SCION_ID for scion '$short' ($cname not running?); skipping its recreate"
      rc_all=1
      continue
    fi
    log info "  scion '$short' (id=$scion_id): recreate via bin/thriden-scion-up.sh"
    if ! ./bin/thriden-scion-up.sh "$scion_id" >&2; then
      log error "  scion-up failed for '$short'"
      rc_all=1
    fi
  done
  return "$rc_all"
}

recreate_failed=false
# Scion services first: the manifest ordering puts engram before forge, and
# scion-up recreates engram-<short> then forge-<short> via depends_on, which
# preserves that contract. Substrate follows.
if [[ ${#scion_swap_shorts[@]} -gt 0 ]]; then
  if ! recreate_scions; then
    recreate_failed=true
  fi
fi
if ! $recreate_failed && [[ ${#swap_services[@]} -gt 0 ]]; then
  if ! sops exec-env "$stack_env" "docker compose ${compose_files_q} up -d ${swap_services[*]@Q}" 2>&1 | tee -a /tmp/thriden-up-$run_id.log >&2; then
    recreate_failed=true
  fi
fi
if $recreate_failed; then
  log error "recreate failed; reverting pins + recreating originals"
  revert_pins
  if [[ ${#scion_swap_shorts[@]} -gt 0 ]]; then
    recreate_scions || log error "  original-tag scion recreate also failed; stack in unknown state, manual review required"
  fi
  if [[ ${#swap_services[@]} -gt 0 ]]; then
    sops exec-env "$stack_env" "docker compose ${compose_files_q} up -d ${swap_services[*]@Q}" >&2 || \
      log error "  original-tag recreate also failed; stack in unknown state, manual review required"
  fi
  set_result_field '.failure_kind' '"startup_crash"'
  finalize rolled_back
  exit 1
fi

# ── Smoke tests ────────────────────────────────────────────────────────

smoke_tier_0() {  # liveness: container reports running within 30s
  local svc="$1"
  local deadline=$(( SECONDS + 30 ))
  while (( SECONDS < deadline )); do
    state=$(docker compose "${compose_files[@]}" ps --format json "$svc" 2>/dev/null \
      | jq -r '.State // empty' | head -1)
    [[ "$state" == "running" ]] && return 0
    sleep 1
  done
  return 1
}

# Per-service healthcheck port. Keyed by compose service base (matched
# via prefix so engram-helix → 3030, forge-helix → 8200, etc.).
healthcheck_port_for_svc() {
  case "$1" in
    nooscope)  echo 8080 ;;
    # forge-web (substrate) serves /health on 8200; per-Scion forge runtimes
    # serve the PF health server on 8100 (see compose-<short>.yml port maps).
    # The old blanket `forge* → 8200` failed a HEALTHY forge-dm at tier 1 on
    # the first real brain-swap run (2026-07-03) and triggered a spurious
    # rollback (xluj integration bug #6).
    forge-web) echo 8200 ;;
    forge*)    echo 8100 ;;
    engram*)   echo 3030 ;;
    *)         echo "" ;;
  esac
}

smoke_tier_1() {  # healthcheck: HTTP /health returns 200 within the budget
  local svc="$1"
  local port
  port=$(healthcheck_port_for_svc "$svc")
  if [[ -z "$port" ]]; then
    log warn "no healthcheck port known for $svc; tier 1 cannot run, treating as pass"
    return 0
  fi

  # nooscope: probe from the HOST, not in-container (). Its image is
  # nginx-unprivileged:alpine with `apk del curl` (curl dropped for CVEs), so the
  # in-container `curl` probe below can NEVER succeed for it — it timed out every
  # deploy and was swallowed by the non-gating flag, so the check never actually
  # validated nooscope. nooscope publishes its port to the host and the wrapper
  # host has curl (required_deps), so host-probe the published binding instead.
  # Longer budget: nooscope's entrypoint waits up to 90s for forge-web's /scions
  # roster before nginx (and /health) come up (ROSTER_BOOT_BUDGET), which exceeds
  # the 60s used for the always-listening API services.
  if [[ "$svc" == "nooscope" ]]; then
    local hostbind deadline=$(( SECONDS + 100 ))
    hostbind=$(docker compose "${compose_files[@]}" port "$svc" "$port" 2>/dev/null | head -1)
    # `docker compose port` reports the bind address, which is 0.0.0.0 when
    # published on all interfaces. curl treats 0.0.0.0 as loopback on Linux, but
    # don't lean on that quirk — normalise to 127.0.0.1 for an explicit connect.
    hostbind="${hostbind/0.0.0.0/127.0.0.1}"
    if [[ -z "$hostbind" ]]; then
      log warn "nooscope publishes no host port for ${port}; tier 1 cannot host-probe, treating as pass"
      return 0
    fi
    while (( SECONDS < deadline )); do
      if curl -fsSL -o /dev/null -w '%{http_code}' "http://${hostbind}/health" 2>/dev/null | grep -q 200; then
        return 0
      fi
      sleep 2
    done
    return 1
  fi

  local deadline=$(( SECONDS + 60 ))
  while (( SECONDS < deadline )); do
    # -L: follow redirects and judge the FINAL status. forge-web v0.11.0's
    # session middleware 307s anonymous /health to /login (which serves 200)
    # — the redirect landing proves uvicorn is up and routing, and once PF
    # exempts /health from auth (PersonaForge bean filed 2026-07-03) the
    # direct 200 behaves identically. API services (engram, forge-<scion>)
    # answer 200 directly and are unaffected.
    if docker compose "${compose_files[@]}" exec -T "$svc" \
         sh -c "curl -fsSL -o /dev/null -w '%{http_code}' http://localhost:${port}/health 2>/dev/null" \
         2>/dev/null | grep -q 200; then
      return 0
    fi
    sleep 2
  done
  return 1
}

smoke_failed=false
failed_component=""

# A smoke failure on a NON-GATING component records + warns but never rolls the
# bundle back. nooscope is non-gating (): a stateless, read-only
# viewer must not veto a brain+runtime upgrade that otherwise passed. It stays
# non-gating as a backstop even now that its tier-1 probe actually works
# (host-side; see smoke_tier_1). Historically its "failures" were NOT a
# warming-substrate race but a dead probe — the wrapper exec'd `curl` inside the
# nooscope image, which has curl stripped for CVEs, so the check timed out every
# deploy regardless of nooscope's health. Even a genuinely still-warming viewer
# (its entrypoint waits up to 90s for forge-web's roster, then degraded-boots per
# ) shouldn't roll back a good upgrade. Gating components (engram
# brain, forge runtime + substrate) still roll back on failure.
smoke_is_gating() {
  case "$1" in
    nooscope) return 1 ;;
    *)        return 0 ;;
  esac
}
soft_smoke_failures=()
# note_smoke_fail <component> <svc> <failure_kind> <message>
# Returns 0 (gating: caller should `break 2` and roll back the bundle) or
# 1 (soft: caller should `continue` to the next service).
note_smoke_fail() {
  local c="$1" svc="$2" kind="$3" msg="$4"
  if smoke_is_gating "$c"; then
    log error "$msg"
    smoke_failed=true
    failed_component="$c"
    set_result_field '.failure_kind' "\"$kind\""
    return 0
  fi
  log warn "$msg — non-gating component ($c); recording, NOT rolling back (m3wj)"
  soft_smoke_failures+=("$c/$svc:$kind")
  return 1
}

for c in "${components[@]}"; do
  tier=$(smoke_tier_for "$c")
  # Service list rides FD 3, NOT stdin: the `docker compose exec -T` calls
  # inside this loop forward/consume stdin, which silently ate every service
  # after the first (xluj integration bug #9 — forge-web was never smoked in
  # any run; only the component's first service was).
  while IFS= read -r svc <&3; do
    [[ -z "$svc" ]] && continue

    log info "smoke $c/$svc (tier $tier)"

    # Tier 0
    if ! smoke_tier_0 "$svc"; then
      note_smoke_fail "$c" "$svc" startup_crash "tier 0 (liveness) failed for $svc after 30s" && break 2 || continue
    fi

    # Tier 1
    if (( tier >= 1 )); then
      if ! smoke_tier_1 "$svc"; then
        note_smoke_fail "$c" "$svc" healthcheck_timeout "tier 1 (healthcheck) failed for $svc after 60s" && break 2 || continue
      fi
    fi

    # Tier 2 (engram canary query) -- . Operator pre-plants
    # a real node as the canary via POST /admin/canary/plant on each
    # engram-* container; the wrapper fetches it post-swap to verify the
    # new build's query path returns recognised data.
    if (( tier >= 2 )); then
      # Brain must be ACTIVE for the canary read: a no-op recreate (compose
      # saw no config change) leaves the container in whatever state it was
      # in — possibly torpid from a previous wrapper run's exit-torpor, and
      # read/write endpoints 503 while torpid (xluj integration bug #8).
      # /admin/rouse is idempotent (no-op on an active brain).
      docker compose "${compose_files[@]}" exec -T "$svc" \
        sh -c 'curl -fsS -X POST -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" http://localhost:3030/admin/rouse' \
        >/dev/null 2>&1 || log warn "  pre-canary rouse failed for $svc; canary may 503"
      # Two-call form for clarity: one HEAD-style fetch for the HTTP code,
      # then one body fetch on 200. Either call's failure (timeout, 5xx)
      # is a real Tier 2 fail; 404 is "operator chose not to plant" or
      # "canary went stale" -- both soft, treated as skip-with-note.
      # Retry briefly on 503: rouse's HNSW rebuild is fast but not instant.
      canary_deadline=$(( SECONDS + 20 ))
      http_code="000"
      while (( SECONDS < canary_deadline )); do
        http_code=$(docker compose "${compose_files[@]}" exec -T "$svc" \
          sh -c 'curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" http://localhost:3030/admin/canary' \
          2>/dev/null || echo "000")
        [[ "$http_code" != "503" ]] && break
        sleep 2
      done
      case "$http_code" in
        200)
          canary_json=$(docker compose "${compose_files[@]}" exec -T "$svc" \
            sh -c 'curl -fsS -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" http://localhost:3030/admin/canary' \
            2>/dev/null || echo '')
          canary_id=$(echo "$canary_json" | jq -r '.id // empty')
          if [[ -n "$canary_id" ]]; then
            log info "tier 2 pass: $svc canary $canary_id retrieved"
          else
            note_smoke_fail "$c" "$svc" smoke_test_failed "tier 2 failed: $svc /admin/canary returned 200 but no valid .id field" && break 2 || continue
          fi
          ;;
        404)
          log warn "tier 2 skipped: $svc has no canary planted or canary is stale (8unq)"
          log warn "  to enable Tier 2 for this Scion: POST /admin/canary/plant with an existing node_id"
          ;;
        *)
          note_smoke_fail "$c" "$svc" smoke_test_failed "tier 2 failed: $svc /admin/canary returned http $http_code" && break 2 || continue
          ;;
      esac
    fi
  done 3< <(compose_services_for "$c")
done

# Non-gating smoke failures (nooscope) are recorded in the result doc for the
# operator but do NOT trigger a rollback ().
if (( ${#soft_smoke_failures[@]} > 0 )); then
  soft_json=$(printf '%s\n' "${soft_smoke_failures[@]}" | jq -R . | jq -s .)
  set_result_field '.soft_smoke_failures' "$soft_json"
  log warn "non-gating smoke failures recorded (bundle NOT rolled back): ${soft_smoke_failures[*]}"
fi

# ── Promote or rollback ────────────────────────────────────────────────

if $smoke_failed; then
  log error "smoke failed at component '$failed_component'; rolling back"
  set_result_field '.failed_component' "\"$failed_component\""
  revert_pins
  log info "recreating original images"
  if [[ ${#scion_swap_shorts[@]} -gt 0 ]]; then
    recreate_scions || log error "  recreate-original failed for a scion; stack in unknown state"
  fi
  if [[ ${#swap_services[@]} -gt 0 ]]; then
    sops exec-env "$stack_env" "docker compose ${compose_files_q} up -d ${swap_services[*]@Q}" 2>&1 >&2 \
      || log error "  recreate-original failed; stack in unknown state"
  fi

  # : record the actual post-revert scion image tags so a runtime
  # that failed to roll back (the v0.10.0 forge-dm split) is visible in the
  # result doc instead of only in `docker ps`. A mismatch vs scion_pre_tag here
  # means the force-pin above did not take — manual review.
  for short in "${scion_swap_shorts[@]}"; do
    for pfx in engram forge; do
      cn="${proj}-${pfx}-${short}-1"
      docker inspect "$cn" >/dev/null 2>&1 || continue
      img=$(docker inspect "$cn" --format '{{.Config.Image}}' 2>/dev/null)
      log info "  post-revert ${pfx}-${short} image: ${img##*:}"
    done
  done

  # Restore engram brains from pre-flight backups
  for svc in "${engram_services[@]}"; do
    scion="${svc#engram-}"
    [[ "$scion" == "$svc" ]] && scion="default"
    bkp="${backup_path[$scion]:-}"
    if [[ -n "$bkp" && -f "$bkp" ]]; then
      # Import 503s on a torpid brain (same class as the canary read, bug
      # #8); rouse first — idempotent, and we torpor again at the end.
      docker compose "${compose_files[@]}" exec -T "$svc" \
        sh -c 'curl -fsS -X POST -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" http://localhost:3030/admin/rouse' \
        >/dev/null 2>&1 || log warn "  pre-import rouse failed for $svc; import may 503"
      log info "/admin/import for $svc from $bkp"
      if docker compose "${compose_files[@]}" exec -T "$svc" \
           sh -c 'curl -fsS -X POST -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" -H "Content-Type: application/json" --data-binary @- http://localhost:3030/admin/import' \
           < "$bkp" >/dev/null 2>&1; then
        log info "  restore complete for $scion"
      else
        log error "  restore FAILED for $scion; brain may be on new code with old data, manual review required"
      fi
    fi
  done

  finalize rolled_back
else
  log info "all smoke tests passed; promoting"
  set_result_field '.succeeded_components' "$(printf '%s\n' "${components[@]}" | jq -R . | jq -s .)"
  finalize succeeded

  # tpo4 hygiene (2wg6): our pins now duplicate what the release tree's
  # deploy/versions.env carries. Remove each pin whose value matches the
  # tree so versions.env resumes ownership and the NEXT release's git pull
  # isn't shadowed. A mismatch is kept and flagged — unsetting it would
  # silently change the effective version.
  for var in "${pin_vars[@]}"; do
    tree_val=$(grep -E "^${var}=" deploy/versions.env 2>/dev/null | head -1 | cut -d= -f2-)
    if [[ "$tree_val" == "${pin_tag[$var]}" ]]; then
      if sops unset "$stack_env" "[\"$var\"]" >/dev/null 2>&1; then
        log info "  unpinned $var (deploy/versions.env owns $tree_val)"
      else
        log warn "  could not unpin $var (sops unset failed/unavailable); harmless duplicate of versions.env ($tree_val)"
      fi
    else
      log warn "  keeping pin $var=${pin_tag[$var]} (tree versions.env says '${tree_val:-<absent>}' — pull the release tree, then remove the pin manually)"
    fi
  done
fi

# ── Return engram to torpor (regardless of success/rollback path) ──────

for svc in "${engram_services[@]}"; do
  log info "POST /admin/torpor on $svc (preserve natural circadian rhythm)"
  if docker compose "${compose_files[@]}" exec -T "$svc" \
       sh -c 'curl -fsS -X POST -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" http://localhost:3030/admin/torpor' \
       >/dev/null 2>&1; then
    log info "  $svc returned to torpor"
  else
    log warn "  /admin/torpor on $svc failed; circadian rouse may need manual intervention"
  fi
done

log info "wrapper complete; final status: $(jq -r '.status' "$result_file")"
trap - EXIT
exit 0
