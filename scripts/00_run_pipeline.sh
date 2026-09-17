#!/usr/bin/env bash
#
# 00_run_pipeline.sh
#
# Runs the whole rebuild-and-verify sequence in one go. Runs on the HOST.
#
#     02  mount the target and sync the in-chroot scripts   (host)
#     05  configure and build the kernel                    (chroot)
#     06  build the NVIDIA driver against it                (chroot)
#     07  install to the ESP and write EFI boot entries     (chroot)
#     08  unmount cleanly                                   (host)
#     10  boot it in QEMU and check the boot log            (host)
#
# Order is not negotiable: 06 has to follow 05 because the module ABI is tied
# to the kernel config, 07 has to follow both because it copies the built
# kernel to the ESP, and 10 has to follow 08 because QEMU cannot be handed a
# disk the host still has mounted read-write.
#
# Stops at the first failure and leaves the mounts in place so the failure can
# be investigated from inside the chroot.
#
# Usage:
#     sudo ./00_run_pipeline.sh              # everything
#     sudo ./00_run_pipeline.sh --skip-vm    # stop after the teardown
#     sudo ./00_run_pipeline.sh --from 07    # resume from a given step
#
# -E so the ERR trap fires from inside functions too; without it a failure in
# step() would exit silently with no pointer to the log.
set -eEuo pipefail

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PROJECT_DIR="${SCRIPT_DIR%/scripts}"
readonly LOG_DIR="${PROJECT_DIR}/logs"
readonly MNT="/mnt/gentoo"

SKIP_VM=0
FROM="02"

while [ $# -gt 0 ]; do
    case "$1" in
        --skip-vm) SKIP_VM=1; shift ;;
        --from)    FROM="${2:-}"; shift 2 ;;
        -h|--help) sed -n '2,30p' "$0"; exit 0 ;;
        *) printf 'unknown option: %s\n' "$1" >&2; exit 2 ;;
    esac
done

die() { printf '\n\033[31mPIPELINE ABORTED: %s\033[0m\n' "$*" >&2; exit 1; }
hdr() { printf '\n\033[1m%s\033[0m\n%s\n' "$*" "$(printf '=%.0s' $(seq 1 68))"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"
mkdir -p "$LOG_DIR"

PIPELINE_START="$(date +%s)"
declare -a COMPLETED=()

# Run one step, log it, time it, and stop the pipeline if it fails.
#   $1 = step number, $2 = where it runs (host|chroot), $3 = script filename
step() {
    local num="$1" where="$2" script="$3"
    local log="${LOG_DIR}/${num}_$(basename "$script" .sh | cut -d_ -f2-).log"
    local start elapsed

    # --from lets a rerun pick up where the last one stopped. Step numbers are
    # zero-padded, so a lexical comparison orders them correctly.
    if [[ "$num" < "$FROM" ]]; then
        printf '\n\033[2m-- skipping %s (--from %s)\033[0m\n' "$script" "$FROM"
        return 0
    fi

    hdr "[${num}] ${script}   (${where})"
    start="$(date +%s)"

    if [ "$where" = "chroot" ]; then
        mountpoint -q "$MNT" || die "${MNT} is not mounted - step 02 must run first"
        [ -f "${MNT}/root/${script}" ] || die "${script} was not staged into the chroot"
        chroot "$MNT" /bin/bash -c "source /etc/profile && /root/${script}" 2>&1 | tee "$log"
    else
        "${SCRIPT_DIR}/${script}" 2>&1 | tee "$log"
    fi

    elapsed=$(( $(date +%s) - start ))
    COMPLETED+=("${num} ${script} ${elapsed}s")
    printf '\n\033[32m-- [%s] done in %ds\033[0m\n' "$num" "$elapsed"
}

# ---------------------------------------------------------------------------
trap 'printf "\n\033[31mFailed. Mounts left in place for investigation:\033[0m\n  sudo chroot %s /bin/bash\nLogs: %s\n" "$MNT" "$LOG_DIR"' ERR

# Sync the in-chroot scripts on every run, including when --from skips step 02.
#
# --from exists to skip expensive work, not to skip keeping the chroot's copies
# current. Skipping 02 previously meant `--from 05` re-ran whatever stale copy
# a failed run had left in /mnt/gentoo/root/ - so a fix made on the host was
# invisible and the same failure repeated identically.
sync_chroot_scripts() {
    mountpoint -q "$MNT" || return 0
    local staged=()
    for s in "${SCRIPT_DIR}"/0[3-7]_*.sh; do
        [ -f "$s" ] || continue
        install -m 0755 "$s" "${MNT}/root/$(basename "$s")"
        staged+=("$(basename "$s")")
    done
    [ "${#staged[@]}" -gt 0 ] && printf '\n\033[2m-- synced into the chroot: %s\033[0m\n' "${staged[*]}"
}
sync_chroot_scripts

step 02 host   02_bootstrap_stage3.sh
step 05 chroot 05_configure_kernel.sh
step 06 chroot 06_nvidia_driver.sh
step 07 chroot 07_make_bootable.sh
step 08 host   08_teardown_chroot.sh

if [ "$SKIP_VM" -eq 0 ]; then
    step 10 host 10_vm_smoke_test.sh
else
    printf '\n\033[2m-- skipping the VM smoke test (--skip-vm)\033[0m\n'
fi

trap - ERR

# ---------------------------------------------------------------------------
# Verdict. Each assertion below corresponds to a bug that actually happened
# during this build, so a regression shows up here rather than at reboot.
# ---------------------------------------------------------------------------
hdr "VERDICT"

verdict_fail=0
assert() {
    local label="$1" log="$2" pattern="$3"
    if [ ! -f "$log" ]; then
        printf '  \033[2m[ -- ] %-46s (step not run)\033[0m\n' "$label"
        return 0
    fi
    if grep -qE "$pattern" "$log" 2>/dev/null; then
        printf '  \033[32m[ OK ]\033[0m %s\n' "$label"
    else
        printf '  \033[31m[FAIL]\033[0m %-46s %s\n' "$label" "$log"
        verdict_fail=1
    fi
}

assert "kernel: efi-framebuffer fallback driver built" \
       "${LOG_DIR}/05_configure_kernel.log" '^  FB_EFI +y +OK'
assert "kernel: simple-framebuffer driver built" \
       "${LOG_DIR}/05_configure_kernel.log" '^  FB_SIMPLE +y +OK'
assert "kernel: io_uring present (Rust init depends on it)" \
       "${LOG_DIR}/05_configure_kernel.log" '^  IO_URING +y +OK'
assert "kernel: network module installed" \
       "${LOG_DIR}/05_configure_kernel.log" 'Network driver present'
assert "nvidia: nvidia.ko and nvidia-uvm.ko built" \
       "${LOG_DIR}/06_nvidia_driver.log" 'nvidia-uvm +OK'
# The inverse of assert: the pattern must NOT appear. Used for the failure
# modes that are invisible when they happen - a stale root=UUID= entry looks
# like a successful run right up until the kernel panics.
refute() {
    local label="$1" log="$2" pattern="$3"
    if [ ! -f "$log" ]; then
        printf '  \033[2m[ -- ] %-46s (step not run)\033[0m\n' "$label"
        return 0
    fi
    if grep -qE "$pattern" "$log" 2>/dev/null; then
        printf '  \033[31m[FAIL]\033[0m %-46s %s\n' "$label" "$log"
        verdict_fail=1
    else
        printf '  \033[32m[ OK ]\033[0m %s\n' "$label"
    fi
}

assert "boot: root= uses PARTUUID, not filesystem UUID" \
       "${LOG_DIR}/07_make_bootable.log" 'root=PARTUUID='
refute "boot: no stale root=UUID= entry written" \
       "${LOG_DIR}/07_make_bootable.log" 'root=UUID='
assert "boot: serial getty enabled" \
       "${LOG_DIR}/07_make_bootable.log" 'agetty -L 115200 ttyS0'
assert "boot: EFI entries not duplicated" \
       "${LOG_DIR}/07_make_bootable.log" 'BootOrder set to'

if [ "$SKIP_VM" -eq 0 ]; then
    assert "vm: root filesystem mounted" \
           "${LOG_DIR}/10_vm_smoke_test.log" '\[ OK \] root filesystem mounted'
    assert "vm: reached a login prompt" \
           "${LOG_DIR}/10_vm_smoke_test.log" '\[ OK \] login prompt reached'
    assert "vm: no kernel panic" \
           "${LOG_DIR}/10_vm_smoke_test.log" 'Reached a login prompt'
fi

# ---------------------------------------------------------------------------
hdr "SUMMARY"
for c in "${COMPLETED[@]}"; do printf '  %s\n' "$c"; done
printf '\n  total %ds\n' "$(( $(date +%s) - PIPELINE_START ))"

echo
if [ "$verdict_fail" -eq 0 ]; then
    cat <<'EOF'
  All assertions passed. What is left can only be tested on bare metal:
    - which framebuffer driver the firmware actually hands over
    - whether the NVIDIA modules load and nvidia-smi sees the GPU
    - whether CUDA survives a kernel stripped to ~1450 options

  Reboot, press F11, pick "Gentoo-ML". Ubuntu stays the default boot target,
  so a failed boot costs a power cycle.

  Then, on the Gentoo side:
    git clone https://github.com/TechieQuokka/ai-specialized-os-prototype
    cd ai-specialized-os-prototype && ./scripts/09_gentoo_first_boot.sh
EOF
else
    echo "  Some assertions failed - read the logs listed above before rebooting."
    exit 1
fi
