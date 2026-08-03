# Obisan

## Raspberry Pi builds

The backend can be cross-compiled for Raspberry Pi from a Linux host.

For a 64-bit Raspberry Pi OS, install an ARM64 cross toolchain and target
development libraries, then build:

```sh
sudo apt install gcc-aarch64-linux-gnu
nimble prod_arm64
```

The backend binary is written to `bin/obisan-linux-arm64`.

For a 32-bit Raspberry Pi OS, install the ARMv7 hard-float cross toolchain and
build:

```sh
sudo apt install gcc-arm-linux-gnueabihf
nimble prod_armv7
```

The backend binary is written to `bin/obisan-linux-armv7`.

The app also links against system libraries such as OpenSSL, SQLite, LMDB, and
libatomic depending on the target image and installed Nim packages. If the
cross-linker reports missing target libraries, install the corresponding
`:arm64` or `:armhf` development package, or build directly on the Raspberry Pi
with:

```sh
nimble prod
```

### Fedora hosts

Fedora's cross GCC packages may install the compiler before the target glibc
sysroot is populated. If `nimble prod_arm64` fails with an error like:

```text
fatal error: stdint.h: No such file or directory
```

install the Fedora-versioned aarch64 glibc sysroot package:

```sh
sudo dnf install gcc-aarch64-linux-gnu "sysroot-aarch64-fc$(rpm -E %fedora)-glibc"
nimble prod_arm64
```

You can confirm the sysroot path with:

```sh
aarch64-linux-gnu-gcc -print-sysroot
find "$(aarch64-linux-gnu-gcc -print-sysroot)" -name stdint.h
```

If the build gets past libc headers and then fails on `-lssl`, `-lcrypto`,
`-lsqlite3`, `-llmdb`, or `-latomic`, the remaining missing piece is target
architecture libraries in the sysroot. For `-lcrypto`, install ARM64 OpenSSL
development files into the sysroot:

```sh
SYSROOT=/usr/aarch64-redhat-linux/sys-root/fc$(rpm -E %fedora)
sudo dnf --installroot="$SYSROOT" --forcearch=aarch64 --releasever="$(rpm -E %fedora)" install openssl-devel
```

If later link steps report SQLite or LMDB target libraries, install those the
same way:

```sh
sudo dnf --installroot="$SYSROOT" --forcearch=aarch64 --releasever="$(rpm -E %fedora)" install sqlite-devel lmdb-libs
```

If this gets too involved, building directly on the Raspberry Pi with
`nimble prod` is usually simpler than maintaining a complete Fedora cross
sysroot for all native dependencies.
