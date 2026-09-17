#!/usr/bin/env bash
#
# 06_nvidia_driver.sh
#
# Runs INSIDE the Gentoo chroot, after 05_configure_kernel.sh.
# Builds the NVIDIA driver against the minimal kernel and configures it for
# headless compute.
#
# VERSION PINNING
#   Pinned to 595.84, which is the version the stock-ubuntu baseline was
#   captured with. This deliberately overrides the project's "always latest"
#   rule for one package: the whole point of the baseline is to attribute a
#   performance difference to the operating system, and that attribution is
#   worthless if the driver changed underneath it at the same time.
#
#   Once stock-ubuntu vs minimal-gentoo has been measured, upgrading the driver
#   becomes its own labelled run and the comparison stays clean.
#
# Run as:
#   sudo chroot /mnt/gentoo /bin/bash -c 'source /etc/profile && /root/06_nvidia_driver.sh'
#
set -euo pipefail

readonly NV_VERSION="595.84"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f /etc/gentoo-release ] || die "not inside a Gentoo chroot - refusing"
[ -d /usr/src/linux ] || die "/usr/src/linux missing - run 05 first"
[ -f /usr/src/linux/.config ] || die "kernel is not configured - run 05 first"

# Derived from the source tree rather than hardcoded, and only after the tree
# is known to exist. kernelrelease is what modules_install names the directory
# after; gentoo-sources already carries "-gentoo" in EXTRAVERSION, so nothing
# may be appended to it.
KVER="$(make -s -C /usr/src/linux kernelrelease)"
readonly KVER
[ -n "$KVER" ] || die "could not determine the kernel release from /usr/src/linux"
[ -d "/lib/modules/${KVER}" ] || die "/lib/modules/${KVER} missing - run 05 first"

say "Target kernel: ${KVER}"

# --- pin the driver version -------------------------------------------------
say "Pinning nvidia-drivers to ${NV_VERSION}"
mkdir -p /etc/portage/package.mask /etc/portage/package.use
cat > /etc/portage/package.mask/nvidia-pin <<EOF
# Held at the version the stock-ubuntu baseline was measured with, so that the
# stock -> minimal comparison isolates the OS rather than mixing in a driver
# change. Lift this once that comparison is recorded.
>x11-drivers/nvidia-drivers-${NV_VERSION}
EOF

# --- USE flags --------------------------------------------------------------
# persistenced is the one that matters here: the baseline found
# persistence_mode=Disabled, which lets the driver unload between processes and
# the clocks fall with it. On a headless box there is no display server holding
# the device open, so without the daemon every run pays that cost.
#
# tools (nvidia-settings) needs X and there is no X on this system.
say "Writing USE flags"
cat > /etc/portage/package.use/nvidia <<'EOF'
x11-drivers/nvidia-drivers persistenced -tools -static-libs -powerd
EOF

# --- build ------------------------------------------------------------------
# The ebuild re-checks its CONFIG_CHECK list against /usr/src/linux/.config
# before compiling, so a kernel option stripped too far shows up here as a
# named error rather than as a module that silently fails to load later.
say "Emerging x11-drivers/nvidia-drivers-${NV_VERSION}"
emerge --quiet-build x11-drivers/nvidia-drivers || die "nvidia-drivers build failed"

# --- verify the modules actually exist --------------------------------------
say "Verifying built modules"
missing=0
for m in nvidia nvidia-uvm nvidia-modeset nvidia-drm; do
    if find "/lib/modules/${KVER}" -name "${m}.ko*" -print -quit | grep -q .; then
        printf '  %-16s OK\n' "$m"
    else
        printf '  %-16s MISSING\n' "$m"
        [ "$m" = "nvidia" ] || [ "$m" = "nvidia-uvm" ] && missing=1
    fi
done
[ "$missing" -eq 0 ] || die "nvidia.ko or nvidia-uvm.ko was not built - CUDA will not work"

depmod -a "$KVER"

# --- runtime configuration --------------------------------------------------
# modeset=0 keeps the driver out of the display path entirely. Nothing on this
# machine draws to a screen through the GPU, and the baseline measured 473 MiB
# of VRAM held by the desktop session - this is what reclaims it.
say "Writing /etc/modprobe.d/nvidia.conf"
cat > /etc/modprobe.d/nvidia.conf <<'EOF'
# Headless compute node: the GPU never drives a display.
options nvidia-drm modeset=0

# Use the page attribute table for memory mapping rather than MTRRs. This is
# why CONFIG_X86_PAT is a hard requirement of the driver.
options nvidia NVreg_UsePageAttributeTable=1
EOF

# nouveau is not even built into this kernel, but the blacklist costs nothing
# and makes the intent explicit for anyone reading the system later.
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

say "Configuring module autoload (OpenRC)"
cat > /etc/conf.d/modules <<'EOF'
# nvidia_uvm is what CUDA actually talks to; loading it at boot avoids paying
# the module load on the first process that touches the GPU.
modules="nvidia nvidia_uvm"
EOF

# --- persistence daemon -----------------------------------------------------
if rc-service --exists nvidia-persistenced 2>/dev/null; then
    say "Enabling nvidia-persistenced at boot"
    rc-update add nvidia-persistenced default
else
    say "WARNING: nvidia-persistenced init script not found; persistence mode will stay off"
fi

# --- report -----------------------------------------------------------------
say "NVIDIA driver installed."
echo
echo "Installed version:"
qlist -ICv x11-drivers/nvidia-drivers 2>/dev/null || equery list nvidia-drivers 2>/dev/null
echo
echo "Modules in /lib/modules/${KVER}:"
find "/lib/modules/${KVER}" -name 'nvidia*.ko*' -printf '  %f\n' 2>/dev/null | sort
echo
cat <<'EOF'
The driver cannot be loaded from inside the chroot - the running kernel here is
the host's, not the one just built. It gets exercised on the first real boot.

Next: bootloader, so the machine can boot this kernel on its own.
EOF
