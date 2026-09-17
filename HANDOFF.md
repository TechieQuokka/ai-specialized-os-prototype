# Handoff — state as of 2026-09-17

Written for a fresh session picking this up cold. `README.md` explains what the
project is and why; this file says where it stands and what to do next.

---

## Where things stand

A minimal Gentoo system is **installed and bootable** on the Toshiba HDD. The
kernel and NVIDIA driver are built, the EFI boot entries are written, and a
QEMU smoke test confirms the boot path works end to end.

**Nothing has been booted on bare metal yet.** That is the next action, and it
is the only way to answer the question the whole prototype exists for:

> Does the CUDA stack survive a kernel stripped from Ubuntu's 10,048 enabled
> options down to 1,457?

---

## Do this next

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
   git clone https://github.com/TechieQuokka/ai-specialized-os-prototype
   cd ai-specialized-os-prototype && ./scripts/09_gentoo_first_boot.sh
   ```
   It verifies the boot, installs torch, runs the benchmark, and compares
   against the stock baseline. It writes `/root/handoff/` from an EXIT trap, so
   diagnostics survive even if it aborts early.
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
| No IP from `ip a` | `rc-service dhcpcd restart` |

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
Boot0002  Gentoo-ML            root=PARTUUID=... rw nvidia-drm.modeset=0 console=tty0
Boot0003  Gentoo-ML-isolcpus   + isolcpus=2,3 nohz_full=2,3 rcu_nocbs=2,3
BootOrder 0001,0000,0002,0003                     <- 0001 is Ubuntu, still first
```

**Refer to these by label, never by number.** The firmware assigns the number,
and it reuses freed slots: these were `Boot0005`/`Boot0006` until the NVRAM loss
described above, and came back as `0002`/`0003` when they were recreated. The
label is ours and is stable.

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

Eleven bugs during this build. Two were real system-configuration problems
(`root=UUID=` without an initramfs, and the missing `efi-framebuffer` fallback
driver). The other nine were all script orchestration: source-versus-deployed
copies drifting, mount preconditions, and success being announced rather than
verified.

Three patterns worth not repeating:

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

`00_run_pipeline.sh` ends with one assertion per bug that actually occurred, so
a regression surfaces at the end of a run rather than at the next reboot.
