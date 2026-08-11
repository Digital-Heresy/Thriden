#!/usr/bin/env bash
#
# thriden-redeploy.sh — pull the newest image for a substrate service and
# recreate it, in one command.
#
# Why this exists: once a per-Scion runtime (forge-<short>) also runs
# `forge:main`, the old redeploy dance breaks — `docker rmi forge:main` is
# refused (a running container references it) and `docker compose pull` SKIPS
# it under `pull_policy: missing`. A DIRECT `docker pull` ignores pull_policy
# and re-points the `:main` tag without touching the running Scion; then we
# recreate just the substrate service with `--pull never`.
#
# Usage:  thriden-redeploy.sh [service]      (default: forge-web)
#   service in: forge-web | nooscope
#
# Self-elevates to deploy. The GHCR credential window is narrow (login -> pull
# -> logout, inside a tempfile so the token never crosses a shell-command
# string). Overridable via THRIDEN_STACK_DIR / THRIDEN_DEPLOY_USER /
# THRIDEN_HOST_SHORT.
#
set -euo pipefail

STACK_DIR="${THRIDEN_STACK_DIR:-/srv/thriden}"
DEPLOY_USER="${THRIDEN_DEPLOY_USER:-deploy}"
BASE_COMPOSE="docker compose -f docker-compose.yml -f compose.prod.yml"

service="${1:-forge-web}"
case "$service" in
  forge-web) image="ghcr.io/digital-heresy/forge";    ver_var="FORGE_VERSION" ;;
  nooscope)  image="ghcr.io/digital-heresy/nooscope"; ver_var="NOOSCOPE_VERSION" ;;
  *) echo "usage: $(basename "$0") [forge-web|nooscope]" >&2; exit 2 ;;
esac

if [ "$(id -un)" != "$DEPLOY_USER" ]; then
  echo ">> elevating to '$DEPLOY_USER' ..." >&2
  exec sudo -u "$DEPLOY_USER" -H "$0" "$@"
fi

cd "$STACK_DIR"
# Compose lowercases the project name and strips characters outside
# [a-z0-9_-], so a raw basename is wrong for any capitalised directory and the
# derived container name below never resolves -- the health wait then spins the
# full 60s and reports state=unknown ( sweep).
proj="${COMPOSE_PROJECT_NAME:-$(basename "$STACK_DIR" | tr "[:upper:]" "[:lower:]" | tr -cd "a-z0-9_-")}"
stack_env="secrets/prod/stack.enc.env"

# Pin versions from the non-secret manifest () so a host migrated
# off stack.enc.env pins resolves a real tag below, not `:-main`. A *_VERSION
# still in stack.enc.env wins (sops exec-env layers it on top in the resolve).
[ -f deploy/versions.env ] && { set -a; . ./deploy/versions.env; set +a; }

# Tell forge-web where this checkout lives, so the commands it renders point at
# a real path instead of the hardcoded /srv/thriden. Sourcing exports
# THRIDEN_HOST_ROOT; the recreate below carries it into the container. Sourced
# in every wrapper that recreates forge-web, so the value is CONSISTENT across
# them -- a var that is set by one wrapper and unset by another makes compose
# churn the container on alternate runs.
# Guarded: this rung is a convenience (it saves the operator a one-time /setup
# entry), so a tree missing the file must degrade, not abort -- but silently
# falling back to the hardcoded /srv/thriden would hand a custom-path operator a
# broken command, so say so.
# shellcheck source=bin/thriden-root.lib.sh
if [ -f "$(dirname "$0")/thriden-root.lib.sh" ]; then
  . "$(dirname "$0")/thriden-root.lib.sh"
else
  echo "WARN: bin/thriden-root.lib.sh missing; forge-web will fall back to its" >&2
  echo "      /setup override (or /srv/thriden) for rendered commands." >&2
fi

# Host short for the GHCR pull credential (shared resolution chain).
# shellcheck source=bin/thriden-host-short.lib.sh
. "$(dirname "$0")/thriden-host-short.lib.sh"
host_short="$(thriden_resolve_host_short)"
host_env="secrets/prod/hosts/${host_short}/host.enc.env"
if [ ! -f "$host_env" ]; then
  echo "ERROR: $host_env not found (GHCR pull credential)." >&2
  exit 1
fi

# Resolve the tag the compose references (defaults to main, like compose.prod.yml).
# Fail if the decrypt itself fails. An empty read here is indistinguishable
# from "no pin set", and both land on :main -- so a sops failure would quietly
# pull main onto a host that had pinned a release. Same shape as the rest of
# this sweep: an empty capture must not become a value.
if ! ver="$(sops exec-env "$stack_env" "printf '%s' \"\${${ver_var}:-main}\"")"; then
  echo "ERROR: could not read ${ver_var} from ${stack_env} (sops failed)." >&2
  echo "       Refusing to guess -- that would pull :main over a pinned release." >&2
  exit 1
fi
ref="${image}:${ver:-main}"

echo ">> pulling $ref (direct — ignores pull_policy, re-points the tag) ..." >&2
export DOCKER_CONFIG="$STACK_DIR/.docker"
install -d -m 0700 "$DOCKER_CONFIG"

# login -> pull -> logout inside a tempfile (the token reaches it only via the
# host env sops decrypts, never via an interpolated shell-command string).
inner="$(mktemp /tmp/thriden-redeploy.XXXXXX.sh)"
trap 'shred -u "$inner" 2>/dev/null || rm -f "$inner"' EXIT
cat > "$inner" <<'INNER_EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${GHCR_PULL_USER:?GHCR_PULL_USER missing from host env}"
: "${GHCR_PULL_TOKEN:?GHCR_PULL_TOKEN missing from host env}"
: "${THRIDEN_PULL_REF:?THRIDEN_PULL_REF missing}"
trap 'docker logout ghcr.io >/dev/null 2>&1 || true' EXIT
printf '%s' "$GHCR_PULL_TOKEN" | docker login ghcr.io -u "$GHCR_PULL_USER" --password-stdin >/dev/null
docker pull "$THRIDEN_PULL_REF" 2>&1 | tail -1
INNER_EOF
chmod +x "$inner"
export THRIDEN_PULL_REF="$ref"
sops exec-env "$host_env" "$inner"

echo ">> recreating $service from the freshly-pulled image ..." >&2
sops exec-env "$stack_env" \
  "$BASE_COMPOSE up -d --force-recreate --pull never $service"

# Wait for healthy (services with a healthcheck) or running (those without).
cname="${proj}-${service}-1"
for _ in $(seq 1 30); do
  state="$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$cname" 2>/dev/null || true)"
  case "$state" in healthy|running) break ;; esac
  sleep 2
done

rev="$(docker inspect "$cname" -f '{{index .Config.Labels "org.opencontainers.image.revision"}}' 2>/dev/null || true)"
echo ">> $service redeployed: $ref  state=${state:-unknown}  rev=${rev:0:12}" >&2
