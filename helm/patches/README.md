# Chart patches

The official charts ([free5gc/free5gc-helm](https://github.com/free5gc/free5gc-helm)
tag `v4.2.2`, commit `0d0b4b392bbb1b099acb9a1b37c39e0647ff6d4c`) are never
forked or committed here. `scripts/fetch-charts.sh` clones that exact commit,
refuses to continue if the tag has moved, and applies these patches with
`git apply --check` first. A patch that no longer applies cleanly stops the
deployment.

Everything that *could* be done with values is done with values
(`helm/*.yaml.tftpl`). A patch exists only where the pinned templates offer no
value to achieve a requirement.

| Patch | Files | Why values were insufficient |
|---|---|---|
| `0001-smf-single-upf-configmap` | `free5gc-smf/templates/smf-configmap.yaml` | In non-Multus mode the default SMF wrapper only resolves the ULCL UPF Services (`iupf1`, `psaupf1`, `psaupf2`). The upstream README documents single-UPF as **replacing** this template with `smf-configmap-single-upf.yaml`, which ships in the same chart. The patch is exactly that replacement, unmodified. |
| `0002-amf-n2-service-clusterip` | `free5gc-amf/templates/amf-service.yaml` | The template always renders `nodePort`, which the API server rejects for `type: ClusterIP`. The patch emits `nodePort` only for `type: NodePort`, so N2 can stay internal. |
| `0003-mongodb-auth-uri-from-secret` | `free5gc-{nrf,udr,pcf,chf}/templates/*-deployment.yaml` | These NFs build `mongodb://<service>:<port>` with no way to add credentials, so MongoDB authentication is impossible through values. With `global.mongodbAuth.enabled`, the patch reads the password from a Secret (`secretKeyRef`), lets Kubernetes compose `MONGODB_URI` via `$(VAR)` expansion, and has `awk` (reading the URI from `ENVIRON`) write a config copy into a memory-backed `emptyDir`. The password never appears in a ConfigMap, a manifest, Helm values, Terraform state or a process command line. Disabled, the templates render exactly as upstream. |
| `0004-upf-init-containers` | `free5gc-upf/templates/upf/upf-deployment.yaml` | No init-container hook exists. It is used for the `wait-gtp5g` gate, which keeps the UPF from starting until a compatible gtp5g version is loaded on its node (the upstream wrapper waits 30 s for `upfgtp` and then starts anyway). |
| `0005-ueransim-ue-extra-volumes` | `ueransim/templates/ue/ue-deployment.yaml` | No hook for extra volumes exists. It is used to mount the per-UE credentials Secret and a memory-backed scratch directory, so K/OPc never sit in a ConfigMap or in Helm values. |
| `0006-nrf-duplicate-readiness-probe` | `free5gc-nrf/templates/nrf-deployment.yaml` | Upstream bug: the NRF container emits `readinessProbe` twice, which is malformed YAML that strict parsers (kubeconform `-strict`) reject. Lenient parsers keep the last block, so the patch deletes the first one (an HTTP probe on port 80, where the NRF does not listen). Runtime behaviour is unchanged. |

Patches 0002, 0004 and 0005 add generic, opt-in extension points that would be
reasonable upstream contributions; 0003 could become one with a
`global.mongodb.uri` value.

## Regenerating a patch

```bash
git clone https://github.com/free5gc/free5gc-helm.git /tmp/f && cd /tmp/f
git checkout 0d0b4b392bbb1b099acb9a1b37c39e0647ff6d4c
for p in /path/to/repo/helm/patches/000[1-N]*.patch; do git apply "$p"; done   # up to the one you edit
# ...edit...
git diff > /path/to/repo/helm/patches/000N-<name>.patch
scripts/validate.sh --refetch
```
