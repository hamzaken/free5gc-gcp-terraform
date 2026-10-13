# Testing

Tests are split into three tiers. Only tier 1 runs in pull requests; tiers 2
and 3 need a deployed (billable) environment.

## Tier 1 – static and local (no cloud): `scripts/validate.sh`

| # | Check | Tool |
|---|---|---|
| 1 | Terraform formatting and validation of every root and module | `terraform fmt -check`, `terraform validate` |
| 2 | CIDR validity, canonical form, private space, overlap, GKE capacity; IMSI generation (leading zeros, 2/3-digit MNC, overflow); PLMN/S-NSSAI/TAC encodings; image pin format | `terraform test` (16 cases) |
| 3 | Bash and Terraform derive identical IMSI lists | `tests/test_imsi_consistency.sh` |
| 4 | Upstream tag still points to the pinned commit; patches apply cleanly | `scripts/fetch-charts.sh` |
| 5 | Offline render of the exact Helm values the platform stage deploys | `tests/render` harness |
| 6 | Charts lint and render with those values | `helm lint`, `helm template` |
| 7 | 247 assertions on rendered manifests (digest pins, exposure, MongoDB auth wiring, no secrets in values/ConfigMaps, UPF gate, cross-chart Service names) | `tests/check_rendered.py` |
| 8 | Kubernetes schema validation, strict mode (75 objects) | `kubeconform` |
| 9 | Shell scripts | `shellcheck` |
| 10 | Secrets and IaC misconfiguration | `gitleaks`, `trivy config`, `checkov` (CI security job) |

Also run in CI (`provisioner` job) and locally with downloaded binaries:

- `tests/test_provisioner_local.sh`: runs `provision.js` against a real
  MongoDB 7.0.9 with authentication, created the same way as the Bitnami chart
  creates it. Covers first insert, idempotent re-run, preservation of
  NF-owned fields (SQN, ratingGroup, quota), check mode, rejection of mismatched
  or malformed credentials without echoing them, clean failure with a wrong
  password without printing the URI, and app-user isolation.

## Tier 2 – deployment health: `scripts/verify.sh --level health`

Nodes Ready and Ubuntu; gtp5g loaded with the pinned version on every UPF node
(loader logs saved); all free5GC Pods Ready; exactly one UPF; synced Secrets
present (key names only); authenticated MongoDB connection; every IMSI present
in all six subscription/policy collections; total authentication records equal
the intended count.

## Tier 3 – 5G functional: `scripts/verify.sh --level functional`

| Check | Evidence |
|---|---|
| gNB NG Setup over SCTP (N2) | `nr-cli <gnb> --exec status` shows `is-ngap-up: true` |
| All UE processes running | `nr-cli --dump` lists every `imsi-…` |
| Registration of every UE | `nr-cli <imsi> --exec status` shows `RM-REGISTERED` |
| PDU session per UE | `nr-cli <imsi> --exec ps-list` shows `PS-ACTIVE` and an address from `ue_cidr` |
| User plane through the UPF (N3 → N6) | `ping -I uesimtunN` to `PING_TARGET` (default 8.8.8.8) for every UE |

Each run writes `.evidence/<timestamp>/` (node list, loader log, Pod lists,
gNB/UE/AMF/SMF/UPF logs, per-UE status and ping output, `summary.md`). Attach
it when reporting results. The manual GitHub workflow uploads it as an
artifact.

## What has been executed

| Tier | Status |
|---|---|
| 1 – static/local | **Executed and passing** (2026-10-13, macOS arm64, Terraform 1.16.5, Helm 3.21.4, MongoDB 7.0.9, mongosh 2.2.5) |
| 2 – deployment health | **Executed and passing**: 11/11 checks (2026-10-13) |
| 3 – 5G functional | **Executed and passing**: 5/5 checks (2026-10-13) |

### Live run, 2026-10-13

Environment: GCP sandbox project, region `europe-west1` / zone
`europe-west1-b` (the sandbox's organisation policy forbids `europe-west9`),
GKE **1.36.4-gke.1391002** (REGULAR), Dataplane V2, nodes **Ubuntu 24.04.4 LTS,
kernel 6.8.0-1062-gke** (built with gcc-13). General pool 2 × e2-standard-2 (a
sandbox policy rejects e2-standard-4), UPF pool 1 × e2-standard-2.

| Check | Result |
|---|---|
| Nodes Ready / Ubuntu | 3/3, Ubuntu 24.04.4 LTS |
| gtp5g | `linux-headers-6.8.0-1062-gke` installed from the Ubuntu archive; gtp5g 0.10.2 built and loaded on 1/1 UPF node; UPF gate passed |
| free5GC Pods | 12 Running (AMF AUSF CHF NEF NRF NSSF PCF SMF UDM UDR, 1 UPF, MongoDB) |
| Secret sync (Workload Identity) | 3/3 Kubernetes Secrets populated from Secret Manager |
| MongoDB | authenticated root login; 10/10 IMSIs in all 6 collections; exactly 10 authentication records |
| N2 | NG Setup successful (`UERANSIM-gnb-208-93-1`, `is-ngap-up: true`) |
| Registration | 10/10 `RM-REGISTERED`, `CM-CONNECTED`, `MM-REGISTERED/NORMAL-SERVICE` |
| PDU sessions | 10/10 `PS-ACTIVE`, addresses 10.60.0.1–10.60.0.10 on `uesimtun0..9` |
| User plane | 10/10 UEs: `ping -I uesimtunN 8.8.8.8`, 3/3 packets, 0% loss |
| Evidence hygiene | no 128-bit hex value in any evidence file |

### Bugs found only by the live run (all fixed in this repository)

| Symptom | Root cause | Fix |
|---|---|---|
| Secret IAM bindings: `Identity Pool does not exist` | The Workload Identity pool appears asynchronously after cluster creation | `module.secrets` now depends on the whole GKE module |
| Regional secrets: `does not match the expected format [projects/*/secrets/*]` | gcloud sends regional names to the global endpoint | `bootstrap-secrets.sh` sets the regional endpoint override for its own process |
| gtp5g DaemonSet created no Pods | GKE's ResourceQuota restricts `system-node-critical` to `kube-system` | priority class removed; a check forbids `system-*` classes |
| All NFs `AuthenticationFailed`; MongoDB log "Deploying MongoDB with persisted data" on a new disk | Upstream mounts the PD on the data directory; `lost+found` makes Bitnami skip user creation | `mongodb.persistence.mountPath: /bitnami/mongodb`; regression check added |
| Re-apply after a Helm timeout: release "will be created" | Timed-out release exists in the cluster but not in state | `upgrade_install = true` on both releases |
