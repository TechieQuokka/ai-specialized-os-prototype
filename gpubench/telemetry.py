"""Sample GPU clocks, power, temperature and throttle reasons during a run.

An achieved-TFLOPS number on its own cannot distinguish "the code is
inefficient" from "the card spent 40% of the run clamped by its power limit".
Those two need completely different responses, so every benchmark runs with a
sampler attached and reports the throttle breakdown next to the result.
"""

from __future__ import annotations

import threading
import time
from typing import Any

try:
    import pynvml

    NVML_AVAILABLE = True
except ImportError:  # pragma: no cover - environment dependent
    NVML_AVAILABLE = False


def _reason_flags() -> dict[str, int]:
    """Throttle-reason bit flags.

    pynvml renamed these from ``nvmlClocksThrottleReason*`` to
    ``nvmlClocksEventReason*``; both spellings are accepted so the harness runs
    against whichever version the target system ends up with.
    """
    if not NVML_AVAILABLE:
        return {}

    names = {
        "gpu_idle": "GpuIdle",
        "applications_clocks": "ApplicationsClocksSetting",
        "sw_power_cap": "SwPowerCap",
        "hw_slowdown": "HwSlowdown",
        "sync_boost": "SyncBoost",
        "sw_thermal": "SwThermalSlowdown",
        "hw_thermal": "HwThermalSlowdown",
        "hw_power_brake": "HwPowerBrakeSlowdown",
        "display_clocks": "DisplayClockSetting",
    }
    flags = {}
    for key, suffix in names.items():
        for prefix in ("nvmlClocksThrottleReason", "nvmlClocksEventReason"):
            value = getattr(pynvml, prefix + suffix, None)
            if value is not None:
                flags[key] = value
                break
    return flags


def _get_throttle_reasons(handle) -> int:
    for name in (
        "nvmlDeviceGetCurrentClocksThrottleReasons",
        "nvmlDeviceGetCurrentClocksEventReasons",
    ):
        fn = getattr(pynvml, name, None)
        if fn is not None:
            return fn(handle)
    return 0


class Telemetry:
    """Background NVML sampler. Use as a context manager around a benchmark."""

    def __init__(self, index: int = 0, interval: float = 0.05) -> None:
        self.index = index
        self.interval = interval
        self.samples: list[dict[str, Any]] = []
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None
        self._handle = None
        self._flags = _reason_flags()

    def __enter__(self) -> "Telemetry":
        if not NVML_AVAILABLE:
            return self
        pynvml.nvmlInit()
        self._handle = pynvml.nvmlDeviceGetHandleByIndex(self.index)
        self._stop.clear()
        self.samples.clear()
        self._thread = threading.Thread(target=self._loop, daemon=True)
        self._thread.start()
        return self

    def __exit__(self, *exc: object) -> None:
        if self._thread is not None:
            self._stop.set()
            self._thread.join(timeout=5)
        if NVML_AVAILABLE and self._handle is not None:
            try:
                pynvml.nvmlShutdown()
            except pynvml.NVMLError:
                pass

    def _loop(self) -> None:
        h = self._handle
        while not self._stop.is_set():
            try:
                util = pynvml.nvmlDeviceGetUtilizationRates(h)
                self.samples.append(
                    {
                        "t": time.monotonic(),
                        "sm_clock_mhz": pynvml.nvmlDeviceGetClockInfo(h, pynvml.NVML_CLOCK_SM),
                        "mem_clock_mhz": pynvml.nvmlDeviceGetClockInfo(h, pynvml.NVML_CLOCK_MEM),
                        "power_w": pynvml.nvmlDeviceGetPowerUsage(h) / 1000.0,
                        "temp_c": pynvml.nvmlDeviceGetTemperature(h, pynvml.NVML_TEMPERATURE_GPU),
                        "util_gpu_pct": util.gpu,
                        "util_mem_pct": util.memory,
                        "throttle_bits": _get_throttle_reasons(h),
                    }
                )
            except pynvml.NVMLError:
                pass
            self._stop.wait(self.interval)

    def summary(self) -> dict[str, Any]:
        """Aggregate the samples into something worth putting in a result file."""
        if not self.samples:
            return {"available": False, "samples": 0}

        def stats(key: str) -> dict[str, float]:
            vals = [s[key] for s in self.samples]
            return {
                "min": round(min(vals), 2),
                "mean": round(sum(vals) / len(vals), 2),
                "max": round(max(vals), 2),
            }

        # Fraction of samples in which each reason was asserted. gpu_idle is
        # reported but is not a loss: it just means the sampler caught the card
        # between workloads.
        n = len(self.samples)
        throttle = {
            name: round(sum(1 for s in self.samples if s["throttle_bits"] & bit) / n, 4)
            for name, bit in self._flags.items()
        }
        active_throttle = {
            k: v for k, v in throttle.items() if v > 0 and k not in ("gpu_idle", "applications_clocks")
        }

        return {
            "available": True,
            "samples": n,
            "interval_s": self.interval,
            "sm_clock_mhz": stats("sm_clock_mhz"),
            "mem_clock_mhz": stats("mem_clock_mhz"),
            "power_w": stats("power_w"),
            "temp_c": stats("temp_c"),
            "util_gpu_pct": stats("util_gpu_pct"),
            "throttle_fraction": throttle,
            "throttle_active": active_throttle,
            # The single number to read first: if this is non-zero the card
            # was not free to run at its own pace, and every achieved-TFLOPS
            # figure below it is a measurement of the limit, not of the code.
            "throttled_any_fraction": round(
                sum(1 for s in self.samples if s["throttle_bits"] & ~self._flags.get("gpu_idle", 0))
                / n,
                4,
            ),
        }
