#!/usr/bin/env bash
#
# 08_teardown_chroot.sh
#
# Runs on the HOST (not in the chroot). Unmounts the Gentoo installation
# cleanly so the machine can be rebooted into it.
#
# Rebooting with the target filesystem still mounted read-write leaves ext4
# dirty and forces a recovery pass on the next mount - and the next mount is
# the first boot of a hand-built kernel, which is not the moment to add an
# extra variable.
#
# Re-entering the chroot later is just 02_bootstrap_stage3.sh again: it detects
# an already-unpacked stage3 and only re-establishes the mounts.
#
# Run as: sudo ./08_teardown_chroot.sh
#
set -euo pipefail

readonly MNT="/mnt/gentoo"
readonly TARGET_SERIAL="Z6CFSL8MS"
readonly SWAP_UUID="69f553c9-5179-49e5-a653-9f0d502e7b77"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

if ! mountpoint -q "$MNT"; then
    say "${MNT} is not mounted - nothing to do"
    exit 0
fi

# Confirm we are about to unmount the Toshiba and not something else that
# happens to be mounted there.
root_src="$(findmnt -no SOURCE "$MNT")"
root_disk="/dev/$(lsblk -no PKNAME "$root_src" | head -1)"
actual_serial="$(lsblk -dno SERIAL "$root_disk" | tr -d '[:space:]')"
[ "$actual_serial" = "$TARGET_SERIAL" ] \
    || die "${MNT} is backed by ${root_disk} (serial ${actual_serial}), not ${TARGET_SERIAL}"

say "Unmounting ${MNT} (backed by ${root_src} on ${root_disk})"
findmnt -R "$MNT" -o TARGET,SOURCE,FSTYPE

# Anything still holding a file open under the tree blocks the unmount and is
# far easier to find now than to diagnose from a lazy unmount later.
if command -v fuser >/dev/null 2>&1; then
    if fuser -m "$MNT" >/dev/null 2>&1; then
        say "Processes still using ${MNT}:"
        fuser -vm "$MNT" 2>&1 || true
        die "close these before tearing down (a stray chroot shell is the usual cause)"
    fi
fi

say "Turning off swap on the target"
swap_part="/dev/disk/by-uuid/${SWAP_UUID}"
if [ -e "$swap_part" ] && swapon --noheadings --show=NAME | grep -qx "$(readlink -f "$swap_part")"; then
    swapoff "$(readlink -f "$swap_part")"
    echo "  swapoff $(readlink -f "$swap_part")"
else
    echo "  target swap was not active"
fi

say "Recursive unmount"
umount -R "$MNT" || die "unmount failed - see the process list above"

sync

say "Teardown complete."
echo
if mountpoint -q "$MNT"; then
    echo "  WARNING: ${MNT} is somehow still mounted"
else
    echo "  ${MNT} is clear"
fi
echo
lsblk -o NAME,FSTYPE,LABEL,SIZE,MOUNTPOINT "$root_disk"
cat <<'EOF'

Safe to reboot. At the firmware boot menu (F11) pick "Gentoo-ML".
Ubuntu is still the default boot target, so a failed boot costs a power cycle.
EOF
