#!/usr/bin/env bash
#
# 10_vm_smoke_test.sh
#
# Boots the freshly installed Gentoo system in QEMU before committing to a
# bare-metal reboot. Runs on the HOST.
#
# WHAT THIS CAN AND CANNOT TEST
#   This machine has an i3-14100F - no integrated graphics - and exactly one
#   GPU. Passing the RTX 3060 through to a VM would leave the host with no
#   display at all, so GPU passthrough is not on the table. The VM therefore
#   cannot answer the question the project actually cares about: whether the
#   CUDA stack survives a kernel stripped from 10048 options to ~1457.
#
#   It can still test almost everything else about a first boot, which is where
#   most of the risk of a bricked-feeling afternoon lives:
#       - the kernel boots at all
#       - AHCI is built in and finds the disk
#       - the root filesystem mounts by UUID with no initramfs
#       - FB_SIMPLE actually produces a console (the bug fixed most recently)
#       - OpenRC starts its services
#       - a login prompt appears
#
# NON-DESTRUCTIVE
#   The disk is attached with snapshot=on, so every write the VM makes goes to
#   a temporary overlay and the real installation is untouched. The ESP is
#   mounted read-only, and only to copy the kernel image out.
#
# BOOT METHOD
#   QEMU's -kernel rather than the EFI stub path. A fresh VM has empty EFI
#   NVRAM, so it does not know about the Boot0005 entry created on the host,
#   and the ESP has no \EFI\BOOT\BOOTX64.EFI fallback for the firmware to find
#   on its own. Direct kernel boot skips only the firmware handoff - everything
#   after it is the real thing - and it allows a serial console, so the whole
#   boot is captured as text instead of having to be read off a screenshot.
#
# Run as: sudo ./10_vm_smoke_test.sh
#
set -euo pipefail

readonly TARGET_SERIAL="Z6CFSL8MS"
readonly ESP_UUID="930F-3DE2"
readonly ROOT_UUID="bfeafe2f-51cb-4648-bae4-c81009d78e22"
readonly KVER="6.18.48-gentoo"

readonly VM_MEM="4G"
readonly VM_CPUS="4"
readonly BOOT_TIMEOUT="${BOOT_TIMEOUT:-120}"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="${SCRIPT_DIR%/scripts}"
readonly WORK="${PROJECT_DIR}/.vmtest"
readonly SERIAL_LOG="${PROJECT_DIR}/logs/vm-boot.log"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (needs raw access to the disk)"
command -v qemu-system-x86_64 >/dev/null || die "qemu-system-x86_64 not installed"

mkdir -p "$WORK" "$(dirname "$SERIAL_LOG")"

# --- locate the target disk by serial, as everywhere else in this project ----
say "Locating the target disk"
target=""
for dev in /dev/sd[a-z]; do
    [ -b "$dev" ] || continue
    if [ "$(lsblk -dno SERIAL "$dev" 2>/dev/null | tr -d '[:space:]')" = "$TARGET_SERIAL" ]; then
        target="$dev"; break
    fi
done
[ -n "$target" ] || die "no disk with serial ${TARGET_SERIAL} attached"
echo "  ${target}"

# The installation must not be mounted: QEMU would be reading a filesystem that
# the host is simultaneously writing to.
if findmnt -rno TARGET,SOURCE | grep -q "${target}"; then
    findmnt -rno TARGET,SOURCE | grep "${target}"
    die "partitions on ${target} are still mounted - run 08_teardown_chroot.sh first"
fi

# --- pull the kernel out of the ESP -----------------------------------------
say "Extracting the kernel image (ESP mounted read-only)"
esp="$(readlink -f "/dev/disk/by-uuid/${ESP_UUID}")"
[ -b "$esp" ] || die "ESP with UUID ${ESP_UUID} not found"

tmpmnt="$(mktemp -d)"
mount -o ro "$esp" "$tmpmnt"
kernel_src="${tmpmnt}/EFI/Gentoo/vmlinuz-${KVER}.efi"
if [ -f "$kernel_src" ]; then
    cp "$kernel_src" "${WORK}/vmlinuz"
    echo "  $(ls -la "${WORK}/vmlinuz" | awk '{print $5" bytes"}')"
else
    umount "$tmpmnt"; rmdir "$tmpmnt"
    die "kernel not found at ${kernel_src}"
fi
umount "$tmpmnt"
rmdir "$tmpmnt"

# --- run ---------------------------------------------------------------------
# console=ttyS0 in addition to tty0: tty0 exercises the FB_SIMPLE console path
# (the thing being verified), while ttyS0 makes the same output readable as
# text on the host.
CMDLINE="root=UUID=${ROOT_UUID} rw nvidia-drm.modeset=0 console=tty0 console=ttyS0,115200"

say "Booting in QEMU"
echo "  memory   ${VM_MEM}, cpus ${VM_CPUS}"
echo "  disk     ${target} (snapshot=on - the real installation is not written to)"
echo "  cmdline  ${CMDLINE}"
echo "  serial   ${SERIAL_LOG}"
echo "  timeout  ${BOOT_TIMEOUT}s"
echo

qemu_args=(
    -machine q35
    -m "$VM_MEM"
    -smp "$VM_CPUS"
    -kernel "${WORK}/vmlinuz"
    -append "$CMDLINE"
    # ich9-ahci so the guest exercises the same SATA_AHCI driver that was
    # compiled into the kernel, rather than virtio.
    -device ich9-ahci,id=ahci
    -drive "id=rootdisk,file=${target},format=raw,if=none,snapshot=on,cache=unsafe"
    -device ide-hd,drive=rootdisk,bus=ahci.0
    -netdev user,id=net0
    -device e1000e,netdev=net0
    -display none
    -serial mon:stdio
    -no-reboot
)
[ -c /dev/kvm ] && qemu_args+=(-enable-kvm -cpu host)

set +e
timeout --foreground "$BOOT_TIMEOUT" \
    qemu-system-x86_64 "${qemu_args[@]}" 2>&1 | tee "$SERIAL_LOG"
rc=$?
set -e

# --- verdict -----------------------------------------------------------------
say "Boot log analysis"

check_log() {
    local label="$1" pattern="$2"
    if grep -qiE "$pattern" "$SERIAL_LOG" 2>/dev/null; then
        printf '  [ OK ] %s\n' "$label"
    else
        printf '  [ ?? ] %s\n' "$label"
        return 1
    fi
}

check_log "kernel started"            "Linux version ${KVER}" || true
check_log "AHCI driver bound"         "ahci.*(AHCI|SSS|slots)" || true
check_log "disk detected"             "sd [0-9]+:.*\[sda\]|Attached SCSI disk" || true
check_log "simple-framebuffer claimed" "simple-framebuffer|simplefb" || true
check_log "root filesystem mounted"   "EXT4-fs.*mounted filesystem" || true
check_log "init started"              "Free memory|OpenRC|init:|Starting" || true
check_log "login prompt reached"      "login:" || true

echo
if grep -qiE "Kernel panic|Unable to mount root|VFS: Cannot open root" "$SERIAL_LOG"; then
    echo "  KERNEL PANIC - see the log above"
    grep -iE -A5 "Kernel panic|Unable to mount root|VFS: Cannot open root" "$SERIAL_LOG" | head -20
elif grep -q "login:" "$SERIAL_LOG"; then
    echo "  Reached a login prompt. The boot path is sound; what remains untestable"
    echo "  here is the GPU, which needs bare metal on this machine."
else
    echo "  No login prompt within ${BOOT_TIMEOUT}s and no panic either - read"
    echo "  ${SERIAL_LOG} to see how far it got."
fi

echo
echo "Full log: ${SERIAL_LOG}"
echo "The installation on ${target} was not modified (snapshot=on)."
