# Handoff — state as of 2026-09-18

Written for a fresh session picking this up cold. `README.md` explains what the
project is and why; this file says where it stands and what to do next.

---

## Where things stand

A minimal Gentoo system is **installed and bootable** on the Toshiba HDD. The
kernel and NVIDIA driver are built, the EFI boot entries are written, and the
QEMU smoke test now reaches a login prompt and accepts a login — the one item
it had previously left unproven.

The full pipeline was last run clean on 2026-09-18 at 09:02–09:05:

```
05  kernel built, 1,459 options, CONFIG_CMDLINE recorded at /boot/config-6.18.48-gentoo
06  nvidia.ko nvidia-uvm.ko nvidia-drm.ko nvidia-modeset.ko nvidia-peermem.ko
07  \EFI\BOOT\BOOTX64.EFI installed with the builtin command line
    Gentoo-ML and Gentoo-ML-isolcpus written, BootOrder 0001,0000,0002,0003,0004
10  boots to a login prompt on serial
```

**It has now booted on bare metal, and the CUDA stack survived.** First on
2026-09-18 09:12–09:27 from the F11 menu; `09_gentoo_first_boot.sh` ran to
completion with `exit_status=0`. Four more bare-metal boots since, and the
CUDA stack has come up on every one of them — the two runs that produced no
measurement failed on network and on a stale checkout, never on the driver.
The most recent bundle is in
`logs/from-target/` — it is overwritten by each collection, so anything worth
keeping belongs in `results/` or in this file.

```
nvidia-smi          WORKED - driver 595.84, CUDA 13.2, RTX 3060 seen
modules loaded      nvidia, nvidia_uvm, nvidia_modeset, nvidia_drm  (+ r8169)
persistence_mode    Enabled   (the VM's nvidia-persistenced failure was the absent GPU)
dmesg               clean - mei_me and rdinit are both expected and harmless
```

So the yes/no question the prototype was built to answer is answered:

> Does the CUDA stack survive a kernel stripped from Ubuntu's 10,048 enabled
> options down to 1,459?  **Yes.**

That makes the remaining question the interesting one, and it is not a
yes/no: **how much of the GPU can this OS actually reach?** Percentages of
ceiling, not deltas against Ubuntu — a run that is 0.7% faster than Ubuntu is
still leaving two thirds of the card unused if its MFU is 34%. Use:

```
python3 -m gpubench utilization results/*minimal-gentoo*.json
```

As measured on 2026-09-18 over seven runs, the weakest path is the training
step at **34.9%** of the bf16 tensor ceiling (34.8–35.0 across the seven).
Compute, memory and pinned transfer are all close to the card's limits
(92–107%); pageable H2D sits at 59.4%.

The baseline comparison is now **complete**: device side and feed path, both
operating systems, one matched stack, with repeats. What is left is the
`isolcpus` arm — see "Do this next".

### What the OS was actually worth

Measured 2026-09-18 on a matched stack — torch 2.14.0, torchvision 0.29.0,
Python 3.14.7, cuDNN 92400, driver 595.84 on **both** sides, so the kernel is
the only variable. Ubuntu ran six times (09:46–09:48 and 10:44–10:47), Gentoo
seven across three separate boots (09:25, 10:00–10:01, 11:32–11:36).
`results/` holds all thirteen. A row counts as a difference only when the two
min..max ranges do not overlap.

| path | ubuntu n=6 | gentoo n=7 | verdict |
|---|---|---|---|
| GEMM fp32 | 9.33 .. 9.54 TFLOPS | 9.40 .. 9.54 | overlap — same |
| GEMM bf16 | 27.03 .. 27.49 TFLOPS | 26.97 .. 27.39 | overlap — same |
| memory bandwidth | 331.9 .. 333.1 GB/s | 333.1 .. 333.1 | overlap — same |
| train MFU | 34.5 .. 35.0 % | 34.8 .. 35.0 | overlap — same |
| train tok/s | 3841 .. 3893 | 3870 .. 3896 | overlap — same |
| **PCIe pageable H2D** | 8.10 .. 8.97 GB/s | **14.81 .. 14.92** | **+71%** |
| **PCIe pinned H2D** | 15.56 .. 22.97 GB/s | **24.58 .. 24.59** | **+21%** |
| **kernel launch (eager)** | 2.79 .. 2.90 µs | **3.04 .. 3.14** | **+8% slower** |
| kernel launch (graphed) | 0.89 .. 0.91 µs | 0.91 .. 0.92 | overlap — same |

So the minimal kernel costs nothing on compute, memory or training throughput,
wins large on host-to-device transfer, and loses a little on kernel dispatch.
Graph capture cuts dispatch to 0.91 µs (3.4x) on both sides, so the launch
regression is a structural weak point rather than a real ceiling.

The earlier n=3/n=4 version of this table reported +73% / +38% / −9%. The
verdicts did not change with three more Ubuntu runs and three more Gentoo runs;
only the percentages moved, and they moved because **Ubuntu's spread widened**,
not because Gentoo's did.

### And what it was worth under load

The feed path was measured on both sides on 2026-09-18 (Ubuntu 10:44–10:47,
Gentoo 11:32–11:36, n=3 each). This is the measurement that decides which of
the two device-side differences actually matters, because both of them live on
the host/device boundary and the feed path is that boundary under load.

| | ubuntu n=3 | gentoo n=3 |
|---|---|---|
| ceiling, batch already in VRAM | 405.4 .. 410.1 img/s | 409.6 .. 410.5 |
| **real pipeline** | 383.9 .. 388.7 img/s | **394.4 .. 395.2** |
| **efficiency** | 94.7 .. 94.8 % | **96.1 .. 96.3 %** |
| transfer cost | 2.3 .. 2.7 % | **1.2 .. 1.5 %** |
| host cost | 2.7 .. 2.9 % | 2.4 .. 2.6 % |
| step p50 | 160.58 .. 162.19 ms | **158.26 .. 158.44** |
| step p99/p50 | 1.017 .. 1.020 | **1.001** |

**They do not cancel and they do not compound — one of them is the wrong size
to matter.** Transfer cost is halved, which is the PCIe result surviving
contact with a real workload. The −8% eager dispatch regression does not appear
at all: 3 µs cannot show in a 158 ms step, and the Gentoo step is the faster of
the two anyway. Worker sweep, mean of 3:

```
workers      0       2       4       8     img/s
ubuntu   230.3   386.9   382.7   356.5
gentoo   234.4   394.7   392.4   374.9
```

Both peak at 2 and degrade past the physical core count — the four-core CPU,
on either OS. Gentoo degrades less: at 8 workers Ubuntu's p99 loader wait hit
194 ms on one run, against 6.3 ms worst case on Gentoo.

**The variance is still the more interesting result.** The minimal kernel is
not just faster on transfer, it is close to deterministic:

```
PCIe pinned     ubuntu 15.56 .. 22.97  (47.6%)   gentoo 24.58 .. 24.59  (0.04%)
PCIe pageable   ubuntu  8.10 ..  8.97  (10.7%)   gentoo 14.81 .. 14.92  (0.74%)
memory          ubuntu 331.9 .. 333.1  ( 0.4%)   gentoo 333.1 .. 333.1  (identical x7)
train stdev     ubuntu up to 1.11 ms             gentoo 0.05 .. 0.15 ms
feed p99/p50    ubuntu 1.017 .. 1.020            gentoo 1.001
```

Seven Gentoo runs across three boots put memory bandwidth at the same figure to
one decimal, and pinned PCIe inside a 0.01 GB/s window, while Ubuntu's pinned
figure moves by half on the same hardware. This is item 6 in the README's table
— OS-level noise — and it is the thing the project set out to remove. For a
measurement harness it matters more than the means: a 48% swing is wide enough
to hide every effect the later arms are meant to detect.

An earlier comparison, made before the pin existed, reported GEMM regressions
of −1.3% to −2.8% and a +59% pageable gain. The regressions were the torch
version, not the kernel, and vanished once the stacks matched — one of them
(fp32) even changed sign. That run is kept at
`results/superseded/20260917T171657-stock-ubuntu-torch2.11.json`, out of the
`results/*stock-ubuntu*.json` glob so it cannot be picked up by accident.

It **can** still be picked up on purpose, though: the target's own clone has it
under its original name, so it comes back inside every `logs/from-target/`
bundle. Copy results out of a bundle by label, never with `*.json`. See "Do
this next", step 3.

---

## Do this next

**Boot the `isolcpus` arm and measure it.** The baseline comparison is finished
— device side and feed path, both operating systems, matched stack, repeats —
and every loss still on the table is host-side and structural: the training
step at 34.9% of the bf16 ceiling, the −8% eager dispatch, and a worker sweep
that degrades past the physical core count. Four cores feeding 3584 is this
build's structural weak point, and core isolation is the one knob aimed at
exactly that.

```
# reboot, F11, pick Gentoo-ML-isolcpus.  Then, as root:
/root/run.sh isolcpus          # preflight + 3 runs, one command

# back on Ubuntu
sudo ./scripts/11_collect_from_target.sh
cp logs/from-target/results/*-isolcpus.json results/     # NOT *.json - see below
python3 -m gpubench compare results/*minimal-gentoo*.json results/*isolcpus*.json
python3 -m gpubench utilization results/*isolcpus*.json
```

Three things to get right, in this order:

1. **`Gentoo-ML-isolcpus` must come from the NVRAM entry.** The `isolcpus=2,3
   nohz_full=2,3 rcu_nocbs=2,3` arguments live only in that entry's
   LoadOptions. If the firmware has discarded it, the `UEFI OS` fallback still
   boots — but it boots the *builtin* command line, i.e. without isolation, and
   the run would silently re-measure `minimal-gentoo` under a different label.
   Run `sudo ./scripts/12_restore_boot_entries.sh` from Ubuntu first if the
   entry is missing from the F11 menu.
2. **Confirm the isolation actually took**, before trusting anything. It has
   been empty on all thirteen runs so far, because every one of them booted the
   plain arm:
   ```
   cat /proc/cmdline                       # isolcpus= present?
   python3 -m gpubench env | grep -E 'isolated|nohz_full'
   ```
3. **Copy results back by label, never with `*.json`.**
   `logs/from-target/results/` also contains `20260917T171657-stock-ubuntu.json`
   — the torch 2.11 run that was deliberately moved to `results/superseded/`
   here. A blanket `cp` puts it back under its original name, inside the
   `results/*stock-ubuntu*.json` glob, and silently poisons every future
   baseline with three releases of torch drift. That confound is the reason the
   `compare` stack check exists; do not reintroduce it through a wildcard.

Expect the feed path and the dispatch number to move, and expect compute and
memory not to. Take three runs; the Gentoo side is deterministic enough that
three is plenty.

---

## How the feed-path measurement was finally collected

Kept because it took three attempts and each failure was a different class of
problem. If a future arm produces nothing, the cause is likely in here.

### The 10:52 attempt failed twice over

A run was attempted on 2026-09-18 at 10:52 and produced no measurement. Two
independent causes, either of which was enough on its own:

**1. No network.** The machine booted with no interface at all — only `lo`.
`09` aborted at its default-route check before installing anything. Every
disk-side explanation was checked and cleared: `r8169.ko` installed,
`modules.alias` carrying `pci:v000010ECd00008125…  r8169`, `modules.dep`
showing no dependencies, `PHYLIB`/`REALTEK_PHY` built in, `rtl8125a-3.fw`
present, nothing blacklisting it, `80-drivers.rules` intact, `systemd-utils`
built with `USE=kmod`. `dmesg` never mentions `r8169`, so modprobe was never
called.

What that boot actually shows is that **udev coldplug loaded no modules at
all**: `nvidia` appears at 15.2 s, which is the `modules` service at the `boot`
runlevel loading it by name, not `udev-trigger` at `sysinit` matching its
modalias. `nvidia_drm`, the other module nothing names explicitly, is missing
too. Why coldplug did nothing is **still unknown**.

**It is intermittent, which is the most useful thing known about it.** The
11:22 boot came up with `r8169` loaded and `enp3s0` holding a lease, on the
same disk and the same kernel, with nothing changed in between. So it is not a
missing file or a wrong config — every candidate of that shape was checked and
cleared anyway — but a race or a timing-dependent failure in coldplug. That
also means catching it requires being lucky on the boot where it happens:
`13_gentoo_preflight_and_run.sh` captures `udevadm test` output automatically,
but only on a boot that actually fails, which is why the evidence is still
outstanding.

`06_nvidia_driver.sh` now names `r8169` in `/etc/conf.d/modules` so the one
network interface no longer depends on coldplug working. That file is written
in the chroot, so the change is not on the target yet; the preflight below
applies it in place, which is cheaper than re-running 06.

**2. The clone was three commits stale.** The Gentoo side is a *separate
checkout* at `/root/ai-specialized-os-prototype`, cloned from GitHub. Its HEAD
was `a8d1d0e`, and `--feed-path` arrived in `39a2de7`. Even with working
network, that run would have re-measured the existing baseline and produced
nothing new. **`git pull` is a required step, not a tidiness step** — it was
missing from this runbook, which is why it was missed.

### And why the 11:22 retry still did not measure

Adding the `git pull` was not enough, because the pull itself refused:

```
error: The following untracked working tree files would be overwritten by merge:
        results/20260918T100008-minimal-gentoo.json
        ... Aborting
```

Results are written on the target and travel back to Ubuntu over the disk,
where they are committed and pushed. So the same file ends up untracked here
and tracked upstream, and git will not overwrite an untracked file with a
merge. `13` now moves exactly those files — untracked locally, present in
`origin/main` — into `/root/handoff/preserved/` before merging, rather than
deleting them.

The `--feed-path` guard did its job: the stale checkout was caught and the run
stopped instead of quietly re-measuring the old baseline and looking like a
success.

### The 11:30 run, which worked

Third attempt, and it went straight through — 11:30:01 to 11:36:04, three runs,
`exit_status=0`. The preflight log records each fix doing its job:

```
r8169 loaded: yes            udev coldplug worked this boot
default route present        192.168.0.18/24 on enp3s0
/etc/conf.d/modules          already names r8169 (persisted at 11:22)
git pull                     3 untracked results preserved, then a8d1d0e -> c0d10a8
09 carries --feed-path       guard satisfied
CPU governor                 powersave -> performance
swap                         off
```

Two things in that list are worth noticing. The governor was on `powersave`
again despite having been set before — it does not survive a reboot, and only
the preflight catches it. And `13` moved the three untracked result files out
of the way rather than deleting them, which is what let the pull through.

Three lessons, in the order they cost time:

- **A runbook step that only a human remembers is not a step.** The `git pull`
  was in the prose and not in any script, and it was skipped. It is now inside
  `13`, along with the network repair and the governor.
- **A guard that stops a run is cheaper than a run that produces the wrong
  number.** The `--feed-path` check turned a silent re-measurement of the old
  baseline into a loud abort with a named cause.
- **Bootstrap scripts cannot arrive through the thing they bootstrap.** `13`
  is what repairs the network and updates the checkout, so it cannot itself
  come from the checkout. `14_install_target_runner.sh` places it on the target
  as `/root/run.sh` from Ubuntu; re-run it after changing `13`.

Operational notes that still apply to every arm:

- `09` tees its own output into the bundle as `run-<timestamp>-<label>.log`,
  one per run, so a failure says which check rejected the machine instead of
  leaving it to be inferred from `ip.txt`. `summary.txt` names the log for the
  run it describes.
- The first run of a new arm installs nothing new (torchvision is already
  there) but does rebuild the JPEG corpus under `/dev/shm` if the tmpfs was
  cleared by the reboot — about 30 s. The corpus **must** stay on tmpfs:
  Ubuntu runs from an SSD and the target from a 5400rpm HDD, and that is the
  one confound this comparison cannot absorb.

### Reading the comparison

`compare` prints a loud `!! SOFTWARE STACK DIFFERS` block whenever torch,
cuDNN, CUDA runtime, Python or the driver differ between two runs. If that
block is absent, the deltas are the OS speaking. If it is present, they are
not — no matter how clean the table above it looks. This exists because the
first comparison had no such check and reported three torch releases of drift
as though it were kernel tuning.

The percentages that matter to this project are in `gpubench utilization`,
not in the delta table: a configuration 0.7% faster than Ubuntu is still
leaving two thirds of the card unused if its MFU is 34%.

**Environment for the Ubuntu side**: `~/miniconda3/envs/gpubench-314`
(Python 3.14.7 + torch 2.14.0 + torchvision 0.29.0), built to match Gentoo
exactly. The older `envs/torch` is Python 3.11 / torch 2.11 and must not be
used for baselines. Run from the project root with `PYTHONPATH=$PWD`, since
`gpubench` is not installed into the environment:

```
PYTHONPATH=$PWD ~/miniconda3/envs/gpubench-314/bin/python -m gpubench run \
    --label stock-ubuntu --precision-mode mixed --batch-size 1 --seq-len 1024 \
    --feed-path --feed-batch-size 64 --feed-steps 40
```

---

## Booting into Gentoo again

1. Reboot, press **F11**, pick **`Gentoo-ML`**.
   Ubuntu is still the default boot target, so a plain reboot goes back to
   Ubuntu and a failed boot costs only a power cycle.

   **If `Gentoo-ML` is not in the F11 menu**, the firmware has discarded the
   NVRAM entries again — expected on this board, see "When the disk vanishes
   from the boot menu" below. Look for the Toshiba under a firmware-assigned
   name instead (`UEFI OS`, or the model string): that is the
   `\EFI\BOOT\BOOTX64.EFI` fallback, and it boots the plain configuration from
   the command line compiled into the kernel. It is not a degraded mode — same
   kernel, same command line. Only the `isolcpus` arm needs the NVRAM entry,
   which `sudo ./scripts/12_restore_boot_entries.sh` puts back from Ubuntu.

   If the Toshiba is absent under *any* name, run the disk checks in that same
   section before suspecting hardware. It has been fine every time so far.
2. Log in as `root`.
3. ```
   /root/run.sh [label]        # default label: minimal-gentoo
   ```
   This is `13_gentoo_preflight_and_run.sh`, placed there by
   `14_install_target_runner.sh` from Ubuntu. It repairs the network, persists
   `r8169`, pulls the checkout, verifies the pulled code carries what the run
   needs, sets the governor, swaps off, then runs `09` three times.

   **The `git pull` inside it is load-bearing.** `/root/ai-specialized-os-prototype`
   is a separate working copy that only receives changes through GitHub, and it
   has already been three commits behind at run time once — see below. Push
   from Ubuntu before rebooting.

   Doing it by hand instead is `cd /root/ai-specialized-os-prototype && git pull
   && ./scripts/09_gentoo_first_boot.sh`, but then the governor, the network and
   the staleness check are back to being things someone has to remember.

   The script verifies the boot, installs the **pinned** torch (replacing a
   mismatched one if it finds it), runs the benchmark, and compares against the
   stock baseline. It writes `/root/handoff/` from an EXIT trap — including a
   full log of its own output — so diagnostics survive even if it aborts early.
4. Reboot back to Ubuntu (no F11).
5. ```
   sudo ./scripts/11_collect_from_target.sh
   ```
   Mounts the target read-only and pulls `/root/handoff/` into
   `logs/from-target/`, printing the headline facts.

Results are handed back over the disk rather than over the network: both disks
are in the same machine, and pushing from Gentoo would mean authenticating
GitHub on a system with no credentials on it.

### If it fails

Any failure is recoverable by power-cycling back into Ubuntu. The Samsung SSD
(Ubuntu), the WDC drive (BitLocker) and the TAMMUZ drive (Windows) have never
been written to at any point in this project.

| Symptom | Meaning |
|---|---|
| Black screen | Framebuffer driver problem — power cycle, report it |
| Kernel panic | Photograph the screen |
| No `nvidia` in `lsmod` | Try `modprobe nvidia nvidia_uvm` and read the error |
| `nvidia-smi` fails | Something is missing from the kernel config |
| No IP from `ip a`, interface listed | `rc-service dhcpcd restart` |
| No interface at all, only `lo` | `r8169` never loaded — `modprobe r8169` first, *then* restart dhcpcd. Seen on 2026-09-18; cause unknown, see "The 10:52 attempt" |

### When the disk vanishes from the boot menu

Happened three times on 2026-09-17, and it is not random: this board discards
any boot entry it did not itself derive. See the section below for the
mechanism. The symptom is that `Gentoo-ML` and `Gentoo-ML-isolcpus` are gone
from NVRAM, `BootOrder` is back to just `0001,0000`, and the Toshiba stops
appearing in the F11 menu entirely. It reads like a dead drive. It is not one.

**Check the disk from Ubuntu before suspecting hardware.** Every time this has
happened, the drive has been provably fine, and the checks take a minute:

```
lsblk -o NAME,SIZE,MODEL,SERIAL,LABEL          # all three partitions present?
sudo dmesg | grep -E "ata[0-9]+[.:]"           # link up? any resets or errors?
lsblk -o NAME,PARTTYPE,PARTTYPENAME /dev/sdc   # is sdc1 still an EFI System?
```

On 2026-09-18 that read: `sdc` with `GENTOO_ESP`/`GENTOO_SWAP`/`GENTOO_ROOT`
intact, `ata7: SATA link up 3.0 Gbps` with no errors and the drive identifying
48 ms after link-up, and `sdc1` typed `c12a7328-…` exactly like the Ubuntu ESP.
Nothing was wrong with the disk on any of the three occasions.

Two details worth knowing so they do not look like faults. **3.0 Gbps is
correct for this drive** — `MQ01ABD` is a SATA II part; only `MQ01ABF` is
6 Gb/s. And the Toshiba is always the *last* of the four to be configured, by
about 40 ms, which is normal 2.5" HDD behaviour and far too small to be a
spin-up problem. A genuine spin-up-timing fault would also be intermittent;
this failure is perfectly reproducible, which is what pointed at firmware
policy rather than hardware.

```
sudo ./scripts/12_restore_boot_entries.sh
```

It finds the disk by serial, discovers the kernel image on the ESP rather than
assuming a version, recreates both entries, appends them to `BootOrder` so
Ubuntu stays the default, and then reads NVRAM back to confirm each entry
exists, points at the right ESP, carries `root=PARTUUID=` and is in
`BootOrder`.

**A fallback `\EFI\BOOT\BOOTX64.EFI` is the actual fix, and it is installed.**
This file used to say the opposite — "would not help, so do not add one" — and
that was correct only while the command line lived nowhere but NVRAM. Booting
the fallback path passes no LoadOptions, so the kernel came up with no `root=`,
no initramfs to recover, and panicked. The reasoning was sound; the premise has
since been removed. 05 compiles the command line in as `CONFIG_CMDLINE`, so
that path now boots.

That matters because restoring NVRAM entries turned out not to be a fix at all,
only a delay. On 2026-09-18 the 19:24 log from the previous evening was read
back: `BootOrder` had held **seven** entries and now held two. `0002`, `0003`
and `0004` had gone along with our `0005` and `0006`. The survivors were
`\EFI\Microsoft\Boot\bootmgfw.efi` and `\EFI\ubuntu\shimx64.efi`.

Both survivors are paths AMI's own boot scan recognises. This firmware
regenerates its boot list from that scan every POST and does not carry forward
entries it cannot re-derive, so `\EFI\Gentoo\vmlinuz-*.efi` was never going to
survive a reboot no matter how carefully it was written and verified. A disk
with nothing regenerable on it also never reaches the boot list, which is why
the Toshiba looked absent from the firmware entirely.

Confirmed by probe before committing to a rebuild: copying the existing kernel
to `\EFI\BOOT\BOOTX64.EFI` and rebooting made the Toshiba appear immediately,
and the firmware loaded and ran the kernel, which then panicked at exactly the
missing `root=` — proving the firmware reads the ESP fine and that the only
missing piece was the command line.

So the division of labour is now:

- **`\EFI\BOOT\BOOTX64.EFI` + `CONFIG_CMDLINE`** — guarantees the disk is
  visible and bootable. Survives NVRAM loss because it does not use NVRAM.
- **NVRAM entries** — select between configurations. Losing them now costs the
  `isolcpus` arm of the A/B test, not the ability to boot.

---

## Machine

| | |
|---|---|
| CPU | Intel i3-14100F — 4C/8T, **no integrated graphics** |
| RAM | 24 GB DDR4-2133 |
| GPU | NVIDIA RTX 3060 12 GB (GA106), driver 595.84, CUDA 13.2 |
| Board | MSI PRO B760M-A DDR4 II, UEFI |
| NIC | Realtek RTL8125 2.5GbE (`r8169`, built as a module) |
| SATA | Intel Raptor Lake AHCI (`ahci`, built in) |

### Disks — only `sdc` is ever touched

| Device | Identity | Status |
|---|---|---|
| `sda` | Samsung SSD 870 EVO 2TB | **Live Ubuntu** — never written |
| `sdb` | WDC WD40EZRZ 4TB | BitLocker "Storage2" — never written |
| **`sdc`** | **TOSHIBA MQ01ABD100M 1TB, serial `Z6CFSL8MS`** | **Target** |
| `sdd` | TAMMUZ 238 GB | Windows — never written |

Every script locates the target by **serial number**, never by `/dev/sdX`, and
aborts if the model or byte size does not match. Kernel device names are
assigned in probe order and can change between boots; a serial cannot.

### Identifiers

```
disk serial     Z6CFSL8MS
root PARTUUID   3eb15fc3-858e-4b37-abe5-d43c8554799a   <- used by root=
root fs UUID    bfeafe2f-51cb-4648-bae4-c81009d78e22   <- used by /etc/fstab
ESP UUID        930F-3DE2
swap UUID       69f553c9-5179-49e5-a653-9f0d502e7b77

sdc1  1 GiB    FAT32  GENTOO_ESP
sdc2  8 GiB    swap   GENTOO_SWAP    build insurance; swapoff for benchmarks
sdc3  922 GiB  ext4   GENTOO_ROOT
```

The ESP carries the same kernel twice, on purpose:

```
\EFI\Gentoo\vmlinuz-6.18.48-gentoo.efi   named NVRAM entries point here
\EFI\Gentoo\config-6.18.48-gentoo        the config that image was built from
\EFI\BOOT\BOOTX64.EFI                    the firmware's own scan finds this one
```

`root=` must use **PARTUUID** and `/etc/fstab` must use the **filesystem
UUID**. They are not interchangeable — see "Decisions" below.

---

## Scripts

`00_run_pipeline.sh` runs 02, 05, 06, 07, 08, 10 in order, logs each step to
`logs/`, stops at the first failure with the mounts left in place, and ends with
an assertion-based verdict. Step 02 always runs regardless of `--from`, because
it establishes the mounts and syncs the scripts into the chroot.

| | Runs on | Does |
|---|---|---|
| `01_partition_target_disk.sh` | host | GPT, ESP/swap/root, format |
| `02_bootstrap_stage3.sh` | host | Mount, unpack stage3, Portage config, chroot mounts, **stage scripts** |
| `03_chroot_setup.sh` | chroot | Repo sync, profile, timezone, locale, fstab |
| `04_build_world.sh` | chroot | Portage update, `@world`, base toolset, `rust-bin` |
| `05_configure_kernel.sh` | chroot | Kernel config + verify + build |
| `06_nvidia_driver.sh` | chroot | NVIDIA driver against that kernel |
| `07_make_bootable.sh` | chroot | Services, root password, ESP, EFI entries |
| `08_teardown_chroot.sh` | host | Clean unmount |
| `09_gentoo_first_boot.sh` | **booted Gentoo** | Verify, install torch, benchmark |
| `10_vm_smoke_test.sh` | host | QEMU boot test, non-destructive |
| `11_collect_from_target.sh` | host | Read `/root/handoff` off the target |
| `12_restore_boot_entries.sh` | host | Recreate the EFI boot entries after NVRAM loss |
| `13_gentoo_preflight_and_run.sh` | **booted Gentoo** | Network, checkout, governor, then N× `09` |
| `14_install_target_runner.sh` | host | Put 13 on the target as `/root/run.sh` |

01, 03 and 04 are done and do not need re-running. 02, 05–08 and 12 are
idempotent.

`14` is the only script in the project that mounts the target **read-write**
from Ubuntu, so it checks harder than the read-only collectors do — serial,
model, not-the-live-root, `/etc/gentoo-release` present, a repo clone present —
and writes exactly one file. Re-run it whenever `13` changes; the copy does not
update by itself, which is the cost of it being the bootstrap.

---

## Decisions worth not re-litigating

**Gentoo as the base.** Chosen because the larger project's deliverable is a
Rust PID 1. OpenRC is default and systemd is absent, so replacing init does not
mean fighting udev/logind/journald. USE flags remove code rather than just
packages — `USE="-X -wayland"` means `libX11` is never built, which a binary
distribution cannot express. Verified after the build: `xorg-server`, `libX11`,
`wayland` and `pulseaudio` are all absent from the tree.

**Not the `hardened` profile.** Its toolchain and kernel mitigations cost
measurable performance, and this machine exists to measure performance.

**No initramfs.** AHCI and ext4 are built in, so the kernel mounts root
directly. One less layer between firmware and PID 1 — which matters when PID 1
is the component being replaced. This is *why* `root=` must be `PARTUUID=`: the
kernel resolves `root=` itself and can only read identifiers stored in the
partition table. A filesystem UUID lives in the superblock, which cannot be read
until the filesystem is mounted. An initramfs normally breaks that circle with
blkid; this system has none.

**EFI stub, no bootloader.** The kernel image *is* the EFI executable. The
command line lives in the EFI boot entry, so each configuration under test gets
its own named entry and the firmware boot menu doubles as the A/B test menu:

```
Boot0002  UEFI OS              \EFI\BOOT\BOOTX64.EFI  <- firmware made this one
Boot0003  Gentoo-ML            root=PARTUUID=... rw nvidia-drm.modeset=0 console=tty0
Boot0004  Gentoo-ML-isolcpus   + isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3
BootOrder 0001,0000,0002,0003,0004                <- 0001 is Ubuntu, still first
```

`UEFI OS` is not ours. The firmware created it by finding
`\EFI\BOOT\BOOTX64.EFI` during its own scan, which is exactly why it is the
entry that survives — it is regenerated rather than remembered. It boots the
plain configuration from the kernel's builtin command line.

**Refer to these by label, never by number.** The firmware assigns the number,
and it reuses freed slots: `Gentoo-ML` has been `Boot0005`, then `Boot0002`,
and is now `Boot0003`. The label is ours and is stable.

**Both `FB_SIMPLE` and `FB_EFI`.** sysfb registers `simple-framebuffer` when the
firmware's mode is compatible with the generic modes and falls back to
`efi-framebuffer` when it is not. Only the firmware decides which. Enabling one
driver risks a black screen with no console to read the reason from, and the
QEMU test structurally cannot catch it — `-kernel` boot hands over no
framebuffer at all.

**NVIDIA pinned to 595.84.** Deliberately overrides the project's
"always latest" rule for this one package: the stock baseline was measured with
595.84, and attributing a difference to the OS fails if the driver moves at the
same time. Upgrade after the comparison is recorded, as its own labelled run.

**Open kernel modules.** Not a choice — `USE=kernel-open` was removed from the
ebuild and is now always on for this driver version. Spec §3.1 assumed a
closed-source kernel module; that is now only true of the CUDA userspace.

**No GPU passthrough to a VM.** The i3-14100F has no integrated graphics and
there is one card, so passing it through leaves the host with no display. The
IOMMU side is actually ideal (group 10 holds only `01:00.0` and `01:00.1`), but
passthrough could only answer a yes/no that bare metal answers in two minutes,
and a hypervisor layer would contaminate the very measurement this project
exists to take.

---

## Measurement

`gpubench/` measures where GPU throughput goes, per loss source, with an
environment snapshot and NVML telemetry attached to every run. Results are
labelled and diffed across OS configurations — that comparison is the point.

```
python3 -m gpubench run --label <name> --precision-mode mixed --batch-size 1 --seq-len 1024
python3 -m gpubench compare results/a.json results/b.json
```

### `stock-ubuntu` baseline (committed, `results/`)

Mean of the six matched-stack runs (torch 2.14.0). The figures the project
quoted before 2026-09-18 09:46 came from the torch 2.11 run now in
`results/superseded/` and should not be carried forward.

```
fp32     9.45 TFLOPS   74.2% of spec   1.00x
tf32    13.56 TFLOPS   53.2%           1.44x
bf16    27.26 TFLOPS  106.9%           2.88x
fp16    27.14 TFLOPS  106.4%           2.87x

memory bandwidth   332.8 GB/s  (92.4% of 360)
PCIe H2D           20.25 GB/s pinned  vs  8.69 GB/s pageable   (2.33x)
kernel launch      2.86 us eager  ->  0.90 us graphed          (3.18x)
training step      MFU 34.9%, 3878 tok/s, 9934 MiB peak VRAM
feed path          94.7% of the card's ceiling survives being fed

throttling: sw_power_cap for 54-77% of the GEMM sweep
```

**Read the throttling line first.** The card sat at its 170 W power cap for
most of the sweep, so those achieved-TFLOPS figures measure the power limit,
not the code. Without that telemetry, fp32 at 74.2% would have looked like
inefficient code. Gentoo throttles the same way on the same sweep (75%), which
is why no OS change moves the compute rows and none has.

### What the OS can and cannot recover

Because the power cap dominates, a minimal OS will **not** move GEMM TFLOPS
much. That prediction has now been tested and held — compute, memory and
training throughput all came back identical. What it does recover is host-side,
and all four of these are confirmed:

- **473 MiB VRAM** held by the desktop session (`nvidia-drm.modeset=0`) —
  Gentoo runs start with 11,776 MiB free against Ubuntu's 11,461–11,603
- **CPU governor** — stock Ubuntu was on `powersave`, throttling the cores that
  feed the GPU. Note it does not survive a reboot on Gentoo either; the
  preflight in `13` sets it every time, and caught it on `powersave` again at
  11:30
- **persistence mode** — was disabled; `nvidia-persistenced` is now enabled
- **scheduler jitter** — the largest single effect, and visible in three
  independent places: `step_time_stdev` (1.11 ms → 0.05 ms), PCIe pinned spread
  (47.6% → 0.04%), and feed-path step p99/p50 (1.02 → 1.001)

Set expectations accordingly: this project recovers host overhead, VRAM and
run-to-run variance, not the GPU compute ceiling.

### A spec correction worth carrying forward

Spec §5.2 claims Qwen3-0.6B "fits comfortably within 12GB without CPU offload."
Measured, with mixed-precision AdamW:

```
model state alone  7,751 MiB    63% of the card
activations        2,183 MiB
peak               9,934 MiB    1,956 MiB spare

largest configs that fit @ seq 1024:
  mixed             batch 1      (batch 2 OOMs)
  mixed + ckpt      batch 2
  pure bf16         batch 2
  pure bf16 + ckpt  batch 4
```

The 151,936-token vocabulary makes the logits tensor, not the weights, the
memory bottleneck. Spec §7 lists 8-bit AdamW as "recommended" — it is closer to
required: it would cut the optimizer moments from 8 to 2 bytes/param, freeing
about 2.9 GB.

---

## What the VM smoke test cannot tell you

It covers kernel boot, AHCI, GPT scan, ext4 root mount with no initramfs,
OpenRC, udev, dhcpcd, sshd, a login prompt, and absence of panics. It cannot
cover anything involving the actual card:

1. **Which framebuffer driver the firmware hands over.** `-kernel` boot hands
   over no framebuffer at all, so this is structurally untestable in QEMU.
   Verified on bare metal only by the console coming up.
2. **NVIDIA module load and `nvidia-smi`.** No GPU in the VM, so
   `nvidia-persistenced` failing there is expected and means nothing. On bare
   metal the same failure would mean the driver did not attach.
   **Verified on bare metal 2026-09-18** — all four modules, persistence
   enabled.
3. **CUDA on the minimal kernel.** The question the prototype exists to answer.
   **Verified 2026-09-18**, then measured thirteen times.

And the trap that follows from 1–3, because it has already caused a false
alarm: step 10 boots the installation **in QEMU** with `snapshot=on`, so the
real disk is never written — but its serial console prints the same
`gentoo-ml login:` banner the real machine does. Logging in there proves the
getty works and nothing else; any work done inside it is discarded when the VM
exits. If a `gentoo-ml login:` is on screen, check whether
`00_run_pipeline.sh` is still running before concluding the machine has booted.

---

## Working agreement

1. Converse in Korean; write all code, comments and docs in English.
2. Prefer latest library/toolchain versions; web search is authorized to confirm
   them. (The NVIDIA pin above is a deliberate, documented exception.)
3. **One question at a time.**
4. Get approval before touching anything above the working directory.
5. Get approval before starting work — including resuming after a finished task.

---

## How the bugs went, and what changed

Fifteen bugs during this build. Two were real system-configuration problems
(`root=UUID=` without an initramfs, and the missing `efi-framebuffer` fallback
driver). The other thirteen were all script orchestration: source-versus-deployed
copies drifting, mount preconditions, and success being announced rather than
verified.

Five patterns worth not repeating:

- **Writing a parser against an assumed output format.** `efibootmgr` prints the
  device path after the label, so an anchored `label$` match never fired and
  boot entries accumulated instead of being replaced. Run the command, look at
  it, then write the matcher.
- **Suppressing a command's output and then printing success anyway.**
  `rc-update ... >/dev/null 2>&1 || true` followed by an unconditional
  "-> default runlevel" meant a failed registration was indistinguishable from a
  successful one. Both registration paths now check that the runlevel symlink
  exists and abort if it does not.
- **A design decision not propagating to its dependents.** "No initramfs"
  implies `root=PARTUUID=`; "headless" implies the console still needs a
  framebuffer driver. When a constraint is chosen, write it down and check what
  else it touches.
- **A step that lives only in prose.** The `git pull` on the target was
  documented in this file and in no script, and it was skipped on the first
  attempt at the feed-path measurement — costing a boot. The fix was not a
  louder warning but moving it into `13`, together with the network repair and
  the governor. The same applies to the `cp logs/from-target/results/*.json`
  line that used to be here: it silently undid the torch-2.11 supersede, and a
  wildcard in a runbook is a bug waiting for someone to run it verbatim.

- **Code exercised only on the clean path.** Both of 2026-09-18's bugs were
  this, and both blocked *resuming* rather than starting. 07 read
  `/boot/config-$KVER` for evidence that the kernel had a builtin command line,
  on the assumption that `make install` leaves one there — it does that only
  when an `installkernel` is in `$PATH`, and none is, so the file had never
  existed. 02 fed lsblk's `MOUNTPOINT` column to `umount`, which works until a
  rerun finds swap active and the column reads `[SWAP]`; a clean run never sees
  it because 08 swaps off during teardown. `--from` exists to make resuming
  cheap, so the resume path deserves the same scrutiny as the first run.

Two smaller notes from the same day. The `/boot/config` copy to the ESP had
carried `2>/dev/null || true` since it was written, so the file's absence had
been tolerated silently the whole time — the suppress-and-continue pattern
above, caught only because a later guard happened to need the same file. And
07's error for that guard named the wrong cause, telling the next run to re-run
05 when 05's own log showed `CMDLINE_BOOL y OK` and the full command line
verified; an error that misidentifies its cause costs a diagnosis cycle and
nearly sent the fix in the wrong direction.

`00_run_pipeline.sh` ends with one assertion per bug that actually occurred, so
a regression surfaces at the end of a run rather than at the next reboot.
