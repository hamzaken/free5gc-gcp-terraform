# Deployment guide

## 1. Prerequisites

| Tool | Version | Used by |
|---|---|---|
| Terraform | >= 1.9 (tested 1.16.5) | both stages |
| Google Cloud CLI | recent, with `gke-gcloud-auth-plugin` | ADC, secrets bootstrap, kubectl credentials |
| kubectl | >= 1.31 | `verify.sh`, `destroy.sh` |
| git, openssl, bash | any (bash 3.2 on macOS is fine) | scripts |
| Helm | v3.21.4 | `validate.sh` only (Terraform uses the Helm provider) |
| python3 | >= 3.8 | `validate.sh` only |

A GCP project with billing enabled. Organisation policies that forbid
regional Secret Manager, Ubuntu node images, disabling Secure Boot, or Cloud
NAT will block parts of this design.

**Restricted projects (training sandboxes, strict organisations).** Check
`gcp.resourceLocations` and any machine-type allow-list before deploying. If
`europe-west9` or `e2-standard-4` are not allowed, start from
`terraform/infra/terraform.tfvars.sandbox.example` (`europe-west1`, general
pool 2 × e2-standard-2). The general pool needs **at least 4 vCPU in total**:
one e2-standard-2 leaves Pods `Pending`, and `terraform plan` rejects that
layout with an explanation.

## 2. IAM

<a id="iam"></a>For a personal lab project `roles/owner` works. Least-privilege
set for the administrator (or the CI deployer service account):

| Role | Why |
|---|---|
| `roles/serviceusage.serviceUsageAdmin` | enable the required APIs |
| `roles/compute.networkAdmin`, `roles/compute.securityAdmin` | VPC, subnet, router, NAT; firewall rule |
| `roles/container.admin` | cluster, node pools, Kubernetes objects |
| `roles/iam.serviceAccountAdmin`, `roles/iam.serviceAccountUser` | create the node SA and attach it to node pools |
| `roles/resourcemanager.projectIamAdmin` | grant the node SA its role |
| `roles/cloudkms.admin` | key ring, key, key IAM |
| `roles/artifactregistry.admin` | Docker Hub remote repository and its IAM |
| `roles/secretmanager.admin` | secret containers, accessor bindings, adding versions |

## 3. Deploy

```bash
gcloud auth login
gcloud auth application-default login          # Terraform + scripts use ADC

cp terraform/infra/terraform.tfvars.example terraform/infra/terraform.tfvars
$EDITOR terraform/infra/terraform.tfvars        # project_id (+ optional sizing)
$EDITOR config/network.yaml config/subscribers.yaml   # optional

scripts/validate.sh                             # offline checks, no cloud access
scripts/deploy.sh                               # asks "yes" before each billable apply
scripts/verify.sh                               # health + 5G functional tests
```

`deploy.sh` runs four stages (each can be run alone with `--stage`):

1. **infra** – `terraform -chdir=terraform/infra plan`, confirm, apply
   (about 10-15 minutes, mostly the GKE cluster).
2. **secrets** – `scripts/bootstrap-secrets.sh`: generates the MongoDB passwords
   and one K/OPc pair per IMSI, and stores them in Secret Manager. Idempotent.
3. **charts** – `scripts/fetch-charts.sh`: pinned upstream charts + patches.
4. **platform** – `terraform -chdir=terraform/platform plan`, confirm, apply.
   Order: namespaces and NetworkPolicies → Secret sync → gtp5g loader → free5GC
   (Helm waits for all Pods, including the UPF behind its gtp5g gate) →
   provisioning Job (waits for completion) → UERANSIM. A first run takes about
   10-20 minutes (image pulls through the registry proxy, gtp5g build).

Manual equivalent, without the script:

```bash
terraform -chdir=terraform/infra init && terraform -chdir=terraform/infra apply
scripts/bootstrap-secrets.sh
scripts/fetch-charts.sh
cp terraform/platform/terraform.tfvars.example terraform/platform/terraform.tfvars
# fill it from: terraform -chdir=terraform/infra output
terraform -chdir=terraform/platform init && terraform -chdir=terraform/platform apply
$(terraform -chdir=terraform/infra output -raw get_credentials_command)
```

### Administrator access to the cluster

The control plane has no public IP endpoint. `kubectl` reaches it through the
**DNS-based endpoint**, authorised by IAM:

```bash
gcloud container clusters get-credentials free5gc-gke \
  --zone europe-west9-a --project <project> --dns-endpoint
kubectl get nodes
```

`authorized_networks` only matters if you also reach the private IP endpoint
from inside the VPC or over VPN.

## 4. Changing subscribers or addressing

- **Subscribers:** edit `config/subscribers.yaml`, then
  `scripts/bootstrap-secrets.sh --rotate-subscribers` (credentials must match the
  IMSI list), then `scripts/deploy.sh --stage platform`. The provisioning Job name
  changes with the profile, so it re-runs. It never deletes subscribers that
  were removed from the list; `verify.sh` reports extra records.
- **Rotate keys only:** `scripts/bootstrap-secrets.sh --rotate-subscribers`, then
  `scripts/deploy.sh --reprovision`.
- **IP ranges:** VPC and secondary ranges cannot be changed in place on an
  existing cluster. Destroy and redeploy. `ue_cidr` changes only need the
  platform stage.

## 5. Costs (estimates, 2026-10-13, europe-west9, on-demand, 730 h/month)

| Item | Default size | Approx. USD/month | Source |
|---|---|---|---|
| General node | 1 × e2-standard-4 | ~114 ($0.1555/h) | [Spare Cores](https://sparecores.com/server/gcp/e2-standard-4), [gcloud-compute.com](https://gcloud-compute.com/e2-standard-4.html) |
| UPF node | 1 × e2-standard-2 | ~57 (half of the above) | same |
| GKE cluster management fee | 1 zonal cluster | 73 ($0.10/h); the GKE free tier credit usually offsets one zonal cluster per billing account. Check [GKE pricing](https://cloud.google.com/kubernetes-engine/pricing) | GKE pricing page |
| Persistent Disk (pd-balanced) | 2 × 50 GB boot + 8 GB MongoDB | ~12-28 (aggregators quote $0.116-$0.26 per GB-month for Paris) | [gcloud-compute.com](https://gcloud-compute.com/europe-west9.html), [Cloud Mercato](https://pcr.cloud-mercato.com/providers/google/volumes/pd-balanced) |
| Cloud NAT | 2 VMs + 1 auto IP | ~2 gateway + ~4 IP + $0.045/GiB processed | [Cloud NAT pricing](https://cloud.google.com/nat/pricing) |
| Cloud Logging | system + workload logs at `info` | usually within the 50 GiB/project/month free allotment; $0.50/GiB beyond | Cloud Logging pricing |
| Secret Manager, KMS, Artifact Registry | 3 secrets, 1 key, ~1-2 GB cache | < 1 | respective pricing pages |
| **Total** | | **~190-210 / month, about $0.27/h**, plus 73 if the free tier is already used | |

Cost control:

- **Destroy when idle** (`scripts/destroy.sh`). A 4-hour lab session costs
  about $1-1.50.
- `spot = true` on either pool roughly halves compute cost (Spot nodes can be
  preempted; the UPF node is re-prepared automatically by the gtp5g DaemonSet).
- `logging_components = ["SYSTEM_COMPONENTS"]` removes workload logs.
- Keep `enable_vpc_flow_logs = false` unless investigating.
- Use the [Pricing Calculator](https://cloud.google.com/products/calculator) for
  current numbers before deploying; prices above are third-party estimates.

## 6. GitHub Actions (optional)

<a id="github-actions"></a>`.github/workflows/ci.yml` runs on every PR with no
cloud access. `.github/workflows/deploy.yml` can deploy, verify or destroy, but
only on **manual dispatch**, with the project ID typed as confirmation, through
the `gcp-lab` Environment (configure required reviewers), authenticated by
**GitHub OIDC → Workload Identity Federation** (no keys).

One-time setup (run by a project administrator; it creates IAM resources):

```bash
PROJECT=<project-id>; REPO=<owner>/<repo>
PROJECT_NUMBER=$(gcloud projects describe "$PROJECT" --format='value(projectNumber)')

# State bucket (private, versioned)
gcloud storage buckets create "gs://${PROJECT}-tfstate" --project "$PROJECT" \
  --location europe-west9 --uniform-bucket-level-access --public-access-prevention
gcloud storage buckets update "gs://${PROJECT}-tfstate" --versioning

# Workload Identity pool + GitHub provider restricted to this repository
gcloud iam workload-identity-pools create github --project "$PROJECT" --location global
gcloud iam workload-identity-pools providers create-oidc github --project "$PROJECT" \
  --location global --workload-identity-pool github \
  --issuer-uri https://token.actions.githubusercontent.com \
  --attribute-mapping 'google.subject=assertion.sub,attribute.repository=assertion.repository,attribute.environment=assertion.environment' \
  --attribute-condition "assertion.repository == '${REPO}' && assertion.environment == 'gcp-lab'"

# Deployer service account (no keys), impersonable only from that repo/environment
gcloud iam service-accounts create free5gc-deployer --project "$PROJECT"
SA="free5gc-deployer@${PROJECT}.iam.gserviceaccount.com"
gcloud iam service-accounts add-iam-policy-binding "$SA" --project "$PROJECT" \
  --role roles/iam.workloadIdentityUser \
  --member "principalSet://iam.googleapis.com/projects/${PROJECT_NUMBER}/locations/global/workloadIdentityPools/github/attribute.repository/${REPO}"
# then grant $SA the roles from section 2, and roles/storage.objectAdmin on the state bucket
```

Repository variables: `GCP_PROJECT_ID`, `GCP_WIF_PROVIDER`
(`projects/<num>/locations/global/workloadIdentityPools/github/providers/github`),
`GCP_DEPLOY_SA`, `TF_STATE_BUCKET`. None of them is a secret.

## 7. Teardown

```bash
scripts/destroy.sh                 # platform, then infra; asks for confirmation
scripts/destroy.sh --platform-only # keep the cluster, remove workloads and data
```

The script deletes the namespaces first, so the MongoDB PVC (and its
Persistent Disk) is removed while the cluster still exists, waits for the
PersistentVolume to disappear, destroys the infrastructure, then lists any
unattached `pvc-*` disks that would still be billed. Destroying infra also
deletes the Secret Manager secrets (subscriber keys are lost). The KMS key ring
cannot be deleted in GCP; its key versions are scheduled for destruction and
stop costing money.
