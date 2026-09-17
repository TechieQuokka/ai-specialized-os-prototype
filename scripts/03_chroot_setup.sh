#!/usr/bin/env bash
#
# 03_chroot_setup.sh
#
# Runs INSIDE the Gentoo chroot prepared by 02_bootstrap_stage3.sh.
# Does the fast configuration work only: ebuild repository, profile, timezone,
# locale, fstab, hostname. No long compiles happen here - those live in
# 04_build_world.sh so this script stays re-runnable in a couple of minutes.
#
# Run as:
#   sudo chroot /mnt/gentoo /bin/bash -c 'source /etc/profile && /root/03_chroot_setup.sh'
#
set -euo pipefail

readonly ROOT_UUID="bfeafe2f-51cb-4648-bae4-c81009d78e22"
readonly ESP_UUID="930F-3DE2"
readonly SWAP_UUID="69f553c9-5179-49e5-a653-9f0d502e7b77"

readonly HOSTNAME_NEW="gentoo-ml"
readonly TIMEZONE="Asia/Seoul"
readonly PORTAGE_TMPFS_SIZE="12G"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"

# Confirm we really are inside the chroot and not on the Ubuntu host. Without
# this guard a mistyped command would rewrite the host's fstab and timezone.
[ -f /etc/gentoo-release ] \
    || die "not inside a Gentoo chroot (/etc/gentoo-release missing) - refusing"

say "Inside: $(cat /etc/gentoo-release)"

# --- ebuild repository ------------------------------------------------------
# emerge-webrsync is used for the first sync: it pulls a signed snapshot and
# verifies it on its own, so it works before the release keys are installed.
# Plain rsync verification needs sec-keys/openpgp-keys-gentoo-release, which
# is installed further down.
if [ -d /var/db/repos/gentoo/metadata ]; then
    say "Ebuild repository already present - refreshing with emerge --sync"
    if ! emerge --sync --quiet; then
        say "rsync sync failed - falling back to emerge-webrsync"
        emerge-webrsync
    fi
else
    say "Fetching the ebuild repository (emerge-webrsync)"
    mkdir -p /var/db/repos/gentoo
    emerge-webrsync
fi

# --- profile ----------------------------------------------------------------
say "Available profiles:"
eselect profile list | grep -E 'amd64/23\.0' || true

# Deliberately NOT a hardened profile. Hardened adds toolchain and kernel
# mitigations that cost measurable performance, and this machine exists to
# measure performance - the mitigations would show up as noise in every
# benchmark comparison. Deliberately not a desktop profile either.
readonly WANTED_PROFILE="default/linux/amd64/23.0/no-multilib"

profile_id="$(eselect profile list \
    | sed 's/\x1b\[[0-9;]*m//g' \
    | awk -v want="$WANTED_PROFILE" '$2 == want { gsub(/[\[\]]/, "", $1); print $1; exit }')"

if [ -n "$profile_id" ]; then
    say "Selecting profile: ${WANTED_PROFILE} (id ${profile_id})"
    eselect profile set "$profile_id"
else
    die "profile ${WANTED_PROFILE} not offered by eselect - inspect the list above"
fi

say "Active profile:"
eselect profile show

# --- timezone ---------------------------------------------------------------
say "Setting timezone to ${TIMEZONE}"
if [ -f "/usr/share/zoneinfo/${TIMEZONE}" ]; then
    ln -snf "/usr/share/zoneinfo/${TIMEZONE}" /etc/localtime
    echo "$TIMEZONE" > /etc/timezone
else
    say "WARNING: /usr/share/zoneinfo/${TIMEZONE} missing; will be set after timezone-data is built"
    echo "$TIMEZONE" > /etc/timezone
fi

# --- locale -----------------------------------------------------------------
say "Configuring locales"
cat > /etc/locale.gen <<'LOCALEGEN'
C.UTF-8 UTF-8
en_US.UTF-8 UTF-8
LOCALEGEN
locale-gen

# C.utf8 keeps tool output in plain English, which makes build logs and
# benchmark output easier to diff across runs.
eselect locale set C.utf8 || true

# --- fstab ------------------------------------------------------------------
say "Writing /etc/fstab"
cat > /etc/fstab <<FSTAB
# <fs>                                      <mountpoint>      <type>  <opts>                                    <dump> <pass>

UUID=${ROOT_UUID}   /                 ext4    noatime                                   0 1
UUID=${ESP_UUID}                             /efi              vfat    noatime,fmask=0077,dmask=0077             0 2
UUID=${SWAP_UUID}   none              swap    sw                                        0 0

# Portage build scratch in RAM. The root filesystem lives on a 5400 rpm 2.5"
# drive, where the small-file I/O of a compile becomes seek-bound. Sizing this
# at ${PORTAGE_TMPFS_SIZE} does not reserve the memory - tmpfs only consumes what is written.
tmpfs                                        /var/tmp/portage  tmpfs   size=${PORTAGE_TMPFS_SIZE},uid=portage,gid=portage,mode=0775  0 0
FSTAB
cat /etc/fstab

# --- hostname ---------------------------------------------------------------
say "Setting hostname to ${HOSTNAME_NEW}"
echo "$HOSTNAME_NEW" > /etc/hostname
cat > /etc/conf.d/hostname <<HOSTCONF
hostname="${HOSTNAME_NEW}"
HOSTCONF

# --- release keys for future rsync verification ----------------------------
say "Installing Gentoo release keys (enables verified emerge --sync)"
emerge --quiet --noreplace sec-keys/openpgp-keys-gentoo-release || \
    say "WARNING: could not install release keys yet; emerge-webrsync still works"

# --- per-package config skeleton -------------------------------------------
mkdir -p /etc/portage/package.use \
         /etc/portage/package.accept_keywords \
         /etc/portage/package.mask \
         /etc/portage/package.env \
         /etc/portage/env

# Packages whose build trees overflow a 12G tmpfs get pushed back onto disk.
# Slower, but a build that dies at 90% because tmpfs filled up costs more.
cat > /etc/portage/env/large-build.conf <<'LARGEBUILD'
PORTAGE_TMPDIR="/var/tmp/portage-large"
LARGEBUILD

cat > /etc/portage/package.env/large-build <<'PKGENV'
dev-lang/rust           large-build.conf
sys-devel/llvm          large-build.conf
sys-devel/gcc           large-build.conf
dev-lang/spidermonkey   large-build.conf
PKGENV

mkdir -p /var/tmp/portage-large
chown portage:portage /var/tmp/portage-large

# --- report -----------------------------------------------------------------
say "Chroot setup complete."
cat <<'EOF'

Configuration summary:
  profile    default/linux/amd64/23.0/no-multilib   (no hardened, no desktop)
  timezone   Asia/Seoul
  locale     C.utf8
  fstab      root / efi / swap + tmpfs build scratch
  mirrors    KAIST primary

Next step (long - this is where the hours go):

    /root/04_build_world.sh

EOF
