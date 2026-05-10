#!/bin/sh

# Cross-build a minimal Linux system for ARM Cortex-M4 (MPS2-AN386)
#
# This script produces a self-contained, bootable Linux image targeting the Arm
# MPS2-AN386 FPGA platform (Cortex-M4, no MMU, Thumb-2 only).
# It builds a first-pass GCC cross-compiler (C only), a shared FDPIC libc,
# BusyBox for a minimal userspace, and a Linux kernel with embedded initramfs.

set -e

# shellcheck disable=SC2329

CPU=arm
TARGET=arm-uclinuxfdpiceabi
FLAVOR=cortexm-fdpic

BINUTILS_VERSION=2.46.0
GCC_VERSION=16.1.0
UCLIBC_NG_VERSION=1.0.57
MUSL_VERSION=1.2.5
BUSYBOX_VERSION=1.37.0
LINUX_VERSION=7.0

BINUTILS_URL=https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz
GCC_URL=https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
# GitHub auto-archive. The canonical mirror at downloads.uclibc-ng.org
# has been observed returning HTTP 522 (Cloudflare-to-origin failure)
# for extended windows; GitHub's tag-based source archive is permanent
# and byte-equivalent to the upstream tarball content (same 5,527-file
# tree, only the top-level directory uses lowercase 'u' which we rename
# back below to keep configs/uClibc-ng-*.config and the rest of this
# script unchanged).
UCLIBC_NG_URL=https://github.com/wbx-github/uclibc-ng/archive/refs/tags/v${UCLIBC_NG_VERSION}.tar.gz
MUSL_URL=https://musl.libc.org/releases/musl-${MUSL_VERSION}.tar.gz
BUSYBOX_URL=https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
LINUX_URL=https://www.kernel.org/pub/linux/kernel/v7.x/linux-${LINUX_VERSION}.tar.xz

ROOTDIR=$(cd "$(dirname "$0")" >/dev/null && pwd)
cd "${ROOTDIR}"
TOOLCHAIN=${ROOTDIR}/toolchain
ROOTFS=${ROOTDIR}/rootfs
LOGDIR=${ROOTDIR}/logs
STATE_DIR=${ROOTDIR}/.build-state
QUIET=${QUIET:-0}
LOG_TAIL_LINES=${LOG_TAIL_LINES:-200}
KERNEL_SYSCALL_TABLE=${KERNEL_SYSCALL_TABLE:-}
KERNEL_CONFIG_FRAGMENT=${KERNEL_CONFIG_FRAGMENT:-}
KERNEL_LTO_MODE=${KERNEL_LTO_MODE:-none}
# DWARF policy. The default ('none') matches the production image:
# CONFIG_DEBUG_INFO_NONE=y, addr2line cannot resolve any symbol, and
# scripts/subsystem-rollup.py exits with the documented "DWARF
# missing" code. Set KERNEL_DEBUG_INFO=reduced to ship REDUCED DWARF
# so the diagnostic rollup can attribute symbols to source dirs. The
# deployed Image is stripped of debug sections before bootwrapper
# packing, so this knob only changes vmlinux artifacts and link time.
KERNEL_DEBUG_INFO=${KERNEL_DEBUG_INFO:-none}
KERNEL_REPORT_DIR=${KERNEL_REPORT_DIR:-${ROOTDIR}/profiles/kernel-pgo}
PGO_WORKLOAD_FILE=${PGO_WORKLOAD_FILE:-${ROOTDIR}/configs/pgo-workload.txt}
PGO_BASE_CONFIG_FRAGMENT=${PGO_BASE_CONFIG_FRAGMENT:-${ROOTDIR}/configs/kernel-pgo-prune.config}
# Extra GCC-kernel-LTO link flags for controlled experiments. The local
# CONFIG_LTO_GCC patch forwards this variable only at final link time.
# Keep the default empty; production defaults to no kernel LTO because
# the current pruned image is smaller without it.
KERNEL_LTO_EXTRA_CFLAGS=${KERNEL_LTO_EXTRA_CFLAGS:-}
LIBC_IMPL_EXPLICIT=0
if [ "${LIBC_IMPL+x}" = x ]; then
    LIBC_IMPL_EXPLICIT=1
fi
EXPERIMENTAL_MUSL_DEFAULT=${EXPERIMENTAL_MUSL_DEFAULT:-0}
if [ "${LIBC_IMPL_EXPLICIT}" = "0" ]; then
    if [ "${EXPERIMENTAL_MUSL_DEFAULT}" = "1" ]; then
        LIBC_IMPL=musl
    else
        LIBC_IMPL=uclibc-ng
    fi
fi
# Closest musl-side matches for the size-oriented uClibc-ng config:
# simple allocator, section-friendly codegen, GNU hash-only dynamic
# linker metadata, no legacy time32 compatibility shims, and a
# BusyBox-only source set that drops unused subsystems plus most of
# musl's locale/multibyte/wide-char machinery in favor of tiny
# ASCII/C-locale replacements.
MUSL_MALLOC_DIR=${MUSL_MALLOC_DIR:-oldmalloc}
MUSL_DISABLE_COMPAT_TIME32=${MUSL_DISABLE_COMPAT_TIME32:-1}
# GCC 15 on this target shrinks musl materially with -Oz and
# -fno-semantic-interposition. The latter is safe for this BusyBox-only
# shared-libc profile and reduces internal PIC call overhead/size by
# letting the compiler assume musl's own global definitions are final.
MUSL_EXTRA_CFLAGS=${MUSL_EXTRA_CFLAGS:--Oz -fomit-frame-pointer -fno-unwind-tables -fno-asynchronous-unwind-tables -ffunction-sections -fdata-sections -fno-semantic-interposition}
MUSL_EXTRA_LDFLAGS=${MUSL_EXTRA_LDFLAGS:--Wl,--gc-sections -Wl,--hash-style=gnu}
MUSL_BUSYBOX_ONLY_NO_RUNTIME_DL=${MUSL_BUSYBOX_ONLY_NO_RUNTIME_DL:-1}
MUSL_BUSYBOX_ONLY_NO_TZFILE=${MUSL_BUSYBOX_ONLY_NO_TZFILE:-1}
# Experimental: generate a BusyBox-derived musl export map and relink
# libc against it. This is currently useful as a size-analysis tool, but
# the pruned-export FDPIC runtime is not yet proven bootable enough to be
# the default build path on this target.
MUSL_BUSYBOX_ONLY_EXPORT_MAP=${MUSL_BUSYBOX_ONLY_EXPORT_MAP:-0}
MUSL_BUSYBOX_EXPORT_MAP_PATH=${MUSL_BUSYBOX_EXPORT_MAP_PATH:-${STATE_DIR}/musl-busybox-exports.map}
MUSL_BUSYBOX_EXPORT_MAP_MAX_PASSES=${MUSL_BUSYBOX_EXPORT_MAP_MAX_PASSES:-2}
MUSL_PRUNE_UNUSED_MATH=${MUSL_PRUNE_UNUSED_MATH:-1}
MUSL_KEEP_MATH_SRCS=${MUSL_KEEP_MATH_SRCS:-copysign.c copysignl.c fabs.c fabsl.c fmod.c fmodl.c frexp.c frexpl.c scalbn.c scalbnf.c scalbnl.c}
MUSL_OMIT_SRCS_GLOBS=${MUSL_OMIT_SRCS_GLOBS:-./src/aio/*.c ./src/complex/*.c ./src/crypt/*.c ./src/mq/*.c ./src/locale/*.c ./src/multibyte/*.c ./src/ctype/isw*.c ./src/ctype/tow*.c ./src/ctype/wc*.c ./src/misc/wordexp.c ./src/misc/nftw.c ./src/legacy/ftw.c ./src/time/__map_file.c ./src/regex/regcomp.c ./src/regex/regerror.c ./src/regex/regexec.c ./src/regex/tre-mem.c ./src/stdlib/atof.c ./src/stdlib/strtod.c ./src/stdlib/wcstod.c}
BUSYBOX_ONLY_NO_PRINTF_FLOAT=${BUSYBOX_ONLY_NO_PRINTF_FLOAT:-1}

NCPU=$(grep -c processor /proc/cpuinfo 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
MAKE_JOBS=${MAKE_JOBS:-${NCPU}}

PATH=${TOOLCHAIN}/bin:${PATH}

mkdir -p "${LOGDIR}" "${STATE_DIR}"

# SHA256 checksums for downloaded source packages.
# Update these when bumping component versions.
# To populate missing checksums: sha256sum downloads/*
CHECKSUM_binutils="binutils-${BINUTILS_VERSION}.tar.xz=d75a94f4d73e7a4086f7513e67e439e8fcdcbb726ffe63f4661744e6256b2cf2"
CHECKSUM_gcc="gcc-${GCC_VERSION}.tar.xz=50efb4d94c3397aff3b0d61a5abd748b4dd31d9d3f2ab7be05b171d36a510f79"
CHECKSUM_uclibc="v${UCLIBC_NG_VERSION}.tar.gz=f49704e0affc75fde9ee4e870c20e53c1d807eca2a4683377b359b8361e84312"
CHECKSUM_musl="musl-${MUSL_VERSION}.tar.gz=a9a118bbe84d8764da0ea0d28b3ab3fae8477fc7e4085d90102b8596fc7c75e4"
CHECKSUM_busybox="busybox-${BUSYBOX_VERSION}.tar.bz2=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4"
CHECKSUM_linux="linux-${LINUX_VERSION}.tar.xz=bb7f6d80b387c757b7d14bb93028fcb90f793c5c0d367736ee815a100b3891f0"

assert_supported_libc() {
    case "${LIBC_IMPL}" in
    uclibc-ng)
        return 0
        ;;
    musl)
        return 0
        ;;
    *)
        echo "ERROR: unsupported LIBC_IMPL='${LIBC_IMPL}' (expected 'uclibc-ng' or 'musl')" >&2
        exit 1
        ;;
    esac
}

libc_config_glob() {
    case "${LIBC_IMPL}" in
    uclibc-ng) echo "configs/uClibc-ng-*" ;;
    musl) echo "configs/musl-*" ;;
    *)
        echo "ERROR: unsupported LIBC_IMPL='${LIBC_IMPL}' (expected 'uclibc-ng' or 'musl')" >&2
        exit 1
        ;;
    esac
}

toolchain_fingerprint() {
    LIBC_CONFIGS=$(libc_config_glob)
    {
        sha256sum build.sh
        sha256sum patches/0001-* 2>/dev/null || true
        sha256sum ${LIBC_CONFIGS} 2>/dev/null || true
        printf 'EXPERIMENTAL_MUSL_DEFAULT=%s\n' "${EXPERIMENTAL_MUSL_DEFAULT}"
        printf 'LIBC_IMPL=%s\n' "${LIBC_IMPL}"
        if [ "${LIBC_IMPL}" = "musl" ]; then
            sha256sum \
                patches/0024-musl-* \
                patches/0025-musl-* \
                patches/0026-musl-* \
                patches/0027-musl-* \
                patches/0028-musl-* \
                patches/0029-musl-* \
                patches/0030-musl-* \
                patches/0031-musl-* \
                patches/0033-musl-* \
                patches/0034-musl-* \
                patches/0035-musl-* \
                patches/0036-musl-* \
                patches/0037-musl-* \
                patches/0038-musl-* \
                patches/0039-musl-* \
                patches/0040-musl-* \
                support/arm-fdpic-crtreloc.c \
                2>/dev/null || true
            printf 'MUSL_MALLOC_DIR=%s\n' "${MUSL_MALLOC_DIR}"
            printf 'MUSL_DISABLE_COMPAT_TIME32=%s\n' "${MUSL_DISABLE_COMPAT_TIME32}"
            printf 'MUSL_EXTRA_CFLAGS=%s\n' "${MUSL_EXTRA_CFLAGS}"
            printf 'MUSL_EXTRA_LDFLAGS=%s\n' "${MUSL_EXTRA_LDFLAGS}"
            printf 'MUSL_BUSYBOX_ONLY_NO_RUNTIME_DL=%s\n' "${MUSL_BUSYBOX_ONLY_NO_RUNTIME_DL}"
            printf 'MUSL_BUSYBOX_ONLY_NO_TZFILE=%s\n' "${MUSL_BUSYBOX_ONLY_NO_TZFILE}"
            printf 'MUSL_BUSYBOX_ONLY_EXPORT_MAP=%s\n' "${MUSL_BUSYBOX_ONLY_EXPORT_MAP}"
            printf 'MUSL_PRUNE_UNUSED_MATH=%s\n' "${MUSL_PRUNE_UNUSED_MATH}"
            printf 'MUSL_KEEP_MATH_SRCS=%s\n' "${MUSL_KEEP_MATH_SRCS}"
            printf 'MUSL_OMIT_SRCS_GLOBS=%s\n' "${MUSL_OMIT_SRCS_GLOBS}"
            printf 'BUSYBOX_ONLY_NO_PRINTF_FLOAT=%s\n' "${BUSYBOX_ONLY_NO_PRINTF_FLOAT}"
            if [ -f "${MUSL_BUSYBOX_EXPORT_MAP_PATH}" ]; then
                sha256sum "${MUSL_BUSYBOX_EXPORT_MAP_PATH}"
            fi
        fi
    } | sha256sum | cut -d' ' -f1
}

image_fingerprint() {
    {
        printf '%s\n' "$1"
        printf 'KERNEL_LTO_MODE=%s\n' "${KERNEL_LTO_MODE}"
        printf 'KERNEL_LTO_EXTRA_CFLAGS=%s\n' "${KERNEL_LTO_EXTRA_CFLAGS}"
        printf 'KERNEL_SYSCALL_TABLE=%s\n' "${KERNEL_SYSCALL_TABLE}"
        printf 'KERNEL_CONFIG_FRAGMENT=%s\n' "${KERNEL_CONFIG_FRAGMENT}"
        printf 'KERNEL_DEBUG_INFO=%s\n' "${KERNEL_DEBUG_INFO}"
        if [ -n "${KERNEL_SYSCALL_TABLE}" ] && [ -f "${KERNEL_SYSCALL_TABLE}" ]; then
            sha256sum "${KERNEL_SYSCALL_TABLE}"
        fi
        if [ -n "${KERNEL_CONFIG_FRAGMENT}" ] && [ -f "${KERNEL_CONFIG_FRAGMENT}" ]; then
            sha256sum "${KERNEL_CONFIG_FRAGMENT}"
        fi
        printf 'PGO_WORKLOAD_FILE=%s\n' "${PGO_WORKLOAD_FILE}"
        if [ -f "${PGO_WORKLOAD_FILE}" ]; then
            sha256sum "${PGO_WORKLOAD_FILE}"
        fi
        sha256sum build.sh
        find configs patches tools scripts -type f -print0 | sort -z | xargs -0 sha256sum
    } | sha256sum | cut -d' ' -f1
}

refresh_build_fingerprints() {
    TOOLCHAIN_FP=$(toolchain_fingerprint)
    IMAGE_FP=$(image_fingerprint "${TOOLCHAIN_FP}")
}

refresh_build_fingerprints

stage_fingerprint() {
    case "$1" in
    binutils|gcc|linux_headers|libc)
        printf '%s' "${TOOLCHAIN_FP}" ;;
    *)
        printf '%s' "${IMAGE_FP}" ;;
    esac
}

run_logged() {
    STEP=$1
    shift

    if [ "${QUIET}" = "1" ]; then
        echo "BUILD: ${CURRENT_STAGE}: ${STEP}"
        if "$@" >>"${CURRENT_LOG}" 2>&1; then
            return 0
        else
            STATUS=$?
        fi

        echo "ERROR: ${CURRENT_STAGE} failed during ${STEP}" >&2
        echo "ERROR: showing the last ${LOG_TAIL_LINES} lines from ${CURRENT_LOG}" >&2
        tail -n "${LOG_TAIL_LINES}" "${CURRENT_LOG}" >&2 || cat "${CURRENT_LOG}" >&2
        exit "${STATUS}"
    fi

    "$@"
}

extract_source() {
    ARCHIVE=$1
    SRCDIR=$2
    shift 2

    if [ -d "${SRCDIR}" ]; then
        echo "BUILD: reusing ${SRCDIR}"
        return 0
    fi

    run_logged "extract ${SRCDIR}" tar "$@" "downloads/${ARCHIVE}"
}

stage_stamp_file() {
    echo "${STATE_DIR}/$1.stamp"
}

stage_stamp_matches() {
    STAMP_FILE=$(stage_stamp_file "$1")
    [ -f "${STAMP_FILE}" ] && grep -qx "$(stage_fingerprint "$1")" "${STAMP_FILE}"
}

mark_stage_complete() {
    printf '%s\n' "$(stage_fingerprint "$1")" >"$(stage_stamp_file "$1")"
}

stage_verify_binutils() {
    [ -x "${TOOLCHAIN}/bin/${TARGET}-ld" ]
}

stage_verify_gcc() {
    [ -x "${TOOLCHAIN}/bin/${TARGET}-gcc" ]
}

stage_verify_linux_headers() {
    [ -f "${TOOLCHAIN}/${TARGET}/include/linux/types.h" ]
}

stage_verify_libc() {
    [ -f "${TOOLCHAIN}/${TARGET}/lib/libc.a" ] || [ -f "${TOOLCHAIN}/${TARGET}/lib/libc.so" ]
}

stage_verify_busybox() {
    [ -x "${ROOTFS}/bin/busybox" ]
}

stage_verify_finalize_rootfs() {
    [ -x "${ROOTFS}/etc/rc" ] && [ -L "${ROOTFS}/init" ] || return 1

    # FDPIC rootfs must contain the dynamic loader and shared libraries
    # that busybox was linked against.
    READELF=${TOOLCHAIN}/bin/${TARGET}-readelf
    [ -x "${READELF}" ] || return 0

    INTERP=$(LC_ALL=C "${READELF}" -l "${ROOTFS}/bin/busybox" 2>/dev/null | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
    [ -z "${INTERP}" ] && return 0
    [ -e "${ROOTFS}${INTERP}" ] || [ -L "${ROOTFS}${INTERP}" ] || return 1

    _needed_libs=$(LC_ALL=C "${READELF}" -d "${ROOTFS}/bin/busybox" 2>/dev/null |
        sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
    for needed in ${_needed_libs}; do
        [ -e "${ROOTFS}/lib/${needed}" ] || [ -L "${ROOTFS}/lib/${needed}" ] ||
            [ -e "${ROOTFS}/usr/lib/${needed}" ] || [ -L "${ROOTFS}/usr/lib/${needed}" ] || return 1
    done
}

stage_verify_linux() {
    [ -f "${ROOTDIR}/linux-${LINUX_VERSION}/arch/arm/boot/Image" ]
}

stage_verify_bootwrapper() {
    [ -f "${ROOTDIR}/bootwrapper/linux.axf" ]
}

stage_verify_kernel_pgo_cycle() {
    [ -f "${KERNEL_REPORT_DIR}/cycle/final/selected-candidate.txt" ] &&
        [ -f "${KERNEL_REPORT_DIR}/cycle/configs/pgo-kernel.config" ] &&
        [ -f "${ROOTDIR}/bootwrapper/linux.axf" ]
}

stage_verify_kernel_syscall_prune_cycle() {
    [ -f "${KERNEL_REPORT_DIR}/syscall-prune-cycle/final/selected-candidate.txt" ] &&
        [ -f "${KERNEL_REPORT_DIR}/syscall-prune-cycle/configs/syscall-prune.tbl" ] &&
        [ -f "${ROOTDIR}/bootwrapper/linux.axf" ]
}

stage_verify_kernel_lto_sweep() {
    [ -f "${KERNEL_REPORT_DIR}/lto-sweep/final/summary.txt" ] &&
        [ -f "${KERNEL_REPORT_DIR}/lto-sweep/final/candidate-matrix.txt" ]
}

stage_is_current() {
    STAGE=$1
    VERIFY_FUNC=stage_verify_${STAGE}

    if ! stage_stamp_matches "${STAGE}"; then
        return 1
    fi

    "${VERIFY_FUNC}"
}

# Remove stale source/build trees before re-running a stage so that
# cached artifacts (config.status, already-applied patches) cannot
# silently carry over from a previous fingerprint.
stage_clean() {
    case "$1" in
    binutils)       rm -rf "binutils-${BINUTILS_VERSION}" ;;
    gcc)            rm -rf "gcc-${GCC_VERSION}" ;;
    linux_headers)  rm -rf "linux-${LINUX_VERSION}" ;;  # shared with linux; both extract fresh
    libc)           rm -rf "uClibc-ng-${UCLIBC_NG_VERSION}" "musl-${MUSL_VERSION}" ;;
    busybox)        rm -rf "busybox-${BUSYBOX_VERSION}" "${ROOTFS}" ;;
    finalize_rootfs) ;; # idempotent; overwrites its outputs
    linux)          rm -rf "linux-${LINUX_VERSION}" ;;
    bootwrapper)    rm -rf bootwrapper ;;
    kernel_pgo_cycle) rm -rf "${KERNEL_REPORT_DIR}/cycle" ;;
    kernel_syscall_prune_cycle) rm -rf "${KERNEL_REPORT_DIR}/syscall-prune-cycle" ;;
    kernel_lto_sweep) rm -rf "${KERNEL_REPORT_DIR}/lto-sweep" ;;
    esac
}

verify_checksum() {
    FILE=$1
    EXPECTED=$2
    if [ -z "${EXPECTED}" ]; then
        return 0
    fi
    ACTUAL=$(sha256sum "downloads/${FILE}" | cut -d' ' -f1)
    if [ "${ACTUAL}" != "${EXPECTED}" ]; then
        echo "ERROR: checksum mismatch for ${FILE}"
        echo "  expected: ${EXPECTED}"
        echo "  got:      ${ACTUAL}"
        exit 1
    fi
}

fetch_file() {
    URL=$1
    CHECKSUM_VAR=$2
    PACKAGE=$(basename "${URL}")
    mkdir -p downloads
    if [ ! -f "downloads/${PACKAGE}" ]; then
        echo "BUILD: fetching ${PACKAGE}"
        if [ "${QUIET}" = "1" ]; then
            wget -q -P downloads "${URL}"
        else
            wget -P downloads "${URL}"
        fi
    fi
    EXPECTED=""
    if [ -n "${CHECKSUM_VAR}" ]; then
        EXPECTED=$(echo "${CHECKSUM_VAR}" | cut -d= -f2)
    fi
    verify_checksum "${PACKAGE}" "${EXPECTED}"
}

patch_already_applied() {
    PATCH_NAME=$(basename "$1")

    case "${PATCH_NAME}" in
    0002-*)
        grep -q "config NET_SMALL" init/Kconfig &&
            grep -q "CONFIG_NET_SMALL" include/net/protocol.h &&
            grep -q "CONFIG_NET_SMALL" net/sunrpc/cache.c &&
            grep -q "CONFIG_NET_SMALL" net/unix/af_unix.h
        ;;
    0003-*)
        grep -q "config MAX_SWAPFILES_SHIFT" init/Kconfig &&
            grep -q "CONFIG_MAX_SWAPFILES_SHIFT" include/linux/swap.h &&
            grep -q "MAX_SWAPFILES_SHIFT == 0" include/linux/swapops.h
        ;;
    0004-*)
        grep -q "config CRC32_TABLES" init/Kconfig &&
            grep -q "#ifndef CONFIG_CRC32_TABLES" lib/crc/crc32-main.c
        ;;
    0005-*)
        grep -q "config PROC_STRIPPED" fs/proc/Kconfig &&
            grep -q "CONFIG_PROC_STRIPPED" fs/locks.c
        ;;
    0006-*)
        grep -q "config LTO_GCC" arch/Kconfig &&
            [ -f scripts/Makefile.lto ]
        ;;
    0010-*)
        # Check for the unique symbols introduced by the patch rather
        # than literal `select` lines, which are whitespace-fragile.
        grep -q "config UNWINDER_NONE" arch/arm/Kconfig.debug &&
            grep -Eq "^[[:space:]]*select[[:space:]]+ARM_UNWIND[[:space:]]+if[[:space:]]+!UNWINDER_NONE[[:space:]]*$" arch/arm/Kconfig
        ;;
    *)
        return 1
        ;;
    esac
}

apply_patch_once() {
    PATCH_FILE=$1
    PATCH_NAME=$(basename "${PATCH_FILE}")
    STAMP_DIR=.applied-patches
    STAMP_FILE=${STAMP_DIR}/${PATCH_NAME}

    mkdir -p "${STAMP_DIR}"
    if [ -f "${STAMP_FILE}" ] && patch_already_applied "${PATCH_FILE}"; then
        echo "BUILD: skipping ${PATCH_NAME} (stamp verified)"
        return 0
    fi

    if patch -p1 -N --dry-run <"${PATCH_FILE}" >/dev/null 2>&1; then
        echo "BUILD: applying ${PATCH_NAME}"
        patch -p1 -N <"${PATCH_FILE}"
        touch "${STAMP_FILE}"
    elif patch_already_applied "${PATCH_FILE}"; then
        echo "BUILD: skipping ${PATCH_NAME} (already applied)"
        touch "${STAMP_FILE}"
    elif patch -p1 -R --dry-run <"${PATCH_FILE}" >/dev/null 2>&1; then
        echo "BUILD: skipping ${PATCH_NAME} (already applied)"
        touch "${STAMP_FILE}"
    else
        echo "ERROR: failed to apply ${PATCH_NAME}"
        exit 1
    fi
}

build_binutils() {
    echo "BUILD: building binutils-${BINUTILS_VERSION}"
    fetch_file "${BINUTILS_URL}" "${CHECKSUM_binutils}"

    extract_source "binutils-${BINUTILS_VERSION}.tar.xz" "binutils-${BINUTILS_VERSION}" -xJf
    cd binutils-${BINUTILS_VERSION}

    if patch -p1 -R --dry-run <../patches/0001-arm-Do-not-insert-stubs-needing-Arm-code-on-Thumb-on.patch >/dev/null 2>&1; then
        run_logged "apply thumb-only binutils patch" patch -p1 -R <../patches/0001-arm-Do-not-insert-stubs-needing-Arm-code-on-Thumb-on.patch
    fi

    run_logged "configure" ./configure --target=${TARGET} --prefix=${TOOLCHAIN}
    run_logged "build" make -j${MAKE_JOBS}
    run_logged "install" make install
    cd ../
}

build_gcc() {
    echo "BUILD: building gcc-${GCC_VERSION}"
    fetch_file "${GCC_URL}" "${CHECKSUM_gcc}"

    extract_source "gcc-${GCC_VERSION}.tar.xz" "gcc-${GCC_VERSION}" -xJf
    cd gcc-${GCC_VERSION}
    run_logged "download gcc prerequisites" contrib/download_prerequisites
    mkdir -p ${TARGET}
    cd ${TARGET}
    run_logged "configure" ../configure --target=${TARGET} \
        --prefix=${TOOLCHAIN} \
        --disable-multilib \
        --disable-shared \
        --disable-libssp \
        --disable-threads \
        --disable-libmudflap \
        --disable-libgomp \
        --disable-libatomic \
        --disable-libsanitizer \
        --disable-libquadmath \
        --disable-libmpx \
        --without-headers \
        --with-system-zlib \
        --with-arch=armv7e-m \
        --with-mode=thumb \
        --with-float=soft \
        --enable-languages=c
    run_logged "build" make -j${MAKE_JOBS}
    run_logged "install" make install
    cd ../..
}

build_linux_headers() {
    echo "BUILD: building linux-${LINUX_VERSION} headers"
    fetch_file "${LINUX_URL}" "${CHECKSUM_linux}"

    extract_source "linux-${LINUX_VERSION}.tar.xz" "linux-${LINUX_VERSION}" -xJf
    cd linux-${LINUX_VERSION}
    run_logged "defconfig" make ARCH=${CPU} defconfig
    run_logged "headers_install" make ARCH=${CPU} headers_install
    mkdir -p "${TOOLCHAIN}/${TARGET}"
    rm -rf "${TOOLCHAIN}/${TARGET}/include"
    cp -a usr/include ${TOOLCHAIN}/${TARGET}/
    cd ../
}

build_uclibc_ng() {
    echo "BUILD: building uClibc-${UCLIBC_NG_VERSION}"
    fetch_file "${UCLIBC_NG_URL}" "${CHECKSUM_uclibc}"

    extract_source "v${UCLIBC_NG_VERSION}.tar.gz" "uClibc-ng-${UCLIBC_NG_VERSION}" -xzf
    # GitHub source archive unpacks to lowercase 'uclibc-ng-X.Y.Z'; rename
    # to the canonical-tarball capitalization so configs/ and stage_clean
    # references stay valid. extract_source's own "reuse" check above
    # already short-circuits on subsequent runs once the rename has taken.
    [ -d "uClibc-ng-${UCLIBC_NG_VERSION}" ] || mv "uclibc-ng-${UCLIBC_NG_VERSION}" "uClibc-ng-${UCLIBC_NG_VERSION}"
    cp configs/uClibc-ng-${UCLIBC_NG_VERSION}-${FLAVOR}.config uClibc-ng-${UCLIBC_NG_VERSION}/.config
    cd uClibc-ng-${UCLIBC_NG_VERSION}

    # FDPIC ldso refresh: descriptor allocator, eager binding, XIP policy
    # plus 0022 follow-up that broadens the writable-text gate and
    # replaces additive end-address checks with subtraction-based bounds.
    for p in ../patches/0021-ldso-arm-fdpic-*.patch ../patches/0022-ldso-arm-fdpic-*.patch; do
        [ -f "${p}" ] || continue
        apply_patch_once "${p}"
    done

    TOOLCHAIN_ESCAPED=$(echo ${TOOLCHAIN}/${TARGET} | sed 's/\//\\\//g')
    sed -i "s/^KERNEL_HEADERS=.*\$/KERNEL_HEADERS=\"${TOOLCHAIN_ESCAPED}\/include\"/" .config
    # Use a target-relative runtime prefix so PT_INTERP inside built ELFs
    # references /lib/ld-uClibc.so.0 instead of the host toolchain path.
    # Keep development files at the sysroot root because GCC is not
    # configured with an extra /usr sysroot suffix for target headers/crt.
    sed -i 's/^RUNTIME_PREFIX=.*$/RUNTIME_PREFIX="\/"/' .config
    sed -i 's/^DEVEL_PREFIX=.*$/DEVEL_PREFIX="\/"/' .config

    run_logged "oldconfig" sh -c "make oldconfig CROSS=${TARGET}- TARGET_ARCH=${CPU} </dev/null"
    run_logged "build and install" make -j${MAKE_JOBS} install CROSS=${TARGET}- TARGET_ARCH=${CPU} \
        DESTDIR="${TOOLCHAIN}/${TARGET}"
    cd ../
}

build_musl() {
    echo "BUILD: building musl-${MUSL_VERSION}"
    fetch_file "${MUSL_URL}" "${CHECKSUM_musl}"

    extract_source "musl-${MUSL_VERSION}.tar.gz" "musl-${MUSL_VERSION}" -xzf
    cd musl-${MUSL_VERSION}

    apply_patch_once ../patches/0024-musl-arm-fdpic-dynamic-linking.patch
    apply_patch_once ../patches/0025-musl-tiny-iconv.patch
    apply_patch_once ../patches/0026-musl-allow-omitting-source-globs.patch
    apply_patch_once ../patches/0027-musl-busybox-only-c-locale-and-ascii-multibyte.patch
    apply_patch_once ../patches/0028-musl-busybox-only-c-locale.patch
    apply_patch_once ../patches/0029-musl-busybox-only-disable-runtime-dlfcn.patch
    apply_patch_once ../patches/0030-musl-busybox-only-minimal-dlfcn-stubs.patch
    apply_patch_once ../patches/0031-musl-busybox-only-no-tzfile.patch
    apply_patch_once ../patches/0033-musl-fdpic-dlstart-direct-dls2.patch
    apply_patch_once ../patches/0034-musl-arm-fdpic-soft-tp.patch
    apply_patch_once ../patches/0035-musl-fdpic-local-funcdesc-got.patch
    apply_patch_once ../patches/0036-musl-fdpic-dlstart-handle-rel.patch
    apply_patch_once ../patches/0037-musl-fdpic-init-array-fpaddr.patch
    apply_patch_once ../patches/0038-musl-fdpic-runtime-relative-laddr.patch
    apply_patch_once ../patches/0039-musl-arm-fdpic-xip-aware-loadmap-and-textrel.patch
    apply_patch_once ../patches/0040-musl-fdpic-laddr-idempotent.patch
    # musl's ARM TLS fast paths assume CP15/kuser helper conventions that
    # do not hold on this Cortex-M FDPIC target. Force direct TP reads
    # through the working Thumb syscall ABI instead of function-pointer
    # or CP15-based helpers.
    cat > arch/arm/pthread_arch.h <<'EOF'
#ifdef __FDPIC__
static inline uintptr_t __get_tp()
{
	extern hidden uintptr_t __aeabi_read_tp(void);
	return __aeabi_read_tp();
}
#elif ((__ARM_ARCH_6K__ || __ARM_ARCH_6KZ__ || __ARM_ARCH_6ZK__) && !__thumb__) \
 || __ARM_ARCH_7A__ || __ARM_ARCH_7R__ || __ARM_ARCH >= 7

static inline uintptr_t __get_tp()
{
	uintptr_t tp;
	__asm__ ( "mrc p15,0,%0,c13,c0,3" : "=r"(tp) );
	return tp;
}

#else

#if __ARM_ARCH_4__ || __ARM_ARCH_4T__ || __ARM_ARCH == 4
#define BLX "mov lr,pc\n\tbx"
#else
#define BLX "blx"
#endif

static inline uintptr_t __get_tp()
{
	extern hidden uintptr_t __a_gettp_ptr;
	register uintptr_t tp __asm__("r0");
	__asm__ ( BLX " %1" : "=r"(tp) : "r"(__a_gettp_ptr) : "cc", "lr" );
	return tp;
}

#endif

#define TLS_ABOVE_TP
#define GAP_ABOVE_TP 8

#define MC_PC arm_pc

#ifdef __FDPIC__
#define MC_GOT arm_r9
#define CANCEL_GOT (*(uintptr_t *)((char *)__syscall_cp_asm+sizeof(uintptr_t)))
#endif
EOF
    cat > src/thread/arm/__aeabi_read_tp.s <<'EOF'
.syntax unified
.global __aeabi_read_tp
.type __aeabi_read_tp,%function
__aeabi_read_tp:
#if __FDPIC__
	push {r7}
	mov r7, #0x0f0000
	orr r7, r7, #6
	svc #0
	pop {r7}
	bx lr
#else
	ldr r0,1f
	add r0,r0,pc
	ldr r0,[r0]
2:	bx r0
	.align 2
1:	.word __a_gettp_ptr - 2b
#endif
EOF
    cat > src/ldso/arm/tlsdesc.S <<'EOF'
.syntax unified

.text
.global __tlsdesc_static
.hidden __tlsdesc_static
.type __tlsdesc_static,%function
__tlsdesc_static:
	ldr r0,[r0]
	bx lr

.global __tlsdesc_dynamic
.hidden __tlsdesc_dynamic
.type __tlsdesc_dynamic,%function
__tlsdesc_dynamic:
	push {r2,r3,ip,lr}
	ldr r1,[r0]
	ldr r2,[r1,#4]
	ldr r1,[r1]

#if __FDPIC__
	push {r7}
	mov r7, #0x0f0000
	orr r7, r7, #6
	svc #0
	pop {r7}
#elif ((__ARM_ARCH_6K__ || __ARM_ARCH_6KZ__ || __ARM_ARCH_6ZK__) && !__thumb__) \
 || __ARM_ARCH_7A__ || __ARM_ARCH_7R__ || __ARM_ARCH >= 7
	mrc p15,0,r0,c13,c0,3
#else
	ldr r0,1f
	add r0,r0,pc
	ldr r0,[r0]
2:
#if __ARM_ARCH >= 5
	blx r0
#else
#if __thumb__
	add lr,pc,#1
#else
	mov lr,pc
#endif
	bx r0
#endif
#endif
	ldr r3,[r0,#-4]
	ldr ip,[r3,r1,LSL #2]
	sub r0,ip,r0
	add r0,r0,r2
#if __ARM_ARCH >= 5
	pop {r2,r3,ip,pc}
#else
	pop {r2,r3,ip,lr}
	bx lr
#endif

#if __FDPIC__ || (((__ARM_ARCH_6K__ || __ARM_ARCH_6KZ__ || __ARM_ARCH_6ZK__) && !__thumb__) \
 || __ARM_ARCH_7A__ || __ARM_ARCH_7R__ || __ARM_ARCH >= 7)
#else
	.align 2
1:	.word __a_gettp_ptr - 2b
#endif
EOF
    MUSL_EFFECTIVE_CFLAGS=${MUSL_EXTRA_CFLAGS}
    MUSL_EFFECTIVE_LDFLAGS=${MUSL_EXTRA_LDFLAGS}
    if [ "${MUSL_BUSYBOX_ONLY_NO_RUNTIME_DL}" = "1" ]; then
        MUSL_EFFECTIVE_CFLAGS="${MUSL_EFFECTIVE_CFLAGS} -DMUSL_BUSYBOX_ONLY_NO_RUNTIME_DL=1"
    fi
    if [ "${MUSL_BUSYBOX_ONLY_NO_TZFILE}" = "1" ]; then
        MUSL_EFFECTIVE_CFLAGS="${MUSL_EFFECTIVE_CFLAGS} -DMUSL_BUSYBOX_ONLY_NO_TZFILE=1"
    fi
    if [ "${MUSL_BUSYBOX_ONLY_EXPORT_MAP}" = "1" ] &&
       [ "${MUSL_BUSYBOX_EXPORT_MAP_PASS:-0}" -gt 0 ] &&
       [ -f "${MUSL_BUSYBOX_EXPORT_MAP_PATH}" ]; then
        MUSL_EFFECTIVE_LDFLAGS="${MUSL_EFFECTIVE_LDFLAGS} -Wl,--version-script=${MUSL_BUSYBOX_EXPORT_MAP_PATH}"
    fi
    MUSL_EFFECTIVE_OMIT_SRCS_GLOBS=${MUSL_OMIT_SRCS_GLOBS}
    if [ "${MUSL_PRUNE_UNUSED_MATH}" = "1" ]; then
        for math_src in src/math/*.c; do
            math_keep=0
            for keep_src in ${MUSL_KEEP_MATH_SRCS}; do
                if [ "$(basename "${math_src}")" = "${keep_src}" ]; then
                    math_keep=1
                    break
                fi
            done
            if [ "${math_keep}" = "0" ]; then
                MUSL_EFFECTIVE_OMIT_SRCS_GLOBS="${MUSL_EFFECTIVE_OMIT_SRCS_GLOBS} ./${math_src}"
            fi
        done
        for math_src in src/math/arm/*.c; do
            MUSL_EFFECTIVE_OMIT_SRCS_GLOBS="${MUSL_EFFECTIVE_OMIT_SRCS_GLOBS} ./${math_src}"
        done
    fi

    run_logged "configure" env \
        CC=${TOOLCHAIN}/bin/${TARGET}-gcc \
        AR=${TOOLCHAIN}/bin/${TARGET}-ar \
        RANLIB=${TOOLCHAIN}/bin/${TARGET}-ranlib \
        ./configure --prefix=/ --syslibdir=/lib
    if [ "${MUSL_DISABLE_COMPAT_TIME32}" = "1" ]; then
        # This build only targets our bundled BusyBox on a modern kernel,
        # so we can drop the 32-bit time ABI compatibility shims to save
        # space in the shared libc.
        run_logged "build" make -j${MAKE_JOBS} \
            MALLOC_DIR=${MUSL_MALLOC_DIR} \
            STARTFILE_CRT=rcrt1.o \
            LDSO_ABI_SUFFIX=-fdpic \
            COMPAT_SRC_DIRS= \
            "OMIT_SRCS_GLOBS=${MUSL_EFFECTIVE_OMIT_SRCS_GLOBS}" \
            "CFLAGS=${MUSL_EFFECTIVE_CFLAGS}" \
            "LDFLAGS=${MUSL_EFFECTIVE_LDFLAGS}"
    else
        run_logged "build" make -j${MAKE_JOBS} \
            MALLOC_DIR=${MUSL_MALLOC_DIR} \
            STARTFILE_CRT=rcrt1.o \
            LDSO_ABI_SUFFIX=-fdpic \
            "OMIT_SRCS_GLOBS=${MUSL_EFFECTIVE_OMIT_SRCS_GLOBS}" \
            "CFLAGS=${MUSL_EFFECTIVE_CFLAGS}" \
            "LDFLAGS=${MUSL_EFFECTIVE_LDFLAGS}"
    fi

    MUSL_KERNEL_HEADERS_BACKUP=${ROOTDIR}/.musl-kernel-headers
    rm -rf "${MUSL_KERNEL_HEADERS_BACKUP}"
    mkdir -p "${MUSL_KERNEL_HEADERS_BACKUP}"
    for hdr_dir in asm asm-generic drm linux misc mtd rdma scsi sound video xen; do
        [ -e "${TOOLCHAIN}/${TARGET}/include/${hdr_dir}" ] || continue
        cp -a "${TOOLCHAIN}/${TARGET}/include/${hdr_dir}" "${MUSL_KERNEL_HEADERS_BACKUP}/"
    done

    rm -rf "${TOOLCHAIN}/${TARGET}/lib"
    rm -rf "${TOOLCHAIN}/${TARGET}/include"
    if [ "${MUSL_DISABLE_COMPAT_TIME32}" = "1" ]; then
        run_logged "install" make \
            MALLOC_DIR=${MUSL_MALLOC_DIR} \
            STARTFILE_CRT=rcrt1.o \
            LDSO_ABI_SUFFIX=-fdpic \
            COMPAT_SRC_DIRS= \
            "OMIT_SRCS_GLOBS=${MUSL_EFFECTIVE_OMIT_SRCS_GLOBS}" \
            "CFLAGS=${MUSL_EFFECTIVE_CFLAGS}" \
            "LDFLAGS=${MUSL_EFFECTIVE_LDFLAGS}" \
            install DESTDIR="${TOOLCHAIN}/${TARGET}"
    else
        run_logged "install" make \
            MALLOC_DIR=${MUSL_MALLOC_DIR} \
            STARTFILE_CRT=rcrt1.o \
            LDSO_ABI_SUFFIX=-fdpic \
            "OMIT_SRCS_GLOBS=${MUSL_EFFECTIVE_OMIT_SRCS_GLOBS}" \
            "CFLAGS=${MUSL_EFFECTIVE_CFLAGS}" \
            "LDFLAGS=${MUSL_EFFECTIVE_LDFLAGS}" \
            install DESTDIR="${TOOLCHAIN}/${TARGET}"
    fi
    for hdr_dir in asm asm-generic drm linux misc mtd rdma scsi sound video xen; do
        [ -e "${MUSL_KERNEL_HEADERS_BACKUP}/${hdr_dir}" ] || continue
        cp -a "${MUSL_KERNEL_HEADERS_BACKUP}/${hdr_dir}" "${TOOLCHAIN}/${TARGET}/include/"
    done
    rm -rf "${MUSL_KERNEL_HEADERS_BACKUP}"

    # GCC's arm-uclinuxfdpiceabi FDPIC PIE specs expect musl's shared
    # startup object plus a real __self_reloc implementation. Keep
    # musl's Scrt1.o and provide an ARM FDPIC crtreloc.o instead of a
    # placeholder.
    cp lib/Scrt1.o "${TOOLCHAIN}/${TARGET}/lib/Scrt1.o"
    ln -sf /lib/libc.so "${TOOLCHAIN}/${TARGET}/lib/ld-musl-arm-fdpic.so.1"
    run_logged "build crtreloc" \
        "${TOOLCHAIN}/bin/${TARGET}-gcc" -c -fPIE \
        -I"${TOOLCHAIN}/${TARGET}/include" \
        "${ROOTDIR}/support/arm-fdpic-crtreloc.c" \
        -o "${TOOLCHAIN}/${TARGET}/lib/crtreloc.o"
    cd ../
}

build_libc() {
    assert_supported_libc

    case "${LIBC_IMPL}" in
    uclibc-ng)
        build_uclibc_ng
        ;;
    musl)
        build_musl
        ;;
    esac
}

refresh_musl_busybox_export_map() {
    MAP_TMP=${STATE_DIR}/musl-busybox-exports.map.new

    [ "${LIBC_IMPL}" = "musl" ] || return 0
    [ "${MUSL_BUSYBOX_ONLY_EXPORT_MAP}" = "1" ] || return 0
    [ -x "${ROOTDIR}/scripts/generate-musl-export-map.sh" ] || return 0
    [ -f "${ROOTFS}/bin/busybox" ] || return 0

    "${ROOTDIR}/scripts/generate-musl-export-map.sh" \
        "${ROOTFS}/bin/busybox" \
        "${TOOLCHAIN}/${TARGET}/lib/libc.so" \
        "${MAP_TMP}"

    if [ -f "${MUSL_BUSYBOX_EXPORT_MAP_PATH}" ] && \
       cmp -s "${MAP_TMP}" "${MUSL_BUSYBOX_EXPORT_MAP_PATH}"; then
        rm -f "${MAP_TMP}"
        return 0
    fi

    mv "${MAP_TMP}" "${MUSL_BUSYBOX_EXPORT_MAP_PATH}"
    MUSL_BUSYBOX_EXPORT_MAP_UPDATED=1
}

build_busybox() {
    echo "BUILD: building busybox-${BUSYBOX_VERSION}"
    fetch_file "${BUSYBOX_URL}" "${CHECKSUM_busybox}"

    extract_source "busybox-${BUSYBOX_VERSION}.tar.bz2" "busybox-${BUSYBOX_VERSION}" -xjf
    cp configs/busybox-${BUSYBOX_VERSION}.config busybox-${BUSYBOX_VERSION}/.config
    cd busybox-${BUSYBOX_VERSION}
    if [ "${LIBC_IMPL}" = "musl" ]; then
        apply_patch_once ../patches/0032-busybox-only-disable-float-printf.patch
    fi

    sed -i 's/# CONFIG_NOMMU is not set/CONFIG_NOMMU=y/' .config
    sed -i 's/# CONFIG_PIE is not set/CONFIG_PIE=y/' .config
    case "${LIBC_IMPL}" in
    uclibc-ng)
        BUSYBOX_EXTRA_CFLAGS="--sysroot=${TOOLCHAIN}/${TARGET} -mthumb -march=armv7e-m -ffunction-sections -fdata-sections -fipa-icf -Os"
        BUSYBOX_EXTRA_LDFLAGS="-Wl,--gc-sections"
        BUSYBOX_EXTRA_LDLIBS=""
        ;;
    musl)
        BUSYBOX_EXTRA_CFLAGS="--sysroot=${TOOLCHAIN}/${TARGET} -isystem ${TOOLCHAIN}/${TARGET}/include -mthumb -march=armv7e-m -ffunction-sections -fdata-sections -fipa-icf -Os"
        if [ "${BUSYBOX_ONLY_NO_PRINTF_FLOAT}" = "1" ]; then
            BUSYBOX_EXTRA_CFLAGS="${BUSYBOX_EXTRA_CFLAGS} -DBUSYBOX_ONLY_NO_PRINTF_FLOAT=1"
        fi
        BUSYBOX_EXTRA_LDFLAGS="-Wl,--gc-sections -Wl,-dynamic-linker,/lib/ld-musl-arm-fdpic.so.1 -Wl,-rpath-link,${TOOLCHAIN}/${TARGET}/lib -L${TOOLCHAIN}/${TARGET}/lib -B${TOOLCHAIN}/${TARGET}/lib"
        BUSYBOX_EXTRA_LDLIBS=""
        ;;
    esac
    sed -i "s|CONFIG_EXTRA_CFLAGS=\"\"|CONFIG_EXTRA_CFLAGS=\"${BUSYBOX_EXTRA_CFLAGS}\"|" .config
    # With FDPIC PIE userspace, gc-sections strips dead ELF sections before
    # the final link while preserving shared-library dynamic linking.
    sed -i "s|CONFIG_EXTRA_LDFLAGS=\"\"|CONFIG_EXTRA_LDFLAGS=\"${BUSYBOX_EXTRA_LDFLAGS}\"|" .config
    sed -i "s|CONFIG_EXTRA_LDLIBS=\"\"|CONFIG_EXTRA_LDLIBS=\"${BUSYBOX_EXTRA_LDLIBS}\"|" .config

    # Reinstall into a clean rootfs so disabled applets do not leave stale links.
    rm -rf "${ROOTFS}"

    run_logged "oldconfig" make oldconfig
    run_logged "build and install" make -j${MAKE_JOBS} CROSS_COMPILE=${TARGET}- CONFIG_PREFIX=${ROOTFS} install SKIP_STRIP=y
    cd ../

    MUSL_BUSYBOX_EXPORT_MAP_UPDATED=0
    refresh_musl_busybox_export_map
    if [ "${MUSL_BUSYBOX_EXPORT_MAP_UPDATED}" = "1" ]; then
        MUSL_BUSYBOX_EXPORT_MAP_PASS=${MUSL_BUSYBOX_EXPORT_MAP_PASS:-0}
        MUSL_BUSYBOX_EXPORT_MAP_PASS=$((MUSL_BUSYBOX_EXPORT_MAP_PASS + 1))
        if [ "${MUSL_BUSYBOX_EXPORT_MAP_PASS}" -gt "${MUSL_BUSYBOX_EXPORT_MAP_MAX_PASSES}" ]; then
            echo "ERROR: musl BusyBox export map did not converge after ${MUSL_BUSYBOX_EXPORT_MAP_MAX_PASSES} passes" >&2
            exit 1
        fi

        echo "BUILD: musl export map refreshed from BusyBox (pass ${MUSL_BUSYBOX_EXPORT_MAP_PASS})"
        refresh_build_fingerprints
        rm -rf "musl-${MUSL_VERSION}" "busybox-${BUSYBOX_VERSION}" "${ROOTFS}"
        build_musl
        build_busybox
        mark_stage_complete libc
        return 0
    fi
}

copy_runtime_src() {
    SRC=$1

    # Canonicalize both the sysroot prefix and the source path to defeat
    # symlink-based escapes (e.g. ../../outside passing a lexical prefix check).
    SYSROOT_REAL=$(cd "${TOOLCHAIN}/${TARGET}" && pwd -P)
    SRC_REAL=$(cd "$(dirname "${SRC}")" && pwd -P)/$(basename "${SRC}")

    case "${SRC_REAL}" in
    "${SYSROOT_REAL}"/*) ;;
    *)
        echo "ERROR: runtime library '${SRC}' resolves to '${SRC_REAL}', outside ${SYSROOT_REAL}" >&2
        exit 1
        ;;
    esac

    rel=${SRC#${TOOLCHAIN}/${TARGET}/}
    dst_dir=${ROOTFS}/$(dirname "${rel}")
    dst=${dst_dir}/$(basename "${SRC}")
    mkdir -p "${dst_dir}"
    cp -a "${SRC}" "${dst_dir}/"

    if [ ! -L "${dst}" ] && [ -x "${TOOLCHAIN}/bin/${TARGET}-strip" ]; then
        "${TOOLCHAIN}/bin/${TARGET}-strip" --strip-unneeded "${dst}" >/dev/null 2>&1 || true
    fi

    if [ -L "${SRC}" ]; then
        TARGET_NAME=$(readlink "${SRC}")
        case "${TARGET_NAME}" in
        /*)
            TARGET_SRC=${TOOLCHAIN}/${TARGET}${TARGET_NAME}
            ;;
        *)
            TARGET_SRC=$(dirname "${SRC}")/${TARGET_NAME}
            ;;
        esac
        [ -e "${TARGET_SRC}" ] || {
            echo "ERROR: runtime symlink target '${TARGET_SRC}' does not exist" >&2
            exit 1
        }
        # Guard against circular symlinks: bail if we are about to copy
        # the same canonical path we started from.
        NEXT_REAL=$(cd "$(dirname "${TARGET_SRC}")" && pwd -P)/$(basename "${TARGET_SRC}")
        if [ "${NEXT_REAL}" = "${SRC_REAL}" ]; then
            echo "ERROR: circular symlink detected at '${SRC}'" >&2
            exit 1
        fi
        copy_runtime_src "${TARGET_SRC}"
    fi
}

copy_runtime_entry() {
    NAME=$1
    for libdir in "${TOOLCHAIN}/${TARGET}/lib" "${TOOLCHAIN}/${TARGET}/usr/lib"; do
        SRC=${libdir}/${NAME}
        [ -e "${SRC}" ] || [ -L "${SRC}" ] || continue
        copy_runtime_src "${SRC}"
        return 0
    done

    echo "ERROR: failed to locate runtime library '${NAME}' in ${TOOLCHAIN}/${TARGET}" >&2
    exit 1
}

install_runtime_libraries() {
    READELF=${TOOLCHAIN}/bin/${TARGET}-readelf
    [ -x "${READELF}" ] || return 0

    for libdir in "${ROOTFS}/lib" "${ROOTFS}/usr/lib"; do
        rm -rf "${libdir}"
    done

    # Collect the interpreter.
    INTERP=$(LC_ALL=C "${READELF}" -l "${ROOTFS}/bin/busybox" | sed -n 's/.*Requesting program interpreter: \(.*\)]/\1/p')
    if [ -n "${INTERP}" ]; then
        copy_runtime_entry "$(basename "${INTERP}")"
    fi

    # Seed the work queue with busybox, then walk DT_NEEDED transitively
    # so that indirect dependencies (e.g. libpthread pulled by libc) are
    # also copied into the rootfs.
    _rt_queue="${ROOTFS}/bin/busybox"
    _rt_done=""

    while [ -n "${_rt_queue}" ]; do
        # Pop first entry.
        _rt_cur="${_rt_queue%%
*}"
        _rt_queue="${_rt_queue#${_rt_cur}}"
        _rt_queue="${_rt_queue#
}"

        # Skip already-processed files.
        case " ${_rt_done} " in
        *" ${_rt_cur} "*) continue ;;
        esac
        _rt_done="${_rt_done} ${_rt_cur}"

        LC_ALL=C "${READELF}" -d "${_rt_cur}" 2>/dev/null |
            sed -n 's/.*Shared library: \[\(.*\)\]/\1/p' |
            while IFS= read -r needed; do
                [ -n "${needed}" ] || continue
                # Copy into rootfs if not already present.
                for _chk in "${ROOTFS}/lib/${needed}" "${ROOTFS}/usr/lib/${needed}"; do
                    [ -e "${_chk}" ] && continue 2
                done
                copy_runtime_entry "${needed}"
            done

        # Enqueue any newly copied libraries for transitive scanning.
        for _libdir in "${ROOTFS}/lib" "${ROOTFS}/usr/lib"; do
            [ -d "${_libdir}" ] || continue
            for _f in "${_libdir}"/*.so "${_libdir}"/*.so.*; do
                [ -f "${_f}" ] || continue
                case " ${_rt_done} " in
                *" ${_f} "*) continue ;;
                esac
                case "
${_rt_queue}
" in
                *"
${_f}
"*) continue ;;
                esac
                _rt_queue="${_rt_queue}
${_f}"
            done
        done
    done
}

strip_rootfs_binaries() {
    STRIP=${TOOLCHAIN}/bin/${TARGET}-strip
    READELF=${TOOLCHAIN}/bin/${TARGET}-readelf
    [ -x "${STRIP}" ] || return 0
    [ -x "${READELF}" ] || return 0

    find "${ROOTFS}" -type f \( -name 'busybox' -o -name '*.so' -o -name '*.so.*' \) \
        -exec sh -c '
            for f do
                if "'"${READELF}"'" -h "$f" >/dev/null 2>&1; then
                    "'"${STRIP}"'" --strip-unneeded "$f"
                fi
            done
        ' sh {} +
}

build_finalize_rootfs() {
    echo "BUILD: finalizing rootfs"

    mkdir -p "${ROOTFS}/etc" "${ROOTFS}/proc"
    install_runtime_libraries
    strip_rootfs_binaries

    {
        echo "::sysinit:/bin/sh /etc/rc"
        echo "::respawn:-/bin/sh"
    } >"${ROOTFS}/etc/inittab"

    {
        echo "#!/bin/sh"
        echo "mount -t devtmpfs devtmpfs /dev 2>/dev/null || true"
        echo "mount -t proc proc /proc"
        printf '%s\n' 'printf "\nLinux for Cortex-M\n\n"'
    } >"${ROOTFS}/etc/rc"
    run_logged "optimize init shell script" sh -c "python3 \"${ROOTDIR}/tools/optimize-shell.py\" \"${ROOTFS}/etc/rc\" >\"${ROOTFS}/etc/rc.optimized\""
    mv "${ROOTFS}/etc/rc.optimized" "${ROOTFS}/etc/rc"
    chmod 755 "${ROOTFS}/etc/rc"

    ln -sf /sbin/init "${ROOTFS}/init"
}

kernel_make() {
    make ARCH=${CPU} CROSS_COMPILE=${TARGET}- \
        "LTO_EXTRA_CFLAGS=${KERNEL_LTO_EXTRA_CFLAGS:-}" \
        "KCFLAGS=${KERNEL_KCFLAGS:-}" \
        "$@"
}

build_linux() {
    echo "BUILD: building linux-${LINUX_VERSION}"

    fetch_file "${LINUX_URL}" "${CHECKSUM_linux}"
    extract_source "linux-${LINUX_VERSION}.tar.xz" "linux-${LINUX_VERSION}" -xJf
    cd linux-${LINUX_VERSION}

    # Apply linux-tiny patches for reduced memory footprint and LTO support
    for p in ../patches/0002-*.patch ../patches/0003-*.patch ../patches/0004-*.patch ../patches/0005-*.patch ../patches/0006-*.patch ../patches/0010-*.patch ../patches/0011-*.patch ../patches/0012-*.patch ../patches/0013-*.patch ../patches/0014-*.patch ../patches/0015-*.patch ../patches/0016-*.patch ../patches/0017-*.patch ../patches/0018-*.patch ../patches/0019-*.patch ../patches/0020-*.patch ../patches/0023-*.patch; do
        [ -f "${p}" ] || continue
        apply_patch_once "${p}"
    done

    KERNEL_KCFLAGS=

    if [ -n "${KERNEL_SYSCALL_TABLE}" ]; then
        if [ ! -f "${KERNEL_SYSCALL_TABLE}" ]; then
            echo "ERROR: missing kernel syscall table override: ${KERNEL_SYSCALL_TABLE}"
            exit 1
        fi
        cp -- "${KERNEL_SYSCALL_TABLE}" arch/arm/tools/syscall.tbl
    fi

    run_logged "mps2_defconfig" kernel_make mps2_defconfig

    sed -i "s/# CONFIG_BLK_DEV_INITRD is not set/CONFIG_BLK_DEV_INITRD=y/" .config
    sed -i "/CONFIG_INITRAMFS_SOURCE=/d" .config
    echo "CONFIG_INITRAMFS_SOURCE=\"${ROOTFS} ${ROOTDIR}/configs/rootfs.dev\"" >>.config
    echo "CONFIG_INITRAMFS_COMPRESSION_GZIP=y" >>.config
    # Keep the kernel image itself uncompressed. The boot flow consumes the
    # raw arch/arm/boot/Image via bootwrapper; the zImage self-decompressor
    # in arch/arm/boot/compressed/ is not part of that path. This also lines
    # up with future XIP work, where the kernel text must stay plaintext.
    sed -i '/^CONFIG_KERNEL_/d' .config
    sed -i '/^# CONFIG_KERNEL_.* is not set/d' .config
    echo "CONFIG_KERNEL_UNCOMPRESSED=y" >>.config
    # NOTE: LZ4 and ZSTD have been evaluated on this 16 MiB SSRAM target
    # and both panic during initramfs unpack. lib/decompress_unlz4.c
    # hardcodes an 8 MiB output buffer (LZ4_DEFAULT_UNCOMPRESSED_CHUNK_SIZE)
    # which requires an order-11 contiguous block; the buddy allocator
    # never forms one at boot on this RAM size even with
    # ARCH_FORCE_MAX_ORDER=11. lib/decompress_unzstd.c sizes its DStream
    # workspace from the compressed file's windowSize header, and the
    # default `zstd -19` (scripts/Makefile.lib cmd_zstd) emits an
    # 8 MiB window so the workspace also exceeds MAX_PAGE_ORDER. Any
    # switch away from gzip on this target needs either kernel patches
    # (chunk size in the LZ4 wrapper, or zstd command-line in
    # scripts/Makefile.lib) or installing lzop on the build host. Until
    # then, gzip stays and inflate_fast remains ~2.8% of matched boot
    # blocks (95k TB hits) -- the cost is real but the alternatives are
    # unbootable as wired today.
    if [ -n "${KERNEL_CONFIG_FRAGMENT}" ] && [ -f "${KERNEL_CONFIG_FRAGMENT}" ]; then
        cat -- "${KERNEL_CONFIG_FRAGMENT}" >>.config
    fi

    # This board has no NIC and no remaining userspace networking needs.
    sed -i 's/^CONFIG_NET=y/# CONFIG_NET is not set/' .config
    echo "# CONFIG_MODULES is not set" >>.config
    echo "CONFIG_MAX_SWAPFILES_SHIFT=0" >>.config
    echo "# CONFIG_CRC32_TABLES is not set" >>.config
    echo "CONFIG_PROC_STRIPPED=y" >>.config
    echo "CONFIG_CC_OPTIMIZE_FOR_SIZE=y" >>.config

    # FDPIC userspace replaces the previous FLAT pipeline.
    echo "CONFIG_BINFMT_ELF_FDPIC=y" >>.config
    echo "# CONFIG_BINFMT_FLAT is not set" >>.config
    echo "# CONFIG_BINFMT_SCRIPT is not set" >>.config
    echo "# CONFIG_COREDUMP is not set" >>.config

    case "${KERNEL_LTO_MODE}" in
    none)
        # Production size baseline: the current pruned Cortex-M image is
        # materially smaller without GCC whole-kernel LTO.
        echo "CONFIG_LTO_NONE=y" >>.config
        ;;
    gcc)
        # GCC LTO remains available for explicit experiments even though it
        # regresses the current shipped image size. GCC 16.1 added
        # -flto-toplevel-asm-heuristics, but this tree already carries
        # explicit top-level-asm/linkage fixes in patch 0006; leave any
        # heuristic tuning to KERNEL_LTO_EXTRA_CFLAGS opt-in runs.
        echo "CONFIG_LTO_GCC=y" >>.config
        ;;
    *)
        echo "ERROR: KERNEL_LTO_MODE must be 'none' or 'gcc' (got '${KERNEL_LTO_MODE}')"
        exit 1
        ;;
    esac

    # Disable KALLSYMS -- unnecessary for this minimal target, and also
    # required when GCC LTO is selected because symbol mangling prevents
    # kallsyms convergence on this tree.
    echo "# CONFIG_KALLSYMS is not set" >>.config

    # Dead code/data elimination: adds -ffunction-sections -fdata-sections
    # to KBUILD_CFLAGS_KERNEL (appended after KBUILD_CFLAGS, so it overrides
    # the LTO patch's -fno-function-sections for kernel objects)
    echo "CONFIG_LD_DEAD_CODE_DATA_ELIMINATION=y" >>.config

    # Disable sysfs: no userspace in this config enumerates /sys,
    # and the kobject/kset hierarchy is pure dead weight on Cortex-M4
    echo "# CONFIG_SYSFS is not set" >>.config

    # BASE_SMALL shrinks core hash tables, IDR radix trees, and pid_max.
    # It is an EXPERT-visible bool; mps2_defconfig already enables EXPERT.
    echo "CONFIG_BASE_SMALL=y" >>.config

    # Single-user system: drop UID/GID mapping and related syscalls.
    echo "# CONFIG_MULTIUSER is not set" >>.config

    # Core size pruning: defensive disables and minimum sizes.
    # BLOCK is already off in mps2_defconfig but pin it explicitly so any
    # future defconfig drift is caught by olddefconfig + the verifier below.
    # SWAP depends on BLOCK and is therefore unreachable; the explicit "not
    # set" line keeps the .config audit-friendly.
    echo "# CONFIG_BLOCK is not set" >>.config
    echo "# CONFIG_SWAP is not set" >>.config
    # Tiny SLUB allocator for small-memory uniprocessor (depends on EXPERT).
    echo "CONFIG_SLUB_TINY=y" >>.config
    # Drop printk descriptor table to its 4KB Kconfig minimum. The 64KB
    # default contributes ~180KB of static .data via _printk_rb_static_infos.
    sed -i "/^CONFIG_LOG_BUF_SHIFT=/d" .config
    echo "CONFIG_LOG_BUF_SHIFT=12" >>.config
    # DWARF policy. Production: CONFIG_DEBUG_INFO_NONE=y (no DWARF in
    # vmlinux, fastest link, smallest build artifacts). Diagnostic:
    # KERNEL_DEBUG_INFO=reduced enables CONFIG_DEBUG_INFO_REDUCED=y so
    # scripts/subsystem-rollup.py can attribute every .text symbol to
    # a source directory via addr2line. CONFIG_DEBUG_INFO is a hidden
    # bool selected by the DWARF choice options; we never set it
    # directly. The deployed Image is stripped of debug sections, so
    # the diagnostic build does not change shipped image size.
    case "${KERNEL_DEBUG_INFO}" in
    none)
        echo "CONFIG_DEBUG_INFO_NONE=y" >>.config
        ;;
    reduced)
        # The "Debug information" choice block requires exactly one
        # positive selection. Pick TOOLCHAIN_DEFAULT (which selects
        # the hidden CONFIG_DEBUG_INFO bool), then layer
        # DEBUG_INFO_REDUCED on top -- it is a depends-on-DEBUG_INFO
        # modifier, not a choice member. Stating only DEBUG_INFO_NONE
        # off would leave the choice under-specified and olddefconfig
        # would silently fall back to the kconfig default.
        echo "# CONFIG_DEBUG_INFO_NONE is not set" >>.config
        echo "CONFIG_DEBUG_INFO_DWARF_TOOLCHAIN_DEFAULT=y" >>.config
        echo "CONFIG_DEBUG_INFO_REDUCED=y" >>.config
        ;;
    *)
        echo "ERROR: KERNEL_DEBUG_INFO must be 'none' or 'reduced' (got '${KERNEL_DEBUG_INFO}')"
        exit 1
        ;;
    esac
    # Drop the ARM EABI unwind tables (.ARM.exidx/.ARM.extab, ~75KB).
    # Requires patch 0010 to introduce UNWINDER_NONE on Thumb-2.
    echo "# CONFIG_UNWINDER_ARM is not set" >>.config
    echo "CONFIG_UNWINDER_NONE=y" >>.config

    # Subsystem size pruning: serial-only NOMMU
    # boot-to-shell target. Many of these are dependency-gated off by
    # NOMMU/NET=n/SYSFS=n already; the explicit lines pin them so future
    # defconfig drift is caught and the section-size delta is auditable.
    # SHMEM, AUDIT, POSIX_MQUEUE, SECURITY, TASK_*, AUDIT_*: depend on
    # MMU, NET, or SYSFS+MULTIUSER and would silently come back if any of
    # those flipped.  IO_URING / FUTEX / TIMERFD / FHANDLE / MEMBARRIER /
    # RSEQ default y under EXPERT and need real disables.
    echo "# CONFIG_IO_URING is not set" >>.config
    echo "# CONFIG_AIO is not set" >>.config
    echo "# CONFIG_FHANDLE is not set" >>.config
    echo "# CONFIG_TIMERFD is not set" >>.config
    echo "# CONFIG_ADVISE_SYSCALLS is not set" >>.config
    echo "# CONFIG_MEMBARRIER is not set" >>.config
    echo "# CONFIG_RSEQ is not set" >>.config
    echo "# CONFIG_SECCOMP is not set" >>.config
    echo "# CONFIG_KEYS is not set" >>.config
    echo "# CONFIG_AUDIT is not set" >>.config
    echo "# CONFIG_SYSVIPC is not set" >>.config
    echo "# CONFIG_POSIX_MQUEUE is not set" >>.config
    echo "# CONFIG_FUTEX is not set" >>.config
    echo "# CONFIG_EPOLL is not set" >>.config
    echo "# CONFIG_INOTIFY_USER is not set" >>.config
    echo "# CONFIG_DNOTIFY is not set" >>.config
    echo "# CONFIG_SIGNALFD is not set" >>.config
    echo "# CONFIG_EVENTFD is not set" >>.config
    echo "# CONFIG_TASKSTATS is not set" >>.config
    echo "# CONFIG_TASK_DELAY_ACCT is not set" >>.config
    echo "# CONFIG_TASK_XACCT is not set" >>.config
    echo "# CONFIG_TASK_IO_ACCOUNTING is not set" >>.config
    echo "# CONFIG_WATCH_QUEUE is not set" >>.config
    echo "# CONFIG_VM_EVENT_COUNTERS is not set" >>.config
    echo "# CONFIG_SHMEM is not set" >>.config
    echo "# CONFIG_SECURITY is not set" >>.config

    # Initrd decompressor pruning: the embedded initramfs is gzip-compressed
    # (CONFIG_INITRAMFS_COMPRESSION_GZIP=y). Every other RD_* selector
    # defaults to y under EXPERT and pulls a full decompressor library into
    # the image -- olddefconfig silently restores them after defconfig.
    # Sub-bucket rollup measured RD_ZSTD = 36,942 bytes (lib/zstd),
    # RD_LZ4 = 10,972 bytes (lib/lz4), RD_XZ = 6,598 bytes (lib/xz),
    # RD_LZO = 728 bytes (lib/lzo) of dead .text in the production vmlinux;
    # RD_LZMA / RD_BZIP2 do not currently land any .text but their default-y
    # status lets olddefconfig drift them back on the next time a fs/ or
    # net/ symbol gets enabled. RD_ZSTD also pulls lib/xxhash.c (~3KB).
    # Keep RD_GZIP=y as the boot-path requirement; explicitly disable the
    # rest, including the residuals, so olddefconfig cannot silently
    # re-enable them.
    echo "# CONFIG_RD_ZSTD is not set" >>.config
    echo "# CONFIG_RD_LZ4 is not set" >>.config
    echo "# CONFIG_RD_XZ is not set" >>.config
    echo "# CONFIG_RD_LZMA is not set" >>.config
    echo "# CONFIG_RD_BZIP2 is not set" >>.config
    echo "# CONFIG_RD_LZO is not set" >>.config

    # Serial-only target: drop the VT terminal layer and accessibility
    # console support.  CONFIG_TTY stays on -- the AMBA PL011 console
    # driver depends on it.
    echo "# CONFIG_VT is not set" >>.config
    echo "# CONFIG_LOGO is not set" >>.config
    echo "# CONFIG_A11Y_BRAILLE_CONSOLE is not set" >>.config

    # tty trim: keep CONFIG_TTY for the PL011 console; drop PTY layers
    # and the line-discipline autoloader (no out-of-tree ldiscs to load).
    echo "# CONFIG_UNIX98_PTYS is not set" >>.config
    echo "# CONFIG_LEGACY_PTYS is not set" >>.config
    echo "# CONFIG_LDISC_AUTOLOAD is not set" >>.config

    # Driver families with no consumer on MPS2-AN386.  AMBA bus stays on
    # because the SoC enumerates PL011 over it.  REGMAP is a hidden bool
    # auto-selected by MFD_SYSCON et al.; with all selectors off it
    # disappears from .config on its own.
    echo "# CONFIG_NEW_LEDS is not set" >>.config
    echo "# CONFIG_WATCHDOG is not set" >>.config
    echo "# CONFIG_PPS is not set" >>.config
    echo "# CONFIG_MFD_SYSCON is not set" >>.config
    echo "# CONFIG_RTC_CLASS is not set" >>.config
    echo "# CONFIG_PCI is not set" >>.config

    # Device nodes ship in initramfs (configs/rootfs.dev); the devtmpfs
    # mount in /etc/rc is guarded with `|| true` so it silently skips.
    # CONSEQUENCE: any new device the kernel needs (e.g. a second UART,
    # an HW RNG) must be declared explicitly in configs/rootfs.dev or it
    # will not appear under /dev -- there is no udev/mdev fallback.
    echo "# CONFIG_DEVTMPFS is not set" >>.config
    echo "# CONFIG_DEVTMPFS_MOUNT is not set" >>.config

    # /proc/sys is never read by the boot-to-shell workload.  PROC_FS
    # itself stays on with PROC_STRIPPED -- BusyBox uses /proc/self/exe
    # for SH_STANDALONE re-exec.
    echo "# CONFIG_PROC_SYSCTL is not set" >>.config

    # Debug knobs the production image never exercises.  PRINTK_TIME and
    # DEBUG_BUGVERBOSE are pure metadata cost; STACKPROTECTOR adds a
    # canary check at every function prologue.
    echo "# CONFIG_DEBUG_FS is not set" >>.config
    echo "# CONFIG_PRINTK_TIME is not set" >>.config
    echo "# CONFIG_DEBUG_BUGVERBOSE is not set" >>.config
    echo "# CONFIG_STACKPROTECTOR is not set" >>.config
    echo "# CONFIG_STACKPROTECTOR_STRONG is not set" >>.config

    # Scheduler trim: Linux 7.0 removed CONFIG_SCHED_DEBUG and unified
    # debug.c into build_utility.c.  Patch 0012 reintroduces a knob
    # (SCHED_DEBUG_OUTPUT, default y) that wraps debug.c body in #ifdef
    # and provides empty stubs for the externally-called symbols.
    # /proc/<pid>/sched returns empty seq_file; OOPS sched_show_task
    # path is unaffected (defined in core.c).  Measured: -4,278 bytes /
    # 16 symbols on the production vmlinux .text.
    echo "# CONFIG_SCHED_DEBUG_OUTPUT is not set" >>.config

    # Patch 0013 mirrors 0012 for deadline.c: SCHED_DEADLINE_CLASS
    # default y; set n to wrap deadline.c body in #ifdef and substitute
    # a stub class (DEFINE_SCHED_CLASS(dl) with pick_task=NULL_returner,
    # all other callbacks NULL).  __checkparam_dl returns false so
    # sched_setattr with policy=6 is rejected with -EPERM and no task
    # ever joins SCHED_DEADLINE.  Any later attempt to program a DL
    # server is rejected with -EOPNOTSUPP, so the scheduler must also
    # keep the cgroup-bandwidth/group-sched knobs below disabled.
    # Measured: -10,530 bytes / 81 symbols.
    echo "# CONFIG_SCHED_DEADLINE_CLASS is not set" >>.config
    echo "# CONFIG_PSI is not set" >>.config
    echo "# CONFIG_CGROUPS is not set" >>.config
    echo "# CONFIG_SCHED_AUTOGROUP is not set" >>.config

    # Patch 0014 replaces fair.c (CFS/EEVDF) with a compact O(1) priority
    # round-robin SCHED_NORMAL class under CONFIG_SCHED_FAIR_TINY.  fair.c
    # body is wrapped in #ifndef; the #else branch provides a per-CPU
    # bitmap + per-priority FIFO (HIGH/NORMAL/LOW) plus stubs for every
    # symbol other TUs (rt.c, deadline.c stub, syscalls.c, topology.c,
    # idle.c, build_utility.c) reference.  Linux 7.0 has no CONFIG_SMP
    # guard inside fair.c so balance code (select_task_rq, sched_balance_*,
    # _nohz_idle_balance, ~7.8KB total) stays linked under UP via the
    # sched_class table; this knob is the only way to remove it.  nice
    # values quantise to the three buckets (nice<0 -> HIGH, nice==0 ->
    # NORMAL, nice>0 -> LOW); SCHED_IDLE collapses to LOW; rt_sched_class
    # still pre-empts via the existing class chain walk.
    echo "CONFIG_SCHED_FAIR_TINY=y" >>.config

    # Patch 0015 introduces CONFIG_SCHED_TOPOLOGY_MINIMAL (default n; set y
    # here).  Wraps kernel/sched/topology.c body in #ifndef and substitutes
    # a minimal stub block: def_root_domain + init_rootdomain +
    # init_defrootdomain + rq_attach_root + sched_get/put_rd +
    # sched_domains_mutex helpers + empty sched_init_domains and
    # partition_sched_domains.  Drops sched_domain construction, NUMA,
    # perf-domain, asym-capacity, and topology-debug machinery.  Safe on
    # UP NOMMU (SMP=n, NUMA=n, ENERGY_MODEL=n, CGROUPS=n, CPUSETS=n).
    echo "CONFIG_SCHED_TOPOLOGY_MINIMAL=y" >>.config

    # Patch 0016 introduces CONFIG_SCHED_NO_RICH_API (default n; set y here).
    # Wraps SYSCALL_DEFINEs for sched_setparam/getparam (154/155),
    # sched_set/getscheduler (156/157), sched_get_priority_{max,min}
    # (159/160), sched_rr_get_interval (161), sched_{set,get}affinity
    # (241/242), sched_{set,get}attr (380/381) in #ifndef; sys_ni.c gains
    # COND_SYSCALL aliases so the slot returns -ENOSYS.  Internal helpers
    # (sched_set_fifo*, sched_setscheduler_nocheck, sched_setattr_nocheck,
    # sched_setaffinity, sched_getaffinity, __sched_setaffinity,
    # dl_task_check_affinity) stay live for RCU/kthread/compat callers.
    # Keeps sched_yield (158) and nice (34) intact.
    echo "CONFIG_SCHED_NO_RICH_API=y" >>.config

    # Patch 0017 introduces CONFIG_POSIX_CPU_TIMERS (default y; set n here).
    # Wraps kernel/time/posix-cpu-timers.c body in #ifdef and substitutes
    # k_clock dispatch tables that return -EINVAL for clock_process /
    # clock_thread / clock_posix_cpu, plus no-op stubs for
    # posix_cputimers_group_init / posix_cpu_timers_exit{,_group} /
    # run_posix_cpu_timers / update_rlimit_cpu / thread_group_sample_cputime
    # / set_process_cpu_timer.  Effective syscall impact: clock_gettime /
    # clock_getres / clock_nanosleep on CLOCK_PROCESS_CPUTIME_ID and
    # CLOCK_THREAD_CPUTIME_ID return -EINVAL; setrlimit(RLIMIT_CPU) and
    # ITIMER_PROF / ITIMER_VIRTUAL become silent no-ops.
    echo "# CONFIG_POSIX_CPU_TIMERS is not set" >>.config

    # Existing Kconfig follow-up from TODO.md: periodic ticks are cheaper
    # than the nohz idle state machine on this target, and QEMU has no power
    # story to protect. With the tiny scheduler and GCC LTO, this removes
    # idle tick suppression paths that otherwise stay resident.
    echo "# CONFIG_NO_HZ_IDLE is not set" >>.config

    # Patch 0018 introduces CONFIG_SCHED_PELT_RT_MINI (default n; set y).
    # Stubs CFS-side (__update_load_avg_blocked_se / _se / _cfs_rq) and
    # DL-side (update_dl_rq_load_avg) PELT entry points to return 0;
    # update_other_load_avgs collapses to a thin call to update_rt_rq_load_avg.
    # Safe under SCHED_FAIR_TINY=y (no fair-class PELT consumer) and
    # SCHED_DEADLINE_CLASS=n (DL stub class never accumulates load).
    echo "CONFIG_SCHED_PELT_RT_MINI=y" >>.config

    # Patch 0019 introduces CONFIG_SCHED_RT_TINY (default n; set y here).
    # Wraps kernel/sched/rt.c body in #ifndef and substitutes a fixed-priority
    # FIFO class: priority bitmap + per-priority list_heads, O(1) enqueue /
    # dequeue / pick.  Drops SCHED_RR slice rotation (RR collapses to FIFO),
    # RT bandwidth period timer, throttle, push/pull migration, cpupri
    # find_lowest_rq, and sched_rt/rr_handler sysctl writers.  Cross-priority
    # preemption stays via resched_curr; RT > fair preemption stays via the
    # class-chain walk.  Safe on UP NOMMU with no `chrt` applet.
    echo "CONFIG_SCHED_RT_TINY=y" >>.config

    # Patch 0020 introduces CONFIG_TIME_NO_SET_WALLCLOCK (default n; set y).
    # Stubs do_settimeofday64, do_adjtimex, and timekeeping_warp_clock to
    # return -EPERM / no-op.  Effective syscall impact: settimeofday(2),
    # clock_settime(2), adjtimex(2), and stime(2) all return -EPERM;
    # clock_gettime(2) read paths stay live.  NTP discipline / leap-second
    # / TAI maintenance helpers in timekeeping.c become candidates for LTO
    # dead-stripping.  Safe with QEMU's stable boot-time epoch and no NTP
    # source / RTC on this target.
    echo "CONFIG_TIME_NO_SET_WALLCLOCK=y" >>.config

    run_logged "olddefconfig" kernel_make olddefconfig

    # Verify critical config options survived olddefconfig resolution.
    # Only symbols whose disable line should reliably appear in .config
    # are checked positively here; dependency-gated symbols (SHMEM, AUDIT,
    # POSIX_MQUEUE, SECURITY) are validated by the negative guards below.
    for opt in \
        "# CONFIG_NET is not set" \
        "# CONFIG_MODULES is not set" \
        "# CONFIG_SYSFS is not set" \
        "CONFIG_BLK_DEV_INITRD=y" \
        "CONFIG_BASE_SMALL=y" \
        "CONFIG_CC_OPTIMIZE_FOR_SIZE=y" \
        "# CONFIG_MULTIUSER is not set" \
        "CONFIG_BINFMT_ELF_FDPIC=y" \
        "# CONFIG_BINFMT_FLAT is not set" \
        "# CONFIG_BINFMT_SCRIPT is not set" \
        "# CONFIG_COREDUMP is not set" \
        "# CONFIG_BLOCK is not set" \
        "CONFIG_SLUB_TINY=y" \
        "CONFIG_LOG_BUF_SHIFT=12" \
        "CONFIG_UNWINDER_NONE=y" \
        "# CONFIG_IO_URING is not set" \
        "# CONFIG_FUTEX is not set" \
        "# CONFIG_EPOLL is not set" \
        "# CONFIG_INOTIFY_USER is not set" \
        "# CONFIG_TIMERFD is not set" \
        "# CONFIG_FHANDLE is not set" \
        "# CONFIG_VT is not set" \
        "# CONFIG_UNIX98_PTYS is not set" \
        "# CONFIG_LEGACY_PTYS is not set" \
        "# CONFIG_LDISC_AUTOLOAD is not set" \
        "# CONFIG_NEW_LEDS is not set" \
        "# CONFIG_WATCHDOG is not set" \
        "# CONFIG_MFD_SYSCON is not set" \
        "# CONFIG_DEVTMPFS is not set" \
        "# CONFIG_PROC_SYSCTL is not set" \
        "# CONFIG_DEBUG_FS is not set" \
        "# CONFIG_PRINTK_TIME is not set" \
        "# CONFIG_VM_EVENT_COUNTERS is not set" \
        "# CONFIG_SYSVIPC is not set" \
        "# CONFIG_WATCH_QUEUE is not set" \
        "# CONFIG_PPS is not set" \
        "# CONFIG_RTC_CLASS is not set" \
        "# CONFIG_AIO is not set" \
        "# CONFIG_SIGNALFD is not set" \
        "# CONFIG_EVENTFD is not set" \
        "# CONFIG_DNOTIFY is not set" \
        "# CONFIG_ADVISE_SYSCALLS is not set" \
        "# CONFIG_MEMBARRIER is not set" \
        "# CONFIG_RSEQ is not set" \
        "# CONFIG_SECCOMP is not set" \
        "# CONFIG_KEYS is not set" \
        "# CONFIG_STACKPROTECTOR is not set" \
        "# CONFIG_DEBUG_BUGVERBOSE is not set" \
        "# CONFIG_RD_ZSTD is not set" \
        "# CONFIG_RD_LZ4 is not set" \
        "# CONFIG_RD_XZ is not set" \
        "# CONFIG_RD_LZMA is not set" \
        "# CONFIG_RD_BZIP2 is not set" \
        "# CONFIG_RD_LZO is not set" \
        "# CONFIG_SCHED_DEBUG_OUTPUT is not set" \
        "# CONFIG_SCHED_DEADLINE_CLASS is not set" \
        "# CONFIG_PSI is not set" \
        "# CONFIG_CGROUPS is not set" \
        "# CONFIG_SCHED_AUTOGROUP is not set" \
        "CONFIG_SCHED_FAIR_TINY=y" \
        "CONFIG_SCHED_TOPOLOGY_MINIMAL=y" \
        "CONFIG_SCHED_NO_RICH_API=y" \
        "# CONFIG_POSIX_CPU_TIMERS is not set" \
        "# CONFIG_NO_HZ_IDLE is not set" \
        "CONFIG_SCHED_PELT_RT_MINI=y" \
        "CONFIG_SCHED_RT_TINY=y" \
        "CONFIG_TIME_NO_SET_WALLCLOCK=y"; do
        if ! grep -q "^${opt}\$" .config; then
            echo "ERROR: expected '${opt}' in .config after olddefconfig"
            exit 1
        fi
    done

    case "${KERNEL_LTO_MODE}" in
    none)
        if ! grep -q "^CONFIG_LTO_NONE=y$" .config; then
            echo "ERROR: expected 'CONFIG_LTO_NONE=y' in .config (KERNEL_LTO_MODE=none)"
            exit 1
        fi
        if grep -q "^CONFIG_LTO_GCC=y$" .config; then
            echo "ERROR: CONFIG_LTO_GCC=y survived olddefconfig despite KERNEL_LTO_MODE=none"
            exit 1
        fi
        ;;
    gcc)
        if ! grep -q "^CONFIG_LTO_GCC=y$" .config; then
            echo "ERROR: expected 'CONFIG_LTO_GCC=y' in .config (KERNEL_LTO_MODE=gcc)"
            exit 1
        fi
        ;;
    esac

    if ! grep -q "^CONFIG_KERNEL_UNCOMPRESSED=y$" .config; then
        echo "ERROR: expected 'CONFIG_KERNEL_UNCOMPRESSED=y' in .config"
        exit 1
    fi
    for sym in KERNEL_GZIP KERNEL_BZIP2 KERNEL_LZMA KERNEL_XZ \
               KERNEL_LZO KERNEL_LZ4 KERNEL_ZSTD; do
        if grep -q "^CONFIG_${sym}=y$" .config; then
            echo "ERROR: CONFIG_${sym}=y survived olddefconfig (kernel image must stay uncompressed)"
            exit 1
        fi
    done

    # ARM_UNWIND is a hidden bool: when no choice or `select` references it
    # the symbol is omitted from .config entirely rather than emitted as
    # "is not set". Treat presence of an explicit =y as the failure mode.
    if grep -q "^CONFIG_ARM_UNWIND=y" .config; then
        echo "ERROR: CONFIG_ARM_UNWIND=y survived olddefconfig (UNWINDER_NONE patch broken?)"
        exit 1
    fi

    # DWARF policy is mode-conditional: production keeps DEBUG_INFO_NONE=y,
    # the diagnostic build keeps DEBUG_INFO_REDUCED=y. The other side must
    # not survive olddefconfig in either mode.
    case "${KERNEL_DEBUG_INFO}" in
    none)
        if ! grep -q "^CONFIG_DEBUG_INFO_NONE=y\$" .config; then
            echo "ERROR: expected 'CONFIG_DEBUG_INFO_NONE=y' in .config (KERNEL_DEBUG_INFO=none)"
            exit 1
        fi
        if grep -q "^CONFIG_DEBUG_INFO_REDUCED=y\$" .config; then
            echo "ERROR: CONFIG_DEBUG_INFO_REDUCED=y survived olddefconfig despite KERNEL_DEBUG_INFO=none"
            exit 1
        fi
        ;;
    reduced)
        if ! grep -q "^CONFIG_DEBUG_INFO_REDUCED=y\$" .config; then
            echo "ERROR: expected 'CONFIG_DEBUG_INFO_REDUCED=y' in .config (KERNEL_DEBUG_INFO=reduced)"
            exit 1
        fi
        ;;
    esac

    # Negative-guard for symbols whose `# CONFIG_X is not set` line gets
    # stripped by olddefconfig because their `depends on` clause is unmet
    # under the current build state (NOMMU, NET=n, SYSFS=n, MULTIUSER=n,
    # VT=n, DEVTMPFS=n, STACKPROTECTOR=n).  These cannot be checked
    # positively, but they must never silently resolve to =y if a dep
    # ever flips back:
    #   SHMEM                     -- depends on MMU
    #   AUDIT/POSIX_MQUEUE/TASKSTATS -- depend on NET
    #   SECURITY                  -- depends on SYSFS && MULTIUSER
    #   PCI                       -- arch-gated; not visible on cortex-m
    #   STACKPROTECTOR_STRONG     -- depends on STACKPROTECTOR=y
    #   LOGO/A11Y_BRAILLE_CONSOLE -- depend on the VT stack
    #   DEVTMPFS_MOUNT            -- depends on DEVTMPFS=y
    #   CGROUP_SCHED/*_GROUP_SCHED/CFS_BANDWIDTH -- depend on CGROUPS=y
    for sym in SHMEM AUDIT POSIX_MQUEUE SECURITY TASKSTATS PCI \
               STACKPROTECTOR_STRONG LOGO A11Y_BRAILLE_CONSOLE \
               DEVTMPFS_MOUNT \
               CGROUP_SCHED FAIR_GROUP_SCHED CFS_BANDWIDTH RT_GROUP_SCHED \
               SCHED_CORE NUMA_BALANCING UCLAMP_TASK \
               SCHED_THERMAL_PRESSURE SCHEDSTATS; do
        if grep -q "^CONFIG_${sym}=y\$" .config; then
            echo "ERROR: CONFIG_${sym}=y survived olddefconfig (subsystem disable broken?)"
            exit 1
        fi
    done

    # Decompressor library guard. RD_ZSTD/RD_LZ4/RD_XZ/RD_LZMA/RD_BZIP2/
    # RD_LZO disabled above must cascade to ZSTD_DECOMPRESS /
    # LZ4_DECOMPRESS / XZ_DEC / LZO_DECOMPRESS, the umbrella DECOMPRESS_*
    # hidden bools, and XXHASH (selected by ZSTD_DECOMPRESS, also pulled
    # by BCACHE / BTRFS but those need BLOCK=y which this target lacks).
    # LZO_DECOMPRESS has more upstream selectors than the others
    # (squashfs / btrfs / jffs2 / f2fs / zram / crypto / lib), all of
    # which depend on BLOCK=y or NET=y / crypto knobs that are off here;
    # the negative guard catches any future drift that re-enables one of
    # them. If anything else still selects these symbols (a future fs/ or
    # net/ enable, e.g. squashfs+zstd), we must catch that drift loudly
    # so the size win does not silently regress.
    for sym in ZSTD_DECOMPRESS ZSTD_COMMON LZ4_DECOMPRESS XZ_DEC \
               LZO_DECOMPRESS \
               XXHASH DECOMPRESS_ZSTD DECOMPRESS_LZ4 DECOMPRESS_XZ \
               DECOMPRESS_LZMA DECOMPRESS_BZIP2 DECOMPRESS_LZO; do
        if grep -q "^CONFIG_${sym}=y\$" .config; then
            echo "ERROR: CONFIG_${sym}=y survived olddefconfig (decompressor guard tripped)"
            exit 1
        fi
    done

    KERNEL_KCFLAGS="-mno-fdpic ${KERNEL_KCFLAGS}"
    # Build only the artifacts this repo actually consumes. The
    # bootwrapper stages arch/arm/boot/Image directly; zImage and the
    # compressed self-decompressor are outside the boot path and do not
    # work with CONFIG_KERNEL_UNCOMPRESSED.
    run_logged "build" kernel_make -j${MAKE_JOBS} KAFLAGS=-mno-fdpic KALLSYMS_EXTRA_PASS=1 vmlinux Image

    REPORT_SUBDIR=${KERNEL_REPORT_DIR}/none
    mkdir -p "${REPORT_SUBDIR}"
    run_logged "kernel size report" "${ROOTDIR}/scripts/kernel-size-report.sh" \
        "${ROOTDIR}" "${ROOTDIR}/linux-${LINUX_VERSION}" "${ROOTDIR}/bootwrapper" "${REPORT_SUBDIR}"
    cd ../
}

snapshot_kernel_artifacts() {
    SNAPDIR=$1

    mkdir -p "${SNAPDIR}"
    cp "linux-${LINUX_VERSION}/vmlinux" "${SNAPDIR}/vmlinux"
    cp "linux-${LINUX_VERSION}/System.map" "${SNAPDIR}/System.map"
    cp "linux-${LINUX_VERSION}/.config" "${SNAPDIR}/kernel.config"
    cp "linux-${LINUX_VERSION}/arch/arm/boot/Image" "${SNAPDIR}/Image"
    cp "bootwrapper/linux.axf" "${SNAPDIR}/linux.axf"
}

restore_kernel_artifacts() {
    SNAPDIR=$1

    cp "${SNAPDIR}/vmlinux" "linux-${LINUX_VERSION}/vmlinux"
    cp "${SNAPDIR}/System.map" "linux-${LINUX_VERSION}/System.map"
    cp "${SNAPDIR}/kernel.config" "linux-${LINUX_VERSION}/.config"
    cp "${SNAPDIR}/Image" "linux-${LINUX_VERSION}/arch/arm/boot/Image"
    cp "${SNAPDIR}/linux.axf" "bootwrapper/linux.axf"
}

snapshot_linux_artifacts() {
    SNAPDIR=$1

    mkdir -p "${SNAPDIR}"
    cp "linux-${LINUX_VERSION}/vmlinux" "${SNAPDIR}/vmlinux"
    cp "linux-${LINUX_VERSION}/System.map" "${SNAPDIR}/System.map"
    cp "linux-${LINUX_VERSION}/.config" "${SNAPDIR}/kernel.config"
    cp "linux-${LINUX_VERSION}/arch/arm/boot/Image" "${SNAPDIR}/Image"
}

linux_image_size() {
    wc -c <"${ROOTDIR}/linux-${LINUX_VERSION}/arch/arm/boot/Image" | tr -d ' '
}

linux_vmlinux_size() {
    wc -c <"${ROOTDIR}/linux-${LINUX_VERSION}/vmlinux" | tr -d ' '
}

linux_axf_size() {
    wc -c <"${ROOTDIR}/bootwrapper/linux.axf" | tr -d ' '
}

read_section_size() {
    REPORT_FILE=$1
    SECTION_NAME=$2

    if [ ! -f "${REPORT_FILE}" ]; then
        echo 0
        return
    fi

    awk -v section="${SECTION_NAME}" '
        /^== / {
            if (in_vmlinux) {
                exit
            }
            in_vmlinux = ($0 ~ /\/linux-[0-9.]+\/vmlinux ==/)
            next
        }
        in_vmlinux && $1 == section {
            print $2
            found = 1
            exit
        }
        END {
            if (!found) {
                print 0
            }
        }
    ' "${REPORT_FILE}"
}

sum_section_sizes() {
    REPORT_FILE=$1
    shift

    TOTAL=0
    for SECTION_NAME in "$@"; do
        VALUE=$(read_section_size "${REPORT_FILE}" "${SECTION_NAME}")
        TOTAL=$((TOTAL + VALUE))
    done
    echo "${TOTAL}"
}

read_boot_metric() {
    METRICS_FILE=$1
    METRIC_NAME=$2

    if [ ! -f "${METRICS_FILE}" ]; then
        echo 0
        return
    fi

    VALUE=$(sed -n "s/^${METRIC_NAME}=//p" "${METRICS_FILE}" | tail -n 1)
    case "${VALUE}" in
    ''|*[!0-9]*)
        echo 0
        ;;
    *)
        echo "${VALUE}"
        ;;
    esac
}

read_metric_value() {
    METRICS_FILE=$1
    METRIC_NAME=$2

    if [ ! -f "${METRICS_FILE}" ]; then
        return
    fi

    sed -n "s/^${METRIC_NAME}=//p" "${METRICS_FILE}" | tail -n 1
}

boot_not_regressed() {
    _baseline=$1
    _candidate=$2
    # No baseline measurement: cannot reject on boot time
    [ "$_baseline" -eq 0 ] && return 0
    # Baseline measured but candidate did not: candidate failed to boot
    [ "$_candidate" -eq 0 ] && return 1
    # Both measured: candidate must not exceed baseline
    [ "$_candidate" -le "$_baseline" ]
}

validate_kernel_image() {
    OUTDIR=$1

    mkdir -p "${OUTDIR}"
    run_logged "validate qemu workload" "${ROOTDIR}/scripts/validate-qemu.sh" \
        "${ROOTDIR}/bootwrapper/linux.axf" \
        "${OUTDIR}/qemu-validate.log" \
        "${PGO_WORKLOAD_FILE}" \
        "${OUTDIR}/boot-metrics.txt"
}

record_candidate_result() {
    NAME=$1
    OUTDIR=$2
    SIZE=$3
    METRICS_FILE=$4
    SECTION_REPORT=$5
    BOOT_MARKER_MS=$(read_boot_metric "${METRICS_FILE}" "boot_marker_ms")
    SHELL_READY_MS=$(read_boot_metric "${METRICS_FILE}" "shell_ready_ms")
    TEXT_BYTES=$(sum_section_sizes "${SECTION_REPORT}" ".head.text" ".text")
    RODATA_BYTES=$(sum_section_sizes "${SECTION_REPORT}" ".rodata" ".ARM.unwind_idx" ".ARM.unwind_tab" "__param" ".notes")
    DATA_BYTES=$(read_section_size "${SECTION_REPORT}" ".data")
    BSS_BYTES=$(read_section_size "${SECTION_REPORT}" ".bss")
    INIT_BYTES=$(sum_section_sizes "${SECTION_REPORT}" ".init.text" ".init.data" ".init.proc.info" ".init.arch.info")
    RESIDENT_BYTES=$((TEXT_BYTES + RODATA_BYTES + DATA_BYTES + BSS_BYTES))

    {
        echo "candidate=${NAME}"
        echo "linux_axf_bytes=${SIZE}"
        echo "boot_marker_ms=${BOOT_MARKER_MS}"
        echo "shell_ready_ms=${SHELL_READY_MS}"
        echo "kernel_text_bytes=${TEXT_BYTES}"
        echo "kernel_rodata_bytes=${RODATA_BYTES}"
        echo "kernel_data_bytes=${DATA_BYTES}"
        echo "kernel_bss_bytes=${BSS_BYTES}"
        echo "kernel_init_bytes=${INIT_BYTES}"
        echo "kernel_resident_bytes=${RESIDENT_BYTES}"
    } >"${OUTDIR}/result.txt"
}

append_candidate_summary() {
    SUMMARY_FILE=$1
    NAME=$2
    RESULT_FILE=$3

    SIZE=$(read_boot_metric "${RESULT_FILE}" "linux_axf_bytes")
    BOOT_MARKER_MS=$(read_boot_metric "${RESULT_FILE}" "boot_marker_ms")
    SHELL_READY_MS=$(read_boot_metric "${RESULT_FILE}" "shell_ready_ms")
    RESIDENT_BYTES=$(read_boot_metric "${RESULT_FILE}" "kernel_resident_bytes")
    INIT_BYTES=$(read_boot_metric "${RESULT_FILE}" "kernel_init_bytes")
    printf '%s %s %s %s %s %s\n' \
        "${NAME}" "${SIZE}" "${BOOT_MARKER_MS}" "${SHELL_READY_MS}" "${RESIDENT_BYTES}" "${INIT_BYTES}" \
        >>"${SUMMARY_FILE}"
}

append_candidate_decision() {
    DECISION_FILE=$1
    NAME=$2
    SIZE=$3
    BOOT_MS=$4
    SELECTED_NAME=$5
    SELECTED_SIZE=$6
    SELECTED_BOOT_MS=$7
    BASELINE_BOOT_MS=$8
    RESIDENT_BYTES=$9
    SELECTED_RESIDENT_BYTES=${10}
    INIT_BYTES=${11}
    SELECTED_INIT_BYTES=${12}

    ELIGIBLE=no
    REASON=skipped
    SIZE_DELTA=$((SIZE - SELECTED_SIZE))
    BOOT_DELTA=$((BOOT_MS - SELECTED_BOOT_MS))
    RESIDENT_DELTA=$((RESIDENT_BYTES - SELECTED_RESIDENT_BYTES))
    INIT_DELTA=$((INIT_BYTES - SELECTED_INIT_BYTES))

    if [ "${SIZE}" -gt 0 ]; then
        if boot_not_regressed "${BASELINE_BOOT_MS}" "${BOOT_MS}"; then
            ELIGIBLE=yes
            if [ "${NAME}" = "${SELECTED_NAME}" ]; then
                REASON=selected
            elif [ "${SIZE}" -gt "${SELECTED_SIZE}" ]; then
                REASON=larger_than_selected
            elif [ "${SIZE}" -lt "${SELECTED_SIZE}" ]; then
                REASON=smaller_than_selected_unexpected
            elif [ "${BOOT_MS}" -gt "${SELECTED_BOOT_MS}" ]; then
                REASON=slower_than_selected
            else
                REASON=tie_lost
            fi
        else
            REASON=rejected_boot_regression
        fi
    fi

    printf '%s %s %s %s %s %s %s %+d %+d %+d %+d\n' \
        "${NAME}" "${ELIGIBLE}" "${REASON}" "${SIZE}" "${BOOT_MS}" "${RESIDENT_BYTES}" \
        "${INIT_BYTES}" "${SIZE_DELTA}" "${BOOT_DELTA}" "${RESIDENT_DELTA}" "${INIT_DELTA}" \
        >>"${DECISION_FILE}"
}

write_final_summary() {
    SUMMARY_PATH=$1
    CANDIDATE_MATRIX=$2
    DECISION_FILE=$3
    SELECTED_NAME=$4
    BASELINE_SIZE=$5
    SELECTED_SIZE=$6
    BASELINE_BOOT_MS=$7
    SELECTED_BOOT_MS=$8
    BASELINE_KERNEL_DIR=$9
    OBJECTIVE_SCORECARD=${10}

    {
        echo "Kernel PGO cycle summary"
        echo
        echo "selected_candidate=${SELECTED_NAME}"
        echo "baseline_linux_axf_bytes=${BASELINE_SIZE}"
        echo "selected_linux_axf_bytes=${SELECTED_SIZE}"
        echo "baseline_shell_ready_ms=${BASELINE_BOOT_MS}"
        echo "selected_shell_ready_ms=${SELECTED_BOOT_MS}"
        if [ -f "${OBJECTIVE_SCORECARD}" ]; then
            echo
            echo "objective_scorecard:"
            cat "${OBJECTIVE_SCORECARD}"
        fi
        echo
        echo "footprint_pareto_frontier_boot_eligible:"
        sed -n '1p' "${CANDIDATE_MATRIX}"
        awk '
            NR == FNR {
                if (FNR > 1 && $2 == "yes") {
                    eligible[$1] = 1
                }
                next
            }
            FNR == 1 { next }
            eligible[$1] {
                count++
                name[count] = $1
                size[count] = $2 + 0
                boot[count] = $4 + 0
                resident[count] = $5 + 0
                init[count] = $6 + 0
                row[count] = $0
            }
            END {
                for (i = 1; i <= count; i++) {
                    dominated = 0
                    for (j = 1; j <= count; j++) {
                        if (i == j) {
                            continue
                        }
                        if (size[j] <= size[i] &&
                            resident[j] <= resident[i] &&
                            init[j] <= init[i] &&
                            (size[j] < size[i] ||
                             resident[j] < resident[i] ||
                             init[j] < init[i])) {
                            dominated = 1
                            break
                        }
                    }
                    if (!dominated) {
                        print row[i]
                    }
                }
            }
        ' "${DECISION_FILE}" "${CANDIDATE_MATRIX}" | sort -k2,2n -k5,5n -k6,6n -k4,4n -k1,1
        echo
        echo "metric_leaders:"
        echo "image_size=$(tail -n +2 "${CANDIDATE_MATRIX}" | sort -k2,2n -k4,4n -k5,5n -k1,1 | head -n 1)"
        echo "shell_ready=$(tail -n +2 "${CANDIDATE_MATRIX}" | sort -k4,4n -k2,2n -k5,5n -k1,1 | head -n 1)"
        echo "resident_footprint=$(tail -n +2 "${CANDIDATE_MATRIX}" | sort -k5,5n -k2,2n -k4,4n -k1,1 | head -n 1)"
        echo "init_footprint=$(tail -n +2 "${CANDIDATE_MATRIX}" | sort -k6,6n -k5,5n -k2,2n -k1,1 | head -n 1)"
        echo
        echo "candidate_matrix:"
        cat "${CANDIDATE_MATRIX}"
        echo
        echo "candidate_ranking_by_size:"
        {
            sed -n '1p' "${CANDIDATE_MATRIX}"
            sed -n '2,$p' "${CANDIDATE_MATRIX}" | sort -k2,2n -k4,4n -k5,5n -k1,1
        }
        echo
        echo "candidate_ranking_by_shell_ready:"
        {
            sed -n '1p' "${CANDIDATE_MATRIX}"
            sed -n '2,$p' "${CANDIDATE_MATRIX}" | sort -k4,4n -k2,2n -k5,5n -k1,1
        }
        echo
        echo "candidate_ranking_by_resident_footprint:"
        {
            sed -n '1p' "${CANDIDATE_MATRIX}"
            sed -n '2,$p' "${CANDIDATE_MATRIX}" | sort -k5,5n -k2,2n -k4,4n -k1,1
        }
        echo
        echo "candidate_ranking_by_init_footprint:"
        {
            sed -n '1p' "${CANDIDATE_MATRIX}"
            sed -n '2,$p' "${CANDIDATE_MATRIX}" | sort -k6,6n -k5,5n -k2,2n -k1,1
        }
        echo
        echo "candidate_decisions:"
        cat "${DECISION_FILE}"
        if [ -f "${BASELINE_KERNEL_DIR}/kernel_summary.txt" ]; then
            echo
            echo "[baseline_profile]"
            grep -E '^(matched_ratio|top_32_ratio|top_64_ratio)=' \
                "${BASELINE_KERNEL_DIR}/kernel_summary.txt" || true
        fi
    } >"${SUMMARY_PATH}"
}

compose_kernel_config_fragment() {
    OUTPUT=$1
    shift

    : >"${OUTPUT}"
    for FRAGMENT in "$@"; do
        if [ -n "${FRAGMENT}" ] && [ -f "${FRAGMENT}" ]; then
            cat "${FRAGMENT}" >>"${OUTPUT}"
            printf '\n' >>"${OUTPUT}"
        fi
    done
}

workload_sha256() {
    if [ ! -f "${PGO_WORKLOAD_FILE}" ]; then
        echo missing
        return 1
    fi
    sha256sum "${PGO_WORKLOAD_FILE}" | cut -d' ' -f1
}

profile_cache_dir() {
    CACHE_NAMESPACE=$1
    TRACE_SELECTOR=$2
    TRACE_TAG=$(printf '%s' "${TRACE_SELECTOR}" | tr ',/' '__')
    printf '%s/cache/%s-%s\n' "${KERNEL_REPORT_DIR}" "${CACHE_NAMESPACE}" "${TRACE_TAG}"
}

kernel_profile_cache_valid() {
    CACHE_DIR=$1
    TRACE_SELECTOR=$2
    MANIFEST=${CACHE_DIR}/manifest.env
    WORKLOAD_SHA=$(workload_sha256) || return 1

    [ -f "${MANIFEST}" ] || return 1
    [ -f "${CACHE_DIR}/profile/kernel_summary.txt" ] || return 1
    [ -f "${CACHE_DIR}/profile/kernel_hits.txt" ] || return 1
    [ -f "${CACHE_DIR}/profile/kernel_syscalls.txt" ] || return 1
    [ -f "${CACHE_DIR}/analysis/pgo-kernel.config" ] || return 1
    [ -f "${CACHE_DIR}/analysis/syscalls.txt" ] || return 1

    [ "$(sed -n 's/^image_fingerprint=//p' "${MANIFEST}")" = "${IMAGE_FP}" ] || return 1
    [ "$(sed -n 's/^workload_sha256=//p' "${MANIFEST}")" = "${WORKLOAD_SHA}" ] || return 1
    [ "$(sed -n 's/^trace_selector=//p' "${MANIFEST}")" = "${TRACE_SELECTOR}" ] || return 1
}

link_cached_tree() {
    SRC_DIR=$1
    DEST_DIR=$2

    mkdir -p "${DEST_DIR}"
    for SRC_FILE in "${SRC_DIR}"/*; do
        [ -f "${SRC_FILE}" ] || continue
        DEST_FILE=${DEST_DIR}/$(basename "${SRC_FILE}")
        rm -f "${DEST_FILE}"
        ln -s "${SRC_FILE}" "${DEST_FILE}"
    done
}

materialize_cache_tree() {
    # Copy (do not hardlink) so a future writer that follows a
    # link_cached_tree symlink in a working dir cannot mutate the cached
    # source through a shared inode.
    SRC_DIR=$1
    DEST_DIR=$2

    mkdir -p "${DEST_DIR}"
    for SRC_FILE in "${SRC_DIR}"/*; do
        [ -f "${SRC_FILE}" ] || continue
        DEST_FILE=${DEST_DIR}/$(basename "${SRC_FILE}")
        rm -f "${DEST_FILE}"
        cp -f "${SRC_FILE}" "${DEST_FILE}"
    done
}

prepare_kernel_profile_analysis() {
    PROFILE_DIR=$1
    ANALYSIS_DIR=$2
    TRACE_SELECTOR=$3
    CACHE_NAMESPACE=$4

    CACHE_DIR=$(profile_cache_dir "${CACHE_NAMESPACE}" "${TRACE_SELECTOR}")
    KERNEL_PROFILE_CACHE_HIT=no
    KERNEL_PROFILE_CACHE_DIR=${CACHE_DIR}

    mkdir -p "${PROFILE_DIR}" "${ANALYSIS_DIR}" "${CACHE_DIR}"

    if kernel_profile_cache_valid "${CACHE_DIR}" "${TRACE_SELECTOR}"; then
        echo "BUILD: reusing cached kernel profile analysis (${CACHE_DIR})"
        link_cached_tree "${CACHE_DIR}/profile" "${PROFILE_DIR}"
        link_cached_tree "${CACHE_DIR}/analysis" "${ANALYSIS_DIR}"
        KERNEL_PROFILE_CACHE_HIT=yes
        return 0
    fi

    echo "BUILD: collecting kernel profile (${TRACE_SELECTOR})"
    run_logged "collect kernel profile" env "QEMU_LOG=${TRACE_SELECTOR}" \
        "${ROOTDIR}/scripts/collect-kernel-profile.sh" \
        "${ROOTDIR}/bootwrapper/linux.axf" \
        "${ROOTDIR}/linux-${LINUX_VERSION}/vmlinux" \
        "${PROFILE_DIR}"

    run_logged "analyze kernel profile" python3 "${ROOTDIR}/scripts/analyze-kernel-pgo.py" \
        --profile-prefix "${PROFILE_DIR}/kernel" \
        --linux-dir "${ROOTDIR}/linux-${LINUX_VERSION}" \
        --output-dir "${ANALYSIS_DIR}"

    rm -rf "${CACHE_DIR}/profile" "${CACHE_DIR}/analysis"
    mkdir -p "${CACHE_DIR}/profile" "${CACHE_DIR}/analysis"
    materialize_cache_tree "${PROFILE_DIR}" "${CACHE_DIR}/profile"
    materialize_cache_tree "${ANALYSIS_DIR}" "${CACHE_DIR}/analysis"
    {
        printf 'image_fingerprint=%s\n' "${IMAGE_FP}"
        printf 'workload_sha256=%s\n' "$(workload_sha256)"
        printf 'trace_selector=%s\n' "${TRACE_SELECTOR}"
    } >"${CACHE_DIR}/manifest.env"
}

build_candidate_kernel() {
    NAME=$1
    SYSCALL_TABLE=$2
    CONFIG_FRAGMENT=$3
    REPORT_ROOT=$4
    SNAPDIR=$5

    stage_clean linux
    stage_clean bootwrapper
    (
        KERNEL_SYSCALL_TABLE="${SYSCALL_TABLE}" \
        KERNEL_CONFIG_FRAGMENT="${CONFIG_FRAGMENT}" \
        KERNEL_REPORT_DIR="${REPORT_ROOT}" \
        build_linux
    )
    (
        KERNEL_SYSCALL_TABLE="${SYSCALL_TABLE}" \
        KERNEL_CONFIG_FRAGMENT="${CONFIG_FRAGMENT}" \
        KERNEL_REPORT_DIR="${REPORT_ROOT}" \
        build_bootwrapper
    )
    validate_kernel_image "${REPORT_ROOT}/validation"
    snapshot_kernel_artifacts "${SNAPDIR}"
    record_candidate_result "${NAME}" "${SNAPDIR}" "$(linux_axf_size)" \
        "${REPORT_ROOT}/validation/boot-metrics.txt" \
        "${REPORT_ROOT}/none/section-sizes.txt"
}

record_lto_candidate_result() {
    NAME=$1
    OUTDIR=$2
    SECTION_REPORT=$3

    IMAGE_BYTES=$(linux_image_size)
    VMLINUX_BYTES=$(linux_vmlinux_size)
    TEXT_BYTES=$(sum_section_sizes "${SECTION_REPORT}" ".head.text" ".text")
    RODATA_BYTES=$(sum_section_sizes "${SECTION_REPORT}" ".rodata" ".ARM.unwind_idx" ".ARM.unwind_tab" "__param" ".notes")
    DATA_BYTES=$(read_section_size "${SECTION_REPORT}" ".data")
    BSS_BYTES=$(read_section_size "${SECTION_REPORT}" ".bss")

    {
        echo "candidate=${NAME}"
        echo "status=ok"
        echo "image_bytes=${IMAGE_BYTES}"
        echo "vmlinux_bytes=${VMLINUX_BYTES}"
        echo "text_bytes=${TEXT_BYTES}"
        echo "rodata_bytes=${RODATA_BYTES}"
        echo "data_bytes=${DATA_BYTES}"
        echo "bss_bytes=${BSS_BYTES}"
        echo "note=-"
    } >"${OUTDIR}/result.txt"
}

record_lto_candidate_failure() {
    NAME=$1
    OUTDIR=$2
    NOTE=$3

    {
        echo "candidate=${NAME}"
        echo "status=failed"
        echo "image_bytes=-"
        echo "vmlinux_bytes=-"
        echo "text_bytes=-"
        echo "rodata_bytes=-"
        echo "data_bytes=-"
        echo "bss_bytes=-"
        echo "note=${NOTE}"
    } >"${OUTDIR}/result.txt"
}

append_lto_candidate_summary() {
    SUMMARY_FILE=$1
    NAME=$2
    RESULT_FILE=$3
    BASELINE_RESULT=$4
    STATUS=$(read_metric_value "${RESULT_FILE}" "status")
    NOTE=$(read_metric_value "${RESULT_FILE}" "note")

    if [ "${STATUS}" != "ok" ]; then
        printf '%s %s - - - - - - - - - - - %s\n' \
            "${NAME}" "${STATUS}" "${NOTE}" \
            >>"${SUMMARY_FILE}"
        return
    fi

    IMAGE_BYTES=$(read_boot_metric "${RESULT_FILE}" "image_bytes")
    VMLINUX_BYTES=$(read_boot_metric "${RESULT_FILE}" "vmlinux_bytes")
    TEXT_BYTES=$(read_boot_metric "${RESULT_FILE}" "text_bytes")
    RODATA_BYTES=$(read_boot_metric "${RESULT_FILE}" "rodata_bytes")
    DATA_BYTES=$(read_boot_metric "${RESULT_FILE}" "data_bytes")
    BSS_BYTES=$(read_boot_metric "${RESULT_FILE}" "bss_bytes")

    BASE_IMAGE=$(read_boot_metric "${BASELINE_RESULT}" "image_bytes")
    BASE_VMLINUX=$(read_boot_metric "${BASELINE_RESULT}" "vmlinux_bytes")
    BASE_TEXT=$(read_boot_metric "${BASELINE_RESULT}" "text_bytes")
    BASE_RODATA=$(read_boot_metric "${BASELINE_RESULT}" "rodata_bytes")
    BASE_DATA=$(read_boot_metric "${BASELINE_RESULT}" "data_bytes")
    BASE_BSS=$(read_boot_metric "${BASELINE_RESULT}" "bss_bytes")

    printf '%s %s %s %s %s %s %s %s %+d %+d %+d %+d %+d %+d %s\n' \
        "${NAME}" "${STATUS}" "${IMAGE_BYTES}" "${VMLINUX_BYTES}" "${TEXT_BYTES}" "${RODATA_BYTES}" \
        "${DATA_BYTES}" "${BSS_BYTES}" \
        "$((IMAGE_BYTES - BASE_IMAGE))" \
        "$((VMLINUX_BYTES - BASE_VMLINUX))" \
        "$((TEXT_BYTES - BASE_TEXT))" \
        "$((RODATA_BYTES - BASE_RODATA))" \
        "$((DATA_BYTES - BASE_DATA))" \
        "$((BSS_BYTES - BASE_BSS))" \
        "${NOTE}" \
        >>"${SUMMARY_FILE}"
}

build_lto_candidate() {
    NAME=$1
    LTO_MODE=$2
    GCC_EXTRA=$3
    REPORT_ROOT=$4
    SNAPDIR=$5
    SNAPSHOT_MODE=${6:-linux}

    mkdir -p "${REPORT_ROOT}" "${SNAPDIR}"
    stage_clean linux
    if ! (
        KERNEL_LTO_MODE="${LTO_MODE}" \
        KERNEL_LTO_EXTRA_CFLAGS="${GCC_EXTRA}" \
        KERNEL_REPORT_DIR="${REPORT_ROOT}" \
        build_linux
    ); then
        cp -f "${LOGDIR}/linux.log" "${REPORT_ROOT}/build-failure.log" 2>/dev/null || true
        record_lto_candidate_failure "${NAME}" "${SNAPDIR}" "build_linux_failed"
        return 1
    fi

    if [ "${SNAPSHOT_MODE}" = "kernel" ]; then
        stage_clean bootwrapper
        if ! (
            KERNEL_LTO_MODE="${LTO_MODE}" \
            KERNEL_LTO_EXTRA_CFLAGS="${GCC_EXTRA}" \
            KERNEL_REPORT_DIR="${REPORT_ROOT}" \
            build_bootwrapper
        ); then
            cp -f "${LOGDIR}/bootwrapper.log" "${REPORT_ROOT}/build-failure.log" 2>/dev/null || true
            record_lto_candidate_failure "${NAME}" "${SNAPDIR}" "build_bootwrapper_failed"
            return 1
        fi
        snapshot_kernel_artifacts "${SNAPDIR}"
    else
        snapshot_linux_artifacts "${SNAPDIR}"
    fi

    record_lto_candidate_result "${NAME}" "${SNAPDIR}" "${REPORT_ROOT}/none/section-sizes.txt"
}

build_kernel_lto_sweep() {
    SWEEP_DIR=${KERNEL_REPORT_DIR}/lto-sweep
    FINAL_DIR=${SWEEP_DIR}/final
    ARTIFACT_DIR=${SWEEP_DIR}/artifacts
    SUMMARY_FILE=${FINAL_DIR}/candidate-matrix.txt
    BASELINE_SNAP=${ARTIFACT_DIR}/baseline
    BASELINE_ROOT=${SWEEP_DIR}/baseline

    mkdir -p "${FINAL_DIR}" "${ARTIFACT_DIR}"
    {
        echo "candidate status image_bytes vmlinux_bytes text_bytes rodata_bytes data_bytes bss_bytes image_delta vmlinux_delta text_delta rodata_delta data_delta bss_delta note"
    } >"${SUMMARY_FILE}"

    echo "BUILD: LTO sweep baseline - no LTO"
    if ! build_lto_candidate "baseline" "none" "" "${BASELINE_ROOT}" "${BASELINE_SNAP}" "kernel"; then
        echo "ERROR: LTO sweep baseline build failed"
        exit 1
    fi
    append_lto_candidate_summary "${SUMMARY_FILE}" "baseline" "${BASELINE_SNAP}/result.txt" "${BASELINE_SNAP}/result.txt"

    echo "BUILD: LTO sweep candidate - gcc"
    if ! build_lto_candidate "gcc" "gcc" "" \
        "${SWEEP_DIR}/gcc" "${ARTIFACT_DIR}/gcc"; then
        :
    fi
    append_lto_candidate_summary "${SUMMARY_FILE}" "gcc" "${ARTIFACT_DIR}/gcc/result.txt" "${BASELINE_SNAP}/result.txt"

    echo "BUILD: LTO sweep candidate - gcc-inline-tight"
    if ! build_lto_candidate "gcc-inline-tight" "gcc" \
        "--param=inline-unit-growth=5 --param=max-inline-insns-single=32 --param=max-inline-insns-auto=16" \
        "${SWEEP_DIR}/gcc-inline-tight" "${ARTIFACT_DIR}/gcc-inline-tight"; then
        :
    fi
    append_lto_candidate_summary "${SUMMARY_FILE}" "gcc-inline-tight" "${ARTIFACT_DIR}/gcc-inline-tight/result.txt" "${BASELINE_SNAP}/result.txt"

    echo "BUILD: LTO sweep candidate - gcc-ipa-off"
    if ! build_lto_candidate "gcc-ipa-off" "gcc" \
        "-fno-ipa-cp-clone -fno-ipa-sra -fno-inline-functions -fno-inline-small-functions" \
        "${SWEEP_DIR}/gcc-ipa-off" "${ARTIFACT_DIR}/gcc-ipa-off"; then
        :
    fi
    append_lto_candidate_summary "${SUMMARY_FILE}" "gcc-ipa-off" "${ARTIFACT_DIR}/gcc-ipa-off/result.txt" "${BASELINE_SNAP}/result.txt"

    BEST_BY_IMAGE=$(awk '$2 == "ok" && (best == "" || $3+0 < best) { best=$3+0; name=$1 } END { print name }' "${SUMMARY_FILE}")
    BEST_IMAGE_BYTES=$(awk -v name="${BEST_BY_IMAGE}" '$1==name { print $3 }' "${SUMMARY_FILE}")

    {
        echo "Kernel LTO sweep summary"
        echo
        echo "baseline_image_bytes=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "image_bytes")"
        echo "baseline_vmlinux_bytes=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "vmlinux_bytes")"
        echo "best_candidate_by_image=${BEST_BY_IMAGE}"
        echo "best_candidate_image_bytes=${BEST_IMAGE_BYTES}"
        echo
        echo "candidate_matrix:"
        cat "${SUMMARY_FILE}"
        echo
        echo "ranking_by_image:"
        {
            sed -n '1p' "${SUMMARY_FILE}"
            awk 'NR == 1 || $2 == "ok"' "${SUMMARY_FILE}" | sed -n '2,$p' | sort -k3,3n -k5,5n -k6,6n -k1,1
        }
        echo
        echo "ranking_by_text:"
        {
            sed -n '1p' "${SUMMARY_FILE}"
            awk 'NR == 1 || $2 == "ok"' "${SUMMARY_FILE}" | sed -n '2,$p' | sort -k5,5n -k3,3n -k6,6n -k1,1
        }
        echo
        echo "ranking_by_rodata:"
        {
            sed -n '1p' "${SUMMARY_FILE}"
            awk 'NR == 1 || $2 == "ok"' "${SUMMARY_FILE}" | sed -n '2,$p' | sort -k6,6n -k3,3n -k5,5n -k1,1
        }
        echo
        echo "failed_candidates:"
        {
            sed -n '1p' "${SUMMARY_FILE}"
            awk '$2 != "ok" { print }' "${SUMMARY_FILE}"
        }
    } >"${FINAL_DIR}/summary.txt"

    restore_kernel_artifacts "${BASELINE_SNAP}"
}

build_kernel_pgo_cycle() {
    CYCLE_DIR=${KERNEL_REPORT_DIR}/cycle
    BASELINE_DIR=${CYCLE_DIR}/baseline
    FINAL_DIR=${CYCLE_DIR}/final
    CONFIG_DIR=${CYCLE_DIR}/configs
    SUMMARY_FILE=${FINAL_DIR}/candidate-matrix.txt
    DECISION_FILE=${FINAL_DIR}/candidate-decisions.txt
    FINAL_SUMMARY=${FINAL_DIR}/summary.txt
    OBJECTIVE_SCORECARD=${FINAL_DIR}/objective-scorecard.txt
    BASELINE_SNAP=${CYCLE_DIR}/artifacts/baseline
    CONFIG_SNAP=${CYCLE_DIR}/artifacts/config-only
    SYSCALL_SNAP=${CYCLE_DIR}/artifacts/syscall-prune
    mkdir -p "${BASELINE_DIR}" "${FINAL_DIR}" "${CONFIG_DIR}" "${CYCLE_DIR}/artifacts"
    {
        echo "candidate linux_axf_bytes boot_marker_ms shell_ready_ms kernel_resident_bytes kernel_init_bytes"
    } >"${SUMMARY_FILE}"
    {
        echo "candidate eligible decision linux_axf_bytes shell_ready_ms kernel_resident_bytes kernel_init_bytes size_delta_vs_selected shell_delta_vs_selected resident_delta_vs_selected init_delta_vs_selected"
    } >"${DECISION_FILE}"

    if [ ! -f "${PGO_WORKLOAD_FILE}" ]; then
        echo "ERROR: missing PGO workload file: ${PGO_WORKLOAD_FILE}"
        exit 1
    fi

    echo "BUILD: kernel PGO cycle step 1/3 - baseline kernel build"
    build_candidate_kernel "baseline" "" "" "${BASELINE_DIR}" "${BASELINE_SNAP}"
    BASELINE_SIZE=$(linux_axf_size)
    BASELINE_BOOT_MS=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "shell_ready_ms")
    append_candidate_summary "${SUMMARY_FILE}" "baseline" "${BASELINE_SNAP}/result.txt"

    echo "BUILD: kernel PGO cycle step 2/3 - QEMU trace collection"
    prepare_kernel_profile_analysis "${BASELINE_DIR}/kernel" "${CONFIG_DIR}" \
        "${QEMU_LOG:-exec,in_asm}" "profile-analysis"

    MERGED_CONFIG=${CONFIG_DIR}/pgo-kernel.merged.config
    compose_kernel_config_fragment "${MERGED_CONFIG}" \
        "${PGO_BASE_CONFIG_FRAGMENT}" \
        "${CONFIG_DIR}/pgo-kernel.config"

    echo "BUILD: kernel PGO cycle step 3/3 - PGO rebuild with generated config fragment"
    build_candidate_kernel "config-only" "" "${MERGED_CONFIG}" \
        "${CYCLE_DIR}/config-only" "${CONFIG_SNAP}"
    CONFIG_SIZE=$(sed -n 's/^linux_axf_bytes=//p' "${CONFIG_SNAP}/result.txt")
    CONFIG_SIZE=${CONFIG_SIZE:-0}
    CONFIG_BOOT_MS=$(read_boot_metric "${CONFIG_SNAP}/result.txt" "shell_ready_ms")
    append_candidate_summary "${SUMMARY_FILE}" "config-only" "${CONFIG_SNAP}/result.txt"

    DETECTED_SYSCALLS=$(sed -n 's/^detected_syscalls=//p' "${BASELINE_DIR}/kernel/kernel_summary.txt")
    DETECTED_SYSCALLS=${DETECTED_SYSCALLS:-0}

    SYSCALL_SIZE=0
    SYSCALL_BOOT_MS=0
    if [ "${DETECTED_SYSCALLS}" -gt 0 ]; then
        SYSCALL_TABLE_PATCH=${CONFIG_DIR}/syscall-prune.tbl
        run_logged "generate syscall prune table" python3 "${ROOTDIR}/scripts/generate-syscall-prune-table.py" \
            --syscall-report "${CONFIG_DIR}/syscalls.txt" \
            --syscall-table "${ROOTDIR}/linux-${LINUX_VERSION}/arch/arm/tools/syscall.tbl" \
            --output-table "${SYSCALL_TABLE_PATCH}"

        build_candidate_kernel "syscall-prune" "${SYSCALL_TABLE_PATCH}" "${MERGED_CONFIG}" \
            "${CYCLE_DIR}/syscall-prune" "${SYSCALL_SNAP}"
        SYSCALL_SIZE=$(sed -n 's/^linux_axf_bytes=//p' "${SYSCALL_SNAP}/result.txt")
        SYSCALL_SIZE=${SYSCALL_SIZE:-0}
        SYSCALL_BOOT_MS=$(read_boot_metric "${SYSCALL_SNAP}/result.txt" "shell_ready_ms")
        append_candidate_summary "${SUMMARY_FILE}" "syscall-prune" "${SYSCALL_SNAP}/result.txt"
    else
        echo "PGO: skipping syscall-prune candidate: no syscalls detected (set QEMU_LOG=exec,cpu,in_asm to enable)"
    fi

    BEST_NAME=baseline
    BEST_SNAP=${BASELINE_SNAP}
    BEST_SIZE=${BASELINE_SIZE}
    BEST_BOOT_MS=${BASELINE_BOOT_MS}
    BEST_RESIDENT_BYTES=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "kernel_resident_bytes")
    BEST_INIT_BYTES=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "kernel_init_bytes")

    if [ "${CONFIG_SIZE}" -gt 0 ] && boot_not_regressed "${BASELINE_BOOT_MS}" "${CONFIG_BOOT_MS}" &&
        [ "${CONFIG_SIZE}" -lt "${BEST_SIZE}" ]; then
        BEST_NAME=config-only
        BEST_SNAP=${CONFIG_SNAP}
        BEST_SIZE=${CONFIG_SIZE}
        BEST_BOOT_MS=${CONFIG_BOOT_MS}
        BEST_RESIDENT_BYTES=$(read_boot_metric "${CONFIG_SNAP}/result.txt" "kernel_resident_bytes")
        BEST_INIT_BYTES=$(read_boot_metric "${CONFIG_SNAP}/result.txt" "kernel_init_bytes")
    fi

    if [ "${SYSCALL_SIZE}" -gt 0 ] && boot_not_regressed "${BASELINE_BOOT_MS}" "${SYSCALL_BOOT_MS}" &&
        [ "${SYSCALL_SIZE}" -lt "${BEST_SIZE}" ]; then
        BEST_NAME=syscall-prune
        BEST_SNAP=${SYSCALL_SNAP}
        BEST_SIZE=${SYSCALL_SIZE}
        BEST_BOOT_MS=${SYSCALL_BOOT_MS}
        BEST_RESIDENT_BYTES=$(read_boot_metric "${SYSCALL_SNAP}/result.txt" "kernel_resident_bytes")
        BEST_INIT_BYTES=$(read_boot_metric "${SYSCALL_SNAP}/result.txt" "kernel_init_bytes")
    fi

    if [ "${BEST_NAME}" = "baseline" ]; then
        echo "PGO: no candidate improved linux.axf size without regressing shell_ready_ms; keeping baseline"
        echo "  baseline:      ${BASELINE_SIZE} bytes, ${BASELINE_BOOT_MS} ms"
        echo "  config-only:   ${CONFIG_SIZE} bytes, ${CONFIG_BOOT_MS} ms"
        echo "  syscall-prune: ${SYSCALL_SIZE} bytes, ${SYSCALL_BOOT_MS} ms"
    fi

    restore_kernel_artifacts "${BEST_SNAP}"

    {
        echo "selected_candidate=${BEST_NAME}"
        echo "baseline_linux_axf_bytes=${BASELINE_SIZE}"
        echo "selected_linux_axf_bytes=${BEST_SIZE}"
        echo "baseline_shell_ready_ms=${BASELINE_BOOT_MS}"
        echo "selected_shell_ready_ms=${BEST_BOOT_MS}"
        echo "candidate_matrix=${SUMMARY_FILE}"
        echo "candidate_decisions=${DECISION_FILE}"
    } >"${FINAL_DIR}/selected-candidate.txt"
    append_candidate_decision "${DECISION_FILE}" "baseline" "${BASELINE_SIZE}" "${BASELINE_BOOT_MS}" \
        "${BEST_NAME}" "${BEST_SIZE}" "${BEST_BOOT_MS}" "${BASELINE_BOOT_MS}" \
        "$(read_boot_metric "${BASELINE_SNAP}/result.txt" "kernel_resident_bytes")" "${BEST_RESIDENT_BYTES}" \
        "$(read_boot_metric "${BASELINE_SNAP}/result.txt" "kernel_init_bytes")" "${BEST_INIT_BYTES}"
    append_candidate_decision "${DECISION_FILE}" "config-only" "${CONFIG_SIZE}" "${CONFIG_BOOT_MS}" \
        "${BEST_NAME}" "${BEST_SIZE}" "${BEST_BOOT_MS}" "${BASELINE_BOOT_MS}" \
        "$(read_boot_metric "${CONFIG_SNAP}/result.txt" "kernel_resident_bytes")" "${BEST_RESIDENT_BYTES}" \
        "$(read_boot_metric "${CONFIG_SNAP}/result.txt" "kernel_init_bytes")" "${BEST_INIT_BYTES}"
    append_candidate_decision "${DECISION_FILE}" "syscall-prune" "${SYSCALL_SIZE}" "${SYSCALL_BOOT_MS}" \
        "${BEST_NAME}" "${BEST_SIZE}" "${BEST_BOOT_MS}" "${BASELINE_BOOT_MS}" \
        "$(read_boot_metric "${SYSCALL_SNAP}/result.txt" "kernel_resident_bytes")" "${BEST_RESIDENT_BYTES}" \
        "$(read_boot_metric "${SYSCALL_SNAP}/result.txt" "kernel_init_bytes")" "${BEST_INIT_BYTES}"

    BASELINE_RESIDENT_BYTES=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "kernel_resident_bytes")
    BASELINE_INIT_BYTES=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "kernel_init_bytes")
    SELECTED_SIZE_DELTA_VS_BASELINE=$((BEST_SIZE - BASELINE_SIZE))
    SELECTED_BOOT_DELTA_VS_BASELINE=$((BEST_BOOT_MS - BASELINE_BOOT_MS))
    SELECTED_RESIDENT_DELTA_VS_BASELINE=$((BEST_RESIDENT_BYTES - BASELINE_RESIDENT_BYTES))
    SELECTED_INIT_DELTA_VS_BASELINE=$((BEST_INIT_BYTES - BASELINE_INIT_BYTES))

    {
        echo "selected_candidate=${BEST_NAME}"
        echo "selected_size_delta_vs_baseline=${SELECTED_SIZE_DELTA_VS_BASELINE}"
        echo "selected_shell_delta_vs_baseline=${SELECTED_BOOT_DELTA_VS_BASELINE}"
        echo "selected_resident_delta_vs_baseline=${SELECTED_RESIDENT_DELTA_VS_BASELINE}"
        echo "selected_init_delta_vs_baseline=${SELECTED_INIT_DELTA_VS_BASELINE}"
        echo "selected_image_size_goal_met=$( [ "${BEST_SIZE}" -lt "${BASELINE_SIZE}" ] && echo yes || echo no )"
        echo "selected_resident_footprint_goal_met=$( [ "${BEST_RESIDENT_BYTES}" -lt "${BASELINE_RESIDENT_BYTES}" ] && echo yes || echo no )"
        echo "selected_init_footprint_goal_met=$( [ "${BEST_INIT_BYTES}" -lt "${BASELINE_INIT_BYTES}" ] && echo yes || echo no )"
        echo "selected_boot_constraint_met=$(boot_not_regressed "${BASELINE_BOOT_MS}" "${BEST_BOOT_MS}" && echo yes || echo no)"
        if [ "${BEST_SIZE}" -lt "${BASELINE_SIZE}" ] &&
            [ "${BEST_RESIDENT_BYTES}" -lt "${BASELINE_RESIDENT_BYTES}" ] &&
            [ "${BEST_INIT_BYTES}" -lt "${BASELINE_INIT_BYTES}" ] &&
            boot_not_regressed "${BASELINE_BOOT_MS}" "${BEST_BOOT_MS}"; then
            echo "selected_systematic_goal_met=yes"
        else
            echo "selected_systematic_goal_met=no"
        fi
    } >"${OBJECTIVE_SCORECARD}"

    write_final_summary "${FINAL_SUMMARY}" "${SUMMARY_FILE}" "${DECISION_FILE}" "${BEST_NAME}" \
        "${BASELINE_SIZE}" "${BEST_SIZE}" "${BASELINE_BOOT_MS}" "${BEST_BOOT_MS}" \
        "${BASELINE_DIR}/kernel" "${OBJECTIVE_SCORECARD}"

    run_logged "collect final kernel profile" "${ROOTDIR}/scripts/collect-kernel-profile.sh" \
        "${ROOTDIR}/bootwrapper/linux.axf" \
        "${ROOTDIR}/linux-${LINUX_VERSION}/vmlinux" \
        "${FINAL_DIR}/kernel"
    validate_kernel_image "${FINAL_DIR}/validation"

    # Do not stamp linux/bootwrapper as the default build outputs here.
    # This stage may restore an experimental or PGO-tuned image, and a
    # later plain ./build.sh must rebuild the standard kernel path.
}

build_kernel_syscall_prune_cycle() {
    CYCLE_DIR=${KERNEL_REPORT_DIR}/syscall-prune-cycle
    BASELINE_DIR=${CYCLE_DIR}/baseline
    FINAL_DIR=${CYCLE_DIR}/final
    CONFIG_DIR=${CYCLE_DIR}/configs
    SUMMARY_FILE=${FINAL_DIR}/candidate-matrix.txt
    DECISION_FILE=${FINAL_DIR}/candidate-decisions.txt
    BASELINE_SNAP=${CYCLE_DIR}/artifacts/baseline
    CONFIG_SNAP=${CYCLE_DIR}/artifacts/config-only
    SYSCALL_SNAP=${CYCLE_DIR}/artifacts/syscall-prune
    TRACE_SELECTOR=${QEMU_LOG:-exec,cpu,in_asm}

    mkdir -p "${BASELINE_DIR}" "${FINAL_DIR}" "${CONFIG_DIR}" "${CYCLE_DIR}/artifacts"
    {
        echo "candidate linux_axf_bytes boot_marker_ms shell_ready_ms kernel_resident_bytes kernel_init_bytes"
    } >"${SUMMARY_FILE}"
    {
        echo "candidate eligible decision linux_axf_bytes shell_ready_ms kernel_resident_bytes kernel_init_bytes size_delta_vs_selected shell_delta_vs_selected resident_delta_vs_selected init_delta_vs_selected"
    } >"${DECISION_FILE}"

    if [ ! -f "${PGO_WORKLOAD_FILE}" ]; then
        echo "ERROR: missing PGO workload file: ${PGO_WORKLOAD_FILE}"
        exit 1
    fi

    echo "BUILD: syscall-prune cycle step 1/3 - baseline kernel build"
    build_candidate_kernel "baseline" "" "" "${BASELINE_DIR}" "${BASELINE_SNAP}"
    BASELINE_SIZE=$(linux_axf_size)
    BASELINE_BOOT_MS=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "shell_ready_ms")
    BASELINE_RESIDENT=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "kernel_resident_bytes")
    BASELINE_INIT=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "kernel_init_bytes")
    append_candidate_summary "${SUMMARY_FILE}" "baseline" "${BASELINE_SNAP}/result.txt"

    echo "BUILD: syscall-prune cycle step 2/3 - QEMU trace collection"
    prepare_kernel_profile_analysis "${BASELINE_DIR}/kernel" "${CONFIG_DIR}" \
        "${TRACE_SELECTOR}" "profile-analysis"

    MERGED_CONFIG=${CONFIG_DIR}/pgo-kernel.merged.config
    compose_kernel_config_fragment "${MERGED_CONFIG}" \
        "${PGO_BASE_CONFIG_FRAGMENT}" \
        "${CONFIG_DIR}/pgo-kernel.config"

    echo "BUILD: syscall-prune cycle step 3/3 - candidate rebuilds"
    build_candidate_kernel "config-only" "" "${MERGED_CONFIG}" \
        "${CYCLE_DIR}/config-only" "${CONFIG_SNAP}"
    CONFIG_SIZE=$(sed -n 's/^linux_axf_bytes=//p' "${CONFIG_SNAP}/result.txt")
    CONFIG_SIZE=${CONFIG_SIZE:-0}
    CONFIG_BOOT_MS=$(read_boot_metric "${CONFIG_SNAP}/result.txt" "shell_ready_ms")
    CONFIG_RESIDENT=$(read_boot_metric "${CONFIG_SNAP}/result.txt" "kernel_resident_bytes")
    CONFIG_INIT=$(read_boot_metric "${CONFIG_SNAP}/result.txt" "kernel_init_bytes")
    append_candidate_summary "${SUMMARY_FILE}" "config-only" "${CONFIG_SNAP}/result.txt"

    DETECTED_SYSCALLS=$(sed -n 's/^detected_syscalls=//p' "${BASELINE_DIR}/kernel/kernel_summary.txt")
    DETECTED_SYSCALLS=${DETECTED_SYSCALLS:-0}
    if [ "${DETECTED_SYSCALLS}" -le 0 ]; then
        echo "ERROR: syscall-prune cycle detected no syscalls under trace selector '${TRACE_SELECTOR}'"
        echo "Hint: use QEMU_LOG=exec,cpu,in_asm or let this stage use its default."
        exit 1
    fi

    SYSCALL_TABLE_PATCH=${CONFIG_DIR}/syscall-prune.tbl
    run_logged "generate syscall prune table" python3 "${ROOTDIR}/scripts/generate-syscall-prune-table.py" \
        --syscall-report "${CONFIG_DIR}/syscalls.txt" \
        --syscall-table "${ROOTDIR}/linux-${LINUX_VERSION}/arch/arm/tools/syscall.tbl" \
        --output-table "${SYSCALL_TABLE_PATCH}"

    build_candidate_kernel "syscall-prune" "${SYSCALL_TABLE_PATCH}" "${MERGED_CONFIG}" \
        "${CYCLE_DIR}/syscall-prune" "${SYSCALL_SNAP}"
    SYSCALL_SIZE=$(sed -n 's/^linux_axf_bytes=//p' "${SYSCALL_SNAP}/result.txt")
    SYSCALL_SIZE=${SYSCALL_SIZE:-0}
    SYSCALL_BOOT_MS=$(read_boot_metric "${SYSCALL_SNAP}/result.txt" "shell_ready_ms")
    SYSCALL_RESIDENT=$(read_boot_metric "${SYSCALL_SNAP}/result.txt" "kernel_resident_bytes")
    SYSCALL_INIT=$(read_boot_metric "${SYSCALL_SNAP}/result.txt" "kernel_init_bytes")
    append_candidate_summary "${SUMMARY_FILE}" "syscall-prune" "${SYSCALL_SNAP}/result.txt"

    BEST_NAME=baseline
    BEST_SNAP=${BASELINE_SNAP}
    BEST_SIZE=${BASELINE_SIZE}
    BEST_BOOT_MS=${BASELINE_BOOT_MS}
    BEST_RESIDENT_BYTES=${BASELINE_RESIDENT}
    BEST_INIT_BYTES=${BASELINE_INIT}

    if [ "${CONFIG_SIZE}" -gt 0 ] && boot_not_regressed "${BASELINE_BOOT_MS}" "${CONFIG_BOOT_MS}" &&
        [ "${CONFIG_SIZE}" -lt "${BEST_SIZE}" ]; then
        BEST_NAME=config-only
        BEST_SNAP=${CONFIG_SNAP}
        BEST_SIZE=${CONFIG_SIZE}
        BEST_BOOT_MS=${CONFIG_BOOT_MS}
        BEST_RESIDENT_BYTES=${CONFIG_RESIDENT}
        BEST_INIT_BYTES=${CONFIG_INIT}
    fi

    if [ "${SYSCALL_SIZE}" -gt 0 ] && boot_not_regressed "${BASELINE_BOOT_MS}" "${SYSCALL_BOOT_MS}" &&
        [ "${SYSCALL_SIZE}" -lt "${BEST_SIZE}" ]; then
        BEST_NAME=syscall-prune
        BEST_SNAP=${SYSCALL_SNAP}
        BEST_SIZE=${SYSCALL_SIZE}
        BEST_BOOT_MS=${SYSCALL_BOOT_MS}
        BEST_RESIDENT_BYTES=${SYSCALL_RESIDENT}
        BEST_INIT_BYTES=${SYSCALL_INIT}
    fi

    restore_kernel_artifacts "${BEST_SNAP}"

    {
        echo "selected_candidate=${BEST_NAME}"
        echo "trace_selector=${TRACE_SELECTOR}"
        echo "profile_cache_hit=${KERNEL_PROFILE_CACHE_HIT}"
        echo "profile_cache_dir=${KERNEL_PROFILE_CACHE_DIR}"
        echo "detected_syscalls=${DETECTED_SYSCALLS}"
        echo "baseline_linux_axf_bytes=${BASELINE_SIZE}"
        echo "config_only_linux_axf_bytes=${CONFIG_SIZE}"
        echo "syscall_prune_linux_axf_bytes=${SYSCALL_SIZE}"
        echo "baseline_shell_ready_ms=${BASELINE_BOOT_MS}"
        echo "config_only_shell_ready_ms=${CONFIG_BOOT_MS}"
        echo "syscall_prune_shell_ready_ms=${SYSCALL_BOOT_MS}"
        echo "candidate_matrix=${SUMMARY_FILE}"
        echo "candidate_decisions=${DECISION_FILE}"
        echo "syscall_table_patch=${SYSCALL_TABLE_PATCH}"
        echo "syscall_prune_report=${CONFIG_DIR}/syscall-prune.report.txt"
    } >"${FINAL_DIR}/selected-candidate.txt"

    append_candidate_decision "${DECISION_FILE}" "baseline" "${BASELINE_SIZE}" "${BASELINE_BOOT_MS}" \
        "${BEST_NAME}" "${BEST_SIZE}" "${BEST_BOOT_MS}" "${BASELINE_BOOT_MS}" \
        "${BASELINE_RESIDENT}" "${BEST_RESIDENT_BYTES}" "${BASELINE_INIT}" "${BEST_INIT_BYTES}"
    append_candidate_decision "${DECISION_FILE}" "config-only" "${CONFIG_SIZE}" "${CONFIG_BOOT_MS}" \
        "${BEST_NAME}" "${BEST_SIZE}" "${BEST_BOOT_MS}" "${BASELINE_BOOT_MS}" \
        "${CONFIG_RESIDENT}" "${BEST_RESIDENT_BYTES}" "${CONFIG_INIT}" "${BEST_INIT_BYTES}"
    append_candidate_decision "${DECISION_FILE}" "syscall-prune" "${SYSCALL_SIZE}" "${SYSCALL_BOOT_MS}" \
        "${BEST_NAME}" "${BEST_SIZE}" "${BEST_BOOT_MS}" "${BASELINE_BOOT_MS}" \
        "${SYSCALL_RESIDENT}" "${BEST_RESIDENT_BYTES}" "${SYSCALL_INIT}" "${BEST_INIT_BYTES}"

    {
        echo "Kernel syscall-prune cycle summary"
        echo
        cat "${FINAL_DIR}/selected-candidate.txt"
        echo
        echo "candidate_matrix:"
        cat "${SUMMARY_FILE}"
        echo
        echo "candidate_decisions:"
        cat "${DECISION_FILE}"
    } >"${FINAL_DIR}/summary.txt"

    if [ "${BEST_NAME}" = "baseline" ]; then
        echo "SYSCALL-PRUNE: no candidate improved linux.axf size without regressing shell_ready_ms; keeping baseline"
        echo "  baseline:      ${BASELINE_SIZE} bytes, ${BASELINE_BOOT_MS} ms"
        echo "  config-only:   ${CONFIG_SIZE} bytes, ${CONFIG_BOOT_MS} ms"
        echo "  syscall-prune: ${SYSCALL_SIZE} bytes, ${SYSCALL_BOOT_MS} ms"
    fi
}

# QEMU's Cortex-M machine models lack the direct kernel/DTB loading
# support available on full ARM platforms.  A small boot wrapper is
# required to supply reset vectors and transfer control to the kernel.
# The ARM-software/bootwrapper repository (cortex-m-linux branch)
# serves this purpose; it is patched below to reference the MPS2-AN386
# DTB and the correct SSRAM load address (0x21000000).
build_bootwrapper() {
    echo "BUILD: building ARM CORTEX boot wrapper"

    # Reuse the kernel-built dtc when available so fresh hosts do not need
    # a separate device-tree-compiler package just for the bootwrapper DTB.
    DTC_BIN="${ROOTDIR}/linux-${LINUX_VERSION}/scripts/dtc/dtc"
    if [ -x "${DTC_BIN}" ]; then
        :
    elif command -v dtc >/dev/null 2>&1; then
        DTC_BIN=dtc
    else
        echo "ERROR: no dtc available (expected ${DTC_BIN} or host 'dtc' in PATH)" >&2
        exit 1
    fi

    if [ ! -d bootwrapper ]; then
        run_logged "clone bootwrapper" git clone --depth 1 --single-branch https://github.com/ARM-software/bootwrapper.git -b cortex-m-linux
    fi

    cd bootwrapper
    cp ../linux-${LINUX_VERSION}/arch/arm/boot/Image .
    # Hand-pruned DTS strips disabled peripherals (sp804/sp805/extra UARTs),
    # the SMSC ethernet, FPGA LED MFD, and unused fixed-clocks; this halves
    # the bootwrapper DTB and roughly halves the early-boot fdt_* hot path.
    run_logged "compile slim mps2 dtb" \
        "${DTC_BIN}" -q -I dts -O dtb -o mps2.dtb ../configs/mps2-slim.dts
    sed -i -e 's/mps2-an399.dtb/mps2.dtb/' -e 's/mps2-an385.dtb/mps2.dtb/' Makefile
    sed -i 's/0x60000000/0x21000000/' Makefile
    sed -i 's/. = PHYS_OFFSET;/. = 0x0;/' linux.lds.S

    run_logged "build" make CROSS_COMPILE=${TARGET}- \
        CC="${TOOLCHAIN}/bin/${TARGET}-gcc -mno-fdpic" \
        LD="${TOOLCHAIN}/bin/${TARGET}-ld" \
        AS="${TOOLCHAIN}/bin/${TARGET}-as"

    REPORT_SUBDIR=${KERNEL_REPORT_DIR}/none
    mkdir -p "${REPORT_SUBDIR}"
    # vmlinux did not change between the kernel build and the bootwrapper
    # build, so this refresh only needs to capture linux.axf in filesizes.txt.
    # Running the full report here would rotate the previous snapshot away.
    run_logged "refresh kernel size report" "${ROOTDIR}/scripts/kernel-size-report.sh" \
        "${ROOTDIR}" "${ROOTDIR}/linux-${LINUX_VERSION}" "${ROOTDIR}/bootwrapper" "${REPORT_SUBDIR}" files

    cd ../
}

#
# Do the real work.
#

if [ "${1:-}" = "clean" ]; then
    rm -rf binutils-${BINUTILS_VERSION}
    rm -rf gcc-${GCC_VERSION}
    rm -rf linux-${LINUX_VERSION}
    rm -rf uClibc-ng-${UCLIBC_NG_VERSION}
    rm -rf musl-${MUSL_VERSION}
    rm -rf busybox-${BUSYBOX_VERSION}
    rm -rf bootwrapper
    rm -rf "${TOOLCHAIN}"
    rm -rf "${ROOTFS}"
    rm -rf "${LOGDIR}"
    rm -rf "${STATE_DIR}"
    exit 0
fi

DEFAULT_STAGES="binutils gcc linux_headers libc busybox finalize_rootfs linux bootwrapper"
ALL_STAGES="${DEFAULT_STAGES} kernel_pgo_cycle kernel_syscall_prune_cycle kernel_lto_sweep"

if [ "$#" = 0 ]; then
    STAGES="${DEFAULT_STAGES}"
else
    STAGES=""
    for arg in "$@"; do
        case "${arg}" in
        uClibc)
            STAGES="${STAGES} libc"
            ;;
        binutils | gcc | linux_headers | libc | busybox | finalize_rootfs | linux | bootwrapper | kernel_pgo_cycle | kernel_syscall_prune_cycle | kernel_lto_sweep)
            STAGES="${STAGES} ${arg}"
            ;;
        *)
            echo "usage: build.sh [clean]"
            echo "       build.sh <stage> [<stage> ...]"
            echo ""
            echo "default stages: ${DEFAULT_STAGES}"
            echo "all stages: ${ALL_STAGES}"
            echo "default libc: ${LIBC_IMPL}"
            echo "experimental musl default gate: EXPERIMENTAL_MUSL_DEFAULT=1"
            exit 1
            ;;
        esac
    done
fi

if [ "${EXPERIMENTAL_MUSL_DEFAULT}" = "1" ] && [ "${LIBC_IMPL_EXPLICIT}" = "0" ]; then
    echo "BUILD: selected libc ${LIBC_IMPL} via EXPERIMENTAL_MUSL_DEFAULT=1"
else
    echo "BUILD: selected libc ${LIBC_IMPL}"
fi

for stage in ${STAGES}; do
    if stage_is_current "${stage}"; then
        echo "BUILD: skipping ${stage} (up to date)"
        continue
    fi

    CURRENT_STAGE=${stage}
    CURRENT_LOG=${LOGDIR}/${stage}.log
    : >"${CURRENT_LOG}"

    stage_clean "${stage}"

    # Run each stage in a subshell so a mid-build cd failure
    # does not leave the working directory inside a source tree.
    BUILD_FUNC=build_${stage}
    ( "${BUILD_FUNC}" )
    refresh_build_fingerprints
    mark_stage_complete "${stage}"
done

exit 0
