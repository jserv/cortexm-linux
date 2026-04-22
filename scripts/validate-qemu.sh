#!/bin/sh

set -eu

SCRIPT_DIR=$(CDPATH='' cd -- "$(dirname "$0")" && pwd)
IMAGE=${1:-bootwrapper/linux.axf}
LOG=${2:-qemu.log}
WORKLOAD=${3:-${SCRIPT_DIR}/../configs/pgo-workload.txt}
TIMEOUT=${QEMU_TIMEOUT:-180}
BOOT_MARKER=${QEMU_BOOT_MARKER:-Linux for Cortex-M}

if [ ! -f "${IMAGE}" ]; then
    echo "ERROR: missing kernel image: ${IMAGE}" >&2
    exit 1
fi

if [ ! -f "${WORKLOAD}" ]; then
    echo "ERROR: missing workload file: ${WORKLOAD}" >&2
    exit 1
fi

exec expect "${SCRIPT_DIR}/validate-qemu.expect" "${IMAGE}" "${LOG}" "${TIMEOUT}" "${BOOT_MARKER}" "${WORKLOAD}"
