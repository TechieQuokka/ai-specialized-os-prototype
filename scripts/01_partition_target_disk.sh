#!/usr/bin/env bash
#
# 01_partition_target_disk.sh
#
# Partition and format the Toshiba HDD for the Gentoo prototype install.
#
# SAFETY MODEL
#   The target disk is located by its SERIAL NUMBER, never by its kernel name
#   (/dev/sdX). Kernel names are assigned in probe order and can change between
#   boots; a serial number cannot. If no disk with the expected serial is found,
#   or if the model/size do not match, this script aborts without writing
#   anything. It also refuses to run against the disk hosting the live root
#   filesystem.
#
#   Disks that must never be touched on this machine:
#     Samsung SSD 870 EVO 2TB  (live Ubuntu root + /boot/efi)
#     WDC WD40EZRZ 4TB         (BitLocker "Storage2")
#     TAMMUZ 256GB             (Windows)
#
# RESULT LAYOUT
#   part 1   1 GiB    EFI System Partition   FAT32   GENTOO_ESP
#   part 2   8 GiB    Linux swap             swap    GENTOO_SWAP
#   part 3   rest     Linux filesystem       ext4    GENTOO_ROOT
#
# Requires root. Run: sudo ./01_partition_target_disk.sh
#
set -euo pipefail

# --- target identity -------------------------------------------------------
readonly TARGET_SERIAL="Z6CFSL8MS"
readonly TARGET_MODEL="TOSHIBA MQ01ABD100M"
readonly TARGET_SIZE_BYTES=1000204886016   # 931.5 GiB

# --- layout ----------------------------------------------------------------
readonly ESP_SIZE="+1GiB"
readonly SWAP_SIZE="+8GiB"

readonly ESP_LABEL="GENTOO_ESP"
readonly SWAP_LABEL="GENTOO_SWAP"
readonly ROOT_LABEL="GENTOO_ROOT"

# ext4 reserved-block percentage. The default 5% would hold back ~46 GiB on a
# 922 GiB partition, which is pointless here; 1% still leaves ~9 GiB of slack
# for root to recover from a full disk.
readonly ROOT_RESERVED_PCT=1

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

# --- preconditions ---------------------------------------------------------
[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

for tool in lsblk findmnt wipefs sgdisk partprobe udevadm mkfs.vfat mkfs.ext4 mkswap; do
    command -v "$tool" >/dev/null 2>&1 || die "required tool not found: $tool"
done

# --- locate the target disk by serial --------------------------------------
say "Locating target disk by serial: ${TARGET_SERIAL}"

target=""
for dev in /dev/sd[a-z]; do
    [ -b "$dev" ] || continue
    serial="$(lsblk -dno SERIAL "$dev" 2>/dev/null | tr -d '[:space:]')"
    if [ "$serial" = "$TARGET_SERIAL" ]; then
        target="$dev"
        break
    fi
done

[ -n "$target" ] || die "no disk with serial ${TARGET_SERIAL} is attached"

# --- verify the disk really is what we expect ------------------------------
model="$(lsblk -dno MODEL "$target" | sed 's/[[:space:]]*$//')"
size="$(blockdev --getsize64 "$target")"

[ "$model" = "$TARGET_MODEL" ] \
    || die "model mismatch on ${target}: expected '${TARGET_MODEL}', found '${model}'"
[ "$size" = "$TARGET_SIZE_BYTES" ] \
    || die "size mismatch on ${target}: expected ${TARGET_SIZE_BYTES}, found ${size}"

# --- refuse to touch the live system disk ----------------------------------
root_src="$(findmnt -no SOURCE /)"
root_disk="/dev/$(lsblk -no PKNAME "$root_src" | head -1)"
[ "$root_disk" != "$target" ] \
    || die "${target} hosts the live root filesystem - refusing"

esp_src="$(findmnt -no SOURCE /boot/efi 2>/dev/null || true)"
if [ -n "$esp_src" ]; then
    esp_disk="/dev/$(lsblk -no PKNAME "$esp_src" | head -1)"
    [ "$esp_disk" != "$target" ] \
        || die "${target} hosts the live /boot/efi - refusing"
fi

say "Target confirmed: ${target}  (${model}, serial ${TARGET_SERIAL})"

# --- show what will be destroyed, then confirm -----------------------------
echo
lsblk -o NAME,MODEL,SERIAL,FSTYPE,LABEL,SIZE,MOUNTPOINT "$target"
cat <<EOF

ALL DATA ON ${target} WILL BE DESTROYED.
No other disk on this machine will be read from or written to.

New layout:
  ${target}1   1 GiB    FAT32   ${ESP_LABEL}    (EFI System Partition)
  ${target}2   8 GiB    swap    ${SWAP_LABEL}
  ${target}3   rest     ext4    ${ROOT_LABEL}

EOF
read -r -p "Type ERASE to proceed: " reply
[ "$reply" = "ERASE" ] || die "not confirmed (got '${reply}')"

# --- unmount anything on the target ----------------------------------------
say "Unmounting partitions on ${target}"
# udisks auto-mounts removable-looking disks; make sure nothing is held.
while read -r mnt; do
    [ -n "$mnt" ] || continue
    echo "    umount ${mnt}"
    umount "$mnt"
done < <(lsblk -nro MOUNTPOINT "$target" | grep -v '^$' || true)

while read -r part; do
    [ -n "$part" ] || continue
    if swapon --noheadings --show=NAME 2>/dev/null | grep -qx "$part"; then
        echo "    swapoff ${part}"
        swapoff "$part"
    fi
done < <(lsblk -nrpo NAME "$target" | tail -n +2 || true)

# --- wipe every filesystem signature ---------------------------------------
# Stale signatures (the old NTFS one in particular) make libblkid report the
# wrong type and can confuse bootloader installation later.
say "Wiping filesystem signatures"
while read -r part; do
    [ -n "$part" ] || continue
    echo "    wipefs -a ${part}"
    wipefs -a "$part" >/dev/null
done < <(lsblk -nrpo NAME "$target" | tail -n +2 || true)
wipefs -a "$target" >/dev/null

# --- create the GPT layout -------------------------------------------------
say "Creating GPT partition table"
sgdisk --zap-all "$target" >/dev/null
sgdisk --new=1:0:${ESP_SIZE}  --typecode=1:ef00 --change-name=1:"${ESP_LABEL}"  "$target" >/dev/null
sgdisk --new=2:0:${SWAP_SIZE} --typecode=2:8200 --change-name=2:"${SWAP_LABEL}" "$target" >/dev/null
sgdisk --new=3:0:0            --typecode=3:8300 --change-name=3:"${ROOT_LABEL}" "$target" >/dev/null

partprobe "$target"
udevadm settle

# --- format ----------------------------------------------------------------
say "Formatting ${target}1 as FAT32 (EFI System Partition)"
mkfs.vfat -F32 -n "$ESP_LABEL" "${target}1"

say "Formatting ${target}2 as swap"
mkswap -L "$SWAP_LABEL" "${target}2"

say "Formatting ${target}3 as ext4"
mkfs.ext4 -q -L "$ROOT_LABEL" -m "$ROOT_RESERVED_PCT" "${target}3"

udevadm settle

# --- report ----------------------------------------------------------------
say "Done. Resulting layout:"
echo
lsblk -o NAME,FSTYPE,LABEL,SIZE,UUID "$target"
echo
say "Partition UUIDs for fstab:"
blkid "${target}1" "${target}2" "${target}3"
echo
