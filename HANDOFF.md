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

**It has now booted on bare metal, and the CUDA stack survived.** Booted
2026-09-18 09:12–09:27 from the F11 menu; `09_gentoo_first_boot.sh` ran to
completion with `exit_status=0`. The bundle is in `logs/from-target/`.

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

As measured on 2026-09-18, the weakest path is the training step at **34.8%**
of the bf16 tensor ceiling. Compute, memory and pinned transfer are all close
to the card's limits (92–106%); pageable H2D sits at 59.6%.

### What the OS was actually worth

Measured 2026-09-18 on a matched stack — torch 2.14.0, Python 3.14.7,
cuDNN 92400 on **both** sides, so the kernel is the only variable. Ubuntu ran
three times (09:46–09:48), Gentoo four across two separate boots (09:25 and
10:00–10:01). `results/` holds all seven. A row counts as a difference only
when the two min..max ranges do not overlap.

| path | ubuntu n=3 | gentoo n=4 | verdict |
|---|---|---|---|
| GEMM fp32 | 9.33 .. 9.54 TFLOPS | 9.40 .. 9.54 | overlap — same |
| GEMM bf16 | 27.03 .. 27.49 TFLOPS | 26.97 .. 27.28 | overlap — same |
| memory bandwidth | 331.9 .. 333.1 GB/s | 333.1 .. 333.1 | overlap — same |
| train MFU | 34.80 .. 35.00 % | 34.80 .. 35.00 | overlap — same |
| train tok/s | 3872 .. 3893 | 3870 .. 3896 | overlap — same |
| **PCIe pageable H2D** | 8.10 .. 8.89 GB/s | **14.81 .. 14.90** | **+73%** |
| **PCIe pinned H2D** | 15.56 .. 20.30 GB/s | **24.58 .. 24.59** | **+38%** |
| **kernel launch (eager)** | 2.79 .. 2.85 µs | **3.04 .. 3.14** | **+9% slower** |
| kernel launch (graphed) | 0.89 .. 0.90 µs | 0.91 .. 0.92 | +2% slower |

So the minimal kernel costs nothing on compute, memory or training throughput,
wins large on host-to-device transfer, and loses a little on kernel dispatch.
Graph capture cuts dispatch to 0.91 µs (3.3x), so the launch regression is a
structural weak point rather than a real ceiling.

**The variance is the more interesting result.** The minimal kernel is not
just faster on transfer, it is close to deterministic:

```
PCIe pinned     ubuntu 15.56 .. 20.30  (±13%)     gentoo 24.58 .. 24.59  (±0.02%)
PCIe pageable   ubuntu  8.10 ..  8.89  (±4.6%)    gentoo 14.81 .. 14.90  (±0.3%)
memory          ubuntu 331.9 .. 333.1             gentoo 333.1 .. 333.1  (identical x4)
```

Four Gentoo runs across two boots put memory bandwidth at the same figure to
one decimal, and pinned PCIe inside a 0.01 GB/s window, while Ubuntu's pinned
figure moves 13% run to run on the same hardware. This is item 6 in the
README's table — OS-level noise — and it is the thing the project set out to
remove. For a measurement harness it matters more than the means: a 13% swing
is wide enough to hide most of the effects the later arms are meant to detect.

An earlier comparison, made before the pin existed, reported GEMM regressions
of −1.3% to −2.8% and a +59% pageable gain. The regressions were the torch
version, not the kernel, and vanished once the stacks matched — one of them
(fp32) even changed sign. That run is kept at
`results/superseded/20260917T171657-stock-ubuntu-torch2.11.json`, out of the
`results/*stock-ubuntu*.json` glob so it cannot be picked up by accident.

One trap worth naming, because it has already caused a false alarm: step 10
boots the installation **in QEMU**, with `snapshot=on` so the real disk is never
written. Its serial console prints the same `gentoo-ml login:` banner the real
machine does. Logging in there proves the getty works and nothing else — any
work done inside it is discarded when the VM exits. If a `gentoo-ml login:` is
on screen, check whether `00_run_pipeline.sh` is still running before concluding
the machine has booted.

---

## Do this next

**Boot Gentoo and take the feed-path measurement.** It is new, so no Gentoo
run has it yet; the Ubuntu side already does. `09_gentoo_first_boot.sh` now
passes `--feed-path`.

### The 10:52 attempt failed twice over — read this before repeating it

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
too. Why coldplug did nothing is **still unknown** and needs a live boot to
diagnose — see the preflight below.

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

This is the measurement that answers what the CPU↔GPU path costs, and it is
the one place the two kernels still might differ in a way that matters.
Everything measured so far on the device side came out identical — compute,
memory, training throughput — while the two real differences (PCIe transfer
+38/+73%, dispatch −9%) both live on the boundary between host and device.
The feed path is that boundary under load, so it is where those two effects
either cancel or compound.

On Ubuntu the answer is **94.7% of the card's ceiling survives being fed**
(transfer −2.5%, host −2.8%, n=3, spanning 94.7–94.8%). The GPU sits blocked on
the loader 2.4% of wall time, and the worker sweep peaks at 2 and degrades past
the physical core count:

```
workers   0: 230.3    2: 386.9    4: 382.7    8: 356.5   img/s   (mean of 3)
```

That baseline is reproducible to ±0.05 percentage points, which makes it a
sensitive instrument: a real difference on the Gentoo side will be unmissable.
Whether the minimal kernel does better is unmeasured.

```
# reboot, F11, pick Gentoo-ML.  Then, as root:

# --- preflight: network, then the code, then the clocks -------------------
ip -brief addr                      # only lo listed? then r8169 never loaded

# Diagnose BEFORE fixing. The evidence is the unloaded state, and it is gone
# the moment the module comes up. This is also the one diagnosis that cannot
# be done from Ubuntu against a cold disk.
udevadm test /sys/bus/pci/devices/0000:03:00.0 2>&1 | tail -30
modprobe -v r8169; dmesg | tail -20

rc-service dhcpcd restart
ip route get 1.1.1.1                # must succeed before anything else works

# make it survive the next boot too (06 writes this, but only in the chroot)
grep -q r8169 /etc/conf.d/modules || \
    sed -i 's/^modules="nvidia nvidia_uvm"$/modules="nvidia nvidia_uvm r8169"/' \
        /etc/conf.d/modules

cd /root/ai-specialized-os-prototype
git pull                            # REQUIRED - see above; --feed-path lives in 39a2de7
grep -c feed-path scripts/09_gentoo_first_boot.sh    # must be non-zero

cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_governor   # must be performance

# --- measure ---------------------------------------------------------------
for i in 1 2 3; do ./scripts/09_gentoo_first_boot.sh; done

# back on Ubuntu
sudo ./scripts/11_collect_from_target.sh
cp logs/from-target/results/*.json results/
python3 -m gpubench compare results/*stock-ubuntu*.json results/*minimal-gentoo*.json
```

`09` now tees its own output into the bundle as
`run-<timestamp>-<label>.log`, one per run, so a failure says which check
rejected the machine instead of leaving it to be inferred from `ip.txt`.
`summary.txt` names the log for the run it describes.

The first run on Gentoo will install `torchvision` and build the JPEG corpus
under `/dev/shm`; both are cached afterwards. The corpus must stay on tmpfs —
Ubuntu runs from an SSD and the target from a 5400rpm HDD, and that is the one
confound this comparison cannot absorb.

**Then boot the `isolcpus` arm.** The training step sits at **34.9%** of the
bf16 ceiling and is the weakest path by a wide margin. Nothing measured so far
is OS noise, so the remaining loss is structural: four cores feeding 3584,
which is exactly what `isolcpus` is meant to protect. The −9% eager-launch
regression points the same way — dispatch is the one place the minimal kernel
loses, and dispatch is what core isolation defends.

```
# reboot, F11, pick Gentoo-ML-isolcpus  (needs the NVRAM entry; if it is gone,
# sudo ./scripts/12_restore_boot_entries.sh from Ubuntu first)
for i in 1 2 3; do ./scripts/09_gentoo_first_boot.sh isolcpus; done
```

The script takes the label as its first argument, so each arm keeps its own
results instead of landing on top of the baseline just established. Confirm
the isolation actually took before trusting the numbers — `env.capture()`
records `cpu.isolated` and `cpu.nohz_full`, and they were empty on every run
so far:

```
python3 -m gpubench env | grep -E 'isolated|nohz_full'
```

Take three runs per arm. The Gentoo side is deterministic enough that three is
plenty; it is Ubuntu that needs them.

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
   # first time only
   git clone https://github.com/TechieQuokka/ai-specialized-os-prototype
   # every time after that - this checkout is NOT the one you edit on Ubuntu
   cd ai-specialized-os-prototype && git pull
   ./scripts/09_gentoo_first_boot.sh
   ```
   **The `git pull` is load-bearing.** This clone is a separate working copy
   that only receives changes through GitHub, and it has already been three
   commits behind at run time once — see "The 10:52 attempt" above. Push from
   Ubuntu before rebooting, pull here before running.

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

01, 03 and 04 are done and do not need re-running. 02, 05–08 and 12 are
idempotent.

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

```
fp32     9.52 TFLOPS   74.7% of spec   1.00x
tf32    13.62 TFLOPS   53.4%           1.43x
bf16    27.34 TFLOPS  107.2%           2.87x
fp16    27.42 TFLOPS  107.5%           2.88x

memory bandwidth   332.4 GB/s  (92.3% of 360)
PCIe H2D           21.64 GB/s pinned  vs  9.36 GB/s pageable   (2.31x)
kernel launch      3.03 us eager  ->  0.91 us graphed          (3.31x)
training step      MFU 34.5%, 3843 tok/s, 9934 MiB peak VRAM

throttling: sw_power_cap for 54% of the GEMM sweep
```

**Read the throttling line first.** The card sat at its 170 W power cap for
more than half the sweep, so those achieved-TFLOPS figures measure the power
limit, not the code. Without that telemetry, fp32 at 74.7% would have looked
like inefficient code.

### What the OS can and cannot recover

Because the power cap dominates, a minimal OS will **not** move GEMM TFLOPS
much. What it can recover is host-side:

- **473 MiB VRAM** held by the desktop session (`nvidia-drm.modeset=0`)
- **CPU governor** — stock Ubuntu was on `powersave`, throttling the cores that
  feed the GPU
- **persistence mode** — was disabled; `nvidia-persistenced` is now enabled
- **scheduler jitter** — visible in `step_time_stdev`

Set expectations accordingly: this project recovers host overhead and VRAM, not
the GPU compute ceiling.

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

## Not yet verified — bare metal only

1. **Which framebuffer driver the firmware hands over.** Untestable in QEMU.
2. **NVIDIA module load and `nvidia-smi`.** No GPU in the VM, so
   `nvidia-persistenced` failing there is expected; on bare metal it would mean
   the driver did not attach.
3. **CUDA on the minimal kernel.** The question the prototype exists to answer.

The VM smoke test does cover: kernel boot, AHCI, GPT scan, ext4 root mount with
no initramfs, OpenRC, udev, dhcpcd, sshd, and absence of panics.

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

Thirteen bugs during this build. Two were real system-configuration problems
(`root=UUID=` without an initramfs, and the missing `efi-framebuffer` fallback
driver). The other eleven were all script orchestration: source-versus-deployed
copies drifting, mount preconditions, and success being announced rather than
verified.

Four patterns worth not repeating:

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
