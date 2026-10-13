# Troubleshooting

Start with `scripts/verify.sh`. It saves logs and status to `.evidence/`.
Namespaces: `free5gc`, `ueransim`, `gtp5g-system`.

## Plan-time failures

| Message | Cause / fix |
|---|---|
| `Invalid config/network.yaml: ... overlaps ...` | Two ranges collide; the message names both. |
| `... is not a canonical IPv4 CIDR` | Host bits set (e.g. `10.20.5.0/16`); use the network address. |
| `pod_cidr /N only fits X nodes ...` | Enlarge `pod_cidr` or lower `max_pods_per_node`; capacity includes one surge node per pool. |
| `mnc must be 2 or 3 digits, quoted` | Quote PLMN values in YAML (`mnc: "01"`); unquoted `01` becomes the integer 1. |
| `The REGULAR channel default ... GKE 1.33+ is required` | Choose another `release_channel`, or wait for the rollout in your zone. |
| `Charts not found ... Run scripts/fetch-charts.sh first` | The platform stage needs the patched charts. |
| `tag v4.2.2 now points to ...` | Upstream moved the tag. Review the change before updating `scripts/lib/pins.sh`. |

## gtp5g / UPF

UPF stuck in `Init:0/1`:

```bash
kubectl -n free5gc logs deploy/free5gc-free5gc-upf-upf -c wait-gtp5g
kubectl -n gtp5g-system get pods -o wide
kubectl -n gtp5g-system logs <loader-pod> -c build-and-load
```

| Loader exit code / message | Meaning | Action |
|---|---|---|
| 2 `node is Ubuntu 'X' but builder image is 'Y'` | GKE moved to a new Ubuntu release | Update `images.ubuntu` (tag + digest) in `config/versions.yaml` |
| 5 `could not install linux-headers-<kver>` | No published headers for this GKE kernel yet | Pin an older node version, or wait for the headers. **This is the main platform risk** |
| 6 checksum mismatch | The GitHub tarball changed | Investigate before updating `source_sha256` |
| 8 build failed | gtp5g 0.10.2 does not build on this kernel (expected for >= 6.18) | Needs a newer gtp5g, and a UPF that accepts it (go-upf checks the version) |
| 10 `insmod failed` | Secure Boot or lockdown on the node | The UPF pool must have `enable_secure_boot = false` (default in this stack) |
| 3 `gtp5g X is loaded but Y is pinned` | A different version is already loaded | Recreate the UPF node pool or drain the node |

Check the module on a node:

```bash
kubectl -n gtp5g-system exec <loader-pod> -c ready -- cat /sys/module/gtp5g/version
```

Node auto-upgrades (mandatory on release channels) replace nodes with new
kernels. The DaemonSet rebuilds automatically, which can fail if headers lag.
Use a GKE maintenance exclusion during demos.

## Secrets not synced

Pods in `CreateContainerConfigError` (`secret "mongodb-credentials" not found`):

```bash
kubectl -n free5gc get secretsync,secretproviderclass
kubectl -n free5gc describe secretsync mongodb-credentials
gcloud secrets versions list free5gc-mongodb-app-password --location europe-west9
```

Usual causes: `bootstrap-secrets.sh` not run (no secret version); namespace or
ServiceAccount name differs between the two stages (the IAM principal includes
both); the secret is in a different region than the cluster.

## N2 / SCTP

```bash
kubectl -n ueransim logs deploy/ueransim-gnb -c wait-amf     # sctp_test loop
kubectl -n ueransim logs deploy/ueransim-gnb | grep -i 'ng setup'
kubectl -n free5gc logs -l nf=amf | grep -i -e ngap -e sctp
```

- SCTP needs Dataplane V2, Ubuntu nodes and GKE >= 1.32.2 (all enforced here).
- The NetworkPolicy `allow-n2-from-gnb` admits only Pods labelled
  `component=gnb` in the `ueransim` namespace.
- A PLMN, TAC or slice mismatch between gNB and AMF shows as NG Setup Failure
  in the AMF log.

## Registration fails

```bash
kubectl -n ueransim exec deploy/ueransim-ue -- ./nr-cli --dump
kubectl -n ueransim exec deploy/ueransim-ue -- ./nr-cli imsi-208930000000001 --exec status
kubectl -n free5gc logs -l nf=ausf; kubectl -n free5gc logs -l nf=udm
```

| Symptom | Likely cause |
|---|---|
| `MAC failure` / authentication reject | K/OPc in MongoDB differ from the UE's: rotated in Secret Manager but not re-provisioned. Run `scripts/deploy.sh --reprovision`. |
| `Synch failure`, then success | Normal SQN resynchronisation (e.g. after re-provisioning or a UE restart). |
| `UE not found` / `USER_NOT_FOUND` | Subscriber missing: `kubectl -n free5gc logs job/<subscriber-provisioner-…>`. |
| Registration reject, cause 7 or 62 | Slice/DNN mismatch between UE, AMF, NSSF and subscription (all derived from `config/*.yaml`; edit there, never in Pods). |

## PDU session or ping fails

```bash
kubectl -n ueransim exec deploy/ueransim-ue -- ./nr-cli imsi-208930000000001 --exec ps-list
kubectl -n free5gc logs -l nf=smf | grep -i -e pfcp -e upf
kubectl -n free5gc logs deploy/free5gc-free5gc-upf-upf
kubectl -n ueransim exec deploy/ueransim-ue -- ip -4 addr show
kubectl -n ueransim exec deploy/ueransim-ue -- ping -I uesimtun0 -c 3 8.8.8.8
```

- **SMF cannot associate with the UPF (PFCP):** the SMF resolves the UPF Pod IP
  once at start-up. If the UPF Pod was recreated, restart the SMF:
  `kubectl -n free5gc rollout restart deploy/free5gc-free5gc-smf-smf`.
- **Session up, no ping:** check UPF `iptables -t nat -S` (MASQUERADE for
  `ue_cidr`), Cloud NAT logs (errors only), and that the target is reachable
  from a Pod at all.
- **Large packets fail:** see MTU in [networking.md](networking.md#mtu).

## MongoDB

```bash
kubectl -n free5gc logs statefulset/mongodb
kubectl -n free5gc get pvc
# Subscriber count, without exposing the password on argv:
kubectl -n free5gc exec mongodb-0 -c mongodb -- mongosh --nodb --quiet --eval \
  "new Mongo('mongodb://root:'+encodeURIComponent(process.env.MONGODB_ROOT_PASSWORD)+'@127.0.0.1/admin').getDB('free5gc').getCollection('subscriptionData.authenticationData.authenticationSubscription').countDocuments({})"
```

NRF/UDR/PCF/CHF in `CrashLoopBackOff` with authentication errors: the
`mongodb-credentials` Secret changed after MongoDB was initialised. Bitnami
sets users only on first start, so either restore the old secret version or
delete the PVC (data loss) and re-provision.

## Teardown left resources

```bash
gcloud compute disks list --filter="name~^pvc- AND -users:*"
gcloud container clusters list
gcloud secrets list --location europe-west9
```

If `terraform/platform` cannot reach a cluster that no longer exists, clear its
state (the objects were deleted with the cluster):

```bash
terraform -chdir=terraform/platform state list | xargs -n1 terraform -chdir=terraform/platform state rm
```
