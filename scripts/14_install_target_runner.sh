#!/usr/bin/env bash
#
# 14_install_target_runner.sh
#
# Runs on the Ubuntu HOST. Places 13_gentoo_preflight_and_run.sh on the target
# disk as /root/run.sh, so the Gentoo session is one short command.
#
#     sudo ./scripts/14_install_target_runner.sh
#
# Why a copy rather than just running it from the checkout: 13 is what repairs
# the network and updates the checkout, so it cannot itself arrive through the
# checkout. The copy is the bootstrap. That also means it does not update when
# 13 does - re-run this after changing 13, which is what this script is for.
#
# This is the only thing in the project that mounts the target read-WRITE from
# Ubuntu, so it checks harder than the read-only collectors do and writes
# exactly one file.
set -euo pipefail

readonly TARGET_SERIAL="Z6CFSL8MS"
readonly TARGET_MODEL="TOSHIBA MQ01ABD100M"
readonly DEST_REL="root/run.sh"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SRC="${SCRIPT_DIR}/13_gentoo_preflight_and_run.sh"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f "$SRC" ] || die "source script not found: ${SRC}"

say "Locating the target by serial"
target=""
for dev in /dev/sd?; do
    if [ "$(lsblk -dno SERIAL "$dev" 2>/dev/null | tr -d '[:space:]')" = "$TARGET_SERIAL" ]; then
        target="$dev"; break
    fi
done
[ -n "$target" ] || die "no disk with serial ${TARGET_SERIAL} attached"

model="$(lsblk -dno MODEL "$target" | sed 's/[[:space:]]*$//')"
[ "$model" = "$TARGET_MODEL" ] \
    || die "serial matched ${target} but model is '${model}', expected '${TARGET_MODEL}'"

# Never the disk this system is running from, under any circumstances.
live_disk="$(findmnt -no SOURCE / | sed 's/[0-9]*$//')"
[ "$live_disk" = "$target" ] && die "${target} hosts the live root - refusing"
efi_disk="$(findmnt -no SOURCE /boot/efi 2>/dev/null | sed 's/[0-9]*$//')"
[ "$efi_disk" = "$target" ] && die "${target} hosts the live /boot/efi - refusing"

root_part="${target}3"
[ -b "$root_part" ] || die "${root_part} is not a block device"
echo "  ${target}  ${model}  serial ${TARGET_SERIAL}"
echo "  writing to ${root_part} (GENTOO_ROOT)"

findmnt -no TARGET "$root_part" >/dev/null 2>&1 \
    && die "${root_part} is already mounted - unmount it first"

say "Mounting read-write"
tmpmnt="$(mktemp -d)"
cleanup() { mountpoint -q "$tmpmnt" && umount "$tmpmnt"; rmdir "$tmpmnt" 2>/dev/null || true; }
trap cleanup EXIT
mount -o rw "$root_part" "$tmpmnt" || die "could not mount ${root_part} read-write"

# Confirm this is the Gentoo root and not merely something that happens to be
# partition 3, before writing to it.
[ -f "${tmpmnt}/etc/gentoo-release" ] \
    || die "${root_part} has no /etc/gentoo-release - this is not the Gentoo root"
[ -d "${tmpmnt}/root/ai-specialized-os-prototype/.git" ] \
    || die "no repo clone at /root/ai-specialized-os-prototype on the target"
echo "  $(cat "${tmpmnt}/etc/gentoo-release")"

dest="${tmpmnt}/${DEST_REL}"
if [ -e "$dest" ]; then
    if cmp -s "$SRC" "$dest"; then
        say "Already current - /${DEST_REL} is byte-identical to 13"
        sha256sum "$SRC" | sed 's/^/  /'
        exit 0
    fi
    say "Replacing the existing /${DEST_REL}"
    ls -la "$dest" | sed "s|${tmpmnt}||" | sed 's/^/  old: /'
    sha256sum "$dest" | sed "s|${tmpmnt}||" | sed 's/^/  old: /'
else
    say "Installing /${DEST_REL}"
fi

install -m 0755 "$SRC" "$dest"

say "Verifying what landed"
ls -la "$dest" | sed "s|${tmpmnt}||" | sed 's/^/  /'
cmp -s "$SRC" "$dest" || die "copy differs from the source"
echo "  byte-identical to ${SRC##*/}"
sha256sum "$dest" | sed "s|${tmpmnt}||" | sed 's/^/  /'

sync
say "Unmounting"
