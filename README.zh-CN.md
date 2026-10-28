# b580-bar-tool

[English](README.md) | **简体中文**

> **中文是本项目的主语言**：脚本输出、日志、`docs/` 与本文都直接以中文写成，英文版是为国际读者
> 做的翻译。两版说法不一致时，**以中文版为准**。
> English readers: see [`README.md`](README.md) — the English file is a translation; the Chinese one governs.

在 BIOS 给不到足够大 BAR 窗口的主板上，为 Intel Arc 显卡把 PCIe BAR2 扩到 16GB。

**BIOS 这条路线是走过的，走不通。** BIOS 里确实有 BAR 大小设置项（出厂默认 256MB），
但**能把机器正常起来的最大值只有 512MB**；再往上调，显卡初始化不过，机器**直接卡在 POST**。
于是两难：能起来的档位只到 512MB，而显卡需要 16GB —— **能起来的都不够大，够大的都起不来**。

这台机器无显示输出、无 IPMI，卡在 POST 时既看不到卡在哪一步，也没法远程改回设置，
只能到现场断电、清 CMOS 恢复默认。所以本项目绕过固件：在运行时改写 PCIe 配置空间里的
ReBAR Control，再让内核重新分配上游桥窗口，一次拿到 16GB —— 不改 BIOS，也不赌 POST。

> 若你的板子 BIOS 里连 BAR 大小选项都没有（部分服务器板如此），同样适用 ——
> 本工具不依赖 BIOS 的任何选项，只依赖卡的 ReBAR 能力和内核的重新枚举。

本项目基于 **PCI-SIG 公开的 PCI Express Resizable BAR 扩展能力规范（ECAP ID `0x0015`，
2008-01-22 提出、2008-04-24 经 PWG 批准，作为 ECN 并入 PCIe Base Spec 2.1 / 3.0）**
与目标机器的实测寄存器值独立实现，不复制任何第三方同类项目的代码。

规范原文出处、Linux 内核实现依据、以及前人（PCI-SIG、Linux PCI 子系统、
ReBarUEFI 等）的贡献，逐条列在 **[`CREDITS.md`](CREDITS.md)**。

> **文档脱敏说明**：为便于分享，本仓库文档中的主机信息已替换为占位符 ——
> `<SERVER_IP>` = 目标服务器地址，`<USER>` = 登录账号，`<REVIEW_HOST>` = 评审机地址。
> 照抄命令前请按实际环境替换。脚本内的账号亦已改为运行时自动推断（`GPU_USER` / `SUDO_USER`），无需硬编码。

---

## 当前状态（务必先读）

| 项 | 状态 |
|---|---|
| `status` / `gpu` / `check` / `plan` | 已实测通过 |
| `rehearse`（remove + rescan 演练，不改 BAR） | **已实测通过，4 秒，零挂死** |
| `apply --size 10`（1GB 探针） | **成功，BAR2 520MB 窗口 → 1032MB，BAR2 = 1024MB** |
| `apply --size 14`（正式扩到 16GB） | **成功，BAR2 = 16384MB** |
| BAR2 实测结果 | **16GB** @ `0x20000000000`（64-bit prefetchable），Control = `0x00000e22` |

> ⚠️ **这一行是执行过 `apply` 之后的状态，不是开机默认值。**
> BAR2 是**运行时**状态：重启或断电后回到 BIOS 的设定值（本机 512MB，出厂默认 256MB），
> 必须重新执行 `apply`。**跑推理、训练，或任何依赖大 BAR 的任务之前，先核对一眼：**
>
> ```bash
> sudo ./b580-bar-tool.sh status --gpu <BDF>
> ```
>
> 看两行就够：`BAR2 实际大小 : 512MB`、`根端口窗口 : 520MB` —— 是这个值就是没扩，
> 别急着往下游排查。（2026-10-28 目标机上就因为这个顺序搞反，先去查了推理引擎的跨卡搬运。）

### 实测结论：全量 re-enumeration 能扩桥窗口，`xe` 的 in-place resize 不能

这是本项目最关键的一条事实，也是它为什么能成的原因：

```
# 开机时与 15:24 演练时，xe 驱动自己试过两次，两次都失败
xe: BAR 2 [mem size 0x400000000 64bit pref]: can't assign; no space
xe: Failed to resize BAR2 to 16384MiB (-ENOSPC). Consider enabling 'Resizable BAR' support in your BIOS
```

原因是 `pci_resize_resource()` 只在**现有桥窗口内**找空间，不会去扩根端口窗口；而本项目
"先写 Control 再全量 re-enumeration" 走的是 `pbus_reassign_bridge_resources`，它会重排并
扩大桥窗口。实测三级跳：

| 阶段 | 根端口 prefetch 窗口 | BAR2 | CPU 可访问显存 |
|---|---|---|---|
| 初始 | 520MB | 512MB | 1GB（`Small BAR device`） |
| `--size 10` | **1032MB** | 1024MB | 1GB（`Small BAR device`） |
| `--size 14` | **16392MB** | **16384MB** | **11.9GB `0x2fb800000`**（无 `Small BAR`） |

> 表中「初始」是 **BIOS 已设到能起来的最大值 512MB** 的状态。出厂默认是 256MB，那时 BAR2
> 只有 256MB、根端口窗口也相应更小 —— 本工具照样能从那里直接跳到 16GB，起始值不影响
> 写入的目标（见下文「移植到别的主板」）。
> 另外注意 520MB 只比 BIOS 的 512MB 多 8MB，说明固件就是按"最大 512MB"在规划桥窗口，
> 没为更大的 BAR 预留过空间。

> 中间那次 `--size 10` 的价值：它请求的 1GB 超过了当时 520MB 的窗口，**必须扩窗才能成功**，
> 因此是一个精准的机制探针。成功即证明扩窗可行，再上 16GB 才有依据。

> **顺带一个对照，正好说明卡在哪一层**：同样是 1GB 这一档，运行时扩窗能成，在 BIOS 里设
> 却卡 POST（见 `docs/environment.md`）。缺的不是显卡的硬件能力，而是固件在 POST 阶段
> 规划桥窗口的能力 —— 这也正是本项目把这件事搬到系统起来之后做的原因。

**不要误以为 BAR 靠 BIOS 或持久配置生效。** 这是一种运行时状态，断电重启后配置空间由
BIOS 重置，BAR 回到 512MB；需要重新执行 `apply`（脚本不写任何持久配置）。

---

## 目标机器（<SERVER_IP>）

> 这张表只列与 BAR 扩容直接相关的几项。完整的软硬件环境（主板型号、BIOS 版本、
> CPU / 内存、内核与驱动版本、Vulkan ICD、基准工具链）在
> [`docs/environment.md`](docs/environment.md)。

| 项 | 值 |
|---|---|
| GPU | `0000:04:00.0` Intel Arc B580（Battlemage G21） |
| 根端口 | `0000:00:02.0`（C610 / Wellsburg，X99） |
| 拓扑 | `00:02.0` → `02:00.0`(switch 上游) → `03:01.0`→GPU / `03:02.0`→HDMI 音频 |
| 驱动 | `xe`（内核 7.0.0-38）+ `snd_hda_intel` |
| ReBAR ECAP | 偏移 `0x420` |
| Capability | `0x0007f000` → 支持 N=8..14 → 256MB ~ 16GB |
| Control | `0x00000922` → BAR 索引 2，size 字段 9 = **512MB** |
| 目标 Control | `0x00000e22` → size 字段 14 = **16GB** |
| 内核参数 | 已含 `pci=realloc` |
| 显示输出 | 全 headless，7 个显示口均 disconnected |

`Control` 位域（PCI-SIG 规范定义）：

```
bits[2:0]   BAR Index（必须原样保留，本机 = 2）
bits[13:8]  BAR Size（N，实际字节数 = 2^(N+20)）
```

改尺寸就是：`new = (old & ~0x3F00) | (N << 8)`。

---

## 定位：全手动

这是**手动工具**。它不安装任何东西、不启用任何服务、不往磁盘写任何能活过重启的东西 ——
想要扩容就跑一次 `b580-bar-tool.sh apply`，撑到下次断电为止。这是有意设计，不是缺功能。

`tools/` 是**实验记录**。拓扑探测层、批量路径、启停辅助脚本、两个 systemd 单元，都是
*这台机器*在摸索过程中恰好需要的东西。它们公开是因为它们是证据，不是因为它们是一套
受支持的安装器。读它们，取走对你主板有用的部分，其余忽略。

### 想让它开机自动生效的话

能做，但需要在本仓库**之外**改一处，这里值得说准确：`preflight()` 把一切都压在一行判断上：

```bash
grep -qw 'pci=realloc' /proc/cmdline    # b580-bar-tool.sh —— 这就是那道闸门
```

所以"自动"的第一步其实是：改 GRUB（`GRUB_CMDLINE_LINUX_DEFAULT`），加 `pci=realloc`，
`update-grub`，重启 —— 也就是本工具存在就是为了绕开的那个持久化改动。把那条 `grep` 删掉
同样没用：桥窗口之所以能变大，是因为内核在 rescan 时重新分配了资源，没有 `pci=realloc`
它就不会重新分配，脚本怎么想都没用。

`tools/` 下那两个单元（`b580-rebar.service`、`b580-rebar-late.service`）只在作者机器上跑过。
它们作为参考随仓库提供；请当成你自己写单元的起点，而不是受支持的安装器。

---

## 用法

```bash
sudo ./b580-bar-tool.sh status      # 只读：寄存器与窗口现状
sudo ./b580-bar-tool.sh gpu         # 只读：列出全部显示设备身份（双显卡必跑）
sudo ./b580-bar-tool.sh check       # 只读：逐条验 apply 的前置条件
sudo ./b580-bar-tool.sh plan        # dry-run：打印完整执行计划
sudo ./b580-bar-tool.sh rehearse    # 演练：只做 remove+rescan，不写 Control
sudo ./b580-bar-tool.sh apply       # 真正执行（需输入 YES 确认）
sudo ./b580-bar-tool.sh rollback    # 把 Control 恢复到 apply 前记录的值
```

`--size <N>` 可指定目标 N（默认取本卡支持上限 14）；`--yes` 跳过交互确认；`--gpu <BDF>` 手工指定设备。

### 多显卡安全

`class 0x030000` 只说明"这是显示设备"，**不能区分是哪一张卡**。因此：

- 脚本用 `vendor:device` 校验身份，默认期望 `8086:e20b`（Battlemage G21 / Arc B580），
  可用 `TOPO_DEV_IDS="8086:xxxx"` 换成别的型号（支持空格分隔多个）
- 检测到 **≥2 个**带 ReBAR 的显示设备时**拒绝自动选择**，列出每个的身份后要求 `--gpu` 指定
- 显式 `--gpu` 也必须过身份校验；目标不是 B580 时需 `--allow-any-gpu` 才放行
- 多卡环境**先跑 `tools/gpu-topology.sh --plan`**，它会直接给出每张卡该跑什么命令

推荐执行顺序：`gpu-topology.sh --plan` → `gpu` → `status` → `check` → `plan` → `rehearse` → `apply --size 10`（探针）→ `apply --size 14`

### 多卡为什么需要"锚点分组"

扩 BAR 必须 `remove` 一个桥设备 —— 而 remove 会摘掉它**整个子树**。
要扩哪一级的窗口，就得摘哪一级；能摘多高，取决于**再高一级的子树里有没有别人的设备**
（NVMe / 网卡 / RAID 卡）。这个结论无法写死，只能探测。

`tools/lib/topology.sh` 的做法：从 GPU 沿 sysfs 父链往上走，只要某一级的子树里
除了目标卡（含它自带的内部桥、HDMI 音频）没有别的设备，就继续往上；停在最高的那一级，
称为**安全锚点**。它通常等于根端口，但代码里没有这个假设。

| 探测结果 | 含义 | 该跑什么 |
|---|---|---|
| 每张卡独占一个锚点（`atomic`） | 互不影响 | 逐张 `apply --gpu <BDF>` |
| 多张卡共用一个锚点（`batch`） | 同一次 rescan 里一起结算窗口 | `rebar-batch.sh` 整组一次处理 |

**为什么共用锚点时不能逐张跑**：第 2 次 rescan 需要两倍的窗口，内核分配不理想时
会把先扩好的那张挤小，而 `apply` 只校验目标卡 → 报"成功"，另一张静默降级。

`tools/rebar-autofix.sh` 会根据探测结果自动选路，开机自愈用的就是它。

---

## 移植到别的主板：起始 256MB 一样能用

一台机器的 BAR2 起始大小**不是本工具的前提条件**。出厂 BIOS 通常只给 **256MB**，改过 BIOS 的
板子可能给 512MB（本机就是 512MB），两者都能扩到 16GB。

**为什么无所谓起始值**：脚本读当前 size 字段只为两件事——幂等判断（当前已 ≥ 目标就退出）与
打印；真正写入的是**绝对目标值** `new = (old & ~0x3F00) | (N << 8)`，与旧值无关。起始 8（256MB）
时 8 < 14，照常执行。

**真正的三个前提**（与 256/512 无关）：

| 前提 | 说明 | 怎么查 |
|---|---|---|
| Capability 位图含 N=14 | 这是 **GPU 自身**的能力，同一块 B580 恒为 `0x0007f000`（N=8..14），与主板无关 | `status` 里的「卡支持上限」 |
| `pci=realloc` 在内核命令行 | 没有它，重扫时内核不被允许扩大桥窗口；脚本会直接报 ERROR 拒绝执行 | `cat /proc/cmdline` |
| 根复合体 Above-4G 窗口有 ≥16GB 连续且 16GB 对齐的空闲 | 这一条最容易成为真瓶颈。本机父窗口 `20000000000-2ffffffffff`（1TB），base 恰好 16GB 对齐 | `sudo grep "PCI Bus 0000:00" /proc/iomem` |
| 芯片组容忍全量重枚举 | 少数芯片组会挂死，恢复靠断电；先跑 `rehearse` 单独验证，它不改 BAR | `rehearse` |

**起始 256MB 反而收益更大**：作者在 C602 平台（256MB 起始）实测带宽 15 → 392 GB/s；
本机 512MB 起始时，增量只有 512MB → 16GB 那一段。

**若 16GB 装不下**：可退到 `--size 13`（8GB），把 12GB 显存的前 8GB 映射给 CPU，
仍远好于 256MB；dmesg 会显示 `CPU accessible size` 相应变小。

---

## 更大的卡：换一个幂次就行，但没有实测过

`--size` 收的不是 MB，是**幂次**：`字节数 = 2^(N+20)`。

| N | 窗口 | 出现在哪 |
|---|---|---|
| 8 | 256MB | 出厂 BIOS 的默认值 |
| 9 | 512MB | 改过 BIOS 的板子（本机） |
| 13 | 8GB | 12GB 显存装不下 16GB 时的退档 |
| 14 | 16GB | B580 的 ECAP 上限，**本项目实测过的最大的一个** |
| 15 | 32GB | 24GB 级显卡会用到，**未实测** |

多数情况下连这个数都不用填。**上限不是写死的 16GB**，而是从卡自己的 Capability 位图
读出来的（脚本里的 `max_supported_n()`）；不给 `--size` 就取那个上限。所以换一张
ECAP 声明 N=15 的卡，脚本会自己冲着 32GB 去，改都不用改。

需要动手的只有两处，都不是尺寸本身：

1. **身份校验**。`EXPECT_ID_DEFAULT="8086:e20b"` 是 B580 的 `vendor:device`。换别的型号
   要么加 `--allow-any-gpu`，要么改这个常量 —— 后者更安全，`--allow-any-gpu` 等于把
   "别改错卡"这道防线整个撤掉。
2. **根复合体的空闲窗口要装得下更大的对齐块**。32GB 连续**且 32GB 对齐**，比 16GB 难
   得多。这一条最可能先失败，失败的表现是分配被降级，脚本判 `BAR2 != 期望` 后回滚。

**没验过的部分，明说**：作者手上只有 B580（12GB 显存、上限 N=14），**N>14 没有任何
真机数据**。代码上是同一段逻辑、同一个公式，只差一个常数 —— 但"能推出来"不等于"跑过"。
按可能性排序，可能的失效点：

- 桥窗口分配失败（内核找不到足够大的连续区域）→ 判 `BAR2 != 期望`，回滚。属安全失败；
- 卡侧声明了更高档位、固件却不接受写入 → 字段写进去了但 BAR2 没变，`status` 会显示
  两者矛盾（`plan`/`apply` 的幂等判据同时看字段和实际大小，正是为了这种情况）；
- 芯片组容忍度：根端口重枚举这个动作本身没变，风险应与 16GB 时同级，但没有验证。

因此脚本在卡声明 N>14 时会先打一条 `WARN`，`plan` 阶段就能看到，不用等到真下手。

> **等你补**：有更大的卡跑通了（或跑挂了），开 issue 贴 `status` 的输出、卡型号、
> `gpu-topology.sh` 的结果。这张表的 N>14 那几行现在只有公式，没有实测值。

---

## 执行前必须做的事：停 GPU 服务

**GPU 有 DMA 在途时移除根端口是最可能挂死的场景。** 先停服务：

```bash
sudo -v                      # 先缓存 sudo 凭据（脚本不再接受密码参数）
./tools/stop-gpu.sh --dry-run   # 先看会停哪些，不动任何东西
./tools/stop-gpu.sh
```

它不带任何服务名清单 —— 而是现场问"此刻谁抓着设备"：

```
fuser /dev/dri/renderD*     →  PID
/proc/<pid>/cgroup          →  0::/system.slice/paddleocr-vl-8094.service
basename                    →  paddleocr-vl-8094.service
```

反查出来的逐个停掉，并把 unit 名记进 `/run/b580-bar-tool/stopped-units`，
`start-gpu.sh` 据此只恢复这些、不多不少。不归任何 unit 的占用者（登录会话、手工
拉起的进程）会列出来让你处理 —— 脚本不替你猜。

**为什么用反查而不是清单**：作者是这台机器上 9 个推理服务，但 2026-10-28 实测那一刻
**只有 3 个真的占着 GPU**。写死清单会把 9 个全停（其中 6 个本来空闲），而且以后新增
服务必然漏掉。

`check` 用同一套 `fuser` 判断，只要还有进程抓着节点就**直接拒绝** `apply`/`rehearse`。

| 端口 | 单元 | 级别 | 实测占用 GPU |
|---|---|---|---|
| 8094 | `paddleocr-vl-8094.service` | 系统 | **是** |
| 8092 | `llama-rerank.service` | 用户 | **是** |
| 8093 | `llama-asr.service` | 用户 | **是** |
| 8095 | `paddlex-8095.service` | 系统 | 否（CPU 流水线） |
| 8091 | `tei-rerank-gpu.service` | 用户 | 否 |
| — | `ollama.service` | 系统 | 否 |
| — | `model-watch.service` / `model-watch-11434.service` / `headroom-proxy.service` | 用户 | 否 |

> 这张表是"反查在本机解析出来的结果"，属于**观测记录，不是配置**。你的机器上会不一样，
> 那没关系：唯一的要求是"没有东西在用 GPU"。

---

## 风险与回退

**风险**：`remove` 根端口后 rescan 时，少数芯片组不容忍重新枚举，可能导致内核挂死。

**实测结论**：本机 C610 完全容忍，演练 4 秒通过。

**兜底**：`tools/wd-enable.sh` 启用 systemd 运行时看门狗（走 PCH 的 iTCO_wdt 硬件 TCO 定时器，60 秒）。内核挂死会被硬件自动复位整机，无需到机房断电。

```bash
sudo ./tools/wd-enable.sh              # 启用
# 回退：/etc/systemd/system.conf 里 RuntimeWatchdogSec 改回注释，再 systemctl daemon-reexec
```

**本脚本不写任何持久配置**：不碰 BIOS、固件、GRUB、initramfs。断电重启后配置空间由 BIOS 重置，BAR 回到 512MB，系统正常起来。

---

### 除 BAR2 之外还会变什么

两处副作用，均为实测。都不是本工具造出来的，但都会咬到周边工具：

| 现象 | 说明 |
|---|---|
| **DRM 节点号会变** | `rescan` 之后 `renderD128` / `renderD129` 变成 `renderD129` / `renderD130`（实测）。服务重启后自己按新节点打开，不受影响；但任何**记下过节点号**的监控或脚本会指错设备。取节点号要通配 `/dev/dri/renderD*`，或从 `/sys/class/drm/*/device` 反查 BDF |
| **`rollback` 不是空操作** | 只要上次 `apply` 留下的 `/var/lib/b580-bar-tool.state` 还在，`rollback` 就会把 BAR 真改回记录值（实测 `16384MB → 512MB`）。想「什么都不做」先看 `status`，别拿报错当保护 |

---

### 已知风险与处置决定

安全审计（`docs/security-review.md`）指出两个高危组合，处置决定如下：

| 风险 | 决定 | 依据 |
|---|---|---|
| 开机 unit 以 **root** 执行 `/opt` 下脚本，而该目录属主是运维账号（可写） | **接受，不收紧属主** | 隔离网段 + 单操作员专用机 + 脚本全部纳入 git 留痕。完整理由与补偿措施见 `docs/security-review.md` **RA-01** |
| 提权通道为 `docker --privileged --pid=host` + `nsenter -t 1` | **保留** | 目标机未配置免密 sudo 时的唯一手段。全部为人工执行，不写入任何 cron / systemd / CI |

接受前提是三条同时成立：**隔离网段**、**单操作员专用机**、**脚本变更走 git**。
任一条不成立（接入非受信终端 / 新增登录账号 / 改由自动化流程写入 `/opt`）须立即重新评估并收紧：

```bash
chown -R root:root /opt/b580-bar-tool && chmod -R go-w /opt/b580-bar-tool
```

---

## 部署：两种布局都支持

本工具不需要安装。`git clone` 之后直接用，或者把 `tools/` 的内容平铺到某个固定目录
（如 `/opt/b580-bar-tool/`）长期放着。两种布局脚本都能认出来：

| 布局 | 结构 | 适用 |
|---|---|---|
| **仓库布局** | `b580-bar-tool.sh` 在根，辅助脚本在 `tools/` | 直接 clone 下来用 |
| **部署布局（平铺）** | `tools/` 的内容全部复制到同一层目录，主脚本与辅助脚本同级 | 常驻一台机器，用绝对路径调用 |

路径解析集中在 `find_tool()`（`tools/apply-bar-root.sh` 等辅助脚本开头）：它两种布局都试，
所以从仓库直接跑和从平铺目录跑，都不会因为"找不到主脚本"而静默失败。

> ⚠️ **平铺部署唯一的真风险，是"跑在旧版本上"。** 平铺是**复制**不是链接，仓库更新后不会自动同步；
> 而平铺目录里没有任何版本标识，你没法一眼看出它停在哪一版。
>
> 2026-10-28 就在目标机上撞到一次：`/opt` 里的脚本落后仓库 **41 个提交**，其中的 `stop-gpu.sh`
> 还是"写死服务清单"的旧实现，结果漏停了两个服务；停服记录文件也没生成，`start-gpu.sh` 无从恢复，
> 只能手工列清单起回来。
>
> 每次同步后留一个版本戳，排查时先看它：
>
> ```bash
> git -C <仓库路径> describe --always --dirty > /opt/b580-bar-tool/VERSION
> ```
>
> 主脚本启动时第一行日志也会打印 `v$VER` —— 两个对不上，就是没同步。

---

## 目录说明

```
b580-bar-tool.sh          主脚本（单文件，无外部依赖；ECAP 偏移由能力链表探测得出）
tools/lib/topology.sh     探测层：设备枚举 / ECAP 定位 / 祖先链 / 安全锚点 / 分组 / 计划
tools/gpu-topology.sh     拓扑体检报告（--plan 给结论，--env 给变量，只读）
tools/rebar-batch.sh      按锚点分组扩 BAR2（先写全部 Control，再一次 rescan）
tools/rebar-autofix.sh    探测 → 选路 → 交给上面两个之一（systemd 用这个）
docs/rebar-task.md        三版模型派发用的技术任务书（只给规范和实测数据，不给实现步骤）
docs/environment.md       实测运行环境：主板/BIOS/CPU/内核/驱动/Mesa/基准工具版本清单
docs/reviews/             独立评审归档（两席报告全文 + 结论裁定索引，针对 v1.1.0）
docs/case-*.md            具体机器的实测案例（拓扑、日志、结论），不作通用前提
tools/lib/gpu-services.sh 反查层：设备 → PID → cgroup → unit（代码里没有任何服务名）
tools/stop-gpu.sh         停掉当前抓着 renderD 的东西，记录其 unit，等节点释放
tools/start-gpu.sh        只恢复记录里的那些 unit，然后复查
tools/stop-gpu-root.sh    同上，root / nsenter 场景入口（需 GPU_USER=<用户>）
tools/start-gpu-root.sh   同上，root / nsenter 场景入口
tools/wd-enable.sh        启用硬件看门狗
bench/run-bench.sh        llama-bench 封装（默认 Qwen3.5-9B Q6_K），测 pp / tg
bench/fa-matrix.sh        FlashAttention 开关矩阵，Qwen3 4B 与 Qwen3.5 9B 两种规模
bench/reports/            实测数据：双卡 SYCL vs Vulkan、9B pp4096 单卡对照
docs/GLOSSARY.md          中英术语对照表（两版译名的唯一依据）
tools/check-i18n.sh       双语一致性检查（只比结构，只读）
README.zh-CN.md           中文版 README        ┐
DISCLAIMER.zh-CN.md       中文版免责声明       │ 这四对是双语文档；
CREDITS.zh-CN.md          中文版致谢           │ 中文为主语言，英文为译文
CLEANROOM.zh-CN.md        中文版独立实现声明   ┘
DISCLAIMER.md             免责、失败模式、商标声明、AI 参与说明、验证边界（动手前先读）
CREDITS.md                规范出处、方法首创者、Linux 内核侧依据、同类项目对比
CLEANROOM.md              独立实现声明与第三方接触范围披露
NEXT.md                   已知未修项与待办 + 实测坑清单（作者本机交接笔记，只有中文）
archive/                  三版免费模型候选实现 —— 仅供评审留证，均不可用
```

> **探测层是唯一的"机器长什么样"来源**。上层脚本不得写死 BDF、槽位、ECAP 偏移、
> `renderD` 编号 —— 这些在不同主板、不同插槽、不同 BIOS 上都会变，写死的后果是
> 静默失效（条件不满足直接跳过，日志里一个字都没有）。

扩容完成后用 `tools/start-gpu.sh` 恢复服务：

```bash
sudo -v
./tools/start-gpu.sh                        # 恢复记录的 unit + 复查 + 打印 BAR2 现状
```

> `archive/` 内的脚本保留**历史原貌**，其中的脚本名、日志路径仍为旧名 `rebar-b580`
> （项目 2026-10-27 由 `rebar-b580` 更名为 `b580-bar-tool`）。归档文件不作修改，
> 以保证评审证据的真实性。

### 文档语言

**中文是本项目的主语言。** 作者母语中文：脚本输出、日志、`docs/` 下的全部文档，以及下面这四份的
原文，都是中文。`README`、`DISCLAIMER`、`CREDITS`、`CLEANROOM` 另有英文译文，供国际读者阅读。
两版说法不一致时，**以中文版为准**。

**脚本输出只有中文，这是刻意的。** 没有 `--lang` 开关，也没有消息表 —— 一旦上双语，每条消息都得
写两份，其中一份必然悄悄腐烂。而且你真正要从输出里取的东西本来不需要翻译：级别前缀
（`ERROR` / `WARN` / `INFO` / `OK`）、第几步、以及打印出来的数值（BDF、寄存器值、MB）。
看不懂的提示照样能处置：前缀告诉你该不该停，`/var/log/b580-bar-tool.steps` 告诉你停在哪一步，
其余都是数字。

为什么不全部翻译：**没人维护的译文比不翻更糟** —— 它会过期，然后误导读者。这四个覆盖了
完整的决策链（可不可信 → 安不安全 → 抄没抄 → 怎么用），`docs/` 是想深入才看的第二层。

英文版另有两节只在英文侧存在：**Chinese-only pages**（中文页面的一句话索引，中文读者不需要）
与 **Reproducing the throughput numbers**（实测数据复现）。中文版没有这两节不算漏译。

两条防止两版漂移的办法：

- **[`docs/GLOSSARY.md`](docs/GLOSSARY.md)** 在翻译前先把每个术语的译法定死 ——
  BAR2 用 **aperture**、桥窗口用 **window**（这两个不能混）；`remove` 不译成 "unplug"；
  演练是 **rehearsal** 不是 "dry run"（它会真的 remove 设备）
- **`tools/check-i18n.sh`** 比对每一对的**结构**（二级/三级标题数、代码块围栏数），
  **不做全文 diff** —— 中英文不可能逐行对齐，全文 diff 全是噪声

改完任一侧后跑一次：

```bash
./tools/check-i18n.sh
```

### ⚠️ archive 目录里的候选脚本有致命缺陷，不要使用

| 文件 | 缺陷 |
|---|---|
| `cand-hy3.sh` | 读 Capability 用 `.W`（16 位），丢掉高 16 位，误判本机上限仅 2GB，据此**自我拒绝执行** |
| `cand-minimax.sh` | 用 `setpci ... .d` 宽度——**非法**（合法只有 `.b/.w/.l`），寄存器完全读写不了，直接退出 |
| `baseline.sh` | 主脚本的前身，保留用于追溯演化 |

保留它们是为了证明主脚本的独立性与评审过程，不是可用代码。

---

## 写这类脚本必踩的坑（本机实测记录）

1. `seq 0x100 4 0xFFC` —— GNU seq **不认十六进制参数**，ECAP 扫描会静默失效
2. `[ $x -eq 0x0015 ]` —— `test` 的整数比较**不支持十六进制字面量**（会报 `integer expression expected`
   并恒为假），必须用 `(( ))` 算术上下文。**这条被违反过两次**：第二次是把 ECAP 探测从
   "猜死偏移"改成"遍历能力链"时，比较写成了 `[ "$capid" -eq "$ECAP_ID_REBAR" ]`，
   结果探测永远失败、直接报"未找到带 ReBAR 的显示设备"——改造旧代码时请重新核对每处比较
3. `setpci` 宽度只有 `.b` / `.w` / `.l`，**没有 `.d`**
4. `/sys/.../resource2` 在部分内核读会返回 **EIO**，须读 `resource` 第 3 行
5. 读 Capability 必须 `.l` 取 32 位，用 `.w` 只拿低 16 位会误判上限
6. `lspci -n` 的字段是 `BDF` / `class:` / `vendor:device`，**class 在第 2 字段且带尾冒号**；取 `$3` 会拿到 vendor:device（本项目曾因此让 `apply` 误拒、并会去 unbind `pcieport`）
7. 解绑驱动**只解绑终端设备**（`xe` / `snd_hda_intel`），`pcieport` 保持绑定，由锚点级联移除
8. **`GROUPS` 是 bash 的保留特殊变量**（当前用户的组 ID 数组，root 恒为 `0`）。
   `GROUPS=()` / `GROUPS+=(...)` 会被 bash 接管，读出来永远是 `("0")`。
   本项目因此让"锚点分组"在计划里显示成"锚点 0、本组 0 张"——数组看着有值，
   内容全是假的。同类危险名还有 `PIPESTATUS` `RANDOM` `SECONDS` `LINENO` `UID` `PPID`，
   数组命名一律加业务前缀（现用 `ANCHOR_GROUPS`）
9. **`readarray`/`while read` 收集多行输出时，先确认命令在同样上下文（root、同命名空间）
   真的输出了多行**。`for x in "${arr[@]}"` 在数组只有 1 个假元素时不会报错，只会安静地少跑
10. 卡的 **GPU 核心自身链路**在 sysfs 里可能是 `x1 / 2.5GT/s`（那是卡内桥到核心的内部链路），
    真实槽位链路要看**卡内桥**（`current_link_width`）。别拿核心的值判断"插错槽了"

---

## 环境依赖

`bash`、`pciutils`（`setpci` / `lspci`）、`psmisc`（`fuser`，仅 `check` 需要）、root 权限。
内核需支持 ReBAR 扩展能力（6.12+ 完善）且命令行含 `pci=realloc`。

除此之外**不需要安装任何东西**：全仓库是纯 shell，没有 Python / Perl / 编译步骤，
也没有需要 `pip` 或 `apt` 拉取的运行时。

**实测环境**（本文档所有数据来源那台机器）的完整软硬件清单在
**[`docs/environment.md`](docs/environment.md)** —— 含主板/BIOS/CPU/内存、Ubuntu 与内核版本、
`xe` 驱动、pciutils 与 Mesa 版本、llama.cpp 构建号，以及「哪些条件必须满足、哪些可以不同」。
想复现 `bench/reports/` 里的吞吐数字，先对照那一页。

---

## 理论依据与致谢

这个工具做的每件事都有公开出处，完整的引用清单（含链接、日期、提交号）在 [`CREDITS.md`](CREDITS.md)。
最关键的六处：

| 依据 | 出处 | 用在哪 |
|---|---|---|
| **"remove + rescan" 这个方法** | **andersevenrud** 首次公开（[H11SSL-i + B580 的 gist](https://gist.github.com/andersevenrud/eec93e9151117bc0d6b6133b40eaffa5)）；**Ilpo Järvinen**、**Lucas De Marchi**（Intel）从内核侧解释了为什么必须移除整张卡 | **整条工作流的核心动作** —— 本项目的技术路线就是照着这条走的 |
| **Resizable BAR 能力定义** | PCI-SIG **Resizable BAR Capability ECN**（2008-01-22 提出 / 2008-04-24 PWG 批准），并入 PCIe Base Spec 2.1 与 3.0，Extended Capability ID `0015h` | 写 Control 寄存器的 size 字段 |
| **内核重排资源** | `pci=realloc` —— **Ram Pai**（IBM），2011-06-30；拆成 `=on/=off` —— **Yinghai Lu**，2012-02-01 | 让内核按新尺寸重新分配，而非沿用 BIOS 的分配 |
| **桥窗口扩大** | `pbus_reassign_bridge_resources`（`drivers/pci/setup-bus.c`） | 根端口窗口 520MB → 16392MB |
| **移除与重扫接口** | `Documentation/ABI/testing/sysfs-bus-pci`；`rescan` 由 **Alex Chiang** 于 2009-01 引入 | `remove` + `rescan` 触发全量重新枚举 |
| **同款卡上的邻作** | **[Emvo10/Intel-Arc-B580-ReBar](https://github.com/Emvo10/Intel-Arc-B580-ReBar)** —— B580 专用、systemd 开机服务，2026-09-05 公开，**比本项目早约 7 周** | 同一款卡（`8086:e20b`）、同一套 `setpci` + remove/rescan 动作。两条独立路线收敛到同一解法，是对"这条路是对的"最有力的旁证，见 [`CREDITS.md`](CREDITS.md) 第二节 2.4 |
| **同类项目的先例** | **[xCuri0/ReBarUEFI](https://github.com/xCuri0/ReBarUEFI)**（MIT，固件层 DXE 驱动）；**[RodBurlamaqui/Intel-ARC-Rebar](https://github.com/RodBurlamaqui/Intel-ARC-Rebar)**（`arc-rebar`，initramfs 启动期，非开源） | ReBarUEFI 证明「BIOS 说不支持 ≠ 硅片做不到」；`arc-rebar` 与本项目同处 OS 层、且早于我们。两者都在 [`CREDITS.md`](CREDITS.md) 致谢 |

还依赖 [pciutils](https://github.com/pciutils/pciutils)（`setpci` / `lspci`）读写配置空间 ——
没有它这个工具写不出来。推理侧基准依赖 [llama.cpp](https://github.com/ggml-org/llama.cpp)、
Intel oneAPI / Level Zero / UMF 与 Mesa。

## 许可

MIT，见 [`LICENSE`](LICENSE)。**使用、修改、商用均无需事先许可，保留版权与许可声明即可**
（这正是 MIT 的全部要求）。如果你在文章或产品里用到它，欢迎顺带提一句仓库地址 ——
不是许可条件，只是让下一个人搜得到。

本工具为独立实现，与第三方代码的接触记录见 [`CLEANROOM.md`](CLEANROOM.md)；
规范出处与前人贡献见 [`CREDITS.md`](CREDITS.md)。

## 风险声明（动手前先读）

本工具通过**移除 PCIe 桥、改写 BAR 分配**来改变硬件状态。少数情况下（GPU 有 DMA 在途、
锚点子树里混进了未知设备、内核拒绝重新分配）可能导致**系统挂死，只能断电重启**恢复。
它不是厂商工具，没有任何官方支持：

- 先在一台**可以随时断电**的机器上验证，别拿有业务在跑的机器试；
- 自愈 unit 默认**不要** `enable`，手工验证成功后再开；
- 工具不写任何持久配置，重启即回到 BIOS 里的 BAR 设定值（本机 512MB，出厂默认 256MB）。

完整的**失败模式表、责任范围、不适合的场景**见 [`DISCLAIMER.md`](DISCLAIMER.md)。

**AI 参与说明**：本项目的代码与文档由 AI 编程助手参与生成，作者负责方向决策、真机实测、
审核与取舍；实测数据全部来自真实硬件。具体分工、AI 出过的错、以及"验过什么 / 没验过什么"
都如实写在那份 [`DISCLAIMER.md`](DISCLAIMER.md) 里 —— 读者有权先知道这些再决定要不要跑。

> **与 Intel 无关联**：本项目不是 Intel 官方工具，未经其授权、认证或背书。
> Intel、Intel Arc、Battlemage、Xe 为 Intel Corporation 的商标或注册商标；
> 文档中的型号名（如 `B580`）属于指称性使用，仅用于说明适用对象。

