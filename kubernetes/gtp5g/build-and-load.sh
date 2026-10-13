#!/usr/bin/env bash
# Build and load the gtp5g kernel module on a GKE Ubuntu node.
#
# Runs as a privileged init container of DaemonSet gtp5g-system/gtp5g-loader,
# once per node start, only on the dedicated UPF node pool. The container
# image must be the same Ubuntu release as the node (GKE Ubuntu = 24.04).
#
# Inputs (environment):
#   GTP5G_VERSION   expected module version, e.g. 0.10.2
#   GTP5G_URL       source tarball URL
#   GTP5G_SHA256    expected SHA-256 of the tarball
#   HOST_ROOT       where the host's / is mounted read-only (default /host)
#
# Exit codes: 0 = module loaded with the expected version; non-zero = failed
# (the DaemonSet Pod stays in Init:Error/CrashLoopBackOff and the UPF's
# wait-gtp5g init container keeps the UPF from starting).

set -euo pipefail

: "${GTP5G_VERSION:?}" "${GTP5G_URL:?}" "${GTP5G_SHA256:?}"
HOST_ROOT="${HOST_ROOT:-/host}"
KVER="$(uname -r)"
SYS_VERSION=/sys/module/gtp5g/version

log() { printf '[gtp5g-loader] %s\n' "$*"; }

# Read one field of an os-release file without sourcing it (the host file is
# data, never executed as shell code).
os_field() {
  sed -n "s/^$2=\"\{0,1\}\([^\"]*\)\"\{0,1\}\$/\1/p" "$1" | head -n1
}

log "node kernel: ${KVER}"
log "node OS: $(os_field "${HOST_ROOT}/etc/os-release" PRETTY_NAME)"
log "container OS: $(os_field /etc/os-release PRETTY_NAME)"

host_codename="$(os_field "${HOST_ROOT}/etc/os-release" VERSION_CODENAME)"
container_codename="$(os_field /etc/os-release VERSION_CODENAME)"
[[ -n "${host_codename}" ]] || host_codename="unknown"
if [[ "${host_codename}" != "${container_codename}" ]]; then
  log "ERROR: node is Ubuntu '${host_codename}' but builder image is '${container_codename}'."
  log "Update images.ubuntu in config/versions.yaml to match the GKE node image."
  exit 2
fi

if [[ -r "${SYS_VERSION}" ]]; then
  loaded="$(cat "${SYS_VERSION}")"
  if [[ "${loaded}" == "${GTP5G_VERSION}" ]]; then
    log "gtp5g ${loaded} already loaded; nothing to do"
    exit 0
  fi
  # Never rmmod automatically: a running UPF may be using the module.
  log "ERROR: gtp5g ${loaded} is loaded but ${GTP5G_VERSION} is pinned."
  log "Drain the node (or recreate the UPF node pool) to replace the module."
  exit 3
fi

# The kernel's own compiler major version from /proc/version, e.g.
# "... (x86_64-linux-gnu-gcc-13 (Ubuntu 13.3.0-6ubuntu2~24.04) 13.3.0, ..."
kcc_major="$(sed -n 's/.*gcc-\([0-9][0-9]*\)[ )].*/\1/p' /proc/version)"
[[ -n "${kcc_major}" ]] || kcc_major="$(sed -n 's/.*gcc (Ubuntu \([0-9][0-9]*\)\..*/\1/p' /proc/version)"
[[ -n "${kcc_major}" ]] || kcc_major="$(sed -n 's/.*gcc version \([0-9][0-9]*\)\..*/\1/p' /proc/version)"
[[ -n "${kcc_major}" ]] || { log "ERROR: cannot determine kernel compiler from /proc/version"; exit 4; }
log "kernel was built with gcc-${kcc_major}"

export DEBIAN_FRONTEND=noninteractive
log "installing build dependencies and linux-headers-${KVER}"
apt-get update -qq
if ! apt-get install -y -qq --no-install-recommends \
    ca-certificates curl make "gcc-${kcc_major}" libc6-dev kmod \
    "linux-headers-${KVER}" >/dev/null; then
  log "ERROR: could not install linux-headers-${KVER} from the Ubuntu archive."
  log "This GKE node image kernel has no published headers; gtp5g cannot be built."
  exit 5
fi

work="$(mktemp -d)"
log "downloading ${GTP5G_URL}"
curl -fsSL --retry 5 --retry-delay 3 -o "${work}/gtp5g.tar.gz" "${GTP5G_URL}"
echo "${GTP5G_SHA256}  ${work}/gtp5g.tar.gz" | sha256sum -c - >/dev/null \
  || { log "ERROR: checksum mismatch for the gtp5g source tarball"; exit 6; }
tar -xzf "${work}/gtp5g.tar.gz" -C "${work}"
src="$(find "${work}" -mindepth 1 -maxdepth 1 -type d -name 'gtp5g-*' | head -n1)"

src_version="$(sed -n 's/^#define DRV_VERSION "\(.*\)"/\1/p' "${src}/include/genl_version.h")"
[[ "${src_version}" == "${GTP5G_VERSION}" ]] \
  || { log "ERROR: source declares version ${src_version}, expected ${GTP5G_VERSION}"; exit 7; }

log "building gtp5g ${GTP5G_VERSION} for ${KVER}"
make -C "${src}" -j"$(nproc)" KVER="${KVER}" CC="gcc-${kcc_major}" >"${work}/build.log" 2>&1 \
  || { tail -n 50 "${work}/build.log"; log "ERROR: gtp5g build failed for kernel ${KVER}"; exit 8; }

# gtp5g depends on udp_tunnel (in-tree). Load it from the host's module tree.
modprobe --dirname="${HOST_ROOT}" udp_tunnel \
  || { log "ERROR: could not load udp_tunnel from the host module tree"; exit 9; }

log "loading gtp5g.ko"
insmod "${src}/gtp5g.ko" \
  || { log "ERROR: insmod failed (Secure Boot/lockdown enabled on this node?)"; dmesg 2>/dev/null | tail -n 20 || true; exit 10; }

loaded="$(cat "${SYS_VERSION}")"
[[ "${loaded}" == "${GTP5G_VERSION}" ]] \
  || { log "ERROR: loaded module reports version ${loaded}"; exit 11; }

log "gtp5g ${loaded} loaded successfully on ${KVER}"
