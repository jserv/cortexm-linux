#!/bin/sh

set -eu

ROOTDIR=$1
LINUXDIR=$2
BOOTWRAPPERDIR=$3
OUTDIR=$4

TARGET=arm-uclinuxfdpiceabi
SIZE_TOOL=${ROOTDIR}/toolchain/bin/${TARGET}-size
NM_TOOL=${ROOTDIR}/toolchain/bin/${TARGET}-nm

mkdir -p "${OUTDIR}"

report_file_sizes() {
    {
        echo "artifact bytes"
        for f in \
            "${LINUXDIR}/vmlinux" \
            "${LINUXDIR}/arch/arm/boot/Image" \
            "${ROOTDIR}/rootfs/bin/busybox" \
            "${ROOTDIR}/toolchain/${TARGET}/lib/libc.so" \
            "${ROOTDIR}/toolchain/${TARGET}/lib/ld-uClibc.so.0" \
            "${BOOTWRAPPERDIR}/linux.axf"; do
            [ -f "${f}" ] || continue
            printf '%s %s\n' "${f}" "$(wc -c <"${f}" | tr -d ' ')"
        done

        if [ -f "${LINUXDIR}/arch/arm/boot/Image" ]; then
            printf '%s %s\n' "${LINUXDIR}/arch/arm/boot/Image.gz" \
                "$(gzip -n -9 -c "${LINUXDIR}/arch/arm/boot/Image" | wc -c | tr -d ' ')"
        fi
    } >"${OUTDIR}/filesizes.txt"
}

report_sections() {
    [ -x "${SIZE_TOOL}" ] || return 0

    {
        for f in \
            "${LINUXDIR}/vmlinux" \
            "${ROOTDIR}/rootfs/bin/busybox" \
            "${ROOTDIR}/toolchain/${TARGET}/lib/libc.so" \
            "${ROOTDIR}/toolchain/${TARGET}/lib/ld-uClibc.so.0"; do
            [ -f "${f}" ] || continue
            echo "== ${f} =="
            if ! "${SIZE_TOOL}" -A "${f}" 2>&1; then
                echo "[size tool skipped unsupported file]"
            fi
            echo
        done
    } >"${OUTDIR}/section-sizes.txt"
}

report_symbols() {
    [ -x "${NM_TOOL}" ] || return 0
    [ -f "${LINUXDIR}/vmlinux" ] || return 0

    "${NM_TOOL}" --numeric-sort -S "${LINUXDIR}/vmlinux" >"${OUTDIR}/symbol-order.txt"
    "${NM_TOOL}" --size-sort -S "${LINUXDIR}/vmlinux" | tail -n 80 >"${OUTDIR}/largest-symbols.txt"
}

report_file_sizes
report_sections
report_symbols
