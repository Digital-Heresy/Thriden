#!/usr/bin/env bash
# Idempotent setup for the `personaforge.deploy_payloads` Mongo collection
# consumed by `bin/thriden-deploy-payload.sh -i <_id>` (xluj Phase 3).
#
# Creates (or modifies via collMod if already present) the collection with
# a $jsonSchema validator derived from schemas/deploy-payload-mongo.schema.json.
# Safe to re-run -- collMod replaces the validator atomically.
#
# Operator runs this once per Thriden host after the stack is up, BEFORE
# Forge starts writing payloads. PF's deploy schedule UI should refuse to
# write if the collection's validator is missing; this script ensures the
# precondition is in place.
#
# Usage:
#   bin/thriden-deploy-payloads-setup.sh
#
# Pre-reqs: docker compose stack up; jq + docker available on the host.
#
# Bean:  Phase 3
# Schema: schemas/deploy-payload-mongo.schema.json

set -euo pipefail

schema_file="schemas/deploy-payload-mongo.schema.json"

for dep in jq docker; do
  if ! command -v "$dep" >/dev/null; then
    echo "ERROR: required tool '$dep' not in PATH" >&2
    exit 1
  fi
done

if [[ ! -f "$schema_file" ]]; then
  echo "ERROR: $schema_file not found (run from repo root)" >&2
  exit 1
fi

# Strip JSON Schema metadata keys ($schema, $id, title, description) that
# Mongo's $jsonSchema validator doesn't consume. Keep everything else.
# Also: deeply walk the schema and rename `type` -> `bsonType` for the
# leaf fields where we explicitly typed against BSON (objectId, date).
# But since our schema already uses `bsonType` where appropriate, all we
# need is the top-level strip.
schema_inner=$(jq 'del(."$schema", ."$id", .title, .description)' "$schema_file")

# Build the mongosh script. Schema is passed via env var so the script
# can JSON.parse it cleanly; no JS-source interpolation of operator data.
read -r -d '' MONGO_SCRIPT <<'JS' || true
const schema = JSON.parse(process.env.MONGO_QUERY_SCHEMA);
const cols = db.getCollectionNames();
if (cols.includes("deploy_payloads")) {
  const result = db.runCommand({
    collMod: "deploy_payloads",
    validator: {$jsonSchema: schema},
    validationLevel: "strict",
    validationAction: "error"
  });
  print("collMod result: " + JSON.stringify(result));
} else {
  db.createCollection("deploy_payloads", {
    validator: {$jsonSchema: schema},
    validationLevel: "strict",
    validationAction: "error"
  });
  print("created collection deploy_payloads with validator");
}
// Sanity probe: confirm validator landed.
const opts = db.runCommand({listCollections: 1, filter: {name: "deploy_payloads"}}).cursor.firstBatch[0].options;
if (!opts || !opts.validator || !opts.validator.$jsonSchema) {
  print("ERROR: validator did not land");
  quit(1);
}
print("validator confirmed; deploy_payloads is ready for Forge to write into");
JS

echo "[setup] applying validator from $schema_file to personaforge.deploy_payloads"

MONGO_QUERY_SCHEMA="$schema_inner" \
docker compose -f docker-compose.yml -f compose.prod.yml exec -T \
  -e MONGO_QUERY_SCHEMA="$schema_inner" \
  mongodb \
  sh -c 'mongosh "mongodb://$MONGO_INITDB_ROOT_USERNAME:$MONGO_INITDB_ROOT_PASSWORD@localhost:27017/personaforge?authSource=admin" --quiet' \
  <<< "$MONGO_SCRIPT"

echo "[setup] done"
