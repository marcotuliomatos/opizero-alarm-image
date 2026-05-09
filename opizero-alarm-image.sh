#!/usr/bin/env bash
set -euo pipefail

SCRIPT_VERSION="0.1.0"
APP_ID="opizero-alarm-image"

CACHE_DIR=""
BUILD_DIR=""
CLEAN_CACHE_FULL=0
SUDO_KEEPALIVE_PID=""

IMAGE="ArchLinuxARM-OrangePiZero.img"
IMAGE_XZ="${IMAGE}.xz"
IMAGE_SIZE="3G"

MOUNT_POINT=""
SERIAL_DEVICE="/dev/ttyUSB0"

CROSS_COMPILE="arm-none-eabi-"
DEFAULT_SYSTEM_LOCALE="en_US.UTF-8"
SYSTEM_LOCALE=""

ARCH_TARBALL="ArchLinuxARM-armv7-latest.tar.gz"
ARCH_URL="http://os.archlinuxarm.org/os/${ARCH_TARBALL}"

UBOOT_VERSION="2026.01"
UBOOT_TARBALL="u-boot-v${UBOOT_VERSION}.tar.gz"
UBOOT_DIR="u-boot-${UBOOT_VERSION}"
UBOOT_BIN_NAME="u-boot-sunxi-with-spl.bin"
UBOOT_BIN=""
UBOOT_URL="https://github.com/u-boot/u-boot/archive/refs/tags/v${UBOOT_VERSION}.tar.gz"

BOOT_TXT=""
BOOT_SCR=""

XR819_FW_REPO="https://github.com/armbian/firmware.git"
XR819_FW_DIR="armbian-firmware"
XR819_FW_FILES=(
  "boot_xr819.bin"
  "fw_xr819.bin"
  "sdd_xr819.bin"
)

XRADIO_REPO="https://github.com/fifteenhex/xradio.git"
XRADIO_DIR="xradio"

ENABLE_ONBOARD_WIFI=1
PREPARE_ROOTFS_ON_OPI=0
NO_COLOR=0

LOOP_DEV=""
INSTALL_DEVICE=""
INSTALL_RESIZE=1

BLUE=""
GREEN=""
YELLOW=""
RED=""
RESET=""

colors_enabled() {
  [[ "${NO_COLOR}" -eq 0 ]] && [[ -t 1 ]]
}

setup_colors() {
  if colors_enabled; then
    BLUE=$'\033[1;34m'
    GREEN=$'\033[1;32m'
    YELLOW=$'\033[1;33m'
    RED=$'\033[1;31m'
    RESET=$'\033[0m'
  else
    BLUE=""
    GREEN=""
    YELLOW=""
    RED=""
    RESET=""
  fi
}

log() {
  printf '%s::%s %s\n' "${BLUE}" "${RESET}" "$*"
}

success() {
  printf '%s::%s %s\n' "${GREEN}" "${RESET}" "$*"
}

warn() {
  printf '%swarning:%s %s\n' "${YELLOW}" "${RESET}" "$*" >&2
}

die() {
  printf '%serror:%s %s\n' "${RED}" "${RESET}" "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "command not found: $1"
}

detect_host_locale() {
  local locale_value=""

  locale_value="$(locale | sed -n 's/^LANG=//p' | tr -d '"')"

  if [[ -z "${locale_value}" || "${locale_value}" == "C" || "${locale_value}" == "POSIX" ]]; then
    locale_value="${DEFAULT_SYSTEM_LOCALE}"
  fi

  echo "${locale_value}"
}

detect_cache_dir() {
  local cache_home="${XDG_CACHE_HOME:-}"

  if [[ -z "${cache_home}" || "${cache_home}" != /* ]]; then
    cache_home="${HOME}/.cache"
  fi

  echo "${cache_home}/${APP_ID}"
}

ensure_cache_dir() {
  mkdir -p "${CACHE_DIR}"
}

validate_gzip_file() {
  local file="$1"

  [[ -f "${file}" ]] || return 1
  gzip -t "${file}" >/dev/null 2>&1
}

start_sudo_keepalive() {
  sudo -v || die "sudo authentication failed"

  (
    while true; do
      sudo -n -v >/dev/null 2>&1 || exit
      sleep 60
    done
  ) &

  SUDO_KEEPALIVE_PID="$!"
}

stop_sudo_keepalive() {
  set +e

  if [[ -n "${SUDO_KEEPALIVE_PID}" ]]; then
    kill "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    wait "${SUDO_KEEPALIVE_PID}" 2>/dev/null || true
    SUDO_KEEPALIVE_PID=""
  fi

  set -e
}

create_build_dir() {
  BUILD_DIR="$(mktemp -d -t opizero-alarm-image.XXXXXXXXXX)"
  MOUNT_POINT="${BUILD_DIR}/mnt"
  BOOT_TXT="${BUILD_DIR}/boot.txt"
  BOOT_SCR="${BUILD_DIR}/boot.scr"
  UBOOT_BIN="${BUILD_DIR}/${UBOOT_BIN_NAME}"
}

set_image() {
  IMAGE="$1"
  IMAGE_XZ="${IMAGE}.xz"
}

set_uboot_version() {
  UBOOT_VERSION="$1"
  UBOOT_TARBALL="u-boot-v${UBOOT_VERSION}.tar.gz"
  UBOOT_DIR="u-boot-${UBOOT_VERSION}"
  UBOOT_URL="https://github.com/u-boot/u-boot/archive/refs/tags/v${UBOOT_VERSION}.tar.gz"
}

cleanup_mounts() {
  set +e

  if [[ -n "${MOUNT_POINT}" ]]; then
    sudo -n umount -R -l "${MOUNT_POINT}/run" 2>/dev/null || true
    sudo -n umount -R -l "${MOUNT_POINT}/sys" 2>/dev/null || true
    sudo -n umount -R -l "${MOUNT_POINT}/proc" 2>/dev/null || true
    sudo -n umount -R -l "${MOUNT_POINT}/dev" 2>/dev/null || true
    sudo -n umount -R -l "${MOUNT_POINT}" 2>/dev/null || true
  fi

  if [[ -n "${LOOP_DEV}" ]]; then
    sudo -n losetup -d "${LOOP_DEV}" 2>/dev/null || true
    LOOP_DEV=""
  fi

  set -e
}

cleanup_build_dir() {
  set +e

  if [[ -n "${BUILD_DIR}" && "${BUILD_DIR}" != "/" ]]; then
    rm -rf "${BUILD_DIR}" 2>/dev/null || true
    BUILD_DIR=""
    MOUNT_POINT=""
    BOOT_TXT=""
    BOOT_SCR=""
    UBOOT_BIN=""
  fi

  set -e
}

cleanup_all() {
  cleanup_mounts
  cleanup_build_dir
  stop_sudo_keepalive
}

download_cached_file() {
  local url="$1"
  local output="$2"
  local description="$3"
  local tmp_output="${output}.part"

  ensure_cache_dir

  rm -f "${tmp_output}"

  log "Downloading ${description}"
  curl -fL "${url}" -o "${tmp_output}"
  mv -f "${tmp_output}" "${output}"
}

ensure_cached_gzip_file() {
  local url="$1"
  local output="$2"
  local description="$3"

  ensure_cache_dir

  if validate_gzip_file "${output}"; then
    log "Using cached ${description}: ${output}"
    return
  fi

  if [[ -e "${output}" ]]; then
    warn "cached ${description} is invalid; removing it"
    rm -f "${output}" "${output}.part"
  fi

  download_cached_file "${url}" "${output}" "${description}"

  if ! validate_gzip_file "${output}"; then
    rm -f "${output}"
    die "downloaded ${description} is invalid: ${output}"
  fi
}

download_rootfs() {
  ensure_cached_gzip_file \
    "${ARCH_URL}" \
    "${CACHE_DIR}/${ARCH_TARBALL}" \
    "Arch Linux ARM root fs"
}

download_uboot() {
  ensure_cached_gzip_file \
    "${UBOOT_URL}" \
    "${CACHE_DIR}/${UBOOT_TARBALL}" \
    "U-Boot tarball"
}

extract_uboot() {
  ensure_cache_dir

  local tarball="${CACHE_DIR}/${UBOOT_TARBALL}"
  local source_dir="${CACHE_DIR}/${UBOOT_DIR}"

  if [[ -d "${source_dir}" ]]; then
    if [[ -f "${source_dir}/Makefile" && -f "${source_dir}/configs/orangepi_zero_defconfig" ]]; then
      log "Using cached U-Boot: ${source_dir}"
      return
    fi

    warn "cached U-Boot source tree is invalid; removing it"
    rm -rf "${source_dir}"
  fi

  if ! validate_gzip_file "${tarball}"; then
    warn "cached U-Boot tarball is invalid; downloading it again"
    rm -f "${tarball}" "${tarball}.part"
    download_uboot
  fi

  log "Extracting U-Boot"
  if ! tar -C "${CACHE_DIR}" -xf "${tarball}"; then
    warn "cached U-Boot tarball failed during extraction; downloading it again"
    rm -rf "${source_dir}"
    rm -f "${tarball}" "${tarball}.part"
    download_uboot

    log "Extracting U-Boot"
    tar -C "${CACHE_DIR}" -xf "${tarball}"
  fi

  [[ -f "${source_dir}/Makefile" ]] || die "extracted U-Boot source tree is invalid: ${source_dir}"
  [[ -f "${source_dir}/configs/orangepi_zero_defconfig" ]] || die "U-Boot defconfig not found: orangepi_zero_defconfig"
}

validate_xr819_firmware_cache() {
  local repo_dir="$1"
  local fw

  for fw in "${XR819_FW_FILES[@]}"; do
    [[ -f "${repo_dir}/xr819/${fw}" ]] || return 1
  done
}

validate_xradio_cache() {
  local repo_dir="$1"

  [[ -f "${repo_dir}/Makefile" ]]
}

clone_cached_repo() {
  local repo_url="$1"
  local repo_dir="$2"
  local description="$3"
  local validator="${4:-}"
  local tmp_dir="${repo_dir}.part"

  ensure_cache_dir

  if [[ -d "${repo_dir}" ]]; then
    if git -C "${repo_dir}" rev-parse --is-inside-work-tree >/dev/null 2>&1 && \
       { [[ -z "${validator}" ]] || "${validator}" "${repo_dir}"; }; then
      log "Using cached ${description}: ${repo_dir}"
      return
    fi

    warn "cached ${description} is invalid; cloning it again"
    rm -rf "${repo_dir}"
  fi

  rm -rf "${tmp_dir}"

  log "Cloning ${description}"
  git clone --depth=1 "${repo_url}" "${tmp_dir}"

  if [[ -n "${validator}" ]] && ! "${validator}" "${tmp_dir}"; then
    rm -rf "${tmp_dir}"
    die "cloned ${description} is invalid"
  fi

  mv -f "${tmp_dir}" "${repo_dir}"
}

clone_xr819_firmware() {
  clone_cached_repo \
    "${XR819_FW_REPO}" \
    "${CACHE_DIR}/${XR819_FW_DIR}" \
    "Armbian firmware repository" \
    validate_xr819_firmware_cache
}

clone_xradio() {
  clone_cached_repo \
    "${XRADIO_REPO}" \
    "${CACHE_DIR}/${XRADIO_DIR}" \
    "xradio repository" \
    validate_xradio_cache
}

write_boot_txt() {
  log "Creating ${BOOT_TXT}"

  cat > "${BOOT_TXT}" <<'BOOTTXT'
part uuid ${devtype} ${devnum}:${bootpart} uuid

setenv fdtfile sun8i-h2-plus-orangepi-zero.dtb
setenv bootargs console=${console} root=PARTUUID=${uuid} rw rootwait

load ${devtype} ${devnum}:${bootpart} ${kernel_addr_r} /boot/zImage
load ${devtype} ${devnum}:${bootpart} ${fdt_addr_r} /boot/dtbs/${fdtfile}

if load ${devtype} ${devnum}:${bootpart} ${ramdisk_addr_r} /boot/initramfs-linux.img; then
    bootz ${kernel_addr_r} ${ramdisk_addr_r}:${filesize} ${fdt_addr_r}
else
    bootz ${kernel_addr_r} - ${fdt_addr_r}
fi
BOOTTXT
}

build_boot_scr() {
  need_cmd mkimage

  write_boot_txt

  log "Generating ${BOOT_SCR}"
  mkimage \
    -A arm \
    -O linux \
    -T script \
    -C none \
    -n "Orange Pi Zero boot script" \
    -d "${BOOT_TXT}" \
    "${BOOT_SCR}"
}

build_uboot() {
  need_cmd make

  download_uboot
  extract_uboot

  log "Building U-Boot for Orange Pi Zero"
  (
    cd "${CACHE_DIR}/${UBOOT_DIR}"
    make ARCH=arm CROSS_COMPILE="${CROSS_COMPILE}" orangepi_zero_defconfig
    make -j"$(nproc)" ARCH=arm CROSS_COMPILE="${CROSS_COMPILE}"
  )

  cp "${CACHE_DIR}/${UBOOT_DIR}/${UBOOT_BIN_NAME}" "${UBOOT_BIN}"
}

create_empty_image() {
  log "Creating image ${IMAGE} with size ${IMAGE_SIZE}"

  rm -f "${IMAGE}" "${IMAGE_XZ}"
  truncate -s "${IMAGE_SIZE}" "${IMAGE}"

  log "Creating partition table"
  printf 'label: dos\nunit: sectors\n\n%s1 : start=32768, type=83, bootable\n' "${IMAGE}" \
    | sfdisk "${IMAGE}" 2>&1 \
    | sed '/^>>>/d'
}

setup_loop_and_mount() {
  need_cmd losetup
  need_cmd mkfs.ext4

  log "Attaching image to loop device"
  LOOP_DEV="$(sudo losetup --find --show --partscan "${IMAGE}")"
  echo "Loop device: ${LOOP_DEV}"

  sleep 1

  log "Formatting ext4 partition"
  sudo mkfs.ext4 -F "${LOOP_DEV}p1"

  mkdir -p "${MOUNT_POINT}"

  log "Mounting root filesystem at ${MOUNT_POINT}"
  sudo mount "${LOOP_DEV}p1" "${MOUNT_POINT}"
}

clear_mounted_rootfs() {
  [[ -n "${MOUNT_POINT}" ]] || die "internal error: MOUNT_POINT is empty"
  [[ "${MOUNT_POINT}" != "/" ]] || die "internal error: refusing to clear /"

  sudo find "${MOUNT_POINT}" -mindepth 1 -maxdepth 1 -exec rm -rf -- {} +
}

extract_rootfs_into_image() {
  need_cmd bsdtar

  local tarball="${CACHE_DIR}/${ARCH_TARBALL}"

  if ! validate_gzip_file "${tarball}"; then
    warn "cached Arch Linux ARM root fs is invalid; downloading it again"
    rm -f "${tarball}" "${tarball}.part"
    download_rootfs
  fi

  log "Extracting Arch Linux ARM root filesystem"
  if sudo bsdtar -xpf "${tarball}" -C "${MOUNT_POINT}"; then
    return
  fi

  warn "cached Arch Linux ARM root fs failed during extraction; downloading it again"
  clear_mounted_rootfs
  rm -f "${tarball}" "${tarball}.part"
  download_rootfs

  log "Extracting Arch Linux ARM root filesystem"
  sudo bsdtar -xpf "${tarball}" -C "${MOUNT_POINT}"
}

install_boot_files_into_rootfs() {
  log "Installing boot.scr"

  sudo cp "${BOOT_SCR}" "${MOUNT_POINT}/boot.scr"
  sudo mkdir -p "${MOUNT_POINT}/boot"
  sudo cp "${BOOT_SCR}" "${MOUNT_POINT}/boot/boot.scr"
}

configure_base_rootfs() {
  log "Configuring hostname"
  echo alarm | sudo tee "${MOUNT_POINT}/etc/hostname" >/dev/null
}

write_uboot_to_image() {
  [[ -n "${UBOOT_BIN}" ]] || die "internal error: UBOOT_BIN is empty"
  [[ -f "${UBOOT_BIN}" ]] || die "U-Boot binary not found: ${UBOOT_BIN}"

  log "Writing SPL + U-Boot to standard sunxi offset"

  dd if="${UBOOT_BIN}" of="${IMAGE}" bs=1024 seek=8 conv=notrunc,fsync
  sync
}

compress_image() {
  log "Compressing image"
  xz -f -k "${IMAGE}"
}

install_xr819_firmware_into_rootfs() {
  clone_xr819_firmware

  log "Installing XR819 firmware"

  sudo mkdir -p "${MOUNT_POINT}/usr/lib/firmware/xr819"

  for fw in "${XR819_FW_FILES[@]}"; do
    sudo cp "${CACHE_DIR}/${XR819_FW_DIR}/xr819/${fw}" "${MOUNT_POINT}/usr/lib/firmware/xr819/"
  done
}

install_xradio_source_into_rootfs() {
  clone_xradio

  log "Installing xradio source into /usr/src/xradio-git"

  sudo rm -rf "${MOUNT_POINT}/usr/src/xradio-git"
  sudo mkdir -p "${MOUNT_POINT}/usr/src/xradio-git"
  sudo cp -a "${CACHE_DIR}/${XRADIO_DIR}/." "${MOUNT_POINT}/usr/src/xradio-git/"
}

write_xradio_dkms_conf() {
  log "Creating xradio dkms.conf"

  sudo tee "${MOUNT_POINT}/usr/src/xradio-git/dkms.conf" >/dev/null <<'DKMSCONF'
PACKAGE_NAME="xradio"
PACKAGE_VERSION="git"

BUILT_MODULE_NAME[0]="xradio_wlan"
BUILT_MODULE_LOCATION[0]="."
DEST_MODULE_LOCATION[0]="/updates"

AUTOINSTALL="yes"

MAKE[0]="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build modules"
CLEAN="make -C ${kernel_source_dir} M=${dkms_tree}/${PACKAGE_NAME}/${PACKAGE_VERSION}/build clean"
DKMSCONF
}

enable_xradio_module_load() {
  log "Enabling automatic xradio_wlan module loading"

  sudo mkdir -p "${MOUNT_POINT}/etc/modules-load.d"
  echo xradio_wlan | sudo tee "${MOUNT_POINT}/etc/modules-load.d/xradio.conf" >/dev/null
}

prepare_wifi_files() {
  install_xr819_firmware_into_rootfs
  install_xradio_source_into_rootfs
  write_xradio_dkms_conf
  enable_xradio_module_load
}

write_first_boot_setup() {
  log "Installing Orange Pi first-boot rootfs preparation service"

  sudo mkdir -p "${MOUNT_POINT}/usr/local/sbin"
  sudo mkdir -p "${MOUNT_POINT}/etc/systemd/system"
  sudo mkdir -p "${MOUNT_POINT}/etc/systemd/system/multi-user.target.wants"

  sudo tee "${MOUNT_POINT}/usr/local/sbin/opizero-firstboot-setup" >/dev/null <<EOF2
#!/usr/bin/env bash
set -euo pipefail

DONE="/var/lib/opizero-firstboot-setup.done"
LOG="/var/log/opizero-firstboot-setup.log"
SYSTEM_LOCALE="${SYSTEM_LOCALE}"
ENABLE_ONBOARD_WIFI="${ENABLE_ONBOARD_WIFI}"

exec > >(tee -a "\${LOG}") 2>&1

if [[ -e "\${DONE}" ]]; then
  echo ":: First-boot setup already completed"
  exit 0
fi

echo ":: Orange Pi Zero first-boot rootfs preparation started"

disable_pacman_option() {
  local option="\$1"

  if grep -q "^#\${option}" /etc/pacman.conf; then
    sed -i "s/^#\${option}/\${option}/" /etc/pacman.conf
  elif ! grep -q "^\${option}" /etc/pacman.conf; then
    echo "\${option}" >> /etc/pacman.conf
  fi
}

configure_locale() {
  echo ":: Configuring locale: \${SYSTEM_LOCALE}"

  if [[ "\${SYSTEM_LOCALE}" == "C" || "\${SYSTEM_LOCALE}" == "C.UTF-8" || "\${SYSTEM_LOCALE}" == "POSIX" ]]; then
    echo "LANG=\${SYSTEM_LOCALE}" > /etc/locale.conf
    return
  fi

  local entry="\${SYSTEM_LOCALE} UTF-8"

  if ! grep -q "^\${entry}$" /etc/locale.gen; then
    if grep -q "^#\${entry}$" /etc/locale.gen; then
      sed -i "s/^#\${entry}$/\${entry}/" /etc/locale.gen
    else
      echo "\${entry}" >> /etc/locale.gen
    fi
  fi

  locale-gen
  echo "LANG=\${SYSTEM_LOCALE}" > /etc/locale.conf
}

configure_pacman() {
  echo ":: Configuring pacman sandbox and keyring"

  disable_pacman_option DisableSandboxFilesystem
  disable_pacman_option DisableSandboxSyscalls

  pacman-key --init || true
  pacman-key --populate archlinuxarm || true

  pacman -Sy --noconfirm archlinuxarm-keyring || true
  pacman-key --populate archlinuxarm || true
}

install_packages() {
  echo ":: Updating system and installing required packages"

  if [[ "\${ENABLE_ONBOARD_WIFI}" == "1" ]]; then
    pacman -Syu --noconfirm \\
      linux-armv7 \\
      linux-armv7-headers \\
      dkms \\
      base-devel \\
      git \\
      iw \\
      wireless-regdb
  else
    pacman -Syu --noconfirm \\
      linux-armv7 \\
      wireless-regdb
  fi
}

setup_wifi_dkms() {
  if [[ "\${ENABLE_ONBOARD_WIFI}" != "1" ]]; then
    echo ":: Onboard Wi-Fi support disabled"
    return
  fi

  echo ":: Building and installing xradio DKMS module"

  test -d /usr/src/xradio-git

  dkms remove xradio/git --all || true
  dkms add /usr/src/xradio-git
  dkms autoinstall

  depmod -a

  mkdir -p /etc/modules-load.d
  echo xradio_wlan > /etc/modules-load.d/xradio.conf

  if ! find /usr/lib/modules -name 'xradio_wlan.ko*' -print -quit | grep -q .; then
    echo "error: xradio_wlan.ko was not found after DKMS"
    exit 1
  fi
}

configure_pacman
configure_locale
install_packages
setup_wifi_dkms

touch "\${DONE}"

echo ":: First-boot setup completed"
echo ":: Rebooting to use the updated kernel and modules"
systemctl reboot
EOF2

  sudo chmod +x "${MOUNT_POINT}/usr/local/sbin/opizero-firstboot-setup"

  sudo tee "${MOUNT_POINT}/etc/systemd/system/opizero-firstboot-setup.service" >/dev/null <<'SERVICEEOF'
[Unit]
Description=Orange Pi Zero first-boot rootfs preparation
Wants=network-online.target
After=network-online.target
ConditionPathExists=!/var/lib/opizero-firstboot-setup.done

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/opizero-firstboot-setup
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
SERVICEEOF

  sudo ln -sf /etc/systemd/system/opizero-firstboot-setup.service \
    "${MOUNT_POINT}/etc/systemd/system/multi-user.target.wants/opizero-firstboot-setup.service"
}

check_chroot_requirements() {
  [[ -x /usr/bin/qemu-arm-static ]] || die "install qemu user emulation: sudo pacman -S qemu-user-static qemu-user-static-binfmt"
  command -v arch-chroot >/dev/null 2>&1 || die "install arch-chroot: sudo pacman -S arch-install-scripts"
}

mount_chroot_filesystems() {
  log "Mounting pseudo-filesystems for chroot"

  sudo cp /usr/bin/qemu-arm-static "${MOUNT_POINT}/usr/bin/"

  sudo mount --rbind /dev "${MOUNT_POINT}/dev"
  sudo mount --make-rslave "${MOUNT_POINT}/dev"

  sudo mount -t proc proc "${MOUNT_POINT}/proc"
  sudo mount -t sysfs sysfs "${MOUNT_POINT}/sys"
  sudo mount -t tmpfs tmpfs "${MOUNT_POINT}/run"
}

unmount_chroot_filesystems() {
  set +e

  sudo -n umount -R -l "${MOUNT_POINT}/run" 2>/dev/null || true
  sudo -n umount -R -l "${MOUNT_POINT}/sys" 2>/dev/null || true
  sudo -n umount -R -l "${MOUNT_POINT}/proc" 2>/dev/null || true
  sudo -n umount -R -l "${MOUNT_POINT}/dev" 2>/dev/null || true

  sudo rm -f "${MOUNT_POINT}/usr/bin/qemu-arm-static"

  set -e
}

arch_chroot_run() {
  sudo arch-chroot "${MOUNT_POINT}" /usr/bin/env \
    LANG=C.UTF-8 \
    LC_ALL=C.UTF-8 \
    /bin/bash -c "$1"
}

configure_pacman_in_chroot() {
  log "Configuring pacman and keyring inside rootfs"

  arch_chroot_run '
set -e

disable_pacman_option() {
    local option="$1"

    if grep -q "^#${option}" /etc/pacman.conf; then
        sed -i "s/^#${option}/${option}/" /etc/pacman.conf
    elif ! grep -q "^${option}" /etc/pacman.conf; then
        echo "${option}" >> /etc/pacman.conf
    fi
}

disable_pacman_option DisableSandboxFilesystem
disable_pacman_option DisableSandboxSyscalls

pacman-key --init || true
pacman-key --populate archlinuxarm || true

pacman -Sy --noconfirm archlinuxarm-keyring || true
pacman-key --populate archlinuxarm || true
'
}

configure_locale_in_chroot() {
  log "Configuring system locale: ${SYSTEM_LOCALE}"

  if [[ "${SYSTEM_LOCALE}" == "C" || "${SYSTEM_LOCALE}" == "C.UTF-8" || "${SYSTEM_LOCALE}" == "POSIX" ]]; then
    arch_chroot_run "
set -e
echo 'LANG=${SYSTEM_LOCALE}' > /etc/locale.conf
"
    return
  fi

  local locale_gen_entry
  locale_gen_entry="${SYSTEM_LOCALE} UTF-8"

  arch_chroot_run "
set -e

if ! grep -q '^${locale_gen_entry}$' /etc/locale.gen; then
    if grep -q '^#${locale_gen_entry}$' /etc/locale.gen; then
        sed -i 's/^#${locale_gen_entry}$/${locale_gen_entry}/' /etc/locale.gen
    else
        echo '${locale_gen_entry}' >> /etc/locale.gen
    fi
fi

locale-gen
echo 'LANG=${SYSTEM_LOCALE}' > /etc/locale.conf
"
}

install_alarm_kernel_and_deps_in_chroot() {
  log "Updating rootfs and installing kernel dependencies"

  if [[ "${ENABLE_ONBOARD_WIFI}" -eq 1 ]]; then
    arch_chroot_run '
set -e

pacman -Syu --noconfirm \
    linux-armv7 \
    linux-armv7-headers \
    dkms \
    base-devel \
    git \
    iw \
    wireless-regdb
'
  else
    arch_chroot_run '
set -e

pacman -Syu --noconfirm \
    linux-armv7 \
    wireless-regdb
'
  fi
}

verify_wifi_dkms_in_rootfs() {
  log "Verifying xradio DKMS module inside rootfs"

  local tmpfile
  tmpfile="$(mktemp)"

  sudo find "${MOUNT_POINT}/usr/lib/modules" -name 'xradio_wlan.ko*' -print | tee "${tmpfile}"

  if [[ ! -s "${tmpfile}" ]]; then
    rm -f "${tmpfile}"
    die "xradio_wlan.ko was not found inside rootfs after DKMS."
  fi

  rm -f "${tmpfile}"
}

prepare_rootfs() {
  check_chroot_requirements
  mount_chroot_filesystems

  configure_pacman_in_chroot
  configure_locale_in_chroot
  install_alarm_kernel_and_deps_in_chroot

  if [[ "${ENABLE_ONBOARD_WIFI}" -eq 1 ]]; then
    verify_wifi_dkms_in_rootfs
  fi

  unmount_chroot_filesystems
}

build_image() {
  need_cmd curl
  need_cmd git
  need_cmd sfdisk
  need_cmd dd
  need_cmd xz

  start_sudo_keepalive
  create_build_dir
  trap cleanup_all EXIT

  download_rootfs
  build_uboot
  build_boot_scr

  if [[ "${ENABLE_ONBOARD_WIFI}" -eq 1 ]]; then
    clone_xr819_firmware
    clone_xradio
  fi

  create_empty_image
  setup_loop_and_mount
  extract_rootfs_into_image
  install_boot_files_into_rootfs
  configure_base_rootfs

  if [[ "${ENABLE_ONBOARD_WIFI}" -eq 1 ]]; then
    prepare_wifi_files
  else
    log "Onboard Wi-Fi support disabled"
  fi

  if [[ "${PREPARE_ROOTFS_ON_OPI}" -eq 1 ]]; then
    log "PREPARE_ROOTFS_ON_OPI=1: deferring rootfs preparation to Orange Pi first boot"
    write_first_boot_setup
  else
    log "PREPARE_ROOTFS_ON_OPI=0: preparing rootfs on host"
    prepare_rootfs
  fi

  log "Unmounting image"
  sudo sync
  cleanup_mounts

  write_uboot_to_image
  compress_image

  success "Image ready"
  ls -lh "${IMAGE}" "${IMAGE_XZ}"

  cleanup_build_dir
  stop_sudo_keepalive
  trap - EXIT
}

detect_partition_1() {
  local dev="$1"

  if [[ "${dev}" =~ mmcblk[0-9]+$ || "${dev}" =~ nvme[0-9]+n[0-9]+$ ]]; then
    echo "${dev}p1"
  else
    echo "${dev}1"
  fi
}

install_image() {
  local block_device="${1:-}"

  [[ -n "${block_device}" ]] || die "usage: $0 install DEVICE [--no-resize]"
  [[ -b "${block_device}" ]] || die "not a block device: ${block_device}"
  [[ -f "${IMAGE}" ]] || die "image not found: ${IMAGE}. Run build first."

  echo
  echo "WARNING: this will overwrite ${block_device}"
  echo "Image: ${IMAGE}"
  echo
  read -r -p "Type YES to continue: " confirm

  [[ "${confirm}" == "YES" ]] || die "cancelled"

  log "Writing image to DEVICE"
  sudo dd if="${IMAGE}" of="${block_device}" bs=4M status=progress conv=fsync
  sync

  if [[ "${INSTALL_RESIZE}" -eq 1 ]]; then
    resize_partition_after_install "${block_device}"
  else
    log "Skipping partition resize"
  fi
}

resize_partition_after_install() {
  local block_device="$1"

  if ! command -v growpart >/dev/null 2>&1; then
    warn "growpart not found. Install cloud-guest-utils or resize manually."
    return
  fi

  log "Expanding partition to fill DEVICE"

  sudo partprobe "${block_device}" || true
  sleep 2

  sudo growpart "${block_device}" 1 || {
    warn "growpart failed. The partition may already fill the disk."
    return
  }

  sudo partprobe "${block_device}" || true
  sleep 2

  local part
  part="$(detect_partition_1 "${block_device}")"

  [[ -b "${part}" ]] || die "partition not found after growpart: ${part}"

  log "Checking and resizing filesystem: ${part}"
  sudo e2fsck -f "${part}"
  sudo resize2fs "${part}"
  sync
}

clean_cache() {
  log "Cleaning build artifacts"

  cleanup_all

  rm -rf \
    "${IMAGE}" \
    "${IMAGE_XZ}"

  if [[ -z "${CACHE_DIR}" || "${CACHE_DIR}" == "/" ]]; then
    return
  fi

  if [[ "${CLEAN_CACHE_FULL}" -eq 1 ]]; then
    log "Cleaning full cache: ${CACHE_DIR}"
    rm -rf "${CACHE_DIR}"
  else
    log "Cleaning rebuildable cache entries"
    rm -rf "${CACHE_DIR}/${UBOOT_DIR}"
  fi
}

serial() {
  need_cmd picocom

  log "Opening serial console on ${SERIAL_DEVICE}"
  picocom -b 115200 "${SERIAL_DEVICE}"
}

version() {
  echo "opizero-alarm-image.sh ${SCRIPT_VERSION}"
}

usage() {
  cat <<EOF3
Orange Pi Zero Arch Linux ARM image builder

Usage:
  $0 [GLOBAL_OPTIONS] COMMAND [COMMAND_OPTIONS]

Global Options:
  --no-color                    Disable colored output
  -h, --help                    Show this help message
  --version                     Show script version

Commands:
  build [OPTIONS]               Build the image and prepare rootfs
  install DEVICE [OPTIONS]      Write the image to DEVICE
  clean-cache [OPTIONS]         Remove build artifacts and cached build files
  serial [OPTIONS]              Open the UART serial console
  help                          Show this help message

Build Options:
  --image FILE                  Output image path
                                Default: ${IMAGE}

  --image-size SIZE             Initial image size
                                Default: ${IMAGE_SIZE}

  --cross-compile PREFIX        ARM cross compiler prefix for U-Boot
                                Default: ${CROSS_COMPILE}

  --uboot-version VERSION       U-Boot release tag version
                                Default: ${UBOOT_VERSION}

  --locale LOCALE               System locale to generate inside the image
                                Default: host LANG, fallback: ${DEFAULT_SYSTEM_LOCALE}

  --no-wifi                     Disable onboard Wi-Fi support by leaving the XR819
                                firmware and the xradio DKMS module out of the image

  --prepare-rootfs-on-opi       Defer rootfs preparation to the Orange Pi first
                                boot

Install Options:
  --no-resize                   Do not expand the partition after writing the image

Clean-cache Options:
  --full                        Also remove downloaded tarballs and cloned repos

Serial Options:
  --serial-device DEVICE        Serial device used by the serial command
                                Default: ${SERIAL_DEVICE}

Cache:
  ${CACHE_DIR}

Examples:
  $0 build

  $0 build --no-wifi

  $0 build --locale pt_BR.UTF-8

  $0 build --prepare-rootfs-on-opi

  $0 build \\
     --image ArchLinuxARM-OrangePiZero.img \\
     --image-size 3G \\
     --locale pt_BR.UTF-8

  $0 --no-color build

  $0 install /dev/sdX

  $0 install /dev/sdX --no-resize

  $0 clean-cache

  $0 clean-cache --full

  $0 serial --serial-device /dev/ttyUSB0
EOF3
}

parse_global_options() {
  PARSED_GLOBAL_COUNT=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-color)
        NO_COLOR=1
        ;;
      -h|--help)
        setup_colors
        usage
        exit 0
        ;;
      --version)
        setup_colors
        version
        exit 0
        ;;
      build|install|clean-cache|serial|help)
        break
        ;;
      -*)
        setup_colors
        die "unknown global option: $1"
        ;;
      *)
        break
        ;;
    esac

    PARSED_GLOBAL_COUNT=$((PARSED_GLOBAL_COUNT + 1))
    shift
  done

  setup_colors
}

parse_build_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --image)
        shift
        [[ $# -gt 0 ]] || die "--image requires a value"
        set_image "$1"
        ;;
      --image=*)
        set_image "${1#--image=}"
        ;;
      --image-size)
        shift
        [[ $# -gt 0 ]] || die "--image-size requires a value"
        IMAGE_SIZE="$1"
        ;;
      --image-size=*)
        IMAGE_SIZE="${1#--image-size=}"
        ;;
      --cross-compile)
        shift
        [[ $# -gt 0 ]] || die "--cross-compile requires a value"
        CROSS_COMPILE="$1"
        ;;
      --cross-compile=*)
        CROSS_COMPILE="${1#--cross-compile=}"
        ;;
      --uboot-version)
        shift
        [[ $# -gt 0 ]] || die "--uboot-version requires a value"
        set_uboot_version "$1"
        ;;
      --uboot-version=*)
        set_uboot_version "${1#--uboot-version=}"
        ;;
      --locale)
        shift
        [[ $# -gt 0 ]] || die "--locale requires a value"
        SYSTEM_LOCALE="$1"
        ;;
      --locale=*)
        SYSTEM_LOCALE="${1#--locale=}"
        ;;
      --no-wifi)
        ENABLE_ONBOARD_WIFI=0
        ;;
      --prepare-rootfs-on-opi)
        PREPARE_ROOTFS_ON_OPI=1
        ;;
      *)
        die "unknown build option: $1"
        ;;
    esac

    shift
  done
}

parse_install_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-resize)
        INSTALL_RESIZE=0
        ;;
      -*)
        die "unknown install option: $1"
        ;;
      *)
        if [[ -n "${INSTALL_DEVICE}" ]]; then
          die "usage: $0 install DEVICE [--no-resize]"
        fi
        INSTALL_DEVICE="$1"
        ;;
    esac

    shift
  done

  [[ -n "${INSTALL_DEVICE}" ]] || die "usage: $0 install DEVICE [--no-resize]"
}

parse_serial_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --serial-device)
        shift
        [[ $# -gt 0 ]] || die "--serial-device requires a value"
        SERIAL_DEVICE="$1"
        ;;
      --serial-device=*)
        SERIAL_DEVICE="${1#--serial-device=}"
        ;;
      *)
        die "unknown serial option: $1"
        ;;
    esac

    shift
  done
}

parse_clean_cache_options() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --full)
        CLEAN_CACHE_FULL=1
        ;;
      *)
        die "unknown clean-cache option: $1"
        ;;
    esac

    shift
  done
}

reject_args() {
  local command="$1"
  shift

  [[ $# -eq 0 ]] || die "${command} does not accept arguments or options"
}

main() {
  SYSTEM_LOCALE="$(detect_host_locale)"
  CACHE_DIR="$(detect_cache_dir)"

  parse_global_options "$@"
  shift "${PARSED_GLOBAL_COUNT}"

  local cmd="${1:-help}"
  shift || true

  case "${cmd}" in
    build)
      parse_build_options "$@"
      build_image
      ;;
    install)
      parse_install_args "$@"
      install_image "${INSTALL_DEVICE}"
      ;;
    serial)
      parse_serial_options "$@"
      serial
      ;;
    clean-cache)
      parse_clean_cache_options "$@"
      clean_cache
      ;;
    help|"")
      reject_args help "$@"
      usage
      ;;
    *)
      die "unknown command: ${cmd}"
      ;;
  esac
}

main "$@"
