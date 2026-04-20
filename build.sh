#!/bin/sh

# Cross-build a minimal Linux system for ARM Cortex-M4 (MPS2-AN386)
#
# This script produces a self-contained, bootable Linux image targeting the Arm
# MPS2-AN386 FPGA platform (Cortex-M4, no MMU, Thumb-2 only).
# It builds a first-pass GCC cross-compiler (C only), uClibc-ng as C library,
# BusyBox for a minimal userspace, and a Linux kernel with embedded initramfs.

set -e

CPU=arm
TARGET=arm-uclinuxeabi
FLAVOR=cortexm-flt

BINUTILS_VERSION=2.46.0
GCC_VERSION=15.2.0
ELF2FLT_VERSION=2024.05
UCLIBC_NG_VERSION=1.0.57
BUSYBOX_VERSION=1.37.0
LINUX_VERSION=7.0

BINUTILS_URL=https://ftp.gnu.org/gnu/binutils/binutils-${BINUTILS_VERSION}.tar.xz
GCC_URL=https://ftp.gnu.org/gnu/gcc/gcc-${GCC_VERSION}/gcc-${GCC_VERSION}.tar.xz
UCLIBC_NG_URL=https://downloads.uclibc-ng.org/releases/${UCLIBC_NG_VERSION}/uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz
BUSYBOX_URL=https://busybox.net/downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
ELF2FLT_URL=https://github.com/uclinux-dev/elf2flt/archive/refs/tags/v${ELF2FLT_VERSION}.tar.gz
LINUX_URL=https://www.kernel.org/pub/linux/kernel/v7.x/linux-${LINUX_VERSION}.tar.xz

ROOTDIR=$(cd "$(dirname "$0")" >/dev/null && pwd)
cd "${ROOTDIR}"
TOOLCHAIN=${ROOTDIR}/toolchain
ROOTFS=${ROOTDIR}/rootfs

NCPU=$(grep -c processor /proc/cpuinfo 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 1)

PATH=${TOOLCHAIN}/bin:${PATH}

# SHA256 checksums for downloaded source packages.
# Update these when bumping component versions.
# To populate missing checksums: sha256sum downloads/*
CHECKSUM_binutils=""
CHECKSUM_gcc=""
CHECKSUM_uclibc=""
CHECKSUM_busybox="busybox-${BUSYBOX_VERSION}.tar.bz2=3311dff32e746499f4df0d5df04d7eb396382d7e108bb9250e7b519b837043a4"
CHECKSUM_elf2flt=""
CHECKSUM_linux="linux-${LINUX_VERSION}.tar.xz=bb7f6d80b387c757b7d14bb93028fcb90f793c5c0d367736ee815a100b3891f0"

verify_checksum() {
    FILE=$1
    EXPECTED=$2
    if [ -z "${EXPECTED}" ]; then
        echo "WARNING: no checksum defined for ${FILE}"
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
        wget -P downloads "${URL}"
    fi
    if [ -n "${CHECKSUM_VAR}" ]; then
        EXPECTED=$(echo "${CHECKSUM_VAR}" | cut -d= -f2)
        verify_checksum "${PACKAGE}" "${EXPECTED}"
    fi
}

build_binutils() {
    echo "BUILD: building binutils-${BINUTILS_VERSION}"
    fetch_file ${BINUTILS_URL} "${CHECKSUM_binutils}"

    tar xvJf downloads/binutils-${BINUTILS_VERSION}.tar.xz
    cd binutils-${BINUTILS_VERSION}

    patch -p1 -R <../patches/0001-arm-Do-not-insert-stubs-needing-Arm-code-on-Thumb-on.patch

    ./configure --target=${TARGET} --prefix=${TOOLCHAIN}
    make -j${NCPU}
    make install
    cd ../
}

build_gcc() {
    echo "BUILD: building gcc-${GCC_VERSION}"
    fetch_file ${GCC_URL} "${CHECKSUM_gcc}"

    tar xvJf downloads/gcc-${GCC_VERSION}.tar.xz
    cd gcc-${GCC_VERSION}
    contrib/download_prerequisites
    mkdir ${TARGET}
    cd ${TARGET}
    ../configure --target=${TARGET} \
        --prefix=${TOOLCHAIN} \
        --enable-multilib \
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
        --enable-languages=c
    make -j${NCPU}
    make install
    cd ../..
}

build_linux_headers() {
    echo "BUILD: building linux-${LINUX_VERSION} headers"
    fetch_file ${LINUX_URL} "${CHECKSUM_linux}"

    tar xvJf downloads/linux-${LINUX_VERSION}.tar.xz
    cd linux-${LINUX_VERSION}
    make ARCH=${CPU} defconfig
    make ARCH=${CPU} headers_install
    cp -a usr/include ${TOOLCHAIN}/${TARGET}/
    cd ../
}

build_uClibc() {
    echo "BUILD: building uClibc-${UCLIBC_NG_VERSION}"
    fetch_file ${UCLIBC_NG_URL} "${CHECKSUM_uclibc}"

    tar xvJf downloads/uClibc-ng-${UCLIBC_NG_VERSION}.tar.xz
    cp configs/uClibc-ng-${UCLIBC_NG_VERSION}-${FLAVOR}.config uClibc-ng-${UCLIBC_NG_VERSION}/.config
    cd uClibc-ng-${UCLIBC_NG_VERSION}

    TOOLCHAIN_ESCAPED=$(echo ${TOOLCHAIN}/${TARGET} | sed 's/\//\\\//g')
    sed -i "s/^KERNEL_HEADERS=.*\$/KERNEL_HEADERS=\"${TOOLCHAIN_ESCAPED}\/include\"/" .config
    sed -i "s/^RUNTIME_PREFIX=.*\$/RUNTIME_PREFIX=\"${TOOLCHAIN_ESCAPED}\"/" .config
    sed -i "s/^DEVEL_PREFIX=.*\$/DEVEL_PREFIX=\"${TOOLCHAIN_ESCAPED}\"/" .config

    make oldconfig CROSS=${TARGET}- TARGET_ARCH=${CPU} </dev/null
    make -j${NCPU} install CROSS=${TARGET}- TARGET_ARCH=${CPU}
    cd ../
}

build_elf2flt() {
    echo "BUILD: building elf2flt-${ELF2FLT_VERSION}"
    fetch_file ${ELF2FLT_URL} "${CHECKSUM_elf2flt}"

    tar xvzf downloads/v${ELF2FLT_VERSION}.tar.gz
    cd elf2flt-${ELF2FLT_VERSION}

    # Apply elf2flt patches for newer binutils compatibility
    for p in ../patches/0007-*.patch ../patches/0008-*.patch ../patches/0009-*.patch; do
        [ -f "${p}" ] || continue
        if patch -p1 -N --dry-run <"${p}" >/dev/null 2>&1; then
            echo "BUILD: applying $(basename ${p})"
            patch -p1 -N <"${p}"
        elif patch -p1 -R --dry-run <"${p}" >/dev/null 2>&1; then
            echo "BUILD: skipping $(basename ${p}) (already applied)"
        else
            echo "ERROR: failed to apply $(basename ${p})"
            exit 1
        fi
    done

    ./configure --disable-werror \
        --with-binutils-include-dir=${ROOTDIR}/binutils-${BINUTILS_VERSION}/include \
        --with-bfd-include-dir=${ROOTDIR}/binutils-${BINUTILS_VERSION}/bfd \
        --with-libbfd=${ROOTDIR}/binutils-${BINUTILS_VERSION}/bfd/.libs/libbfd.a \
        --with-libiberty=${ROOTDIR}/binutils-${BINUTILS_VERSION}/libiberty/libiberty.a \
        --prefix=${TOOLCHAIN} \
        --target=${TARGET}
    make
    make install
    cd ../
}

build_busybox() {
    echo "BUILD: building busybox-${BUSYBOX_VERSION}"
    fetch_file ${BUSYBOX_URL} "${CHECKSUM_busybox}"

    tar xvjf downloads/busybox-${BUSYBOX_VERSION}.tar.bz2
    cp configs/busybox-${BUSYBOX_VERSION}.config busybox-${BUSYBOX_VERSION}/.config
    cd busybox-${BUSYBOX_VERSION}

    sed -i 's/# CONFIG_NOMMU is not set/CONFIG_NOMMU=y/' .config
    sed -i 's/CONFIG_EXTRA_CFLAGS=""/CONFIG_EXTRA_CFLAGS="-mthumb -march=armv7e-m -ffunction-sections -fdata-sections -fipa-icf"/' .config
    # gc-sections passes through elf2flt wrapper to ld.real; limited effect
    # on FLAT binaries but enables dead-section stripping at ELF stage
    sed -i 's/CONFIG_EXTRA_LDFLAGS=""/CONFIG_EXTRA_LDFLAGS="-Wl,--gc-sections"/' .config

    make oldconfig
    make -j${NCPU} CROSS_COMPILE=${TARGET}- CONFIG_PREFIX=${ROOTFS} install SKIP_STRIP=y
    cd ../
}

build_finalize_rootfs() {
    echo "BUILD: finalizing rootfs"

    mkdir -p ${ROOTFS}/etc
    mkdir -p ${ROOTFS}/proc

    echo "::sysinit:/etc/rc" >${ROOTFS}/etc/inittab
    echo "::respawn:-/bin/sh" >>${ROOTFS}/etc/inittab

    echo "#!/bin/sh" >${ROOTFS}/etc/rc
    echo "mount -t devtmpfs devtmpfs /dev" >>${ROOTFS}/etc/rc
    echo "mount -t proc proc /proc" >>${ROOTFS}/etc/rc
    echo "echo -e \"\\nLinux for Cortex-M\\n\\n\"" >>${ROOTFS}/etc/rc
    chmod 755 ${ROOTFS}/etc/rc

    ln -sf /sbin/init ${ROOTFS}/init
}

build_linux() {
    echo "BUILD: building linux-${LINUX_VERSION}"

    cd linux-${LINUX_VERSION}

    # Apply linux-tiny patches for reduced memory footprint and LTO support
    for p in ../patches/0002-*.patch ../patches/0003-*.patch ../patches/0004-*.patch ../patches/0005-*.patch ../patches/0006-*.patch; do
        [ -f "${p}" ] || continue
        if patch -p1 -N --dry-run <"${p}" >/dev/null 2>&1; then
            echo "BUILD: applying $(basename ${p})"
            patch -p1 -N <"${p}"
        elif patch -p1 -R --dry-run <"${p}" >/dev/null 2>&1; then
            echo "BUILD: skipping $(basename ${p}) (already applied)"
        else
            echo "ERROR: failed to apply $(basename ${p})"
            exit 1
        fi
    done

    make ARCH=${CPU} CROSS_COMPILE=${TARGET}- mps2_defconfig

    sed -i "s/# CONFIG_BLK_DEV_INITRD is not set/CONFIG_BLK_DEV_INITRD=y/" .config
    sed -i "/CONFIG_INITRAMFS_SOURCE=/d" .config
    echo "CONFIG_INITRAMFS_SOURCE=\"${ROOTFS} ${ROOTDIR}/configs/rootfs.dev\"" >>.config
    echo "CONFIG_INITRAMFS_COMPRESSION_GZIP=y" >>.config

    # Enable linux-tiny size reductions
    echo "CONFIG_NET_SMALL=y" >>.config
    echo "CONFIG_MAX_SWAPFILES_SHIFT=0" >>.config
    echo "# CONFIG_CRC32_TABLES is not set" >>.config
    echo "CONFIG_PROC_STRIPPED=y" >>.config

    # Enable GCC LTO for whole-kernel optimization
    echo "CONFIG_LTO_GCC=y" >>.config
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

    make ARCH=${CPU} CROSS_COMPILE=${TARGET}- olddefconfig </dev/null

    # Verify critical config options survived olddefconfig resolution
    for opt in "# CONFIG_SYSFS is not set" "CONFIG_BLK_DEV_INITRD=y"; do
        if ! grep -q "^${opt}\$" .config; then
            echo "ERROR: expected '${opt}' in .config after olddefconfig"
            exit 1
        fi
    done

    make -j${NCPU} ARCH=${CPU} CROSS_COMPILE=${TARGET}- KALLSYMS_EXTRA_PASS=1
    cd ../
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
        git clone https://github.com/ARM-software/bootwrapper.git -b cortex-m-linux
    fi

    cd bootwrapper
    cp ../linux-${LINUX_VERSION}/arch/arm/boot/Image .
    # Linux 7.0 does not ship an AN386 DTS; the AN385 DTB is compatible
    # because both FPGA images share the same peripheral and memory map.
    cp ../linux-${LINUX_VERSION}/arch/arm/boot/dts/arm/mps2-an385.dtb mps2.dtb
    sed -i -e 's/mps2-an399.dtb/mps2.dtb/' -e 's/mps2-an385.dtb/mps2.dtb/' Makefile
    sed -i 's/0x60000000/0x21000000/' Makefile
    sed -i 's/. = PHYS_OFFSET;/. = 0x0;/' linux.lds.S

    make CROSS_COMPILE=${TARGET}-

    cd ../
}

#
# Do the real work.
#

if [ "$1" = "clean" ]; then
    rm -rf binutils-${BINUTILS_VERSION}
    rm -rf gcc-${GCC_VERSION}
    rm -rf linux-${LINUX_VERSION}
    rm -rf uClibc-ng-${UCLIBC_NG_VERSION}
    rm -rf elf2flt-${ELF2FLT_VERSION}
    rm -rf busybox-${BUSYBOX_VERSION}
    rm -rf bootwrapper
    rm -rf ${TOOLCHAIN}
    rm -rf ${ROOTFS}
    exit 0
fi

ALL_STAGES="binutils gcc linux_headers uClibc elf2flt busybox finalize_rootfs linux bootwrapper"

if [ "$#" = 0 ]; then
    STAGES="${ALL_STAGES}"
else
    STAGES=""
    for arg in "$@"; do
        case "${arg}" in
        binutils | gcc | linux_headers | uClibc | elf2flt | busybox | finalize_rootfs | linux | bootwrapper)
            STAGES="${STAGES} ${arg}"
            ;;
        *)
            echo "usage: build.sh [clean]"
            echo "       build.sh <stage> [<stage> ...]"
            echo ""
            echo "stages: ${ALL_STAGES}"
            exit 1
            ;;
        esac
    done
fi

for stage in ${STAGES}; do
    # Run each stage in a subshell so a mid-build cd failure
    # does not leave the working directory inside a source tree.
    ( build_${stage} )
done

exit 0
