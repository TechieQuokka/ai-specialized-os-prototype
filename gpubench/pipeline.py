"""What the CPU->GPU feed path costs, measured against the GPU's own ceiling.

The other five benchmarks measure the card. This one measures the machine
around it, because on this build that is where the throughput actually goes:
four cores feeding 3584, with every batch crossing PCIe on the way in.

The question is not "how fast is the GPU" - `peak_gemm` answers that - but
"how much of that speed survives a real feed path", and the only honest way
to answer it is to run the same model three times with progressively more of
the real pipeline attached:

    device_only   batch already resident in VRAM, forward+backward only.
                  No host involvement at all. This is the ceiling.

    h2d_only      batch built on the host, transferred per step, then the
                  same compute. device_only minus this is the transfer cost.

    full          real JPEG decode, augmentation, collation and pinning in
                  DataLoader workers, then transfer, then compute. This is
                  what a training run actually gets.

`full / device_only` is the number this module exists to produce: the fraction
of the GPU's own ceiling that survives being fed. Image classification is the
vehicle rather than the point - it is used because JPEG decode and augment put
real, measurable load on the host, which token slicing does not.

Nothing here is about accuracy. The model is never expected to learn; the
labels are random and the loop runs a fixed number of steps. Every reported
number is a rate or a latency.
"""

from __future__ import annotations

import os
import random
import shutil
import statistics
import time
from pathlib import Path
from typing import Any

import torch
import torch.nn as nn

from .spec import FEED_PATH_DATA_ROOT as DEFAULT_DATA_ROOT


# --------------------------------------------------------------------------
# Synthetic corpus
#
# Generated rather than downloaded, for the same reason the transformer in
# `benches` is constructed rather than fetched: the benchmark should not
# depend on a network fetch, and the Gentoo target has no credentials and a
# slow link. Smoothed noise is used instead of white noise because white noise
# does not compress, and a JPEG that does not compress does not decode at a
# realistic speed - which would overstate the very cost being measured.
# --------------------------------------------------------------------------

def ensure_corpus(
    root: str = DEFAULT_DATA_ROOT,
    n_images: int = 2048,
    classes: int = 10,
    width: int = 500,
    height: int = 375,
    seed: int = 0,
) -> dict[str, Any]:
    """Create the JPEG corpus if it is not already there. Idempotent."""
    from PIL import Image

    root_path = Path(root)
    marker = root_path / f".complete-{n_images}-{width}x{height}"
    if marker.exists():
        sizes = [p.stat().st_size for p in root_path.rglob("*.jpg")]
        return {
            "root": str(root_path),
            "images": len(sizes),
            "mean_kib": round(statistics.mean(sizes) / 1024, 1) if sizes else 0,
            "created": False,
        }

    if root_path.exists():
        shutil.rmtree(root_path)
    for c in range(classes):
        (root_path / f"class{c:02d}").mkdir(parents=True, exist_ok=True)

    rng = random.Random(seed)
    gen = torch.Generator().manual_seed(seed)
    sizes = []
    for i in range(n_images):
        # Decode cost scales with how much high-frequency detail the JPEG
        # carries, so the corpus has to land near the file size of real
        # photographs or it understates the host cost this benchmark exists to
        # measure. A smooth base from an upsampled tile, plus finer octaves,
        # puts a 500x375 image around 100 KiB - the ImageNet ballpark. A single
        # smooth octave came out at 25 KiB and made decode look four times
        # cheaper than it is.
        img = torch.zeros(3, height, width)
        amplitude = 1.0
        for tile_h, tile_w in ((12, 16), (48, 64), (150, 200), (height, width)):
            octave = torch.rand(3, tile_h, tile_w, generator=gen)
            if (tile_h, tile_w) == (height, width):
                img += amplitude * octave
            else:
                img += amplitude * torch.nn.functional.interpolate(
                    octave.unsqueeze(0), size=(height, width), mode="bicubic",
                    align_corners=False,
                ).squeeze(0)
            amplitude *= 0.5
        img = (img / img.amax()).clamp(0, 1)
        arr = (img.permute(1, 2, 0) * 255).to(torch.uint8).numpy()
        path = root_path / f"class{rng.randrange(classes):02d}" / f"{i:06d}.jpg"
        Image.fromarray(arr).save(path, format="JPEG", quality=95)
        sizes.append(path.stat().st_size)

    marker.touch()
    return {
        "root": str(root_path),
        "images": n_images,
        "mean_kib": round(statistics.mean(sizes) / 1024, 1),
        "created": True,
    }


# --------------------------------------------------------------------------
# The model under the pipeline
# --------------------------------------------------------------------------

def _resnet50(num_classes: int = 10) -> nn.Module:
    from torchvision.models import resnet50

    # No pretrained weights: this measures throughput, and downloading a
    # checkpoint would make the benchmark depend on the network.
    return resnet50(weights=None, num_classes=num_classes)


def _flops_per_image(height: int = 224, width: int = 224) -> float:
    """ResNet-50 forward+backward FLOPs at the given input size.

    The usual reference figure is 4.1 GFLOPs for a 224x224 forward pass, and
    backward is conventionally counted as twice forward, so a training step is
    about 3x forward. Scaled by pixel count for other input sizes.
    """
    forward = 4.1e9 * (height * width) / (224 * 224)
    return 3.0 * forward


# --------------------------------------------------------------------------
# The three stages
# --------------------------------------------------------------------------

def _make_step(model: nn.Module, optimizer, use_amp: bool):
    loss_fn = nn.CrossEntropyLoss()

    def step(images: torch.Tensor, labels: torch.Tensor) -> None:
        optimizer.zero_grad(set_to_none=True)
        with torch.autocast("cuda", dtype=torch.bfloat16, enabled=use_amp):
            loss = loss_fn(model(images), labels)
        loss.backward()
        optimizer.step()

    return step


def _device_only(
    batch_size: int, steps: int, warmup: int, resolution: int, use_amp: bool
) -> dict[str, Any]:
    """Ceiling: one batch, already in VRAM, reused every step."""
    device = torch.device("cuda")
    model = _resnet50().to(device).to(memory_format=torch.channels_last)
    opt = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9)
    step = _make_step(model, opt, use_amp)

    images = torch.randn(batch_size, 3, resolution, resolution, device=device).to(
        memory_format=torch.channels_last
    )
    labels = torch.randint(0, 10, (batch_size,), device=device)

    for _ in range(warmup):
        step(images, labels)
    torch.cuda.synchronize()

    t0 = time.perf_counter()
    for _ in range(steps):
        step(images, labels)
    torch.cuda.synchronize()
    elapsed = time.perf_counter() - t0

    del model, opt, images, labels
    torch.cuda.empty_cache()
    return {
        "seconds": round(elapsed, 4),
        "images_per_s": round(batch_size * steps / elapsed, 1),
        "ms_per_step": round(elapsed / steps * 1000, 2),
    }


def _h2d_only(
    batch_size: int, steps: int, warmup: int, resolution: int, use_amp: bool, pinned: bool
) -> dict[str, Any]:
    """Ceiling plus transfer: batch built on the host, copied in every step.

    No decode and no augmentation - the host tensor is prepared once and
    re-sent - so the difference from `device_only` is the PCIe crossing and
    nothing else.
    """
    device = torch.device("cuda")
    model = _resnet50().to(device).to(memory_format=torch.channels_last)
    opt = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9)
    step = _make_step(model, opt, use_amp)

    # Laid out on the host exactly as the device wants it, so the timed region
    # is the PCIe copy and not a layout-conversion kernel running after it.
    host = torch.randn(batch_size, 3, resolution, resolution).to(
        memory_format=torch.channels_last
    )
    if pinned:
        host = host.pin_memory()
    labels = torch.randint(0, 10, (batch_size,), device=device)

    def one() -> float:
        # Drain the queue first. Without this the synchronize below waits on
        # the previous step's backward pass as well as the copy, and the
        # "transfer time" comes out as the compute time - which is how this
        # first reported 0.26 GB/s across a link measured at 24 GB/s.
        torch.cuda.synchronize()
        t = time.perf_counter()
        images = host.to(device, non_blocking=pinned)
        torch.cuda.synchronize()
        h2d = time.perf_counter() - t
        step(images, labels)
        return h2d

    for _ in range(warmup):
        one()
    torch.cuda.synchronize()

    h2d_times = []
    t0 = time.perf_counter()
    for _ in range(steps):
        h2d_times.append(one())
    torch.cuda.synchronize()
    elapsed = time.perf_counter() - t0

    nbytes = host.numel() * host.element_size()
    del model, opt, host, labels
    torch.cuda.empty_cache()
    return {
        "seconds": round(elapsed, 4),
        "images_per_s": round(batch_size * steps / elapsed, 1),
        "ms_per_step": round(elapsed / steps * 1000, 2),
        "h2d_ms_per_step": round(statistics.median(h2d_times) * 1000, 3),
        "h2d_gbs": round(nbytes / statistics.median(h2d_times) / 1e9, 2),
        "pinned": pinned,
    }


def _full(
    root: str,
    batch_size: int,
    steps: int,
    warmup: int,
    resolution: int,
    use_amp: bool,
    num_workers: int,
) -> dict[str, Any]:
    """Reality: decode, augment, collate, pin, transfer, compute.

    The loop separates the time spent blocked on the loader from the time
    spent on the device, because those two call for completely different
    fixes - more workers against a faster card - and a single end-to-end
    figure cannot tell them apart.
    """
    from torch.utils.data import DataLoader
    from torchvision import transforms
    from torchvision.datasets import ImageFolder

    device = torch.device("cuda")
    tf = transforms.Compose(
        [
            transforms.RandomResizedCrop(resolution),
            transforms.RandomHorizontalFlip(),
            transforms.ToTensor(),
            transforms.Normalize([0.485, 0.456, 0.406], [0.229, 0.224, 0.225]),
        ]
    )
    dataset = ImageFolder(root, transform=tf)
    loader = DataLoader(
        dataset,
        batch_size=batch_size,
        shuffle=True,
        num_workers=num_workers,
        pin_memory=True,
        drop_last=True,
        persistent_workers=num_workers > 0,
        prefetch_factor=4 if num_workers > 0 else None,
    )

    model = _resnet50(num_classes=len(dataset.classes)).to(device).to(
        memory_format=torch.channels_last
    )
    opt = torch.optim.SGD(model.parameters(), lr=0.01, momentum=0.9)
    step = _make_step(model, opt, use_amp)

    wait_times: list[float] = []
    step_times: list[float] = []
    done = 0
    started = None
    it = iter(loader)

    while done < warmup + steps:
        t_wait = time.perf_counter()
        try:
            images, labels = next(it)
        except StopIteration:
            it = iter(loader)
            continue
        wait = time.perf_counter() - t_wait

        t_step = time.perf_counter()
        images = images.to(device, non_blocking=True).to(memory_format=torch.channels_last)
        labels = labels.to(device, non_blocking=True)
        step(images, labels)
        torch.cuda.synchronize()
        elapsed_step = time.perf_counter() - t_step

        done += 1
        if done == warmup:
            started = time.perf_counter()
        elif done > warmup:
            wait_times.append(wait)
            step_times.append(elapsed_step)

    total = time.perf_counter() - started
    del model, opt, loader, it
    torch.cuda.empty_cache()

    n = len(step_times)
    wait_total = sum(wait_times)
    return {
        "num_workers": num_workers,
        "seconds": round(total, 4),
        "images_per_s": round(batch_size * n / total, 1),
        "ms_per_step": round(total / n * 1000, 2),
        # The fraction of wall time the training loop sat blocked with nothing
        # to feed the card. This is the starvation figure.
        "loader_wait_fraction": round(wait_total / total, 4),
        "loader_wait_ms_p50": round(statistics.median(wait_times) * 1000, 3),
        "loader_wait_ms_p99": round(sorted(wait_times)[int(n * 0.99) - 1] * 1000, 3),
        "step_ms_p50": round(statistics.median(step_times) * 1000, 3),
        "step_ms_p99": round(sorted(step_times)[int(n * 0.99) - 1] * 1000, 3),
        "step_ms_jitter_p99_over_p50": round(
            sorted(step_times)[int(n * 0.99) - 1] / statistics.median(step_times), 3
        ),
    }


# --------------------------------------------------------------------------
# Entry point
# --------------------------------------------------------------------------

def feed_path(
    batch_size: int = 64,
    steps: int = 40,
    warmup: int = 8,
    resolution: int = 224,
    use_amp: bool = True,
    worker_sweep: tuple[int, ...] = (0, 2, 4, 8),
    data_root: str = DEFAULT_DATA_ROOT,
    n_images: int = 2048,
) -> dict[str, Any]:
    """Run all three stages and report what the feed path costs."""
    corpus = ensure_corpus(root=data_root, n_images=n_images)

    out: dict[str, Any] = {
        "batch_size": batch_size,
        "steps": steps,
        "resolution": resolution,
        "amp_bf16": use_amp,
        "corpus": corpus,
        "host_cpus": os.cpu_count(),
        "flops_per_image": _flops_per_image(resolution, resolution),
    }

    out["device_only"] = _device_only(batch_size, steps, warmup, resolution, use_amp)
    out["h2d_pinned"] = _h2d_only(batch_size, steps, warmup, resolution, use_amp, pinned=True)
    out["h2d_pageable"] = _h2d_only(batch_size, steps, warmup, resolution, use_amp, pinned=False)

    sweep = {}
    for nw in worker_sweep:
        if nw > (os.cpu_count() or 1) * 2:
            continue
        sweep[str(nw)] = _full(
            corpus["root"], batch_size, steps, warmup, resolution, use_amp, nw
        )
    out["full_by_workers"] = sweep

    # The headline: how much of the card's own ceiling survives a real feed.
    ceiling = out["device_only"]["images_per_s"]
    best_nw, best = max(sweep.items(), key=lambda kv: kv[1]["images_per_s"])
    out["best_workers"] = int(best_nw)
    out["full"] = best
    out["feed_efficiency_pct"] = round(100.0 * best["images_per_s"] / ceiling, 1)
    out["transfer_cost_pct"] = round(
        100.0 * (ceiling - out["h2d_pinned"]["images_per_s"]) / ceiling, 1
    )
    # Whatever the transfer does not explain is decode, augment and scheduling.
    out["host_cost_pct"] = round(
        100.0 * (out["h2d_pinned"]["images_per_s"] - best["images_per_s"]) / ceiling, 1
    )
    achieved_tflops = best["images_per_s"] * out["flops_per_image"] / 1e12
    out["achieved_tflops"] = round(achieved_tflops, 2)
    return out
