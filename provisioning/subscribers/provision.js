// Idempotent free5GC subscriber provisioner (mongosh script).
//
// Run by the Kubernetes Job "subscriber-provisioner-*" in the free5gc
// namespace:  mongosh --nodb --quiet --norc /scripts/provision.js
//
// Inputs
//   env MONGODB_URI                      authenticated URI (composed by Kubernetes
//                                        from a Secret; never printed)
//   /config/profile.json                 non-secret profile rendered by Terraform
//   /credentials/subscribers.txt         "<imsi> <k> <opc>" per line (Secret)
//   env PROVISIONER_MODE                 "apply" (default) or "check"
//   env PROFILE_PATH / CREDENTIALS_PATH  override the two paths above (tests)
//
// Document shapes mirror what the free5GC WebConsole (commit 3878732, shipped
// with free5GC v4.2.2) writes for one subscriber with one slice and one DNN.
// Field names follow free5gc/openapi v1.2.3 JSON tags.
//
// Idempotency: every write is updateOne(filter, ..., {upsert: true}). Filter
// fields are populated by MongoDB on insert and never repeated in $set (that
// would be a path conflict). $set carries the fields this script owns and
// $setOnInsert the fields that network functions update at runtime (SQN by
// the UDM, charging quota/ratingGroup by the PCF).
// Nothing is ever deleted.

const fs = require("fs");

function fail(msg) {
  print("[provisioner] ERROR: " + msg);
  quit(1);
}
function log(msg) {
  print("[provisioner] " + msg);
}

// ---------------------------------------------------------------------------
// Load and validate inputs
// ---------------------------------------------------------------------------
const profilePath = process.env.PROFILE_PATH || "/config/profile.json";
const credentialsPath = process.env.CREDENTIALS_PATH || "/credentials/subscribers.txt";
const profile = JSON.parse(fs.readFileSync(profilePath, "utf8"));
const mode = process.env.PROVISIONER_MODE || "apply"; // "apply" | "check"

const credLines = fs
  .readFileSync(credentialsPath, "utf8")
  .split("\n")
  .map((l) => l.trim())
  .filter((l) => l.length > 0 && !l.startsWith("#"));

const creds = credLines.map((line, i) => {
  const [imsi, k, opc] = line.split(/\s+/);
  if (!/^[0-9]{15}$/.test(imsi || "") || !/^[0-9a-f]{32}$/.test(k || "") || !/^[0-9a-f]{32}$/.test(opc || "")) {
    // Never echo the line: it contains key material.
    fail("credential line " + (i + 1) + " is malformed (expected '<15-digit imsi> <32 hex K> <32 hex OPc>')");
  }
  return { imsi, k, opc };
});

const expected = [...profile.imsis].sort();
const provided = creds.map((c) => c.imsi).sort();
if (JSON.stringify(expected) !== JSON.stringify(provided)) {
  const missing = expected.filter((x) => !provided.includes(x));
  const extra = provided.filter((x) => !expected.includes(x));
  fail(
    "credential IMSIs do not match config/subscribers.yaml. missing=" + JSON.stringify(missing) +
      " unexpected=" + JSON.stringify(extra) +
      ". Re-run scripts/bootstrap-secrets.sh --rotate-subscribers after changing the subscriber list."
  );
}
if (new Set(provided).size !== provided.length) fail("duplicate IMSIs in credential file");
log("validated " + creds.length + " credential entries for PLMN " + profile.plmn);

// ---------------------------------------------------------------------------
// Connect with retry
// ---------------------------------------------------------------------------
if (!process.env.MONGODB_URI) fail("MONGODB_URI is not set");
const maxAttempts = parseInt(process.env.PROVISIONER_CONNECT_ATTEMPTS || "60", 10);
let mdb = null; // not "db": mongosh reserves that global
for (let attempt = 1; attempt <= maxAttempts; attempt++) {
  try {
    const conn = new Mongo(process.env.MONGODB_URI);
    mdb = conn.getDB(profile.database);
    const r = mdb.runCommand({ ping: 1 });
    if (r.ok === 1) break;
    mdb = null;
  } catch (e) {
    // Print only the error class: driver messages may echo connection details.
    log("MongoDB not ready (attempt " + attempt + "/" + maxAttempts + "): " + (e.codeName || e.name));
    mdb = null;
  }
  if (attempt < maxAttempts) sleep(5000);
}
if (mdb === null) fail("could not connect to MongoDB");
log("connected to database '" + profile.database + "'");

// ---------------------------------------------------------------------------
// Document builders
// ---------------------------------------------------------------------------
const servingPlmnId = profile.plmn;
const snssai = { sst: NumberInt(profile.sst), sd: profile.sd };
const dnn = profile.dnn;
const snssaiKey = profile.snssai_hex; // e.g. "01010203"

function upsert(collection, filter, set, setOnInsert) {
  const update = { $set: set };
  if (setOnInsert) update.$setOnInsert = setOnInsert;
  const res = mdb.getCollection(collection).updateOne(filter, update, { upsert: true });
  if (!res.acknowledged) fail("write not acknowledged on " + collection);
  return res.upsertedCount === 1 ? "inserted" : res.modifiedCount === 1 ? "updated" : "unchanged";
}

const stats = {};
function count(collection, outcome) {
  stats[collection] = stats[collection] || { inserted: 0, updated: 0, unchanged: 0 };
  stats[collection][outcome]++;
}

// ---------------------------------------------------------------------------
// Check mode: report presence only
// ---------------------------------------------------------------------------
const collections = {
  auth: "subscriptionData.authenticationData.authenticationSubscription",
  am: "subscriptionData.provisionedData.amData",
  sm: "subscriptionData.provisionedData.smData",
  smfSel: "subscriptionData.provisionedData.smfSelectionSubscriptionData",
  amPolicy: "policyData.ues.amData",
  smPolicy: "policyData.ues.smData",
  charging: "policyData.ues.chargingData",
};

if (mode === "check") {
  const report = {};
  for (const [name, coll] of Object.entries(collections)) {
    if (name === "charging" && profile.charging_method === "none") continue;
    const found = mdb.getCollection(coll).distinct("ueId", { ueId: { $in: expected.map((i) => "imsi-" + i) } });
    report[name] = found.length;
  }
  const allAuth = mdb.getCollection(collections.auth).countDocuments({});
  print(JSON.stringify({ expected: expected.length, per_collection: report, total_auth_documents: allAuth }));
  const ok = Object.values(report).every((n) => n === expected.length);
  quit(ok ? 0 : 2);
}

// ---------------------------------------------------------------------------
// Apply
// ---------------------------------------------------------------------------
for (const c of creds) {
  const ueId = "imsi-" + c.imsi;

  count(collections.auth, upsert(
    collections.auth,
    { ueId: ueId },
    {
      authenticationMethod: profile.authentication_method,
      encPermanentKey: c.k,
      encOpcKey: c.opc,
      authenticationManagementField: profile.authentication_management_field,
    },
    // The UDM advances the SQN on every authentication; never reset it.
    { sequenceNumber: { sqnScheme: "GENERAL", sqn: profile.sequence_number } }
  ));

  count(collections.am, upsert(
    collections.am,
    { ueId: ueId, servingPlmnId: servingPlmnId },
    {
      gpsis: ["msisdn-"],
      subscribedUeAmbr: { uplink: profile.ambr.ue_uplink, downlink: profile.ambr.ue_downlink },
      nssai: { defaultSingleNssais: [snssai], singleNssais: [] },
    }
  ));

  count(collections.sm, upsert(
    collections.sm,
    // Equality on the whole embedded document (field order sst, sd as written).
    { ueId: ueId, servingPlmnId: servingPlmnId, singleNssai: snssai },
    {
      dnnConfigurations: {
        [dnn]: {
          pduSessionTypes: { defaultSessionType: "IPV4", allowedSessionTypes: ["IPV4"] },
          sscModes: { defaultSscMode: "SSC_MODE_1", allowedSscModes: ["SSC_MODE_2", "SSC_MODE_3"] },
          "5gQosProfile": {
            "5qi": NumberInt(profile.default_5qi),
            arp: { priorityLevel: NumberInt(8), preemptCap: "NOT_PREEMPT", preemptVuln: "NOT_PREEMPTABLE" },
            priorityLevel: NumberInt(8),
          },
          sessionAmbr: { uplink: profile.ambr.session_uplink, downlink: profile.ambr.session_downlink },
        },
      },
    }
  ));

  count(collections.smfSel, upsert(
    collections.smfSel,
    { ueId: ueId, servingPlmnId: servingPlmnId },
    {
      subscribedSnssaiInfos: { [snssaiKey]: { dnnInfos: [{ dnn: dnn }] } },
    }
  ));

  count(collections.amPolicy, upsert(
    collections.amPolicy,
    { ueId: ueId },
    { subscCats: ["free5gc"] }
  ));

  count(collections.smPolicy, upsert(
    collections.smPolicy,
    { ueId: ueId },
    {
      smPolicySnssaiData: {
        [snssaiKey]: { snssai: snssai, smPolicyDnnData: { [dnn]: { dnn: dnn } } },
      },
    }
  ));

  if (profile.charging_method === "Offline") {
    // Slice-level charging record, as created by the WebConsole. The PCF
    // looks it up by {ueId, snssai, dnn:"", filter:""} and writes ratingGroup.
    count(collections.charging, upsert(
      collections.charging,
      { ueId: ueId, servingPlmnId: servingPlmnId, snssai: snssaiKey, dnn: "", filter: "" },
      { chargingMethod: "Offline", unitCost: "1" },
      { quota: "0" }
    ));
  }
}

log("summary " + JSON.stringify(stats));
log("provisioned " + creds.length + " subscribers");
