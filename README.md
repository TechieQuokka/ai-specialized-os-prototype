# AI-Specialized OS — Prototype v3

A prototype for a purpose-built, headless Linux system whose job is to run one
workload — full fine-tuning of a small LLM on a single consumer GPU — with as
little of the operating system in the way as possible.

**The OS is the project. The model is the workload used to measure it.**

This repository holds the prototype: the installation scaffolding for the base
system, and a benchmark harness whose whole reason for existing is to answer one
question.

> How much of the GPU's theoretical throughput does this machine actually
> deliver, and where does the rest go?

---

## The question this prototype exists to answer

"Is the GPU being used?" is easy and uninteresting. The useful question is what
fraction of peak the hardware reaches, and which layer eats the difference.
There are six places the throughput goes:

| # | Source of loss | Why it matters here |
|---|---|---|
| 1 | Not using tensor cores | fp32-only work discards roughly half the card before anything else happens |
| 2 | PCIe transfer | pageable vs pinned host memory differs by more than 2x |
| 3 | Kernel launch overhead / CPU bottleneck | 4 cores feeding a 3584-core GPU is this build's structural weak point |
| 4 | Clock throttling | a 170 W board power limit moves the ceiling itself |
| 5 | Memory bandwidth | low arithmetic intensity hits the 360 GB/s wall, not the FLOPS wall |
| 6 | **OS-level noise** | scheduler jitter, interrupts, governor, VRAM held by a desktop session |

Item 6 is the one this project is actually about. Items 1–5 have to be pinned
down first, or there is no way to attribute anything to item 6.

That is why the deliverable is a **re-runnable harness** rather than a
one-shot benchmark. Every run is tagged with a configuration label, and results
are diffed across labels:

```
stock-ubuntu → minimal-gentoo → headless → isolcpus → performance-governor
```

Two "loss" data points were already visible on the stock system before any of
this was built: the desktop session was holding 358 MiB of VRAM, and the PCIe
link was sitting at gen 1 of 4 at idle — which is normal downshift behaviour,
but means PCIe bandwidth must be measured under load or the number is fiction.

---

## Hardware

| Component | Spec |
|---|---|
| CPU | Intel Core i3-14100F — 4 cores / 8 threads, no iGPU |
| RAM | 24 GB DDR4-2133 |
| GPU | NVIDIA RTX 3060 12 GB (GA106) |
| Board | MSI PRO B760M-A DDR4 II |
| Network | Realtek RTL8125 2.5GbE (in-tree `r8169`) |
| Target disk | Toshiba MQ01ABD100M, 1 TB, 5400 rpm |

The absence of an integrated GPU matters: with a single graphics card and no
iGPU, handing the GPU to a VM leaves the host without display output. That
pushes GPU-related validation onto bare metal rather than a VM.

Reference ceilings for the RTX 3060, to be confirmed by measurement rather than
trusted: ~12.7 TFLOPS FP32, ~25.5 TFLOPS dense tensor (bf16/fp16), 360 GB/s
memory bandwidth, PCIe 4.0 x16.

---

## Why Gentoo as the base

The eventual deliverable of the larger project is a custom PID 1 written in
Rust. That single fact drives the base-system choice more than anything else.

- **Init is a replaceable part.** OpenRC is the default and systemd is absent,
  so swapping PID 1 does not mean fighting udev, logind, journald and tmpfiles
  on the way.
- **USE flags remove code, not just packages.** `USE="-X -wayland"` means the
  graphical code paths are never compiled and `libX11` never enters the
  dependency graph. A binary distribution cannot express this — it ships one
  build for everyone, with every feature enabled.
- **Custom kernels are the normal workflow**, not a fight against the packaging.
- **Versions can be frozen precisely.** This matters more than it sounds: if
  packages drift between benchmark runs, the comparison that justifies the whole
  project becomes meaningless. Rolling-release freshness and measurement
  reproducibility are in direct tension, and reproducibility wins.

The configuration deliberately avoids the `hardened` profile. Hardened adds
toolchain and kernel mitigations that cost measurable performance, and this
machine exists to measure performance — the mitigations would show up as noise
in every comparison.

Gentoo is roughly "Linux From Scratch with a package manager." Going all the way
down to LFS would spend the effort in the wrong place: the interesting work is
the init layer, not bootstrapping a toolchain.

---

## Repository layout

```
scripts/
  01_partition_target_disk.sh   partition + format the target disk
  02_bootstrap_stage3.sh        mount, unpack stage3, write Portage config, chroot prep
  03_chroot_setup.sh            repo sync, profile, timezone, locale, fstab   (in chroot)
  04_build_world.sh             Portage update, @world rebuild, base toolset  (in chroot)
```

Not in version control: `downloads/` (the stage3 tarball, reproducible from the
URL in the scripts) and `logs/`.

---

## Safety model of the install scripts

These scripts repartition a disk on a machine that also holds a live Ubuntu
install, a BitLocker volume and a Windows install. Every one of them therefore:

- **Locates the target by serial number, never by `/dev/sdX`.** Kernel device
  names are assigned in probe order and can change between boots; a serial
  cannot. If no disk with the expected serial is attached, the script aborts
  without writing anything.
- **Cross-checks model and exact byte size** before touching the disk.
- **Resolves partitions by UUID and then verifies each UUID actually lives on
  that disk**, so a cloned UUID elsewhere cannot redirect the work.
- **Refuses to run against the disk hosting the live root or `/boot/efi`.**
- **Re-verifies the stage3 SHA-512** against the GPG-verified DIGESTS entry
  immediately before unpacking.
- The in-chroot scripts **abort unless `/etc/gentoo-release` exists**, so a
  mistyped command cannot rewrite the host's fstab and timezone.

The target disk gets its own EFI System Partition rather than sharing the
Windows one. The install is then self-contained: if the experiment fails, the
cable comes out and nothing else on the machine has changed.

---

## Status

- [x] Target disk partitioned — dedicated ESP, swap, ext4 root
- [x] stage3 verified (GPG + SHA-512) and unpacked
- [x] Portage configured — `no-multilib` profile, `-march=native`, graphical stack excluded
- [x] Ebuild repository synced, locale / timezone / fstab written
- [ ] `@world` rebuild and base toolset
- [ ] Minimal kernel configuration
- [ ] NVIDIA driver integration
- [ ] GPU benchmark harness
- [ ] Baseline comparison across OS configurations

---

## Notes

Build scratch (`PORTAGE_TMPDIR`) is mounted on tmpfs. The root filesystem is a
5400 rpm 2.5" drive, where the small-file I/O of a compile becomes seek-bound
rather than CPU-bound. Sizing the tmpfs does not reserve the memory — tmpfs only
consumes what is actually written.

Mirror selection was measured rather than assumed: KAIST responded in 0.097 s
against 4.27 s for the official distfiles host, a 44x difference that compounds
across everything Gentoo downloads.

This is explicitly an experimental system. Breaking it is an acceptable
outcome and rolling it back costs nothing.
