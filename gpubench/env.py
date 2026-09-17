"""Capture everything about the machine that could move a benchmark number.

A result is only useful next to the configuration that produced it. Comparing
a `stock` run against an `isolcpus` run means nothing unless both runs recorded
which governor was active, what the kernel command line said, and which driver
was loaded. Everything here is cheap to collect and goes into every result file.
"""

from __future__ import annotations

import os
import platform
import re
import shutil
import subprocess
from datetime import datetime, timezone
from pathlib import Path
from typing import Any


def _read(path: str) -> str | None:
    try:
        return Path(path).read_text().strip()
    except OSError:
        return None


def _run(cmd: list[str]) -> str | None:
    if not shutil.which(cmd[0]):
        return None
    try:
        out = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    except (OSError, subprocess.TimeoutExpired):
        return None
    return out.stdout.strip() if out.returncode == 0 else None


def _cpu() -> dict[str, Any]:
    model = None
    cpuinfo = _read("/proc/cpuinfo") or ""
    for line in cpuinfo.splitlines():
        if line.startswith("model name"):
            model = line.split(":", 1)[1].strip()
            break

    # The governor decides whether the CPU that feeds the GPU is allowed to
    # stay at boost clocks. On a 4-core host driving a 3584-core GPU this is
    # not a detail.
    governors = sorted(
        {
            g
            for p in Path("/sys/devices/system/cpu").glob("cpu[0-9]*/cpufreq/scaling_governor")
            if (g := _read(str(p)))
        }
    )

    return {
        "model": model,
        "logical_cpus": os.cpu_count(),
        "governors": governors,
        # Cores removed from the scheduler's general-purpose pool.
        "isolated": _read("/sys/devices/system/cpu/isolated") or "",
        "nohz_full": _read("/sys/devices/system/cpu/nohz_full") or "",
        "smt_active": _read("/sys/devices/system/cpu/smt/active"),
    }


def _memory() -> dict[str, Any]:
    meminfo = _read("/proc/meminfo") or ""
    total_kb = swap_kb = None
    for line in meminfo.splitlines():
        if line.startswith("MemTotal:"):
            total_kb = int(line.split()[1])
        elif line.startswith("SwapTotal:"):
            swap_kb = int(line.split()[1])

    thp = _read("/sys/kernel/mm/transparent_hugepage/enabled")
    # The file reads like "always [madvise] never"; the brackets mark the
    # active setting.
    thp_active = None
    if thp:
        m = re.search(r"\[(\w+)\]", thp)
        thp_active = m.group(1) if m else thp

    return {
        "total_gib": round(total_kb / 1048576, 2) if total_kb else None,
        "swap_gib": round(swap_kb / 1048576, 2) if swap_kb else None,
        "transparent_hugepages": thp_active,
        "hugepages_total": _read("/sys/kernel/mm/hugepages/hugepages-2048kB/nr_hugepages"),
    }


def _os() -> dict[str, Any]:
    os_release = {}
    for line in (_read("/etc/os-release") or "").splitlines():
        if "=" in line:
            k, v = line.split("=", 1)
            os_release[k] = v.strip('"')

    return {
        "distro": os_release.get("PRETTY_NAME"),
        "kernel": platform.release(),
        # The kernel command line carries almost every OS-level knob this
        # project cares about: isolcpus, nohz_full, nvidia-drm.modeset,
        # mitigations, hugepages.
        "cmdline": _read("/proc/cmdline"),
        "hostname": platform.node(),
    }


def _gpu() -> dict[str, Any]:
    fields = [
        "name",
        "driver_version",
        "vbios_version",
        "memory.total",
        "pcie.link.gen.current",
        "pcie.link.gen.max",
        "pcie.link.width.current",
        "pcie.link.width.max",
        "persistence_mode",
        "compute_mode",
        "clocks.max.sm",
        "clocks.max.memory",
        "power.limit",
        "power.max_limit",
    ]
    out = _run(
        ["nvidia-smi", f"--query-gpu={','.join(fields)}", "--format=csv,noheader,nounits"]
    )
    if not out:
        return {"available": False}

    values = [v.strip() for v in out.splitlines()[0].split(",")]
    gpu = dict(zip(fields, values))
    gpu["available"] = True

    # Recorded but never trusted on its own: the link downshifts at idle, so a
    # gen-1 reading here says nothing about the link under load. pcie.py
    # measures the bandwidth that actually matters.
    gpu["note_pcie"] = "link gen/width sampled at idle; see the pcie benchmark for loaded bandwidth"
    return gpu


def _torch() -> dict[str, Any]:
    try:
        import torch
    except ImportError:
        return {"available": False}

    info: dict[str, Any] = {
        "available": True,
        "torch": torch.__version__,
        "cuda_runtime": torch.version.cuda,
        "cudnn": torch.backends.cudnn.version(),
        "cuda_available": torch.cuda.is_available(),
    }
    if torch.cuda.is_available():
        props = torch.cuda.get_device_properties(0)
        info.update(
            {
                "device_name": props.name,
                "capability": f"{props.major}.{props.minor}",
                "sm_count": props.multi_processor_count,
                "vram_total_mib": round(props.total_memory / 1048576),
                # VRAM already spoken for before this process started - a
                # desktop session typically holds a few hundred MiB.
                "vram_free_mib": round(torch.cuda.mem_get_info()[0] / 1048576),
            }
        )
    return info


def capture() -> dict[str, Any]:
    """Collect the full environment snapshot for a result file."""
    return {
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "os": _os(),
        "cpu": _cpu(),
        "memory": _memory(),
        "gpu": _gpu(),
        "torch": _torch(),
        "python": platform.python_version(),
    }


if __name__ == "__main__":
    import json

    print(json.dumps(capture(), indent=2))
