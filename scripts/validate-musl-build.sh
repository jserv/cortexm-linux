#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
ROOTDIR=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)
TARGET=${TARGET:-arm-uclinuxfdpiceabi}
TOOLCHAIN=${TOOLCHAIN:-${ROOTDIR}/toolchain}
ROOTFS=${ROOTFS:-${ROOTDIR}/rootfs}
IMAGE=${1:-${ROOTDIR}/bootwrapper/linux.axf}
LOG=${2:-${ROOTDIR}/qemu-musl.log}
WORKLOAD=${3:-${ROOTDIR}/configs/musl-smoke-workload.txt}
METRICS=${4:-${ROOTDIR}/qemu-musl.metrics}
READELF=${READELF:-${TOOLCHAIN}/bin/${TARGET}-readelf}

BUSYBOX=${ROOTFS}/bin/busybox
LOADER=${ROOTFS}/lib/ld-musl-arm-fdpic.so.1
LIBC=${ROOTFS}/lib/libc.so

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

[ -x "${READELF}" ] || fail "missing target readelf: ${READELF}"
[ -f "${BUSYBOX}" ] || fail "missing rootfs busybox: ${BUSYBOX}"
[ -f "${LIBC}" ] || fail "missing musl libc: ${LIBC}"
[ -L "${LOADER}" ] || fail "missing musl loader symlink: ${LOADER}"
[ -f "${IMAGE}" ] || fail "missing kernel image: ${IMAGE}"
[ -f "${WORKLOAD}" ] || fail "missing workload file: ${WORKLOAD}"

INTERP=$(LC_ALL=C "${READELF}" -l "${BUSYBOX}" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
[ "${INTERP}" = "/lib/ld-musl-arm-fdpic.so.1" ] || fail "unexpected PT_INTERP: ${INTERP:-<none>}"

NEEDED=$(
    LC_ALL=C "${READELF}" -d "${BUSYBOX}" 2>/dev/null |
        sed -n 's/.*Shared library: \[\(.*\)\]/\1/p'
)
[ -n "${NEEDED}" ] || fail "busybox is missing DT_NEEDED entries"
echo "${NEEDED}" | grep -qx 'libc.so' || fail "busybox does not depend on musl libc"
echo "${NEEDED}" | grep -q 'libuClibc' && fail "busybox still depends on uClibc-ng"

LOADER_TARGET=$(readlink "${LOADER}" || true)
[ "${LOADER_TARGET}" = "/lib/libc.so" ] || fail "unexpected musl loader symlink target: ${LOADER_TARGET:-<none>}"

exec "${SCRIPT_DIR}/validate-qemu.sh" "${IMAGE}" "${LOG}" "${WORKLOAD}" "${METRICS}"
