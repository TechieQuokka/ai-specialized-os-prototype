#!/usr/bin/env bash
#
# 02_bootstrap_stage3.sh
#
# Mount the target disk, unpack the verified stage3 tarball onto it, write the
# Portage configuration, and prepare a chroot. Leaves the system ready for
# 03_chroot_setup.sh.
#
# SAFETY MODEL
#   Partitions are addressed by UUID, never by kernel name. Before mounting,
#   each UUID is resolved and checked to make sure it lives on the expected
#   Toshiba disk (matched by serial). Anything else aborts before a single
#   mount happens.
#
#   Disks that must never be touched on this machine:
#     Samsung SSD 870 EVO 2TB  (live Ubuntu root + /boot/efi)
#     WDC WD40EZRZ 4TB         (BitLocker "Storage2")
#     TAMMUZ 256GB             (Windows)
#
# Requires root. Run: sudo ./02_bootstrap_stage3.sh
#
set -euo pipefail

# --- identity of the target ------------------------------------------------
readonly TARGET_SERIAL="Z6CFSL8MS"
readonly ROOT_UUID="bfeafe2f-51cb-4648-bae4-c81009d78e22"
readonly ESP_UUID="930F-3DE2"
readonly SWAP_UUID="69f553c9-5179-49e5-a653-9f0d502e7b77"

readonly MNT="/mnt/gentoo"

# Portage build scratch lives in RAM. The target is a 5400 rpm 2.5" drive;
# compiling on it directly makes builds seek-bound rather than CPU-bound.
# tmpfs only consumes what is actually written, so sizing it at 12G does not
# reserve 12G. Packages that blow past it (rust, llvm, gcc) need a per-package
# PORTAGE_TMPDIR override back onto disk.
readonly PORTAGE_TMPFS_SIZE="12G"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PROJECT_DIR="${SCRIPT_DIR%/scripts}"
readonly STAGE3="${PROJECT_DIR}/downloads/stage3-amd64-nomultilib-openrc-20260913T163055Z.tar.xz"
readonly STAGE3_SHA512="dee1f4f61e929ef79ea8b2c3f768907a1317de0356097e1180af1922e174d16ea76d777f82f33050dbc1f3723dd8d9b4aff248913283be570a53ddde904c75ae"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

# --- resolve the target disk by serial -------------------------------------
say "Locating target disk by serial: ${TARGET_SERIAL}"
target=""
for dev in /dev/sd[a-z]; do
    [ -b "$dev" ] || continue
    if [ "$(lsblk -dno SERIAL "$dev" 2>/dev/null | tr -d '[:space:]')" = "$TARGET_SERIAL" ]; then
        target="$dev"
        break
    fi
done
[ -n "$target" ] || die "no disk with serial ${TARGET_SERIAL} is attached"
say "Target disk: ${target}"

# --- resolve partitions by UUID and confirm they live on that disk ---------
# This is the guard that matters: a UUID alone could in principle be cloned
# onto another disk, so every UUID must also resolve onto the Toshiba.
resolve_uuid() {
    local uuid="$1" name="$2" path parent
    path="/dev/disk/by-uuid/${uuid}"
    [ -e "$path" ] || die "${name} partition (UUID ${uuid}) not found"
    path="$(readlink -f "$path")"
    parent="/dev/$(lsblk -no PKNAME "$path" | head -1)"
    [ "$parent" = "$target" ] \
        || die "${name} (UUID ${uuid}) resolves to ${path} on ${parent}, not ${target}"
    printf '%s' "$path"
}

root_part="$(resolve_uuid "$ROOT_UUID" root)"
esp_part="$(resolve_uuid "$ESP_UUID" ESP)"
swap_part="$(resolve_uuid "$SWAP_UUID" swap)"
say "root=${root_part}  esp=${esp_part}  swap=${swap_part}"

# --- verify the stage3 tarball still matches what we verified --------------
say "Re-checking stage3 integrity"
[ -f "$STAGE3" ] || die "stage3 tarball not found: ${STAGE3}"
actual="$(sha512sum "$STAGE3" | awk '{print $1}')"
[ "$actual" = "$STAGE3_SHA512" ] \
    || die "stage3 SHA512 mismatch - refusing to unpack an unverified tarball"
say "SHA512 matches the GPG-verified DIGESTS entry"

# --- release udisks automounts on the target -------------------------------
# Only filesystem mounts are in the way. lsblk reports an active swap partition
# with the literal string "[SWAP]" in the MOUNTPOINT column rather than a path,
# and feeding that to umount fails with "no mount point specified" - which
# aborts the whole pipeline. This script enables that same swap a few lines
# below, so there is nothing to release and nothing to gain by turning it off.
#
# It stayed hidden because a clean run never reaches this state: 08 swaps off
# during teardown, so the disk is quiet by the time 02 runs again. It takes a
# rerun after a mid-pipeline failure, with swap still on, to hit it - which is
# exactly when the pipeline most needs to be able to resume.
say "Releasing any automounts on ${target}"
while read -r dev mnt; do
    [ -n "$mnt" ] || continue
    if [ "$mnt" = "[SWAP]" ]; then
        echo "    ${dev} is active swap - left alone, re-checked below"
        continue
    fi
    [ "$mnt" != "$MNT" ] || continue
    echo "    umount ${mnt}"
    umount "$mnt" || die "could not unmount ${mnt}"
done < <(lsblk -nrpo NAME,MOUNTPOINT "$target" || true)

# --- mount ------------------------------------------------------------------
say "Mounting target filesystems under ${MNT}"
mkdir -p "$MNT"
mountpoint -q "$MNT" || mount "$root_part" "$MNT"

mkdir -p "${MNT}/efi"
mountpoint -q "${MNT}/efi" || mount "$esp_part" "${MNT}/efi"

swapon --noheadings --show=NAME | grep -qx "$swap_part" || swapon "$swap_part"

findmnt -no SOURCE,TARGET "$MNT" || true
findmnt -no SOURCE,TARGET "${MNT}/efi" || true

# --- unpack stage3 ----------------------------------------------------------
if [ -x "${MNT}/bin/bash" ]; then
    say "stage3 already unpacked (${MNT}/bin/bash exists) - skipping extraction"
else
    say "Unpacking stage3 (this takes a few minutes on a 5400 rpm drive)"
    # --xattrs-include and --numeric-owner are required by the Gentoo handbook:
    # without them capabilities and ownership on the unpacked tree are wrong.
    tar xpf "$STAGE3" \
        --xattrs-include='*.*' \
        --numeric-owner \
        -C "$MNT"
    say "Unpacked"
fi

# --- Portage configuration --------------------------------------------------
say "Writing ${MNT}/etc/portage/make.conf"
mkdir -p "${MNT}/etc/portage"
cat > "${MNT}/etc/portage/make.conf" <<'MAKECONF'
# Gentoo host for the AI-specialized OS prototype.
# Headless CUDA compute node: no graphical stack, no audio, no systemd.

COMMON_FLAGS="-O2 -pipe -march=native"
CFLAGS="${COMMON_FLAGS}"
CXXFLAGS="${COMMON_FLAGS}"
FCFLAGS="${COMMON_FLAGS}"
FFLAGS="${COMMON_FLAGS}"
LDFLAGS="-Wl,-O1 -Wl,--as-needed"

CHOST="x86_64-pc-linux-gnu"

# i3-14100F: 4 cores / 8 threads. -l caps the run queue so that parallel
# emerge jobs cannot collectively oversubscribe the CPU.
MAKEOPTS="-j8 -l8"
EMERGE_DEFAULT_OPTS="--jobs=2 --load-average=9 --keep-going --with-bdeps=y"

FEATURES="parallel-fetch"

# The point of using Gentoo here: these features are never compiled, so the
# graphical stack never enters the dependency graph at all. A binary
# distribution cannot express this - it ships one build for everyone.
USE="-X -wayland -gtk -gtk3 -qt5 -qt6 -gnome -kde -plasma \
     -pulseaudio -alsa -sound -bluetooth -cups -printsupport \
     -systemd -introspection -vulkan \
     -doc -handbook -examples \
     threads openmp"

VIDEO_CARDS="nvidia"
INPUT_DEVICES=""

# NVIDIA-r2 covers the proprietary driver. Note that `cuda` is deliberately
# NOT a global USE flag: setting it globally drags the multi-gigabyte CUDA
# toolkit into unrelated packages. PyTorch wheels ship their own CUDA runtime,
# so only the kernel driver is actually required here.
ACCEPT_LICENSE="* -@EULA NVIDIA-r2"
ACCEPT_KEYWORDS="amd64"

# Measured from this machine: KAIST ~0.10s, official distfiles ~4.27s.
GENTOO_MIRRORS="https://ftp.kaist.ac.kr/gentoo/ https://ftp.daumkakao.com/gentoo/ https://distfiles.gentoo.org/"

L10N="en"
LC_MESSAGES=C.utf8
MAKECONF

say "Writing ${MNT}/etc/portage/repos.conf/gentoo.conf"
mkdir -p "${MNT}/etc/portage/repos.conf"
cat > "${MNT}/etc/portage/repos.conf/gentoo.conf" <<'REPOSCONF'
[DEFAULT]
main-repo = gentoo

[gentoo]
location = /var/db/repos/gentoo
sync-type = rsync
sync-uri = rsync://ftp.kaist.ac.kr/gentoo-portage
auto-sync = yes
sync-rsync-verify-jobs = 1
sync-rsync-verify-metamanifest = yes
sync-rsync-verify-max-age = 3
sync-openpgp-key-path = /usr/share/openpgp-keys/gentoo-release.asc
sync-openpgp-key-refresh-retry-count = 40
sync-openpgp-key-refresh-retry-overall-timeout = 1200
sync-openpgp-key-refresh-retry-delay-exp-base = 2
sync-openpgp-key-refresh-retry-delay-max = 60
sync-openpgp-key-refresh-retry-delay-mult = 4
REPOSCONF

# --- build scratch in RAM ---------------------------------------------------
say "Mounting tmpfs on ${MNT}/var/tmp/portage (size=${PORTAGE_TMPFS_SIZE})"
mkdir -p "${MNT}/var/tmp/portage"
if ! mountpoint -q "${MNT}/var/tmp/portage"; then
    portage_uid="$(awk -F: '$1=="portage"{print $3}' "${MNT}/etc/passwd")"
    portage_gid="$(awk -F: '$1=="portage"{print $3}' "${MNT}/etc/group")"
    [ -n "$portage_uid" ] && [ -n "$portage_gid" ] \
        || die "portage user/group missing from the unpacked stage3"
    mount -t tmpfs -o "size=${PORTAGE_TMPFS_SIZE},uid=${portage_uid},gid=${portage_gid},mode=0775" \
        tmpfs "${MNT}/var/tmp/portage"
fi

# --- chroot plumbing --------------------------------------------------------
say "Copying DNS configuration"
cp --dereference /etc/resolv.conf "${MNT}/etc/resolv.conf"

say "Setting up chroot bind mounts"
mountpoint -q "${MNT}/proc" || mount --types proc /proc "${MNT}/proc"

if ! mountpoint -q "${MNT}/sys"; then
    mount --rbind /sys "${MNT}/sys"
    mount --make-rslave "${MNT}/sys"
fi

if ! mountpoint -q "${MNT}/dev"; then
    mount --rbind /dev "${MNT}/dev"
    mount --make-rslave "${MNT}/dev"
fi

if ! mountpoint -q "${MNT}/run"; then
    mount --bind /run "${MNT}/run"
    mount --make-slave "${MNT}/run"
fi

# Some Ubuntu hosts do not expose /dev/shm as a real mount inside the chroot.
if [ -L /dev/shm ]; then
    rm -f "${MNT}/dev/shm"
    mkdir -p "${MNT}/dev/shm"
    mount --types tmpfs --options nosuid,nodev,noexec shm "${MNT}/dev/shm"
    chmod 1777 "${MNT}/dev/shm"
fi

# --- stage the in-chroot scripts --------------------------------------------
# Every script that runs inside the chroot, not just the next one. Staging a
# subset means a later re-run silently executes a stale copy from a previous
# session - which is exactly how an already-fixed root=UUID command line got
# written into the EFI boot entries a second time.
say "Staging in-chroot scripts into ${MNT}/root/"
for s in "${SCRIPT_DIR}"/0[3-9]_*.sh; do
    [ -f "$s" ] || continue
    case "$(basename "$s")" in
        08_teardown_chroot.sh) continue ;;   # runs on the host
        09_gentoo_first_boot.sh) continue ;; # runs on the booted system
    esac
    install -m 0755 "$s" "${MNT}/root/$(basename "$s")"
    printf '    %s\n' "$(basename "$s")"
done

# --- report -----------------------------------------------------------------
say "Bootstrap complete. Current mounts:"
echo
findmnt -R "$MNT" -o TARGET,SOURCE,FSTYPE,SIZE 2>/dev/null || true
echo
cat <<EOF

Next step - enter the chroot and run the setup script:

    sudo chroot ${MNT} /bin/bash -c 'source /etc/profile && /root/03_chroot_setup.sh'

Or enter interactively:

    sudo chroot ${MNT} /bin/bash
    source /etc/profile
    export PS1="(chroot) \${PS1}"

EOF
