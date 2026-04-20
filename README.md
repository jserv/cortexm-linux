# Linux on Arm Cortex-M

A testbed for running and experimenting with Linux on Arm Cortex-M microcontrollers.
Cortex-M cores have no MMU, so the kernel runs in nommu mode and userspace binaries use the FLAT executable format.
The entire system -- cross-toolchain, C library, userspace, kernel, and boot wrapper --
is built from source by a single shell script and boots under QEMU.

Use this project to study how Linux behaves without an MMU,
to prototype kernel patches for Cortex-M,
or to experiment with minimal embedded Linux configurations on a microcontroller-class CPU.

## Prerequisites

A Linux host is required.  The build downloads and compiles an entire
cross-toolchain, C library, BusyBox, and kernel from source, so expect
significant build time and several gigabytes of disk space.

Install the host packages needed for a cross-toolchain build (Debian/Ubuntu):

```shell
$ sudo apt-get install build-essential bison flex texinfo \
    libncurses-dev wget git qemu-system-arm
```

## Quick start

```shell
$ ./build.sh
$ qemu-system-arm -M mps2-an386 -cpu cortex-m4 -nographic \
    -kernel bootwrapper/linux.axf
```

Exit QEMU with `Ctrl-a x`.

## What gets built

The build runs in a fixed order, downloading sources automatically:

| Step | Component | Version | Purpose |
|------|-----------|---------|---------|
| 1 | binutils | 2.46.0 | Assembler, linker (with Thumb-only patch) |
| 2 | GCC | 15.2.0 | C-only cross-compiler, first-pass |
| 3 | Linux headers | 7.0 | Kernel headers for C library build |
| 4 | uClibc-ng | 1.0.57 | Lightweight C library for nommu targets |
| 5 | elf2flt | 2024.05 | ELF-to-FLAT converter for nommu binaries |
| 6 | BusyBox | 1.37.0 | Minimal userspace (shell, coreutils) |
| 7 | Linux kernel | 7.0 | Kernel with embedded initramfs |
| 8 | Boot wrapper | -- | Reset vectors for QEMU Cortex-M emulation |

Individual stages can be re-run selectively:
```shell
$ ./build.sh busybox finalize_rootfs linux bootwrapper
```

Run `./build.sh clean` to remove build artifacts while keeping downloaded sources.

## Target platform

- CPU: Arm Cortex-M4 (ARMv7E-M, Thumb-2 only, no Arm-mode instructions)
- Machine: MPS2-AN386 (QEMU emulation of the ARM MPS2 FPGA board)
- No MMU -- the kernel uses `CONFIG_MMU=n` with a bootwrapper-loaded image
- Binaries are FLAT format, produced by `elf2flt` from ELF objects

QEMU's MPS2-AN386 model does not provide the normal ARM Linux boot path,
so this project uses a boot wrapper (from the `cortex-m-linux` branch of ARM-software/bootwrapper)
that supplies the Cortex-M vector table and jumps to the kernel at `0x21000000`.

## Experiments you can try
- Adjust kernel configs to measure the size floor for a bootable Cortex-M Linux system.
- Add or remove BusyBox applets and observe the FLAT binary size impact.
- Write small C programs, cross-compile them with the toolchain,
  and drop them into the initramfs to see how nommu affects process behavior
  (traditional `fork` is unavailable; programs use `vfork` or,
  where the C library provides it, `posix_spawn`).
- Test newer kernel versions for Cortex-M support regressions.

## License

Build scripts are released under the MIT license.
See `LICENSE` for details.
Each upstream component carries its own license.
