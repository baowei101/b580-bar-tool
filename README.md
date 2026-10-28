# b580-bar-tool

**English** | [简体中文](README.zh-CN.md)

> **Chinese is this project's primary language.** The scripts print Chinese, the logs are in
> Chinese, and `docs/` is Chinese only. This English file is a translation of
> [`README.zh-CN.md`](README.zh-CN.md); where the two differ, the Chinese text governs.

Expand an Intel Arc GPU's PCIe BAR2 aperture to 16 GB on boards whose BIOS cannot give it
enough address space — at runtime, without flashing anything.

**The BIOS route was tried. It does not work.** The BIOS does expose a BAR size setting
(default 256 MB), but **the largest value the machine still boots with is 512 MB**.
Anything larger and the GPU fails to initialize: **the system hangs at POST**. That is the
dilemma — the sizes that boot are too small, the sizes that are big enough never boot.

This machine has no display output and no IPMI. A POST hang means you cannot see where it
stopped and cannot revert the setting remotely — someone has to walk over, cut power, and
clear CMOS. So this project bypasses the firmware instead: rewrite the ReBAR Control register
in PCI configuration space at runtime, then let the kernel reallocate the upstream bridge
window. Result: 16 GB, no BIOS change, no POST gamble.

> If your board has no BAR size option at all (some server boards), this still applies —
> the tool depends only on the GPU's ReBAR capability and the kernel's ability to
> re-enumerate, not on any BIOS setting.

Built from the **PCI-SIG Resizable BAR Capability ECN (ECAP ID `0x0015`, proposed 2008-01-22,
approved by the PWG 2008-04-24, merged into PCIe Base Spec 2.1 / 3.0)** and register values
measured on the target machine. No third-party project's code was copied.

Full provenance — specification source, kernel implementation, and prior work (PCI-SIG, the
Linux PCI subsystem, ReBarUEFI and others) — is itemised in **[`CREDITS.md`](CREDITS.md)**.

> **Redaction note**: host details in this repository's documentation have been replaced with
> placeholders — `<SERVER_IP>` for the target host, `<USER>` for the login account,
> `<REVIEW_HOST>` for the review machine. Replace them before copying any command. Account
> names inside the scripts are inferred at runtime (`GPU_USER` / `SUDO_USER`), so nothing is
> hard-coded.

---

## Current status (read this first)

| Item | Status |
|---|---|
| `status` / `gpu` / `check` / `plan` | Verified on hardware |
| `rehearse` (remove + rescan rehearsal, BAR untouched) | **Verified, 4 s, no hang** |
| `apply --size 10` (1 GB probe) | **Succeeded: bridge window 520 MB → 1032 MB, BAR2 = 1024 MB** |
| `apply --size 14` (the real 16 GB resize) | **Succeeded: BAR2 = 16384 MB** |
| BAR2 measured | **16 GB** @ `0x20000000000` (64-bit prefetchable), Control = `0x00000e22` |

> ⚠️ **That row is the state *after* an `apply`, not the boot default.**
> BAR2 is a **runtime** state: a reboot or power cycle puts it back to whatever the BIOS
> sets (512 MB on this machine, 256 MB from the factory), so you must run `apply` again.
> **Before inference, training, or anything that depends on a large BAR, check it first:**
>
> ```bash
> sudo ./b580-bar-tool.sh status --gpu <BDF>
> ```
>
> Two lines are all you need: the reported BAR2 size and the upstream bridge window.
> If they read 512 MB and 520 MB, the BAR is not expanded — stop looking downstream.
> (On 2026-10-28 the order was reversed on the target machine, and the hunt went into
> the inference engine's cross-GPU transfers first.)

### Key finding: full re-enumeration expands the bridge window; `xe`'s in-place resize cannot

This is the single most important fact behind the project — it is why it works at all:

```
# The xe driver tried on its own twice, at boot and during a 15:24 rehearsal. Both failed.
xe: BAR 2 [mem size 0x400000000 64bit pref]: can't assign; no space
xe: Failed to resize BAR2 to 16384MiB (-ENOSPC). Consider enabling 'Resizable BAR' support in your BIOS
```

`pci_resize_resource()` only looks for space **inside the existing bridge window**; it never
enlarges the root port window. This project writes the Control register first and then triggers
a full re-enumeration, which goes through `pbus_reassign_bridge_resources()` — that function
reflows and expands bridge windows. Measured in three steps:

| Stage | Root port prefetch window | BAR2 | CPU-accessible VRAM |
|---|---|---|---|
| Initial | 520 MB | 512 MB | 1 GB (`Small BAR device`) |
| `--size 10` | **1032 MB** | 1024 MB | 1 GB (`Small BAR device`) |
| `--size 14` | **16392 MB** | **16384 MB** | **11.9 GB `0x2fb800000`** (no `Small BAR`) |

> "Initial" above is **the BIOS set to 512 MB — the largest value that still boots**. Factory
> default is 256 MB, in which case BAR2 is 256 MB and the root port window correspondingly
> smaller; the tool jumps from there to 16 GB just the same, because the starting value does
> not affect the target it writes (see "Porting to another board").
> Note also that 520 MB is only 8 MB more than the BIOS's 512 MB — the firmware plans the
> upstream bridge window on the assumption that 512 MB is the ceiling, and never reserved room
> for a larger BAR.

> Why the intermediate `--size 10` mattered: the 1 GB it requests exceeds the 520 MB window at
> the time, so **it can only succeed if the window actually expands**. That makes it a precise
> probe of the mechanism. Once it works, going to 16 GB has a basis.

> A contrast that shows which layer is the obstacle: for the same 1 GB step, expanding at
> runtime works, while setting it in the BIOS hangs at POST (see
> [`docs/environment.md`](docs/environment.md), Chinese). What is missing is not the GPU's
> hardware capability but the firmware's ability to plan bridge windows during POST — exactly
> why this project moved the operation to after the system is up.

**Do not assume the BAR size persists.** It is runtime state. After a power cycle the
configuration space is reset by the BIOS and BAR2 returns to 512 MB; `apply` must be re-run.
The scripts write no persistent configuration.

---

## Target machine (`<SERVER_IP>`)

> This table lists only what matters for BAR resizing. The complete hardware and software
> inventory — board model, BIOS version, CPU/RAM, kernel and driver versions, Vulkan ICD,
> benchmark toolchain — is in [`docs/environment.md`](docs/environment.md) (Chinese).

| Item | Value |
|---|---|
| GPU | `0000:04:00.0` Intel Arc B580 (Battlemage G21) |
| Root port | `0000:00:02.0` (C610 / Wellsburg, X99) |
| Topology | `00:02.0` → `02:00.0` (switch upstream) → `03:01.0`→GPU / `03:02.0`→HDMI audio |
| Driver | `xe` (kernel 7.0.0-38) + `snd_hda_intel` |
| ReBAR ECAP | offset `0x420` |
| Capability | `0x0007f000` → supports N=8..14 → 256 MB … 16 GB |
| Control | `0x00000922` → BAR index 2, size field 9 = **512 MB** |
| Target Control | `0x00000e22` → size field 14 = **16 GB** |
| Kernel parameter | `pci=realloc` present |
| Display output | Fully headless, all 7 outputs disconnected |

`Control` bit layout (as defined by the PCI-SIG specification):

```
bits[2:0]   BAR Index (must be preserved; 2 on this machine)
bits[13:8]  BAR Size (N, actual bytes = 2^(N+20))
```

Resizing is just: `new = (old & ~0x3F00) | (N << 8)`.

---

## Scope: manual by design

This is a **manual tool**. Nothing is installed, no service is enabled, nothing is written that
survives a reboot — you run `b580-bar-tool.sh apply` when you want the resize, and it lasts until
the next power cycle. That is the intended usage, not a missing feature.

`tools/` is an **experiment log**. The topology probe, the batch path, the start/stop helpers and
the two systemd units are what *this* machine happened to need while the route was being worked
out. They are published because they are the evidence, not because they are a supported installer.
Read them, take the parts that apply to your board, ignore the rest.

### If you want it applied automatically at boot

It can be done, but it needs one change **outside this repository**, and this is the part worth
being precise about. `preflight()` gates everything on a single line:

```bash
grep -qw 'pci=realloc' /proc/cmdline    # b580-bar-tool.sh — the gate
```

So "automatic" first means: edit GRUB (`GRUB_CMDLINE_LINUX_DEFAULT`), add `pci=realloc`, run
`update-grub`, reboot — i.e. exactly the persistent change this tool exists to avoid. Deleting
the `grep` does not help either: the bridge window only grows because the kernel reallocates
resources during rescan, and without `pci=realloc` it will not, no matter what the script believes.

The two units under `tools/` (`b580-rebar.service`, `b580-rebar-late.service`) ran on the author's
machine only. They are shipped as reference; treat them as a starting point for your own unit,
not as a supported installer.

---

## Usage

```bash
sudo ./b580-bar-tool.sh status      # read-only: registers and current window
sudo ./b580-bar-tool.sh gpu         # read-only: identity of every display device (required on multi-GPU)
sudo ./b580-bar-tool.sh check       # read-only: verify every precondition for apply
sudo ./b580-bar-tool.sh plan        # dry run: print the full execution plan
sudo ./b580-bar-tool.sh rehearse    # rehearsal: remove+rescan only, Control untouched
sudo ./b580-bar-tool.sh apply       # actually run (asks for YES)
sudo ./b580-bar-tool.sh rollback    # restore Control to the value recorded before apply
```

`--size <N>` sets the target N (defaults to the card's maximum, 14); `--yes` skips the
interactive confirmation; `--gpu <BDF>` selects the device explicitly.

### Multi-GPU safety

`class 0x030000` only says "this is a display device" — **it cannot tell you which card**.
Therefore:

- Identity is validated by `vendor:device`, default `8086:e20b` (Battlemage G21 / Arc B580).
  Use `TOPO_DEV_IDS="8086:xxxx"` for other models (space-separated list supported).
- With **two or more** ReBAR-capable display devices the tool **refuses to auto-select**;
  it lists each identity and requires `--gpu`.
- An explicit `--gpu` is still validated; a non-B580 target needs `--allow-any-gpu`.
- On multi-GPU systems **run `tools/gpu-topology.sh --plan` first** — it prints the exact
  command each card needs.

Recommended order: `gpu-topology.sh --plan` → `gpu` → `status` → `check` → `plan` →
`rehearse` → `apply --size 10` (probe) → `apply --size 14`.

### Why multi-GPU needs anchor grouping

Expanding a BAR requires `remove`-ing a bridge device — and `remove` takes out its **entire
subtree**. To widen a given level's window you must remove that level; how far up you can go
depends on **whether the next level up contains anybody else's devices** (NVMe / NIC / RAID).
That cannot be hard-coded; it must be probed.

`tools/lib/topology.sh` walks up the sysfs parent chain from the GPU. As long as a level's
subtree contains nothing but the target card (its internal bridge and HDMI audio), it keeps
going; it stops at the highest such level and calls it the **safe anchor**. That usually equals
the root port, but the code makes no such assumption.

| Probe result | Meaning | What to run |
|---|---|---|
| Each card has its own anchor (`atomic`) | Independent | `apply --gpu <BDF>` per card |
| Several cards share one anchor (`batch`) | Windows are settled in the same rescan | `rebar-batch.sh`, whole group at once |

**Why you must not run them one at a time when the anchor is shared**: the second rescan needs
twice the window; if the kernel allocation is unfavourable it can shrink the card already
expanded, while `apply` only validates its own target — so it reports "success" while the other
card was silently downgraded.

`tools/rebar-autofix.sh` picks the path automatically from the probe result; the boot-time
self-healing unit uses it.

---

## Porting to another board: a 256 MB starting point works just as well

A machine's initial BAR2 size is **not a precondition**. A stock BIOS usually gives **256 MB**;
a board with a modified BIOS may give 512 MB (this one does). Both reach 16 GB.

**Why the starting value does not matter**: the current size field is read for only two
reasons — the idempotency check (already ≥ target → exit) and logging. What gets written is an
**absolute target** `new = (old & ~0x3F00) | (N << 8)`, independent of the old value. With a
starting value of 8 (256 MB), 8 < 14, so it proceeds as usual.

**The three real preconditions** (unrelated to 256 vs 512):

| Precondition | Explanation | How to check |
|---|---|---|
| Capability bitmap includes N=14 | This is the **GPU's own** capability; the same B580 always reports `0x0007f000` (N=8..14), independent of the board | "card max" in `status` |
| `pci=realloc` on the kernel command line | Without it the kernel may not expand bridge windows during rescan; the script refuses with an ERROR | `cat /proc/cmdline` |
| ≥16 GB of free, 16 GB-aligned contiguous space in the root complex Above-4G window | The one most likely to become the real bottleneck. Here the parent window is `20000000000-2ffffffffff` (1 TB), base happens to be 16 GB-aligned | `sudo grep "PCI Bus 0000:00" /proc/iomem` |
| The chipset tolerates full re-enumeration | A few hang; recovery is a power cycle. Verify with `rehearse` first — it does not touch the BAR | `rehearse` |

**A 256 MB starting point actually gains more**: on a C602 platform (256 MB start) the author
measured bandwidth going from 15 → 392 GB/s; on this machine, starting at 512 MB, only the
512 MB → 16 GB step is gained.

**If 16 GB does not fit**: fall back to `--size 13` (8 GB), mapping the first 8 GB of the
12 GB of VRAM to the CPU — still far better than 256 MB; `dmesg` will show a correspondingly
smaller `CPU accessible size`.

---

## Bigger cards: change the exponent, nothing else — but it has not been tested

`--size` does not take megabytes. It takes an **exponent**: `bytes = 2^(N+20)`.

| N | Window | Where it shows up |
|---|---|---|
| 8 | 256 MB | Stock BIOS default |
| 9 | 512 MB | Board with a modified BIOS (this one) |
| 13 | 8 GB | Fallback when 16 GB will not fit 12 GB of VRAM |
| 14 | 16 GB | The B580's ECAP ceiling — **the largest this project has measured** |
| 15 | 32 GB | What a 24 GB-class card would ask for — **untested** |

Most of the time you do not have to supply the number at all. **The ceiling is not hardcoded
to 16 GB** — it is read from the card's own Capability bitmap (`max_supported_n()` in the
script), and `target_n` defaults to it. Point the tool at a card whose ECAP advertises
N=15 and it will go for 32 GB without a code change.

Two things do need attention, and neither is the size itself:

1. **Identity check.** `EXPECT_ID_DEFAULT="8086:e20b"` is the B580's `vendor:device`. For any
   other model, either pass `--allow-any-gpu` or change that constant — preferring the latter,
   since `--allow-any-gpu` removes the "don't touch the wrong card" guard entirely.
2. **The root complex needs that much free, aligned space.** 32 GB contiguous **and**
   32 GB-aligned is a much bigger ask than 16 GB. This is the most likely failure: allocation
   gets downgraded, the script sees `BAR2 != expected` and rolls back.

**What has not been verified, stated plainly**: the author only has a B580 (12 GB VRAM, ceiling
N=14). **There is no on-hardware data for N>14 at all.** The code path is the same logic and the
same formula, differing by one constant — but "it follows" is not "it ran". Likely failure modes,
in rough order:

- Bridge window allocation fails (the kernel cannot find a large enough contiguous region) →
  `BAR2 != expected` → rollback. A safe failure;
- The card advertises a higher step but its firmware rejects the write → the field takes the new
  value while BAR2 does not, and `status` shows the contradiction (`plan`/`apply` check both the
  field and the real size for exactly this reason);
- Chipset tolerance: the root-port re-enumeration itself is unchanged, so the risk should be on
  par with 16 GB — but it is unverified.

That is why the script prints a `WARN` when a card reports N>14 — visible at `plan` time, not
after the fact.

> **Waiting on you**: if you get a larger card working (or break it), open an issue with the
> output of `status`, the card model, and `gpu-topology.sh`. The N>14 rows above are formula,
> not measurement.

---

## Before you run: stop the GPU services

**Removing the root port while the GPU has DMA in flight is the most likely way to hang the
machine.** Stop the services first:

```bash
sudo -v                      # cache sudo credentials first (the scripts take no password argument)
./tools/stop-gpu.sh --dry-run   # see what it would stop, without stopping anything
./tools/stop-gpu.sh
```

It carries no list of service names — it asks who is holding the device *right now*:

```
fuser /dev/dri/renderD*     →  PID
/proc/<pid>/cgroup          →  0::/system.slice/paddleocr-vl-8094.service
basename                    →  paddleocr-vl-8094.service
```

Whatever comes back gets stopped, and the unit names are written to
`/run/b580-bar-tool/stopped-units` so that `start-gpu.sh` restores exactly those and nothing
else. Processes that belong to no unit (a login session, something started by hand) are reported
for you to handle — the script does not guess.

Why a lookup and not a list: on the author's machine nine services make up the inference stack,
but **only three were actually holding the GPU** when measured on 2026-10-28. A hard-coded list
stops all nine — including six that were idle — and silently misses anything added later.

`check` uses the same `fuser` check and **refuses** `apply`/`rehearse` while anything still holds
a node.

| Port | Unit | Scope | Holding the GPU? |
|---|---|---|---|
| 8094 | `paddleocr-vl-8094.service` | system | **yes** |
| 8092 | `llama-rerank.service` | user | **yes** |
| 8093 | `llama-asr.service` | user | **yes** |
| 8095 | `paddlex-8095.service` | system | no (CPU pipeline) |
| 8091 | `tei-rerank-gpu.service` | user | no |
| — | `ollama.service` | system | no |
| — | `model-watch.service` / `model-watch-11434.service` / `headroom-proxy.service` | user | no |

> This table is what the lookup resolved to on this machine — an observation, not configuration.
> On yours it will differ, and that is fine: the only requirement is "nothing is using the GPU".

---

## Risk and rollback

**Risk**: if the chipset does not tolerate re-enumeration, rescanning after removing the root
port can hang the kernel.

**Measured**: this C610 tolerates it; the rehearsal completes in 4 seconds.

**Safety net**: `tools/wd-enable.sh` enables the systemd runtime watchdog (the PCH's `iTCO_wdt`
hardware TCO timer, 60 s). A hung kernel is reset by hardware — no trip to the machine room
needed.

```bash
sudo ./tools/wd-enable.sh              # enable
# revert: comment RuntimeWatchdogSec back out in /etc/systemd/system.conf, then systemctl daemon-reexec
```

**Nothing persistent is written**: no BIOS, firmware, GRUB or initramfs changes. After a power
cycle the configuration space is reset by the BIOS, BAR2 returns to 512 MB, and the system boots
normally.

---

### What else changes besides BAR2

Two side effects, both measured. Neither is caused by this tool, but both bite the tools around
it:

| Effect | Detail |
|---|---|
| **DRM node numbers shift** | After `rescan`, `renderD128` / `renderD129` become `renderD129` / `renderD130` (measured). Services reopen the new node when restarted and are unaffected — but anything that **cached a node number** now points at the wrong device. Glob `/dev/dri/renderD*`, or resolve the BDF via `/sys/class/drm/*/device` |
| **`rollback` is not a no-op** | As long as `/var/lib/b580-bar-tool.state` from the last `apply` is present, `rollback` really writes that value back (measured: `16384MB → 512MB`). To do nothing, look at `status` first — do not count on an error message as your protection |

---

### Known risks and the decision taken

A security audit (`docs/security-review.md`, Chinese) flagged two high-risk combinations.
The decisions:

| Risk | Decision | Rationale |
|---|---|---|
| The boot unit runs scripts under `/opt` as **root**, while that directory is owned by the operator account (writable) | **Accepted; ownership not tightened** | Isolated network segment + single-operator dedicated machine + all script changes tracked in git. Full reasoning and compensating controls in `docs/security-review.md` **RA-01** |
| The privilege path is `docker --privileged --pid=host` + `nsenter -t 1` | **Retained** | The only means when the target has no passwordless sudo. Always run by hand; never written into cron / systemd / CI |

Acceptance holds only while all three are true: **isolated network**, **single-operator
dedicated machine**, **script changes go through git**. If any one stops holding (an untrusted
terminal is attached / a new login account is added / `/opt` starts being written by
automation), re-evaluate immediately and tighten:

```bash
chown -R root:root /opt/b580-bar-tool && chmod -R go-w /opt/b580-bar-tool
```

---

## Deployment: both layouts work

Nothing to install. Either use it straight from a `git clone`, or flatten `tools/` into a fixed
directory (e.g. `/opt/b580-bar-tool/`) and keep it there. The scripts recognise both:

| Layout | Structure | When to use |
|---|---|---|
| **Repo layout** | `b580-bar-tool.sh` at the root, helpers under `tools/` | straight from a clone |
| **Deployed (flat)** | contents of `tools/` copied into one directory, alongside the main script | long-lived install on one machine, invoked by absolute path |

Path resolution lives in `find_tool()` (top of `tools/apply-bar-root.sh` and friends): it tries
both layouts, so running from a clone and running from a flat directory both work — and neither
fails silently with "can't find the main script".

> ⚠️ **The one real risk of a flat deployment is running stale code.** Flattening is a *copy*,
> not a link, so repo updates never propagate; and a flat directory carries no version marker,
> so you cannot tell at a glance which revision it is.
>
> That bit us on 2026-10-28: `/opt` was **41 commits behind**, its `stop-gpu.sh` was still the
> old hard-coded unit-list implementation, two services were left running, and no stopped-units
> record was written — so `start-gpu.sh` had nothing to restore from.
>
> Stamp the revision after every sync, and check it first when troubleshooting:
>
> ```bash
> git -C <repo-path> describe --always --dirty > /opt/b580-bar-tool/VERSION
> ```
>
> The main script also logs `v$VER` on its first line — if the two disagree, it is stale.

---

## Repository layout

```
b580-bar-tool.sh          Main script (single file, no external deps; ECAP offset found by walking the chain)
tools/lib/topology.sh     Probe layer: enumerate / locate ECAP / ancestor chain / safe anchor / grouping / plan
tools/gpu-topology.sh     Topology report (--plan gives the verdict, --env gives variables; read-only)
tools/rebar-batch.sh      Resize BAR2 per anchor group (write all Controls first, then one rescan)
tools/rebar-autofix.sh    Probe → route → hand off to one of the above (used by systemd)
tools/lib/gpu-services.sh Reverse lookup: device → PID → cgroup → unit (no service names in the code)
tools/stop-gpu.sh         Stop whatever holds a renderD node, record the units, wait until nodes are free
tools/start-gpu.sh        Restore exactly the recorded units, then verify
tools/stop-gpu-root.sh    Same, for root / nsenter contexts (needs GPU_USER=<user>)
tools/start-gpu-root.sh   Same, for root / nsenter contexts
tools/wd-enable.sh        Enable the hardware watchdog
tools/check-i18n.sh       Bilingual consistency check (compares structure of each doc pair; read-only)
bench/run-bench.sh        llama-bench wrapper (default Qwen3.5-9B Q6_K), measures pp / tg
bench/fa-matrix.sh        FlashAttention on/off matrix, Qwen3 4B and Qwen3.5 9B
bench/reports/            Measurements: dual-GPU SYCL vs Vulkan, 9B pp4096 single-GPU
docs/GLOSSARY.md          Chinese↔English terminology (the authoritative word list for both versions)
docs/environment.md       Measured environment: board/BIOS/CPU/kernel/driver/Mesa/benchmark toolchain
docs/reviews/             Independent review archive (three reports + adjudication index)
docs/case-*.md            Case studies on specific machines (topology, logs, conclusions); not general premises
docs/rebar-task.md        Technical brief used to dispatch the candidate implementations
README.zh-CN.md           Chinese README        ┐
DISCLAIMER.zh-CN.md       Chinese disclaimer    │ these four are the bilingual pairs;
CREDITS.zh-CN.md          Chinese credits       │ Chinese is primary; English is the translation
CLEANROOM.zh-CN.md        Chinese clean room    ┘
DISCLAIMER.md             Warranty, failure modes, trademark, AI involvement, validation limits (read first)
CREDITS.md                Specification source, originators of the method, kernel-side basis, peer projects
CLEANROOM.md              Independent-implementation statement and disclosure of exposure
NEXT.md                   Known-unfixed items and TODOs (nothing is hidden; Chinese)
archive/                  Three candidate implementations from free models — kept as review evidence, all unusable
```

> **The probe layer is the only source of truth for "what this machine looks like".** Nothing
> above it may hard-code a BDF, slot, ECAP offset or `renderD` number — all of those change
> across boards, slots and BIOS versions, and a hard-coded value fails *silently* (the condition
> simply does not match and the log says nothing).

Restore services after resizing:

```bash
sudo -v
./tools/start-gpu.sh                        # restore the recorded units + verify + print current BAR2
```

> Scripts under `archive/` keep their **original form** — their names and log paths still say
> `rebar-b580` (the project was renamed on 2026-10-27). Archive files are deliberately not
> edited, so the review evidence stays authentic.

### Documentation languages

**Chinese is the primary language.** The author writes Chinese natively: the scripts, the logs,
everything under `docs/`, and the original of every document here are Chinese. Four documents —
`README`, `DISCLAIMER`, `CREDITS`, `CLEANROOM` — also have an English translation for
international readers. Where a pair disagrees, the Chinese file governs.

**Script output is Chinese-only, deliberately.** There is no `--lang` switch and no message
catalogue: with two languages every message would exist twice, and one copy always rots. Nor is
it needed — what you act on is not prose but the level prefix (`ERROR` / `WARN` / `INFO` / `OK`),
the step number, and the values printed (BDF, register value, MB). A message you cannot read is
still actionable: the prefix says whether to stop, `/var/log/b580-bar-tool.steps` says where it
stopped, and the rest is numbers.

Why not translate all of it: a translation nobody maintains is worse than none — it goes stale and
misleads readers. These four are the whole decision chain ("is it trustworthy → is it safe → was
anything copied → how do I use it"). `docs/` is the second layer, opened only when you want to go
deeper, and its audience is essentially the author.

Two sections exist only in this file, by design: *Chinese-only pages* (an index of the Chinese
pages, which a Chinese reader does not need) and *Reproducing the throughput numbers*. Their
absence from the Chinese file is not a missing translation.

Two guards keep each pair from drifting apart:

- **[`docs/GLOSSARY.md`](docs/GLOSSARY.md)** fixes one translation per term *before* translating
  (BAR2 **aperture** vs bridge **window**; **`remove`**, not "unplug"; **`rehearsal`**, not
  "dry run");
- **`tools/check-i18n.sh`** compares the structure of each pair — heading counts and code-fence
  counts — and reports mismatches. It deliberately does not diff the text: Chinese and English can
  never be line-aligned, so a full diff is pure noise. Run it after editing either side of a pair:

```bash
./tools/check-i18n.sh
```

### Chinese-only pages, one line each

Everything under `docs/` is Chinese-only, and so is `NEXT.md` at the root. Here is what each page
covers, so you can judge whether you need it:

| File | What it covers |
|---|---|
| `docs/environment.md` | The machine behind every number in this repo: Supermicro X10DAL-i, BIOS 3.2 (2019), 2× Xeon E5-2673 v3, 157 GiB RAM, Ubuntu 24.04.5, kernel 7.0.0-38 + `pci=realloc`, pciutils 1:3.10.0, system Mesa 25.2.8 while the effective Vulkan ICD is **26.3.0-rc1**, llama.cpp **b11925**. Also separates "must satisfy" from "free to differ" |
| `docs/dual-gpu-checklist.md` | Dual-B580 checklist: topology, separate root ports, four fallback routes and what to run in which order |
| `docs/case-dual-b580-separate-root-ports.md` | Case study: two B580s on independent root ports — full logs, symmetry and parallel-efficiency measurements |
| `docs/bench-sycl-vs-vulkan.md` | Single-GPU SYCL vs Vulkan benchmark, per-model tables, and why a 512 MB window leaves only Vulkan usable |
| `docs/security-review.md` | Security audit of the scripts: file operations, outbound access, privilege paths, item RA-01 |
| `docs/rebar-task.md` | The brief used to dispatch three candidate implementations — specification and measurements only, no implementation steps |
| `docs/reviews/` | Two rounds of three-reviewer independent review, including the points where we disagreed |
| `bench/reports/*.md` | Raw measurement reports (dual-GPU SYCL vs Vulkan, per-backend pp4096) |
| `NEXT.md` | Known-unfixed list with priorities and the measured pitfall log — the honest counterpart to the status table above. Chinese only: it is the author's handover notes, roughly half of it is this machine's own state, so there is no useful English version. The parts a reader is likely to get bitten by (DRM renumbering, `rollback` not being a no-op) are promoted into *Risk and rollback* above |

### Reproducing the throughput numbers

Three components decide whether you can reproduce `bench/reports/`:

| Component | Version used | Why it matters |
|---|---|---|
| Kernel | `7.0.0-38-generic` with `pci=realloc` | Without `realloc` the window never expands and there is nothing to measure |
| Vulkan ICD | **Mesa 26.3.0-rc1** via `/etc/vulkan/icd.d/10-intel-26.3.json` | The distro package is 25.2.8. **The ~1156 t/s prefill figure only holds on 26.3.0-rc1**; the stock package gives different numbers |
| llama.cpp | **b11925** (`fae9ac561`, 0.7.0-dev); `vulkan-x64` and `sycl-fp16-x64` from the same build | SYCL and Vulkan figures are only comparable when both come from the same build |

Full inventory — including which conditions are mandatory and which may differ:
[`docs/environment.md`](docs/environment.md) (Chinese).

### ⚠️ The candidate scripts in `archive/` have fatal defects — do not use them

| File | Defect |
|---|---|
| `cand-hy3.sh` | Reads Capability with `.W` (16-bit), discards the high half, concludes the card tops out at 2 GB, and **refuses to run on that false basis** |
| `cand-minimax.sh` | Uses `setpci ... .d` — **not a valid width** (only `.b` / `.w` / `.l` exist), so the register cannot be read or written at all; it exits immediately |
| `baseline.sh` | Predecessor of the main script, kept for history |

They are retained to document the main script's independence and the review process — not as
usable code.

---

## Pitfalls in writing this kind of script (measured on this machine)

1. `seq 0x100 4 0xFFC` — GNU seq **does not accept hexadecimal arguments**; an ECAP scan
   silently does nothing.
2. `[ $x -eq 0x0015 ]` — `test` integer comparison **does not accept hex literals** (it prints
   `integer expression expected` and is always false). Use `(( ))` arithmetic context instead.
   **This was violated twice.** The second time was when ECAP detection was changed from
   "guess a fixed offset" to "walk the capability chain": the comparison became
   `[ "$capid" -eq "$ECAP_ID_REBAR" ]`, so detection always failed and the script reported
   "no display device with ReBAR found" — re-check every comparison when porting old code.
3. `setpci` widths are only `.b` / `.w` / `.l`. **There is no `.d`.**
4. `/sys/.../resource2` returns **EIO** for reads on some kernels; read line 3 of `resource`
   instead.
5. Read Capability with `.l` to get all 32 bits; `.w` takes only the low 16 and misjudges the
   maximum size.
6. `lspci -n` fields are `BDF` / `class:` / `vendor:device` — **class is field 2 and carries a
   trailing colon**. Taking `$3` yields `vendor:device` (this once made `apply` reject a valid
   target *and* made the script try to unbind `pcieport`).
7. Unbind **leaf devices only** (`xe` / `snd_hda_intel`); leave `pcieport` bound and let the
   anchor's removal cascade through it.
8. **`GROUPS` is a bash reserved special variable** (the current user's group ID array; always
   `0` for root). Assignments like `GROUPS=()` / `GROUPS+=(...)` are taken over by bash and it
   always reads back `("0")`. This once made anchor grouping report "anchor 0, 0 cards in this
   group" — the array looked populated, all of it fake. Other dangerous names:
   `PIPESTATUS`, `RANDOM`, `SECONDS`, `LINENO`, `UID`, `PPID`. Prefix array names with a
   business term (now `ANCHOR_GROUPS`).
9. **When collecting multi-line output with `readarray` / `while read`, first confirm the
   command really emits multiple lines in that same context** (root, same namespace).
   `for x in "${arr[@]}"` does not complain when the array holds a single bogus element — it
   just quietly does less work.
10. The **GPU core's own link** may show `x1 / 2.5GT/s` in sysfs — that is the internal link
    from the on-card bridge to the die. The real slot link is on the **on-card bridge**
    (`current_link_width`). Do not use the core's value to decide you plugged into the wrong
    slot.

---

## Requirements

`bash`, `pciutils` (`setpci` / `lspci`), `psmisc` (`fuser`, only for `check`), root.

The kernel must support the ReBAR extended capability (mature from 6.12) and be booted with
`pci=realloc`.

Beyond that **nothing needs to be installed**: the repository is pure shell — no Python, no
Perl, no compile step, no `pip` or `apt` runtime.

---

## Provenance and credits

Every action this tool takes has a public source; the full citation list (links, dates, commit
IDs) is in [`CREDITS.md`](CREDITS.md). The six that matter most:

| Basis | Source | Used for |
|---|---|---|
| **The "remove + rescan" method** | **andersevenrud** first published it ([gist for H11SSL-i + B580](https://gist.github.com/andersevenrud/eec93e9151117bc0d6b6133b40eaffa5)); **Ilpo Järvinen** and **Lucas De Marchi** (Intel) explained from the kernel side why the whole card must be removed | **The core action of the entire workflow** — the technical route follows this |
| **Resizable BAR capability definition** | PCI-SIG **Resizable BAR Capability ECN** (proposed 2008-01-22 / approved by PWG 2008-04-24), merged into PCIe Base Spec 2.1 and 3.0, Extended Capability ID `0015h` | Writing the size field of the Control register |
| **Kernel resource reallocation** | `pci=realloc` — **Ram Pai** (IBM), 2011-06-30; split into `=on/=off` — **Yinghai Lu**, 2012-02-01 | Letting the kernel allocate to the new size instead of inheriting the BIOS layout |
| **Bridge window expansion** | `pbus_reassign_bridge_resources()` (`drivers/pci/setup-bus.c`) | Root port window 520 MB → 16392 MB |
| **Remove and rescan interfaces** | `Documentation/ABI/testing/sysfs-bus-pci`; `rescan` introduced by **Alex Chiang**, 2009-01 | `remove` + `rescan` triggering full re-enumeration |
| **A neighbour on the same card** | **[Emvo10/Intel-Arc-B580-ReBar](https://github.com/Emvo10/Intel-Arc-B580-ReBar)** — B580-only, systemd boot service, published 2026-09-05, **about 7 weeks earlier than this project** | Same card (`8086:e20b`), same `setpci` + remove/rescan actions. Two independent routes converging on one solution is the strongest evidence that the route is right; see [`CREDITS.md`](CREDITS.md) section 2.4 |
| **Prior art** | **[xCuri0/ReBarUEFI](https://github.com/xCuri0/ReBarUEFI)** (MIT, firmware-layer DXE driver); **[RodBurlamaqui/Intel-ARC-Rebar](https://github.com/RodBurlamaqui/Intel-ARC-Rebar)** (`arc-rebar`, initramfs stage, not open source) | ReBarUEFI showed that "the BIOS says no" ≠ "the silicon cannot"; `arc-rebar` sits at the same OS layer and predates us. Both are credited in [`CREDITS.md`](CREDITS.md) |

It also depends on [pciutils](https://github.com/pciutils/pciutils) (`setpci` / `lspci`) for
configuration-space access — without it this tool could not exist. The inference benchmarks
depend on [llama.cpp](https://github.com/ggml-org/llama.cpp), Intel oneAPI / Level Zero / UMF,
and Mesa.

## License

MIT, see [`LICENSE`](LICENSE). **Use, modification and commercial use need no prior
permission — keep the copyright and license notice** (that is all MIT requires). If you use it
in an article or a product, mentioning the repository URL is welcome but **not** a license
condition — it just helps the next person find it.

This is an independent implementation; the record of exposure to third-party code is in
[`CLEANROOM.md`](CLEANROOM.md), and provenance plus prior contributions are in
[`CREDITS.md`](CREDITS.md).

## Safety (read before you run anything)

This tool changes hardware state by **removing a PCIe bridge and rewriting BAR allocation**.
In rare cases (GPU DMA in flight, an unknown device inside the anchor subtree, the kernel
refusing to reallocate) it can **hang the system, recoverable only by a power cycle**. It is not
a vendor tool and has no official support:

- Validate first on a machine **you can power-cycle at will**; do not try it on a box with live
  workloads;
- Do **not** `enable` the self-healing unit by default — turn it on only after a manual
  success;
- Nothing persistent is written; a reboot returns to the BIOS's BAR setting (512 MB here,
  factory default 256 MB).

The full **failure-mode table, liability scope and unsuitable scenarios** are in
[`DISCLAIMER.md`](DISCLAIMER.md).

**AI involvement**: the code and documentation were produced with AI coding assistants; the
author made the design decisions, ran the on-hardware tests, and reviewed and rejected what
did not hold. All measurements come from real hardware. The division of labour, the mistakes
the AI made, and "what was verified vs. what was not" are stated plainly in
[`DISCLAIMER.md`](DISCLAIMER.md) — you deserve to know that before running it on your machine.

> **Not affiliated with Intel.** This is not an official Intel tool and is not authorised,
> certified or endorsed by Intel. Intel, Intel Arc, Battlemage and Xe are trademarks or
> registered trademarks of Intel Corporation. Product names such as `B580` are used
> nominatively, solely to state what the tool applies to.
