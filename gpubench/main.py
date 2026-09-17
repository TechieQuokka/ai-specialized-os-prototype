"""CLI for the GPU efficiency harness.

    python -m gpubench run --label stock-ubuntu
    python -m gpubench run --label minimal-gentoo
    python -m gpubench compare results/*stock-ubuntu*.json results/*minimal-gentoo*.json

The label is the whole point. A single run says how fast this machine is; two
runs under different OS configurations say what the OS configuration was worth,
which is the question this project exists to answer.
"""

from __future__ import annotations

import argparse
import json
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import Any

from . import env
from .telemetry import Telemetry

# `benches` is imported lazily inside cmd_run: it pulls in torch, and the `env`
# subcommand has to stay usable on a machine where torch is not installed yet.


def _run_one(name: str, fn, **kwargs) -> dict[str, Any]:
    """Run one benchmark with a telemetry sampler attached."""
    print(f"  {name} ... ", end="", flush=True)
    with Telemetry() as tel:
        try:
            result = fn(**kwargs)
        except Exception as exc:
            print(f"FAILED ({exc})")
            return {"error": str(exc), "type": type(exc).__name__}
    result["telemetry"] = tel.summary()
    print("done")
    return result


def cmd_run(args: argparse.Namespace) -> int:
    try:
        import torch
    except ImportError:
        print("torch is not installed - run: pip install -r requirements.txt", file=sys.stderr)
        return 1

    if not torch.cuda.is_available():
        print("CUDA is not available to torch - nothing to measure", file=sys.stderr)
        return 1

    from . import benches

    print(f"Capturing environment (label: {args.label})")
    environment = env.capture()

    gpu = environment.get("gpu", {})
    print(f"  GPU    {gpu.get('name')}  driver {gpu.get('driver_version')}")
    print(f"  kernel {environment['os']['kernel']}")
    print(f"  gov    {','.join(environment['cpu']['governors']) or 'n/a'}")
    vram_free = environment.get("torch", {}).get("vram_free_mib")
    vram_total = environment.get("torch", {}).get("vram_total_mib")
    if vram_free and vram_total:
        held = vram_total - vram_free
        print(f"  VRAM   {held} MiB already held before this process started")

    print("Running benchmarks")
    results: dict[str, Any] = {
        "label": args.label,
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "environment": environment,
        "benchmarks": {},
    }

    b = results["benchmarks"]
    b["peak_gemm"] = _run_one("peak_gemm", benches.peak_gemm)
    b["memory_bandwidth"] = _run_one("memory_bandwidth", benches.memory_bandwidth)
    b["pcie"] = _run_one("pcie", benches.pcie)
    b["launch_overhead"] = _run_one("launch_overhead", benches.launch_overhead)
    if not args.skip_train:
        b["train_step"] = _run_one(
            "train_step",
            benches.train_step,
            batch_size=args.batch_size,
            seq_len=args.seq_len,
            dtype=args.dtype,
        )

    out_dir = Path(args.out)
    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now().strftime("%Y%m%dT%H%M%S")
    path = out_dir / f"{stamp}-{args.label}.json"
    path.write_text(json.dumps(results, indent=2))

    print(f"\nWritten: {path}")
    _summarize(results)
    return 0


def _summarize(r: dict[str, Any]) -> None:
    b = r.get("benchmarks", {})
    print("\n" + "=" * 62)
    print(f"SUMMARY  [{r['label']}]")
    print("=" * 62)

    gemm = b.get("peak_gemm", {})
    if "error" not in gemm:
        print("\nCompute ceiling (best GEMM per dtype)")
        for dtype in ("fp32", "tf32", "bf16", "fp16"):
            e = gemm.get(dtype)
            if not e:
                continue
            print(
                f"  {dtype:5s} {e['best_tflops']:7.2f} TFLOPS"
                f"   {e['pct_of_spec']:5.1f}% of spec"
                f"   {e['speedup_vs_fp32']:5.2f}x vs fp32"
            )

    mem = b.get("memory_bandwidth", {})
    if "bandwidth_gbs" in mem:
        print(
            f"\nMemory bandwidth   {mem['bandwidth_gbs']:6.1f} GB/s"
            f"   ({mem['pct_of_spec']}% of 360 GB/s)"
        )

    p = b.get("pcie", {})
    if "pinned_peak_h2d_gbs" in p:
        print(
            f"PCIe H2D peak      {p['pinned_peak_h2d_gbs']:6.2f} GB/s pinned"
            f"   vs {p.get('pageable_peak_h2d_gbs', 0):.2f} GB/s pageable"
        )

    lo = b.get("launch_overhead", {})
    if "eager_us_per_launch" in lo:
        line = f"Kernel launch      {lo['eager_us_per_launch']:6.2f} us eager"
        if "cudagraph_us_per_launch" in lo:
            line += f"   {lo['cudagraph_us_per_launch']:.2f} us graphed ({lo['graph_speedup']}x)"
        print(line)

    ts = b.get("train_step", {})
    if "mfu_pct" in ts:
        print(
            f"\nTraining step      {ts['seconds_per_step']:.3f} s"
            f"   {ts['tokens_per_second']:.0f} tok/s"
            f"   MFU {ts['mfu_pct']}%"
            f"   peak VRAM {ts['peak_vram_mib']} MiB"
        )

    # Any throttling means the ceilings above were the card's limits speaking,
    # not the code's.
    throttled = []
    for name, entry in b.items():
        tel = entry.get("telemetry", {})
        for reason, frac in (tel.get("throttle_active") or {}).items():
            throttled.append(f"{name}:{reason}={frac:.0%}")
    if throttled:
        print("\nThrottling observed: " + ", ".join(throttled))
    else:
        print("\nNo throttling observed.")
    print()


def _extract(r: dict[str, Any]) -> dict[str, float]:
    """Pull out the handful of numbers worth diffing between runs."""
    b = r.get("benchmarks", {})
    flat: dict[str, float] = {}

    for dtype in ("fp32", "tf32", "bf16", "fp16"):
        e = b.get("peak_gemm", {}).get(dtype)
        if e:
            flat[f"gemm.{dtype}.tflops"] = e["best_tflops"]

    if "bandwidth_gbs" in b.get("memory_bandwidth", {}):
        flat["memory.gbs"] = b["memory_bandwidth"]["bandwidth_gbs"]

    p = b.get("pcie", {})
    for k in ("pinned_peak_h2d_gbs", "pageable_peak_h2d_gbs"):
        if k in p:
            flat[f"pcie.{k}"] = p[k]

    lo = b.get("launch_overhead", {})
    for k in ("eager_us_per_launch", "cudagraph_us_per_launch"):
        if k in lo:
            flat[f"launch.{k}"] = lo[k]

    ts = b.get("train_step", {})
    for k in ("seconds_per_step", "tokens_per_second", "mfu_pct", "peak_vram_mib"):
        if k in ts:
            flat[f"train.{k}"] = ts[k]

    return flat


def cmd_compare(args: argparse.Namespace) -> int:
    runs = []
    for path in args.files:
        data = json.loads(Path(path).read_text())
        runs.append((data.get("label", Path(path).stem), _extract(data), data))

    if len(runs) < 2:
        print("need at least two result files to compare", file=sys.stderr)
        return 1

    base_label, base, base_raw = runs[0]
    print(f"\nBaseline: {base_label}")
    for label, flat, raw in runs[1:]:
        print(f"\n{'=' * 72}\n{base_label}  ->  {label}\n{'=' * 72}")
        print(f"{'metric':<34}{base_label[:14]:>14}{label[:14]:>14}{'delta':>10}")
        print("-" * 72)
        for key in sorted(set(base) | set(flat)):
            a, bv = base.get(key), flat.get(key)
            if a is None or bv is None:
                continue
            # Lower is better for latency and memory footprint.
            lower_better = "us_per_launch" in key or "seconds_per_step" in key or "vram" in key
            delta = (bv - a) / a * 100 if a else 0.0
            arrow = ""
            if abs(delta) >= 1.0:
                improved = (delta < 0) if lower_better else (delta > 0)
                arrow = " +" if improved else " -"
            print(f"{key:<34}{a:>14.2f}{bv:>14.2f}{delta:>9.1f}%{arrow}")

        # The configuration difference is usually the explanation for the
        # numbers above, so show it right underneath them.
        ba, bb = base_raw["environment"], raw["environment"]
        diffs = []
        if ba["os"]["cmdline"] != bb["os"]["cmdline"]:
            diffs.append("kernel cmdline")
        if ba["cpu"]["governors"] != bb["cpu"]["governors"]:
            diffs.append(f"governor {ba['cpu']['governors']} -> {bb['cpu']['governors']}")
        if ba["os"]["kernel"] != bb["os"]["kernel"]:
            diffs.append(f"kernel {ba['os']['kernel']} -> {bb['os']['kernel']}")
        if ba["os"]["distro"] != bb["os"]["distro"]:
            diffs.append(f"distro {ba['os']['distro']} -> {bb['os']['distro']}")
        if diffs:
            print("\nConfiguration differences: " + "; ".join(diffs))
    print()
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="gpubench", description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)

    r = sub.add_parser("run", help="run the benchmark suite and write a result file")
    r.add_argument("--label", required=True,
                   help="configuration name, e.g. stock-ubuntu or minimal-gentoo")
    r.add_argument("--out", default="results", help="output directory")
    r.add_argument("--batch-size", type=int, default=4)
    r.add_argument("--seq-len", type=int, default=1024)
    r.add_argument("--dtype", default="bf16", choices=["bf16", "fp16", "fp32"])
    r.add_argument("--skip-train", action="store_true",
                   help="skip the training step benchmark")
    r.set_defaults(func=cmd_run)

    c = sub.add_parser("compare", help="diff two or more result files")
    c.add_argument("files", nargs="+")
    c.set_defaults(func=cmd_compare)

    e = sub.add_parser("env", help="print the environment snapshot and exit")
    e.set_defaults(func=lambda a: (print(json.dumps(env.capture(), indent=2)), 0)[1])

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
