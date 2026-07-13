#!/usr/bin/env bash
# thriden-doctor.sh — one-command install verifier for Thriden hosts ().
#
# Turns "is this participant's install golden?" from a support conversation into
# a command. Retro item from the 2026-07-03 Cairn upgrade series: every one of
# the integration bugs that ate a deploy window was discoverable by a host-side
# check BEFORE the window needed it. This assembles those checks (each already
# existed as a debugging fragment) into a single PASS/WARN/FAIL report.
#
# READ-ONLY by design: it never rouses a brain, mutates Mongo, plants a canary,
# or touches versions. It only observes. Safe to run any time, including mid-
# torpor (a sleeping brain is reported as WARN "unverifiable", not FAIL).
#
# Run it from the stack dir (where docker-compose.yml lives), as the operator
# who owns the sops age key:
#   cd /srv/thriden && bin/thriden-doctor.sh
#   bin/thriden-doctor.sh -h <host-short>     # override host-short resolution
#
# Exit code: 0 if no FAIL (WARN still allowed); nonzero if any check FAILs.
# "All green" (zero WARN, zero FAIL) = the install is golden.
#
# Checks (bean ):
#   1. Host-short resolves (which chain step matched; warn if fragile).
#   2. secrets/prod/{stack,hosts/<short>/host}.enc.env decrypt with the age key.
#   3. GHCR pull credential works (login/logout round-trip, isolated config).
#   4. sops version >= 3.9 (the wrapper's rollback 'unset' path needs it).
#   5. deploy_payloads validator present AND current vs the shipped schema.
#   6. thriden-deploy-dispatch.timer installed + enabled + last run clean.
#   7. Per Scion drop-in: engram/forge running+healthy, canary fresh, soul bound.
#   8. No *_VERSION shadows in stack.enc.env (tpo4 discipline).
#   9. Tree on a thriden-v* tag or main, clean (no stray files), remote reachable.
#
# Companion tooling this leans on:
#   bin/thriden-host-short.lib.sh          (check 1)
#   schemas/deploy-payload-mongo.schema.json (check 5)
#   bin/thriden-deploy-payloads-setup.sh   (remediation for 5)
#   deploy/systemd/thriden-deploy-dispatch.{service,timer} (check 6)

set -uo pipefail

# ── Arg parse ──────────────────────────────────────────────────────────────
host_override=""
for a in "$@"; do
  case "$a" in
    --help|-\?)
      sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
      exit 0
      ;;
  esac
done
while getopts "h:" opt; do
  case "$opt" in
    h) host_override="$OPTARG" ;;
    *) echo "usage: $0 [-h <host-short>]" >&2; exit 2 ;;
  esac
done

# ── Must run from the stack dir ────────────────────────────────────────────
if [[ ! -f docker-compose.yml || ! -f compose.prod.yml ]]; then
  echo "ERROR: run from the Thriden stack dir (docker-compose.yml + compose.prod.yml not found in $(pwd))." >&2
  exit 2
fi

script_dir="$(cd "$(dirname "$0")" && pwd)"
COMPOSE=(-f docker-compose.yml -f compose.prod.yml)

# ── Host-short resolution (shared lib; check 1 reports on it) ───────────────
# host_override / host_short survive the sops re-exec below via env, because
# `sops exec-env` accepts only TWO positionals (the file + a single sh-command
# string) — re-passing argv through it breaks (compose-pull note 1). So we carry
# the resolved values in DOCTOR_HOST_* and re-exec with just "$0".
host_override="${DOCTOR_HOST_OVERRIDE:-$host_override}"
# shellcheck source=bin/thriden-host-short.lib.sh
. "$script_dir/thriden-host-short.lib.sh"
host_short="$(thriden_resolve_host_short "$host_override" 2>/dev/null || true)"
host_short="${DOCTOR_HOST_SHORT:-$host_short}"

stack_env="secrets/prod/stack.enc.env"
host_env="secrets/prod/hosts/${host_short}/host.enc.env"

# ── Pre-wrap decrypt probe + SOPS self-wrap ────────────────────────────────
# Several checks (5, 7) need `docker compose exec`, which evaluates the compose
# files — and docker-compose.yml requires ${MONGO_ROOT_PASSWORD:?}. Re-exec
# under `sops exec-env stack.enc.env` so those work. But a doctor must not DIE
# in sops when the key is wrong (that IS check 2's finding), so we probe the
# decrypt first, record the result in the environment (survives the re-exec),
# and only wrap if the stack tier actually decrypts. If it doesn't, we run in a
# degraded mode: the compose-dependent checks WARN-skip and check 2 FAILs.
if [[ -z "${MONGO_ROOT_PASSWORD:-}" ]]; then
  if [[ -f "$stack_env" ]] && sops -d "$stack_env" >/dev/null 2>&1; then
    export DOCTOR_STACK_DECRYPT=ok
  elif [[ -f "$stack_env" ]]; then
    export DOCTOR_STACK_DECRYPT=fail
  else
    export DOCTOR_STACK_DECRYPT=missing
  fi
  if [[ -f "$host_env" ]] && sops -d "$host_env" >/dev/null 2>&1; then
    export DOCTOR_HOST_DECRYPT=ok
  elif [[ -f "$host_env" ]]; then
    export DOCTOR_HOST_DECRYPT=fail
  else
    export DOCTOR_HOST_DECRYPT=missing
  fi
  if [[ "$DOCTOR_STACK_DECRYPT" == "ok" ]]; then
    export DOCTOR_HOST_SHORT="$host_short" DOCTOR_HOST_OVERRIDE="$host_override"
    exec sops exec-env "$stack_env" "$0"
  fi
fi
: "${DOCTOR_STACK_DECRYPT:=missing}"
: "${DOCTOR_HOST_DECRYPT:=missing}"

# True once we are inside the sops wrap (compose vars available).
wrapped=0
[[ -n "${MONGO_ROOT_PASSWORD:-}" ]] && wrapped=1

# ── Reporting scaffold ─────────────────────────────────────────────────────
if [[ -t 1 ]]; then
  C_RESET=$'\033[0m'; C_PASS=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_DIM=$'\033[2m'; C_BOLD=$'\033[1m'
else
  C_RESET=; C_PASS=; C_WARN=; C_FAIL=; C_DIM=; C_BOLD=
fi
n_pass=0; n_warn=0; n_fail=0

# report <PASS|WARN|FAIL> <title> <detail> [remediation]
report() {
  local status="$1" title="$2" detail="$3" fix="${4:-}"
  local tag color
  case "$status" in
    PASS) tag=" PASS "; color="$C_PASS"; n_pass=$((n_pass+1)) ;;
    WARN) tag=" WARN "; color="$C_WARN"; n_warn=$((n_warn+1)) ;;
    FAIL) tag=" FAIL "; color="$C_FAIL"; n_fail=$((n_fail+1)) ;;
  esac
  printf '%s[%s]%s %s\n' "$color" "$tag" "$C_RESET" "$title"
  [[ -n "$detail" ]] && printf '        %s%s%s\n' "$C_DIM" "$detail" "$C_RESET"
  [[ -n "$fix" && "$status" != "PASS" ]] && printf '        %s-> fix: %s%s\n' "$C_DIM" "$fix" "$C_RESET"
}

# doctor_mongo_eval <js> [KEY=VALUE ...] — run a mongosh script in the mongodb
# container, JS passed via env (5hxi injection-safety: never in the command
# string), --eval form (piped stdin makes mongosh echo a prompt that corrupts
# parsed output). Only callable when wrapped (MONGO_ROOT_PASSWORD in env).
doctor_mongo_eval() {
  local js="$1"; shift
  local flags=(-e "MONGO_QUERY_JS=$js") kv
  for kv in "$@"; do flags+=(-e "$kv"); done
  docker compose "${COMPOSE[@]}" exec -T "${flags[@]}" mongodb \
    sh -c 'mongosh "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/personaforge?authSource=admin" --quiet --eval "$MONGO_QUERY_JS"' \
    2>/dev/null | tr -d '\r'
}

printf '%s== Thriden doctor ==%s  host-short=%s  stack=%s\n\n' \
  "$C_BOLD" "$C_RESET" "${host_short:-<unresolved>}" "$(pwd)"

# ── Check 1 — host-short resolves ──────────────────────────────────────────
check_host_short() {
  if [[ -z "$host_short" ]]; then
    report FAIL "1. Host-short resolution" \
      "could not resolve a host-short name" \
      "pin it once: echo <short> > .thriden-host-short  (or export THRIDEN_HOST_SHORT, or pass -h). runbook-provision-scion.md"
    return
  fi
  # Which chain step matched (mirrors thriden-host-short.lib.sh order).
  local via
  local -a hostdirs=()
  local d
  for d in secrets/prod/hosts/*/; do [[ -d "$d" ]] && hostdirs+=("$(basename "$d")"); done
  local hn; hn="$(hostname -s 2>/dev/null || true)"
  if [[ -n "$host_override" ]]; then via="explicit -h"
  elif [[ -n "${THRIDEN_HOST_SHORT:-}" ]]; then via="THRIDEN_HOST_SHORT env"
  elif [[ -s .thriden-host-short ]]; then via=".thriden-host-short pin"
  elif [[ -n "$hn" && -d "secrets/prod/hosts/$hn" ]]; then via="hostname -s"
  else via="single host dir"; fi
  # Fragile: >1 host dir with no durable pin means an unattended path can guess wrong.
  if [[ ${#hostdirs[@]} -gt 1 && ! -s .thriden-host-short && -z "${THRIDEN_HOST_SHORT:-}" && "$via" != "explicit -h" ]]; then
    report WARN "1. Host-short resolution" \
      "resolved '$host_short' via $via, but ${#hostdirs[@]} host dirs exist and nothing is pinned (${hostdirs[*]})" \
      "pin it: echo $host_short > .thriden-host-short  — an unattended dispatch can't pass -h (xluj bug #3)"
  else
    report PASS "1. Host-short resolution" "resolved '$host_short' via $via"
  fi
}

# ── Check 2 — secrets decrypt with the local age key ───────────────────────
check_secrets_decrypt() {
  local s="$DOCTOR_STACK_DECRYPT" h="$DOCTOR_HOST_DECRYPT"
  local fail=0 detail=""
  case "$s" in
    ok)      detail+="stack.enc.env: ok. " ;;
    fail)    detail+="stack.enc.env: DECRYPT FAILED. "; fail=1 ;;
    missing) detail+="stack.enc.env: MISSING. "; fail=1 ;;
  esac
  case "$h" in
    ok)      detail+="host.enc.env ($host_short): ok." ;;
    fail)    detail+="host.enc.env ($host_short): DECRYPT FAILED."; fail=1 ;;
    missing) detail+="host.enc.env ($host_short): MISSING."; fail=1 ;;
  esac
  if (( fail )); then
    report FAIL "2. Secrets decrypt" "$detail" \
      "confirm your age key is at the SOPS_AGE_KEY_FILE / default path and is a recipient of these files. secrets-setup.md; secrets-ops.md § 6"
  else
    report PASS "2. Secrets decrypt" "$detail"
  fi
}

# ── Check 3 — GHCR pull credential round-trips ─────────────────────────────
check_ghcr() {
  if [[ "$DOCTOR_HOST_DECRYPT" != "ok" ]]; then
    report WARN "3. GHCR pull credential" \
      "skipped: host.enc.env did not decrypt (see check 2)" \
      "fix check 2 first, then re-run"
    return
  fi
  # Isolated DOCKER_CONFIG so the probe never persists a credential in the
  # operator's real docker config (same discipline as thriden-compose-pull.sh).
  local cfg; cfg="$(pwd)/.docker-doctor"
  install -d -m 0700 "$cfg"
  export DOCKER_CONFIG="$cfg"
  if sops exec-env "$host_env" \
       'printf %s "${GHCR_PULL_TOKEN:?}" | docker login ghcr.io -u "${GHCR_PULL_USER:?}" --password-stdin >/dev/null 2>&1' \
       >/dev/null 2>&1; then
    docker logout ghcr.io >/dev/null 2>&1 || true
    report PASS "3. GHCR pull credential" "docker login ghcr.io succeeded (credential valid)"
  else
    docker logout ghcr.io >/dev/null 2>&1 || true
    report FAIL "3. GHCR pull credential" \
      "docker login ghcr.io failed with the token in host.enc.env" \
      "your GHCR PAT may be expired (90-day rotation). Drop the new value into $host_env, sops -e -i, re-run. secrets-setup.md; beta-onboarding.md § 9"
  fi
  rm -rf "$cfg" 2>/dev/null || true
  unset DOCKER_CONFIG
}

# ── Check 4 — sops version >= 3.9 ──────────────────────────────────────────
check_sops_version() {
  if ! command -v sops >/dev/null 2>&1; then
    report FAIL "4. sops version" "sops not in PATH" "install sops >= 3.9. secrets-setup.md"
    return
  fi
  local raw ver major minor
  raw="$(sops --version 2>/dev/null | head -1)"
  ver="$(printf '%s' "$raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -1)"
  major="${ver%%.*}"; minor="${ver#*.}"; minor="${minor%%.*}"
  if [[ -z "$ver" ]]; then
    report WARN "4. sops version" "could not parse version from: $raw" "confirm sops >= 3.9 manually"
  elif (( major > 3 || (major == 3 && minor >= 9) )); then
    report PASS "4. sops version" "sops $ver (>= 3.9)"
  else
    report FAIL "4. sops version" "sops $ver is below 3.9" \
      "the wrapper's rollback 'unset' path needs sops >= 3.9. Upgrade sops. secrets-setup.md"
  fi
}

# ── Check 5 — deploy_payloads validator present AND current ────────────────
check_validator() {
  if (( ! wrapped )); then
    report WARN "5. deploy_payloads validator" \
      "skipped: needs stack.enc.env for the Mongo query (see check 2)" ""
    return
  fi
  if [[ ! -f schemas/deploy-payload-mongo.schema.json ]]; then
    report WARN "5. deploy_payloads validator" "shipped schema file not found; cannot compare" ""
    return
  fi
  local js live want got
  js='const o = db.runCommand({listCollections:1, filter:{name:"deploy_payloads"}}).cursor.firstBatch[0];
if (!o) { print("__MISSING_COLLECTION__"); quit(0); }
const v = o.options && o.options.validator && o.options.validator["$jsonSchema"];
print(v ? JSON.stringify(v) : "__NO_VALIDATOR__");'
  live="$(doctor_mongo_eval "$js")"
  if [[ -z "$live" ]]; then
    report FAIL "5. deploy_payloads validator" "could not query mongodb (container down or unreachable)" \
      "bring the stack up (docker compose up -d), then re-run"
    return
  fi
  case "$live" in
    *__MISSING_COLLECTION__*)
      report FAIL "5. deploy_payloads validator" "deploy_payloads collection does not exist" \
        "the deploy-payloads-init service applies this on 'docker compose up'; recreate it (up -d deploy-payloads-init) or run bin/thriden-deploy-payloads-setup.sh"
      return ;;
    *__NO_VALIDATOR__*)
      report FAIL "5. deploy_payloads validator" "collection exists but carries NO \$jsonSchema validator" \
        "recreate the deploy-payloads-init service (up -d deploy-payloads-init) or run bin/thriden-deploy-payloads-setup.sh to apply the validator"
      return ;;
  esac
  # Present -> is it current? Compare against the shipped schema, stripped of
  # the same metadata keys the setup script strips, both canonicalized.
  want="$(jq -cS 'del(."$schema", ."$id", .title, .description)' schemas/deploy-payload-mongo.schema.json 2>/dev/null)"
  got="$(printf '%s' "$live" | jq -cS . 2>/dev/null)"
  if [[ -n "$got" && "$got" == "$want" ]]; then
    report PASS "5. deploy_payloads validator" "present and matches shipped schema"
  else
    report WARN "5. deploy_payloads validator" \
      "validator present but DIFFERS from schemas/deploy-payload-mongo.schema.json (stale)" \
      "a 'docker compose up' re-applies it via deploy-payloads-init (self-heals after git pull); or re-run bin/thriden-deploy-payloads-setup.sh"
  fi
}

# ── Check 6 — dispatch timer installed + enabled + last run clean ──────────
check_dispatch_timer() {
  if ! command -v systemctl >/dev/null 2>&1 || ! systemctl list-units >/dev/null 2>&1; then
    report WARN "6. Upgrade dispatcher timer" \
      "systemd unavailable on this host (WSL single-user?); scheduled upgrade-at-wake not applicable here" \
      "on a systemd host, install per runbook-upgrade-thriden.md § 7b; on WSL use the manual upgrade path (beta-onboarding.md § 9)"
    return
  fi
  local unit="thriden-deploy-dispatch.timer"
  local enabled active result exitstatus
  enabled="$(systemctl is-enabled "$unit" 2>/dev/null || true)"
  if [[ "$enabled" != "enabled" ]]; then
    report FAIL "6. Upgrade dispatcher timer" \
      "$unit is '${enabled:-not-installed}'" \
      "install + enable: see deploy/systemd/thriden-deploy-dispatch.service header; runbook-upgrade-thriden.md § 7b"
    return
  fi
  active="$(systemctl is-active "$unit" 2>/dev/null || true)"
  result="$(systemctl show thriden-deploy-dispatch.service -p Result --value 2>/dev/null || true)"
  exitstatus="$(systemctl show thriden-deploy-dispatch.service -p ExecMainStatus --value 2>/dev/null || true)"
  if [[ "$active" != "active" ]]; then
    report FAIL "6. Upgrade dispatcher timer" "$unit enabled but not active (state=$active)" \
      "systemctl start $unit; check: systemctl status $unit"
    return
  fi
  # The service exits 0 on nothing-to-do, 1 informationally (a wrapper failure /
  # benign claim race) — the unit declares SuccessExitStatus=0 1. Result=success
  # covers both. Empty Result = has not run yet (fresh install) -> WARN.
  if [[ -z "$result" || "$result" == "success" ]]; then
    if [[ -z "$result" ]]; then
      report WARN "6. Upgrade dispatcher timer" "enabled + active, but the service has not run yet" \
        "harmless on a fresh install; it polls every 60s. Re-run the doctor after a minute to confirm a clean run"
    else
      report PASS "6. Upgrade dispatcher timer" "enabled, active, last run clean (Result=success, exit=$exitstatus)"
    fi
  else
    report FAIL "6. Upgrade dispatcher timer" "last run not clean (Result=$result, exit=$exitstatus)" \
      "inspect: journalctl -u thriden-deploy-dispatch.service -n 50"
  fi
}

# ── Check 7 — per-Scion drop-in health ─────────────────────────────────────
check_scions() {
  local -a scions=()
  local f s
  shopt -s nullglob
  for f in compose-*.yml; do s="${f#compose-}"; s="${s%.yml}"; scions+=("$s"); done
  shopt -u nullglob
  if [[ ${#scions[@]} -eq 0 ]]; then
    report WARN "7. Scion health" "no compose-*.yml drop-ins on this host (no Scion provisioned yet)" \
      "provision your first Scion: beta-onboarding.md § 7 / runbook-provision-scion.md"
    return
  fi
  if (( ! wrapped )); then
    report WARN "7. Scion health" \
      "found ${#scions[@]} Scion drop-in(s) (${scions[*]}) but skipped: needs stack.enc.env (see check 2)" ""
    return
  fi
  for s in "${scions[@]}"; do
    local esvc="engram-$s" fsvc="forge-$s"
    local files=("${COMPOSE[@]}" -f "compose-$s.yml")
    # Container running + healthy for both halves.
    local half issues=""
    for half in "$esvc" "$fsvc"; do
      local ps state health
      ps="$(docker compose "${files[@]}" ps "$half" --format json 2>/dev/null)"
      if [[ -z "$ps" || "$ps" == "null" || "$ps" == "[]" ]]; then issues+="$half: not created; "; continue; fi
      # `ps --format json` emits NDJSON in some compose versions and a JSON array
      # in others; `-s` + flatten normalizes both to a single object.
      state="$(printf '%s' "$ps" | jq -rs 'flatten[0].State // empty' 2>/dev/null)"
      health="$(printf '%s' "$ps" | jq -rs 'flatten[0].Health // empty' 2>/dev/null)"
      if [[ -z "$state" ]]; then issues+="$half: not created; "; continue; fi
      if [[ "$state" != "running" ]]; then issues+="$half: state=$state; "
      elif [[ "$health" == "unhealthy" ]]; then issues+="$half: unhealthy; "
      elif [[ "$health" == "starting" ]]; then issues+="$half: still starting; "
      fi
    done
    # Soul binding (instance.json forge_soul_id) on the brain.
    local soul=""
    soul="$(docker compose "${files[@]}" exec -T "$esvc" cat /data/instance.json 2>/dev/null | jq -r '.forge_soul_id // empty' 2>/dev/null)"
    # Canary: 200 fresh, 404 not planted, 503 torpid (planted but asleep).
    local code
    code="$(docker compose "${files[@]}" exec -T "$esvc" \
      sh -c 'curl -s -o /dev/null -w "%{http_code}" -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" http://localhost:3030/admin/canary' 2>/dev/null || echo 000)"

    # Verdict for this Scion.
    if [[ -n "$issues" ]]; then
      report FAIL "7. Scion '$s'" "container issue(s): ${issues%%; }" \
        "docker compose ${COMPOSE[*]} -f compose-$s.yml ps ; logs; do NOT bare 'up -d' a Scion (unbinds the soul) — use bin/thriden-scion-up.sh"
      continue
    fi
    if [[ -z "$soul" ]]; then
      report FAIL "7. Scion '$s'" "running, but forge_soul_id is EMPTY in /data/instance.json (never fully genesis'd)" \
        "re-provision the Scion soul binding: runbook-provision-scion.md"
      continue
    fi
    case "$code" in
      200) report PASS "7. Scion '$s'" "engram+forge healthy, soul bound ($soul), canary fresh" ;;
      503) report WARN "7. Scion '$s'" "healthy + soul bound ($soul); brain is torpid so canary freshness is unverifiable (expected while sleeping)" \
             "no action if the Scion is meant to be asleep; a scheduled brain upgrade rouses + reads the canary itself" ;;
      404) report FAIL "7. Scion '$s'" "healthy + soul bound ($soul) but NO canary planted (Tier 2 smoke would be skipped on a brain swap)" \
             "plant one: POST /admin/canary/plant with an existing node_id (bin/thriden-scion-up.sh does this at bring-up)" ;;
      *)   report WARN "7. Scion '$s'" "healthy + soul bound ($soul); /admin/canary returned http $code" \
             "check the brain: docker compose ${COMPOSE[*]} -f compose-$s.yml logs $esvc" ;;
    esac
  done
}

# ── Check 8 — no *_VERSION shadows in stack.enc.env ────────────────────────
check_version_shadows() {
  if [[ "$DOCTOR_STACK_DECRYPT" != "ok" ]]; then
    report WARN "8. Version shadows" "skipped: stack.enc.env did not decrypt (see check 2)" ""
    return
  fi
  local shadows
  shadows="$(sops -d --output-type dotenv "$stack_env" 2>/dev/null | grep -oE '^[A-Za-z_][A-Za-z0-9_]*_VERSION' | sort -u | paste -sd' ' - || true)"
  if [[ -z "$shadows" ]]; then
    report PASS "8. Version shadows" "no *_VERSION keys pinned in stack.enc.env (tpo4 discipline holds)"
  else
    report WARN "8. Version shadows" "stack.enc.env carries version pin(s): $shadows" \
      "versions belong in deploy/versions.env, not stack.enc.env (tpo4). Legitimate ONLY as a deliberate post-rollback shadow (2wg6). If this is not a fresh rollback, remove them: sops edit $stack_env"
  fi
}

# ── Check 9 — tree state ───────────────────────────────────────────────────
check_tree() {
  if ! command -v git >/dev/null 2>&1 || ! git rev-parse --git-dir >/dev/null 2>&1; then
    report WARN "9. Tree state" "not a git checkout (or git missing); cannot verify recipe version/cleanliness" \
      "the stack dir should be a clone of the Digital-Heresy/Thriden mirror. beta-onboarding.md § 2"
    return
  fi
  # On main, or detached exactly at a thriden-v* tag?
  local branch tag pos
  branch="$(git symbolic-ref -q --short HEAD 2>/dev/null || true)"
  tag="$(git describe --tags --exact-match 2>/dev/null || true)"
  if [[ "$branch" == "main" ]]; then pos="on main"
  elif [[ "$tag" == thriden-v* ]]; then pos="at tag $tag"
  else
    report WARN "9. Tree state" "HEAD is neither main nor a thriden-v* tag (branch='${branch:-detached}', describe='${tag:-none}')" \
      "check out a release: git checkout thriden-v<x.y.z>  (or main). runbook-upgrade-thriden.md"
    # keep going to also report cleanliness below
  fi
  # Cleanliness, ignoring sops re-encryption noise under secrets/ (j248).
  # Porcelain is "XY<space>PATH"; match the path column (starts at char 4) so a
  # worktree-modified secret (" M secrets/…", Y=M) is excluded too — matching on
  # the status chars ('^.[ ?] secrets/') missed exactly that case and turned
  # benign sops diffs into a false FAIL.
  local dirt tracked untracked
  dirt="$(git status --porcelain 2>/dev/null | grep -vE '^...secrets/' || true)"
  tracked="$(printf '%s\n' "$dirt" | grep -E '^ ?[MADRCU]' || true)"
  untracked="$(printf '%s\n' "$dirt" | grep -E '^\?\?' || true)"
  if [[ -n "$tracked" ]]; then
    report FAIL "9. Tree state" "$pos, but tracked recipe files are modified:"$'\n'"$(printf '%s' "$tracked" | sed 's/^/          /')" \
      "restore the recipe: git checkout -- <file>  (local edits to compose/scripts drift from the released recipe)"
  elif [[ -n "$untracked" ]]; then
    report WARN "9. Tree state" "$pos, clean tracked tree, but stray untracked file(s) present:"$'\n'"$(printf '%s' "$untracked" | sed 's/^/          /')" \
      "review + remove strays (the '&1' incident was a stray redirect file). If intentional, add to .gitignore"
  else
    report PASS "9. Tree state" "$pos, clean (secrets/ sops noise ignored)"
  fi
  # Remote reachable (git pull path).
  local ls_ok=1
  if command -v timeout >/dev/null 2>&1; then
    timeout 10 git ls-remote origin -h >/dev/null 2>&1 || ls_ok=0
  else
    git ls-remote origin -h >/dev/null 2>&1 || ls_ok=0
  fi
  (( ls_ok )) || report WARN "9. Tree state (remote)" "git remote 'origin' not reachable" \
    "check network / the mirror URL: git remote -v ; upgrades need 'git pull' to reach the mirror"
}

# ── Run all checks ─────────────────────────────────────────────────────────
check_host_short
check_secrets_decrypt
check_ghcr
check_sops_version
check_validator
check_dispatch_timer
check_scions
check_version_shadows
check_tree

# ── Summary ────────────────────────────────────────────────────────────────
printf '\n%s== Summary ==%s  %s%d PASS%s  %s%d WARN%s  %s%d FAIL%s\n' \
  "$C_BOLD" "$C_RESET" \
  "$C_PASS" "$n_pass" "$C_RESET" \
  "$C_WARN" "$n_warn" "$C_RESET" \
  "$C_FAIL" "$n_fail" "$C_RESET"

if (( n_fail > 0 )); then
  printf '%sNOT golden — resolve the FAIL(s) above before deploying or scheduling an upgrade.%s\n' "$C_FAIL" "$C_RESET"
  exit 1
elif (( n_warn > 0 )); then
  printf '%sMostly healthy, but not all green — review the WARN(s) above.%s\n' "$C_WARN" "$C_RESET"
  exit 0
else
  printf '%sAll green — this install is golden.%s\n' "$C_PASS" "$C_RESET"
  exit 0
fi
