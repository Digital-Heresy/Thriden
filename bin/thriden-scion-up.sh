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
# it resolves engram-<short> / forge-<short>. Host short = the single dir under
# secrets/prod/hosts/ (override with THRIDEN_HOST_SHORT for multi-host).
host_short="${THRIDEN_HOST_SHORT:-}"
if [ -z "$host_short" ]; then
  host_short="$(ls secrets/prod/hosts/ 2>/dev/null | head -n1)"
fi
pull_args=(-f docker-compose.yml -f compose.prod.yml -f "$file")
[ -n "$host_short" ] && pull_args=(-h "$host_short" "${pull_args[@]}")
echo ">> pulling images from GHCR (host=${host_short:-auto}) ..." >&2
bin/thriden-compose-pull.sh "${pull_args[@]}"

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

echo ">> up. verify the binding + health:" >&2
echo "     $BASE_COMPOSE -f $file ps" >&2
echo "     $BASE_COMPOSE -f $file exec engram-$short cat /data/instance.json" >&2
