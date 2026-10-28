# Disclaimer, Trademark Notice, and AI Involvement

**English** | [简体中文](DISCLAIMER.zh-CN.md)

> **Chinese is this project's primary language** — scripts, logs and `docs/` are written in
> Chinese, and this English file is a translation. Where the two differ, the Chinese text governs.

> This is not boilerplate. This tool **really does change hardware state**. Read section 1
> before you run it. Section 3 states plainly how much of this project was produced by AI —
> if that matters to you, the information you need is there.

---

## 1. Disclaimer

### 1.1 Provided "AS IS", without warranty of any kind

This software is provided **"AS IS"**, without warranty of any kind, express or implied,
including but not limited to the warranties of **merchantability, fitness for a particular
purpose, and non-infringement**. The binding legal terms are in [`LICENSE`](LICENSE) (MIT).
This section restates them in plain language and does not alter their legal effect.

### 1.2 What it actually touches

| Action | Concrete effect |
|---|---|
| Writes PCI configuration space | Rewrites the GPU's ReBAR Control register (extended capability `0x0015`, offset `0x420` on this machine) |
| Removes a device from the running kernel | `echo 1 > .../remove` removes the **upstream root port and its entire subtree**, not just the GPU |
| Force-unbinds drivers | Unbinds every leaf device in the subtree, **potentially including NIC and storage controllers** depending on your topology |
| Triggers a full re-enumeration | `echo 1 > /sys/bus/pci/rescan`, letting the kernel reflow bridge windows and BARs at the new size |

### 1.3 Known failure modes

These are not hypothetical — they were measured or confirmed during review:

| Failure mode | Consequence | Recovery |
|---|---|---|
| Kernel hangs during `remove` | System frozen; fans spin, no response | Power cycle |
| Unbound the storage controller holding the root filesystem | Root filesystem unreachable, processes stall | Power cycle (data may be damaged) |
| Interrupted between `remove` and `rescan` by `SIGKILL` / OOM / power loss | The subtree disappears from sysfs | `echo 1 \| sudo tee /sys/bus/pci/rescan`, or reboot |
| Driver does not rebind after `rescan` | GPU unusable (`/dev/dri` missing) | Reboot, or `bind` manually |
| Operating on two cards at once | Unverified behaviour; they may interfere | One card at a time |

The tool ships with `check` (read-only self-test), `rehearse` (rehearsal, no register writes),
`rollback_to`, and interrupt trapping — **all of which reduce risk, none of which eliminate
it**. Boundaries are documented in [`NEXT.md`](NEXT.md) (Chinese).

### 1.4 Scope of liability

To the maximum extent permitted by law, the author and contributors are **not liable for any
direct, indirect, incidental, special or consequential damages**, including but not limited to
loss of data, damage to equipment, business interruption, loss of profits, or the cost of
replacement or repair. **You bear the entire risk of using this tool.** Whether to use it, and
on which machine, is entirely your judgement.

### 1.5 Scenarios where you should not use it

If any of the following applies, **do not use it** — or first make sure you can absorb the
worst case:

- A production machine with live workloads, online services, or training in progress;
- **No IPMI, no display output, and you are not physically on site** — if it hangs, nobody can
  rescue it;
- A single GPU that is also the only display output;
- A machine you do not own (rented, managed, or company property without permission);
- Laptops, all-in-ones, or systems with a locked BIOS and no recovery path;
- You cannot accept "the worst case requires walking over and cutting power".

> This project's target machine needs it precisely because it hits the combination
> "headless + no IPMI + BIOS hangs at POST when set larger" — which means its author **knew the
> cost and accepted it**. Whether your machine is in the same position is your call
> (see [`docs/environment.md`](docs/environment.md), section 1, Chinese).

---

## 2. No relationship with Intel whatsoever

- This project is an **independent third-party tool**. It is not official Intel software and is
  **not authorised, certified, sponsored or endorsed by Intel**;
- **Intel**, **Intel Arc**, **Battlemage** and **Xe** are trademarks or registered trademarks of
  Intel Corporation;
- Product names such as `B580` and `Arc` are used **nominatively**, solely to state what the
  tool applies to. They do not imply any affiliation or partnership;
- `PCIe`, `PCI-SIG`, `Resizable BAR` and similar names belong to their respective owners;
- All trademarks remain the property of their owners. This project claims no trademark rights.

Likewise, this project has **no affiliation** with Supermicro, Dell, Lenovo, Mesa, llama.cpp or
Intel oneAPI; those names appear only to describe the test environment or dependencies.

---

## 3. AI involvement (full disclosure)

### 3.1 Bottom line

**The code and documentation of this project were produced largely by AI coding assistants. The
author made the design decisions, ran the on-hardware tests, and reviewed and rejected what did
not hold.** Every measured number comes from a real run on real hardware — **not one was
invented by a model.**

This is stated prominently on purpose: you have the right to know who wrote the code in front of
you and how far its validation went, before deciding to run it on your machine.

### 3.2 Division of labour

| Stage | Done by |
|---|---|
| Choosing the technical route (runtime Control write + remove/rescan, no firmware flashing) | **The author** |
| Hardware setup, dual-GPU installation, trying every BIOS BAR setting (including the POST hang) | **The author** |
| Writing code (main bash script, batch script, systemd units, watchdog) | **AI-generated**; reviewed, edited and accepted/rejected by the author |
| Writing documentation (README, CREDITS, CLEANROOM, this file, `docs/`) | **AI-generated**; reviewed by the author, who corrected factual errors repeatedly |
| Designing commands and interpreting logs | AI proposed, **the author ran them and checked the output** |
| On-hardware validation (`rehearse`, `apply`, interrupt injection, dual-GPU benchmarks) | **The author performed them**; AI wrote the test steps |
| Unit tests (11 assertions on the trap logic) | **AI wrote and ran them**; the author confirmed the results |
| Independent review (two rounds, three reviewers each) | **Performed by other AI models**; the author decided what to adopt |
| Final release decision, licence choice, scope of credits | **The author** |

### 3.3 Mistakes the AI made (listed openly, unfiltered)

All of these were corrected. They are listed because they illustrate exactly **why AI-generated
code has to be verified by a human**:

| Mistake | How it was caught |
|---|---|
| Documentation claimed "the BIOS has no Resizable BAR option" | The author pointed out that it does — the largest value that boots is 512 MB |
| Documentation claimed "a 2019 BIOS predates ReBAR" | The author pointed out the ReBAR ECN was finalised in 2008; the claim was wrong in concept |
| Documentation claimed "BIOS POST takes 24 min 43 s" | The author pointed out that was a one-off observation, and mis-measured |
| Reverse-engineered "a 256 MB window is about 264 MB" from an 8 MB margin | Self-checked, found to have no measurement behind it, deleted (an inference is not a fact) |
| Cited a repository that does not exist, `rahulunair/ollama-sycl` | GitHub API returned 404; the link was removed |
| Cited a review report filename that does not exist | A directory listing caught it; replaced with the two real review rounds |
| Benchmark computed a bogus `BAR2 0MB` | `awk` does not parse `0x` prefixes; re-measured with bash arithmetic |
| Two "failures" in the first trap unit-test run | The test driver was at fault (`$(...)` runs a subshell, so variable changes did not propagate), not the code |

### 3.4 What this means for you

- The code **has been verified on hardware, but it has not been exhaustively tested**;
- AI-generated code may have defects on **a branch you hit** that neither the author nor the AI
  anticipated;
- Known-unfixed items are all public in [`NEXT.md`](NEXT.md) (Chinese) — **there are no hidden
  known problems**;
- Hence the recommended path: `check` → `rehearse` → single-GPU `apply` → dual-GPU only last.

---

## 4. How far validation actually went

Separating "what was verified" from "what was not" is more useful than claiming "thoroughly
tested".

### 4.1 What was verified

| Item | Content | Result |
|---|---|---|
| Syntax | Every `.sh` through `bash -n` | Passes |
| Unit tests | 6 groups / 11 assertions on the trap recovery logic (original code extracted verbatim, only the path prefix substituted) | 11/11 pass |
| On-hardware rehearsal | `rehearse` (full `unbind → remove → rescan → verify → rebind`, **no register writes**) | 4 s, trap completely silent |
| On-hardware resize | `apply --size 14`, both cards 512 MB → 16384 MB | Succeeded; root port window 520 MB → 16392 MB |
| Interrupt recovery | Injected delay, then `SIGTERM` after `remove` | Recovered in 2 s; `xe` rebound automatically |
| Backend comparison | SYCL vs Vulkan, single and dual GPU, multiple models and contexts | See [`bench/reports/`](bench/reports/) |
| Independent review | Two rounds, three reviewers each | See [`docs/reviews/`](docs/reviews/) (Chinese) |
| Service regression | Actual calls against the three inference services (8092/8093/8094) after resize testing | Normal |

### 4.2 What was not done, or cannot be done

- **Fully validated on only one machine** (Supermicro X10DAL-i + 2× B580); a second machine
  served as reference only;
- **No kernel version matrix**: only `7.0.0-38-generic` was tested; `6.12+` is a reasonable
  baseline, not a measurement;
- **No long-duration stability test**: it has not run for days to watch for leaks or
  intermittent failures;
- **Arc A-series not covered**: `ECAP` reads only the first `(Cap, Control)` pair, so an A-series
  card could be written at the wrong BAR index (B580 is unaffected);
- **Shared root ports are refused, not handled**: if the root port also hosts an NVMe/NIC, the
  `preflight` step lists those devices and **refuses** `apply`/`rehearse` (fail-closed), and
  `check` reports the same ERROR; `rollback` only warns, because restoring the original value
  takes priority over the gate. The difference from `tools/rebar-batch.sh` is **capability, not
  safety** — the batch script downgrades the anchor to the on-card bridge and still works, while
  the single-card script just says "no, use the batch script";
- **No card larger than a B580 was tested**: the highest step actually exercised is `N=14`
  (16 GB). `N>14` runs the same logic and the same formula, differing by one constant, but there
  is **no on-hardware data** — see "Bigger cards" in the README;
- **`SIGKILL` / OOM / power loss cannot be trapped**: a vanished subtree is still possible in
  those cases.

> If you get it working (or break it) on another platform, an issue with your board model and
> logs is welcome — compatibility for this project can only be established one machine at a
> time. Cards with more VRAM are especially wanted: changing the `--size` exponent should be
> enough in theory, but the N>14 rows of that table are formula today, not measurement.

---

## 5. If you redistribute, fork, or ship this commercially

MIT lets you do all of that. **Just keep the copyright notice and the full licence text** — no
prior permission needed. Beyond that there are only two requests (**not** licence conditions):

1. Keep [`CREDITS.md`](CREDITS.md) — it records other people's contributions. Removing it does
   not violate the licence, but it is not decent;
2. If you modify the code and publish it, say what you changed — it helps the next person work
   out where a problem came from.

---

*This document is an engineering statement, not legal advice. If you intend to use this in a
commercial product or deploy it at scale inside an organisation, have your legal team review the
statutory references in [`CLEANROOM.md`](CLEANROOM.md) section 5 together with the MIT terms.*
