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

# ── Optional git self-sync (-S) ────────────────────────────────────────
#
# Bring the stack tree to the manifest's `thriden_version` BEFORE deploying,
# so a release that changes compose *structure* (new service / env var /
# per-Scion compose / bin script) rides a single Forge "schedule" click
# instead of needing a manual `git pull` first ().
#
# File mode only, on purpose:
#   - there is no Mongo claim to order against, and thriden_version is
#     readable up front (in -i mode the claim happens later, and checking
#     out mid-claim would risk a double-claim);
#   - the checkout rewrites this very script + the compose files under the
#     running process, so we re-exec the now-current version (guarded) to
#     run the rest of the lifecycle from the checked-out release, not the
#     bytes bash half-read before the checkout.
# The direct -i (Mongo) sync is the host-side wake harness's job
# (checkout-then-invoke) -- see .
if [[ "$do_sync" == 1 && -z "${THRIDEN_PAYLOAD_SYNCED:-}" ]]; then
  if [[ -n "$mongo_id" ]]; then
    echo "ERROR: -S (git self-sync) requires file mode (-m); for -i the wake harness must checkout before invoking" >&2
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
  # No-op fast path: already exactly at the target tag.
  if [[ "$(git describe --tags --exact-match HEAD 2>/dev/null || true)" != "$sync_target" ]]; then
    # A deploy host must be pristine -- refuse rather than clobber local work.
    if ! git diff --quiet || ! git diff --cached --quiet; then
      echo "ERROR: -S refusing to checkout over a dirty tree; resolve local changes first" >&2
      exit 1
    fi
    echo "[sync] fetching tags + checking out $sync_target" >&2
    if ! git fetch --tags --quiet; then
      echo "ERROR: -S git fetch failed; refusing to deploy a possibly-stale tree" >&2
      exit 1
    fi
    if ! git rev-parse -q --verify "refs/tags/${sync_target}^{commit}" >/dev/null; then
      echo "ERROR: -S target tag '$sync_target' not found after fetch" >&2
      exit 1
    fi
    if ! git checkout --quiet "$sync_target"; then
      echo "ERROR: -S checkout of '$sync_target' failed" >&2
      exit 1
    fi
  fi
  # Re-exec the (now-current) script; guard prevents a sync loop.
  export THRIDEN_PAYLOAD_SYNCED=1
  exec "$0" "$@"
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

if [[ -z "$host_short" ]]; then
  host_short="$(hostname -s)"
fi

host_env="secrets/prod/hosts/${host_short}/host.enc.env"
stack_env="secrets/prod/stack.enc.env"

for f in "$host_env" "$stack_env"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: $f not found" >&2
    exit 1
  fi
done

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

  docker compose -f docker-compose.yml -f compose.prod.yml exec -T \
    "${env_flags[@]}" mongodb \
    sh -c 'mongosh "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/personaforge?authSource=admin" --quiet --eval "$MONGO_QUERY_JS"'
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

# Map logical component → compose env var
env_var_for() {
  case "$1" in
    engram)   echo ENGRAM_VERSION ;;
    forge)    echo FORGE_VERSION ;;
    nooscope) echo NOOSCOPE_VERSION ;;
    *) echo ""; return 1 ;;
  esac
}

# Map logical component → compose service names (glob expanded later)
compose_services_for() {
  case "$1" in
    engram)   docker compose -f docker-compose.yml -f compose.prod.yml ps --services 2>/dev/null | grep -E '^engram(-.+)?$' || true ;;
    forge)    docker compose -f docker-compose.yml -f compose.prod.yml ps --services 2>/dev/null | grep -E '^forge(-.+)?$' || true ;;
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
    health_json=$(docker compose -f docker-compose.yml -f compose.prod.yml exec -T "$svc" \
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
    if docker compose -f docker-compose.yml -f compose.prod.yml exec -T "$svc" \
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

declare -A original_tag
log info "capturing original env values before pin"
for c in "${components[@]}"; do
  var=$(env_var_for "$c") || { log error "no env var mapping for component '$c'"; finalize failed; exit 1; }
  # Decrypt to inspect current value (in-memory only via process substitution)
  original_tag[$c]=$(sops -d --extract "[\"$var\"]" --output-type dotenv "$stack_env" 2>/dev/null \
    | grep "^${var}=" | cut -d= -f2- || echo "")
  log info "  $c: $var=${original_tag[$c]:-<unset>} → ${new_tag[$c]}"
done

# Save originals into result file so a re-run knows what to revert to
originals_json=$(printf '%s\n' "${!original_tag[@]}" | jq -R . | jq -s 'reduce .[] as $k ({}; .)')
for c in "${!original_tag[@]}"; do
  originals_json=$(echo "$originals_json" | jq --arg k "$c" --arg v "${original_tag[$c]}" '. + {($k): $v}')
done
set_result_field '.original_tags' "$originals_json"

log info "pinning new tags via sops set"
for c in "${components[@]}"; do
  var=$(env_var_for "$c")
  tag="${new_tag[$c]}"
  sops set "$stack_env" "[\"$var\"]" "\"$tag\""
  log info "  pinned $var=$tag"
done

# ── Swap ───────────────────────────────────────────────────────────────

revert_pins() {
  log info "reverting tag pins"
  for c in "${components[@]}"; do
    var=$(env_var_for "$c")
    orig="${original_tag[$c]}"
    if [[ -n "$orig" ]]; then
      sops set "$stack_env" "[\"$var\"]" "\"$orig\""
      log info "  restored $var=$orig"
    else
      log warn "  $var had no original value; leaving pinned (manual review recommended)"
    fi
  done
}

# Collect all compose service names we'll be operating on
swap_services=()
for c in "${components[@]}"; do
  while IFS= read -r s; do [[ -n "$s" ]] && swap_services+=("$s"); done < <(compose_services_for "$c")
done

if [[ ${#swap_services[@]} -eq 0 ]]; then
  log error "manifest components [${components[*]}] match no running compose services on this host"
  log error "refusing to proceed -- without an explicit swap target list, 'docker compose up -d' would recreate every service in the stack"
  log error "check that the expected services (e.g. engram-<short>, forge-<short>) are running, or correct the manifest"
  revert_pins
  set_result_field '.failure_kind' '"wrapper_error"'
  finalize failed
  exit 1
fi

log info "swap targets: ${swap_services[*]}"
log info "pulling new images via bin/thriden-compose-pull.sh"
if ! ./bin/thriden-compose-pull.sh -h "$host_short" 2>&1 | tee -a /tmp/thriden-pull-$run_id.log >&2; then
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
if ! sops exec-env "$stack_env" "docker compose -f docker-compose.yml -f compose.prod.yml up -d ${swap_services[*]@Q}" 2>&1 | tee -a /tmp/thriden-up-$run_id.log >&2; then
  log error "compose up failed; reverting pins + recreating originals"
  revert_pins
  sops exec-env "$stack_env" "docker compose -f docker-compose.yml -f compose.prod.yml up -d ${swap_services[*]@Q}" >&2 || \
    log error "  original-tag recreate also failed; stack in unknown state, manual review required"
  set_result_field '.failure_kind' '"startup_crash"'
  finalize rolled_back
  exit 1
fi

# ── Smoke tests ────────────────────────────────────────────────────────

smoke_tier_0() {  # liveness: container reports running within 30s
  local svc="$1"
  local deadline=$(( SECONDS + 30 ))
  while (( SECONDS < deadline )); do
    state=$(docker compose -f docker-compose.yml -f compose.prod.yml ps --format json "$svc" 2>/dev/null \
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
    nooscope) echo 8080 ;;
    forge*)   echo 8200 ;;
    engram*)  echo 3030 ;;
    *)        echo "" ;;
  esac
}

smoke_tier_1() {  # healthcheck: HTTP /health returns 200 within 60s
  local svc="$1"
  local port
  port=$(healthcheck_port_for_svc "$svc")
  if [[ -z "$port" ]]; then
    log warn "no healthcheck port known for $svc; tier 1 cannot run, treating as pass"
    return 0
  fi
  local deadline=$(( SECONDS + 60 ))
  while (( SECONDS < deadline )); do
    if docker compose -f docker-compose.yml -f compose.prod.yml exec -T "$svc" \
         sh -c "curl -fsS -o /dev/null -w '%{http_code}' http://localhost:${port}/health 2>/dev/null" \
         2>/dev/null | grep -q 200; then
      return 0
    fi
    sleep 2
  done
  return 1
}

smoke_failed=false
failed_component=""
for c in "${components[@]}"; do
  tier=$(smoke_tier_for "$c")
  while IFS= read -r svc; do
    [[ -z "$svc" ]] && continue

    log info "smoke $c/$svc (tier $tier)"

    # Tier 0
    if ! smoke_tier_0 "$svc"; then
      log error "tier 0 (liveness) failed for $svc after 30s"
      smoke_failed=true
      failed_component="$c"
      set_result_field '.failure_kind' '"startup_crash"'
      break 2
    fi

    # Tier 1
    if (( tier >= 1 )); then
      if ! smoke_tier_1 "$svc"; then
        log error "tier 1 (healthcheck) failed for $svc after 60s"
        smoke_failed=true
        failed_component="$c"
        set_result_field '.failure_kind' '"healthcheck_timeout"'
        break 2
      fi
    fi

    # Tier 2 (engram canary query) -- . Operator pre-plants
    # a real node as the canary via POST /admin/canary/plant on each
    # engram-* container; the wrapper fetches it post-swap to verify the
    # new build's query path returns recognised data.
    if (( tier >= 2 )); then
      # Two-call form for clarity: one HEAD-style fetch for the HTTP code,
      # then one body fetch on 200. Either call's failure (timeout, 5xx)
      # is a real Tier 2 fail; 404 is "operator chose not to plant" or
      # "canary went stale" -- both soft, treated as skip-with-note.
      http_code=$(docker compose -f docker-compose.yml -f compose.prod.yml exec -T "$svc" \
        sh -c 'curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" http://localhost:3030/admin/canary' \
        2>/dev/null || echo "000")
      case "$http_code" in
        200)
          canary_json=$(docker compose -f docker-compose.yml -f compose.prod.yml exec -T "$svc" \
            sh -c 'curl -fsS -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" http://localhost:3030/admin/canary' \
            2>/dev/null || echo '')
          canary_id=$(echo "$canary_json" | jq -r '.id // empty')
          if [[ -n "$canary_id" ]]; then
            log info "tier 2 pass: $svc canary $canary_id retrieved"
          else
            log error "tier 2 failed: $svc /admin/canary returned 200 but no valid .id field"
            smoke_failed=true
            failed_component="$c"
            set_result_field '.failure_kind' '"smoke_test_failed"'
            break 2
          fi
          ;;
        404)
          log warn "tier 2 skipped: $svc has no canary planted or canary is stale (8unq)"
          log warn "  to enable Tier 2 for this Scion: POST /admin/canary/plant with an existing node_id"
          ;;
        *)
          log error "tier 2 failed: $svc /admin/canary returned http $http_code"
          smoke_failed=true
          failed_component="$c"
          set_result_field '.failure_kind' '"smoke_test_failed"'
          break 2
          ;;
      esac
    fi
  done < <(compose_services_for "$c")
done

# ── Promote or rollback ────────────────────────────────────────────────

if $smoke_failed; then
  log error "smoke failed at component '$failed_component'; rolling back"
  set_result_field '.failed_component' "\"$failed_component\""
  revert_pins
  log info "recreating original images"
  sops exec-env "$stack_env" "docker compose -f docker-compose.yml -f compose.prod.yml up -d ${swap_services[*]@Q}" 2>&1 >&2 \
    || log error "  recreate-original failed; stack in unknown state"

  # Restore engram brains from pre-flight backups
  for svc in "${engram_services[@]}"; do
    scion="${svc#engram-}"
    [[ "$scion" == "$svc" ]] && scion="default"
    bkp="${backup_path[$scion]:-}"
    if [[ -n "$bkp" && -f "$bkp" ]]; then
      log info "/admin/import for $svc from $bkp"
      if docker compose -f docker-compose.yml -f compose.prod.yml exec -T "$svc" \
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
fi

# ── Return engram to torpor (regardless of success/rollback path) ──────

for svc in "${engram_services[@]}"; do
  log info "POST /admin/torpor on $svc (preserve natural circadian rhythm)"
  if docker compose -f docker-compose.yml -f compose.prod.yml exec -T "$svc" \
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
