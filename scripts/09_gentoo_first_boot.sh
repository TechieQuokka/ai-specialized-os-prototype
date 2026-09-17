#!/usr/bin/env bash
#
# 09_gentoo_first_boot.sh
#
# Runs ON THE GENTOO SYSTEM after its first boot. Verifies that the hand-built
# kernel actually works, installs the Python side of the benchmark harness, and
# takes the minimal-gentoo measurement to compare against the stock-ubuntu
# baseline.
#
# To get here from a fresh boot:
#     git clone https://github.com/TechieQuokka/ai-specialized-os-prototype
#     cd ai-specialized-os-prototype
#     ./scripts/09_gentoo_first_boot.sh
#
set -euo pipefail

readonly LABEL="minimal-gentoo"
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly PROJECT_DIR="${SCRIPT_DIR%/scripts}"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }
ok()  { printf '  [ OK ] %s\n' "$*"; }
bad() { printf '  [FAIL] %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root"
[ -f /etc/gentoo-release ] || die "this runs on the Gentoo system, not the Ubuntu host"
[ -d /mnt/gentoo/usr ] && die "this looks like the chroot, not a booted Gentoo system"

failures=0

# ---------------------------------------------------------------------------
# 1. Did the hand-built kernel actually come up the way it was configured?
# ---------------------------------------------------------------------------
say "Kernel"
echo "  $(uname -srm)"
echo "  cmdline: $(cat /proc/cmdline)"

case "$(uname -r)" in
    *gentoo*) ok "running the hand-built kernel" ;;
    *) bad "not running the Gentoo kernel"; failures=$((failures+1)) ;;
esac

# ---------------------------------------------------------------------------
# 2. NVIDIA. This is the real gate: whether the CUDA stack survives a kernel
#    stripped from 10048 options down to ~1457.
# ---------------------------------------------------------------------------
say "NVIDIA driver"
if lsmod | grep -q '^nvidia'; then
    lsmod | grep '^nvidia' | awk '{printf "  %-18s %s\n", $1, $2}'
    ok "modules loaded"
else
    bad "no nvidia modules loaded - try: modprobe nvidia nvidia_uvm"
    failures=$((failures+1))
fi

if command -v nvidia-smi >/dev/null 2>&1 && nvidia-smi >/dev/null 2>&1; then
    nvidia-smi --query-gpu=name,driver_version,memory.total,memory.used,persistence_mode \
        --format=csv,noheader | sed 's/^/  /'
    ok "driver sees the GPU"

    # The stock baseline measured 473 MiB of VRAM held by the desktop session.
    # With nvidia-drm.modeset=0 and no display server, that should be gone.
    used="$(nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits)"
    echo "  VRAM in use before any workload: ${used} MiB  (stock Ubuntu held 473 MiB)"
else
    bad "nvidia-smi cannot talk to the driver"
    failures=$((failures+1))
fi

# ---------------------------------------------------------------------------
# 3. Network
# ---------------------------------------------------------------------------
say "Network"
ip -brief addr show 2>/dev/null | grep -v '^lo' | sed 's/^/  /' || true
if ip route get 1.1.1.1 >/dev/null 2>&1; then
    ok "has a default route"
else
    bad "no route - check: rc-service dhcpcd start"
    failures=$((failures+1))
fi

# ---------------------------------------------------------------------------
# 4. The OS-level knobs this project exists to measure
# ---------------------------------------------------------------------------
say "Tuning state"
gov="$(cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor 2>/dev/null || echo unknown)"
printf '  %-26s %s\n' "cpufreq governor" "$gov"
[ "$gov" = "performance" ] && ok "governor is performance (stock Ubuntu was powersave)" \
    || bad "governor is ${gov}, expected performance"

printf '  %-26s %s\n' "isolated cpus" "$(cat /sys/devices/system/cpu/isolated 2>/dev/null || echo none)"
printf '  %-26s %s\n' "nohz_full" "$(cat /sys/devices/system/cpu/nohz_full 2>/dev/null || echo none)"
printf '  %-26s %s\n' "transparent hugepages" \
    "$(sed -n 's/.*\[\(\w*\)\].*/\1/p' /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null || echo n/a)"
printf '  %-26s %s\n' "swap" "$(swapon --noheadings --show=NAME 2>/dev/null | paste -sd, - || echo none)"

if [ "$failures" -gt 0 ]; then
    die "${failures} check(s) failed - fix these before measuring anything"
fi
say "All checks passed."

# ---------------------------------------------------------------------------
# 5. Python side of the harness.
#
# System Python plus pip, per the project's no-conda/no-venv rule. The torch
# wheel carries its own CUDA runtime, so the only thing the OS has to provide
# is the kernel driver verified above.
# ---------------------------------------------------------------------------
say "Installing the Python harness dependencies"
python3 --version

if ! python3 -m pip --version >/dev/null 2>&1; then
    say "pip not present - installing"
    emerge --quiet-build --noreplace dev-python/pip || python3 -m ensurepip --upgrade
fi

# Gentoo may mark the system Python as externally managed; this project
# deliberately installs into it rather than building a venv.
PIP_FLAGS=()
python3 -c 'import sys,sysconfig,os; sys.exit(0 if os.path.exists(os.path.join(sysconfig.get_path("stdlib"),"EXTERNALLY-MANAGED")) else 1)' \
    && PIP_FLAGS+=(--break-system-packages) || true

if ! python3 -c 'import torch' 2>/dev/null; then
    say "Installing torch (large download - the CUDA runtime ships inside the wheel)"
    python3 -m pip install "${PIP_FLAGS[@]}" torch nvidia-ml-py || die "torch install failed"
else
    ok "torch already installed"
fi

python3 - <<'EOF'
import torch
print(f"  torch {torch.__version__}  cuda {torch.version.cuda}  available={torch.cuda.is_available()}")
if torch.cuda.is_available():
    p = torch.cuda.get_device_properties(0)
    print(f"  {p.name}  sm_{p.major}{p.minor}  {p.total_memory/1048576:.0f} MiB")
EOF

python3 -c 'import torch,sys; sys.exit(0 if torch.cuda.is_available() else 1)' \
    || die "torch cannot see the GPU - the driver works but the CUDA userspace does not"

# ---------------------------------------------------------------------------
# 6. The measurement.
# Same flags as the stock-ubuntu baseline so the comparison isolates the OS.
# ---------------------------------------------------------------------------
say "Running the benchmark (label: ${LABEL})"
cd "$PROJECT_DIR"
python3 -m gpubench run --label "$LABEL" \
    --precision-mode mixed --batch-size 1 --seq-len 1024

say "Comparing against the stock baseline"
stock="$(ls -1 results/*stock-ubuntu*.json 2>/dev/null | tail -1)"
mine="$(ls -1 results/*${LABEL}*.json 2>/dev/null | tail -1)"
if [ -n "$stock" ] && [ -n "$mine" ]; then
    python3 -m gpubench compare "$stock" "$mine"
else
    echo "  need both result files to compare; have stock='${stock}' mine='${mine}'"
fi

cat <<'EOF'

Next, to measure the core-isolation configuration separately: reboot, pick
"Gentoo-ML-isolcpus" from the firmware boot menu, and run

    python3 -m gpubench run --label gentoo-isolcpus --precision-mode mixed \
        --batch-size 1 --seq-len 1024

Then compare all three.
EOF
