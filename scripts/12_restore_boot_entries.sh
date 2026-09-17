#!/usr/bin/env bash
#
# 12_restore_boot_entries.sh
#
# Runs on the UBUNTU HOST. Recreates the Gentoo EFI boot entries after the
# firmware has dropped them from NVRAM.
#
# WHY THIS EXISTS
#   07_make_bootable.sh writes these entries from inside the chroot, at the end
#   of an install that takes hours. But EFI boot entries live in firmware NVRAM,
#   not on the disk, and NVRAM is not ours: clearing CMOS, toggling Fast Boot,
#   a firmware update, or the board's own housekeeping can all remove them. On
#   2026-09-17 both entries vanished from an MSI PRO B760M-A after Fast Boot was
#   disabled, leaving BootOrder with only Windows and Ubuntu in it.
#
#   When that happens the target disk disappears from the F11 boot menu
#   entirely, which reads like a dead drive. It is not: the firmware simply has
#   nothing telling it this disk is bootable. Most firmwares will only offer a
#   disk with no NVRAM entry if the ESP carries the removable-media fallback
#   path \EFI\BOOT\BOOTX64.EFI, and this ESP deliberately does not.
#
#   The fallback path is not a fix here, which is worth writing down so it is
#   not attempted later. This is an EFI-stub boot with no bootloader, so the
#   kernel command line is carried in the boot entry's LoadOptions. Booting the
#   fallback path passes no LoadOptions, the kernel comes up with no root=, and
#   with no initramfs to fall back on it panics. The kernel is not built with
#   CONFIG_CMDLINE either, so there is nothing embedded to rescue it. Restoring
#   the NVRAM entries is the only thing that actually boots.
#
# SAFETY
#   This writes EFI variables, which is a real and persistent change to the
#   machine's boot configuration. It only ever adds Gentoo-ML* entries, and it
#   appends them to the END of BootOrder, so Ubuntu stays the default boot
#   target and a plain reboot is unaffected. Nothing on any disk is written.
#
# Run as: sudo ./12_restore_boot_entries.sh
#
set -euo pipefail

readonly TARGET_SERIAL="Z6CFSL8MS"
readonly ESP_UUID="930F-3DE2"
readonly ROOT_PARTUUID="3eb15fc3-858e-4b37-abe5-d43c8554799a"
readonly LABEL_PREFIX="Gentoo-ML"

# Identical to the command line 07 writes. Kept in step with it by hand; if the
# two ever disagree, 07 is the source of truth.
readonly BASE_CMDLINE="root=PARTUUID=${ROOT_PARTUUID} rw nvidia-drm.modeset=0 console=tty0"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
command -v efibootmgr >/dev/null || die "efibootmgr not installed"

# efibootmgr writes through efivarfs. If the host booted in legacy/CSM mode
# there is no efivarfs and the entries cannot be created from here at all -
# better to say so than to fail halfway through with a confusing error.
[ -d /sys/firmware/efi ] || die "host is not booted in UEFI mode - efibootmgr cannot write NVRAM"
findmnt -no OPTIONS /sys/firmware/efi/efivars | grep -qw rw \
    || die "/sys/firmware/efi/efivars is not mounted read-write"

# ---------------------------------------------------------------------------
# 1. Locate the target by serial, never by /dev/sdX.
#
# Kernel device names are assigned in probe order and change between boots. A
# serial cannot. This is the same guard every other script in this project uses.
# ---------------------------------------------------------------------------
say "Locating the target disk"
target=""
for dev in /dev/sd[a-z]; do
    [ -b "$dev" ] || continue
    if [ "$(lsblk -dno SERIAL "$dev" 2>/dev/null | tr -d '[:space:]')" = "$TARGET_SERIAL" ]; then
        target="$dev"; break
    fi
done
[ -n "$target" ] || die "no disk with serial ${TARGET_SERIAL} attached"
echo "  ${target}  $(lsblk -dno MODEL "$target" | sed 's/  */ /g')  serial ${TARGET_SERIAL}"

# The ESP is found by its filesystem UUID rather than by assuming partition 1,
# then checked to be on the disk located above. Either check alone would be
# weaker: the UUID pins the exact filesystem, the serial pins the exact disk.
esp_dev="$(blkid -U "$ESP_UUID" 2>/dev/null || true)"
[ -b "$esp_dev" ] || die "no partition with UUID ${ESP_UUID} found - is the disk attached?"
esp_parent="/dev/$(lsblk -no PKNAME "$esp_dev" | head -1)"
[ "$esp_parent" = "$target" ] \
    || die "ESP ${esp_dev} is on ${esp_parent}, not the expected ${target}"
esp_part="$(printf '%s' "$esp_dev" | grep -oE '[0-9]+$')"
esp_partuuid="$(lsblk -no PARTUUID "$esp_dev" | tr -d '[:space:]')"
echo "  ESP ${esp_dev}  (partition ${esp_part}, PARTUUID ${esp_partuuid})"

# The root partition has to exist too. An entry pointing at a root= that is not
# there boots to a panic, and the panic happens minutes later on bare metal
# where it is expensive to read. Check it now, where it costs nothing.
root_part="$(readlink -f "/dev/disk/by-partuuid/${ROOT_PARTUUID}" 2>/dev/null || true)"
[ -b "$root_part" ] || die "root partition ${ROOT_PARTUUID} not found"
root_parent="/dev/$(lsblk -no PKNAME "$root_part" | head -1)"
[ "$root_parent" = "$target" ] \
    || die "root ${root_part} is on ${root_parent}, not the expected ${target}"
echo "  root ${root_part}  PARTUUID ${ROOT_PARTUUID}"

# ---------------------------------------------------------------------------
# 2. Discover the kernel image on the ESP rather than hardcoding its version.
#
# 07 derives the filename from the kernel source tree, so a gentoo-sources bump
# changes it. Hardcoding a version here would let this script cheerfully write
# an entry pointing at an image that no longer exists - which is exactly the
# failure it is meant to repair.
# ---------------------------------------------------------------------------
say "Reading the ESP"
mnt="$(mktemp -d)"
cleanup() { mountpoint -q "$mnt" && umount "$mnt"; rmdir "$mnt" 2>/dev/null || true; }
trap cleanup EXIT

mount -o ro "$esp_dev" "$mnt" || die "could not mount ${esp_dev} read-only"

mapfile -t images < <(find "${mnt}/EFI/Gentoo" -maxdepth 1 -name 'vmlinuz-*.efi' -printf '%f\n' 2>/dev/null | sort)
case "${#images[@]}" in
    0) die "no vmlinuz-*.efi under \\EFI\\Gentoo on the ESP - run 07 in the chroot first" ;;
    1) : ;;
    *) die "${#images[@]} kernel images under \\EFI\\Gentoo ($(printf '%s ' "${images[@]}")) - remove the stale ones so there is no ambiguity about which one this entry should boot" ;;
esac
readonly IMAGE="${images[0]}"
readonly LOADER="\\EFI\\Gentoo\\${IMAGE}"
printf '  %s  (%s bytes)\n' "$LOADER" "$(stat -c %s "${mnt}/EFI/Gentoo/${IMAGE}")"

umount "$mnt"

# ---------------------------------------------------------------------------
# 3. Replace the entries this script owns.
#
# efibootmgr prints "BootXXXX* <label>\t<device path>", so the label is not at
# end of line and an anchored "label$" match never fires. Splitting on the tab
# isolates the label. Getting this wrong is what made an earlier version of 07
# accumulate duplicate entries instead of replacing them.
# ---------------------------------------------------------------------------
our_bootnums() {
    efibootmgr | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' -v p="$LABEL_PREFIX" '
        match($1, /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\*? /) {
            num = substr($1, 5, 4)
            lbl = substr($1, RLENGTH + 1)
            if (index(lbl, p) == 1) print num
        }'
}

say "Rewriting boot entries"
original_bootorder="$(efibootmgr | awk '/^BootOrder:/{print $2}')"
echo "  BootOrder before: ${original_bootorder:-<empty>}"

stale="$(our_bootnums)"
if [ -n "$stale" ]; then
    echo "  removing existing entries: $(echo "$stale" | paste -sd, -)"
    for num in $stale; do
        efibootmgr --delete-bootnum --bootnum "$num" >/dev/null
    done
else
    echo "  no existing ${LABEL_PREFIX}* entries - this is the expected state after NVRAM loss"
fi

make_entry() {
    local label="$1" extra="$2" cmdline
    cmdline="${BASE_CMDLINE}${extra:+ $extra}"
    efibootmgr --create \
        --disk "$target" --part "$esp_part" \
        --label "$label" \
        --loader "$LOADER" \
        --unicode "$cmdline" >/dev/null
    printf '  %-26s %s\n' "$label" "$cmdline"
}

# Same two configurations 07 creates: the plain boot used for the first boot and
# the minimal-gentoo baseline, and the core-isolation variant measured
# separately so its effect stays attributable.
make_entry "Gentoo-ML" ""
make_entry "Gentoo-ML-isolcpus" "isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3"

# ---------------------------------------------------------------------------
# 4. Append to BootOrder.
#
# Appending rather than prepending keeps Ubuntu the default boot target, so a
# plain reboot still lands somewhere known-good and a failed Gentoo boot costs
# one power cycle. Dropping the entries out of BootOrder entirely would be
# worse: some firmwares only list BootOrder entries in the boot menu, which is
# the very symptom this script exists to repair.
# ---------------------------------------------------------------------------
new_nums="$(our_bootnums)"
gentoo_nums="$(printf '%s' "$new_nums" | paste -sd, -)"

if [ -n "$original_bootorder" ] && [ -n "$gentoo_nums" ]; then
    exclude="$(printf '%s\n%s\n' "$stale" "$new_nums" | awk 'NF && !seen[$0]++')"
    others="$(
        printf '%s' "$original_bootorder" | tr ',' '\n' \
            | awk 'NF' \
            | grep -vxF "$exclude" \
            | awk '!seen[$0]++' \
            | paste -sd, -
    )"
    new_order="${others:+${others},}${gentoo_nums}"
    efibootmgr --bootorder "$new_order" >/dev/null
    echo "  BootOrder after:  ${new_order}"
    [ -n "$others" ] && echo "  the previous default (${others%%,*}) still boots first"
else
    die "could not rebuild BootOrder - inspect 'efibootmgr -v' by hand"
fi

# ---------------------------------------------------------------------------
# 5. Verify, rather than announce.
#
# The entries were written to NVRAM by another program; whether they are
# actually there is a question to be answered by reading NVRAM back, not by
# reaching the end of the script. A registration that failed silently looked
# exactly like a successful one once before in this project.
# ---------------------------------------------------------------------------
say "Verifying"
verbose="$(efibootmgr -v | sed 's/\x1b\[[0-9;]*m//g')"
final_order="$(printf '%s' "$verbose" | awk '/^BootOrder:/{print $2}')"
failures=0
check() {
    if [ "$1" = "ok" ]; then printf '  PASS  %s\n' "$2"
    else printf '  FAIL  %s\n' "$2"; failures=$((failures + 1)); fi
}

# Depending on version, efibootmgr -v renders an entry's optional data inline
# after the device path, or as an indented "data:" hex dump underneath it, or
# both. Rather than pick one and hope, take the whole record - the Boot line
# plus its continuation lines - and additionally decode any hex dump back to
# text. The command line is stored as UCS-2, so dropping the 00 bytes turns it
# back into something greppable.
decode_hex() {
    tr -cd '0-9a-fA-F \n' | tr -s ' \n' '\n' | while read -r b; do
        [ -n "$b" ] && [ "$b" != "00" ] && printf '%b' "\\x${b}"
    done
}

for label in "Gentoo-ML" "Gentoo-ML-isolcpus"; do
    # Explicit repetition instead of {4}: mawk is /usr/bin/awk on Ubuntu and
    # its support for interval expressions is not something to rely on.
    block="$(printf '%s\n' "$verbose" | awk -F'\t' -v l="$label" '
        match($1, /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\*? /) {
            keep = (substr($1, RLENGTH + 1) == l)
        }
        keep { print }')"

    if [ -z "$block" ]; then
        check bad "entry '${label}' exists"
        continue
    fi
    check ok "entry '${label}' exists"

    num="$(printf '%s' "$block" | head -1 | cut -c5-8)"
    haystack="$block
$(printf '%s\n' "$block" | sed -n 's/^ *data: //p' | decode_hex)"

    # The device path has to name our ESP partition. An entry that exists but
    # points at another disk is worse than a missing one: it looks correct in
    # the boot menu and fails at boot.
    case "$haystack" in
        *"$esp_partuuid"*) check ok "  points at ESP ${esp_partuuid}" ;;
        *) check bad "  points at ESP ${esp_partuuid}" ;;
    esac

    case "$haystack" in
        *"File(${LOADER})"*) check ok "  loader ${LOADER}" ;;
        *) check bad "  loader ${LOADER}" ;;
    esac

    # The one that matters most: no root= means a panic, minutes from now, on
    # bare metal, where the only diagnostic is a photograph of the screen.
    case "$haystack" in
        *"root=PARTUUID=${ROOT_PARTUUID}"*) check ok "  cmdline carries root=PARTUUID" ;;
        *) check bad "  cmdline carries root=PARTUUID" ;;
    esac

    case ",${final_order}," in
        *",${num},"*) check ok "  Boot${num} is in BootOrder" ;;
        *) check bad "  Boot${num} is in BootOrder" ;;
    esac
done

echo
printf '%s\n' "$verbose" | grep -E '^(BootOrder|BootCurrent|Boot[0-9A-Fa-f]{4})' | sed 's/^/  /'

if [ "$failures" -ne 0 ]; then
    die "${failures} check(s) failed - do not reboot into Gentoo until these are resolved"
fi

cat <<EOF

==> Boot entries restored.

    Reboot, press F11, pick 'Gentoo-ML'. Ubuntu is still first in BootOrder,
    so a plain reboot goes back to Ubuntu and a failed boot costs a power
    cycle.

    If the entries disappear again after a BIOS settings change, this is the
    script to re-run; it is idempotent.
EOF
