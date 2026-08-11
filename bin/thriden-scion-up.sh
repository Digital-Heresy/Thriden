#!/usr/bin/env bash
#
# thriden-scion-up.sh — bring a provisioned Scion's runtime online in one
# command (MindHive-<bean> /  follow-up).
#
# After Genesis (Web Incubator) a Scion exists in Mongo but isn't running.
# Bringing it up on the Thriden host means: render an image-pinned
# compose-<short>.yml, then `up` engram-<short> + forge-<short>. That path
# carries deployment ceremony an operator shouldn't have to memorise —
# the stack dir and the sops age key belong to the `deploy` service
# account, and the compose needs the prod overlay + a decrypted env. This
# wrapper hides all of it so a normal admin login just runs:
#
#     /srv/thriden/bin/thriden-scion-up.sh <scion-id>
#
# It self-elevates to `deploy`, renders the compose via the in-container
# `personaforge-admin` (forge image only — no host PF install needed), and
# brings up the two services. Idempotent: re-running re-renders the file
# and reconciles the services.
#
# Overridable via env: THRIDEN_STACK_DIR, THRIDEN_DEPLOY_USER, THRIDEN_SECRETS.
#
set -euo pipefail

STACK_DIR="${THRIDEN_STACK_DIR:-/srv/thriden}"
DEPLOY_USER="${THRIDEN_DEPLOY_USER:-deploy}"
SECRETS="${THRIDEN_SECRETS:-secrets/prod/stack.enc.env}"
BASE_COMPOSE="docker compose -f docker-compose.yml -f compose.prod.yml"

SCION_ID="${1:-}"
if [ -z "$SCION_ID" ]; then
  echo "usage: $(basename "$0") <scion-id>" >&2
  exit 2
fi
# A scion id is server-side constrained to this charset. Validate before it
# ever reaches a sops `sh -c` string below — anything else is bogus and could
# be a shell-injection attempt (e.g. `x; rm -rf /`).
case "$SCION_ID" in
  *[!A-Za-z0-9._-]*)
    echo "ERROR: invalid scion id '$SCION_ID' (allowed: letters, digits, . _ -)." >&2
    exit 2 ;;
esac

# The stack dir (writes) and the sops age key (decrypt) belong to the
# deploy service account. If we're not it yet, re-exec under it; the
# operator just needs sudo rights (the normal admin login has them).
if [ "$(id -un)" != "$DEPLOY_USER" ]; then
  echo ">> elevating to '$DEPLOY_USER' (owns the stack dir + sops key) ..." >&2
  exec sudo -u "$DEPLOY_USER" -H "$0" "$@"
fi

cd "$STACK_DIR"

# Pin component versions from the non-secret manifest () so a host
# migrated off stack.enc.env version pins still gets a pinned ENGRAM_VERSION /
# FORGE_RUNTIME_VERSION rather than the `:-main` footgun. A *_VERSION still in
# stack.enc.env wins — `sops exec-env "$SECRETS"` layers it on top below.
[ -f deploy/versions.env ] && { set -a; . ./deploy/versions.env; set +a; }

echo ">> rendering image-pinned compose for '$SCION_ID' ..." >&2
yaml="$(sops exec-env "$SECRETS" \
  "$BASE_COMPOSE exec -T forge-web personaforge-admin scion runtime-compose $SCION_ID --image")"

# The rendered fragment names its services engram-<short> / forge-<short>;
# pull <short> back out so we name the file + target the `up` correctly.
short="$(printf '%s\n' "$yaml" | sed -n 's/^  forge-\([a-z0-9][a-z0-9_-]*\):.*/\1/p' | head -n1)"
if [ -z "$short" ]; then
  echo "ERROR: could not derive the runtime short from the rendered compose." >&2
  echo "       Is '$SCION_ID' a real, provisioned Scion?" >&2
  echo "       ($BASE_COMPOSE exec -T forge-web personaforge-admin scion show $SCION_ID)" >&2
  exit 1
fi

file="compose-$short.yml"
printf '%s\n' "$yaml" > "$file"
echo ">> wrote $STACK_DIR/$file (short=$short)" >&2

upper="$(printf '%s' "$short" | tr 'a-z-' 'A-Z_')"
soul_var="${upper}_SOUL_ID"
raven_var="${upper}_RAVEN_TOKEN"

# Bring-up bindings, sourced from Mongo. <SHORT>_SOUL_ID + <SHORT>_RAVEN_TOKEN
# already live on the Scion's Mongo doc (Genesis stored them), so fetch them
# straight from there via the in-container CLI — no operator-wired SOPS/git.
# runtime-env emits shell-safe `KEY=value` lines — PF's cmd_runtime_env asserts
# both values match ^[A-Za-z0-9_.-]+$ before printing. We parse + export them
# directly (the same read-loop the per-Scion SOPS overlay uses below) rather
# than `eval`-ing the command output, so a regression in that emitter guard
# can't turn a corrupt Mongo doc into host code execution here. The exported
# vars layer under the stack-env `sops exec-env up` below and carry straight
# through to the containers' ${<SHORT>_SOUL_ID} interpolation.
echo ">> fetching $soul_var + $raven_var from Mongo ..." >&2
while IFS= read -r line; do
  case "$line" in
    ''|'#'*)        continue ;;
    [A-Za-z_]*=*)   export "$line" ;;
    *)              echo "WARN: ignoring unexpected runtime-env line" >&2 ;;
  esac
done < <(sops exec-env "$SECRETS" \
  "$BASE_COMPOSE exec -T forge-web personaforge-admin scion runtime-env $SCION_ID")

# Opt-in override: if an operator has staged a per-Scion SOPS file (the future
# Scion-managed-vault tier), overlay it on top so it shadows the Mongo values.
scion_secrets="secrets/prod/scions/$short/runtime.enc.env"
if [ -f "$scion_secrets" ]; then
  echo ">> overlaying per-Scion secrets $scion_secrets ..." >&2
  while IFS= read -r line; do
    case "$line" in ''|'#'*) continue ;; esac
    export "$line"
  done < <(sops -d "$scion_secrets")
fi

# Soul-binding guard. After the Mongo fetch this is set unless the Scion was
# never fully genesis'd (no forge_soul_id). An empty value would boot the
# engram brain UNBOUND, and a SECOND boot then trips the Scion-death
# forge_soul_id mismatch — so refuse rather than footgun.
if [ -z "${!soul_var:-}" ]; then
  cat >&2 <<EOF
ERROR: $soul_var came back empty — '$SCION_ID' has no forge_soul_id in Mongo.
       Was it fully genesis'd?
         $BASE_COMPOSE exec -T forge-web personaforge-admin scion show $SCION_ID
EOF
  exit 1
fi
if [ -z "${!raven_var:-}" ]; then
  echo "WARNING: $raven_var is empty — engram may reject authenticated writes." >&2
fi

# Pull the per-Scion images from private GHCR first. engram:main has never
# been on this host (no engram service in the substrate compose), so the first
# bring-up has to fetch it — and `docker compose up` can't auth to GHCR on its
# own (it'd fail "unauthorized"). thriden-compose-pull.sh holds the narrow
# docker-login -> pull -> logout credential window; adding the per-Scion -f so
# it resolves engram-<short> / forge-<short>. Host-short resolution lives
# inside compose-pull (bin/thriden-host-short.lib.sh; THRIDEN_HOST_SHORT still
# honored via that chain).
echo ">> pulling images from GHCR ..." >&2
bin/thriden-compose-pull.sh -f docker-compose.yml -f compose.prod.yml -f "$file"

echo ">> bringing up engram-$short + forge-$short ..." >&2
sops exec-env "$SECRETS" \
  "$BASE_COMPOSE -f $file up -d --pull never engram-$short forge-$short"

# Mark the Scion stack-managed (engram_external=true). The engram-<short> brain
# we just stood up IS its engram — set the flag via the in-container CLI so the
# Web Incubator shows it 'forged' (out of the kiln gate) with no operator
# command. Idempotent. Non-fatal: a bound brain that isn't flagged still runs.
echo ">> marking $SCION_ID stack-managed (engram_external) ..." >&2
sops exec-env "$SECRETS" \
  "$BASE_COMPOSE exec -T forge-web personaforge-admin scion update $SCION_ID engram_external=true" \
  >/dev/null 2>&1 || echo "   (warning: could not set engram_external; set it from the detail page)" >&2

# ── Auto-plant a smoke canary () ──────────────────────────────
# A fresh Scion has no canary, so every upgrade-at-wake deploy tier-2 soft-skips
# and retrieval-path validation is silently off until an operator remembers
# runbook-provision-scion § 8. Beta participants will not remember. Plant (or
# refresh) it here: designate the newest node via engram's /admin/canary/plant.
# Idempotent — re-planting on every scion-up self-heals a stale/deleted canary
# (staleness was the 8unq soft-skip's second cause). Strictly best-effort: a
# failure never fails the bring-up (the brain is already online + bound).
#
# The raven token stays IN the container (curl reads $ENGRAM_RAVEN_TOKEN there),
# never threaded through the host env; the plant body crosses via stdin to
# curl --data-binary @-, so the node id never rides a shell string (5hxi). jq
# parses on the host — the engram image ships curl but not jq (same split as
# bin/thriden-deploy-payload.sh). Always returns 0.
plant_smoke_canary() {
  local svc="engram-$short" i ready=0 nodes_json node_id
  if ! command -v jq >/dev/null; then
    echo "   (canary: jq is not installed on this host, so the smoke canary was not" >&2
    echo "    planted — the bring-up itself succeeded and your Scion is up. Install it" >&2
    echo "    (sudo apt install -y jq) and re-run this command to arm tier-2 validation.)" >&2
    return 0
  fi
  # Wait for the freshly-(re)started brain's HTTP to answer. /health is
  # unauthenticated and not torpor-gated.
  for i in $(seq 1 15); do
    if sops exec-env "$SECRETS" \
         "$BASE_COMPOSE -f $file exec -T $svc sh -c 'curl -fsS -o /dev/null http://localhost:3030/health'" \
         >/dev/null 2>&1; then ready=1; break; fi
    sleep 2
  done
  if [ "$ready" -ne 1 ]; then
    echo "   (canary: $svc /health not ready after ~30s; skipping auto-plant)" >&2
    return 0
  fi
  # /nodes + /admin/canary/plant 503 while torpid (a recreate can resume
  # torpid); rouse is idempotent (no-op on an active brain).
  sops exec-env "$SECRETS" \
    "$BASE_COMPOSE -f $file exec -T $svc sh -c 'curl -fsS -X POST -H \"Authorization: Bearer \$ENGRAM_RAVEN_TOKEN\" http://localhost:3030/admin/rouse'" \
    >/dev/null 2>&1 || echo "   (canary: pre-read rouse failed; /nodes may 503)" >&2
  # Newest node is the canary target. /nodes?limit=1 is cheap (early-break, one
  # store.get); host-side jq pulls the id out.
  nodes_json=$(sops exec-env "$SECRETS" \
    "$BASE_COMPOSE -f $file exec -T $svc sh -c 'curl -fsS -H \"Authorization: Bearer \$ENGRAM_RAVEN_TOKEN\" \"http://localhost:3030/nodes?limit=1\"'" \
    2>/dev/null || true)
  node_id=$(printf '%s' "$nodes_json" | jq -r '.[0].id // empty' 2>/dev/null || true)
  if [ -z "$node_id" ]; then
    echo "   (canary: $svc has no nodes yet; skipping — tier-2 soft-skips until the brain has content)" >&2
    return 0
  fi
  # Defense in depth: the id is from our own API, but validate the UUID charset
  # before it's used (it doesn't enter a command string — the body crosses via
  # stdin to curl --data-binary @-, the same way the wrapper feeds /admin/import).
  case "$node_id" in
    ''|*[!0-9A-Fa-f-]*)
      echo "   (canary: unexpected node id from /nodes; skipping)" >&2; return 0 ;;
  esac
  if printf '{"node_id":"%s"}' "$node_id" | sops exec-env "$SECRETS" \
       "$BASE_COMPOSE -f $file exec -T $svc sh -c 'curl -fsS -X POST -H \"Authorization: Bearer \$ENGRAM_RAVEN_TOKEN\" -H \"Content-Type: application/json\" --data-binary @- http://localhost:3030/admin/canary/plant'" \
       >/dev/null 2>&1; then
    echo ">> planted smoke canary on $svc: node $node_id (tier-2 now armed)" >&2
  else
    echo "   (canary: plant call failed for $svc; tier-2 will soft-skip — plant manually per runbook-provision-scion § 8)" >&2
  fi
  return 0
}
plant_smoke_canary

# ── Verify commands ────────────────────────────────────────────────────────
# Print what actually WORKS, not the bare compose invocation. The operator's
# shell is neither `deploy` nor inside $STACK_DIR, and every compose call
# against this stack needs the decrypted stack env: docker-compose.yml gives
# MONGO_ROOT_PASSWORD no default (`:?`), so a bare $BASE_COMPOSE dies with
#
#   error while interpolating services.mongodb.environment.MONGO_INITDB_ROOT_PASSWORD:
#   required variable MONGO_ROOT_PASSWORD is missing a value
#
# before it ever reaches the service being asked about. Every internal op in
# this script is already sops-wrapped, so the script did the right thing
# throughout and then handed the operator advice that had drifted from its own
# practice. The first beta participant to stand a Scion up hit exactly this and
# had to re-wrap the command by hand ().
#
# SUDO_USER is set iff we came through the self-elevation above (or the
# operator sudo'd in themselves) -- the same condition under which their own
# shell needs the `sudo -u deploy` prefix to reach the stack dir and the age
# key. Already running as `deploy`? The prefix is not just noise, it may not be
# permitted, so print the plain form. Either way the `cd` is included: nothing
# guarantees the operator's cwd, and both the compose files and $SECRETS are
# relative paths.
#
# Quoting: `sops exec-env` takes its command as ONE shell string (it runs it via
# `sh -c`), so the compose command is single-quoted inside the double-quoted
# `bash -c` payload. No value interpolated below can contain a quote --
# SCION_ID is charset-validated at the top of this script, $short is derived
# from a rendered service name, and the rest are our own constants.
verify_cmd() {
  local inner="$BASE_COMPOSE -f $file $*"
  if [ -n "${SUDO_USER:-}" ]; then
    printf '     sudo -u %s -H bash -c "cd %s && sops exec-env %s '\''%s'\''"\n' \
      "$DEPLOY_USER" "$STACK_DIR" "$SECRETS" "$inner"
  else
    printf '     cd %s && sops exec-env %s '\''%s'\''\n' \
      "$STACK_DIR" "$SECRETS" "$inner"
  fi
}

echo ">> up. verify the binding + health:" >&2
verify_cmd ps >&2
# -T (no TTY) so the command also works non-interactively -- the documented
# remote form is `ssh <host> '<command>'`, which has no TTY to allocate.
verify_cmd exec -T "engram-$short" cat /data/instance.json >&2
