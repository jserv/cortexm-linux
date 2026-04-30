#!/bin/sh

set -eu

ROOTDIR=$1
LINUXDIR=$2
BOOTWRAPPERDIR=$3
OUTDIR=$4
MODE=${5:-full}

TARGET=arm-uclinuxfdpiceabi
SIZE_TOOL=${ROOTDIR}/toolchain/bin/${TARGET}-size
NM_TOOL=${ROOTDIR}/toolchain/bin/${TARGET}-nm
SUBSYSTEM_ROLLUP=${ROOTDIR}/scripts/subsystem-rollup.py
SUBSYSTEM_BUDGET_CHECK=${ROOTDIR}/scripts/check-subsystem-budget.py
SUBSYSTEM_BUDGET_FILE=${ROOTDIR}/configs/subsystem-budget.txt
BLOAT_O_METER=${LINUXDIR}/scripts/bloat-o-meter

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

# Rotate the prior section table and vmlinux snapshot so the new run can
# diff against the immediately preceding build. The "files" mode is a
# refresh-only call (after the bootwrapper finishes), so it must NOT
# rotate -- vmlinux has not changed since the full report ran moments ago.
rotate_snapshots() {
    if [ -f "${OUTDIR}/section-sizes.txt" ]; then
        mv "${OUTDIR}/section-sizes.txt" "${OUTDIR}/section-sizes.prev"
    fi
    if [ -f "${OUTDIR}/vmlinux.current" ]; then
        mv "${OUTDIR}/vmlinux.current" "${OUTDIR}/vmlinux.prev"
    fi
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
    # Keep the longer 80-row tail for context-rich reviews and split out
    # the headline top-20 the methodology calls for.
    "${NM_TOOL}" --size-sort -S "${LINUXDIR}/vmlinux" | tail -n 80 >"${OUTDIR}/largest-symbols.txt"
    tail -n 20 "${OUTDIR}/largest-symbols.txt" >"${OUTDIR}/top20-symbols.txt"
}

snapshot_vmlinux() {
    [ -f "${LINUXDIR}/vmlinux" ] || return 0
    cp "${LINUXDIR}/vmlinux" "${OUTDIR}/vmlinux.current"
}

# Diff the per-section byte counts produced by `size -A` between the
# previous run and the current one, per artifact. Used to spot the case
# where a config change shrinks .text but inflates .rodata, which a
# total-bytes delta hides.
report_section_delta() {
    if [ ! -f "${OUTDIR}/section-sizes.prev" ] || \
       [ ! -f "${OUTDIR}/section-sizes.txt" ]; then
        rm -f "${OUTDIR}/section-sizes-delta.txt"
        return 0
    fi

    BODY=${OUTDIR}/.section-sizes-delta.body
    awk '
        function parse_record(target,   key) {
            if ($0 ~ /^== /)      { artifact = $2; in_table = 0; return }
            if ($0 ~ /^section /) { in_table = 1; return }
            if ($0 ~ /^Total/)    { in_table = 0; return }
            # Capture any data row, not just sections starting with ".".
            # Kernel sections like __param, __ex_table, __ksymtab carry
            # real bytes; filtering on ^\. silently drops them from the
            # delta. The size column being numeric is the right gate.
            if (in_table && NF >= 2 && $2 ~ /^[0-9]+$/) {
                key = artifact SUBSEP $1
                target[key] = $2
                keys[key] = 1
            }
        }
        FNR == 1 { artifact = ""; in_table = 0 }
        NR == FNR { parse_record(prev); next }
        { parse_record(curr) }
        END {
            for (k in keys) {
                p = (k in prev) ? prev[k] : 0
                c = (k in curr) ? curr[k] : 0
                if (p == c) continue
                split(k, parts, SUBSEP)
                printf "%s\t%s\t%d\t%d\t%+d\n", parts[1], parts[2], p, c, c - p
            }
        }
    ' "${OUTDIR}/section-sizes.prev" "${OUTDIR}/section-sizes.txt" |
        sort -k1,1 -k2,2 >"${BODY}"

    {
        printf 'artifact\tsection\tprev\tcurr\tdelta\n'
        cat "${BODY}"
    } >"${OUTDIR}/section-sizes-delta.txt"
    rm -f "${BODY}"
}

# Run scripts/bloat-o-meter against the previous build (auto-rotated) and,
# if the user has manually pinned a baseline, against that too. Both diffs
# are non-fatal: bloat-o-meter requires unstripped artifacts, but the
# operator may prune the snapshots between runs.
report_bloat_o_meter() {
    if [ ! -x "${BLOAT_O_METER}" ] || [ ! -f "${OUTDIR}/vmlinux.current" ]; then
        rm -f "${OUTDIR}/bloat-o-meter.txt" \
            "${OUTDIR}/bloat-o-meter-vs-baseline.txt"
        return 0
    fi

    # bloat-o-meter shells out to `${prefix}nm` directly, so it needs the
    # cross toolchain on PATH. build.sh exports PATH already; running this
    # script standalone does not. Run in a subshell so the modified PATH
    # does not leak into report_subsystem_rollup or anything downstream.
    (
        PATH=${ROOTDIR}/toolchain/bin:${PATH}
        export PATH

        if [ -f "${OUTDIR}/vmlinux.prev" ]; then
            "${BLOAT_O_METER}" -p "${TARGET}-" \
                "${OUTDIR}/vmlinux.prev" "${OUTDIR}/vmlinux.current" \
                >"${OUTDIR}/bloat-o-meter.txt" 2>&1 || true
        else
            rm -f "${OUTDIR}/bloat-o-meter.txt"
        fi

        if [ -f "${OUTDIR}/vmlinux.baseline" ]; then
            "${BLOAT_O_METER}" -p "${TARGET}-" \
                "${OUTDIR}/vmlinux.baseline" "${OUTDIR}/vmlinux.current" \
                >"${OUTDIR}/bloat-o-meter-vs-baseline.txt" 2>&1 || true
        else
            rm -f "${OUTDIR}/bloat-o-meter-vs-baseline.txt"
        fi
    )
}

# LTO-aware subsystem rollup. The Python tool fails with exit code 2
# when DWARF is missing (production builds, CONFIG_DEBUG_INFO_NONE=y);
# the shell layer treats that as a documented skip rather than a build
# failure. The diagnostic build (KERNEL_DEBUG_INFO=reduced) ships
# enough DWARF for addr2line to attribute symbols, and the rollup
# emits subsystem-rollup.txt + .svg + .html under OUTDIR.
report_subsystem_rollup() {
    # Use -r, not -x: the script runs via `python3`, so the +x bit
    # is not part of the runtime contract. A checkout that preserves
    # contents but drops the execute bit (zip extraction, some rsync
    # flags) would otherwise silently disable the rollup.
    if [ ! -r "${SUBSYSTEM_ROLLUP}" ] || [ ! -f "${OUTDIR}/vmlinux.current" ]; then
        rm -f "${OUTDIR}/subsystem-rollup.txt" \
            "${OUTDIR}/subsystem-rollup.err" \
            "${OUTDIR}/subsystem-rollup-bars.svg" \
            "${OUTDIR}/subsystem-rollup-tree.html" \
            "${OUTDIR}/subsystem-rollup-deep.txt" \
            "${OUTDIR}/subsystem-rollup-deep.html"
        return 0
    fi

    # --deep kernel --deep lib drives the per-bucket source-file
    # breakdown the methodology refers to. The two big parents account
    # for ~45% of resident .text after the RD_*-cleanup work, and the
    # depth-2 view (kernel/sched, lib/zstd, ...) is what surfaces
    # actionable single-knob disables. Add more --deep flags here when
    # another parent bucket grows large enough to warrant drilling.
    if python3 "${SUBSYSTEM_ROLLUP}" \
            --vmlinux "${OUTDIR}/vmlinux.current" \
            --linux-tree "${LINUXDIR}" \
            --toolchain-bin "${ROOTDIR}/toolchain/bin" \
            --output "${OUTDIR}/subsystem-rollup.txt" \
            --deep kernel --deep lib \
            2>"${OUTDIR}/subsystem-rollup.err"; then
        rm -f "${OUTDIR}/subsystem-rollup.err"
    else
        # Failure modes:
        #   exit 1 -- input/tooling problem (loud); leave .err for triage
        #   exit 2 -- DWARF missing (production build); expected, drop
        #             the stale outputs but keep .err so the operator
        #             can confirm the cause if it surprises them.
        rm -f "${OUTDIR}/subsystem-rollup.txt" \
            "${OUTDIR}/subsystem-rollup-bars.svg" \
            "${OUTDIR}/subsystem-rollup-tree.html" \
            "${OUTDIR}/subsystem-rollup-deep.txt" \
            "${OUTDIR}/subsystem-rollup-deep.html"
    fi
}

# Compare the subsystem rollup against configs/subsystem-budget.txt.
# Warn-only: a breach prints to stderr and writes a status file but
# does not abort the build. The total-bytes regression gate stays the
# coarse gate; this layer answers WHICH bucket regressed.
report_subsystem_budget() {
    if [ ! -r "${SUBSYSTEM_BUDGET_CHECK}" ] \
        || [ ! -r "${SUBSYSTEM_BUDGET_FILE}" ] \
        || [ ! -f "${OUTDIR}/subsystem-rollup.txt" ]; then
        rm -f "${OUTDIR}/subsystem-budget.txt"
        return 0
    fi

    python3 "${SUBSYSTEM_BUDGET_CHECK}" \
        --rollup "${OUTDIR}/subsystem-rollup.txt" \
        --budget "${SUBSYSTEM_BUDGET_FILE}" \
        --output "${OUTDIR}/subsystem-budget.txt" || true
}

case "${MODE}" in
files)
    report_file_sizes
    ;;
full)
    rotate_snapshots
    report_file_sizes
    report_sections
    report_symbols
    snapshot_vmlinux
    report_section_delta
    report_bloat_o_meter
    report_subsystem_rollup
    report_subsystem_budget
    ;;
*)
    echo "ERROR: unknown mode '${MODE}' (expected: full | files)" >&2
    exit 1
    ;;
esac
