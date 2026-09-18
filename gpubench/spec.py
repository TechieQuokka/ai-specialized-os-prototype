"""The hardware ceilings every measurement is scored against.

Kept in its own module, free of any torch import, so that the question this
prototype exists to answer - how much of the card is actually reachable - can
be asked of a saved result file on a machine that has no CUDA stack installed
at all. `benches` imports these to compute the percentages at run time;
`main.utilization` imports them to re-derive the ceilings when reading results
back.

Vendor figures are reference points, not truth. A card sitting at its power
limit has a lower real ceiling than the spec sheet claims, which is why
`peak_gemm` also derives an FP32 ceiling from the clock observed during the
run, and why a measurement landing slightly above 100% is a boost-clock
artefact rather than an error.
"""

from __future__ import annotations

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


def compute_ceiling(dtype: str) -> float:
    """The TFLOPS ceiling a given GEMM dtype is scored against.

    Everything except fp32 runs on the tensor cores and is therefore measured
    against the dense tensor figure, not the FP32 one.
    """
    return (
        RTX3060_SPEC["fp32_tflops"]
        if dtype == "fp32"
        else RTX3060_SPEC["tensor_dense_tflops"]
    )
