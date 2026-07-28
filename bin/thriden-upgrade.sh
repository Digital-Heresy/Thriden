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

# Resolve our OWN absolute path while we are still in the invocation cwd, before
# the `cd` below. The step-1b self-update check re-execs this path, and it has to
# survive every invocation form we support: a relative `bin/thriden-upgrade.sh`,
# an absolute `/srv/thriden/bin/thriden-upgrade.sh`, and the `sudo -u deploy`
# self-elevation above (which passes "$0" through unchanged).
SELF="$(cd "$(dirname "$0")" && pwd -P)/$(basename "$0")"

cd "$STACK_DIR"
proj="${COMPOSE_PROJECT_NAME:-$(basename "$STACK_DIR")}"

# ── 1. Pull the recipe (versions.env + compose defaults travel with it) ──────
# Hash ourselves BEFORE anything that can rewrite the working tree. That means
# before the detached-HEAD checkout below, not merely before the pull: on a host
# recovering from a scheduled deploy, HEAD sits detached at an OLD release tag,
# so `git checkout main` is itself very likely to be what replaces this script —
# and if the subsequent pull is then a no-op, a hash taken after the checkout
# would compare equal and the guard would miss the change entirely. That is the
# exact bug this guard exists to prevent, one step earlier than it was watching.
self_before="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1 || true)"
if [ -z "$self_before" ]; then
  # Never silently degrade to "assume unchanged" -- that is fail-OPEN, and it
  # reintroduces precisely the staleness this guard closes. Not fatal (a broken
  # self-hash is no reason to abort a working upgrade), but it must be visible.
  echo ">> WARN: could not hash $SELF -- self-update detection is DISABLED for" >&2
  echo "         this run. If this release changes the deploy scripts, re-run." >&2
fi

# A prior scheduled deploy (bin/thriden-deploy-payload.sh self-sync, )
# leaves HEAD detached at a release tag; `git pull --ff-only` can't fast-forward a
# detached HEAD. Re-attach to main first — but only when detached, so an operator
# deliberately on a branch isn't yanked off it. No-op on a host already on a branch.
if ! git symbolic-ref -q HEAD >/dev/null; then
  echo ">> HEAD detached (prior scheduled deploy) — checking out main ..." >&2
  git checkout main
fi
echo ">> git pull --ff-only ..." >&2
git pull --ff-only

# ── 1b. Self-update guard: re-exec if the pull replaced THIS script ─────────
# The pull carries a new copy of this very file. Without this block bash keeps
# executing the copy it already loaded, which is wrong in two ways ():
#
#   1. Any fix to this script lands ONE RUN LATE. Seen live on Cairn upgrading
#      thriden-v0.15.0 -> v0.16.0: the run that delivered "also recreate
#      docker-socket-proxy" pulled the new image, upgraded everything else, and
#      left the proxy on the old container -- while printing "upgrade complete".
#      Silently doing less than the release claimed is the dangerous shape,
#      because the operator gets no signal anything was missed.
#   2. Worse, bash reads a script INCREMENTALLY, tracking a byte offset into the
#      open file. Replacing that file mid-run can make the next read land
#      mid-statement. We have not been bitten, but the failure would be arbitrary
#      and unreproducible, in the script that upgrades production.
#
# Re-exec IMMEDIATELY so as little of the stale body runs as possible. The guard
# env var makes it at most once: if a second change appears within the same run
# something is wrong (a moving branch, a concurrent deploy), and looping forever
# on a production host is worse than finishing on a known-current copy.
if [ -n "$self_before" ]; then
  self_after="$(sha256sum "$SELF" 2>/dev/null | cut -d' ' -f1 || true)"
  if [ -z "$self_after" ]; then
    echo ">> WARN: could not re-hash $SELF after the pull -- cannot tell whether" >&2
    echo "         this script changed. If this release touches the deploy" >&2
    echo "         scripts, re-run to be sure the new logic applied." >&2
  fi
  if [ -n "$self_after" ] && [ "$self_before" != "$self_after" ]; then
    if [ -n "${THRIDEN_UPGRADE_REEXECED:-}" ]; then
      echo ">> WARN: $SELF changed again after re-exec -- continuing on the" >&2
      echo "         current copy rather than looping. Re-run to be certain." >&2
    else
      echo ">> the pull updated this script -- re-execing the new copy ..." >&2
      export THRIDEN_UPGRADE_REEXECED=1
      exec "$SELF" "$@"
    fi
  fi
fi

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

# ── 5. Substrate: pull + recreate forge-web / nooscope / docker-socket-proxy ─
# Host-short resolution lives inside compose-pull now (bin/thriden-host-short.lib.sh);
# THRIDEN_HOST_SHORT is still honored via that chain.
echo ">> pulling substrate images ..." >&2
bin/thriden-compose-pull.sh
echo ">> recreating substrate (forge-web, nooscope, docker-socket-proxy) ..." >&2
# This file set is base+prod only — the per-Scion forge-<short>/engram-<short>
# drop-ins are recreated separately below, so compose would flag them as
# orphans. Suppress that warning (COMPOSE_IGNORE_ORPHANS) rather than pass
# --remove-orphans, which would TEAR DOWN the running Scion runtimes.
# docker-socket-proxy is in this list because compose-pull above fetches every
# service's image with no filter, so a SOCKET_PROXY_VERSION bump WOULD land in
# the local cache and then never be applied -- the running proxy would sit on
# the old image while `deploy/versions.env` and the release notes both claimed
# the base had been refreshed. That silent no-op defeats the weekly-rebuild
# freshness model the vendored image exists for (). It is safe to
# recreate unconditionally: the proxy is stateless, holds no volumes beyond the
# :ro docker socket, and forge-web reconnects on its next request.
COMPOSE_IGNORE_ORPHANS=true sops exec-env "$STACK_ENV" "$BASE_COMPOSE up -d forge-web nooscope docker-socket-proxy"

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
