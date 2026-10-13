#!/usr/bin/env python3
"""Static assertions on the manifests rendered by `helm template`.

Usage: tests/check_rendered.py <render-dir>
Expects <render-dir>/free5gc.yaml, ueransim.yaml and the values files written
by scripts/validate.sh. Python standard library only (no PyYAML), so checks use
per-document regular expressions on Helm's predictable output.
"""

import json
import re
import sys
from pathlib import Path

render = Path(sys.argv[1] if len(sys.argv) > 1 else ".render")
failures = []
passes = 0


def check(cond, msg):
    global passes
    if cond:
        passes += 1
    else:
        failures.append(msg)


def split_docs(text):
    return [d for d in re.split(r"^---\s*$", text, flags=re.M) if re.search(r"^kind:", d, re.M)]


def kind(d):
    return re.search(r"^kind:\s*(\S+)", d, re.M).group(1)


def name(d):
    return re.search(r"^metadata:\n(?:  .*\n)*?  name:\s*\"?([^\"\n]+)", d, re.M).group(1)


def is_hook(d):
    return re.search(r'"?helm\.sh/hook"?\s*:', d) is not None


def find(docs, k, n):
    for d in docs:
        if kind(d) == k and name(d) == n:
            return d
    return None


free5gc = split_docs((render / "free5gc.yaml").read_text())
ueransim = split_docs((render / "ueransim.yaml").read_text())
installed = [d for d in free5gc + ueransim if not is_hook(d)]

# --- Supply chain ------------------------------------------------------------
for d in installed:
    for img in re.findall(r'^\s*-?\s*image:\s*"?([^"\s]+)', d, re.M):
        check("@sha256:" in img, f"{kind(d)}/{name(d)}: image not pinned by digest: {img}")
check(not any("install-tini" in d for d in installed), "MongoDB tini init container still present")

# --- Exposure ----------------------------------------------------------------
for d in installed:
    if kind(d) == "Service":
        t = re.search(r"^\s*type:\s*(\S+)", d, re.M)
        check(t is None or t.group(1) == "ClusterIP", f"Service/{name(d)} is {t.group(1) if t else '?'}, expected ClusterIP")
        check(re.search(r"nodePort:\s*\d", d) is None, f"Service/{name(d)} sets a nodePort")
    check(kind(d) not in ("Ingress", "PersistentVolume"), f"unexpected {kind(d)}/{name(d)}")
    check("hostPath" not in d, f"{kind(d)}/{name(d)} uses hostPath")
    check(re.search(r"priorityClassName:\s*system-", d) is None, f"{kind(d)}/{name(d)} uses a system-* priority class")
check(not any(kind(d) == "Deployment" and "webui" in name(d) for d in installed), "WebConsole is deployed")

n2 = find(free5gc, "Service", "free5gc-free5gc-amf-amf-n2")
check(n2 is not None and "protocol: SCTP" in n2 and "port: 38412" in n2, "AMF N2 Service missing or not SCTP/38412")

# --- MongoDB authentication --------------------------------------------------
mongo = find(free5gc, "StatefulSet", "mongodb")
check(mongo is not None, "MongoDB StatefulSet missing")
if mongo:
    check("name: mongodb-credentials" in mongo, "MongoDB does not use the mongodb-credentials Secret")
    check("storageClassName: standard-rwo" in mongo, "MongoDB volume is not on standard-rwo")
    # Regression (found on GKE): mounting the PD on the data directory makes
    # Bitnami skip user creation because of lost+found.
    check(re.search(r"mountPath: /bitnami/mongodb\n", mongo) is not None and "mountPath: /bitnami/mongodb/data/db" not in mongo,
          "MongoDB volume must be mounted at /bitnami/mongodb, not on the data directory")
    check(re.search(r"MONGODB_EXTRA_USERNAMES\n\s*value:\s*\"?free5gc", mongo) is not None, "free5gc app user not configured")

for nf in ("nrf", "udr", "pcf", "chf"):
    d = find(free5gc, "Deployment", f"free5gc-free5gc-{nf}-{nf}")
    check(d is not None, f"{nf} Deployment missing")
    if not d:
        continue
    main = d[d.index("      containers:"):]
    check(re.search(r"name: MONGODB_PASSWORD\n\s*valueFrom:\n\s*secretKeyRef:\n\s*name: mongodb-credentials", main) is not None,
          f"{nf}: MONGODB_PASSWORD not from Secret")
    check("$(MONGODB_PASSWORD)@mongodb:27017/free5gc?authSource=free5gc" in main, f"{nf}: MONGODB_URI not composed from the Secret")
    check(f"exec ./{nf} -c /free5gc/runtime/{nf}cfg.yaml" in main, f"{nf}: not started with the rendered config")
    check("medium: Memory" in d, f"{nf}: runtime config volume is not memory-backed")

for d in installed:
    if kind(d) == "ConfigMap":
        check(re.search(r"mongodb://[^/\s]*:[^@\s]*@", d) is None, f"ConfigMap/{name(d)} embeds MongoDB credentials")

# --- UPF and gtp5g gate --------------------------------------------------------
upf = find(free5gc, "Deployment", "free5gc-free5gc-upf-upf")
check(upf is not None, "single UPF Deployment missing")
if upf:
    check("name: wait-gtp5g" in upf, "UPF has no gtp5g gate")
    check("free5gc.io/pool: upf" in upf and "key: free5gc.io/upf" in upf, "UPF not pinned to the UPF pool")
for ulcl in ("iupf1", "psaupf1", "psaupf2"):
    check(find(free5gc, "Deployment", f"free5gc-free5gc-upf-{ulcl}") is None, f"ULCL UPF {ulcl} deployed")

# --- Cross-chart name consistency ---------------------------------------------
smf_cm = find(free5gc, "ConfigMap", "free5gc-free5gc-smf-configmap")
check(smf_cm is not None, "SMF ConfigMap missing")
if smf_cm:
    m = re.search(r"getent hosts (\S+)", smf_cm)
    check(m is not None, "SMF wrapper does not resolve a UPF service")
    if m:
        check(find(free5gc, "Service", m.group(1)) is not None,
              f"SMF resolves '{m.group(1)}' but no such Service is rendered")
    check("nodeID: UPF_SERVICE_NAME" in smf_cm, "SMF UPF nodeID placeholder missing")

gnb_cm = find(ueransim, "ConfigMap", "gnb-configmap")
check(gnb_cm is not None, "gNB ConfigMap missing")
if gnb_cm:
    m = re.search(r"amfConfigs:\n\s*- address:\s*(\S+)", gnb_cm)
    check(m is not None, "gNB has no AMF address")
    if m:
        svc, _, ns = m.group(1).partition(".")
        check(find(free5gc, "Service", svc) is not None, f"gNB targets Service '{svc}' which free5GC does not render")
        check(ns.startswith("free5gc.svc"), f"gNB AMF address is not namespace-qualified: {m.group(1)}")

# --- PLMN consistency --------------------------------------------------------
profile = json.loads((render / "subscriber_profile.yaml").read_text())
plmn = profile["plmn"]
amf_cm = find(free5gc, "ConfigMap", "free5gc-free5gc-amf-configmap")
if amf_cm:
    mcc, mnc = plmn[:3], plmn[3:]
    check(f'mcc: "{mcc}"' in amf_cm and f'mnc: "{mnc}"' in amf_cm, "AMF PLMN not quoted/consistent with subscribers")
    check(re.search(r"cipheringOrder:\n\s*- NEA2", amf_cm) is not None, "AMF does not prefer NEA2")

# --- UE credentials never in manifests ----------------------------------------
ue_cm = find(ueransim, "ConfigMap", "ue-configmap")
check(ue_cm is not None, "UE ConfigMap missing")
if ue_cm:
    check('key: "__KEY__"' in ue_cm and 'op: "__OPC__"' in ue_cm, "UE ConfigMap does not use placeholders")
ue = find(ueransim, "Deployment", "ueransim-ue")
check(ue is not None and "secretName: ue-credentials" in ue, "UE Deployment does not mount ue-credentials")

hexkey = re.compile(r"(?<![0-9a-f:])[0-9a-fA-F]{32}(?![0-9a-fA-F])")
upstream_default_k = "8baf473f2f8fd09487cccbd7097c6862"
for f in sorted(render.glob("*.yaml")):
    text = f.read_text()
    text_wo_digests = re.sub(r"sha256:[0-9a-f]{64}", "", text)
    check(upstream_default_k not in text, f"{f.name}: contains the upstream default UE key")
    if f.name.endswith("_values_main.yaml") or f.name.startswith("ueransim_values") or f.name.startswith("subscriber_profile") or f.name.endswith("_values_common.yaml"):
        check(hexkey.search(text_wo_digests) is None, f"{f.name}: contains a 128-bit hex value (possible key material)")

print(f"check_rendered: {passes} checks passed, {len(failures)} failed")
for m in failures:
    print(f"  FAIL: {m}")
sys.exit(1 if failures else 0)
