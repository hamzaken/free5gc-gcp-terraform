#!/usr/bin/env bash
# Functional test of provisioning/subscribers/provision.js against a real,
# throwaway MongoDB with authentication enabled (no cloud, no containers).
#
# Users are created as the Bitnami chart does: "root" in admin, and the
# application user "free5gc" with readWrite on the "free5gc" database only.
#
# Usage: MONGOD=/path/to/mongod MONGOSH=/path/to/mongosh tests/test_provisioner_local.sh
# Requires .render/subscriber_profile.yaml (scripts/validate.sh step 5).

# shellcheck source=scripts/lib/common.sh
source "$(dirname "$0")/../scripts/lib/common.sh"

MONGOD="${MONGOD:-mongod}"
MONGOSH="${MONGOSH:-mongosh}"
require_cmd "${MONGOD}" "${MONGOSH}" openssl

profile="${REPO_ROOT}/.render/subscriber_profile.yaml"
[[ -s "${profile}" ]] || die "missing ${profile}; run scripts/validate.sh first"
script="${REPO_ROOT}/provisioning/subscribers/provision.js"
asserts="${REPO_ROOT}/tests/provisioner/assert.js"

work="$(mktemp -d)"
port=$(( 20000 + RANDOM % 20000 ))
cleanup() {
  "${MONGOSH}" --nodb --quiet --norc --eval \
    'try { new Mongo(process.env.ROOT_URI).getDB("admin").shutdownServer({force: true}) } catch (e) {}' \
    >/dev/null 2>&1 || true
  sleep 1
  rm -rf -- "${work:?}"
}
trap cleanup EXIT
mkdir -p "${work}/db"

start_mongod() {
  "${MONGOD}" --dbpath "${work}/db" --bind_ip 127.0.0.1 --port "${port}" "$@" \
    --logpath "${work}/mongod.log" >/dev/null 2>&1 &
  for _ in $(seq 1 50); do
    "${MONGOSH}" --nodb --quiet --norc --eval "new Mongo('mongodb://127.0.0.1:${port}')" >/dev/null 2>&1 && return 0
    sleep 0.2
  done
  die "mongod did not start (see ${work}/mongod.log)"
}

ROOT_PW="$(openssl rand -hex 24)"; APP_PW="$(openssl rand -hex 24)"
export ROOT_PW APP_PW
export ROOT_URI="mongodb://root:${ROOT_PW}@127.0.0.1:${port}/admin"

log "starting mongod on 127.0.0.1:${port} (no auth) to create users"
start_mongod
"${MONGOSH}" --nodb --quiet --norc --eval "
  const c = new Mongo('mongodb://127.0.0.1:${port}');
  c.getDB('admin').createUser({ user: 'root', pwd: process.env.ROOT_PW, roles: ['root'] });
  c.getDB('free5gc').createUser({ user: 'free5gc', pwd: process.env.APP_PW, roles: [{ role: 'readWrite', db: 'free5gc' }] });
  c.getDB('admin').shutdownServer({ force: true });" >/dev/null 2>&1 || true
sleep 1

log "restarting mongod with --auth"
start_mongod --auth

# Credentials in the exact format written by scripts/bootstrap-secrets.sh.
creds="${work}/subscribers.txt"
{
  echo "# imsi k opc"
  while IFS= read -r imsi; do
    printf '%s %s %s\n' "${imsi}" "$(openssl rand -hex 16)" "$(openssl rand -hex 16)"
  done < <(imsi_list "${REPO_ROOT}/config/subscribers.yaml")
} > "${creds}"

export PROFILE_PATH="${profile}" CREDENTIALS_PATH="${creds}" PROVISIONER_CONNECT_ATTEMPTS=3
export MONGODB_URI="mongodb://free5gc:${APP_PW}@127.0.0.1:${port}/free5gc?authSource=free5gc"

provision() { "${MONGOSH}" --nodb --quiet --norc "${script}"; }
run_asserts() { PHASE="$1" MONGODB_URI="${ROOT_URI}" "${MONGOSH}" --nodb --quiet --norc "${asserts}"; }

assert_no_secrets_in() {
  local out="$1" secret
  for secret in "${APP_PW}" "${ROOT_PW}" $(grep -v '^#' "${creds}" | awk '{ print $2; print $3 }'); do
    [[ "${out}" != *"${secret}"* ]] || die "secret material found in provisioner output"
  done
}

log "TEST 1: first run inserts all subscribers"
out="$(provision)"; printf '%s\n' "${out}" | sed 's/^/    /' >&2
assert_no_secrets_in "${out}"
[[ "${out}" == *'"inserted":10'* ]] || die "expected 10 inserts per collection"
run_asserts initial >&2

log "TEST 2: second run is a no-op (idempotent)"
out="$(provision)"
assert_no_secrets_in "${out}"
[[ "${out}" != *'"inserted":1'* && "${out}" != *'"updated":1'* ]] || die "second run modified documents: ${out}"
log "  no document inserted or modified"

log "TEST 3: re-provisioning preserves NF-owned fields (SQN, ratingGroup, quota)"
run_asserts mutate >&2
provision >/dev/null
run_asserts after-mutation >&2

log "TEST 4: check mode"
out="$(PROVISIONER_MODE=check provision)" || die "check mode failed: ${out}"
log "  ${out}"

log "TEST 5: IMSI mismatch is rejected without echoing key material"
grep -v "$(imsi_list "${REPO_ROOT}/config/subscribers.yaml" | tail -n1)" "${creds}" > "${work}/missing.txt"
if out="$(CREDENTIALS_PATH="${work}/missing.txt" provision 2>&1)"; then die "mismatch accepted"; fi
[[ "${out}" == *"do not match"* ]] || die "unexpected error: ${out}"
assert_no_secrets_in "${out}"
log "  rejected: ${out##*ERROR: }"

log "TEST 6: malformed credential line is rejected without echoing it"
{ head -n2 "${creds}"; echo "208930000000099 not-a-key deadbeefdeadbeefdeadbeefdeadbeef"; } > "${work}/bad.txt"
if out="$(CREDENTIALS_PATH="${work}/bad.txt" provision 2>&1)"; then die "malformed line accepted"; fi
[[ "${out}" == *"malformed"* && "${out}" != *"deadbeef"* ]] || die "unexpected error or leak: ${out}"
log "  rejected without echoing the line"

log "TEST 7: wrong password fails cleanly without printing the URI"
if out="$(MONGODB_URI="mongodb://free5gc:wrong@127.0.0.1:${port}/free5gc?authSource=free5gc" PROVISIONER_CONNECT_ATTEMPTS=1 provision 2>&1)"; then
  die "wrong password accepted"
fi
[[ "${out}" != *"mongodb://"* ]] || die "connection URI printed: ${out}"
log "  ${out//$'\n'/ | }"

log "TEST 8: the application user cannot touch other databases"
if PHASE=x "${MONGOSH}" --nodb --quiet --norc --eval \
  'new Mongo(process.env.MONGODB_URI).getDB("admin").getCollection("x").insertOne({a:1})' >/dev/null 2>&1; then
  die "app user could write to the admin database"
fi
log "  write to admin denied as expected"

log "All provisioner tests passed."
