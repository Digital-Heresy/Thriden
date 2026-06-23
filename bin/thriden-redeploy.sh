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
proj="${COMPOSE_PROJECT_NAME:-$(basename "$STACK_DIR")}"
stack_env="secrets/prod/stack.enc.env"

# Host short for the GHCR pull credential (single dir under hosts/).
host_short="${THRIDEN_HOST_SHORT:-}"
[ -n "$host_short" ] || host_short="$(ls secrets/prod/hosts/ 2>/dev/null | head -n1)"
host_env="secrets/prod/hosts/${host_short}/host.enc.env"
if [ ! -f "$host_env" ]; then
  echo "ERROR: $host_env not found (GHCR pull credential)." >&2
  exit 1
fi

# Resolve the tag the compose references (defaults to main, like compose.prod.yml).
ver="$(sops exec-env "$stack_env" "printf '%s' \"\${${ver_var}:-main}\"")"
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
