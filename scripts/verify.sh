#!/usr/bin/env bash
# Deployment health checks and 5G functional tests against a live cluster.
# Read-only: creates nothing, changes nothing (kubectl get/logs/exec only).
#
#   --level health      nodes, gtp5g, Pods, synced Secrets, MongoDB, subscribers
#   --level functional  gNB NG Setup, UE registration, PDU sessions, user plane
#   --level all         both (default)
#
# Evidence (command outputs, never secret values) is written to
# .evidence/<UTC timestamp>/ (git-ignored).
#
# Env: PING_TARGET (default 8.8.8.8), PING_COUNT (default 3)

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/lib/common.sh"

level="all"
while (( $# > 0 )); do
  case "$1" in
    --level) level="${2:?}"; shift 2 ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    *) die "unknown argument: $1" ;;
  esac
done
[[ "${level}" =~ ^(health|functional|all)$ ]] || die "invalid level: ${level}"

require_cmd kubectl terraform

# Ensure kubectl points at this stack's cluster (DNS endpoint, IAM-authorised).
if ! kubectl config current-context 2>/dev/null | grep -q "$(tf_output "${INFRA_DIR}" cluster_name 2>/dev/null || echo __none__)"; then
  require_cmd gcloud
  get_credentials
fi

NS5G="$(tf_output "${INFRA_DIR}" free5gc_namespace 2>/dev/null || echo free5gc)"
NSRAN="$(tf_output "${INFRA_DIR}" ueransim_namespace 2>/dev/null || echo ueransim)"
NSGTP="gtp5g-system"
PING_TARGET="${PING_TARGET:-8.8.8.8}"
PING_COUNT="${PING_COUNT:-3}"

EVID="${REPO_ROOT}/.evidence/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "${EVID}"
SUMMARY="${EVID}/summary.md"
printf '# Verification %s\n\n| Check | Result | Detail |\n|---|---|---|\n' "$(date -u +%FT%TZ)" > "${SUMMARY}"

npass=0; nfail=0
result() {
  # result PASS|FAIL "<check>" "<detail>"
  local status="$1" check="$2" detail="${3:-}"
  printf '| %s | %s | %s |\n' "${check}" "${status}" "${detail//|//}" >> "${SUMMARY}"
  if [[ "${status}" == "PASS" ]]; then npass=$((npass + 1)); log "PASS  ${check}  ${detail}"
  else nfail=$((nfail + 1)); warn "FAIL  ${check}  ${detail}"; fi
}
save() { tee "${EVID}/$1" ; }
expect_eq() {
  # expect_eq <actual> <expected> <check> <detail>
  if [[ "$1" == "$2" ]]; then result PASS "$3" "$4"; else result FAIL "$3" "$4"; fi
}

mapfile_compat() {
  # mapfile_compat <array-name> <command...>  (bash 3.2 has no mapfile)
  local __name="$1" __line; shift
  eval "${__name}=()"
  while IFS= read -r __line; do eval "${__name}+=(\"\${__line}\")"; done < <("$@")
}

# --------------------------------------------------------------------------
health() {
  log "== Deployment health =="

  kubectl get nodes -L free5gc.io/pool \
    -o custom-columns='NAME:.metadata.name,READY:.status.conditions[?(@.type=="Ready")].status,POOL:.metadata.labels.free5gc\.io/pool,OS:.status.nodeInfo.osImage,KERNEL:.status.nodeInfo.kernelVersion,KUBELET:.status.nodeInfo.kubeletVersion' \
    | save nodes.txt >/dev/null
  local not_ready
  not_ready="$(awk 'NR > 1 && $2 != "True"' "${EVID}/nodes.txt" | wc -l | tr -d ' ')"
  if [[ "${not_ready}" == "0" ]]; then result PASS "GKE nodes Ready" "$(($(wc -l < "${EVID}/nodes.txt") - 1)) nodes"
  else result FAIL "GKE nodes Ready" "${not_ready} not ready"; fi
  if awk 'NR > 1' "${EVID}/nodes.txt" | grep -vq 'Ubuntu'; then result FAIL "Ubuntu node image" "non-Ubuntu node present"
  else result PASS "Ubuntu node image" "$(awk 'NR == 2 { print $4, $5, $6 }' "${EVID}/nodes.txt")"; fi

  # gtp5g
  local ds_ready ds_want pod ver
  ds_ready="$(kubectl -n "${NSGTP}" get ds gtp5g-loader -o jsonpath='{.status.numberReady}' 2>/dev/null || echo 0)"
  ds_want="$(kubectl -n "${NSGTP}" get ds gtp5g-loader -o jsonpath='{.status.desiredNumberScheduled}' 2>/dev/null || echo '?')"
  pod="$(kubectl -n "${NSGTP}" get pods -l app.kubernetes.io/name=gtp5g-loader -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || true)"
  if [[ -n "${pod}" ]]; then
    kubectl -n "${NSGTP}" logs "${pod}" -c build-and-load > "${EVID}/gtp5g-loader.log" 2>&1 || true
    ver="$(kubectl -n "${NSGTP}" exec "${pod}" -c ready -- cat /sys/module/gtp5g/version 2>/dev/null || true)"
  fi
  if [[ "${ds_ready}" == "${ds_want}" && "${ds_want}" != "0" && -n "${ver:-}" ]]; then
    result PASS "gtp5g module loaded" "version ${ver} on ${ds_ready}/${ds_want} UPF nodes"
  else
    result FAIL "gtp5g module loaded" "${ds_ready}/${ds_want} ready; see ${EVID#"${REPO_ROOT}/"}/gtp5g-loader.log"
  fi

  # Workloads
  kubectl -n "${NS5G}" get pods -o wide | save pods-free5gc.txt >/dev/null
  local bad
  bad="$(kubectl -n "${NS5G}" get pods --no-headers 2>/dev/null \
    | awk '$3 != "Completed" { split($2, r, "/"); if (r[1] != r[2] || $3 != "Running") print $1 }')"
  if [[ -z "${bad}" ]]; then result PASS "free5GC Pods Ready" "$(grep -c Running "${EVID}/pods-free5gc.txt") running"
  else result FAIL "free5GC Pods Ready" "not ready: $(echo "${bad}" | tr '\n' ' ')"; fi

  local nf missing="" upf_count
  for nf in amf ausf chf nef nrf nssf pcf smf udm udr upf; do
    kubectl -n "${NS5G}" get pods -l "nf=${nf}" --no-headers 2>/dev/null | grep -q Running || missing="${missing} ${nf}"
  done
  upf_count="$(kubectl -n "${NS5G}" get pods -l nf=upf --no-headers 2>/dev/null | wc -l | tr -d ' ')"
  if [[ -z "${missing}" && "${upf_count}" == "1" ]]; then
    result PASS "NF set present" "AMF AUSF CHF NEF NRF NSSF PCF SMF UDM UDR + exactly 1 UPF"
  else
    result FAIL "NF set present" "missing:${missing:- none}; UPF Pods: ${upf_count}"
  fi

  # Secrets: names and keys only, never values.
  local s
  for s in "${NS5G}/mongodb-credentials" "${NS5G}/subscriber-credentials" "${NSRAN}/ue-credentials"; do
    if kubectl -n "${s%%/*}" get secret "${s##*/}" -o jsonpath='{.data}' 2>/dev/null | grep -q '":'; then
      # shellcheck disable=SC2016  # go-template syntax, not shell expansion
      result PASS "Secret synced: ${s}" "keys: $(kubectl -n "${s%%/*}" get secret "${s##*/}" -o go-template='{{range $k, $v := .data}}{{$k}} {{end}}')"
    else
      result FAIL "Secret synced: ${s}" "missing or empty (check SecretSync status)"
    fi
  done

  # MongoDB connectivity and subscriber presence (root password read from the
  # container's own environment; the script passed on argv contains no secret).
  local imsis_json out
  imsis_json="$(imsi_list "${REPO_ROOT}/config/subscribers.yaml" | awk 'BEGIN { printf "[" } { printf "%s\"%s\"", (NR > 1 ? "," : ""), $1 } END { printf "]" }')"
  out="$(kubectl -n "${NS5G}" exec mongodb-0 -c mongodb -- mongosh --nodb --quiet --norc --eval "
    const c = new Mongo('mongodb://root:' + encodeURIComponent(process.env.MONGODB_ROOT_PASSWORD) + '@127.0.0.1:27017/admin');
    const d = c.getDB('free5gc');
    const want = ${imsis_json}.map((i) => 'imsi-' + i);
    const colls = ['subscriptionData.authenticationData.authenticationSubscription', 'subscriptionData.provisionedData.amData',
      'subscriptionData.provisionedData.smData', 'subscriptionData.provisionedData.smfSelectionSubscriptionData',
      'policyData.ues.amData', 'policyData.ues.smData'];
    const r = {};
    for (const n of colls) r[n] = d.getCollection(n).distinct('ueId', { ueId: { \$in: want } }).length;
    r.total_auth_documents = d.getCollection(colls[0]).countDocuments({});
    r.expected = want.length;
    print(JSON.stringify(r));" 2>&1)" || true
  printf '%s\n' "${out}" > "${EVID}/mongodb-subscribers.json"
  if [[ "${out}" == *'"expected":'* ]]; then
    result PASS "MongoDB authenticated connection" "root login from Pod"
    local expected total
    expected="$(printf '%s' "${out}" | sed -n 's/.*"expected":\([0-9]*\).*/\1/p')"
    total="$(printf '%s' "${out}" | sed -n 's/.*"total_auth_documents":\([0-9]*\).*/\1/p')"
    if printf '%s' "${out}" | grep -Eo '"[a-zA-Z.]+":[0-9]+' | grep -v -e expected -e total_auth | awk -F: -v e="${expected}" '$2 != e { bad = 1 } END { exit bad }'; then
      result PASS "Subscribers provisioned" "${expected}/${expected} IMSIs in all 6 collections"
    else
      result FAIL "Subscribers provisioned" "${out}"
    fi
    if [[ "${total}" == "${expected}" ]]; then result PASS "Exactly the intended subscribers" "${total} authentication records"
    else result FAIL "Exactly the intended subscribers" "${total} authentication records, ${expected} expected"; fi
  else
    result FAIL "MongoDB authenticated connection" "$(printf '%s' "${out}" | head -c 200)"
  fi
}

# --------------------------------------------------------------------------
functional() {
  log "== 5G functional tests =="

  kubectl -n "${NSRAN}" get pods -o wide | save pods-ueransim.txt >/dev/null
  kubectl -n "${NSRAN}" logs deploy/ueransim-gnb --tail=500 > "${EVID}/gnb.log" 2>&1 || true
  kubectl -n "${NSRAN}" logs deploy/ueransim-ue --tail=5000 > "${EVID}/ue.log" 2>&1 || true
  kubectl -n "${NS5G}" logs -l nf=amf --tail=2000 > "${EVID}/amf.log" 2>&1 || true
  kubectl -n "${NS5G}" logs -l nf=smf --tail=2000 > "${EVID}/smf.log" 2>&1 || true
  kubectl -n "${NS5G}" logs -l nf=upf --tail=2000 > "${EVID}/upf.log" 2>&1 || true

  # N2: NG Setup between gNB and AMF (SCTP over Dataplane V2).
  local gnb_name gnb_status
  gnb_name="$(kubectl -n "${NSRAN}" exec deploy/ueransim-gnb -- ./nr-cli --dump 2>/dev/null | head -n1)"
  gnb_status="$(kubectl -n "${NSRAN}" exec deploy/ueransim-gnb -- ./nr-cli "${gnb_name}" --exec status 2>&1 || true)"
  printf '%s\n' "${gnb_status}" > "${EVID}/gnb-status.txt"
  if [[ "${gnb_status}" == *"is-ngap-up: true"* ]]; then result PASS "gNB NG Setup (N2/SCTP)" "${gnb_name}"
  else result FAIL "gNB NG Setup (N2/SCTP)" "see gnb.log / gnb-status.txt"; fi

  # Registration + PDU session per UE.
  local ues=() ue status ps addr iface registered=0 sessions=0 pinged=0 total
  mapfile_compat ues bash -c "kubectl -n '${NSRAN}' exec deploy/ueransim-ue -- ./nr-cli --dump 2>/dev/null | grep '^imsi-' | sort"
  total="${#ues[@]}"
  local expected
  expected="$(imsi_list "${REPO_ROOT}/config/subscribers.yaml" | wc -l | tr -d ' ')"
  if [[ "${total}" == "${expected}" ]]; then result PASS "UE processes running" "${total}/${expected}"
  else result FAIL "UE processes running" "${total}/${expected}"; fi

  kubectl -n "${NSRAN}" exec deploy/ueransim-ue -- ip -o -4 addr show > "${EVID}/ue-interfaces.txt" 2>&1 || true
  : > "${EVID}/ue-status.txt"; : > "${EVID}/ue-ping.txt"
  for ue in "${ues[@]+"${ues[@]}"}"; do
    status="$(kubectl -n "${NSRAN}" exec deploy/ueransim-ue -- ./nr-cli "${ue}" --exec status 2>&1 || true)"
    ps="$(kubectl -n "${NSRAN}" exec deploy/ueransim-ue -- ./nr-cli "${ue}" --exec ps-list 2>&1 || true)"
    printf '### %s\n%s\n%s\n' "${ue}" "${status}" "${ps}" >> "${EVID}/ue-status.txt"
    [[ "${status}" == *"RM-REGISTERED"* ]] && registered=$((registered + 1))
    if [[ "${ps}" == *"PS-ACTIVE"* ]]; then
      sessions=$((sessions + 1))
      addr="$(printf '%s\n' "${ps}" | sed -n 's/.*address: *\([0-9.]*\).*/\1/p' | head -n1)"
      iface="$(awk -v a="${addr}" '$4 ~ "^"a"/" { print $2 }' "${EVID}/ue-interfaces.txt" | head -n1)"
      if [[ -n "${iface}" ]] && kubectl -n "${NSRAN}" exec deploy/ueransim-ue -- \
          ping -I "${iface}" -c "${PING_COUNT}" -W 3 "${PING_TARGET}" >> "${EVID}/ue-ping.txt" 2>&1; then
        pinged=$((pinged + 1))
      fi
    fi
  done

  expect_eq "${registered}" "${expected}" "UE registration" "${registered}/${expected} RM-REGISTERED (see ue-status.txt)"
  expect_eq "${sessions}" "${expected}" "PDU session establishment" "${sessions}/${expected} PS-ACTIVE (see ue-status.txt)"
  expect_eq "${pinged}" "${expected}" "User plane via UPF (N3/N6)" "${pinged}/${expected} UEs reached ${PING_TARGET} (see ue-ping.txt)"
}

case "${level}" in
  health) health ;;
  functional) functional ;;
  all) health; functional ;;
esac

printf '\n%d passed, %d failed\n' "${npass}" "${nfail}" >> "${SUMMARY}"
log "Evidence: ${EVID#"${REPO_ROOT}/"}/ (${npass} passed, ${nfail} failed)"
(( nfail == 0 ))
