#!/usr/bin/env bash
# Pull Thriden stack images from private GHCR with the smallest possible
# on-disk credential window. Wraps:
#
#   sops exec-env <host.enc.env> <inner-script>
#     where the inner script does:
#       docker login --password-stdin -> docker compose pull -> docker logout
#
# Avoids the default `docker login` failure mode where the credential
# persists in $DOCKER_CONFIG/config.json indefinitely (base64-encoded,
# not encrypted). Here the credential is resident only for the pull,
# then `docker logout` removes the ghcr.io entry on exit.
#
# Four implementation notes worth knowing:
#
# 1. sops exec-env's "command to run" arg is a single shell-command string
#    (passed to /bin/sh -c internally), not argv. So `sops exec-env <file>
#    bash -c '...'` parses as four args and breaks ("error: missing file
#    to decrypt"). The workaround: write the inner work to a tempfile and
#    pass that path as the single command arg, with no further argv --
#    runtime parameters (e.g. compose file paths) cross into the inner
#    script via environment variables, not as positional args, because
#    interpolating them into the sh -c string would be a command-injection
#    sink. Verified against sops v3.13.0 on linux/arm64.
#
# 2. The deploy service user has /usr/sbin/nologin and no shell-profile
#    setup. Docker defaults to $HOME/.docker which may or may not exist
#    cleanly across distros; explicitly set DOCKER_CONFIG to a path under
#    the stack tree, ignoring any inherited value (an attacker-controlled
#    $DOCKER_CONFIG via misconfigured systemd / sudoers env_keep / PAM
#    would otherwise pin the credential in an attacker-readable location
#    that survives the docker logout cleanup window).
#
# 3. Two SOPS env tiers are loaded, nested. `docker compose pull` does
#    full variable interpolation up-front before fetching any image, so
#    stack.enc.env (MONGO_ROOT_PASSWORD, *_VERSION) must be in the
#    process env or compose bails before
#    login. host.enc.env (GHCR_PULL_USER, GHCR_PULL_TOKEN) is also
#    needed, but only inside the inner script's docker-login call. The
#    nesting `sops exec-env stack "sops exec-env host inner"` loads both
#    tiers in scope when the inner runs. Credential window stays narrow:
#    the inner script's EXIT trap runs `docker logout` before either env
#    block is torn down.
#
# 4. Multi-file compose: prod is substrate-only `compose.prod.yml`
#    OVERLAYED on the base `docker-compose.yml` (post-af350fb). So the
#    pull operation needs both `-f` flags to resolve the merged service
#    graph (networks defined in base, services overridden in overlay).
#    The wrapper accepts `-f` repeated, and defaults to both prod files
#    when no `-f` is given. The list crosses to the inner script as a
#    newline-delimited env var ($THRIDEN_COMPOSE_FILES), which the inner
#    script reads into an array -- never interpolated into a shell
#    command, so filename-injection stays closed.
#
# Usage:
#   bin/thriden-compose-pull.sh                                 (defaults)
#   bin/thriden-compose-pull.sh -f compose.prod.yml             (single file)
#   bin/thriden-compose-pull.sh -f base.yml -f overlay.yml      (overlay)
#   bin/thriden-compose-pull.sh -h <host-short>                 (override host)
#
# Defaults assume execution from /srv/thriden on a Thriden host:
#   - compose files: docker-compose.yml + compose.prod.yml
#   - host short: derived from `hostname -s` (matches secrets/prod/hosts/<short>/)
#
# Background: docs/secrets-ops.md § 6b
# Beans:  (initial),  (injection hardening),
#         (multi-file + sops key delivery)

set -euo pipefail

compose_files=()
host_short=""

while getopts "f:h:" opt; do
  case "$opt" in
    f) compose_files+=("$OPTARG") ;;
    h) host_short="$OPTARG" ;;
    *) echo "usage: $0 [-f <compose-file>]... [-h <host-short>]" >&2; exit 2 ;;
  esac
done

# Default to the prod overlay pattern when no -f given. Caller can still
# pass explicit -f flags for non-prod use (e.g. a staging overlay).
if [[ ${#compose_files[@]} -eq 0 ]]; then
  compose_files=(docker-compose.yml compose.prod.yml)
fi

if [[ -z "$host_short" ]]; then
  host_short="$(hostname -s)"
fi

host_env="secrets/prod/hosts/${host_short}/host.enc.env"
stack_env="secrets/prod/stack.enc.env"

if [[ ! -f "$host_env" ]]; then
  echo "ERROR: $host_env not found." >&2
  echo "Expected host-scoped credential at secrets/prod/hosts/<host>/host.enc.env." >&2
  echo "See docs/secrets-ops.md § 6b.1 for first-time install." >&2
  exit 1
fi

if [[ ! -f "$stack_env" ]]; then
  echo "ERROR: $stack_env not found." >&2
  echo "docker compose pull does variable interpolation before fetching" >&2
  echo "anything; the stack-tier env must be loadable for the merged" >&2
  echo "compose graph to resolve. See docs/secrets-ops.md § 6." >&2
  exit 1
fi

for f in "${compose_files[@]}"; do
  if [[ ! -f "$f" ]]; then
    echo "ERROR: compose file $f not found in $(pwd)." >&2
    exit 1
  fi
done

# Always set DOCKER_CONFIG to a script-controlled path. See note 2 above.
export DOCKER_CONFIG="$(pwd)/.docker"
install -d -m 0700 "$DOCKER_CONFIG"

# Pass compose file list to the inner script via env, not via the command
# string. See note 1 above. Newline-delimited because bash arrays don't
# cross process boundaries; filenames with newlines aren't supported (any
# sane filesystem layout makes them pathological anyway), but every other
# shell metacharacter -- `;`, `$`, backtick, space, quotes -- passes
# through safely because the inner script reads the env var as literal
# data into an array, never via shell expansion of a command string.
export THRIDEN_COMPOSE_FILES
THRIDEN_COMPOSE_FILES=$(printf '%s\n' "${compose_files[@]}")

inner=$(mktemp /tmp/thriden-pull-inner.XXXXXX.sh)
trap 'shred -u "$inner" 2>/dev/null || rm -f "$inner"' EXIT

cat > "$inner" <<'INNER_EOF'
#!/usr/bin/env bash
set -euo pipefail
: "${GHCR_PULL_USER:?GHCR_PULL_USER missing from host env}"
: "${GHCR_PULL_TOKEN:?GHCR_PULL_TOKEN missing from host env}"
: "${THRIDEN_COMPOSE_FILES:?THRIDEN_COMPOSE_FILES missing}"

# Parse newline-delimited file list into a bash array, then build the
# (-f path)... arg list for docker compose. mapfile reads as literal data
# (no shell expansion of the contents), preserving the injection-safety
# property the outer script established.
mapfile -t files <<< "$THRIDEN_COMPOSE_FILES"
compose_args=()
for f in "${files[@]}"; do
  [[ -n "$f" ]] || continue
  compose_args+=(-f "$f")
done

trap 'docker logout ghcr.io >/dev/null 2>&1 || true' EXIT
printf '%s' "$GHCR_PULL_TOKEN" | \
  docker login ghcr.io -u "$GHCR_PULL_USER" --password-stdin
docker compose "${compose_args[@]}" pull
INNER_EOF
chmod +x "$inner"

# Nest two sops exec-env calls: outer loads stack.enc.env (compose vars
# like MONGO_ROOT_PASSWORD that `docker compose pull` interpolates before
# fetching anything); inner loads host.enc.env (GHCR pull credential)
# and then runs the inner script. Order matters only for var-name
# collisions; in practice the two tiers have disjoint vars (stack: DB /
# *_VERSION; host: GHCR_PULL_*). Inner-most placement of host_env
# keeps the credential window narrative ("opened, used, closed by trap")
# closest to the docker login/logout pair in the inner script.
#
# Both $stack_env and $inner are script-controlled paths (no caller
# input), so single-quoting them inside the sh -c string is sufficient
# to keep this side of the call free of injection sinks.
sops exec-env "$stack_env" "sops exec-env '$host_env' '$inner'"
