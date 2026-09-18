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
            precision_mode=args.precision_mode,
            grad_checkpoint=args.grad_checkpoint,
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
        gc = " +grad-ckpt" if ts.get("grad_checkpoint") else ""
        print(
            f"\nTraining step ({ts['dtype']}/{ts['precision_mode']}{gc}, "
            f"bs={ts['batch_size']} seq={ts['seq_len']})"
        )
        print(
            f"  {ts['seconds_per_step']:.3f} s/step"
            f"   {ts['tokens_per_second']:.0f} tok/s"
            f"   {ts['achieved_tflops']:.2f} TFLOPS"
            f"   MFU {ts['mfu_pct']}%"
        )
        print(
            f"  VRAM  {ts['peak_vram_mib']} MiB peak"
            f"  = {ts['vram_model_state_mib']} model state"
            f" + {ts['vram_activations_mib']} activations"
            f"   ({ts['vram_headroom_mib']} MiB spare)"
        )
    elif ts.get("error") == "out of memory":
        print(
            f"\nTraining step      OUT OF MEMORY at {ts['dtype']}/{ts['precision_mode']}"
            f" bs={ts['batch_size']} seq={ts['seq_len']}"
            f"  (reached {ts.get('peak_vram_mib_before_oom')} MiB)"
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

    # Last, because it is the conclusion the rest of the output supports.
    _print_utilization(r)
    print()


# --------------------------------------------------------------------------
# How much of the card is actually reachable.
#
# This is the question the prototype exists to answer, so it gets its own view
# rather than being inferred from a column of deltas. A delta says "this OS is
# 0.7% faster than that one"; it cannot say whether either one is leaving a
# third of the GPU on the floor. Every ceiling here is already measured by
# `benches` - the numbers below are read back out of the result file, not
# recomputed, so this works on a collected result on a host with no CUDA.
# --------------------------------------------------------------------------

def _utilization(r: dict[str, Any]) -> list[dict[str, Any]]:
    """Achieved-against-ceiling for every path that has a meaningful ceiling."""
    from .spec import PCIE4_X16_PRACTICAL_GBS, RTX3060_SPEC, compute_ceiling

    b = r.get("benchmarks", {})
    rows: list[dict[str, Any]] = []

    def add(path: str, achieved: float | None, unit: str, ceiling: float,
            pct: float | None, note: str = "") -> None:
        if achieved is None:
            return
        # Prefer the percentage the run recorded; fall back to deriving it so a
        # result file written before a given field existed still renders.
        if pct is None:
            pct = round(100.0 * achieved / ceiling, 1) if ceiling else None
        rows.append({"path": path, "achieved": achieved, "unit": unit,
                     "ceiling": ceiling, "pct": pct, "note": note})

    gemm = b.get("peak_gemm", {})
    if "error" not in gemm:
        for dtype in ("fp32", "tf32", "bf16", "fp16"):
            e = gemm.get(dtype)
            if e:
                add(f"compute  {dtype}", e.get("best_tflops"), "TFLOPS",
                    compute_ceiling(dtype), e.get("pct_of_spec"))

    mem = b.get("memory_bandwidth", {})
    add("memory   device", mem.get("bandwidth_gbs"), "GB/s",
        RTX3060_SPEC["memory_bandwidth_gbs"], mem.get("pct_of_spec"))

    p = b.get("pcie", {})
    for kind in ("pinned", "pageable"):
        add(f"transfer h2d {kind}", p.get(f"{kind}_peak_h2d_gbs"), "GB/s",
            PCIE4_X16_PRACTICAL_GBS, p.get(f"{kind}_pct_of_pcie4x16"))

    ts = b.get("train_step", {})
    if "mfu_pct" in ts:
        add(f"training {ts.get('dtype', '?')} step", ts.get("achieved_tflops"), "TFLOPS",
            compute_ceiling(ts.get("dtype", "bf16")), ts.get("mfu_pct"),
            note="model FLOPs utilisation")

    return rows


def _print_utilization(r: dict[str, Any]) -> None:
    rows = _utilization(r)
    if not rows:
        return

    print("\n" + "=" * 72)
    print(f"GPU REACH  [{r['label']}]   how much of the card this OS can actually use")
    print("=" * 72)
    print(f"{'path':<22}{'achieved':>14}{'ceiling':>14}{'reached':>10}")
    print("-" * 72)
    for row in rows:
        pct = row["pct"]
        pct_s = f"{pct:.1f}%" if pct is not None else "n/a"
        achieved = f"{row['achieved']:.2f} {row['unit']}"
        ceiling = f"{row['ceiling']:.2f} {row['unit']}"
        line = f"{row['path']:<22}{achieved:>14}{ceiling:>14}{pct_s:>10}"
        if row["note"]:
            line += f"   {row['note']}"
        print(line)

    # A card is only as usable as the path a real workload is bottlenecked on,
    # so name the worst one rather than leaving it to be spotted in the table.
    scored = [row for row in rows if row["pct"] is not None]
    if scored:
        worst = min(scored, key=lambda row: row["pct"])
        print(f"\n  Weakest path: {worst['path'].strip()} at {worst['pct']:.1f}% of ceiling")
        over = [row for row in scored if row["pct"] > 100.0]
        if over:
            print("  Above 100% means the card boosted past its reference clock, not an error.")


def _extract(r: dict[str, Any]) -> dict[str, float]:
    """Pull out the handful of numbers worth diffing between runs."""
    b = r.get("benchmarks", {})
    flat: dict[str, float] = {}

    for dtype in ("fp32", "tf32", "bf16", "fp16"):
        e = b.get("peak_gemm", {}).get(dtype)
        if e:
            flat[f"gemm.{dtype}.tflops"] = e["best_tflops"]
            # The share of the card reached matters more to this project than
            # the absolute number, so it is diffed too.
            if e.get("pct_of_spec") is not None:
                flat[f"gemm.{dtype}.pct_of_spec"] = e["pct_of_spec"]

    mem = b.get("memory_bandwidth", {})
    if "bandwidth_gbs" in mem:
        flat["memory.gbs"] = mem["bandwidth_gbs"]
        if mem.get("pct_of_spec") is not None:
            flat["memory.pct_of_spec"] = mem["pct_of_spec"]

    p = b.get("pcie", {})
    for k in ("pinned_peak_h2d_gbs", "pageable_peak_h2d_gbs",
              "pinned_pct_of_pcie4x16", "pageable_pct_of_pcie4x16"):
        if k in p:
            flat[f"pcie.{k}"] = p[k]

    lo = b.get("launch_overhead", {})
    for k in ("eager_us_per_launch", "cudagraph_us_per_launch"):
        if k in lo:
            flat[f"launch.{k}"] = lo[k]

    ts = b.get("train_step", {})
    for k in ("seconds_per_step", "tokens_per_second", "mfu_pct", "peak_vram_mib",
              "vram_activations_mib"):
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

        _warn_stack_drift(base_label, ba, label, bb)
    print()
    return 0


# The OS is the variable under test. Everything below is supposed to be held
# fixed, so a difference here is not context for the numbers - it invalidates
# them. This exists because it once did: the 2026-09-18 comparison ran torch
# 2.14.0 against a 2.11.0 baseline and reported a 59% PCIe gain that could
# just as easily have been the torch upgrade. Nothing in the output said so.
_STACK_FIELDS = (
    ("torch", ("torch", "torch"), "torch"),
    ("cuda runtime", ("torch", "cuda_runtime"), "CUDA runtime"),
    ("cudnn", ("torch", "cudnn"), "cuDNN"),
    ("python", ("python",), "Python"),
    ("driver", ("gpu", "driver_version"), "NVIDIA driver"),
)


def _dig(env_snapshot: dict[str, Any], path: tuple[str, ...]) -> Any:
    node: Any = env_snapshot
    for key in path:
        if not isinstance(node, dict):
            return None
        node = node.get(key)
    return node


def _warn_stack_drift(
    base_label: str, base_env: dict[str, Any], label: str, env_snapshot: dict[str, Any]
) -> list[str]:
    """Report software-stack differences between two runs being compared.

    Returns the list of drifted field names so callers can test this without
    parsing stdout.
    """
    drifted: list[str] = []
    lines: list[str] = []
    for _, path, pretty in _STACK_FIELDS:
        a, b = _dig(base_env, path), _dig(env_snapshot, path)
        if a == b or (a is None and b is None):
            continue
        drifted.append(pretty)
        lines.append(f"  {pretty:<14} {a}  ->  {b}")

    if not drifted:
        return []

    print(
        "\n!! SOFTWARE STACK DIFFERS - the deltas above are not attributable to the OS."
        f"\n   {base_label} and {label} did not run the same code:"
    )
    print("\n".join(lines))
    print(
        "   Re-take one side so both match, then compare again. The pin lives in\n"
        "   scripts/09_gentoo_first_boot.sh (TORCH_VERSION)."
    )
    return drifted


def cmd_utilization(args: argparse.Namespace) -> int:
    for path in args.files:
        data = json.loads(Path(path).read_text())
        data.setdefault("label", Path(path).stem)
        _print_utilization(data)
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
    r.add_argument("--precision-mode", default="mixed", choices=["mixed", "pure"],
                   help="mixed: fp32 master weights + autocast (~16 bytes/param, what the "
                        "spec assumes). pure: everything in the low dtype (~8 bytes/param, "
                        "faster but understates real memory use)")
    r.add_argument("--grad-checkpoint", action="store_true",
                   help="recompute activations in the backward pass; trades throughput "
                        "for activation memory")
    r.add_argument("--skip-train", action="store_true",
                   help="skip the training step benchmark")
    r.set_defaults(func=cmd_run)

    c = sub.add_parser("compare", help="diff two or more result files")
    c.add_argument("files", nargs="+")
    c.set_defaults(func=cmd_compare)

    u = sub.add_parser("utilization",
                       help="how much of the GPU each result file actually reached")
    u.add_argument("files", nargs="+")
    u.set_defaults(func=cmd_utilization)

    e = sub.add_parser("env", help="print the environment snapshot and exit")
    e.set_defaults(func=lambda a: (print(json.dumps(env.capture(), indent=2)), 0)[1])

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
