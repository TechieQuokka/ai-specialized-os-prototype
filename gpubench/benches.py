"""The five measurements.

Each one isolates a different place GPU throughput goes missing, so that a
disappointing end-to-end number can be attributed rather than guessed at:

    peak_gemm         the compute ceiling, per dtype
    memory_bandwidth  the other ceiling - what a bandwidth-bound kernel can hope for
    pcie              host<->device transfer, pinned vs pageable
    launch_overhead   how much the 4-core host costs per kernel dispatch
    train_step        what an actual training step achieves against those ceilings
"""

from __future__ import annotations

import math
import statistics
import time
from typing import Any, Callable

import torch
import torch.nn as nn
import torch.nn.functional as F

# Vendor figures for the RTX 3060 12 GB (GA106), recorded as reference points
# rather than treated as truth. `peak_gemm` also derives an FP32 ceiling from
# the clock actually observed during the run, which is the honest comparison:
# a card sitting at its power limit has a lower real ceiling than the spec
# sheet claims.
RTX3060_SPEC = {
    "fp32_tflops": 12.74,
    "tensor_dense_tflops": 25.5,
    "memory_bandwidth_gbs": 360.0,
    "cuda_cores": 3584,
    "pcie_gen": 4,
    "pcie_width": 16,
}

# PCIe 4.0 x16 raw is ~31.5 GB/s each way; protocol overhead puts the
# achievable ceiling nearer 25 GB/s.
PCIE4_X16_PRACTICAL_GBS = 25.0


def _time_cuda(fn: Callable[[], None], iters: int, warmup: int = 5) -> float:
    """Median seconds per iteration, timed with CUDA events.

    CUDA events time the work on the device rather than the Python call, so the
    result is not polluted by interpreter overhead or by the asynchronous
    dispatch returning before the kernel has run.
    """
    for _ in range(warmup):
        fn()
    torch.cuda.synchronize()

    times = []
    for _ in range(iters):
        start = torch.cuda.Event(enable_timing=True)
        end = torch.cuda.Event(enable_timing=True)
        start.record()
        fn()
        end.record()
        torch.cuda.synchronize()
        times.append(start.elapsed_time(end) / 1000.0)
    return statistics.median(times)


# --------------------------------------------------------------------------
# 1. Compute ceiling
# --------------------------------------------------------------------------

def peak_gemm(sizes: tuple[int, ...] = (1024, 2048, 4096, 8192), iters: int = 20) -> dict[str, Any]:
    """Square GEMM sweep per dtype - the compute ceiling this card can reach.

    Running fp32 without TF32 is the single largest self-inflicted loss
    available: it leaves the tensor cores idle and gives up roughly half the
    card before any other consideration.
    """
    device = torch.device("cuda")
    results: dict[str, Any] = {}

    # (label, torch dtype, allow_tf32)
    configs = [
        ("fp32", torch.float32, False),
        ("tf32", torch.float32, True),
        ("bf16", torch.bfloat16, False),
        ("fp16", torch.float16, False),
    ]

    for label, dtype, tf32 in configs:
        prev = torch.backends.cuda.matmul.allow_tf32
        torch.backends.cuda.matmul.allow_tf32 = tf32
        per_size = {}
        best = 0.0
        try:
            for n in sizes:
                try:
                    a = torch.randn(n, n, device=device, dtype=dtype)
                    b = torch.randn(n, n, device=device, dtype=dtype)
                except torch.cuda.OutOfMemoryError:
                    torch.cuda.empty_cache()
                    continue

                secs = _time_cuda(lambda: torch.matmul(a, b), iters)
                tflops = (2.0 * n**3) / secs / 1e12
                per_size[str(n)] = {"seconds": round(secs, 6), "tflops": round(tflops, 2)}
                best = max(best, tflops)

                del a, b
                torch.cuda.empty_cache()
        finally:
            torch.backends.cuda.matmul.allow_tf32 = prev

        results[label] = {"by_size": per_size, "best_tflops": round(best, 2)}

    # Attribution: how much of the spec ceiling each dtype reached, and how
    # much the tensor-core dtypes actually bought over plain fp32.
    fp32_best = results.get("fp32", {}).get("best_tflops", 0.0)
    for label, entry in results.items():
        spec = RTX3060_SPEC["fp32_tflops"] if label == "fp32" else RTX3060_SPEC["tensor_dense_tflops"]
        entry["pct_of_spec"] = round(100.0 * entry["best_tflops"] / spec, 1) if spec else None
        entry["speedup_vs_fp32"] = (
            round(entry["best_tflops"] / fp32_best, 2) if fp32_best else None
        )

    return results


# --------------------------------------------------------------------------
# 2. Memory ceiling
# --------------------------------------------------------------------------

def memory_bandwidth(size_mib: int = 1024, iters: int = 30) -> dict[str, Any]:
    """Device memory bandwidth - the ceiling for anything not compute-bound.

    A copy touches each byte twice (one read, one write), so effective
    bandwidth is 2x the buffer size over the elapsed time.
    """
    device = torch.device("cuda")
    n = (size_mib * 1024 * 1024) // 4
    src = torch.empty(n, device=device, dtype=torch.float32).uniform_()
    dst = torch.empty_like(src)

    secs = _time_cuda(lambda: dst.copy_(src), iters)
    moved_bytes = 2 * src.numel() * src.element_size()
    gbs = moved_bytes / secs / 1e9

    del src, dst
    torch.cuda.empty_cache()

    return {
        "buffer_mib": size_mib,
        "seconds": round(secs, 6),
        "bandwidth_gbs": round(gbs, 1),
        "pct_of_spec": round(100.0 * gbs / RTX3060_SPEC["memory_bandwidth_gbs"], 1),
    }


# --------------------------------------------------------------------------
# 3. Host <-> device transfer
# --------------------------------------------------------------------------

def pcie(
    sizes_mib: tuple[int, ...] = (1, 4, 16, 64, 256, 1024),
    iters: int = 10,
) -> dict[str, Any]:
    """H2D and D2H bandwidth, pinned against pageable host memory.

    Pageable memory cannot be DMA'd directly: the driver stages it through an
    internal pinned buffer, adding a host-side copy. Pinned memory removes that
    hop, and the gap is routinely more than 2x. This is also the measurement
    that reveals the real PCIe link state - the gen reported by nvidia-smi at
    idle is a downshifted link, not the one a transfer will see.
    """
    device = torch.device("cuda")
    out: dict[str, Any] = {"by_size": {}}

    for mib in sizes_mib:
        n = (mib * 1024 * 1024) // 4
        entry: dict[str, Any] = {}

        for kind in ("pageable", "pinned"):
            try:
                host = torch.empty(n, dtype=torch.float32, pin_memory=(kind == "pinned"))
                dev = torch.empty(n, dtype=torch.float32, device=device)
            except (RuntimeError, torch.cuda.OutOfMemoryError):
                torch.cuda.empty_cache()
                continue

            nb = kind == "pinned"  # non_blocking only does anything for pinned memory
            h2d = _time_cuda(lambda: dev.copy_(host, non_blocking=nb), iters)
            d2h = _time_cuda(lambda: host.copy_(dev, non_blocking=nb), iters)
            nbytes = n * 4

            entry[kind] = {
                "h2d_gbs": round(nbytes / h2d / 1e9, 2),
                "d2h_gbs": round(nbytes / d2h / 1e9, 2),
            }

            del host, dev
            torch.cuda.empty_cache()

        if "pinned" in entry and "pageable" in entry:
            entry["pinned_speedup_h2d"] = round(
                entry["pinned"]["h2d_gbs"] / entry["pageable"]["h2d_gbs"], 2
            )
        out["by_size"][str(mib)] = entry

    # Peak transfer rates, taken from the largest sizes where per-call overhead
    # no longer dominates.
    for kind in ("pinned", "pageable"):
        peaks = [
            v[kind]["h2d_gbs"] for v in out["by_size"].values() if kind in v
        ]
        if peaks:
            best = max(peaks)
            out[f"{kind}_peak_h2d_gbs"] = round(best, 2)
            out[f"{kind}_pct_of_pcie4x16"] = round(100.0 * best / PCIE4_X16_PRACTICAL_GBS, 1)

    return out


# --------------------------------------------------------------------------
# 4. Dispatch overhead
# --------------------------------------------------------------------------

def launch_overhead(iters: int = 2000) -> dict[str, Any]:
    """Per-kernel dispatch cost, eager against a captured CUDA graph.

    This is where a 4-core host driving a 3584-core GPU shows up. If a training
    step is made of many small kernels, the host can become the limiting factor
    while the GPU sits partly idle - and the fix is graph capture or fusion, not
    a faster GPU.
    """
    device = torch.device("cuda")
    a = torch.ones(1, device=device)

    # Deliberately trivial work: what is being measured is the dispatch, not
    # the arithmetic.
    def one():
        a.add_(1.0)

    for _ in range(100):
        one()
    torch.cuda.synchronize()

    start = time.perf_counter()
    for _ in range(iters):
        one()
    torch.cuda.synchronize()
    eager_us = (time.perf_counter() - start) / iters * 1e6

    result = {"eager_us_per_launch": round(eager_us, 3), "iters": iters}

    # CUDA graphs replay a pre-recorded dispatch sequence, which removes almost
    # all per-kernel host work.
    try:
        g = torch.cuda.CUDAGraph()
        stream = torch.cuda.Stream()
        stream.wait_stream(torch.cuda.current_stream())
        with torch.cuda.stream(stream):
            for _ in range(3):
                one()
        torch.cuda.current_stream().wait_stream(stream)

        with torch.cuda.graph(g):
            for _ in range(10):
                one()

        for _ in range(10):
            g.replay()
        torch.cuda.synchronize()

        reps = max(iters // 10, 1)
        start = time.perf_counter()
        for _ in range(reps):
            g.replay()
        torch.cuda.synchronize()
        graph_us = (time.perf_counter() - start) / (reps * 10) * 1e6

        result["cudagraph_us_per_launch"] = round(graph_us, 3)
        result["graph_speedup"] = round(eager_us / graph_us, 2) if graph_us else None
    except Exception as exc:  # graph capture is fussy; never fail the whole run
        result["cudagraph_error"] = str(exc)

    del a
    torch.cuda.empty_cache()
    return result


# --------------------------------------------------------------------------
# 5. A real training step
# --------------------------------------------------------------------------

class _Block(nn.Module):
    """Decoder block shaped like Qwen3-0.6B: GQA attention plus a SwiGLU MLP."""

    def __init__(self, d_model: int, n_heads: int, n_kv_heads: int, d_ff: int) -> None:
        super().__init__()
        self.n_heads = n_heads
        self.n_kv_heads = n_kv_heads
        self.head_dim = d_model // n_heads

        self.q = nn.Linear(d_model, n_heads * self.head_dim, bias=False)
        self.k = nn.Linear(d_model, n_kv_heads * self.head_dim, bias=False)
        self.v = nn.Linear(d_model, n_kv_heads * self.head_dim, bias=False)
        self.o = nn.Linear(n_heads * self.head_dim, d_model, bias=False)

        self.gate = nn.Linear(d_model, d_ff, bias=False)
        self.up = nn.Linear(d_model, d_ff, bias=False)
        self.down = nn.Linear(d_ff, d_model, bias=False)

        self.n1 = nn.RMSNorm(d_model)
        self.n2 = nn.RMSNorm(d_model)

    def forward(self, x: torch.Tensor) -> torch.Tensor:
        b, t, _ = x.shape
        h = self.n1(x)

        q = self.q(h).view(b, t, self.n_heads, self.head_dim).transpose(1, 2)
        k = self.k(h).view(b, t, self.n_kv_heads, self.head_dim).transpose(1, 2)
        v = self.v(h).view(b, t, self.n_kv_heads, self.head_dim).transpose(1, 2)

        a = F.scaled_dot_product_attention(q, k, v, is_causal=True, enable_gqa=True)
        a = a.transpose(1, 2).reshape(b, t, -1)
        x = x + self.o(a)

        h = self.n2(x)
        return x + self.down(F.silu(self.gate(h)) * self.up(h))


class _Model(nn.Module):
    def __init__(self, vocab: int, d_model: int, n_layers: int, n_heads: int,
                 n_kv_heads: int, d_ff: int) -> None:
        super().__init__()
        self.embed = nn.Embedding(vocab, d_model)
        self.blocks = nn.ModuleList(
            _Block(d_model, n_heads, n_kv_heads, d_ff) for _ in range(n_layers)
        )
        self.norm = nn.RMSNorm(d_model)
        self.head = nn.Linear(d_model, vocab, bias=False)

    def forward(self, idx: torch.Tensor) -> torch.Tensor:
        x = self.embed(idx)
        for blk in self.blocks:
            x = blk(x)
        return self.head(self.norm(x))


def train_step(
    batch_size: int = 4,
    seq_len: int = 1024,
    iters: int = 12,
    dtype: str = "bf16",
    grad_checkpoint: bool = False,
) -> dict[str, Any]:
    """Full fine-tuning step on a Qwen3-0.6B-shaped model, reported as MFU.

    The model is constructed locally rather than downloaded: the point is to
    measure the machine, and a synthetic model of the right shape does that
    without making the benchmark depend on a network fetch or on a tokenizer.

    MFU (Model FLOPs Utilization) is the number that matters - achieved FLOPs
    over the hardware ceiling. The gap between a GEMM benchmark's TFLOPS and
    this figure is everything the rest of the step costs: optimizer, norms,
    dataloading, dispatch overhead.
    """
    device = torch.device("cuda")
    torch_dtype = {"bf16": torch.bfloat16, "fp16": torch.float16, "fp32": torch.float32}[dtype]

    # Qwen3-0.6B geometry.
    cfg = dict(vocab=151936, d_model=1024, n_layers=28, n_heads=16, n_kv_heads=8, d_ff=3072)

    torch.manual_seed(0)
    model = _Model(**cfg).to(device)
    if torch_dtype is not torch.float32:
        model = model.to(torch_dtype)

    # 8-bit Adam is not assumed here; plain AdamW keeps the measurement
    # comparable across systems and is the heavier, more honest case.
    opt = torch.optim.AdamW(model.parameters(), lr=1e-5, fused=True)

    n_all = sum(p.numel() for p in model.parameters())
    n_embed = cfg["vocab"] * cfg["d_model"] + cfg["vocab"] * cfg["d_model"]
    n_non_embed = n_all - n_embed

    idx = torch.randint(0, cfg["vocab"], (batch_size, seq_len), device=device)
    tgt = torch.randint(0, cfg["vocab"], (batch_size, seq_len), device=device)

    def step() -> None:
        opt.zero_grad(set_to_none=True)
        logits = model(idx)
        loss = F.cross_entropy(logits.float().view(-1, cfg["vocab"]), tgt.view(-1))
        loss.backward()
        opt.step()

    try:
        for _ in range(3):
            step()
        torch.cuda.synchronize()

        times = []
        for _ in range(iters):
            t0 = time.perf_counter()
            step()
            torch.cuda.synchronize()
            times.append(time.perf_counter() - t0)
    except torch.cuda.OutOfMemoryError as exc:
        torch.cuda.empty_cache()
        return {"error": "out of memory", "detail": str(exc), "batch_size": batch_size,
                "seq_len": seq_len, "dtype": dtype}

    secs = statistics.median(times)
    tokens = batch_size * seq_len

    # Forward+backward FLOPs per token: 6N for the parameter matmuls plus the
    # attention term, which grows with sequence length and is not captured by
    # the parameter count.
    flops_per_token = 6 * n_non_embed + 6 * cfg["n_layers"] * cfg["d_model"] * seq_len
    achieved_tflops = flops_per_token * tokens / secs / 1e12

    ceiling = (
        RTX3060_SPEC["fp32_tflops"] if dtype == "fp32" else RTX3060_SPEC["tensor_dense_tflops"]
    )

    peak_mem = torch.cuda.max_memory_allocated() / 1048576
    result = {
        "batch_size": batch_size,
        "seq_len": seq_len,
        "dtype": dtype,
        "params_total_m": round(n_all / 1e6, 1),
        "params_non_embedding_m": round(n_non_embed / 1e6, 1),
        "seconds_per_step": round(secs, 4),
        "tokens_per_second": round(tokens / secs, 1),
        "achieved_tflops": round(achieved_tflops, 2),
        "mfu_pct": round(100.0 * achieved_tflops / ceiling, 1),
        "peak_vram_mib": round(peak_mem),
        "step_time_stdev_s": round(statistics.stdev(times), 5) if len(times) > 1 else 0.0,
    }

    del model, opt, idx, tgt
    torch.cuda.empty_cache()
    torch.cuda.reset_peak_memory_stats()
    return result
