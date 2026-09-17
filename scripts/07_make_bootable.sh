#!/usr/bin/env bash
#
# 07_make_bootable.sh
#
# Runs INSIDE the Gentoo chroot. Turns the installed system into one that can
# actually boot and be logged into: services, root password, kernel on the ESP,
# and firmware boot entries.
#
# BOOT METHOD: EFI stub, no bootloader
#   CONFIG_EFI_STUB makes the kernel image itself an EFI executable, so the
#   firmware loads it directly. There is no GRUB, no initramfs, and no
#   bootloader configuration to keep in sync - which suits a project whose
#   subject is the number of layers between firmware and PID 1.
#
#   The kernel command line lives in the EFI boot entry rather than in a config
#   file, so each configuration under test gets its own named entry. The
#   firmware boot menu then doubles as the A/B test menu, which lines up with
#   how the benchmark harness labels its runs.
#
#   Those entries live in firmware NVRAM, which this board has erased twice.
#   So the same command line is also compiled into the image by 05, and the
#   kernel is installed a second time at \EFI\BOOT\BOOTX64.EFI. NVRAM entries
#   remain the way to select a configuration; the fallback is what guarantees
#   the disk still boots, and still appears in the boot menu, when they are
#   gone. See section 4b.
#
# RECOVERY
#   This writes EFI variables, which is a real and persistent change to the
#   machine's boot configuration. It adds entries and deliberately leaves the
#   existing BootOrder alone, so the machine keeps booting Ubuntu by default
#   and Gentoo is chosen from the firmware boot menu. A kernel that panics
#   costs a power cycle, not a recovery session.
#
# Run as:
#   sudo chroot /mnt/gentoo /bin/bash -c 'source /etc/profile && /root/07_make_bootable.sh'
#
set -euo pipefail

# Derived below from the kernel source tree rather than hardcoded - a
# gentoo-sources bump would otherwise silently write boot entries pointing at
# an image filename that no longer exists.
KVER=""

# root= must use PARTUUID, not the filesystem UUID.
#
# Without an initramfs the kernel resolves root= on its own, and it can only
# read identifiers that live in the partition table. A filesystem UUID lives in
# the superblock, which cannot be read until the filesystem is mounted - and it
# cannot be mounted until it has been found. Normally an initramfs breaks that
# circle by running blkid; this system deliberately has no initramfs.
#
# /etc/fstab keeps using the filesystem UUID: that is resolved by mount(8) in
# userspace, long after the kernel has already mounted the root.
readonly ROOT_PARTUUID="3eb15fc3-858e-4b37-abe5-d43c8554799a"
readonly ROOT_FS_UUID="bfeafe2f-51cb-4648-bae4-c81009d78e22"
readonly ESP_UUID="930F-3DE2"
readonly TARGET_SERIAL="Z6CFSL8MS"
readonly ESP_DIR="/efi/EFI/Gentoo"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f /etc/gentoo-release ] || die "not inside a Gentoo chroot - refusing"
[ -f /boot/vmlinuz ] || die "/boot/vmlinuz missing - run 05 first"
[ -d /usr/src/linux ] || die "/usr/src/linux missing - run 05 first"

# kernelrelease is the string modules_install names its directory after, and
# the one the ESP image filename must agree with. gentoo-sources already puts
# "-gentoo" in EXTRAVERSION, so nothing may be appended to it.
KVER="$(make -s -C /usr/src/linux kernelrelease)"
readonly KVER
[ -n "$KVER" ] || die "could not determine the kernel release from /usr/src/linux"
[ -d "/lib/modules/${KVER}" ] || die "/lib/modules/${KVER} missing - run 05 first"
find "/lib/modules/${KVER}" -name 'nvidia.ko*' -print -quit | grep -q . \
    || die "nvidia.ko not built under /lib/modules/${KVER} - run 06 first"

say "Target kernel: ${KVER}"

# ---------------------------------------------------------------------------
# 1. Root password.
# A system that boots but cannot be logged into is not a working system, and
# on a headless box the console is the only way in until sshd works.
# ---------------------------------------------------------------------------
say "Checking root password"
if awk -F: '$1=="root" && ($2=="" || $2=="!" || $2=="*" || $2=="!!")' /etc/shadow | grep -q .; then
    echo
    echo "  Root has no usable password. Set one now - without it there is no"
    echo "  way to log in on the first boot."
    echo
    passwd root || die "failed to set root password"
else
    echo "  root already has a password set"
fi

# ---------------------------------------------------------------------------
# 2. Services.
# Deliberately short. Anything not needed to get on the network, accept an SSH
# session, or bring the GPU up stays out of the boot path.
# ---------------------------------------------------------------------------
say "Enabling boot services"

# Registers a service and then checks that the runlevel symlink exists.
#
# The previous version discarded rc-update's output and exit status and printed
# "-> default" unconditionally, so a failed registration was indistinguishable
# from a successful one until the service failed to appear at boot. Reporting
# what was attempted is not the same as reporting what happened.
add_service() {
    local svc="$1" runlevel="${2:-default}"
    if ! rc-service --exists "$svc" 2>/dev/null; then
        printf '  %-22s MISSING (no init script)\n' "$svc"
        return 0
    fi
    rc-update add "$svc" "$runlevel" >/dev/null 2>&1 || true
    if [ -L "/etc/runlevels/${runlevel}/${svc}" ]; then
        printf '  %-22s -> %s  (verified)\n' "$svc" "$runlevel"
    else
        die "${svc} was not registered in runlevel ${runlevel}"
    fi
}

add_service dhcpcd default          # wired DHCP
add_service sshd default            # headless access
add_service modules boot            # loads nvidia, nvidia_uvm per /etc/conf.d/modules
add_service nvidia-persistenced default

# OpenRC 0.62 starts per-user services through pam_openrc and needs
# XDG_RUNTIME_DIR to be set. There is no session manager on this box, so the
# feature would only fail noisily in syslog. Turn it off.
say "Disabling OpenRC user services"
if grep -q '^rc_autostart_user=' /etc/rc.conf 2>/dev/null; then
    sed -i 's/^rc_autostart_user=.*/rc_autostart_user="NO"/' /etc/rc.conf
else
    printf '\n# No session manager on this headless box; pam_openrc would only\n# fail into syslog.\nrc_autostart_user="NO"\n' >> /etc/rc.conf
fi

# ---------------------------------------------------------------------------
# 3. sshd, so the machine is reachable once it boots.
# Root login over SSH is enabled because root is the only account that exists.
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Serial getty, via OpenRC rather than /etc/inittab.
#
# Gentoo leaves the ttyS0 line in inittab commented out, so a getty runs on
# tty1 only. That is fine on bare metal, but the QEMU smoke test watches the
# serial port and so can never confirm the boot reached a login prompt.
#
# Uncommenting the inittab line was the obvious fix and it did not work - and,
# worse, it failed silently: sysvinit spawns getty entries without logging
# anything, so a getty that never appears is indistinguishable from one that
# was never configured. OpenRC's agetty service prints "Starting agetty.ttyS0"
# either way, which turns a silent failure into a visible one.
#
# The OpenRC agetty guide is explicit that only one manager may own a port, so
# the inittab line is put back the way the stage3 shipped it.
# ---------------------------------------------------------------------------
say "Enabling a serial getty (OpenRC agetty service)"

if grep -q '^s0:.*ttyS0' /etc/inittab 2>/dev/null; then
    sed -i 's|^s0:\(.*ttyS0.*\)|#s0:\1|' /etc/inittab
    echo "  re-commented the inittab ttyS0 line (OpenRC owns this port now)"
fi

if [ -f /etc/init.d/agetty ]; then
    ln -sf agetty /etc/init.d/agetty.ttyS0
    cat > /etc/conf.d/agetty.ttyS0 <<'AGETTY'
# Serial console getty. Exists so an automated boot test can assert that the
# system reached a login prompt; harmless on bare metal, where the console
# getty on tty1 is the one that matters.
baud="115200"
term_type="vt100"
# --local-line: do not wait for carrier detect, which a virtual serial port
# never asserts.
agetty_options="--local-line"
AGETTY

    # Output deliberately NOT suppressed. The previous version sent rc-update's
    # output and exit status to /dev/null and then printed its own success
    # message unconditionally - so a failed registration still reported
    # "-> default runlevel", and the only symptom was a getty that never
    # appeared. Printing a claim is not the same as verifying it.
    rc-update add agetty.ttyS0 default

    # Verify the registration rather than trusting the command's exit status.
    if [ -L /etc/runlevels/default/agetty.ttyS0 ]; then
        echo "  verified: /etc/runlevels/default/agetty.ttyS0"
    else
        die "rc-update reported success but /etc/runlevels/default/agetty.ttyS0 does not exist"
    fi
else
    echo "  WARNING: /etc/init.d/agetty missing; no serial getty configured"
fi
echo "  runlevel default now contains:"
ls -1 /etc/runlevels/default/ | sed 's/^/    /'
grep -E '^#?(c1|s0):' /etc/inittab | sed 's/^/    /'

say "Configuring sshd"
if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin yes/' /etc/ssh/sshd_config
    grep -q '^PermitRootLogin' /etc/ssh/sshd_config || echo "PermitRootLogin yes" >> /etc/ssh/sshd_config
    echo "  PermitRootLogin yes"
fi

# ---------------------------------------------------------------------------
# 4. Put the kernel on the ESP.
# The firmware reads FAT, not ext4, so an EFI-stub kernel has to live on the
# EFI System Partition rather than in /boot.
# ---------------------------------------------------------------------------
say "Installing the kernel onto the ESP"
mountpoint -q /efi || die "/efi is not mounted"
[ "$(findmnt -no UUID /efi)" = "$ESP_UUID" ] \
    || die "/efi is mounted from an unexpected partition - refusing to write to it"

mkdir -p "$ESP_DIR"
install -m 0644 /boot/vmlinuz "${ESP_DIR}/vmlinuz-${KVER}.efi"
cp -f "/boot/config-${KVER}" "${ESP_DIR}/" 2>/dev/null || true
ls -la "$ESP_DIR"

# ---------------------------------------------------------------------------
# 4b. The removable-media fallback path, so the disk boots with no NVRAM entry.
#
# This used to be documented as a thing NOT to add, and that was correct at the
# time: the command line lived only in the boot entry's LoadOptions, and this
# path supplies none, so a kernel booted here came up with no root=, no
# initramfs to recover, and panicked. The reasoning was sound; its premise has
# since changed. 05 now compiles the command line in as CONFIG_CMDLINE, so a
# boot with empty LoadOptions falls back to a complete, working line.
#
# That turns the fallback into the answer to the actual failure on this board:
# the firmware erased the Gentoo NVRAM entries twice on 2026-09-17, the second
# time within one POST of being written and verified. Most firmwares will offer
# a disk that has no NVRAM entry only if its ESP carries this exact path, so
# installing it is also what puts the Toshiba back in the F11 menu when the
# variables are gone.
#
# It boots the plain configuration. The isolcpus variant still needs its own
# NVRAM entry, because per-configuration command lines are the one thing only
# LoadOptions can express - but losing that entry now costs an A/B arm, not the
# ability to boot.
# ---------------------------------------------------------------------------
say "Installing the removable-media fallback (\\EFI\\BOOT\\BOOTX64.EFI)"

# Refuse to install a fallback that cannot boot. Without CONFIG_CMDLINE this
# path panics, and it panics only when NVRAM is already gone - the one moment
# there is no other way in. A missing /boot/config means 05 was run by some
# other route; treat not-provable as not-safe.
if [ -f "/boot/config-${KVER}" ] && grep -q '^CONFIG_CMDLINE_BOOL=y' "/boot/config-${KVER}"; then
    builtin_cmdline="$(sed -n 's/^CONFIG_CMDLINE="\(.*\)"$/\1/p' "/boot/config-${KVER}")"
    case "$builtin_cmdline" in
        *root=PARTUUID=*)
            mkdir -p /efi/EFI/BOOT
            install -m 0644 /boot/vmlinuz /efi/EFI/BOOT/BOOTX64.EFI
            echo "  installed, boots with the builtin command line:"
            echo "    ${builtin_cmdline}"
            ;;
        *)
            die "the kernel has CONFIG_CMDLINE_BOOL=y but no root=PARTUUID= in CONFIG_CMDLINE; a fallback boot would panic - re-run 05"
            ;;
    esac
else
    die "the kernel has no builtin CONFIG_CMDLINE; a \\EFI\\BOOT\\BOOTX64.EFI boot would panic with no root= - re-run 05 to compile one in"
fi

# ---------------------------------------------------------------------------
# 5. Firmware boot entries.
# One entry per configuration under test. `nvidia-drm.modeset=0` appears in all
# of them: the GPU never drives a display here, and the stock baseline measured
# 473 MiB of VRAM held by a desktop session that this setting reclaims.
# ---------------------------------------------------------------------------
say "Creating EFI boot entries"

esp_dev="$(findmnt -no SOURCE /efi)"
esp_disk="/dev/$(lsblk -no PKNAME "$esp_dev" | head -1)"
esp_part="$(printf '%s' "$esp_dev" | grep -oE '[0-9]+$')"

# The same serial guard the install scripts use: never write boot entries that
# point at a partition on some other disk.
#
# Inside a chroot `lsblk -o SERIAL` usually comes back empty, because it reads
# the udev database rather than sysfs. That is "could not determine", which is
# a different thing from "determined and wrong" - only the second one justifies
# aborting. /dev/disk/by-id encodes the serial in the symlink name and works
# in the chroot, so try that before giving up.
actual_serial="$(lsblk -dno SERIAL "$esp_disk" 2>/dev/null | tr -d '[:space:]')"

if [ -z "$actual_serial" ]; then
    for link in /dev/disk/by-id/*"${TARGET_SERIAL}"*; do
        [ -e "$link" ] || continue
        case "$link" in *-part[0-9]*) continue ;; esac
        if [ "$(readlink -f "$link")" = "$esp_disk" ]; then
            actual_serial="$TARGET_SERIAL"
            break
        fi
    done
fi

if [ -n "$actual_serial" ]; then
    [ "$actual_serial" = "$TARGET_SERIAL" ] \
        || die "ESP lives on ${esp_disk} (serial ${actual_serial}), not the expected ${TARGET_SERIAL}"
    echo "  disk serial verified: ${actual_serial}"
else
    # The ESP UUID was already checked against ESP_UUID above, which pins the
    # exact partition being written to. Proceed on that.
    echo "  WARNING: could not read a disk serial in this chroot;"
    echo "           relying on the ESP UUID check (${ESP_UUID}) instead"
fi

echo "  ESP: ${esp_dev}  (disk ${esp_disk}, partition ${esp_part})"

original_bootorder="$(efibootmgr | awk '/^BootOrder:/{print $2}')"
echo "  BootOrder before: ${original_bootorder}"

readonly BASE_CMDLINE="root=PARTUUID=${ROOT_PARTUUID} rw nvidia-drm.modeset=0 console=tty0"
readonly LABEL_PREFIX="Gentoo-ML"

# List the boot numbers of every entry this script owns.
#
# efibootmgr prints "BootXXXX* <label>\t<device path>", so the label is not at
# end of line - an anchored "label$" match never fires, which is how earlier
# runs ended up creating duplicates instead of replacing. Splitting on the tab
# isolates the header field and the label within it.
our_bootnums() {
    efibootmgr | sed 's/\x1b\[[0-9;]*m//g' | awk -F'\t' -v p="$LABEL_PREFIX" '
        match($1, /^Boot[0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f][0-9A-Fa-f]\*? /) {
            num = substr($1, 5, 4)
            lbl = substr($1, RLENGTH + 1)
            if (index(lbl, p) == 1) print num
        }'
}

# Clear out every entry this script owns before creating any, so a re-run
# replaces rather than accumulates.
stale="$(our_bootnums)"
if [ -n "$stale" ]; then
    echo "  removing previously created entries: $(echo "$stale" | paste -sd, -)"
    for num in $stale; do
        efibootmgr --delete-bootnum --bootnum "$num" >/dev/null
    done
fi

make_entry() {
    local label="$1" extra="$2" cmdline
    cmdline="${BASE_CMDLINE}${extra:+ $extra}"
    efibootmgr --create \
        --disk "$esp_disk" --part "$esp_part" \
        --label "$label" \
        --loader "\\EFI\\Gentoo\\vmlinuz-${KVER}.efi" \
        --unicode "$cmdline" >/dev/null
    printf '  %-26s %s\n' "$label" "$cmdline"
}

# Plain boot. This is the one to use for the first boot and for the
# minimal-gentoo baseline measurement.
make_entry "Gentoo-ML" ""

# Core isolation, per the project spec. Cores 0-1 run the training loop, 2-3
# are taken out of the general scheduler pool for the data loader and
# checkpoint I/O. Measured separately so the effect is attributable.
make_entry "Gentoo-ML-isolcpus" "isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3"

# Put the new entries at the END of BootOrder rather than leaving them out of
# it. efibootmgr --create prepends by default, which would make an unproven
# hand-built kernel the machine's default boot target. But dropping them from
# BootOrder entirely is worse: some firmwares only list BootOrder entries in
# the boot menu, which would leave no way to select Gentoo at all.
#
# Appending keeps the previous default intact and still guarantees the entries
# are visible.
new_nums="$(our_bootnums)"
gentoo_nums="$(printf '%s' "$new_nums" | paste -sd, -)"

if [ -n "$original_bootorder" ] && [ -n "$gentoo_nums" ]; then
    # Everything this script has ever owned: the numbers deleted a moment ago
    # and the ones just created. Both have to come out of the captured
    # BootOrder - the stale ones because they no longer exist, the new ones
    # because they are about to be appended.
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
    say "BootOrder set to ${new_order}"
    [ -n "$others" ] && echo "  the previous default (${others%%,*}) still boots first"
else
    say "WARNING: could not rebuild BootOrder; leaving it as the firmware set it"
fi

# emerge leaves a ._cfg0000_ copy behind when it wants to replace a config file
# this script owns. Drop it so etc-update does not keep prompting about it.
rm -f /etc/modprobe.d/._cfg[0-9]*_nvidia.conf

# ---------------------------------------------------------------------------
# 6. Report
# ---------------------------------------------------------------------------
say "Boot configuration complete."
echo
efibootmgr | sed 's/\x1b\[[0-9;]*m//g'
echo
cat <<EOF

To boot it: reboot, open the firmware boot menu (F11 on this board), and pick
"Gentoo-ML". Ubuntu remains the default, so a failed boot costs a power cycle.

If "Gentoo-ML" is not listed, the firmware has erased the NVRAM entries again.
The disk should still be offered under its own name (TOSHIBA MQ01ABD100M) via
\\EFI\\BOOT\\BOOTX64.EFI, which boots the plain configuration from the command
line compiled into the kernel. Booting that way is not a degraded mode - it is
the same kernel and the same command line. Only the isolcpus arm needs the
NVRAM entry, which 12_restore_boot_entries.sh puts back from Ubuntu.

First boot checklist:
  1. Does it reach a login prompt?
  2. lsmod | grep nvidia        - did the modules load?
  3. nvidia-smi                 - does the driver see the GPU?
  4. ip a                       - did dhcpcd get an address?
  5. nvidia-smi -q | grep Persistence

Then install the benchmark harness and take the comparison run:
  emerge dev-lang/python dev-python/pip
  pip install torch nvidia-ml-py
  python -m gpubench run --label minimal-gentoo
EOF
