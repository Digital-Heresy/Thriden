#!/usr/bin/env bash
# Idempotently mint the random session-signing HMAC keys into the SOPS-encrypted
# stack env, so a fresh install gets stable admin sessions without a manual
# `openssl rand` step.
#
# SESSION_SECRET (forge-web) and NOOSCOPE_SESSION_SECRET (nooscope) sign admin
# UI session cookies. Unset OR empty -> the service mints a per-boot EPHEMERAL
# key -> the admin UI logs you out on every container restart. These keys are
# pure random (no external dependency), so hand-generating them on every fresh
# install (incl. each beta participant) is avoidable friction.
#
# WHY mint here and not in the container: only the operator side holds the age
# key needed to write an ENCRYPTED value into stack.enc.env. A container could
# only persist a PLAINTEXT key to a volume -- unencrypted at rest, outside the
# SOPS lifecycle (not rotatable/backed-up). So: mint-into-SOPS via this init
# helper = right; container-self-mint-to-volume = wrong.
#
# ONLY no-dependency random keys are auto-minted. Provider-issued secrets (API
# keys, operator passwords) STAY manual -- this never fabricates those.
#
# Idempotent: a key that is already present AND non-empty is left untouched, so
# re-running is safe and a no-op once the stack env is populated. Hooks into the
# first-boot secrets flow (docs/secrets-ops.md 1f / pi5-bootstrap / the beta
# participant walkthrough).
#
# Usage:
#   bin/thriden-secrets-init.sh                 # default: secrets/prod/stack.enc.env
#   THRIDEN_STACK_ENV=/path/to/stack.enc.env bin/thriden-secrets-init.sh
#
# Pre-reqs: sops + openssl in PATH (WSL on a Windows operator box), and the
# age key that decrypts stack.enc.env available to sops (SOPS_AGE_KEY_FILE or
# the default keys.txt location).
#

set -euo pipefail

# ── Self-locate: cd to the repo root ────────────────────────────────────────
# So the default relative path to the encrypted stack env resolves regardless of
# the caller's cwd (mirrors the other bin/ scripts).
self="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
cd -- "$(dirname -- "$self")/.." || { echo "ERROR: cannot cd to repo root" >&2; exit 1; }

# Random session-signing HMAC keys that are safe to auto-generate. Each gets a
# fresh `openssl rand -hex 32` when absent or empty in the encrypted stack env.
HMAC_KEYS=(SESSION_SECRET NOOSCOPE_SESSION_SECRET)

ENC_ENV="${THRIDEN_STACK_ENV:-secrets/prod/stack.enc.env}"

need_cmd() {
  command -v "$1" >/dev/null 2>&1 \
    || { echo "ERROR: '$1' not found in PATH" >&2; exit 1; }
}
need_cmd sops
need_cmd openssl

if [[ ! -f "$ENC_ENV" ]]; then
  echo "ERROR: encrypted stack env not found: $ENC_ENV" >&2
  echo "       Populate the rotatable tier first (docs/secrets-ops.md 1f)." >&2
  exit 1
fi

# Decrypt once to inspect current values. Kept in a shell var; never hits disk.
if ! decrypted="$(sops -d "$ENC_ENV")"; then
  echo "ERROR: could not decrypt $ENC_ENV -- is the age key available to sops?" >&2
  exit 1
fi

minted=0
for key in "${HMAC_KEYS[@]}"; do
  # Present AND non-empty? leave it. An empty value still yields a per-boot
  # ephemeral key, so treat empty the same as missing.
  current="$(printf '%s\n' "$decrypted" | sed -n "s/^${key}=//p" | head -n1)"
  if [[ -n "$current" ]]; then
    echo "ok:   $key already set -- leaving it"
    continue
  fi
  value="$(openssl rand -hex 32)"
  sops set "$ENC_ENV" "[\"$key\"]" "\"$value\""
  echo "mint: $key generated (openssl rand -hex 32) + written to $ENC_ENV"
  minted=$((minted + 1))
done

if (( minted > 0 )); then
  echo "thriden-secrets-init: minted $minted key(s). Commit the updated $ENC_ENV."
else
  echo "thriden-secrets-init: nothing to do -- all HMAC keys already set."
fi
