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
#   0. Host command-line deps (docker/jq/curl/git) are on PATH. Without jq the
#      checks below misread rather than fail loudly, so this one runs first.
#   1. Host-short resolves (which chain step matched; warn if fragile).
#   2. secrets/prod/{stack,hosts/<short>/host}.enc.env decrypt with the age key.
#   3. GHCR pull credential works (login/logout round-trip, isolated config).
#   3b. That credential is actually authorized on EVERY pinned image. GHCR
#       access is per-package, so a live PAT missing ONE package's grant passes
#       check 3 and still cannot deploy ().
#   4. sops version >= 3.9 (the wrapper's rollback 'unset' path needs it).
#   5. deploy_payloads validator present AND current vs the shipped schema.
#   6. thriden-deploy-dispatch.timer installed + enabled + last run clean.
#   7. Per Scion drop-in: engram/forge running+healthy, canary fresh, soul bound,
#      and the brain can actually EMBED -- a Voyage key that is configured but
#      REJECTED passes every other check while leaving the Scion unable to form
#      or recall a single memory ().
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

# ── Check 0 — host command-line dependencies ───────────────────────────────
# The deploy path shells out to these; a fresh Ubuntu/WSL image ships none of
# them. `jq` in particular used to fail INVISIBLY here: with it absent, check 5
# compared two empty strings ("stale validator") and check 7 read empty state
# out of `compose ps --format json` and declared healthy containers "not
# created" — i.e. the doctor's own report was the misdiagnosis (Alex, b5d5
# live run). Report the missing tool itself, and have the checks that need it
# skip rather than invent a finding.
have_jq=0; command -v jq >/dev/null 2>&1 && have_jq=1
check_host_deps() {
  local t missing=() apt=()
  for t in docker jq curl git; do
    command -v "$t" >/dev/null 2>&1 && continue
    missing+=("$t")
    # docker is not an apt install on the WSL track — Docker Desktop provides it.
    [[ "$t" == docker ]] || apt+=("$t")
  done
  if [[ ${#missing[@]} -eq 0 ]]; then
    report PASS "0. Host tools" "docker, jq, curl, git all present"
    return
  fi
  local fix=""
  [[ ${#apt[@]} -gt 0 ]] && fix="sudo apt update && sudo apt install -y ${apt[*]}. "
  [[ " ${missing[*]} " == *" docker "* ]] && fix+="docker comes from Docker Desktop's WSL integration (Settings -> Resources -> WSL Integration), not apt. "
  report FAIL "0. Host tools" "missing from PATH: ${missing[*]}" \
    "${fix}beta-onboarding.md § 1"
}

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

# ── Check 3 — GHCR pull credential + per-package pull authorization ────────
# TWO different failures hide behind one symptom here, and telling them apart
# is the entire point of this check:
#
#   3   — is the PAT itself alive?          (`docker login` round-trip)
#   3b  — may this PAT pull EACH pinned image?
#
# GHCR authorization is PER-PACKAGE. `docker login` succeeds for any live token
# carrying read:packages and says NOTHING about which packages it may actually
# fetch. So a PAT missing the grant on ONE package sails through check 3 and
# then dies mid-`thriden-upgrade.sh` on a raw `denied` — which reads as "my
# token expired" and sends the operator to rotate a token that was never the
# problem. Check 3's own fix text used to say exactly that, making a green
# doctor actively misleading.
#
# This is not hypothetical: it is the failure mode built into vendoring the
# socket proxy (). A brand-new private package does NOT inherit
# the grants its siblings already carry, so on the day compose repinned to
# `thriden-socket-proxy` every participant PAT could still pull
# engram/forge/nooscope and not the proxy. 3b names that cause out loud.
check_ghcr() {
  if [[ "$DOCTOR_HOST_DECRYPT" != "ok" ]]; then
    report WARN "3. GHCR pull credential" \
      "skipped: host.enc.env did not decrypt (see check 2)" \
      "fix check 2 first, then re-run"
    report WARN "3b. GHCR per-package pull authorization" \
      "skipped: host.enc.env did not decrypt (see check 2)" \
      "fix check 2 first, then re-run"
    return
  fi

  # Which image refs would a real pull actually fetch? deploy/versions.env is
  # the source of truth, but a legacy *_VERSION still pinned in stack.enc.env
  # shadows it (that is check 8) — and we are ALREADY wrapped in that env, so
  # an inherited value wins below exactly as it wins for `docker compose pull`.
  # Probing the tag that would really be fetched is the only useful probe.
  local vfile="deploy/versions.env" f_forge="" f_noo="" f_sock="" f_engram="" f_runtime=""
  if [[ -f "$vfile" ]]; then
    f_forge="$(sed -n 's/^[[:space:]]*FORGE_VERSION=//p'         "$vfile" | tail -n1)"
    f_noo="$(sed   -n 's/^[[:space:]]*NOOSCOPE_VERSION=//p'      "$vfile" | tail -n1)"
    f_sock="$(sed  -n 's/^[[:space:]]*SOCKET_PROXY_VERSION=//p'  "$vfile" | tail -n1)"
    f_engram="$(sed -n 's/^[[:space:]]*ENGRAM_VERSION=//p'       "$vfile" | tail -n1)"
    f_runtime="$(sed -n 's/^[[:space:]]*FORGE_RUNTIME_VERSION=//p' "$vfile" | tail -n1)"
  fi
  local t_forge="${FORGE_VERSION:-$f_forge}"       t_noo="${NOOSCOPE_VERSION:-$f_noo}"
  local t_sock="${SOCKET_PROXY_VERSION:-$f_sock}"  t_engram="${ENGRAM_VERSION:-$f_engram}"
  local t_runtime="${FORGE_RUNTIME_VERSION:-$f_runtime}"

  # One entry per PACKAGE (that is the ACL unit). forge-runtime rides the same
  # `forge` package, so it is added only when its tag differs — then it tests a
  # tag, not an ACL, and a bad version pin is worth catching too.
  local -a refs=()
  [[ -n "$t_engram"  ]] && refs+=("ghcr.io/digital-heresy/engram:$t_engram")
  [[ -n "$t_forge"   ]] && refs+=("ghcr.io/digital-heresy/forge:$t_forge")
  [[ -n "$t_noo"     ]] && refs+=("ghcr.io/digital-heresy/nooscope:$t_noo")
  [[ -n "$t_sock"    ]] && refs+=("ghcr.io/digital-heresy/thriden-socket-proxy:$t_sock")
  [[ -n "$t_runtime" && "$t_runtime" != "$t_forge" ]] && \
    refs+=("ghcr.io/digital-heresy/forge:$t_runtime")

  # Isolated DOCKER_CONFIG so the probe never persists a credential in the
  # operator's real docker config (same discipline as thriden-compose-pull.sh).
  local cfg; cfg="$(pwd)/.docker-doctor"
  install -d -m 0700 "$cfg"
  export DOCKER_CONFIG="$cfg"

  # Inner script in a tempfile, per thriden-compose-pull.sh note 1: sops
  # exec-env takes ONE sh-command string, and the ref list must cross as
  # environment data rather than be interpolated into that string (injection
  # sink). The EXIT trap closes the credential window before sops tears the
  # env down. Output is one `ref<TAB>verdict<TAB>detail` line per ref, plus a
  # leading `login<TAB>ok|fail` line, so nothing but a verdict escapes the
  # wrap — the token itself never reaches this outer scope.
  local inner; inner="$(mktemp "${TMPDIR:-/tmp}/thriden-doctor-ghcr.XXXXXX.sh")"
  local out; out="$(mktemp "${TMPDIR:-/tmp}/thriden-doctor-ghcr-out.XXXXXX")"
  cat > "$inner" <<'GHCR_EOF'
#!/usr/bin/env bash
set -uo pipefail
trap 'docker logout ghcr.io >/dev/null 2>&1 || true' EXIT
# `docker manifest` is gated behind the experimental CLI flag on older Docker
# releases and unconditional on newer ones; setting this is a no-op on new and
# the enabler on old. We use manifest-inspect rather than a raw registry token
# dance so the credential stays inside docker's own auth handling.
export DOCKER_CLI_EXPERIMENTAL=enabled
if ! printf %s "${GHCR_PULL_TOKEN:?}" \
     | docker login ghcr.io -u "${GHCR_PULL_USER:?}" --password-stdin >/dev/null 2>&1; then
  printf 'login\tfail\t\n'
  exit 0
fi
printf 'login\tok\t\n'
mapfile -t _refs <<< "${THRIDEN_PROBE_REFS:-}"
for r in "${_refs[@]}"; do
  [[ -n "$r" ]] || continue
  if err="$(docker manifest inspect "$r" 2>&1 >/dev/null)"; then
    printf '%s\tok\t\n' "$r"
    continue
  fi
  # Classify on the registry's own words. `denied`/`unauthorized` on a token
  # that JUST logged in successfully means the ACL, not the credential.
  low="$(printf '%s' "$err" | tr '[:upper:]' '[:lower:]' | tr '\n' ' ')"
  case "$low" in
    *denied*|*unauthorized*|*forbidden*|*"insufficient scope"*) v=denied ;;
    *"manifest unknown"*|*"not found"*|*"no such manifest"*)    v=notag  ;;
    *"is not a docker command"*|*"unknown command"*)            v=nocli  ;;
    *)                                                          v=error  ;;
  esac
  printf '%s\t%s\t%s\n' "$r" "$v" "${low:0:160}"
done
GHCR_EOF
  chmod +x "$inner"

  THRIDEN_PROBE_REFS="$(printf '%s\n' "${refs[@]}")" \
    sops exec-env "$host_env" "$inner" >"$out" 2>/dev/null || true

  local login_state; login_state="$(sed -n 's/^login\t\([^\t]*\).*/\1/p' "$out" | head -n1)"
  if [[ "$login_state" == "ok" ]]; then
    report PASS "3. GHCR pull credential" "docker login ghcr.io succeeded (credential is live)"
  else
    report FAIL "3. GHCR pull credential" \
      "docker login ghcr.io failed with the token in host.enc.env" \
      "the PAT itself is dead — most often the 90-day expiry. Drop the new value into $host_env, sops -e -i, re-run. secrets-setup.md; beta-onboarding.md § 9"
    # A dead credential makes every per-package verdict meaningless.
    report WARN "3b. GHCR per-package pull authorization" \
      "skipped: the credential did not log in (see check 3)" \
      "fix check 3 first, then re-run"
    rm -f "$inner" "$out" 2>/dev/null || true
    rm -rf "$cfg" 2>/dev/null || true
    unset DOCKER_CONFIG
    return
  fi

  local denied="" notag="" other="" nocli=0 okn=0 deniedn=0 ref verdict detail
  while IFS=$'\t' read -r ref verdict detail; do
    [[ -n "$ref" && "$ref" != "login" ]] || continue
    case "$verdict" in
      ok)     okn=$((okn+1)) ;;
      denied) denied+="          $ref"$'\n'; deniedn=$((deniedn+1)) ;;
      notag)  notag+="          $ref"$'\n' ;;
      nocli)  nocli=1 ;;
      *)      other+="          $ref  ($detail)"$'\n' ;;
    esac
  done < "$out"

  if (( nocli )); then
    report WARN "3b. GHCR per-package pull authorization" \
      "unverifiable: this docker CLI has no usable 'docker manifest inspect'" \
      "upgrade docker, or prove it by hand: bin/thriden-compose-pull.sh (a 'denied' on ONE image is a package grant, not an expired token — secrets-ops.md § 6b.5.1)"
  elif [[ -n "$denied" ]]; then
    report FAIL "3b. GHCR per-package pull authorization" \
      "the credential is valid but the registry REFUSES $deniedn of $((okn+deniedn)) pinned image(s):"$'\n'"$(printf '%s' "$denied")" \
      "this is a missing package grant, NOT an expired token — do not rotate the PAT. The operator must grant the pulling account Read on each package listed above (Org -> Packages -> <pkg> -> Settings -> Manage access). secrets-ops.md § 6b.5.1 step 2"
  elif [[ -n "$notag" ]]; then
    report FAIL "3b. GHCR per-package pull authorization" \
      "authorized, but the pinned tag does not exist in the registry:"$'\n'"$(printf '%s' "$notag")" \
      "a bad version pin, not an access problem. Reconcile deploy/versions.env (and any *_VERSION shadow in stack.enc.env — see check 8) against the published tags"
  elif [[ -n "$other" ]]; then
    report WARN "3b. GHCR per-package pull authorization" \
      "could not reach a verdict for:"$'\n'"$(printf '%s' "$other")" \
      "usually transient network/registry trouble — re-run. If it persists, prove it by hand with bin/thriden-compose-pull.sh"
  else
    report PASS "3b. GHCR per-package pull authorization" \
      "all $okn pinned image(s) are pullable with this credential"
  fi

  rm -f "$inner" "$out" 2>/dev/null || true
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
  if (( ! have_jq )); then
    report WARN "5. deploy_payloads validator" \
      "skipped: the shipped-vs-live schema comparison needs jq (see check 0)" \
      "install jq, then re-run"
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
        "apply the validator: bin/thriden-deploy-payloads-setup.sh (it self-wraps under sops). A bare 'docker compose up' will NOT work on a prod-layout host -- compose needs MONGO_ROOT_PASSWORD from the encrypted stack env, so it must be: sops exec-env secrets/prod/stack.enc.env 'docker compose -f docker-compose.yml -f compose.prod.yml up -d deploy-payloads-init'"
      return ;;
    *__NO_VALIDATOR__*)
      report FAIL "5. deploy_payloads validator" "collection exists but carries NO \$jsonSchema validator" \
        "apply the validator: bin/thriden-deploy-payloads-setup.sh (it self-wraps under sops). A bare 'docker compose up' will NOT work on a prod-layout host -- compose needs MONGO_ROOT_PASSWORD from the encrypted stack env, so it must be: sops exec-env secrets/prod/stack.enc.env 'docker compose -f docker-compose.yml -f compose.prod.yml up -d deploy-payloads-init'"
      return ;;
  esac
  # Present -> is it current? Compare against the shipped schema, stripped of
  # the same metadata keys the setup script strips, both canonicalized.
  want="$(jq -cS 'del(."$schema", ."$id", .title, .description)' schemas/deploy-payload-mongo.schema.json 2>/dev/null)"
  got="$(printf '%s' "$live" | jq -cS . 2>/dev/null)"
  if [[ -n "$got" && "$got" == "$want" ]]; then
    report PASS "5. deploy_payloads validator" "present and matches shipped schema"
  else
    # Say HOW it differs. "Stale" alone sends the reader to re-run the applier,
    # and when that does not fix it they have nowhere to go (: a
    # participant re-applied and got the identical WARN). The key delta tells
    # "older schema" apart from "the applier and this checker disagree".
    local delta="" only_shipped="" only_live="" rq_s="" rq_l=""
    if [[ -n "$got" ]]; then
      only_shipped="$(comm -23 <(jq -r 'keys[]' <<<"$want" 2>/dev/null | sort) <(jq -r 'keys[]' <<<"$got" 2>/dev/null | sort) | paste -sd, -)"
      only_live="$(comm -13 <(jq -r 'keys[]' <<<"$want" 2>/dev/null | sort) <(jq -r 'keys[]' <<<"$got" 2>/dev/null | sort) | paste -sd, -)"
      [[ -n "$only_shipped" ]] && delta+=" Shipped-only keys: $only_shipped."
      [[ -n "$only_live" ]] && delta+=" Live-only keys: $only_live."
      if [[ -z "$delta" ]]; then
        rq_s="$(jq -r '.required // [] | join(",")' <<<"$want" 2>/dev/null)"
        rq_l="$(jq -r '.required // [] | join(",")' <<<"$got" 2>/dev/null)"
        if [[ "$rq_s" != "$rq_l" ]]; then
          delta=" required[] differs -- shipped: [$rq_s]; live: [$rq_l]."
        else
          delta=" Same top-level keys and required[]; the difference is nested (a property constraint)."
        fi
      fi
    else
      delta=" (the live validator did not parse as JSON.)"
    fi
    report WARN "5. deploy_payloads validator" \
      "validator present but DIFFERS from schemas/deploy-payload-mongo.schema.json (stale).${delta}" \
      "refresh it: bin/thriden-deploy-payloads-setup.sh (it self-wraps under sops). A bare 'docker compose up' will NOT work on a prod-layout host -- compose needs MONGO_ROOT_PASSWORD from the encrypted stack env, so it must be: sops exec-env secrets/prod/stack.enc.env 'docker compose -f docker-compose.yml -f compose.prod.yml up -d deploy-payloads-init'"
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
    local fix6="systemctl start $unit; check: systemctl status $unit"
    # 'failed' is not the same as 'stopped', and the difference matters: a unit
    # that failed once STAYS failed until reset, so this keeps reporting the old
    # failure after the cause is fixed — which reads as "the fix did not work"
    # (: a participant fixed the underlying unit, saw the service
    # start cleanly, and still got this FAIL from a failure minutes earlier).
    # `start` alone will not clear it.
    if [[ "$active" == "failed" ]]; then
      fix6="read WHY first: systemctl status $unit --no-pager -l . Then, once the cause is fixed, clear the latched state — a failed unit stays failed and 'start' alone will not clear it: sudo systemctl reset-failed $unit && sudo systemctl restart $unit"
    fi
    report FAIL "6. Upgrade dispatcher timer" "$unit enabled but not active (state=$active)" \
      "$fix6"
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
    # "No drop-ins here" and "no Scion on this host" are different claims, and
    # conflating them hides a real split brain: a participant's Scion was running
    # and answering while this check reported nothing provisioned, because the
    # containers had been brought up from a DIFFERENT clone than the one the
    # doctor ran in (). The dispatcher points at THIS directory, so
    # a scheduled upgrade would act on a Scion set it cannot see.
    #
    # But "engram container running" alone is not the tell: on a DEV host the
    # Scions are ordinary services in the base compose (the mirror strips them),
    # so they run with no drop-in and are perfectly healthy. The discriminator is
    # whether the base compose itself declares the service -- if it does, this is
    # a dev box, not a split brain. Getting this wrong would fail every localhost
    # run, which is how a check earns its way onto the ignore list.
    # Only trust this when docker actually answers. With Docker Desktop stopped
    # (or WSL integration off) the `docker` shim prints its "could not be found"
    # advice to STDOUT, which a naive read would treat as a container name and
    # report as an orphan -- inventing a split brain out of a stopped daemon.
    local running known orphans=""
    if docker info >/dev/null 2>&1; then
      running="$(docker ps --filter "name=engram-" --format '{{.Names}}' 2>/dev/null                  | grep -E '^[A-Za-z0-9][A-Za-z0-9_.-]*$' || true)"
    fi
    if [[ -n "$running" ]]; then
      known="$(docker compose -f docker-compose.yml config --services 2>/dev/null | grep '^engram-' || true)"
      local c svc
      while IFS= read -r c; do
        [[ -n "$c" ]] || continue
        # container name is <project>-<service>-<n>; recover the service.
        svc="$(printf '%s' "$c" | sed -E 's/^.*-(engram-[A-Za-z0-9_-]+)-[0-9]+$//')"
        grep -qx "$svc" <<<"$known" || orphans+="$c "
      done <<<"$running"
    fi
    if [[ -n "$orphans" ]]; then
      report FAIL "7. Scion health"         "engram container(s) are RUNNING (${orphans% }) but this stack dir has neither a compose-*.yml drop-in nor a base-compose service for them — they were provisioned from a different directory than $(pwd)"         "you are almost certainly running from a second clone. Find the one that provisioned them (it holds compose-<short>.yml) and use that as your stack dir, or re-render here with bin/thriden-scion-up.sh <scion-id>. Until they agree, upgrades and the dispatcher act on a Scion set this directory cannot see"
      return
    fi
    report WARN "7. Scion health" "no compose-*.yml drop-ins here, and no unaccounted-for engram containers — no Scion provisioned yet" \
      "provision your first Scion: beta-onboarding.md § 7 / runbook-provision-scion.md"
    return
  fi
  if (( ! wrapped )); then
    report WARN "7. Scion health" \
      "found ${#scions[@]} Scion drop-in(s) (${scions[*]}) but skipped: needs stack.enc.env (see check 2)" ""
    return
  fi
  if (( ! have_jq )); then
    report WARN "7. Scion health" \
      "found ${#scions[@]} Scion drop-in(s) (${scions[*]}) but skipped: container state + soul binding are read with jq (see check 0)" \
      "install jq, then re-run — without it this check cannot tell a healthy Scion from a missing one"
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
    # Embedding capability (). A brain whose Voyage key is being
    # REJECTED passes every check above -- containers up, healthy, soul bound,
    # canary fresh -- and still cannot form or recall a single memory: recall
    # embeds the query text before the ANN lookup, so every message 500s. That
    # is the beta participant's incident (), and "all green" said
    # golden throughout it.
    #
    # /admin/embedding is authenticated, so the read happens INSIDE the
    # container with $ENGRAM_RAVEN_TOKEN, exactly like the canary probe below --
    # the token never crosses into the host env. It is also O(1), unlike the
    # same flags on /stats, which walks every node (~1s at 500 nodes and worse
    # from there); the doctor only pays that scan when it has already decided
    # to FAIL and wants the pending count for the message.
    #
    # A torpid brain 503s here (torpor gates read routes), leaving both values
    # empty -- so both branches below fall through and the canary clause reports
    # the torpor, rather than this clause inventing an embedding verdict from a
    # sleeping brain.
    local emb emb_code emb_body embed_cfg embed_ok
    emb="$(docker compose "${files[@]}" exec -T "$esvc" \
      sh -c 'curl -s -w "\n%{http_code}" -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" http://localhost:3030/admin/embedding' 2>/dev/null || true)"
    emb_code="$(printf '%s' "$emb" | tail -n1)"
    emb_body="$(printf '%s' "$emb" | sed '$d')"
    embed_cfg="$(printf '%s' "$emb_body" | jq -r '.voyage_configured // empty' 2>/dev/null)"
    embed_ok="$(printf '%s' "$emb_body" | jq -r '.embedding_ok // empty' 2>/dev/null)"
    local embed_why
    embed_why="$(printf '%s' "$emb_body" | jq -r '.last_error_kind // empty' 2>/dev/null)"

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
    # A brain rejecting our credential presents EXACTLY like a brain that cannot
    # embed: every call fails, the Scion answers nothing, and the containers all
    # look fine ( raised this from the in-voice side -- 401 is
    # an operator condition, nothing the human in the room did). Distinguish it
    # here rather than leaving an "http 401" crumb in the canary clause, since
    # the remedy is completely different: fix the token, not the Voyage key.
    if [[ "$emb_code" == "401" || "$emb_code" == "403" ]]; then
      report FAIL "7. Scion '$s'" \
        "engram is REJECTING our credential (http $emb_code) — every authenticated call from the runtime fails, so the Scion cannot read or write memory at all. This is a token problem, NOT a provider problem" \
        "the runtime's ENGRAM_RAVEN_TOKEN and the brain's configured credential disagree. Both come from the Scion's Mongo doc via 'personaforge-admin scion runtime-env' — re-run bin/thriden-scion-up.sh <scion-id> to re-fetch and recreate. Engram logs the rejection to <data_dir>/audit.jsonl as auth_failure/scope_denied if you need to confirm which"
      continue
    fi
    # A brain that cannot embed is useless even though everything above passed,
    # so this outranks the canary verdict.
    if [[ "$embed_cfg" == "true" && "$embed_ok" == "false" ]]; then
      # Only now is the O(N) /stats scan worth it: enrich the failure with how
      # many memories are sitting unembedded behind the broken key.
      local pending extra=""
      pending="$(docker compose "${files[@]}" exec -T "$esvc" \
        sh -c 'curl -fsS -H "Authorization: Bearer $ENGRAM_RAVEN_TOKEN" http://localhost:3030/stats' 2>/dev/null \
        | jq -r '.pending_embed_nodes // 0' 2>/dev/null || true)"
      [[ -n "$pending" && "$pending" != "0" ]] && extra=" $pending memory(ies) are stored but unembedded and NOT searchable."
      # Say WHICH failure. A rate limit and a rejected key both read as "cannot
      # embed", but the remedies are opposites — and sending someone to rotate a
      # key that a 429 has nothing to do with is exactly how the beta
      # participant's second incident would have been misdiagnosed as a relapse
      # of the first. Report only what the signal establishes.
      case "$embed_why" in
        rate_limit)
          report FAIL "7. Scion '$s'" \
            "brain cannot embed — Voyage is RATE LIMITING this account (429), not rejecting the key.${extra} Memory formation and recall fail while it lasts, but nothing is misconfigured" \
            "Voyage's per-minute caps are tied to your usage tier, and an account with NO PAYMENT METHOD sits below Tier 1 with limits low enough that ordinary Scion traffic trips them. Adding a payment method qualifies you for Tier 1 — your free token grant still applies, so this raises the rate ceiling rather than starting a bill. https://docs.voyageai.com/docs/rate-limits . Do NOT rotate the key; that is a different failure (this check names it 'rejecting the key' when it is)" ;;
        auth)
          report FAIL "7. Scion '$s'" \
            "brain CANNOT EMBED — VOYAGE_API_KEY is configured but the provider is REJECTING it.${extra} This Scion cannot form or recall memories; every message fails with a 500 from /query" \
            "verify the key (curl -s https://api.voyageai.com/v1/embeddings -H \"Authorization: Bearer \$KEY\" -H 'Content-Type: application/json' -d '{\"input\":[\"t\"],\"model\":\"voyage-3-lite\"}'), fix it in secrets/prod/stack.enc.env, then bin/thriden-scion-up.sh <scion-id> to recreate (a restart will NOT re-read it). Then POST /admin/reindex to re-embed anything stored while it was broken" ;;
        *)
          report FAIL "7. Scion '$s'" \
            "brain cannot embed — the last embedding attempt failed${embed_why:+ ($embed_why)}.${extra} This Scion cannot form or recall memories" \
            "check the brain's logs for the provider's own error: docker compose ${COMPOSE[*]} -f compose-$s.yml logs --tail 50 $esvc . Then POST /admin/reindex once it is embedding again" ;;
      esac
      continue
    fi
    if [[ "$embed_cfg" == "false" ]]; then
      report WARN "7. Scion '$s'" \
        "no VOYAGE_API_KEY — the brain is running on local hash embeddings; it works, but recall quality is badly degraded" \
        "set VOYAGE_API_KEY in secrets/prod/stack.enc.env and recreate with bin/thriden-scion-up.sh <scion-id>. beta-onboarding.md § 4"
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
  # Exclude host-local files a correct install is SUPPOSED to have. The mirror
  # does not ship a .gitignore covering them, so git reports the participant's
  # own required config as strays — .sops.yaml and .thriden-host-short are
  # literally created by following the onboarding guide, and compose-<short>.yml
  # is written by scion-up. Flagging those trains people to ignore this check,
  # which is the opposite of what it is for ().
  dirt="$(git status --porcelain 2>/dev/null \
          | grep -vE '^...(secrets/|\.sops\.yaml|\.thriden-host-short|\.docker/|compose-[A-Za-z0-9._-]+\.yml)' \
          || true)"
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
check_host_deps
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
