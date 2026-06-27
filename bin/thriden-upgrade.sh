#!/usr/bin/env bash
#
# thriden-upgrade.sh — apply a not-sleep-eligible Thriden upgrade in one
# command. This is the operator-facing one-liner the Forge release page
# advertises for manual (synchronous) upgrades ().
#
#     ssh <host> 'sudo /srv/thriden/bin/thriden-upgrade.sh'
#
# What it does, in order:
#   1. git pull --ff-only            — carries the new deploy/versions.env +
#                                       compose.prod.yml defaults to this host.
#   2. load deploy/versions.env      — the pinned umbrella combination.
#   3. brain-swap guard              — if the pinned ENGRAM_VERSION differs from
#                                       a running engram-<short> brain, ABORT and
#                                       defer to the SCHEDULED (sleep-eligible)
#                                       path: a brain swap needs the pre-flight
#                                       /admin/export + post-flight canary smoke
#                                       + auto-revert that this synchronous path
#                                       does NOT provide. See
#                                       docs/runbook-upgrade-thriden.md.
#   4. legacy-override warning       — if stack.enc.env still pins *_VERSION
#                                       (pre-tpo4), those shadow versions.env;
#                                       warn so a no-op upgrade isn't a mystery.
#   5. substrate                     — pull + recreate forge-web / nooscope.
#   6. per-Scion runtime             — re-run thriden-scion-up.sh per Scion. That
#                                       path re-fetches each Scion's soul/raven
#                                       binding from Mongo before recreate; a
#                                       bare `up -d` would boot the runtime
#                                       UNBOUND (compose-<short>.yml references
#                                       ${<SHORT>_SOUL_ID} as a var, not baked),
#                                       which trips the Scion-death guard on the
#                                       next boot.
#   7. report running versions.
#
# Self-elevates to the deploy service account (owns the stack dir + sops key).
# Overridable via THRIDEN_STACK_DIR / THRIDEN_DEPLOY_USER / THRIDEN_HOST_SHORT.
#
set -euo pipefail

STACK_DIR="${THRIDEN_STACK_DIR:-/srv/thriden}"
DEPLOY_USER="${THRIDEN_DEPLOY_USER:-deploy}"
BASE_COMPOSE="docker compose -f docker-compose.yml -f compose.prod.yml"
STACK_ENV="secrets/prod/stack.enc.env"
VERSIONS_FILE="deploy/versions.env"

if [ "$(id -un)" != "$DEPLOY_USER" ]; then
  echo ">> elevating to '$DEPLOY_USER' (owns the stack dir + sops key) ..." >&2
  exec sudo -u "$DEPLOY_USER" -H "$0" "$@"
fi

cd "$STACK_DIR"
proj="${COMPOSE_PROJECT_NAME:-$(basename "$STACK_DIR")}"

# ── 1. Pull the recipe (versions.env + compose defaults travel with it) ──────
echo ">> git pull --ff-only ..." >&2
git pull --ff-only

# ── 2. Load the pinned umbrella versions ─────────────────────────────────────
if [ ! -f "$VERSIONS_FILE" ]; then
  echo "ERROR: $VERSIONS_FILE not found after pull — this host predates the" >&2
  echo "       versions.env model. Upgrade once via docs/runbook-upgrade-thriden.md" >&2
  echo "       § Manual path, which also migrates you onto versions.env." >&2
  exit 1
fi
set -a; . "./$VERSIONS_FILE"; set +a
echo ">> target: forge=$FORGE_VERSION  forge-runtime=$FORGE_RUNTIME_VERSION  engram=$ENGRAM_VERSION  nooscope=$NOOSCOPE_VERSION" >&2

# ── 3. Brain-swap guard: refuse to swap a running brain synchronously ────────
running_engram_tags="$(docker ps --filter "name=${proj}-engram-" --format '{{.Image}}' \
  | sed -n 's#.*/engram:##p' | sort -u)"
if [ -n "$running_engram_tags" ]; then
  while IFS= read -r tag; do
    [ -n "$tag" ] || continue
    if [ "$tag" != "$ENGRAM_VERSION" ]; then
      cat >&2 <<EOF
ABORT: a running engram brain is on '$tag' but the pinned ENGRAM_VERSION is
       '$ENGRAM_VERSION'. A brain (engram) version change must go through the
       SCHEDULED / sleep-eligible path — it carries the pre-flight backup +
       post-flight canary smoke + auto-revert that this synchronous command
       does not. Schedule it from the Forge /scions banner instead.
       See docs/runbook-upgrade-thriden.md § Scheduled path.
EOF
      exit 1
    fi
  done <<< "$running_engram_tags"
fi

# ── 4. Warn if legacy stack.enc.env version pins still shadow versions.env ───
if sops -d "$STACK_ENV" 2>/dev/null \
     | grep -qE '^(FORGE_VERSION|FORGE_RUNTIME_VERSION|ENGRAM_VERSION|NOOSCOPE_VERSION)='; then
  echo "WARNING: $STACK_ENV still pins one or more *_VERSION vars (pre-tpo4)." >&2
  echo "         Those OVERRIDE deploy/versions.env, so this upgrade may be a" >&2
  echo "         no-op for the shadowed component(s). Migrate by removing those" >&2
  echo "         lines: docs/runbook-upgrade-thriden.md § Migrating off" >&2
  echo "         stack.enc.env version pins." >&2
fi

# ── 5. Substrate: pull + recreate forge-web / nooscope ───────────────────────
host_short="${THRIDEN_HOST_SHORT:-}"
[ -n "$host_short" ] || host_short="$(ls secrets/prod/hosts/ 2>/dev/null | head -n1)"
echo ">> pulling substrate images (host=${host_short:-auto}) ..." >&2
bin/thriden-compose-pull.sh ${host_short:+-h "$host_short"}
echo ">> recreating substrate (forge-web, nooscope) ..." >&2
# This file set is base+prod only — the per-Scion forge-<short>/engram-<short>
# drop-ins are recreated separately below, so compose would flag them as
# orphans. Suppress that warning (COMPOSE_IGNORE_ORPHANS) rather than pass
# --remove-orphans, which would TEAR DOWN the running Scion runtimes.
COMPOSE_IGNORE_ORPHANS=true sops exec-env "$STACK_ENV" "$BASE_COMPOSE up -d forge-web nooscope"

# ── 6. Per-Scion runtime: re-run scion-up (binding-safe) for each drop-in ────
shopt -s nullglob
for f in compose-*.yml; do
  short="${f#compose-}"; short="${short%.yml}"
  cname="${proj}-forge-${short}-1"
  scion_id="$(docker inspect "$cname" --format '{{range .Config.Env}}{{println .}}{{end}}' 2>/dev/null \
    | sed -n 's/^SCION_ID=//p' | head -n1)"
  if [ -z "$scion_id" ]; then
    echo "WARNING: could not derive SCION_ID for '$short' ($cname not running?);" >&2
    echo "         skipping its runtime upgrade. Bring it up with" >&2
    echo "         bin/thriden-scion-up.sh <scion-id> once it's identified." >&2
    continue
  fi
  echo ">> upgrading Scion runtime '$short' (scion=$scion_id) via scion-up ..." >&2
  bin/thriden-scion-up.sh "$scion_id"
done
shopt -u nullglob

# ── 7. Report ────────────────────────────────────────────────────────────────
echo ">> upgrade complete. running images:" >&2
docker ps --filter "name=${proj}-" --format '   {{.Names}}\t{{.Image}}\t{{.Status}}' \
  | grep -iE 'forge|engram|nooscope' || true
