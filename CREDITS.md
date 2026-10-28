# Provenance and Credits

**English** | [简体中文](CREDITS.zh-CN.md)

> **Chinese is this project's primary language** — scripts, logs and `docs/` are written in
> Chinese, and this English file is a translation. Where the two differ, the Chinese text governs.

Nothing in this tool was invented from scratch. Every step stands on a public specification, a
kernel implementation, or someone else's earlier work. This file lists those sources one by one,
both so they can be checked and so the credit goes to the right people.

---

## 1. The primary source: the Resizable BAR capability

The register this tool writes is defined by PCI-SIG.

| Item | Content |
|---|---|
| Specification name | **Resizable BAR Capability ECN** |
| Proposed | 2008-01-22 |
| Approved | 2008-04-24, updated and approved by the PCI-SIG PWG (Protocol Working Group) |
| Published in | Merged as an ECN into the Revision History of **PCI Express Base Specification Revision 2.1** (released 2009-03-04), and subsequently into **Revision 3.0** (2010-11-10) |
| Extended capability ID | **`0015h`** |
| Publisher | PCI-SIG, <https://pcisig.com> |

**Why this counts as the primary source**: the Revision History of PCIe Base 2.1 lists the ECNs
merged into that revision one by one, and one entry reads, verbatim:

> Resizable BAR Capability ECN (January 22, 2008, updated and approved by PWG April 24, 2008)

In other words, the capability was finalised as an ECN in 2008, entered the specification body in
2009 (Rev 2.1), and was reissued with 8.0 GT/s in 2010 (Rev 3.0). **Before this ECN, the ReBAR
mechanism did not exist.**

The capability defines three registers in configuration space (offsets relative to the extended
capability header):

| Offset | Name | How this project uses it |
|---|---|---|
| `+00h` | Extended Capability Header | Read bit[31:20] for the next capability's offset; used to walk the chain |
| `+04h` | Capability Register | Bit[N] set means a BAR size of `2^N` bytes is supported |
| `+08h` | Control Register | bits[13:8] = BAR index, bits[5:0] = target size N |

> The specification text is distributed by PCI-SIG and is not available in full to non-members,
> so only the ECN name, approval date and incorporating revisions are cited here — no body text
> is reproduced. On the B580 the capability sits at `0x420`, and `Capability = 0007f000`
> indicates support for N=8..14 (256 MB … 16 GB).

---

## 2. Who found this method first

The specification only defines how to change the ReBAR register. It says nothing about how to
make the kernel accept the new size afterwards. Someone had to work that out, and Intel's kernel
engineers then explained the mechanism behind it. Three batons, all required.

### 2.1 First baton: andersevenrud (the first to publish this method)

| Item | Content |
|---|---|
| Form | GitHub Gist |
| URL | <https://gist.github.com/andersevenrud/eec93e9151117bc0d6b6133b40eaffa5> |
| Title | *Resizable BAR on SuperMicro H11SSL-I with Intel Arc B580* |
| Hardware | Supermicro H11SSL-i + Intel Arc B580 |
| Contribution | **First public write-up** of the sequence "`setpci` writes ReBAR Control → `remove` the root port → `rescan`", and proof that it takes a 256 MB window to 16 GB |

This is where the whole workflow starts. Before it, the only publicly documented route was
flashing the firmware (ReBarUEFI), which requires modifying firmware and carries a bricking risk.

### 2.2 Second baton: Intel kernel engineers explained why the whole card must be removed

andersevenrud showed *how*, but not *why the device has to be removed at all*. That answer came
from Intel's PCI maintainers:

| Contributor | Output | Key content |
|---|---|---|
| **Ilpo Järvinen** | `[PATCH] PCI: Release unused bridge resources during resize` (2024-05-13, linux-pci) | Using the real topology of DG2 / Arc A380, explains that **the on-card bridge's own BAR0 occupies a slice of the root port window**, so the GPU's BAR2 cannot grow and the resize returns `-ENOSPC` |
| **Ilpo Järvinen** | `[PATCH 14/24] PCI: Warn if bridge window cannot be released when resizing BAR` (2025-08-22) | Adds the **`was not released (still contains assigned resources)`** warning inside `pbus_reassign_bridge_resources()` |
| **Ilpo Järvinen** / **Lucas De Marchi** | `[PATCH 1/2] PCI: Release BAR0 of an integrated bridge to allow GPU BAR resize` (2025-09-18, intel-xe) | Adds a quirk for `0x4fa0`, `0x4fa1` and **`0xe2ff` (exactly the B580's on-card bridge)** to release the bridge BAR0; tagged `Cc: # v6.12+` |
| **Ilpo Järvinen** | Reply on linux-kernel, 2026-04-15 | States the manual path explicitly: *"It may be possible to manually remove the siblings first, resize the eGPU's BAR through sysfs, and finally rescan."* |

**That last sentence is the most direct methodological basis for this project.** Intel's own PCI
maintainer acknowledges that sibling devices pin the window, and that you can remove them by hand,
resize the BAR through sysfs, and rescan. What this project does is automate that manual sequence
and add a safety boundary so that nobody else's devices get caught in it.

It also explains a symptom: **why `was not released` shows up in dmesg.** That warning is itself
a diagnostic added by Ilpo's patch series in 2025. Seeing it confirms "the window is pinned by
something else" — it is not our invention, it is a new clue the kernel provides.

### 2.3 Third baton: RodBurlamaqui turned it into a complete tool

| Item | Content |
|---|---|
| Project | [`RodBurlamaqui/Intel-ARC-Rebar`](https://github.com/RodBurlamaqui/Intel-ARC-Rebar) (command name `arc-rebar`) |
| Form | initramfs-stage POSIX sh plus Debian packaging; runs automatically at boot |
| Licence | **Not open source**: free for personal use, commercial/institutional use requires a separate licence, derivatives prohibited (§3.1 / §3.2 / §9) |
| Credit given to prior work | Its README "Credits" states: *"andersevenrud — the setpci + remove/rescan method, in a gist for the H11SSL-i + B580"* |
| Relationship to this project | See [`CLEANROOM.md`](CLEANROOM.md) §3: we read only its `README` / `DISCLAIMER` / `INSTALL` / `LICENSE` / `live-test.sh` (6 lines) / `diagnose` output, and **never touched the core implementation scripts**; because §1.1 of its licence excludes institutional use and §3.2 forbids modification, it was judged unusable and we implemented independently |

Its LICENSE §4.2 contains a passage that is valuable to anyone following: **the licence covers
only its own implementation** (code, scripts, detection and safety logic, packaging,
documentation); it **does not claim rights over the underlying method of "write the ReBAR Control
register + re-enumerate the root port"**, and it names andersevenrud as the first to publish that
method.

In other words: the method is the method, the implementation is the implementation. We use the
method and wrote our own implementation — which is exactly the position of `CLEANROOM.md`.

### 2.4 The nearest neighbour on the same route: Emvo10's B580-specific tool

| Item | Content |
|---|---|
| Project | [`Emvo10/Intel-Arc-B580-ReBar`](https://github.com/Emvo10/Intel-Arc-B580-ReBar) (formerly `b580-rebar-linux`; the old URL 302s to the current name) |
| Published | Created **2026-09-05**, last updated 2026-09-11 — **about 7 weeks before this project** |
| Target machine | Intel Arc B580 12 GB (`8086:e20b`) — **exactly the same card as this project** |
| Form | POSIX sh main script (`b580-rebar`) + `install.sh` / `uninstall.sh` + systemd service; runs at boot |
| Method | The same route: `setpci` writes ReBAR Control → `remove` the upstream root port → `rescan`, also requiring kernel `pci=realloc` |
| Licence | **None** (no LICENSE file). Publicly visible is not the same as open source — treated as all rights reserved by default copyright, so this project **read only its README and never read or referenced its script implementation** |
| Credit given to prior work | Its README "Credits" states: *"based on the Linux B580 `setpci` + PCI remove/rescan method documented by Anders Evenrud for the Supermicro H11SSL-i"*, with the same gist link |

**Why this deserves its own section**: for the B580 specifically, it is the earliest public
implementation we could find whose target machine **coincides exactly** with this project's. The
two converged independently on the same sequence of actions (`setpci` writes Control → remove →
rescan → verify), which says the route is not one person's coincidence but the necessary solution
for this card on older platforms. It is also the second independent piece of evidence that
"andersevenrud's gist can be engineered into a tool" — corroborating this repository's conclusion.

The differences, recorded honestly:

| Dimension | Emvo10 | This project |
|---|---|---|
| Intended use | Desktop gaming (Bazzite / Fedora / rpm-ostree ecosystem); goal is for LACT to report the full CPU-accessible VRAM | SYCL inference on a headless server; goal is for SYCL to be able to allocate VRAM at all (it SIGBUSes at 512 MB) |
| When it takes effect | systemd service at boot; stays in effect once installed | Manual at runtime by default; `tools/rebar-autofix.sh` is an optional boot oneshot |
| Shared root port | **Refuses by default**: aborts if the branch contains NVMe / network / USB | **Two behaviours coexist**: `tools/rebar-batch.sh` uses `topo_anchor()` to **downgrade the anchor to the on-card bridge, never crossing the boundary** (finer-grained than refusal, still able to try on a shared root port); but the single-GPU script's `apply` **does not reuse** that check from `check`, and will still unbind non-bridge devices in the subtree and remove the root port — that is a defect, see below |
| Surface area | Single GPU, one-shot install/uninstall, focused on "install it and play" | Seven subcommands `status` / `gpu` / `check` / `plan` / `rehearse` / `apply` / `restore`, plus rehearsal, rollback, dual-GPU, batch and a watchdog |
| Multi-GPU | Not addressed | Dual GPUs on independent root ports; batch script |

> The "shared root port" row should be read in three parts rather than as a single ranking:
> - **Its refusal policy** is the most conservative on an unfamiliar board; the cost is that it
>   cannot be used at all when the root port is shared;
> - **This project's batch script** has the finest granularity of the three — it does not refuse,
>   it narrows the scope of `remove` to the highest level where "only our own devices remain", so
>   the risk of crossing the boundary is zero;
> - **This project's single-GPU script** is the weakest of the three — `check` can already
>   identify "non-card device under the root port" and reports `ERROR`, but `apply` never wired
>   that judgement in. Logged as **P1** in [`NEXT.md`](NEXT.md) (Chinese); the fix is to make the
>   single-GPU script reuse the batch script's anchor logic.

### 2.5 Why this route is still necessary today

| Fact | Source |
|---|---|
| The quirk for `0xe2ff` (the B580's on-card bridge) has not reached mainline | The `[PATCH 1/2]` author calls it *"this feels quite hacky to me"*; it is a stopgap, and third-party reports say it is still under review |
| On this machine, kernel `7.0.0-38-generic` + `pci=realloc`, BAR2 is still 512 MB at boot | This repo's README "Key finding", and `NEXT.md` |
| The kernel's `pci_resize_resource()` only looks for space inside the existing bridge window | The xe driver's two `-ENOSPC` failures in the measured logs |

Conclusion: **until Intel's quirk reaches mainline, or "the resource allocator considers the
maximum ReBAR size" ships, "manual removal + rescan" remains the only approach that does not
require flashing firmware.**

## 3. Kernel-side basis

This tool does three things — read an extended capability, change the BAR size, make the kernel
re-enumerate — and each has a kernel implementation behind it.

### 3.1 Walking the extended capability chain

`pci_find_ext_capability()` in `drivers/pci/pci.c`. The kernel searches for a capability by
starting at `0x100` and following the header's next pointer hop by hop. This project uses the same
logic, which is why **`0x420` is never hard-coded** — it still works with a different card or a
different chip generation.

### 3.2 Letting the kernel reallocate resources: `pci=realloc`

| Contributor | Commit | Content |
|---|---|---|
| **Ram Pai** (IBM) | 2011-06-30, `[PATCH] PCI: conditional resource-reallocation through kernel parameter pci=realloc` | Introduces `pci=realloc`, allowing the kernel to reallocate PCI resources when the BIOS allocation is insufficient |
| **Yinghai Lu** | 2012-02-01, `[PATCH 5/7] PCI: Make pci bridge reallocating enabled/disabled` | Splits it into `pci=realloc=on` / `pci=realloc=off` |

Discussion archive: <https://lore.kernel.org/linux-pci/1328136170-17613-6-git-send-email-yinghai@kernel.org/>

The background is worth knowing: dynamic reallocation kept causing regressions at the time, so
Ram Pai's patch was effectively a compromise — **off by default, on only if you ask**. That is
why many machines only behave once `pci=realloc` is written explicitly. This project's target
machine (`/proc/cmdline` contains `pci=realloc`, kernel `7.0.0-38-generic`) is one where it has
been explicitly enabled.

### 3.3 Why the kernel's own "in-place resize" is not enough

The kernel does have `pci_resize_resource()`, but it **only looks for space inside the existing
bridge window** and never enlarges the upstream bridge window. The measured error is exactly this:

```
xe: BAR 2 [mem size 0x400000000 64bit pref]: can't assign; no space
xe: Failed to resize BAR2 to 16384MiB (-ENOSPC). Consider enabling 'Resizable BAR' support in your BIOS
```

> A widely repeated claim deserves correcting: ReBarUEFI's FAQ states that newer Linux will resize
> and allocate the GPU BAR automatically. **On this project's target machine that did not
> happen** — kernel 7.0 with `pci=realloc`, BAR2 is still 512 MB at boot, and the xe driver tried
> twice and failed both times. The reason is that the root port prefetch window is only 520 MB,
> and `pci_resize_resource()` will not touch it. **This is precisely why this project exists.**

This project takes a different path: write the Control register first to fix the size field, then
remove the bridge and rescan, letting `pbus_reassign_bridge_resources()` (`drivers/pci/setup-bus.c`)
reflow and **expand** the bridge window. Measured: root port window 520 MB → 16392 MB, BAR2
512 MB → 16384 MB.

### 3.4 Remove and rescan: the sysfs interfaces

Per `Documentation/ABI/testing/sysfs-bus-pci`:

| Interface | Introduced | Official description |
|---|---|---|
| `/sys/bus/pci/devices/.../remove` | 2009-01 | Writing a non-zero value hot-removes that PCI device **and all of its children** |
| `/sys/bus/pci/devices/.../rescan` | 2009-01 (**introduced by Alex Chiang**) | Writing a non-zero value forces a rescan of the device's parent bus and all child buses, rediscovering previously removed devices |
| `/sys/bus/pci/devices/.../pci_bus/.../rescan` | 2011-05 | Same, scoped to that bus and its children |

That phrase "and all of its children" is the starting point for every safety design in this
project: **which device you remove determines the scope of the risk**. So the tool does not
operate on a fixed BDF — it first probes for an anchor whose "subtree contains only our own
devices", and only then touches it (see README, "Why multi-GPU needs anchor grouping").

## 4. Intel's official position on Arc + ReBAR

| Source | Key wording |
|---|---|
| [Intel support article 000091128, "Intel® Arc™ Graphics — Desktop Quick Start Guide"](https://www.intel.com/content/www/cn/zh/support/articles/000091128/graphics/intel-arc-dedicated-graphics-family.html) | "**Resizable BAR or Smart Access Memory must be enabled** to achieve the best performance with Intel Arc A-series graphics across all applications." |
| Intel Community (Robert Q., 2022-11-25) | Arc graphics **can** work on systems without ReBAR… but performance is significantly affected. |
| Intel Gaming, "Resizable BAR on Intel Arc Graphics" | ReBAR makes transactions from the CPU to VRAM larger; without it the memory controller is flooded by many small transactions |

The latter two are more precise than the first: **Arc does not fail to display, it loses
performance.** The SYCL/oneAPI path is stricter still — what it needs is not bandwidth but a
**mappable window** — allocation sizes are the same order of magnitude as the model footprint
(4B Q8_0 about 4 GB, 9B Q6_K about 7 GB as measured in this repo), and a 512 MB window cannot
hold even the smallest of those, so allocation fails outright (presenting as SIGBUS). That is the
line between "the window must be expanded" and "expanding makes it faster".

## 5. Peer projects: what we did, what others did

| Project | Layer | Relationship to this project |
|---|---|---|
| **[xCuri0/ReBarUEFI](https://github.com/xCuri0/ReBarUEFI)** (MIT) | **Firmware layer** (UEFI DXE driver) | Replaces `PreprocessController` in `PciHostBridgeResourceAllocationProtocol` so the BAR is already large **at every boot-time enumeration**. Suits people who want a permanent fix and are willing to flash firmware. This project sits at the **OS layer** (runtime change + rescan), touches no firmware and can be reverted at any time — complementary, not a replacement |
| **ReBarState** (in the same repo) | User-space configuration tool | Sets the BAR size ReBarUEFI should use and writes it to an NVRAM variable. Same goal as this project's `apply --size N`, but the target is firmware rather than a running kernel |
| **NvStrapsReBar** | Firmware layer (NVIDIA Turing) | The NVIDIA equivalent of the same idea; not addressed here |
| **[RodBurlamaqui/Intel-ARC-Rebar](https://github.com/RodBurlamaqui/Intel-ARC-Rebar)** (`arc-rebar`, not open source) | **OS layer** (initramfs stage) | The closest in layer: also leaves firmware alone, also writes the register and does remove/rescan. Differences are **when it takes effect** (early boot vs. runtime) and **persistence** (it installs a hook that runs every boot; we write no persistent configuration). See section 2.3 |
| **[Emvo10/Intel-Arc-B580-ReBar](https://github.com/Emvo10/Intel-Arc-B580-ReBar)** (no licence) | **OS layer** (systemd boot service) | **Same card (B580 `8086:e20b`), same actions, about 7 weeks earlier** — the nearest neighbour to this project. Differences are the use case (desktop gaming vs. headless inference), shared-root-port policy (it refuses; we unbind and continue) and surface area. See section 2.4 |
| **[pciutils](https://github.com/pciutils/pciutils)** | User-space tool | This project relies on its `setpci` for configuration-space access and `lspci` for link status. Without it this tool could not exist |

**Special thanks to four people (in baton order; the fourth runs alongside this project on the
same card):**

1. **andersevenrud** — the first to publish the route "write the ReBAR register + remove the root
   port + rescan" (the H11SSL-i + B580 gist). Without that step, this project would have no
   starting point.
2. **Ilpo Järvinen and Lucas De Marchi (Intel)** — they explained from the kernel side why the
   whole card must be removed (the on-card bridge's BAR0 pins the root port window), and added the
   `was not released` diagnostic to the kernel. **Ilpo Järvinen also wrote out the manual
   workaround explicitly**, and this project's technical route follows that sentence.
3. **xCuri0** — ReBarUEFI punched through the assumption that "the vendor says the BIOS does not
   support it, so the silicon cannot do it", and its README states *"even required for Intel Arc
   GPUs to function optimally"* — one of the most important corroborations when this project was
   being scoped.
4. **Emvo10** — on **the same B580, with the same `setpci` + remove/rescan actions**, he turned it
   into an installable systemd service about 7 weeks before this project. We did not know that
   repository existed when the work started; checking afterwards, two independent routes had
   converged on the same set of actions. That convergence is itself the strongest corroboration
   that the route is right — and "someone got there first" is worth recording against a name.

> **Independent implementation statement**: this project copied no code from any project listed
> above; the record of exposure is in [`CLEANROOM.md`](CLEANROOM.md). Credit here is for **ideas
> and methods**, not for code provenance. Methods as such are not protected by copyright (see
> `CLEANROOM.md` §5), but whoever first put a method into words deserves to be named.

## 6. Inference and measurement (what the benchmarks depend on)

| Project | Purpose |
|---|---|
| [llama.cpp](https://github.com/ggml-org/llama.cpp) (ggml) | `llama-bench`, plus the SYCL / Vulkan backends. Every script under `bench/` relies on it |
| [Intel oneAPI DPC++](https://github.com/intel/llvm) + [Level Zero](https://github.com/oneapi-src/level-zero) + [UMF](https://github.com/oneapi-src/unified-memory-framework) | SYCL runtime. A missing `libumf.so.1` makes the L0 adapter disappear silently; that trap is recorded in `NEXT.md` |
| [Mesa](https://gitlab.freedesktop.org/mesa/mesa) | The Intel Vulkan driver (ANV). All Vulkan comparison data comes from it |
| A community-maintained ollama SYCL build | Used only to verify the fact that "the official ollama binaries contain no SYCL". Factual reference only; no code used |

## 7. Independent review before publication

Before publication this repository went through two mutually isolated static code reviews. Each
round had **several independent seats reading the source only, without seeing each other's
conclusions**, and each was explicitly forbidden from reading the historical conclusions under
`docs/reviews/` — otherwise it degenerates into copying each other's homework.

### Round one (against v1.1.0; original reports archived)

| Seat | Model | Output |
|---|---|---|
| A | `hy4-preview` (Tencent Hunyuan) | [`hy4-preview.md`](docs/reviews/hy4-preview.md) (24 KB, 25 defects) |
| B | `glm-5.3-flash` (Zhipu) | [`glm-5.3-flash.md`](docs/reviews/glm-5.3-flash.md) (17 KB, 9 redundancies + defects) |
| C | `space-bunny` (MiniMax M3.1 Flash anonymous preview) | **No output** — upstream link returned 502, no conclusion |

That round surfaced 5 high-severity defects confirmed on inspection (false idempotent success,
wrong rollback criterion, removing the bridge even after a failed unbind, empty-argument
enumeration sweeping the whole machine, a rollback default smaller than the original), and left
2 disputes **where two seats concluded the opposite** and hardware testing settled it.

### Round two (against the version after the topology probe layer was introduced; summary in [`round2-2026-10-28.md`](docs/reviews/round2-2026-10-28.md))

| Seat | Model | Output |
|---|---|---|
| A | `hy4-preview` | Conclusions merged into the summary |
| B | `mimo-v2.6-pro` (Xiaomi) | Conclusions merged into the summary |
| C | `glm-5.3-flash` | Conclusions merged into the summary |

This round targeted the refactored version that removed hard-coded BDFs and ECAP offsets, focusing
on failure paths and the self-healing chain. The raw outputs of the three seats were not archived
verbatim, but **the conclusions, the cross-check results and the opinions not adopted** are all in
the summary — including the places where I judged a seat to have misread the code (for example,
"will damage other PCIe devices" is not actually a weakness of this code).

> Why archive the conclusions that were *not* adopted: the value of a review is not only the bugs
> it finds, but the record of "what objections existed at the time, and why they were rejected".
> A later maintainer can use that to overrule us.

## 8. Citation

This project is under the MIT licence. Use, modification and commercial use need no prior
permission — **keep the copyright and licence notice** (see [`LICENSE`](LICENSE)).

If you use it in an article, report or product, mentioning the repository URL is welcome — not a
licence requirement, just so the next person can find it. Likewise, if you improve the probe logic
or hit a new trap, issues and PRs are welcome; the credit will be in the commit history.
