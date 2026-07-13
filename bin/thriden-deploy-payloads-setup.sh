#!/usr/bin/env bash
# Idempotent setup for the `personaforge.deploy_payloads` Mongo collection
# consumed by `bin/thriden-deploy-payload.sh -i <_id>` (xluj Phase 3).
#
# Creates (or modifies via collMod if already present) the collection with
# a $jsonSchema validator derived from schemas/deploy-payload-mongo.schema.json,
# and a partial unique index enforcing "at most one PENDING payload per
# thriden_version" (DB-side backstop for PF's schedule-writer duplicate guard).
# Safe to re-run -- collMod replaces the validator atomically; createIndex is
# idempotent.
#
# Operator runs this once per Thriden host after the stack is up, BEFORE
# Forge starts writing payloads. PF's deploy schedule UI should refuse to
# write if the collection's validator is missing; this script ensures the
# precondition is in place.
#
# Usage:
#   bin/thriden-deploy-payloads-setup.sh          # prod host (SOPS + prod overlay)
#   bin/thriden-deploy-payloads-setup.sh --dev     # local dev stack (bare compose)
#
# Pre-reqs: docker compose stack up; docker available on the host.
# Prod also needs sops (for the MONGO_ROOT_PASSWORD self-wrap).
#
# Bean:  Phase 3
# Schema: schemas/deploy-payload-mongo.schema.json

set -euo pipefail

# ── Self-locate: cd to the repo root ────────────────────────────────────────
# Relative paths below (schema, compose files, secrets, the host-short pin) all
# assume the repo root as cwd. Resolve our own on-disk location and cd there so
# the operator can invoke us by absolute path from anywhere (e.g.
# `/srv/thriden/bin/thriden-deploy-payloads-setup.sh` from $HOME) -- not only
# from a shell already sitting in the repo root. BASH_SOURCE[0] survives a later
# `exec` munging $0; $self is passed forward on the SOPS re-exec so every
# incarnation points at the same file. (Mirrors bin/thriden-deploy-payload.sh.)
self="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)/$(basename -- "${BASH_SOURCE[0]}")"
cd -- "$(dirname -- "$self")/.." || { echo "ERROR: cannot cd to repo root" >&2; exit 1; }

# ── Dev/localhost mode ──────────────────────────────────────────────────────
# --dev targets a bare `docker compose` stack (docker-compose.yml + its
# auto-loaded docker-compose.override.yml) instead of the prod overlay, skips
# the SOPS self-wrap (dev creds come from the repo-root .env that docker compose
# auto-loads), and skips the prod-only host-short pin. Use it for the localhost
# Scions -- the prod path assumes secrets/prod/stack.enc.env + compose.prod.yml.
dev=false
for arg in "$@"; do
  case "$arg" in
    --dev) dev=true ;;
    -h|--help)
      echo "Usage: $0 [--dev]"
      echo "  --dev   target the local dev stack (no prod overlay, no SOPS)"
      exit 0
      ;;
    *)
      echo "ERROR: unknown argument '$arg' (accepts: --dev)" >&2
      exit 1
      ;;
  esac
done

schema_file="schemas/deploy-payload-mongo.schema.json"

# Prod needs sops (self-wrap for MONGO_ROOT_PASSWORD); dev reads it from .env.
# No jq: the schema's metadata-key strip happens in the mongosh JS below, so
# the host needs no JSON tooling (one less prereq on a Windows/dev box).
required_deps=(docker)
if ! $dev; then
  required_deps+=(sops)
fi
for dep in "${required_deps[@]}"; do
  if ! command -v "$dep" >/dev/null; then
    echo "ERROR: required tool '$dep' not in PATH" >&2
    exit 1
  fi
done

if [[ ! -f "$schema_file" ]]; then
  echo "ERROR: $schema_file not found (incomplete checkout? expected at repo root $(pwd))" >&2
  exit 1
fi

# ── SOPS self-wrap ─────────────────────────────────────────────────────────
# The `docker compose exec mongodb` below evaluates the compose files, which
# require MONGO_ROOT_PASSWORD (${MONGO_ROOT_PASSWORD:?}). Re-exec under sops
# exec-env so the operator can just run this directly (no manual `sops exec-env`
# wrapper). Guard: on the re-exec the secret is set, so we fall through.
stack_env="secrets/prod/stack.enc.env"
if ! $dev && [[ -z "${MONGO_ROOT_PASSWORD:-}" && -f "$stack_env" ]]; then
  exec sops exec-env "$stack_env" "$self"
fi

# Pass the raw schema file through; the metadata-key strip ($schema, $id,
# title, description -- keys Mongo's $jsonSchema validator doesn't consume)
# happens in the shared JS. The schema already uses `bsonType` where BSON types
# (objectId, date) matter, so a top-level key strip is all that's needed.
schema_inner=$(cat "$schema_file")

# The mongosh apply logic lives in a shared file so it can't drift from the
# `deploy-payloads-init` compose service that does the same job automatically.
# Piped to mongosh's stdin (schema passed via env), same as before.
js_file="bin/deploy-payloads-validator.mongo.js"
if [[ ! -f "$js_file" ]]; then
  echo "ERROR: $js_file not found (incomplete checkout? expected at repo root $(pwd))" >&2
  exit 1
fi

echo "[setup] applying validator from $schema_file to personaforge.deploy_payloads"

# Dev runs bare so docker compose auto-loads docker-compose.override.yml (the
# stack the operator actually brought up); prod adds the image-pinned overlay.
if $dev; then
  compose_files=()
else
  compose_files=(-f docker-compose.yml -f compose.prod.yml)
fi

MONGO_QUERY_SCHEMA="$schema_inner" \
docker compose "${compose_files[@]}" exec -T \
  -e MONGO_QUERY_SCHEMA="$schema_inner" \
  mongodb \
  sh -c 'mongosh "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/personaforge?authSource=admin" --quiet' \
  < "$js_file"

# ── Pin the host short name (host-short resolution, xluj integration bug #3) ──
# Unattended paths (the wake-path dispatcher -> wrapper) can't pass -h, so pin
# the secrets-bundle name once per host. The lib's fallback chain resolves a
# single-host install unaided, but an explicit pin survives a second host dir
# appearing in the secrets tree.
# Dev has no secrets/prod/hosts/ tree and never runs the unattended dispatcher,
# so the pin is prod-only.
if ! $dev; then
  # shellcheck source=bin/thriden-host-short.lib.sh
  . "$(dirname "$0")/thriden-host-short.lib.sh"
  if [[ ! -s .thriden-host-short ]]; then
    pinned_host_short="$(thriden_resolve_host_short)"
    printf '%s\n' "$pinned_host_short" > .thriden-host-short
    echo "[setup] pinned host short name '$pinned_host_short' -> .thriden-host-short"
  else
    echo "[setup] host short pin already present: $(tr -d '[:space:]' < .thriden-host-short)"
  fi
fi

echo "[setup] done"
