#!/usr/bin/env bash
# thriden-validator-diff.sh — show HOW the live deploy_payloads validator differs
# from the shipped schema.
#
# thriden-doctor.sh check 5 reports "present but DIFFERS"; this prints the diff
# so the difference is diagnosable instead of guessable. Read-only.
#
#   cd <stack dir> && bin/thriden-validator-diff.sh
set -euo pipefail

cd "$(dirname "$0")/.."
SCHEMA="schemas/deploy-payload-mongo.schema.json"
STACK_ENV="secrets/prod/stack.enc.env"
[[ -f "$SCHEMA" ]] || { echo "ERROR: $SCHEMA not found -- run from the stack dir." >&2; exit 1; }
# Name the missing tool. This whole diagnostic exists because a jq-shaped hole
# reported itself as a stale validator for four rounds; it would
# be a poor joke for the tool written to explain that failure to fail the same
# way with "jq: command not found".
command -v jq >/dev/null 2>&1 || {
  echo "ERROR: jq is not installed, and this comparison is meaningless without it." >&2
  echo "       sudo apt install -y jq   (see beta-onboarding.md section 1)" >&2
  exit 1; }

# Same self-wrap as the setup script: compose needs MONGO_ROOT_PASSWORD from the
# encrypted stack env, and re-execing keeps it out of the caller's environment.
if [[ -z "${MONGO_ROOT_PASSWORD:-}" && -f "$STACK_ENV" ]]; then
  exec sops exec-env "$STACK_ENV" "$0"
fi

JS='const o = db.runCommand({listCollections:1, filter:{name:"deploy_payloads"}}).cursor.firstBatch[0];
if (!o) { print("__MISSING_COLLECTION__"); quit(0); }
const v = o.options && o.options.validator && o.options.validator["$jsonSchema"];
print(v ? JSON.stringify(v) : "__NO_VALIDATOR__");'

live="$(docker compose -f docker-compose.yml -f compose.prod.yml exec -T \
          -e MONGO_QUERY_JS="$JS" mongodb \
          sh -c 'mongosh "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/personaforge?authSource=admin" --quiet --eval "$MONGO_QUERY_JS"' \
          2>/dev/null | tr -d '\r')"

case "$live" in
  ""|*__MISSING_COLLECTION__*|*__NO_VALIDATOR__*)
    echo "live validator unreadable: ${live:-<empty>}"; exit 1 ;;
esac

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# Same normalisation check 5 applies: strip the metadata keys the applier drops,
# then canonicalise both sides so key order cannot masquerade as a difference.
jq -S 'del(."$schema", ."$id", .title, .description)' "$SCHEMA" > "$tmp/shipped.json"
printf '%s' "$live" | jq -S . > "$tmp/live.json"

echo "shipped: $(wc -c <"$tmp/shipped.json") bytes   live: $(wc -c <"$tmp/live.json") bytes"
if diff -q "$tmp/shipped.json" "$tmp/live.json" >/dev/null; then
  echo "IDENTICAL — check 5 should be PASS. If it is not, the difference is in the check, not the data."
  exit 0
fi
echo
echo "--- shipped (schemas/deploy-payload-mongo.schema.json)"
echo "+++ live (mongo personaforge.deploy_payloads)"
diff -u "$tmp/shipped.json" "$tmp/live.json" | sed -n '3,60p'
