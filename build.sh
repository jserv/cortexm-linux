#!/bin/sh

# Cross-build a minimal Linux system for ARM Cortex-M4 (MPS2-AN386)
#
# This script produces a self-contained, bootable Linux image targeting the Arm
# MPS2-AN386 FPGA platform (Cortex-M4, no MMU, Thumb-2 only).
# It builds a first-pass GCC cross-compiler (C only), shared FDPIC uClibc-ng,
# BusyBox for a minimal userspace, and a Linux kernel with embedded initramfs.

set -e

# shellcheck disable=SC2329

CPU=arm
TARGET=arm-uclinuxfdpiceabi
FLAVOR=cortexm-fdpic

BINUTILS_VERSION=2.46.0
GCC_VERSION=15.2.0
UCLIBC_NG_VERSION=1.0.57
BUSYBOX_VERSION=1.37.0
LINUX_VERSION=7.0

BINUTILS_URL=https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz
GCC_URL=https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
UCLIBC_NG_URL=https://downloads.uclibc-ng.org/releases/${UCLIBC_NG_VERSION}/uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz
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
KERNEL_EXPERIMENT=${KERNEL_EXPERIMENT:-none}
KERNEL_ORDER_FILE=${KERNEL_ORDER_FILE:-}
KERNEL_SYSCALL_TABLE=${KERNEL_SYSCALL_TABLE:-}
KERNEL_CONFIG_FRAGMENT=${KERNEL_CONFIG_FRAGMENT:-}
KERNEL_REPORT_DIR=${KERNEL_REPORT_DIR:-${ROOTDIR}/profiles/kernel-pgo}
PGO_WORKLOAD_FILE=${PGO_WORKLOAD_FILE:-${ROOTDIR}/configs/pgo-workload.txt}
PGO_BASE_CONFIG_FRAGMENT=${PGO_BASE_CONFIG_FRAGMENT:-${ROOTDIR}/configs/kernel-pgo-prune.config}

NCPU=$(grep -c processor /proc/cpuinfo 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)
MAKE_JOBS=${MAKE_JOBS:-${NCPU}}

PATH=${TOOLCHAIN}/bin:${PATH}

mkdir -p "${LOGDIR}" "${STATE_DIR}"

# SHA256 checksums for downloaded source packages.
# Update these when bumping component versions.
# To populate missing checksums: sha256sum downloads/*
CHECKSUM_binutils="binutils-${BINUTILS_VERSION}.tar.xz=d75a94f4d73e7a4086f7513e67e439e8fcdcbb726ffe63f4661744e6256b2cf2"
CHECKSUM_gcc="gcc-${GCC_VERSION}.tar.xz=438fd996826b0c82485a29da03a72d71d6e3541a83ec702df4271f6fe025d24e"
CHECKSUM_uclibc="uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz=8bc734b584e23ff6ae3d0ebb4c0fb1d1d814c58c82822b93130d436afa7ace8b"
CHECKSUM_busybox="busybox-${BUSYBOX_VERSION}.tar.bz2=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4"
CHECKSUM_linux="linux-${LINUX_VERSION}.tar.xz=bb7f6d80b387c757b7d14bb93028fcb90f793c5c0d367736ee815a100b3891f0"

toolchain_fingerprint() {
    {
        sha256sum build.sh
        sha256sum patches/0001-* 2>/dev/null || true
        sha256sum configs/uClibc-ng-* 2>/dev/null || true
    } | sha256sum | cut -d' ' -f1
}

image_fingerprint() {
    {
        printf '%s\n' "$1"
        printf 'KERNEL_EXPERIMENT=%s\n' "${KERNEL_EXPERIMENT}"
        printf 'KERNEL_ORDER_FILE=%s\n' "${KERNEL_ORDER_FILE}"
        printf 'KERNEL_SYSCALL_TABLE=%s\n' "${KERNEL_SYSCALL_TABLE}"
        printf 'KERNEL_CONFIG_FRAGMENT=%s\n' "${KERNEL_CONFIG_FRAGMENT}"
        if [ -n "${KERNEL_ORDER_FILE}" ] && [ -f "${KERNEL_ORDER_FILE}" ]; then
            sha256sum "${KERNEL_ORDER_FILE}"
        fi
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

TOOLCHAIN_FP=$(toolchain_fingerprint)
IMAGE_FP=$(image_fingerprint "${TOOLCHAIN_FP}")

stage_fingerprint() {
    case "$1" in
    binutils|gcc|linux_headers|uClibc)
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

stage_verify_uClibc() {
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
    [ -e "${ROOTFS}${INTERP}" ] || return 1

    _needed_libs=$(LC_ALL=C "${READELF}" -d "${ROOTFS}/bin/busybox" 2>/dev/null |
        sed -n 's/.*Shared library: \[\(.*\)\]/\1/p')
    for needed in ${_needed_libs}; do
        [ -e "${ROOTFS}/lib/${needed}" ] || [ -e "${ROOTFS}/usr/lib/${needed}" ] || return 1
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
    uClibc)         rm -rf "uClibc-ng-${UCLIBC_NG_VERSION}" ;;
    busybox)        rm -rf "busybox-${BUSYBOX_VERSION}" "${ROOTFS}" ;;
    finalize_rootfs) ;; # idempotent; overwrites its outputs
    linux)          rm -rf "linux-${LINUX_VERSION}" ;;
    bootwrapper)    rm -rf bootwrapper ;;
    kernel_pgo_cycle) rm -rf "${KERNEL_REPORT_DIR}/cycle" ;;
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

build_uClibc() {
    echo "BUILD: building uClibc-${UCLIBC_NG_VERSION}"
    fetch_file "${UCLIBC_NG_URL}" "${CHECKSUM_uclibc}"

    extract_source "uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz" "uClibc-ng-${UCLIBC_NG_VERSION}" -xJf
    cp configs/uClibc-ng-${UCLIBC_NG_VERSION}-${FLAVOR}.config uClibc-ng-${UCLIBC_NG_VERSION}/.config
    cd uClibc-ng-${UCLIBC_NG_VERSION}

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

build_busybox() {
    echo "BUILD: building busybox-${BUSYBOX_VERSION}"
    fetch_file "${BUSYBOX_URL}" "${CHECKSUM_busybox}"

    extract_source "busybox-${BUSYBOX_VERSION}.tar.bz2" "busybox-${BUSYBOX_VERSION}" -xjf
    cp configs/busybox-${BUSYBOX_VERSION}.config busybox-${BUSYBOX_VERSION}/.config
    cd busybox-${BUSYBOX_VERSION}

    sed -i 's/# CONFIG_NOMMU is not set/CONFIG_NOMMU=y/' .config
    sed -i 's/# CONFIG_PIE is not set/CONFIG_PIE=y/' .config
    sed -i "s|CONFIG_EXTRA_CFLAGS=\"\"|CONFIG_EXTRA_CFLAGS=\"--sysroot=${TOOLCHAIN}/${TARGET} -mthumb -march=armv7e-m -ffunction-sections -fdata-sections -fipa-icf -Os\"|" .config
    # With FDPIC PIE userspace, gc-sections strips dead ELF sections before
    # the final link while preserving shared-library dynamic linking.
    sed -i 's/CONFIG_EXTRA_LDFLAGS=""/CONFIG_EXTRA_LDFLAGS="-Wl,--gc-sections"/' .config

    # Reinstall into a clean rootfs so disabled applets do not leave stale links.
    rm -rf "${ROOTFS}"

    run_logged "oldconfig" make oldconfig
    run_logged "build and install" make -j${MAKE_JOBS} CROSS_COMPILE=${TARGET}- CONFIG_PREFIX=${ROOTFS} install SKIP_STRIP=y
    cd ../
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
    mkdir -p "${dst_dir}"
    cp -a "${SRC}" "${dst_dir}/"

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
        [ -e "${SRC}" ] || continue
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
    if [ "${KERNEL_EXPERIMENT}" = "llvm-order-use" ]; then
        if [ -n "${KERNEL_KBUILD_LDFLAGS:-}" ]; then
            make ARCH=${CPU} CROSS_COMPILE=${TARGET}- \
                LLVM=1 LLVM_IAS=0 \
                HOSTCC=clang HOSTCXX=clang++ \
                CC=clang LD=ld.lld \
                "KCFLAGS=${KERNEL_KCFLAGS:-}" \
                "KBUILD_LDFLAGS+=${KERNEL_KBUILD_LDFLAGS}" \
                "$@"
            return
        fi

        make ARCH=${CPU} CROSS_COMPILE=${TARGET}- \
            LLVM=1 LLVM_IAS=0 \
            HOSTCC=clang HOSTCXX=clang++ \
            CC=clang LD=ld.lld \
            "KCFLAGS=${KERNEL_KCFLAGS:-}" \
            "$@"
        return
    fi

    make ARCH=${CPU} CROSS_COMPILE=${TARGET}- \
        "KCFLAGS=${KERNEL_KCFLAGS:-}" \
        "$@"
}

build_linux() {
    echo "BUILD: building linux-${LINUX_VERSION}"

    fetch_file "${LINUX_URL}" "${CHECKSUM_linux}"
    extract_source "linux-${LINUX_VERSION}.tar.xz" "linux-${LINUX_VERSION}" -xJf
    cd linux-${LINUX_VERSION}

    # Apply linux-tiny patches for reduced memory footprint and LTO support
    for p in ../patches/0002-*.patch ../patches/0003-*.patch ../patches/0004-*.patch ../patches/0005-*.patch ../patches/0006-*.patch; do
        [ -f "${p}" ] || continue
        apply_patch_once "${p}"
    done

    KERNEL_KCFLAGS=
    KERNEL_KBUILD_LDFLAGS=

    case "${KERNEL_EXPERIMENT}" in
    none)
        ;;
    llvm-order-use)
        if [ -z "${KERNEL_ORDER_FILE}" ]; then
            echo "ERROR: KERNEL_ORDER_FILE is required when KERNEL_EXPERIMENT=llvm-order-use"
            exit 1
        fi
        if [ ! -f "${KERNEL_ORDER_FILE}" ]; then
            echo "ERROR: missing kernel order file: ${KERNEL_ORDER_FILE}"
            exit 1
        fi
        KERNEL_KCFLAGS="-ffunction-sections -gmlt"
        KERNEL_KBUILD_LDFLAGS="--symbol-ordering-file=${KERNEL_ORDER_FILE} --no-warn-symbol-ordering"
        ;;
    *)
        echo "ERROR: unsupported KERNEL_EXPERIMENT='${KERNEL_EXPERIMENT}'"
        echo "Supported values: none, llvm-order-use"
        exit 1
        ;;
    esac

    if [ -n "${KERNEL_SYSCALL_TABLE}" ]; then
        if [ ! -f "${KERNEL_SYSCALL_TABLE}" ]; then
            echo "ERROR: missing kernel syscall table override: ${KERNEL_SYSCALL_TABLE}"
            exit 1
        fi
        cp "${KERNEL_SYSCALL_TABLE}" arch/arm/tools/syscall.tbl
    fi

    run_logged "mps2_defconfig" kernel_make mps2_defconfig

    sed -i "s/# CONFIG_BLK_DEV_INITRD is not set/CONFIG_BLK_DEV_INITRD=y/" .config
    sed -i "/CONFIG_INITRAMFS_SOURCE=/d" .config
    echo "CONFIG_INITRAMFS_SOURCE=\"${ROOTFS} ${ROOTDIR}/configs/rootfs.dev\"" >>.config
    echo "CONFIG_INITRAMFS_COMPRESSION_GZIP=y" >>.config
    if [ -n "${KERNEL_CONFIG_FRAGMENT}" ] && [ -f "${KERNEL_CONFIG_FRAGMENT}" ]; then
        cat "${KERNEL_CONFIG_FRAGMENT}" >>.config
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

    if [ "${KERNEL_EXPERIMENT}" = "none" ]; then
        # Enable GCC LTO for whole-kernel optimization in the default build.
        echo "CONFIG_LTO_GCC=y" >>.config
    fi
    # Disable KALLSYMS -- incompatible with LTO symbol mangling
    # and unnecessary for this minimal target
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

    run_logged "olddefconfig" kernel_make olddefconfig

    # Verify critical config options survived olddefconfig resolution
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
        "# CONFIG_COREDUMP is not set"; do
        if ! grep -q "^${opt}\$" .config; then
            echo "ERROR: expected '${opt}' in .config after olddefconfig"
            exit 1
        fi
    done

    if [ "${KERNEL_EXPERIMENT}" = "llvm-order-use" ]; then
        run_logged "build" kernel_make -j${MAKE_JOBS} KALLSYMS_EXTRA_PASS=1
    else
        KERNEL_KCFLAGS="-mno-fdpic ${KERNEL_KCFLAGS}"
        run_logged "build" kernel_make -j${MAKE_JOBS} KAFLAGS=-mno-fdpic KALLSYMS_EXTRA_PASS=1
    fi

    REPORT_SUBDIR=${KERNEL_REPORT_DIR}/${KERNEL_EXPERIMENT}
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
    LAYOUT_DECISION_FILE=$9
    BASELINE_KERNEL_DIR=${10}
    BEST_ORDER_NAME=${11}
    BEST_ORDER_SIZE=${12}
    BEST_ORDER_BOOT_MS=${13}
    BEST_ORDER_FILE=${14}
    BEST_ORDER_SIZE_DELTA=${15}
    BEST_ORDER_BOOT_DELTA=${16}
    BEST_ORDER_RESIDENT_DELTA=${17}
    BEST_ORDER_INIT_BYTES=${18}
    BEST_ORDER_INIT_DELTA=${19}
    OBJECTIVE_SCORECARD=${20}

    {
        echo "Kernel PGO cycle summary"
        echo
        echo "selected_candidate=${SELECTED_NAME}"
        echo "baseline_linux_axf_bytes=${BASELINE_SIZE}"
        echo "selected_linux_axf_bytes=${SELECTED_SIZE}"
        echo "baseline_shell_ready_ms=${BASELINE_BOOT_MS}"
        echo "selected_shell_ready_ms=${SELECTED_BOOT_MS}"
        echo "best_order_candidate=${BEST_ORDER_NAME:-none}"
        echo "best_order_linux_axf_bytes=${BEST_ORDER_SIZE:-0}"
        echo "best_order_shell_ready_ms=${BEST_ORDER_BOOT_MS:-0}"
        echo "best_order_file=${BEST_ORDER_FILE:-none}"
        echo "best_order_size_delta_vs_selected=${BEST_ORDER_SIZE_DELTA:-0}"
        echo "best_order_shell_delta_vs_selected=${BEST_ORDER_BOOT_DELTA:-0}"
        echo "best_order_resident_delta_vs_selected=${BEST_ORDER_RESIDENT_DELTA:-0}"
        echo "best_order_init_bytes=${BEST_ORDER_INIT_BYTES:-0}"
        echo "best_order_init_delta_vs_selected=${BEST_ORDER_INIT_DELTA:-0}"
        if [ -f "${OBJECTIVE_SCORECARD}" ]; then
            echo
            echo "objective_scorecard:"
            cat "${OBJECTIVE_SCORECARD}"
        fi
        echo
        echo "remaining_gap_to_trace_layout_win:"
        if [ "${BEST_ORDER_NAME:-}" = "none" ] || [ -z "${BEST_ORDER_NAME:-}" ]; then
            echo "best_order_candidate=none"
            echo "trace_layout_candidate_available=no"
            echo "trace_layout_win_remaining=yes"
        else
            echo "best_order_candidate=${BEST_ORDER_NAME}"
            echo "trace_layout_candidate_available=yes"
            if [ "${BEST_ORDER_SIZE_DELTA:-0}" -gt 0 ] ||
                [ "${BEST_ORDER_RESIDENT_DELTA:-0}" -gt 0 ] ||
                [ "${BEST_ORDER_INIT_DELTA:-0}" -gt 0 ] ||
                [ "${BEST_ORDER_BOOT_DELTA:-0}" -gt 0 ]; then
                echo "trace_layout_win_remaining=yes"
            else
                echo "trace_layout_win_remaining=no"
            fi
            echo "size_bytes_needed_to_tie_selected=${BEST_ORDER_SIZE_DELTA:-0}"
            echo "resident_bytes_needed_to_tie_selected=${BEST_ORDER_RESIDENT_DELTA:-0}"
            echo "init_bytes_needed_to_tie_selected=${BEST_ORDER_INIT_DELTA:-0}"
            echo "shell_ready_ms_headroom_vs_selected=${BEST_ORDER_BOOT_DELTA:-0}"
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
        echo
        echo "layout_profile:"
        if [ -f "${LAYOUT_DECISION_FILE}" ]; then
            echo "[layout_decision]"
            cat "${LAYOUT_DECISION_FILE}"
        else
            echo "missing_layout_decision_file=1"
        fi
        if [ -f "${BASELINE_KERNEL_DIR}/kernel_summary.txt" ]; then
            echo "[baseline_profile]"
            grep -E '^(ordering_symbol_count|ordering_hit_ratio|matched_ratio|top_32_ratio|top_64_ratio)=' \
                "${BASELINE_KERNEL_DIR}/kernel_summary.txt" || true
        fi
        if [ -f "${BASELINE_KERNEL_DIR}/kernel_ld_profile.txt" ]; then
            echo
            echo "ordering_file_head:"
            sed -n '1,12p' "${BASELINE_KERNEL_DIR}/kernel_ld_profile.txt"
        fi
        if [ -f "${BASELINE_KERNEL_DIR}/kernel_ld_profile_full.txt" ]; then
            echo
            echo "ordering_file_full_head:"
            sed -n '1,8p' "${BASELINE_KERNEL_DIR}/kernel_ld_profile_full.txt"
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

build_candidate_kernel() {
    NAME=$1
    EXPERIMENT=$2
    ORDER_FILE=$3
    SYSCALL_TABLE=$4
    CONFIG_FRAGMENT=$5
    REPORT_ROOT=$6
    SNAPDIR=$7

    stage_clean linux
    stage_clean bootwrapper
    (
        KERNEL_EXPERIMENT="${EXPERIMENT}" \
        KERNEL_ORDER_FILE="${ORDER_FILE}" \
        KERNEL_SYSCALL_TABLE="${SYSCALL_TABLE}" \
        KERNEL_CONFIG_FRAGMENT="${CONFIG_FRAGMENT}" \
        KERNEL_REPORT_DIR="${REPORT_ROOT}" \
        build_linux
    )
    (
        KERNEL_EXPERIMENT="${EXPERIMENT}" \
        KERNEL_ORDER_FILE="${ORDER_FILE}" \
        KERNEL_SYSCALL_TABLE="${SYSCALL_TABLE}" \
        KERNEL_CONFIG_FRAGMENT="${CONFIG_FRAGMENT}" \
        KERNEL_REPORT_DIR="${REPORT_ROOT}" \
        build_bootwrapper
    )
    validate_kernel_image "${REPORT_ROOT}/validation"
    snapshot_kernel_artifacts "${SNAPDIR}"
    record_candidate_result "${NAME}" "${SNAPDIR}" "$(linux_axf_size)" \
        "${REPORT_ROOT}/validation/boot-metrics.txt" \
        "${REPORT_ROOT}/${EXPERIMENT}/section-sizes.txt"
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
    ORDER_SNAP=${CYCLE_DIR}/artifacts/llvm-order
    ORDER_FULL_SNAP=${CYCLE_DIR}/artifacts/llvm-order-full
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
    build_candidate_kernel "baseline" "none" "" "" "" "${BASELINE_DIR}" "${BASELINE_SNAP}"
    BASELINE_SIZE=$(linux_axf_size)
    BASELINE_BOOT_MS=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "shell_ready_ms")
    append_candidate_summary "${SUMMARY_FILE}" "baseline" "${BASELINE_SNAP}/result.txt"

    echo "BUILD: kernel PGO cycle step 2/3 - QEMU trace collection"
    run_logged "collect kernel profile" "${ROOTDIR}/scripts/collect-kernel-profile.sh" \
        "${ROOTDIR}/bootwrapper/linux.axf" \
        "${ROOTDIR}/linux-${LINUX_VERSION}/vmlinux" \
        "${BASELINE_DIR}/kernel"

    run_logged "analyze kernel profile" "${ROOTDIR}/scripts/analyze-kernel-pgo.py" \
        --profile-prefix "${BASELINE_DIR}/kernel/kernel" \
        --linux-dir "${ROOTDIR}/linux-${LINUX_VERSION}" \
        --output-dir "${CONFIG_DIR}"

    MERGED_CONFIG=${CONFIG_DIR}/pgo-kernel.merged.config
    LAYOUT_DECISION_FILE=${CONFIG_DIR}/pgo-layout-decision.env
    compose_kernel_config_fragment "${MERGED_CONFIG}" \
        "${PGO_BASE_CONFIG_FRAGMENT}" \
        "${CONFIG_DIR}/pgo-kernel.config"

    echo "BUILD: kernel PGO cycle step 3/3 - PGO rebuild with generated config fragment"
    build_candidate_kernel "config-only" "none" "" "" "${MERGED_CONFIG}" \
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
        run_logged "generate syscall prune table" "${ROOTDIR}/scripts/generate-syscall-prune-table.py" \
            --syscall-report "${CONFIG_DIR}/syscalls.txt" \
            --syscall-table "${ROOTDIR}/linux-${LINUX_VERSION}/arch/arm/tools/syscall.tbl" \
            --output-table "${SYSCALL_TABLE_PATCH}"

        build_candidate_kernel "syscall-prune" "none" "" "${SYSCALL_TABLE_PATCH}" "${MERGED_CONFIG}" \
            "${CYCLE_DIR}/syscall-prune" "${SYSCALL_SNAP}"
        SYSCALL_SIZE=$(sed -n 's/^linux_axf_bytes=//p' "${SYSCALL_SNAP}/result.txt")
        SYSCALL_SIZE=${SYSCALL_SIZE:-0}
        SYSCALL_BOOT_MS=$(read_boot_metric "${SYSCALL_SNAP}/result.txt" "shell_ready_ms")
        append_candidate_summary "${SUMMARY_FILE}" "syscall-prune" "${SYSCALL_SNAP}/result.txt"
    else
        echo "PGO: skipping syscall-prune candidate: no syscalls detected (set QEMU_LOG=exec,cpu,in_asm to enable)"
    fi

    ORDER_SIZE=0
    ORDER_BOOT_MS=0
    ORDER_RESIDENT=0
    ORDER_INIT=0
    ORDER_FULL_SIZE=0
    ORDER_FULL_BOOT_MS=0
    ORDER_FULL_RESIDENT=0
    ORDER_FULL_INIT=0
    if [ -f "${LAYOUT_DECISION_FILE}" ]; then
        # Generated by analyze-kernel-pgo.py with simple shell-safe key=value lines.
        . "${LAYOUT_DECISION_FILE}"
    fi

    if [ "${layout_ordering_recommended:-no}" = "yes" ]; then
        build_candidate_kernel "llvm-order" "llvm-order-use" "${BASELINE_DIR}/kernel/kernel_ld_profile.txt" \
            "" "${MERGED_CONFIG}" "${CYCLE_DIR}/llvm-order" "${ORDER_SNAP}"
        ORDER_SIZE=$(sed -n 's/^linux_axf_bytes=//p' "${ORDER_SNAP}/result.txt")
        ORDER_SIZE=${ORDER_SIZE:-0}
        ORDER_BOOT_MS=$(read_boot_metric "${ORDER_SNAP}/result.txt" "shell_ready_ms")
        ORDER_RESIDENT=$(read_boot_metric "${ORDER_SNAP}/result.txt" "kernel_resident_bytes")
        ORDER_INIT=$(read_boot_metric "${ORDER_SNAP}/result.txt" "kernel_init_bytes")
        append_candidate_summary "${SUMMARY_FILE}" "llvm-order" "${ORDER_SNAP}/result.txt"

        if [ -f "${BASELINE_DIR}/kernel/kernel_ld_profile_full.txt" ]; then
            build_candidate_kernel "llvm-order-full" "llvm-order-use" \
                "${BASELINE_DIR}/kernel/kernel_ld_profile_full.txt" \
                "" "${MERGED_CONFIG}" "${CYCLE_DIR}/llvm-order-full" "${ORDER_FULL_SNAP}"
            ORDER_FULL_SIZE=$(sed -n 's/^linux_axf_bytes=//p' "${ORDER_FULL_SNAP}/result.txt")
            ORDER_FULL_SIZE=${ORDER_FULL_SIZE:-0}
            ORDER_FULL_BOOT_MS=$(read_boot_metric "${ORDER_FULL_SNAP}/result.txt" "shell_ready_ms")
            ORDER_FULL_RESIDENT=$(read_boot_metric "${ORDER_FULL_SNAP}/result.txt" "kernel_resident_bytes")
            ORDER_FULL_INIT=$(read_boot_metric "${ORDER_FULL_SNAP}/result.txt" "kernel_init_bytes")
            append_candidate_summary "${SUMMARY_FILE}" "llvm-order-full" "${ORDER_FULL_SNAP}/result.txt"
        fi
    else
        echo "PGO: skipping llvm-order candidate: ${layout_ordering_reason:-trace too diffuse}"
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

    if [ "${ORDER_SIZE}" -gt 0 ] && boot_not_regressed "${BASELINE_BOOT_MS}" "${ORDER_BOOT_MS}" &&
        [ "${ORDER_SIZE}" -lt "${BEST_SIZE}" ]; then
        BEST_NAME=llvm-order
        BEST_SNAP=${ORDER_SNAP}
        BEST_SIZE=${ORDER_SIZE}
        BEST_BOOT_MS=${ORDER_BOOT_MS}
        BEST_RESIDENT_BYTES=${ORDER_RESIDENT}
        BEST_INIT_BYTES=${ORDER_INIT}
    fi

    if [ "${ORDER_FULL_SIZE}" -gt 0 ] && boot_not_regressed "${BASELINE_BOOT_MS}" "${ORDER_FULL_BOOT_MS}" &&
        [ "${ORDER_FULL_SIZE}" -lt "${BEST_SIZE}" ]; then
        BEST_NAME=llvm-order-full
        BEST_SNAP=${ORDER_FULL_SNAP}
        BEST_SIZE=${ORDER_FULL_SIZE}
        BEST_BOOT_MS=${ORDER_FULL_BOOT_MS}
        BEST_RESIDENT_BYTES=${ORDER_FULL_RESIDENT}
        BEST_INIT_BYTES=${ORDER_FULL_INIT}
    fi

    if [ "${BEST_NAME}" = "baseline" ]; then
        echo "PGO: no candidate improved linux.axf size without regressing shell_ready_ms; keeping baseline"
        echo "  baseline:      ${BASELINE_SIZE} bytes, ${BASELINE_BOOT_MS} ms"
        echo "  config-only:   ${CONFIG_SIZE} bytes, ${CONFIG_BOOT_MS} ms"
        echo "  syscall-prune: ${SYSCALL_SIZE} bytes, ${SYSCALL_BOOT_MS} ms"
        echo "  llvm-order:    ${ORDER_SIZE} bytes, ${ORDER_BOOT_MS} ms"
        echo "  llvm-order-full: ${ORDER_FULL_SIZE} bytes, ${ORDER_FULL_BOOT_MS} ms"
    fi

    BEST_ORDER_NAME=
    BEST_ORDER_SNAP=
    BEST_ORDER_FILE=
    BEST_ORDER_SIZE=0
    BEST_ORDER_BOOT_MS=0
    BEST_ORDER_SIZE_DELTA=0
    BEST_ORDER_BOOT_DELTA=0
    BEST_ORDER_RESIDENT_DELTA=0
    BEST_ORDER_INIT_BYTES=0
    BEST_ORDER_INIT_DELTA=0
    if [ "${ORDER_SIZE}" -gt 0 ]; then
        BEST_ORDER_NAME=llvm-order
        BEST_ORDER_SNAP=${ORDER_SNAP}
        BEST_ORDER_FILE=${BASELINE_DIR}/kernel/kernel_ld_profile.txt
        BEST_ORDER_SIZE=${ORDER_SIZE}
        BEST_ORDER_BOOT_MS=${ORDER_BOOT_MS}
        BEST_ORDER_INIT_BYTES=${ORDER_INIT}
    fi
    if [ "${ORDER_FULL_SIZE}" -gt 0 ] &&
        { [ "${ORDER_SIZE}" -eq 0 ] || [ "${ORDER_FULL_SIZE}" -lt "${ORDER_SIZE}" ]; }; then
        BEST_ORDER_NAME=llvm-order-full
        BEST_ORDER_SNAP=${ORDER_FULL_SNAP}
        BEST_ORDER_FILE=${BASELINE_DIR}/kernel/kernel_ld_profile_full.txt
        BEST_ORDER_SIZE=${ORDER_FULL_SIZE}
        BEST_ORDER_BOOT_MS=${ORDER_FULL_BOOT_MS}
        BEST_ORDER_INIT_BYTES=${ORDER_FULL_INIT}
    fi

    if [ -n "${BEST_ORDER_NAME}" ]; then
        BEST_ORDER_SIZE_DELTA=$((BEST_ORDER_SIZE - BEST_SIZE))
        BEST_ORDER_BOOT_DELTA=$((BEST_ORDER_BOOT_MS - BEST_BOOT_MS))
        BEST_ORDER_RESIDENT_DELTA=$(( $(read_boot_metric "${BEST_ORDER_SNAP}/result.txt" "kernel_resident_bytes") - BEST_RESIDENT_BYTES ))
        BEST_ORDER_INIT_DELTA=$((BEST_ORDER_INIT_BYTES - BEST_INIT_BYTES))
        run_logged "compare ordered kernel layout" "${ROOTDIR}/scripts/compare-kernel-layout.py" \
            --baseline-vmlinux "${BASELINE_SNAP}/vmlinux" \
            --candidate-vmlinux "${BEST_ORDER_SNAP}/vmlinux" \
            --hits "${BASELINE_DIR}/kernel/kernel_hits.txt" \
            --order-file "${BEST_ORDER_FILE}" \
            --output-dir "${CYCLE_DIR}/layout"
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
        echo "best_order_candidate=${BEST_ORDER_NAME:-none}"
        echo "best_order_linux_axf_bytes=${BEST_ORDER_SIZE:-0}"
        echo "best_order_shell_ready_ms=${BEST_ORDER_BOOT_MS:-0}"
        echo "best_order_file=${BEST_ORDER_FILE:-none}"
        echo "best_order_size_delta_vs_selected=${BEST_ORDER_SIZE_DELTA:-0}"
        echo "best_order_shell_delta_vs_selected=${BEST_ORDER_BOOT_DELTA:-0}"
        echo "best_order_resident_delta_vs_selected=${BEST_ORDER_RESIDENT_DELTA:-0}"
        echo "best_order_init_bytes=${BEST_ORDER_INIT_BYTES:-0}"
        echo "best_order_init_delta_vs_selected=${BEST_ORDER_INIT_DELTA:-0}"
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
    append_candidate_decision "${DECISION_FILE}" "llvm-order" "${ORDER_SIZE}" "${ORDER_BOOT_MS}" \
        "${BEST_NAME}" "${BEST_SIZE}" "${BEST_BOOT_MS}" "${BASELINE_BOOT_MS}" \
        "${ORDER_RESIDENT}" "${BEST_RESIDENT_BYTES}" "${ORDER_INIT}" "${BEST_INIT_BYTES}"
    append_candidate_decision "${DECISION_FILE}" "llvm-order-full" "${ORDER_FULL_SIZE}" "${ORDER_FULL_BOOT_MS}" \
        "${BEST_NAME}" "${BEST_SIZE}" "${BEST_BOOT_MS}" "${BASELINE_BOOT_MS}" \
        "${ORDER_FULL_RESIDENT}" "${BEST_RESIDENT_BYTES}" "${ORDER_FULL_INIT}" "${BEST_INIT_BYTES}"

    BASELINE_RESIDENT_BYTES=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "kernel_resident_bytes")
    BASELINE_INIT_BYTES=$(read_boot_metric "${BASELINE_SNAP}/result.txt" "kernel_init_bytes")
    SELECTED_SIZE_DELTA_VS_BASELINE=$((BEST_SIZE - BASELINE_SIZE))
    SELECTED_BOOT_DELTA_VS_BASELINE=$((BEST_BOOT_MS - BASELINE_BOOT_MS))
    SELECTED_RESIDENT_DELTA_VS_BASELINE=$((BEST_RESIDENT_BYTES - BASELINE_RESIDENT_BYTES))
    SELECTED_INIT_DELTA_VS_BASELINE=$((BEST_INIT_BYTES - BASELINE_INIT_BYTES))
    TRACE_LAYOUT_GOAL_MET=no
    BEST_ORDER_SIZE_DELTA_VS_BASELINE=0
    BEST_ORDER_BOOT_DELTA_VS_BASELINE=0
    BEST_ORDER_RESIDENT_DELTA_VS_BASELINE=0
    BEST_ORDER_INIT_DELTA_VS_BASELINE=0
    if [ -n "${BEST_ORDER_NAME}" ]; then
        BEST_ORDER_RESIDENT_BYTES=$(read_boot_metric "${BEST_ORDER_SNAP}/result.txt" "kernel_resident_bytes")
        BEST_ORDER_SIZE_DELTA_VS_BASELINE=$((BEST_ORDER_SIZE - BASELINE_SIZE))
        BEST_ORDER_BOOT_DELTA_VS_BASELINE=$((BEST_ORDER_BOOT_MS - BASELINE_BOOT_MS))
        BEST_ORDER_RESIDENT_DELTA_VS_BASELINE=$((BEST_ORDER_RESIDENT_BYTES - BASELINE_RESIDENT_BYTES))
        BEST_ORDER_INIT_DELTA_VS_BASELINE=$((BEST_ORDER_INIT_BYTES - BASELINE_INIT_BYTES))
        if [ "${BEST_ORDER_SIZE}" -le "${BEST_SIZE}" ] &&
            [ "${BEST_ORDER_RESIDENT_BYTES}" -le "${BEST_RESIDENT_BYTES}" ] &&
            [ "${BEST_ORDER_INIT_BYTES}" -le "${BEST_INIT_BYTES}" ] &&
            boot_not_regressed "${BASELINE_BOOT_MS}" "${BEST_ORDER_BOOT_MS}"; then
            TRACE_LAYOUT_GOAL_MET=yes
        fi
    fi

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
        echo "trace_layout_goal_met=${TRACE_LAYOUT_GOAL_MET}"
        echo "best_order_candidate=${BEST_ORDER_NAME:-none}"
        echo "best_order_size_delta_vs_baseline=${BEST_ORDER_SIZE_DELTA_VS_BASELINE}"
        echo "best_order_shell_delta_vs_baseline=${BEST_ORDER_BOOT_DELTA_VS_BASELINE}"
        echo "best_order_resident_delta_vs_baseline=${BEST_ORDER_RESIDENT_DELTA_VS_BASELINE}"
        echo "best_order_init_delta_vs_baseline=${BEST_ORDER_INIT_DELTA_VS_BASELINE}"
        echo "best_order_size_delta_vs_selected=${BEST_ORDER_SIZE_DELTA:-0}"
        echo "best_order_shell_delta_vs_selected=${BEST_ORDER_BOOT_DELTA:-0}"
        echo "best_order_resident_delta_vs_selected=${BEST_ORDER_RESIDENT_DELTA:-0}"
        echo "best_order_init_delta_vs_selected=${BEST_ORDER_INIT_DELTA:-0}"
        if [ "${TRACE_LAYOUT_GOAL_MET}" = "yes" ]; then
            echo "best_order_competitive_on_systematic_goal=yes"
        else
            echo "best_order_competitive_on_systematic_goal=no"
        fi
    } >"${OBJECTIVE_SCORECARD}"

    write_final_summary "${FINAL_SUMMARY}" "${SUMMARY_FILE}" "${DECISION_FILE}" "${BEST_NAME}" \
        "${BASELINE_SIZE}" "${BEST_SIZE}" "${BASELINE_BOOT_MS}" "${BEST_BOOT_MS}" \
        "${LAYOUT_DECISION_FILE}" "${BASELINE_DIR}/kernel" \
        "${BEST_ORDER_NAME}" "${BEST_ORDER_SIZE}" "${BEST_ORDER_BOOT_MS}" "${BEST_ORDER_FILE}" \
        "${BEST_ORDER_SIZE_DELTA}" "${BEST_ORDER_BOOT_DELTA}" "${BEST_ORDER_RESIDENT_DELTA}" \
        "${BEST_ORDER_INIT_BYTES}" "${BEST_ORDER_INIT_DELTA}" "${OBJECTIVE_SCORECARD}"

    run_logged "collect final kernel profile" "${ROOTDIR}/scripts/collect-kernel-profile.sh" \
        "${ROOTDIR}/bootwrapper/linux.axf" \
        "${ROOTDIR}/linux-${LINUX_VERSION}/vmlinux" \
        "${FINAL_DIR}/kernel"
    validate_kernel_image "${FINAL_DIR}/validation"

    # Do not stamp linux/bootwrapper as the default build outputs here.
    # This stage may restore an experimental or PGO-tuned image, and a
    # later plain ./build.sh must rebuild the standard kernel path.
}

# QEMU's Cortex-M machine models lack the direct kernel/DTB loading
# support available on full ARM platforms.  A small boot wrapper is
# required to supply reset vectors and transfer control to the kernel.
# The ARM-software/bootwrapper repository (cortex-m-linux branch)
# serves this purpose; it is patched below to reference the MPS2-AN386
# DTB and the correct SSRAM load address (0x21000000).
build_bootwrapper() {
    echo "BUILD: building ARM CORTEX boot wrapper"

    if [ ! -d bootwrapper ]; then
        run_logged "clone bootwrapper" git clone --depth 1 --single-branch https://github.com/ARM-software/bootwrapper.git -b cortex-m-linux
    fi

    cd bootwrapper
    cp ../linux-${LINUX_VERSION}/arch/arm/boot/Image .
    # Linux 7.0 does not ship an AN386 DTS; the AN385 DTB is compatible
    # because both FPGA images share the same peripheral and memory map.
    cp ../linux-${LINUX_VERSION}/arch/arm/boot/dts/arm/mps2-an385.dtb mps2.dtb
    sed -i -e 's/mps2-an399.dtb/mps2.dtb/' -e 's/mps2-an385.dtb/mps2.dtb/' Makefile
    sed -i 's/0x60000000/0x21000000/' Makefile
    sed -i 's/. = PHYS_OFFSET;/. = 0x0;/' linux.lds.S

    run_logged "build" make CROSS_COMPILE=${TARGET}- \
        CC="${TOOLCHAIN}/bin/${TARGET}-gcc -mno-fdpic" \
        LD="${TOOLCHAIN}/bin/${TARGET}-ld" \
        AS="${TOOLCHAIN}/bin/${TARGET}-as"

    REPORT_SUBDIR=${KERNEL_REPORT_DIR}/${KERNEL_EXPERIMENT}
    mkdir -p "${REPORT_SUBDIR}"
    run_logged "refresh kernel size report" "${ROOTDIR}/scripts/kernel-size-report.sh" \
        "${ROOTDIR}" "${ROOTDIR}/linux-${LINUX_VERSION}" "${ROOTDIR}/bootwrapper" "${REPORT_SUBDIR}"

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
    rm -rf busybox-${BUSYBOX_VERSION}
    rm -rf bootwrapper
    rm -rf "${TOOLCHAIN}"
    rm -rf "${ROOTFS}"
    rm -rf "${LOGDIR}"
    rm -rf "${STATE_DIR}"
    exit 0
fi

DEFAULT_STAGES="binutils gcc linux_headers uClibc busybox finalize_rootfs linux bootwrapper"
ALL_STAGES="${DEFAULT_STAGES} kernel_pgo_cycle"

if [ "$#" = 0 ]; then
    STAGES="${DEFAULT_STAGES}"
else
    STAGES=""
    for arg in "$@"; do
        case "${arg}" in
        binutils | gcc | linux_headers | uClibc | busybox | finalize_rootfs | linux | bootwrapper | kernel_pgo_cycle)
            STAGES="${STAGES} ${arg}"
            ;;
        *)
            echo "usage: build.sh [clean]"
            echo "       build.sh <stage> [<stage> ...]"
            echo ""
            echo "default stages: ${DEFAULT_STAGES}"
            echo "all stages: ${ALL_STAGES}"
            exit 1
            ;;
        esac
    done
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
    mark_stage_complete "${stage}"
done

exit 0
