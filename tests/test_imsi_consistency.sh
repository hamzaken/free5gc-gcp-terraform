#!/usr/bin/env bash
# The IMSI list is derived twice: in Terraform (provisioning, UE routing) and
# in bash (scripts/bootstrap-secrets.sh, which generates the K/OPc per IMSI).
# This test asserts both derivations agree for every valid fixture.

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/../scripts/lib/common.sh"

harness="${REPO_ROOT}/tests/imsi"
state_dir="${REPO_ROOT}/.render/imsi"
mkdir -p "${state_dir}"
terraform -chdir="${harness}" init -input=false >/dev/null

fixtures=(
  "${REPO_ROOT}/config/subscribers.yaml"
  "${REPO_ROOT}/terraform/modules/config/tests/fixtures/subscribers-leading-zeros.yaml"
  "${REPO_ROOT}/terraform/modules/config/tests/fixtures/subscribers-3digit-mnc.yaml"
)

fail=0
for f in "${fixtures[@]}"; do
  name="$(basename "${f}" .yaml)"
  terraform -chdir="${harness}" apply -auto-approve -input=false \
    -state="${state_dir}/${name}.tfstate" -var "subscribers_file=${f}" >/dev/null
  tf_list="$(terraform -chdir="${harness}" output -state="${state_dir}/${name}.tfstate" -raw imsis)"
  sh_list="$(imsi_list "${f}")"
  if [[ "${tf_list}" == "${sh_list}" ]]; then
    log "PASS ${name}: $(printf '%s\n' "${sh_list}" | wc -l | tr -d ' ') IMSIs, first $(printf '%s\n' "${sh_list}" | head -n1)"
  else
    warn "FAIL ${name}"
    diff <(printf '%s\n' "${tf_list}") <(printf '%s\n' "${sh_list}") >&2 || true
    fail=1
  fi
done
exit "${fail}"
