#!/usr/bin/env bash
#
# 11_collect_from_target.sh
#
# Runs on the UBUNTU HOST after rebooting back from Gentoo. Mounts the target
# filesystem READ-ONLY, copies the diagnostic bundle that 09 left behind, and
# unmounts again.
#
# Both disks live in the same machine, so the benchmark results and boot
# diagnostics never need to travel over the network - no GitHub authentication
# from a freshly installed system with no credentials on it.
#
# Read-only throughout: this script only ever reads from the Gentoo
# installation, so running it cannot disturb the system under test.
#
# Run as: sudo ./11_collect_from_target.sh
#
set -euo pipefail

readonly TARGET_SERIAL="Z6CFSL8MS"
readonly ROOT_PARTUUID="3eb15fc3-858e-4b37-abe5-d43c8554799a"
readonly REMOTE_HANDOFF="root/handoff"

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
readonly SCRIPT_DIR
readonly PROJECT_DIR="${SCRIPT_DIR%/scripts}"
readonly DEST="${PROJECT_DIR}/logs/from-target"

die() { printf '\nABORT: %s\n' "$*" >&2; exit 1; }
say() { printf '\n==> %s\n' "$*"; }

[ "$(id -u)" -eq 0 ] || die "must run as root (use sudo)"

# --- locate the target, by serial as everywhere else ------------------------
say "Locating the target disk"
target=""
for dev in /dev/sd[a-z]; do
    [ -b "$dev" ] || continue
    if [ "$(lsblk -dno SERIAL "$dev" 2>/dev/null | tr -d '[:space:]')" = "$TARGET_SERIAL" ]; then
        target="$dev"; break
    fi
done
[ -n "$target" ] || die "no disk with serial ${TARGET_SERIAL} attached"

root_part="$(readlink -f "/dev/disk/by-partuuid/${ROOT_PARTUUID}" 2>/dev/null || true)"
[ -b "$root_part" ] || die "root partition ${ROOT_PARTUUID} not found"
parent="/dev/$(lsblk -no PKNAME "$root_part" | head -1)"
[ "$parent" = "$target" ] || die "${root_part} is on ${parent}, not the expected ${target}"
echo "  ${root_part} on ${target}"

# --- mount read-only --------------------------------------------------------
tmpmnt="$(mktemp -d)"
cleanup() { mountpoint -q "$tmpmnt" && umount "$tmpmnt"; rmdir "$tmpmnt" 2>/dev/null || true; }
trap cleanup EXIT

say "Mounting read-only"
mount -o ro,noload "$root_part" "$tmpmnt" 2>/dev/null \
    || mount -o ro "$root_part" "$tmpmnt" \
    || die "could not mount ${root_part} read-only"

# --- copy the bundle --------------------------------------------------------
src="${tmpmnt}/${REMOTE_HANDOFF}"
if [ ! -d "$src" ]; then
    say "No handoff bundle at /${REMOTE_HANDOFF} on the target."
    echo "  Either 09_gentoo_first_boot.sh was never run, or it was run from a"
    echo "  shell where \$HOME was not root's. Looking for stray results anyway:"
    find "$tmpmnt/root" "$tmpmnt/home" -maxdepth 4 -name '*.json' -path '*results*' 2>/dev/null \
        | sed "s|${tmpmnt}|  /|" | head
    exit 1
fi

mkdir -p "$DEST"
cp -a "${src}/." "$DEST/"
chown -R "${SUDO_USER:-root}:${SUDO_USER:-root}" "$DEST" 2>/dev/null || true

say "Collected into ${DEST}"
ls -la "$DEST" | tail -n +2 | sed 's/^/  /'

# --- the headline facts, so the answer is visible without opening anything --
say "First look"

if [ -f "${DEST}/summary.txt" ]; then
    sed 's/^/  /' "${DEST}/summary.txt"
fi

echo
if grep -qE 'NVIDIA-SMI|CUDA Version' "${DEST}/nvidia-smi.txt" 2>/dev/null; then
    echo "  nvidia-smi: WORKED"
    grep -E 'NVIDIA-SMI|RTX 3060|MiB /' "${DEST}/nvidia-smi.txt" | sed 's/^/    /'
else
    echo "  nvidia-smi: DID NOT WORK - this is the thing to look at"
    head -5 "${DEST}/nvidia-smi.txt" 2>/dev/null | sed 's/^/    /'
fi

echo
if grep -q '^nvidia ' "${DEST}/lsmod.txt" 2>/dev/null; then
    echo "  loaded nvidia modules:"
    grep '^nvidia' "${DEST}/lsmod.txt" | awk '{printf "    %-18s used by %s\n", $1, $3}'
else
    echo "  no nvidia modules loaded"
    grep -iE 'nvidia|NVRM' "${DEST}/dmesg.txt" 2>/dev/null | head -8 | sed 's/^/    /'
fi

echo
if ls "${DEST}"/results/*.json >/dev/null 2>&1; then
    echo "  benchmark results collected:"
    ls -1 "${DEST}"/results/*.json | sed 's|.*/|    |'
    echo
    echo "  Compare against the stock baseline with:"
    echo "    python3 -m gpubench compare results/*stock-ubuntu*.json ${DEST}/results/*minimal-gentoo*.json"
else
    echo "  no benchmark results - the run did not get that far"
fi
echo
