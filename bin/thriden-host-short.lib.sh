# thriden-host-short.lib.sh -- shared host-short resolution for the deploy
# tooling. Sourced (not executed) by thriden-deploy-payload.sh,
# thriden-compose-pull.sh, thriden-redeploy.sh, thriden-deploy-payloads-setup.sh.
#
# Why: the host-scoped credential tier lives at
# secrets/prod/hosts/<host-short>/host.enc.env, but <host-short> is the
# SECRETS BUNDLE name, not necessarily the OS hostname (booklore runs the
# pi5-prod bundle). Deriving it from `hostname -s` broke the first scheduled
# upgrade-at-wake dispatch (integration bug #3): the dispatcher
# invoked the wrapper with no -h override and the wrapper died pre-claim on
# "secrets/prod/hosts/booklore/host.enc.env not found" for the whole torpor
# window. Manual paths had always worked because the operator passed
# `-h pi5-prod` by hand -- unattended paths get no hand.
#
# Resolution order (first hit wins):
#   1. explicit -h flag (passed in as $1)
#   2. THRIDEN_HOST_SHORT env var
#   3. .thriden-host-short file in the stack dir (pinned once by
#      bin/thriden-deploy-payloads-setup.sh; gitignored, host-local)
#   4. `hostname -s`, iff secrets/prod/hosts/<that>/ exists
#   5. the single directory under secrets/prod/hosts/ (a single-host
#      install is unambiguous)
# Multiple candidate dirs with none matching the hostname is a hard error:
# guessing a credential tier is worse than demanding explicit config.
#
# Assumes cwd = stack dir, same as every caller.

thriden_resolve_host_short() {
  local explicit="${1:-}"
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi
  if [[ -n "${THRIDEN_HOST_SHORT:-}" ]]; then
    printf '%s' "$THRIDEN_HOST_SHORT"
    return 0
  fi
  if [[ -f .thriden-host-short ]]; then
    local pinned
    pinned="$(tr -d '[:space:]' < .thriden-host-short)"
    if [[ -n "$pinned" ]]; then
      printf '%s' "$pinned"
      return 0
    fi
  fi
  local hn
  hn="$(hostname -s 2>/dev/null || true)"
  if [[ -n "$hn" && -d "secrets/prod/hosts/$hn" ]]; then
    printf '%s' "$hn"
    return 0
  fi
  local d dirs=()
  for d in secrets/prod/hosts/*/; do
    [[ -d "$d" ]] || continue
    d="${d%/}"
    dirs+=("${d##*/}")
  done
  if [[ ${#dirs[@]} -eq 1 ]]; then
    printf '%s' "${dirs[0]}"
    return 0
  fi
  echo "ERROR: cannot resolve host short name: hostname '$hn' has no directory under secrets/prod/hosts/ and ${#dirs[@]} candidate dir(s) exist (${dirs[*]:-none})." >&2
  echo "Pin it once:  echo <host-short> > .thriden-host-short   (or set THRIDEN_HOST_SHORT, or pass -h)." >&2
  return 1
}
