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

Items 2 and 3 only show their real cost under a workload that actually feeds
the card, which is what the `feed_path` benchmark is for. It runs ResNet-50
three times — on a batch already resident in VRAM, then with the batch
transferred each step, then with real JPEG decode and augmentation in
DataLoader workers — so the loss splits cleanly into transfer, host, and
what survives:

```
    408.5 img/s   batch already in VRAM      <- the card's own ceiling
                  + PCIe transfer, pinned       −2.5%
    386.9 img/s   + real decode / augment       −2.8%
                  = 94.7% of the ceiling survives being fed
```

(stock-ubuntu, mean of three runs; the efficiency figure spans 94.7–94.8%.)

Image classification is the vehicle, not the point: JPEG decode and augment
put measurable load on the host in a way token slicing does not, and the
four-core CPU is this build's structural weak point. The corpus is generated
rather than downloaded, and lives on tmpfs — Ubuntu runs from an SSD and the
Gentoo target from a 5400rpm HDD, so reading it from the real filesystem
would compare the two disks instead of the two kernels.

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
  00_run_pipeline.sh            runs 02, 05, 06, 07, 08, 10 in order, with a verdict
  01_partition_target_disk.sh   partition + format the target disk
  02_bootstrap_stage3.sh        mount, unpack stage3, write Portage config, chroot prep
  03_chroot_setup.sh            repo sync, profile, timezone, locale, fstab   (in chroot)
  04_build_world.sh             Portage update, @world rebuild, base toolset  (in chroot)
  05_configure_kernel.sh        kernel config, verify, build, install         (in chroot)
  06_nvidia_driver.sh           NVIDIA 595.84 against that kernel             (in chroot)
  07_make_bootable.sh           services, ESP, EFI boot entries + fallback    (in chroot)
  08_teardown_chroot.sh         clean recursive unmount
  09_gentoo_first_boot.sh       verify, install torch, benchmark    (on booted Gentoo)
  10_vm_smoke_test.sh           QEMU boot test, non-destructive (snapshot=on)
  11_collect_from_target.sh     read /root/handoff off the target disk
  12_restore_boot_entries.sh    recreate the EFI boot entries after NVRAM loss

gpubench/                       the measurement harness
  spec.py                       the hardware ceilings, importable without torch
  benches.py                    the five device-side measurements
  pipeline.py                   the CPU->GPU feed path (needs torchvision)
results/                        labelled benchmark runs, diffed across configurations
```

The harness answers the fraction-of-peak question directly:

```
python3 -m gpubench utilization results/*.json    # achieved vs ceiling, per path
python3 -m gpubench compare  a.json b.json        # what a config change was worth
python3 -m gpubench run --label X --feed-path     # include the CPU->GPU feed path
```

`utilization` needs only the result file, not a CUDA stack, so a run collected
off the target can be read back on any machine. `compare` refuses to be quiet
about confounds: if two runs differ in torch, cuDNN, CUDA runtime, Python or
driver version, it prints a `!! SOFTWARE STACK DIFFERS` block, because a delta
across an unpinned dependency is not a measurement of the OS. The torch version
is pinned in `scripts/09_gentoo_first_boot.sh` for that reason.

`00_run_pipeline.sh --from <step>` resumes after a failure, and stops at the
first failing step with the mounts left in place so the chroot can be inspected.
Step 02 always runs regardless, because it establishes those mounts and syncs
the in-chroot scripts.

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
- [x] GPU benchmark harness written (`gpubench/`)
- [x] `stock-ubuntu` baseline captured (`results/`)
- [x] `@world` rebuild and base toolset — 21 min, graphical stack absent from the tree
- [x] Minimal kernel — 1,459 options against Ubuntu's 10,048, 8.8 MB image
- [x] NVIDIA 595.84 built against it; all five modules present
- [x] Bootable — EFI stub, no bootloader, no initramfs; QEMU smoke test reaches a login prompt
- [x] Boot path survives NVRAM loss — see below; the firmware erased the entries three times
- [x] **First bare-metal boot** — 2026-09-18; **CUDA survives the stripped kernel**
      (`nvidia-smi` works, all four modules loaded, `exit_status=0`)
- [x] `minimal-gentoo` measurement captured (`results/`)
- [x] **Valid comparison on a matched stack, with repeats** — torch 2.14.0 /
      Python 3.14.7 / cuDNN 92400 on both sides; Ubuntu n=3, Gentoo n=4 across
      two boots. Compute, memory and training throughput are **unchanged** by
      the stripped kernel; H2D transfer is **+73% pageable / +38% pinned**;
      kernel launch is **+9% slower** (2% once graphed)
- [x] **OS noise measurably removed** — Gentoo holds pinned PCIe inside a
      0.01 GB/s window and memory bandwidth identical across four runs, where
      Ubuntu swings 13% run to run on the same hardware. Item 6 below, caught
- [x] **CPU→GPU feed path measured** (`gpubench/pipeline.py`) — on stock-ubuntu
      **94.7%** of the card's ceiling survives a real decode/augment/transfer
      pipeline (transfer −2.5%, host −2.8%), reproducible to ±0.05 pp over 3 runs
- [ ] Take the feed path on Gentoo — no Gentoo run has it yet; the two known
      kernel differences (PCIe +38/+73%, dispatch −9%) both live on that
      boundary, so this is where they cancel or compound
- [ ] Raise the training step off **34.9%** of the bf16 ceiling — the weakest
      path by a wide margin, and now known not to be OS noise
- [ ] `isolcpus` arm — `headless` and `performance-governor` after it

### The firmware does not keep boot entries it did not create

Worth stating in the README because it looks like failing hardware and is not.
On 2026-09-17 the Gentoo EFI boot entries vanished three times, once within a
single POST of being written and verified, and the target disk stopped appearing
in the boot menu altogether.

The board is an MSI PRO B760M-A DDR4 II (AMI firmware). It rebuilds its boot
list from its own scan every POST and does not carry forward entries it cannot
re-derive. A `BootOrder` that had held seven entries held two the next morning —
the survivors being `\EFI\Microsoft\Boot\bootmgfw.efi` and
`\EFI\ubuntu\shimx64.efi`, both paths that scan recognises. A disk with nothing
regenerable on it never reaches the boot list at all, which is what made a
perfectly healthy drive look dead.

So the boot path no longer depends on NVRAM:

- The kernel carries its own command line as `CONFIG_CMDLINE`, so a boot that
  supplies no LoadOptions still finds `root=`.
- The kernel is installed a second time at `\EFI\BOOT\BOOTX64.EFI`, the
  removable-media path the firmware's scan does recognise and regenerates on its
  own. It appears as `UEFI OS`.

Named NVRAM entries are still written, because a per-configuration command line
is the one thing only LoadOptions can express, and the firmware boot menu
doubling as the A/B test menu is worth keeping. But losing them now costs the
`isolcpus` arm of a comparison rather than the ability to boot at all.

See [`HANDOFF.md`](HANDOFF.md) for the current state, the exact next steps, and
the reasoning behind the decisions that are settled.

### Already visible on the stock system

Environment capture on the unmodified Ubuntu host surfaced four things worth
fixing before any of them get blamed on something else:

| Finding | Why it costs throughput |
|---|---|
| `scaling_governor = powersave` | the 4 cores feeding the GPU are not free to boost |
| `persistence_mode = Disabled` | the driver unloads between processes; clocks drop with it |
| `transparent_hugepage = madvise` | project spec calls for THP off with explicit hugepages |
| 358 MiB VRAM held by the desktop session | gone once the target boots headless |

Also worth noting: the card reports a maximum SM clock of 2130 MHz against the
1777 MHz rated boost the 12.74 TFLOPS reference figure is derived from. The
harness records both, so achieved throughput can be compared against the clock
the card actually ran at rather than only against the spec sheet.

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
