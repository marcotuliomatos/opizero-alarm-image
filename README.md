# opizero-alarm-image

Build a bootable Arch Linux ARM image for the Orange Pi Zero.

The script builds U-Boot, creates an ext4 SD card image, installs the Arch Linux ARM armv7 root filesystem, and prepare onboard XR819 Wi-Fi support.

## Requirements

Arch Linux host packages:

```sh
sudo pacman -S --needed \
  arch-install-scripts \
  qemu-user-static \
  qemu-user-static-binfmt \
  uboot-tools \
  dtc \
  curl \
  git \
  libarchive \
  xz \
  dosfstools \
  e2fsprogs \
  util-linux \
  cloud-guest-utils
```

For U-Boot, install an ARM cross compiler that provides the configured prefix. The default is:

```sh
arm-none-eabi-
```

## Usage

```sh
./opizero-alarm-image.sh build
```

The default output is:

```text
ArchLinuxARM-OrangePiZero.img
ArchLinuxARM-OrangePiZero.img.xz
```

Write the image to an SD card:

```sh
./opizero-alarm-image.sh install /dev/sdX
```

The install command overwrites the target device and asks for confirmation.

## Common options

Build without onboard Wi-Fi support:

```sh
./opizero-alarm-image.sh build --no-wifi
```

Use a different locale:

```sh
./opizero-alarm-image.sh build --locale pt_BR.UTF-8
```

Defer rootfs preparation to the Orange Pi Zero first boot:

```sh
./opizero-alarm-image.sh build --prepare-rootfs-on-opi
```

Use a different image path or size:

```sh
./opizero-alarm-image.sh build \
  --image ArchLinuxARM-OrangePiZero.img \
  --image-size 3G
```

Open a serial console:

```sh
./opizero-alarm-image.sh serial --serial-device /dev/ttyUSB0
```

## Cache

Downloads and cloned repositories are stored under:

```text
${XDG_CACHE_HOME:-$HOME/.cache}/archlinuxarm-orangepi-zero
```

Remove generated images and rebuildable cache entries:

```sh
./opizero-alarm-image.sh clean-cache
```

Remove the full cache, including downloaded tarballs and cloned repositories:

```sh
./opizero-alarm-image.sh clean-cache --full
```

## Wi-Fi

Onboard XR819 Wi-Fi is enabled by default. The script copies XR819 firmware and installs the xradio driver source as a DKMS module.

Use `--no-wifi` to leave both out of the image.

## Known issues

- No TV out/CVBS support.
