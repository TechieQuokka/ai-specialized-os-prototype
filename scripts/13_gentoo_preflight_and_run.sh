#!/usr/bin/env bash
#
# 13_gentoo_preflight_and_run.sh
#
# Runs ON THE BOOTED GENTOO SYSTEM. One command for the whole measurement
# session: diagnose the network, fix it, update the checkout, check the clocks,
# then take the measurement three times.
#
#     /root/run.sh            (the copy placed on the target)
#     ./scripts/13_gentoo_preflight_and_run.sh
#
# Why this exists: the 2026-09-18 10:52 session failed twice over - the machine
# booted with no network interface, and the checkout was three commits behind
# so it would not have measured the new feed path even with network. Both were
# steps a human had to remember. Now neither is.
#
# Ordering matters in one place. The udev diagnosis has to run BEFORE the
# module is loaded by hand, because the unloaded state IS the evidence and it
# is gone the moment modprobe succeeds.
#
# set -e is deliberately NOT used. This script's first job is to collect
# evidence from a machine that is already misbehaving, and a probe that finds
# nothing must not abort the run that was about to explain why.

readonly LABEL="${1:-minimal-gentoo}"
readonly RUNS="${RUNS:-3}"
readonly NIC_PCI="0000:03:00.0"
readonly HANDOFF="/root/handoff"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="${SCRIPT_DIR%/scripts}"
# When run as the bootstrap copy at /root/run.sh there is no scripts/ parent,
# so fall back to the known clone location.
[ -d "${PROJECT_DIR}/scripts" ] || PROJECT_DIR="/root/ai-specialized-os-prototype"
readonly PROJECT_DIR

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }
ok()  { printf '  [ OK ] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f /etc/gentoo-release ] || die "this runs on the booted Gentoo system, not the Ubuntu host"

mkdir -p "$HANDOFF"
readonly LOG="${HANDOFF}/preflight-$(date +%Y%m%dT%H%M%S)-${LABEL}.log"
exec > >(tee -a "$LOG") 2>&1

printf '===========================================================\n'
printf ' preflight + measurement   label=%s  runs=%s\n' "$LABEL" "$RUNS"
printf ' %s\n' "$(date -Is)"
printf '===========================================================\n'

# ---------------------------------------------------------------------------
# 1. Network: evidence first, then repair.
# ---------------------------------------------------------------------------
say "Network state as booted"
ip -brief addr 2>&1 | sed 's/^/  /'
printf '  r8169 loaded: '
lsmod | grep -q '^r8169' && echo yes || echo no

if lsmod | grep -q '^r8169'; then
    ok "r8169 already loaded - udev coldplug worked this boot"
else
    bad "r8169 not loaded - capturing why before touching anything"

    say "udevadm test ${NIC_PCI}  (does the rule chain reach 'kmod load'?)"
    udevadm test "/sys/bus/pci/devices/${NIC_PCI}" 2>&1 | tail -40 | sed 's/^/  /'

    say "What the device says about itself"
    cat "/sys/bus/pci/devices/${NIC_PCI}/modalias" 2>&1 | sed 's/^/  modalias: /'
    lspci -nnk -s "${NIC_PCI}" 2>&1 | sed 's/^/  /'

    say "Did udev ever try? (its own log for this device)"
    udevadm info --query=all --path="/sys/bus/pci/devices/${NIC_PCI}" 2>&1 \
        | head -20 | sed 's/^/  /'

    say "Loading it by hand"
    modprobe -v r8169 2>&1 | sed 's/^/  /'
    sleep 2
    dmesg | tail -20 | sed 's/^/  /'
fi

say "Bringing up DHCP"
rc-service dhcpcd restart 2>&1 | sed 's/^/  /'

# dhcpcd needs a moment; poll rather than guess.
route_ok=0
for _ in $(seq 1 30); do
    if ip route get 1.1.1.1 >/dev/null 2>&1; then route_ok=1; break; fi
    sleep 1
done
ip -brief addr 2>&1 | sed 's/^/  /'
if [ "$route_ok" -eq 1 ]; then
    ok "default route present"
else
    bad "still no route after 30s"
    say "Nothing below this point can work. Reboot to Ubuntu and run"
    echo "  sudo ./scripts/11_collect_from_target.sh"
    echo "  - this log is in the bundle and has the udev evidence in it."
    exit 1
fi

# ---------------------------------------------------------------------------
# 2. Make the fix outlive this boot.
# ---------------------------------------------------------------------------
say "Persisting r8169 in /etc/conf.d/modules"
if grep -qw r8169 /etc/conf.d/modules 2>/dev/null; then
    ok "already named: $(grep '^modules=' /etc/conf.d/modules)"
else
    sed -i 's/^modules="\(.*\)"$/modules="\1 r8169"/' /etc/conf.d/modules
    grep -qw r8169 /etc/conf.d/modules \
        && ok "now: $(grep '^modules=' /etc/conf.d/modules)" \
        || bad "edit did not take - fix /etc/conf.d/modules by hand"
fi

# ---------------------------------------------------------------------------
# 3. The checkout. This is the step whose absence wasted the last session.
# ---------------------------------------------------------------------------
say "Updating the checkout at ${PROJECT_DIR}"
[ -d "${PROJECT_DIR}/.git" ] || die "no git checkout at ${PROJECT_DIR}"
cd "$PROJECT_DIR" || die "cannot cd to ${PROJECT_DIR}"

echo "  before: $(git rev-parse --short HEAD)"
git pull --ff-only 2>&1 | sed 's/^/  /'
echo "  after:  $(git rev-parse --short HEAD)"

# Verify the pull actually delivered the thing being measured, rather than
# trusting that it did. A stale checkout re-measures the existing baseline and
# looks exactly like a successful run.
if grep -q 'feed-path' scripts/09_gentoo_first_boot.sh; then
    ok "09 carries --feed-path"
else
    die "09 has no --feed-path - the checkout is still stale, so this run would
     re-measure the old baseline. Check that the Ubuntu side pushed."
fi

# ---------------------------------------------------------------------------
# 4. Clocks. The governor moves what feeds the GPU, so a wrong one is not
#    comparable to the baseline. 09 now treats this as fatal, so settle it
#    here rather than failing three runs in a row over it.
# ---------------------------------------------------------------------------
say "CPU governor"
gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
if [ "$gov" = "performance" ]; then
    ok "performance"
else
    bad "${gov} - setting performance on all cpus"
    for g in /sys/devices/system/cpu/cpu*/cpufreq/scaling_governor; do
        echo performance > "$g" 2>/dev/null
    done
    gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
    [ "$gov" = "performance" ] && ok "now performance" || bad "still ${gov}"
fi

say "Swap, which must be off for the measurement"
swapon --noheadings --show=NAME 2>/dev/null | sed 's/^/  active: /'
swapoff -a 2>/dev/null && ok "swap off" || ok "no swap was active"

# ---------------------------------------------------------------------------
# 5. Measure.
# ---------------------------------------------------------------------------
say "Running ${RUNS}x 09_gentoo_first_boot.sh (label: ${LABEL})"
rc_any=0
for i in $(seq 1 "$RUNS"); do
    printf '\n----- run %s/%s -----\n' "$i" "$RUNS"
    if ./scripts/09_gentoo_first_boot.sh "$LABEL"; then
        ok "run ${i} finished"
    else
        rc=$?
        bad "run ${i} exited ${rc}"
        rc_any=1
    fi
done

# ---------------------------------------------------------------------------
# 6. Report.
# ---------------------------------------------------------------------------
say "Results now on this machine"
ls -1 "${PROJECT_DIR}/results/"*"${LABEL}"*.json 2>/dev/null | sed 's/^/  /' \
    || echo "  none - the runs did not produce a result file"

printf '\n===========================================================\n'
if [ "$rc_any" -eq 0 ]; then
    echo " All ${RUNS} runs completed."
else
    echo " At least one run failed - the per-run logs in ${HANDOFF} say which check."
fi
cat <<EOF

 Next: reboot back to Ubuntu (plain \`reboot\`, no F11), then there:

     sudo ./scripts/11_collect_from_target.sh

 This log and every per-run log come back with it.
===========================================================
EOF

exit "$rc_any"
