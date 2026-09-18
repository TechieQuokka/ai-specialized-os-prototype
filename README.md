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
DataLoader workers — so the loss splits cleanly into transfer, host, and what
survives. Both operating systems have now been measured on it:

```
                                       stock-ubuntu    minimal-gentoo
    batch already in VRAM               408.5 img/s      410.2 img/s   <- the card's own ceiling
      + PCIe transfer, pinned                 −2.5%            −1.3%
      + real decode / augment                 −2.8%            −2.5%
    ------------------------------------------------------------------
    survives being fed                  386.9 img/s      394.7 img/s
                                              94.7%            96.2%
```

(Mean of three runs per side on a matched software stack. The efficiency
figures span 94.7–94.8% and 96.1–96.3% — the ranges do not overlap, so the
gap is real. Full tables below.)

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
stock-ubuntu → minimal-gentoo → isolcpus
```

Three labels rather than the five originally planned: `headless` and
`performance-governor` turned out to have nothing left to measure on their own,
because the Gentoo build has no graphical stack in its tree at all and the
preflight sets the governor on both sides of every comparison. See Status.

Two "loss" data points were already visible on the stock system before any of
this was built: the desktop session was holding 473 MiB of VRAM at the moment a
benchmark started, and the PCIe link was sitting at gen 1 of 4 at idle — which
is normal downshift behaviour, but means PCIe bandwidth must be measured under
load or the number is fiction.

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

## What has been measured

Everything below runs on one matched software stack — torch 2.14.0,
torchvision 0.29.0, Python 3.14.7, cuDNN 92400, driver 595.84 — so the kernel
is the only variable. `results/` holds every run: **stock-ubuntu n=6,
minimal-gentoo n=7, isolcpus n=3**, the Gentoo side spread across four separate
boots. A row counts as a difference only when the two min..max ranges do not
overlap.

### How much of the card this OS reaches

```
python3 -m gpubench utilization results/*minimal-gentoo*.json
```

| path | achieved | ceiling | reached |
|---|---|---|---|
| compute fp32 | 9.48 TFLOPS | 12.74 | 74.4% |
| compute tf32 | 13.59 TFLOPS | 25.50 | 53.3% |
| compute bf16 | 27.25 TFLOPS | 25.50 | 106.9% |
| compute fp16 | 27.13 TFLOPS | 25.50 | 106.4% |
| memory | 333.1 GB/s | 360.0 | 92.5% |
| transfer h2d pinned | 24.58 GB/s | 25.0 | 98.3% |
| transfer h2d pageable | 14.86 GB/s | 25.0 | 59.4% |
| **training bf16 step** | **8.90 TFLOPS** | 25.50 | **34.9%** |

Above 100% means the card boosted past the 1777 MHz reference clock the
12.74 / 25.5 TFLOPS figures are derived from, not an error.

Read the throttling before the compute rows: the card sat at its 170 W
`sw_power_cap` for 73–75% of the GEMM sweep, on *both* operating systems.
Those TFLOPS measure the power limit, not the OS — which is why no OS change
is expected to move them, and none has.

The training step at **34.9% of the bf16 ceiling** is the weakest path by a
wide margin, and it is now known not to be OS noise.

### What the minimal kernel changed

| path | stock-ubuntu (n=6) | minimal-gentoo (n=7) | verdict |
|---|---|---|---|
| GEMM fp32 | 9.33 .. 9.54 TFLOPS | 9.40 .. 9.54 | overlap — same |
| GEMM bf16 | 27.03 .. 27.49 TFLOPS | 26.97 .. 27.39 | overlap — same |
| memory bandwidth | 331.9 .. 333.1 GB/s | 333.1 .. 333.1 | overlap — same |
| train MFU | 34.5 .. 35.0 % | 34.8 .. 35.0 % | overlap — same |
| train tok/s | 3841 .. 3893 | 3870 .. 3896 | overlap — same |
| **PCIe pageable H2D** | 8.10 .. 8.97 GB/s | **14.81 .. 14.92** | **+71%** |
| **PCIe pinned H2D** | 15.56 .. 22.97 GB/s | **24.58 .. 24.59** | **+21%** |
| **kernel launch, eager** | 2.79 .. 2.90 µs | **3.04 .. 3.14** | **+8% slower** |
| kernel launch, graphed | 0.89 .. 0.91 µs | 0.91 .. 0.92 | overlap — same |

So the minimal kernel costs nothing on compute, memory or training throughput,
wins large on host-to-device transfer, and loses a little on kernel dispatch.
Graph capture cuts dispatch to 0.91 µs on both sides, so the launch regression
is a structural weak point rather than a real ceiling.

### The feed path decides which of those two matters

The two real differences — transfer and dispatch — both live on the boundary
between host and device, so the feed path is where they either cancel or
compound. They do neither. Under load the transfer win shows up and the
dispatch loss does not appear at all:

| | stock-ubuntu (n=3) | minimal-gentoo (n=3) |
|---|---|---|
| ceiling, batch already in VRAM | 405.4 .. 410.1 img/s | 409.6 .. 410.5 |
| **real pipeline** | 383.9 .. 388.7 img/s | **394.4 .. 395.2** |
| **survives being fed** | 94.7 .. 94.8 % | **96.1 .. 96.3 %** |
| transfer cost | 2.3 .. 2.7 % | **1.2 .. 1.5 %** |
| host cost | 2.7 .. 2.9 % | 2.4 .. 2.6 % |
| step time p99 / p50 | 1.017 .. 1.020 | **1.001** |

Transfer cost is halved, which is the PCIe result surviving contact with a real
workload. The −8% eager-launch regression never surfaces: a 3 µs dispatch
cannot show up in a 158 ms step, and the Gentoo step is in fact the *faster* of
the two (p50 158.4 ms against 160.7 ms). One of the two effects is simply the
wrong size to matter under load.

The DataLoader worker sweep says the same thing from the host side:

```
workers      0       2       4       8     img/s, mean of 3
ubuntu   230.3   386.9   382.7   356.5
gentoo   234.4   394.7   392.4   374.9
```

Both peak at 2 workers and degrade past the physical core count — the four-core
CPU showing through, on either OS. Gentoo degrades less: at 8 workers Ubuntu's
99th-percentile loader wait reached 194 ms on one run, against a 6.3 ms worst
case on Gentoo.

### The variance is the result the project was actually after

| metric | ubuntu spread (n=6) | gentoo spread (n=7) |
|---|---|---|
| PCIe pinned H2D | **47.6%** | 0.04% |
| PCIe pageable H2D | 10.7% | 0.74% |
| memory bandwidth | 0.36% | 0.00% — identical ×7 |
| train step stdev | up to 1.11 ms | 0.05 .. 0.15 ms |
| feed step p99 / p50 | 1.017 .. 1.020 | 1.001 |

Seven Gentoo runs across three boots put memory bandwidth at the same figure to
one decimal and pinned PCIe inside a 0.01 GB/s window, while Ubuntu's pinned
figure moves by half on the same hardware. That is item 6 of the table above —
OS-level noise — and removing it is what this project set out to do. For a
measurement harness it matters more than the means: a 48% swing is wide enough
to hide every effect the later configuration arms are meant to detect.

### The `isolcpus` arm changed nothing, for a reason worth keeping

`isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3`, three runs, against the seven
`minimal-gentoo` ones. Every device-side range and every feed-path range
overlaps: GEMM, memory, PCIe, dispatch, MFU, tokens/s, feed efficiency
(96.10–96.23% against 96.10–96.31%), step jitter. The only row whose ranges do
**not** overlap is a regression:

```
workers 0, decode inline in the main process
    minimal-gentoo   234.1 .. 234.7 img/s
    isolcpus         219.6 .. 221.2 img/s        -6%
```

The topology explains it. On this i3-14100F, logical CPUs 0–1 are physical core
0 and 2–3 are physical core 1, so `isolcpus=2,3` removes an entire core — a
quarter of the CPU — from the scheduler's pool. Nothing in the harness sets
affinity, so no thread was placed on the isolated core and the run simply
executed on three cores instead of four. The GPU-bound paths did not notice;
the one purely host-bound path paid for it.

So the finding is not that core isolation is worthless. It is that **isolation
without pinning is just core removal**, and that testing the spec's intent would
mean placing the DataLoader workers on the isolated core explicitly. That was
left undone deliberately: the feed-path decomposition puts the entire host cost
at 2.3–2.6%, so the ceiling on any such gain is smaller than the effect already
measured between the two operating systems.

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
  12_restore_boot_entries.sh    recreate the EFI boot entries, and the
                                per-configuration kernel copy they point at
  13_gentoo_preflight_and_run.sh  the whole Gentoo session in one command
                                  (on booted Gentoo; also at /root/run.sh)
  14_install_target_runner.sh   put 13 on the target as /root/run.sh
                                  (the only script that mounts the target rw)

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
      Python 3.14.7 / cuDNN 92400 on both sides; Ubuntu n=6, Gentoo n=7 across
      three boots. Compute, memory and training throughput are **unchanged** by
      the stripped kernel; H2D transfer is **+71% pageable / +21% pinned**;
      kernel launch is **+8% slower** (no difference once graphed)
- [x] **OS noise measurably removed** — Gentoo holds pinned PCIe inside a
      0.01 GB/s window and memory bandwidth identical across seven runs, where
      Ubuntu's pinned figure spans 47% on the same hardware. Item 6, caught
- [x] **CPU→GPU feed path measured on both** (`gpubench/pipeline.py`) —
      **94.7%** of the card's ceiling survives a real decode/augment/transfer
      pipeline on Ubuntu, **96.2%** on Gentoo, ranges disjoint. The transfer
      win survives contact with a real workload (cost 2.5% → 1.3%); the
      dispatch regression turns out to be the wrong size to matter under load.
      Took three attempts to collect — see `HANDOFF.md` for why the first two
      measured nothing, and what `13_gentoo_preflight_and_run.sh` now handles
- [x] **`isolcpus` arm measured** — three runs, every range overlapping the
      baseline except a −6% regression on the one host-bound path. Isolation
      without pinning removes a core rather than dedicating one; see above
- [x] **Boot entries survive this board** — the firmware compares loader paths,
      not command lines, so the isolation entry now boots its own copy of the
      kernel from `\EFI\Gentoo\isolcpus\`. See below

That closes the prototype. What is left over is either outside what an OS can
answer or not reproducible on demand:

- **The training step at 34.9% of the bf16 ceiling** is the largest remaining
  loss and is **not** OS noise — the OS comparison came back identical on it
  three times over. It belongs to the workload: a 151,936-token vocabulary
  makes the logits tensor, not the weights, the memory bottleneck at batch 1.
  That is the next prototype's problem, not this one's
- **The one boot whose udev coldplug loaded no modules** was seen once and
  never again across the five boots after it, on the same disk and kernel.
  Every disk-side explanation was checked and cleared (alias, deps, firmware,
  blacklists, rules, `USE=kmod`), so it is a race, and catching it means being
  on the boot where it happens. `r8169` is now named explicitly in
  `/etc/conf.d/modules`, which removes the dependency on the answer without
  being one, and `13` captures `udevadm test` automatically on a boot that fails
- **`headless` and `performance-governor` arms** have nothing left to measure
  separately. The graphical stack is absent from the Gentoo tree entirely rather
  than merely unused, and the governor is set to `performance` by the preflight
  on both sides of every comparison already

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

### And it compares boot entries by loader path, not by command line

The A/B menu above then failed in a second, sharper way, which took three
reboots on 2026-09-18 to pin down. `Gentoo-ML` and `Gentoo-ML-isolcpus` were
written together and verified by reading NVRAM back; one POST later only
`Gentoo-ML` was left. Written again, deleted again — while `UEFI OS` and
`Gentoo-ML`, which name *different* files on that same partition, both survived
every time.

Two entries differing only in their LoadOptions cannot coexist on this board:
the firmware treats the loader path as the entry's identity, keeps the first,
and drops the rest. Since a per-configuration command line is the entire point
of the second entry, the fix is to make the two entries name different files —
`07` and `12` now install a second copy of the same kernel image at
`\EFI\Gentoo\isolcpus\` and point the isolation entry there. Nine megabytes to
be distinguishable to firmware that will not look at LoadOptions. The entry has
survived every POST since.

This also gives a one-line check that the intended configuration actually
booted. `CONFIG_CMDLINE_OVERRIDE` is off, so the builtin command line and the
entry's LoadOptions are concatenated:

```
cat /proc/cmdline    # root=PARTUUID= twice -> booted through an NVRAM entry
                     # root=PARTUUID= once  -> booted \EFI\BOOT\BOOTX64.EFI,
                     #                         no per-configuration arguments
```

A run that skips that check can silently measure the plain configuration under
another label, which is worse than a boot that fails.

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
| 473 MiB VRAM held by the desktop session | gone once the target boots headless |

Three of the four are now confirmed recovered: Gentoo runs start with 11,776
MiB of VRAM free against Ubuntu's 11,461–11,603, persistence mode is enabled,
and the governor is set to `performance` by the preflight on every boot — it
does not survive a reboot on either OS, which is why a script sets it rather
than a person.

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
