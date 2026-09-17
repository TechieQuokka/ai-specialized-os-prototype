#!/usr/bin/env bash
#
# 04_build_world.sh
#
# Runs INSIDE the Gentoo chroot, after 03_chroot_setup.sh.
# This is the long one: update Portage, rebuild @world against the new profile
# and USE flags, then install the base toolset for a headless CUDA box.
#
# Expect hours on an i3-14100F. Everything is logged to /var/log/build-world/
# so a failed step can be read back without re-running.
#
# Run as:
#   sudo chroot /mnt/gentoo /bin/bash -c 'source /etc/profile && /root/04_build_world.sh'
#
set -euo pipefail

readonly LOG_DIR="/var/log/build-world"
readonly STAMP="$(date +%Y%m%dT%H%M%S)"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> [%s] %s\n' "$(date +%H:%M:%S)" "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f /etc/gentoo-release ] \
    || die "not inside a Gentoo chroot (/etc/gentoo-release missing) - refusing"

mkdir -p "$LOG_DIR"

# Run a build step, tee its output to a log, and report how long it took.
step() {
    local name="$1"; shift
    local log="${LOG_DIR}/${STAMP}-${name}.log"
    local start elapsed
    say "START ${name}  (log: ${log})"
    start="$(date +%s)"
    if ! "$@" 2>&1 | tee "$log"; then
        die "step '${name}' failed - see ${log}"
    fi
    elapsed=$(( $(date +%s) - start ))
    say "DONE  ${name}  (${elapsed}s)"
}

say "Build host: $(nproc) threads, $(awk '/MemTotal/{printf "%.1f GiB", $2/1048576}' /proc/meminfo) RAM"
say "MAKEOPTS=$(portageq envvar MAKEOPTS)"

# --- 1. Portage itself ------------------------------------------------------
# Updated first and on its own: a newer Portage may understand metadata or
# dependency syntax that the stage3 copy does not, and hitting that in the
# middle of a multi-hour @world run wastes the whole run.
step portage emerge --oneshot --update --quiet-build sys-apps/portage

# --- 2. @world against the new profile and USE flags ------------------------
# --newuse rebuilds whatever the USE changes in make.conf actually affect;
# --deep walks build-time dependencies too. This is the step that removes the
# graphical stack from the tree rather than merely leaving it unused.
step world emerge --update --deep --newuse --quiet-build @world

# --- 3. Drop packages nothing depends on any more ---------------------------
say "Packages no longer required after the profile change:"
emerge --pretend --depclean || true
step depclean emerge --depclean

# --- 4. Base toolset --------------------------------------------------------
# Deliberately small. Anything not needed to build a kernel, drive the network,
# or run the benchmark harness stays off this machine.
BASE_PKGS=(
    app-admin/sudo
    app-editors/vim
    app-misc/tmux
    app-portage/gentoolkit      # equery, revdep-rebuild
    app-portage/portage-utils   # qlist, used by the report below
    app-portage/eix
    dev-vcs/git
    net-misc/dhcpcd
    net-misc/openssh            # headless access once it boots on its own
    sys-apps/pciutils           # lspci - needed to confirm PCIe link state
    sys-apps/usbutils
    sys-process/htop
    sys-apps/lm-sensors         # thermal/throttle telemetry
    sys-kernel/linux-firmware   # r8169 and friends
    sys-kernel/gentoo-sources   # kernel tree; configured in step 05
    sys-apps/kmod
    sys-boot/efibootmgr
)
step base emerge --quiet-build "${BASE_PKGS[@]}"

# --- 5. Rust toolchain ------------------------------------------------------
# rust-bin, not rust. Building rustc from source on 4 cores costs hours and
# buys nothing: the compiler's own build flags do not affect the performance
# of the init/watchdog binary it produces. The source ebuild stays available
# if a reason to switch ever appears.
step rust emerge --quiet-build dev-lang/rust-bin

# --- 6. Report --------------------------------------------------------------
say "Build complete."
echo
echo "Installed package count: $(qlist -I | wc -l)"
echo "World file:"
cat /var/lib/portage/world
echo
echo "Toolchain versions:"
gcc --version | head -1
rustc --version 2>/dev/null || echo "rustc: not on PATH yet (re-source /etc/profile)"
python --version 2>/dev/null || python3 --version
echo
echo "Confirm the graphical stack never entered the tree:"
for p in x11-base/xorg-server x11-libs/libX11 dev-libs/wayland media-sound/pulseaudio; do
    if qlist -I "$p" >/dev/null 2>&1 && [ -n "$(qlist -I "$p")" ]; then
        echo "  PRESENT  $p"
    else
        echo "  absent   $p"
    fi
done
echo
cat <<'EOF'

Next step: kernel configuration (05).

That step is where the project's actual risk lives - stripping the kernel
config far enough to be minimal while keeping every option the NVIDIA module
needs to build and load. It is worth doing interactively rather than from a
script.

EOF
