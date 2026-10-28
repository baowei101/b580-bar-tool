# Clean Room Statement

**English** | [简体中文](CLEANROOM.zh-CN.md)

> **Chinese is this project's primary language** — scripts, logs and `docs/` are written in
> Chinese, and this English file is a translation. Where the two differ, the Chinese text governs.

This document explains the origin, technical basis and development process of `b580-bar-tool`,
so that a reviewer can check it.

**Division of labour with [`CREDITS.md`](CREDITS.md)**: this file establishes that the code was
not copied; CREDITS states whose ideas and methods these are, and why they deserve to be named.
The two do not conflict — crediting a third party is not the same as using their code, and vice
versa.

---

## 1. Conclusion

All code in this repository is an independent implementation. It **contains no third-party
code, scripts or documentation of a comparable project, and is not derived from any**.

The only thing this project shares with publicly available peer projects is **a publicly
documented technical method**: writing a BAR size into the Control register of the PCIe
Resizable BAR extended capability (ECAP ID `0x0015`) and re-enumerating the PCIe root port. That
the method is public is confirmed by three parties independently:

1. **The PCI-SIG specification**: the register layout and semantics of the Resizable BAR
   extended capability are defined by a public PCI-SIG specification;
2. **The Linux kernel's public ABI**: `/sys/bus/pci/devices/*/remove` and `/sys/bus/pci/rescan`
   are standard interfaces the kernel exposes;
3. **The third-party project's own author**: its LICENSE §4.2 states in writing that the method
   is public knowledge and outside the scope of its licence (see §5.2).

---

## 2. Technical basis

Every source the implementation relies on is either a public specification or a measurement made
on this machine:

| Basis | Detail |
|---|---|
| PCI-SIG | ECAP ID `0x0015`; Capability register `bit(4+N)` indicates support for `2^(N+20)`; Control register `bits[2:0]` = BAR index, `bits[13:8]` = size field |
| Linux kernel docs and ABI | Semantics of the `pci=realloc` kernel parameter; `/sys/bus/pci/devices/<BDF>/remove` removes a device; `/sys/bus/pci/rescan` triggers re-enumeration; `/sys/bus/pci/drivers/<drv>/{bind,unbind}` controls driver binding |
| Measurements on this machine | ECAP sits at offset `0x420`; Capability reads `0x0007f000`; Control reads `0x00000922`; root port window and MMIO layout — all read back via `setpci` / `lspci` / sysfs |

**The scripts contain no hard-coded constant taken from a third-party project.** The single fixed
offset, `ECAP_HINT = 0x420`, comes from a `setpci` dump on this machine, and the script still
validates the ECAP ID; if validation fails it walks configuration space from `0x100` to `0xFFC`
as a fallback.

---

## 3. Disclosure of exposure

The third-party project material touched during development is listed in full below:

| Item touched | Content | Entered this implementation? |
|---|---|---|
| `README.md` | Feature description, hardware compatibility, risk statement | No (used to assess risk only) |
| `DISCLAIMER.md` | Disclaimer, failure-mode description | No (used to assess risk only) |
| `INSTALL.md` | Install flow, troubleshooting steps | No (used to assess risk only) |
| `LICENSE` | Full licence text | No (used for compliance analysis only) |
| `live-test.sh` | **6 lines total**: stop display-manager → call the main script → start display-manager | **No**, see below |
| `diagnose` command output | Terminal output of a one-off read-only diagnostic | No (used only to judge feasibility) |

**Not touched**: the core implementation scripts (the main flow under `scripts/init-premount/`),
the detection and safety logic, the packaging scripts, the initramfs hook implementation.

### About the 6 lines of `live-test.sh`

Its entire behaviour is "stop display-manager → call the main flow → start display-manager".
This can be verified in this repository: **none of those three things exists here.**

```bash
grep -niE "display-manager|gdm|lightdm|sddm" b580-bar-tool.sh     # no match
grep -nE "^\s*(source|\.)\s|exec "           b580-bar-tool.sh     # no match (function calls in one file, no sub-script architecture)
```

The reason is straightforward: the target server is fully headless and all 7 display outputs are
`disconnected`, so there is no display-manager to stop; and this project uses function calls
within a single file, so there is no "main script calls sub-script" architecture to mirror.

### The second peer project, contacted only during pre-publication research

On 2026-10-28, while preparing for publication and completing the credits, a search of GitHub for
comparable projects turned up
[`Emvo10/Intel-Arc-B580-ReBar`](https://github.com/Emvo10/Intel-Arc-B580-ReBar) (B580-specific,
published 2026-09-05, about 7 weeks before this project). **We did not know it existed during
implementation** — contact happened after all code had been committed (timeline in §7).

| Item | Situation |
|---|---|
| When | 2026-10-28, **pre-publication** research; implementation already frozen |
| Read | Only `README.md` (public documentation: feature description, the 8-step flow, the refuse-on-shared-root-port safety policy, the credits section) |
| Not read | The `b580-rebar` main script (7046 bytes), `install.sh`, `uninstall.sh`, `b580-rebar.service` |
| Entered this implementation? | **No** — implementation and all commits were complete; it was used only to complete the credits and the comparison table |
| Licence | **No LICENSE file.** Treated as all rights reserved, so we deliberately read only the README and not the implementation |

Why not read the code: it declares no licence; reading it had no value (the implementation was
independently finished long before); and it would only introduce avoidable ambiguity into the
clean room. The README was sufficient to support the credit and the comparison (see
[`CREDITS.md`](CREDITS.md) §2.4).

---

## 4. Route differences from third-party implementations

This is a stronger point than "the code is different": the **technical routes themselves differ**,
not merely the style of writing.

| Dimension | Third-party project | This project |
|---|---|---|
| When it acts | Early in initramfs, before the GPU is claimed by a driver | While the system is running, after unbinding the driver deliberately |
| Persistence | Installs a hook, writes into initramfs; stays in effect across reboots | **Writes no persistent configuration**; one-shot, reset by a reboot |
| Rollback | Kernel parameter `norebar` bypasses the hook | Reboot (configuration space is reset by the BIOS) |
| Code form | Multiple scripts + initramfs hook | Single bash file, no external dependencies |
| Main engineering difficulty | Missing tools in the initramfs environment | DMA safety while removing a live device (handled here with forced `fuser` probing plus an up-front refusal) |

The third-party project acts early to avoid the driver claiming the device; this project operates
at runtime and validates feasibility with an on-hardware rehearsal.

---

## 5. Legal basis

### 5.1 Article 6 of the Computer Software Protection Regulations (China)

> Copyright protection under these Regulations does not extend to the **ideas, processing
> procedures, operating methods** or mathematical concepts used in developing software.

Writing a BAR size to the ECAP Control register and removing/re-enumerating the root port is an
**operating method / processing procedure**, and falls outside copyright protection.

### 5.2 Third-party project LICENSE §4.2 (the author's own statement)

> Nothing in this Agreement grants or claims any rights in the underlying technical method of
> programming the PCI Express Resizable BAR control register and re-enumerating a PCI Express root
> port, **which is publicly known** and was first documented by andersevenrud. This Agreement
> applies to the Licensor's implementation: all of the Software's code, scripts, detection and
> safety logic, packaging, and documentation are the Licensor's original work.

The author explicitly acknowledges that the technical method is public knowledge and that the
agreement claims no rights over it; the agreement covers only their **specific implementation**
(code, scripts, detection and safety logic, packaging, documentation).

**This project uses no part of that software, so the agreement does not apply to it, and nothing
here constitutes any form of use as defined in its §1.1.**

---

## 6. On "similar operation sequences"

If someone compares the two implementations line by line, they will observe the following
similarity:

- unbind the leaf device drivers
- write the ReBAR Control register
- remove the PCIe root port
- trigger a rescan
- verify the BAR size and roll back if it does not match

**There is no second way to write that sequence**, because of hard constraints:

1. The PCIe specification requires the device to be inactive when its BAR size is changed, so the
   driver must be unbound first;
2. The only user-space entry point for the Linux kernel to re-enumerate a device is remove +
   rescan, so the sequence is fixed;
3. The size allocation can fail, so any responsible implementation must verify and roll back.

An identical sequence is the necessary consequence of the specification's constraints and does
not constitute substantial similarity of expression. Copyright protects **expression**, not
**ideas or operating methods** (see §5.1).

---

## 7. Development timeline

| Time (2026-10-27) | Event | Verifiable trace |
|---|---|---|
| Morning | Researched root-port rescan failure reports; assessed whether a third-party approach was viable | Session records |
| Morning | Read the third-party `LICENSE`; confirmed §1.1 excludes institutional use and §3.2 forbids modification ⇒ unusable | Session records |
| Morning | Confirmed §4.2 acknowledges the method is public ⇒ decided to implement independently | Session records |
| Morning | Read the machine's raw ReBAR register values (`setpci` / `lspci` / sysfs) | `docs/` records |
| 09:xx | Wrote `docs/rebar-task.md`: specification and measurements only, **no implementation steps** | File mtime |
| 09:22 | Wrote `archive/baseline.sh` (predecessor of the main script) | File mtime |
| 09:13 / 09:17 | Dispatched three models from different families to implement independently (`cand-hy3` / `cand-minimax`); all three prompts explicitly forbade referencing any comparable third-party project | File mtime |
| Morning | Tested the three candidates on hardware: hy3 misjudged the maximum, minimax used an invalid `setpci` width, the third produced nothing due to an upstream 502 | Session records |
| 09:23 | Merged into `b580-bar-tool.sh`, fixing the `lspci -n` field-index defect | File mtime |
| 15:22 | Enabled the hardware watchdog (`tools/wd-enable.sh`) | `system.conf.bak-rebar-20261027-152256` |
| 15:24 | Ran the `rehearse` rehearsal: remove + rescan succeeded, 4 seconds, no hang | `/var/log/b580-bar-tool.steps` (target machine) |

Dispatching three independent implementations served two purposes: cross-validation from several
directions, and an evidence trail showing the solution was derived from scratch. All three failed
on hardware defects, so the delivered version is a self-written implementation — though it did
absorb hy3's idea of validating the ECAP ID and minimax's idea of explicitly rebinding drivers
(both are generic engineering practice, not third-party code).

---

## 8. How to verify

Anyone can check this independently. The three commands below give **exact expected results**, not
"probably fine":

```bash
# 1) No trace of a third-party implementation should appear in the code
grep -rniE "arc-rebar|burlamaqui|init-premount|update-initramfs" \
  --include='*.sh' --include='*.py' --include='*.service' . --exclude-dir=.git
# Expected: only the self-describing comments in two archive/ candidate scripts; no implementation code

# 2) This project's scripts must contain no display-manager logic (the only behaviour of the third-party live-test.sh)
grep -niE "display-manager|gdm|lightdm|sddm" b580-bar-tool.sh tools/*.sh
# Expected: no match

# 3) This project's scripts must not contain the second peer project's unique identifiers
#    (these are unique to its README: config keys, config path, check output text)
grep -rniE "emvo10|B580_GPU|B580_ROOT_PORT|/etc/default/b580-rebar|16 GB ACTIVE" \
  --include='*.sh' --include='*.service' . --exclude-dir=.git
# Expected: no match

# 4) Commit history
git log --format='%H %ai %s'
```

### Where project names do appear, and why

| Location | Why the name appears |
|---|---|
| `archive/cand-hy3.sh:30`, `archive/cand-minimax.sh:18` | Early candidate implementations **self-describe** in their headers: "no comparable third-party project was referenced (in particular not arc-rebar)" |
| `docs/rebar-task.md:13` | The **prohibition as written** when the candidate implementations were dispatched: do not reference that project |
| `CREDITS.md` | **Public acknowledgement** (method provenance; §2.3 and §2.4 cover the two peer projects) |
| `README.md` | Two rows of the credits table ("A neighbour on the same card", "Prior art") |
| This file | Compliance analysis requires naming the projects, and records when and how far they were contacted |

**Apart from the two categories "declaring we did not reference it" and "thanking it", none of
their material appears in the code.** Those two categories are exactly what shows that contact was
recorded and bounded.

---

*This is an engineering compliance statement, not legal advice. Before commercial deployment, have
your legal team review the statutory references in §5.*
