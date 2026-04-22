#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
ROOTDIR=$(CDPATH='' cd -- "${SCRIPT_DIR}/.." && pwd)

IMAGE=${1:-${ROOTDIR}/bootwrapper/linux.axf}
VMLINUX=${2:-${ROOTDIR}/linux-7.0/vmlinux}
OUTDIR=${3:-${ROOTDIR}/profiles/kernel-pgo/trace-run}
WORKLOAD_FILE=${PGO_WORKLOAD_FILE:-${ROOTDIR}/configs/pgo-workload.txt}
TIMEOUT=${QEMU_TIMEOUT:-180}
BOOT_MARKER=${QEMU_BOOT_MARKER:-Linux for Cortex-M}

TRACE_LOG=${OUTDIR}/qemu-exec.log
CONSOLE_LOG=${OUTDIR}/qemu-console.log
MANIFEST_LOG=${OUTDIR}/qemu-profile-manifest.txt
PROFILE_PREFIX=${OUTDIR}/kernel

mkdir -p "${OUTDIR}"

if [ ! -f "${IMAGE}" ]; then
    echo "ERROR: missing kernel image: ${IMAGE}" >&2
    exit 1
fi

if [ ! -f "${VMLINUX}" ]; then
    echo "ERROR: missing vmlinux image: ${VMLINUX}" >&2
    exit 1
fi

if [ ! -f "${WORKLOAD_FILE}" ]; then
    echo "ERROR: missing workload file: ${WORKLOAD_FILE}" >&2
    exit 1
fi

rm -f "${TRACE_LOG}" "${CONSOLE_LOG}" "${MANIFEST_LOG}" \
    "${PROFILE_PREFIX}_ld_profile.txt" "${PROFILE_PREFIX}_summary.txt"

QEMU_LOG=exec \
QEMU_LOG_FILENAME="${TRACE_LOG}" \
    expect "${SCRIPT_DIR}/qemu-profile.expect" \
        "${IMAGE}" "${CONSOLE_LOG}" "${TIMEOUT}" "${BOOT_MARKER}" "${MANIFEST_LOG}" "${WORKLOAD_FILE}"

printf 'workload_sha256=%s\n' "$(sha256sum "${WORKLOAD_FILE}" | cut -d' ' -f1)" >>"${MANIFEST_LOG}"

PATH="${ROOTDIR}/toolchain/bin:${PATH}" \
python3 "${SCRIPT_DIR}/qemu-trace-to-orderfile.py" \
    --trace "${TRACE_LOG}" \
    --vmlinux "${VMLINUX}" \
    --manifest "${MANIFEST_LOG}" \
    --profile-prefix "${PROFILE_PREFIX}"

echo "profile artifacts:"
echo "  ${TRACE_LOG}"
echo "  ${CONSOLE_LOG}"
echo "  ${MANIFEST_LOG}"
echo "  ${PROFILE_PREFIX}_ld_profile.txt"
echo "  ${PROFILE_PREFIX}_summary.txt"
