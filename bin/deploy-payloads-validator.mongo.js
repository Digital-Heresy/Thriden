// Apply the $jsonSchema validator + partial-unique index to the
// personaforge.deploy_payloads collection.
//
// SINGLE SOURCE OF TRUTH for the mongosh side of deploy-payloads provisioning,
// shared by two callers so the apply logic can't drift between them:
//   - the `deploy-payloads-init` compose service   (automatic, every `up`)
//   - bin/thriden-deploy-payloads-setup.sh          (manual escape hatch)
//
// The full schema (schemas/deploy-payload-mongo.schema.json) arrives via the
// MONGO_QUERY_SCHEMA env var -- passed with `-e` by the manual helper, and
// exported from the mounted file by the init service. Idempotent: collMod
// replaces the validator atomically on re-run, so re-applying on every `up`
// (and after a schema bump -- the validator is additionalProperties:false)
// is safe.
//
// Bean: MindHive-xluj Phase 3 (+ auto-provision follow-up).

const schema = JSON.parse(process.env.MONGO_QUERY_SCHEMA);
// Strip JSON Schema metadata keys Mongo's $jsonSchema validator rejects.
for (const k of ["$schema", "$id", "title", "description"]) delete schema[k];

const cols = db.getCollectionNames();
if (cols.includes("deploy_payloads")) {
  const result = db.runCommand({
    collMod: "deploy_payloads",
    validator: { $jsonSchema: schema },
    validationLevel: "strict",
    validationAction: "error",
  });
  print("collMod result: " + JSON.stringify(result));
} else {
  db.createCollection("deploy_payloads", {
    validator: { $jsonSchema: schema },
    validationLevel: "strict",
    validationAction: "error",
  });
  print("created collection deploy_payloads with validator");
}

// Sanity probe: confirm the validator landed. quit(1) so a caller (the init
// container especially) exits non-zero and the failure is visible.
const opts = db.runCommand({
  listCollections: 1,
  filter: { name: "deploy_payloads" },
}).cursor.firstBatch[0].options;
if (!opts || !opts.validator || !opts.validator.$jsonSchema) {
  print("ERROR: validator did not land");
  quit(1);
}
print("validator confirmed; deploy_payloads is ready for Forge to write into");

// Partial unique index: at most one PENDING payload per thriden_version.
// Hardens PF's schedule-writer duplicate guard (a soft check-then-insert
// TOCTOU) into a DB-enforced invariant. partialFilterExpression scopes it to
// status:"pending" so terminal states can freely repeat a thriden_version.
// Idempotent; non-fatal on failure (e.g. pre-existing duplicate pending docs)
// -- the validator is the critical part, so we warn and still exit 0.
try {
  db.deploy_payloads.createIndex(
    { thriden_version: 1, status: 1 },
    {
      unique: true,
      partialFilterExpression: { status: "pending" },
      name: "uniq_pending_thriden_version",
    }
  );
  print("partial unique index uniq_pending_thriden_version ensured");
} catch (e) {
  print("WARNING: could not create uniq_pending_thriden_version index: " + e.message);
  print("  resolve duplicate pending payloads (cancel all but one), then re-run");
}
