#!/usr/bin/env bash
#
# 05_configure_kernel.sh
#
# Runs INSIDE the Gentoo chroot. Produces a minimal kernel configuration for
# this specific machine, verifies it, and builds it.
#
# APPROACH
#   Start from `make defconfig` and then state every deviation explicitly,
#   rather than driving menuconfig by hand. The config this produces is
#   reproducible, reviewable, and carries the reason for each choice next to
#   the choice - which matters because the whole project is about being able
#   to attribute a performance difference to a specific decision.
#
#   Phase A (this script): a kernel that boots and loads the NVIDIA module.
#   Phase B (later):       strip further, one group at a time, re-measuring.
#   Establishing "works" before chasing "minimal" is the only way to know
#   which removal broke something.
#
# HARDWARE (from lspci on this box)
#   SATA      Intel Raptor Lake AHCI   -> ahci
#   Ethernet  Realtek RTL8125 2.5GbE   -> r8169
#   GPU       NVIDIA GA106 RTX 3060    -> nvidia (open kernel modules)
#   No NVMe, no RAID, no wireless.
#
# Run as:
#   sudo chroot /mnt/gentoo /bin/bash -c 'source /etc/profile && /root/05_configure_kernel.sh'
#
set -euo pipefail

readonly KDIR="/usr/src/linux"
readonly JOBS="$(nproc)"

# Compiled into the image as CONFIG_CMDLINE. Must stay identical to
# BASE_CMDLINE in 07_make_bootable.sh and 12_restore_boot_entries.sh - see the
# CONFIG_CMDLINE block below for why the kernel carries its own copy.
readonly BUILTIN_CMDLINE="root=PARTUUID=3eb15fc3-858e-4b37-abe5-d43c8554799a rw nvidia-drm.modeset=0 console=tty0"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f /etc/gentoo-release ] || die "not inside a Gentoo chroot - refusing"

# gentoo-sources unpacks to /usr/src/linux-<version>-gentoo but does not create
# the /usr/src/linux symlink unless the `symlink` USE flag is set. eselect owns
# that link, so point it at the newest installed tree rather than assuming it
# already exists.
if [ ! -d "$KDIR" ]; then
    say "${KDIR} symlink missing - selecting a kernel source tree"
    command -v eselect >/dev/null 2>&1 || die "eselect not available"

    newest="$(eselect kernel list 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | awk '$2 ~ /^linux-/ { gsub(/[\[\]]/, "", $1); id=$1; name=$2 } END { print id }')"
    [ -n "$newest" ] || die "no kernel sources found - is sys-kernel/gentoo-sources installed?"

    eselect kernel set "$newest"
    eselect kernel list
fi

[ -d "$KDIR" ] || die "${KDIR} still not present after eselect"
[ -f "$KDIR/Makefile" ] || die "${KDIR} exists but has no Makefile - broken source tree"

cd "$KDIR"
say "Kernel source: $(make -s kernelversion 2>/dev/null || echo unknown)  ($(readlink -f "$KDIR"))"

# --- build-time dependencies ------------------------------------------------
missing=()
for t in bc flex bison make gcc ld openssl; do
    command -v "$t" >/dev/null 2>&1 || missing+=("$t")
done
[ -f /usr/include/openssl/opensslv.h ] || missing+=("dev-libs/openssl headers")
if [ ${#missing[@]} -gt 0 ]; then
    say "Installing missing kernel build dependencies: ${missing[*]}"
    emerge --quiet-build --noreplace sys-devel/bc sys-devel/flex sys-devel/bison \
        dev-libs/openssl sys-apps/kmod || die "could not install build dependencies"
fi

# --- start from a known baseline -------------------------------------------
say "Generating defconfig baseline"
make -s defconfig

cfg() { ./scripts/config "$@"; }

say "Applying configuration"

# ---------------------------------------------------------------------------
# NVIDIA module requirements.
# Taken from the CONFIG_CHECK block in nvidia-drivers-595.84.ebuild, which is
# the authoritative list: PROC_FS and X86_PAT are hard requirements, and
# DEBUG_MUTEXES must be off or the module will not build.
# ---------------------------------------------------------------------------
cfg --enable  PROC_FS
cfg --enable  X86_PAT
cfg --enable  SYSVIPC
cfg --disable DEBUG_MUTEXES
cfg --disable LOCKDEP
cfg --disable SLUB_DEBUG_ON
cfg --disable DEBUG_INFO_BTF_MODULES

# PREEMPT_RT is explicitly unsupported by NVIDIA and fails to build against it.
# A voluntary-preemption kernel is also the right choice for a throughput
# workload: fewer preemption points means less scheduler work per unit of
# compute.
cfg --disable PREEMPT_RT
cfg --disable PREEMPT
cfg --enable  PREEMPT_VOLUNTARY

# Modules are required: nvidia.ko is built out-of-tree against this kernel.
cfg --enable  MODULES
cfg --enable  MODULE_UNLOAD

# ---------------------------------------------------------------------------
# Display.
# The target boots headless with nvidia-drm.modeset=0, so the NVIDIA DRM/KMS
# path is never used. Turning off DRM_FBDEV_EMULATION also removes the
# DRM_TTM_HELPER requirement the ebuild imposes on kernels 6.11 and newer.
#
# The EFI framebuffer console is deliberately kept. Without it a boot failure
# during bring-up would be undebuggable - there would be no console to read the
# panic on. It costs almost nothing and can be revisited in phase B once SSH
# access is reliable.
# ---------------------------------------------------------------------------
cfg --disable DRM_FBDEV_EMULATION
cfg --disable DRM_NOUVEAU          # conflicts with the NVIDIA driver
cfg --disable DRM_AMDGPU
cfg --disable DRM_I915
cfg --disable DRM_RADEON
# Console. CONFIG_FB and FRAMEBUFFER_CONSOLE on their own produce a black
# screen - something has to claim the framebuffer the firmware handed over.
#
# sysfb registers one of TWO different platform devices, and which one is not
# knowable in advance. From the kernel documentation for SYSFB_SIMPLEFB: the
# framebuffer is advertised as "simple-framebuffer" when it is compatible with
# the generic modes, and "if the framebuffer is not compatible with the generic
# modes, it is advertised as fallback platform framebuffer so legacy drivers
# like efifb, vesafb and uvesafb can pick it up".
#
#   simple-framebuffer  -> claimed by FB_SIMPLE
#   efi-framebuffer     -> claimed by FB_EFI
#
# Both are enabled because only the firmware decides which one appears, and
# this is the one failure that the QEMU smoke test cannot catch: -kernel boot
# skips the firmware entirely, so no framebuffer is handed over at all and the
# guest falls back to emulated VGA. Getting it wrong means discovering a black
# screen on bare metal with no console to read the reason from.
#
# fbdev rather than DRM_SIMPLEDRM: simpledrm would need DRM_FBDEV_EMULATION
# switched back on to provide a text console, which drags DRM_TTM_HELPER back
# in with it per the nvidia-drivers ebuild. The fbdev drivers attach straight
# to FRAMEBUFFER_CONSOLE.
cfg --enable  SYSFB
cfg --enable  SYSFB_SIMPLEFB
cfg --enable  FB
cfg --enable  FB_CORE
cfg --enable  FB_SIMPLE
cfg --enable  FB_EFI
cfg --enable  FRAMEBUFFER_CONSOLE
cfg --enable  VT
cfg --enable  VT_CONSOLE

# ---------------------------------------------------------------------------
# Storage and root filesystem.
# Built in, not modules: with AHCI and ext4 compiled into the image the system
# boots with no initramfs at all. One less moving part between the bootloader
# and PID 1 - which matters when PID 1 is the thing being replaced.
# ---------------------------------------------------------------------------
cfg --enable  ATA
cfg --enable  ATA_ACPI
cfg --enable  SATA_AHCI
cfg --enable  ATA_SFF
cfg --enable  BLK_DEV_SD
cfg --enable  EXT4_FS
cfg --enable  EXT4_USE_FOR_EXT2
cfg --enable  VFAT_FS                # EFI System Partition
cfg --enable  FAT_FS
cfg --enable  NLS_CODEPAGE_437
cfg --enable  NLS_ISO8859_1
cfg --enable  TMPFS
cfg --enable  TMPFS_POSIX_ACL
cfg --enable  DEVTMPFS
cfg --enable  DEVTMPFS_MOUNT
cfg --enable  PROC_SYSCTL
cfg --enable  SYSFS

# No initramfs.
cfg --disable BLK_DEV_INITRD

# Filesystems this machine will never mount.
for fs in BTRFS_FS XFS_FS F2FS_FS NILFS2_FS JFS_FS REISERFS_FS NTFS3_FS \
          HFS_FS HFSPLUS_FS UDF_FS SQUASHFS CRAMFS MINIX_FS ROMFS_FS \
          NFS_FS NFSD CIFS CEPH_FS GFS2_FS OCFS2_FS; do
    cfg --disable "$fs"
done

# ---------------------------------------------------------------------------
# Networking. Wired only - used for package fetches, dataset downloads and SSH.
# ---------------------------------------------------------------------------
cfg --enable  NET
cfg --enable  INET
cfg --enable  PACKET
cfg --enable  UNIX
cfg --module  R8169                  # Realtek RTL8125 2.5GbE
cfg --enable  ETHERNET
cfg --disable WLAN
cfg --disable WIRELESS
cfg --disable BT                     # bluetooth
cfg --disable IPV6
cfg --disable NETFILTER              # no firewall on a single-purpose box
cfg --disable BRIDGE
cfg --disable VLAN_8021Q
cfg --disable CAN
cfg --disable IRDA

# ---------------------------------------------------------------------------
# Subsystems this machine has no use for. This is where the "minimal install"
# philosophy turns into actual removed code.
# ---------------------------------------------------------------------------
cfg --disable SOUND
cfg --disable SND
cfg --disable SND_HDA_INTEL          # includes the GA106 HDMI audio function
cfg --disable MEDIA_SUPPORT
cfg --disable PARPORT
cfg --disable PRINTER
cfg --disable INPUT_JOYSTICK
cfg --disable INPUT_TABLET
cfg --disable INPUT_TOUCHSCREEN
cfg --disable THUNDERBOLT
cfg --disable INFINIBAND
cfg --disable RFKILL
cfg --disable MACINTOSH_DRIVERS
cfg --disable HAMRADIO
cfg --disable WAN
cfg --disable ISDN
cfg --disable ACCESSIBILITY
cfg --disable STAGING
cfg --disable VIRTUALIZATION         # bare metal only
cfg --disable KVM

# ---------------------------------------------------------------------------
# Things the project specifically depends on.
# ---------------------------------------------------------------------------

# io_uring: the Rust init layer's checkpoint I/O is built on it. Stripping this
# would remove the foundation of the project's core deliverable.
cfg --enable  IO_URING

# Core isolation, for `isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3`.
cfg --enable  CPU_ISOLATION
cfg --enable  NO_HZ_FULL
cfg --enable  RCU_NOCB_CPU

# Explicit hugepages instead of transparent ones, per the project spec: THP's
# background compaction is exactly the kind of unpredictable work a latency
# study does not want.
cfg --enable  HUGETLBFS
cfg --enable  HUGETLB_PAGE
cfg --enable  TRANSPARENT_HUGEPAGE
cfg --enable  TRANSPARENT_HUGEPAGE_MADVISE
cfg --disable TRANSPARENT_HUGEPAGE_ALWAYS

# Frequency scaling, so the governor can actually be set to performance. The
# baseline run found this machine on `powersave`, which throttles the very
# cores that feed the GPU.
cfg --enable  CPU_FREQ
cfg --enable  X86_INTEL_PSTATE
cfg --enable  CPU_FREQ_DEFAULT_GOV_PERFORMANCE
cfg --enable  CPU_FREQ_GOV_PERFORMANCE

# A lower tick rate means less timer work per second on the isolated cores.
cfg --disable HZ_1000
cfg --disable HZ_300
cfg --enable  HZ_250

# OpenRC wants cgroups; the Rust init will likely want them too.
cfg --enable  CGROUPS
cfg --enable  CGROUP_SCHED
cfg --enable  MEMCG

# PCIe link state must stay visible - the baseline showed the link idling at
# gen 1 of 4, and confirming it upshifts under load depends on this.
cfg --enable  PCIEPORTBUS
cfg --enable  PCIEASPM

# EFI boot. The ESP is mounted at /efi and the kernel is booted directly by the
# firmware.
cfg --enable  EFI
cfg --enable  EFI_STUB
cfg --enable  EFIVAR_FS
cfg --enable  EFI_PARTITION

# ---------------------------------------------------------------------------
# A command line compiled into the image, so booting does not depend on NVRAM.
#
# WHY. The command line normally lives in the EFI boot entry's LoadOptions,
# which means it lives in firmware NVRAM - and NVRAM is not ours. This board
# erased the Gentoo boot entries twice on 2026-09-17, the second time within a
# single POST of being written and verified. With the command line only in
# NVRAM, losing those variables means losing root=, which means the disk is
# unbootable until a working Linux is around to run efibootmgr again.
#
# Carrying the command line in the image breaks that dependency. It also makes
# \EFI\BOOT\BOOTX64.EFI a viable boot path (07 installs one): most firmwares
# will offer a disk with no NVRAM entry only if the ESP carries that
# removable-media path, and such a boot passes no LoadOptions at all. Without
# CONFIG_CMDLINE that path panics with no root=; with it, it just boots.
#
# OVERRIDE stays off so the per-configuration entries keep working. On x86 with
# CMDLINE_BOOL=y and CMDLINE_OVERRIDE=n, setup_arch() concatenates the builtin
# line first and the firmware-supplied line after it, and duplicate parameters
# are resolved last-wins. So Gentoo-ML-isolcpus still adds isolcpus= on top, and
# any entry may override root= - while a boot with no LoadOptions at all falls
# back to exactly the line below.
# ---------------------------------------------------------------------------
cfg --enable      CMDLINE_BOOL
cfg --set-str     CMDLINE "$BUILTIN_CMDLINE"
cfg --disable     CMDLINE_OVERRIDE

# Debug noise off - these cost real cycles on every relevant path.
cfg --disable DEBUG_KERNEL
cfg --disable KASAN
cfg --disable KCSAN
cfg --disable UBSAN
cfg --disable FTRACE
cfg --disable KPROBES
cfg --disable LATENCYTOP
cfg --disable SCHED_DEBUG

say "Resolving dependencies (olddefconfig)"
make -s olddefconfig

# ---------------------------------------------------------------------------
# Verify before building. A kernel that is missing AHCI or ext4 does not boot,
# and finding that out after a reboot costs far more than checking here.
# ---------------------------------------------------------------------------
say "Verifying critical options"

check() {
    local opt="$1" want="$2" actual
    actual="$(./scripts/config --state "$opt" 2>/dev/null || echo "?")"
    if [ "$want" = "on" ]; then
        # Built-in or module both count as present.
        if [ "$actual" = "y" ] || [ "$actual" = "m" ]; then
            printf '  %-34s %-4s OK\n' "$opt" "$actual"
        else
            printf '  %-34s %-4s MISSING\n' "$opt" "$actual"
            return 1
        fi
    else
        if [ "$actual" = "n" ] || [ "$actual" = "undef" ]; then
            printf '  %-34s %-4s OK (off)\n' "$opt" "$actual"
        else
            printf '  %-34s %-4s SHOULD BE OFF\n' "$opt" "$actual"
            return 1
        fi
    fi
}

failed=0
echo "  --- required to boot ---"
for o in SATA_AHCI BLK_DEV_SD EXT4_FS VFAT_FS DEVTMPFS DEVTMPFS_MOUNT \
         EFI EFI_STUB EFI_PARTITION PROC_FS SYSFS TMPFS BINFMT_ELF \
         CMDLINE_BOOL; do
    check "$o" on || failed=1
done
check CMDLINE_OVERRIDE off || failed=1

# The builtin command line is a string, not a tristate, so `check` cannot speak
# to it - and the failure mode is quiet. An empty or truncated CONFIG_CMDLINE
# still builds, still boots from an NVRAM entry that supplies its own root=, and
# only panics on the \EFI\BOOT\BOOTX64.EFI path that exists precisely for when
# NVRAM is gone. That is the worst time to find out, so assert it here.
echo "  --- builtin command line (the NVRAM-independent boot path) ---"
actual_cmdline="$(./scripts/config --state CMDLINE 2>/dev/null || echo '?')"
if [ "$actual_cmdline" = "$BUILTIN_CMDLINE" ]; then
    printf '  %-34s OK\n' "CMDLINE"
    printf '  %-34s %s\n' "" "$actual_cmdline"
else
    printf '  %-34s MISMATCH\n' "CMDLINE"
    printf '    expected: %s\n' "$BUILTIN_CMDLINE"
    printf '    actual:   %s\n' "$actual_cmdline"
    failed=1
fi

# root= is the one parameter with no recoverable default. Checked separately
# from the string comparison above so a future edit to BUILTIN_CMDLINE that
# drops it fails here rather than at the next reboot.
case "$actual_cmdline" in
    *root=PARTUUID=*) ;;
    *) echo "  CMDLINE carries no root=PARTUUID= - a fallback boot would panic"
       failed=1 ;;
esac

# Without a driver claiming the firmware framebuffer there is no console, and a
# boot failure becomes unreadable - which defeats the reason for keeping the
# console in the first place.
echo "  --- console (so a failed boot is readable) ---"
# FB_SIMPLE and FB_EFI both required: sysfb picks which platform device to
# register based on the firmware's mode, and only one of the two drivers will
# match whichever it chose.
for o in SYSFB_SIMPLEFB FB_SIMPLE FB_EFI FRAMEBUFFER_CONSOLE VT_CONSOLE; do
    check "$o" on || failed=1
done

echo "  --- required by the NVIDIA module ---"
for o in X86_PAT MODULES MODULE_UNLOAD SYSVIPC; do
    check "$o" on || failed=1
done
for o in DEBUG_MUTEXES PREEMPT_RT DRM_NOUVEAU; do
    check "$o" off || failed=1
done

echo "  --- required by the project ---"
for o in IO_URING CPU_ISOLATION NO_HZ_FULL HUGETLBFS CPU_FREQ R8169 CGROUPS; do
    check "$o" on || failed=1
done

[ "$failed" -eq 0 ] || die "configuration verification failed - not building"

cp .config "/root/kernel-config-$(make -s kernelversion).minimal"
say "Configuration saved to /root/kernel-config-$(make -s kernelversion).minimal"

# --- build ------------------------------------------------------------------
say "Building kernel with -j${JOBS} (this takes a while)"
make -s "-j${JOBS}"

say "Installing modules"
make -s "-j${JOBS}" modules_install

# r8169 is built as a module, so the config check earlier only proved it was
# selected - not that it was built and installed. Without it the machine has no
# network at all, and that is not something to discover after rebooting into a
# system whose only other access path is the console.
# kernelrelease, not kernelversion: modules_install names the directory after
# the release string, and gentoo-sources already carries "-gentoo" in
# EXTRAVERSION - appending it again produces 6.18.48-gentoo-gentoo.
kver="$(make -s kernelrelease)"
if find "/lib/modules/${kver}" -name 'r8169.ko*' -print -quit 2>/dev/null | grep -q .; then
    say "Network driver present: $(find "/lib/modules/${kver}" -name 'r8169.ko*' | head -1)"
else
    die "r8169.ko was not installed under /lib/modules/${kver} - the machine would boot with no network"
fi

say "Installing kernel to /boot"
make -s install

say "Kernel build complete."
echo
echo "Image:   $(ls -la /boot/vmlinuz* 2>/dev/null | tail -1)"
echo "Modules: $(find /lib/modules -maxdepth 1 -type d -name '*gentoo*' | tail -1)"
echo
echo "Config size comparison:"
printf '  %-28s %s options enabled\n' "this minimal config" "$(grep -c '^CONFIG_.*=[ym]' .config)"
if [ -f /proc/config.gz ]; then
    printf '  %-28s %s options enabled\n' "running host kernel" \
        "$(zgrep -c '^CONFIG_.*=[ym]' /proc/config.gz)"
fi
echo
cat <<'EOF'
Next: install the NVIDIA driver against this kernel.

    emerge --ask x11-drivers/nvidia-drivers

The ebuild re-checks its CONFIG_CHECK requirements before building, so a
missing option surfaces as a clear error rather than a broken module.
EOF
