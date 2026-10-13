// Assertions for tests/test_provisioner_local.sh (mongosh --nodb).
// Env: MONGODB_URI (root), PROFILE_PATH, CREDENTIALS_PATH, PHASE.
const fs = require("fs");
const profile = JSON.parse(fs.readFileSync(process.env.PROFILE_PATH, "utf8"));
const creds = fs.readFileSync(process.env.CREDENTIALS_PATH, "utf8").split("\n")
  .filter((l) => /^[0-9]/.test(l)).map((l) => l.split(/\s+/));
const mdb = new Mongo(process.env.MONGODB_URI).getDB("free5gc");
const phase = process.env.PHASE;
let failures = 0;
function ok(cond, msg) { if (!cond) { failures++; print("  FAIL: " + msg); } }

const C = {
  auth: "subscriptionData.authenticationData.authenticationSubscription",
  am: "subscriptionData.provisionedData.amData",
  sm: "subscriptionData.provisionedData.smData",
  smfSel: "subscriptionData.provisionedData.smfSelectionSubscriptionData",
  amPolicy: "policyData.ues.amData",
  smPolicy: "policyData.ues.smData",
  charging: "policyData.ues.chargingData",
};
const n = profile.imsis.length;

if (phase === "mutate") {
  // Simulate the UDM advancing SQN and the PCF writing ratingGroup/quota.
  mdb.getCollection(C.auth).updateOne({ ueId: "imsi-" + profile.imsis[0] }, { $set: { "sequenceNumber.sqn": "0000000000ff" } });
  mdb.getCollection(C.charging).updateOne({ ueId: "imsi-" + profile.imsis[0] }, { $set: { ratingGroup: NumberInt(7), quota: "123" } });
  print("mutated NF-owned fields");
  quit(0);
}

for (const [k, coll] of Object.entries(C)) {
  ok(mdb.getCollection(coll).countDocuments({}) === n, `${k}: expected ${n} documents, found ${mdb.getCollection(coll).countDocuments({})}`);
}

for (const [imsi, key, opc] of creds) {
  const ueId = "imsi-" + imsi;
  const a = mdb.getCollection(C.auth).findOne({ ueId });
  ok(a && a.encPermanentKey === key && a.encOpcKey === opc, `${ueId}: K/OPc mismatch`);
  ok(a && a.authenticationMethod === "5G_AKA" && a.authenticationManagementField === "8000", `${ueId}: auth profile`);
  ok(a && a.sequenceNumber && a.sequenceNumber.sqnScheme === "GENERAL", `${ueId}: SQN scheme`);

  const am = mdb.getCollection(C.am).findOne({ ueId, servingPlmnId: profile.plmn });
  ok(am && am.nssai.defaultSingleNssais[0].sd === profile.sd, `${ueId}: amData nssai`);
  ok(am && typeof am.nssai.defaultSingleNssais[0].sst === "number" && am.nssai.defaultSingleNssais[0].sst === profile.sst, `${ueId}: sst type/value`);

  const sm = mdb.getCollection(C.sm).findOne({ ueId });
  ok(sm && sm.singleNssai.sd === profile.sd && sm.dnnConfigurations[profile.dnn], `${ueId}: smData`);
  ok(sm && sm.dnnConfigurations[profile.dnn]["5gQosProfile"]["5qi"] === profile.default_5qi, `${ueId}: 5QI`);

  const sel = mdb.getCollection(C.smfSel).findOne({ ueId });
  ok(sel && sel.subscribedSnssaiInfos[profile.snssai_hex].dnnInfos[0].dnn === profile.dnn, `${ueId}: smfSelection`);
  ok(mdb.getCollection(C.amPolicy).findOne({ ueId }).subscCats[0] === "free5gc", `${ueId}: amPolicy`);
  ok(mdb.getCollection(C.smPolicy).findOne({ ueId }).smPolicySnssaiData[profile.snssai_hex].smPolicyDnnData[profile.dnn].dnn === profile.dnn, `${ueId}: smPolicy`);

  // The exact filter the PCF uses (pcf/internal/sbi/processor/smpolicy.go).
  const ch = mdb.getCollection(C.charging).findOne({ ueId, snssai: profile.snssai_hex, dnn: "", filter: "" });
  ok(ch && ch.chargingMethod === "Offline", `${ueId}: charging record not found with the PCF filter`);
}

if (phase === "after-mutation") {
  const a = mdb.getCollection(C.auth).findOne({ ueId: "imsi-" + profile.imsis[0] });
  ok(a.sequenceNumber.sqn === "0000000000ff", "re-provisioning reset the SQN advanced by the UDM");
  const ch = mdb.getCollection(C.charging).findOne({ ueId: "imsi-" + profile.imsis[0] });
  ok(ch.ratingGroup === 7 && ch.quota === "123", "re-provisioning clobbered PCF-owned charging fields");
} else {
  const a = mdb.getCollection(C.auth).findOne({ ueId: "imsi-" + profile.imsis[0] });
  ok(a.sequenceNumber.sqn === profile.sequence_number, "initial SQN not set on insert");
}

print(failures === 0 ? `assertions passed (${phase})` : `${failures} assertion(s) failed (${phase})`);
quit(failures === 0 ? 0 : 1);
