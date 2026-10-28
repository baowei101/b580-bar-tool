# 实测运行环境

> **这不是最低要求，是本文档所有实测数字的来源机器。**
> 换一台机器，BDF、ECAP 偏移、槽位编号都会变（那些都是探测出来的，别照抄）；
> 但 OS / 内核 / 驱动 / 基准工具这条链路的版本对照仍然有参考价值 ——
> 尤其是想复现 `bench/reports/` 里那些吞吐数字的时候。
>
> 本页已脱敏：主机名、登录账号、IP、系统盘 UUID 全部以占位符代替。
> 具体某台机器的拓扑与日志在 `docs/case-*.md`，本页只讲软硬件版本。

记录时间：2026-10-28

---

## 一、硬件

| 项 | 值 |
|---|---|
| 主板 | Supermicro **X10DAL-i**（双路 LGA2011-3，Intel C610 / Wellsburg，X99 平台） |
| BIOS | **3.2**，2019-11-26 |
| CPU | 2 × Intel Xeon E5-2673 v3 @ 2.40GHz（12 核/路 → 24 物理核 / 48 线程） |
| 内存 | 157 GiB（`free -g` 内核可见值） |
| 显卡 | 2 × Intel Arc B580 12GB（`8086:e20b`，Battlemage G21） |
| 显卡槽位 | 两个独立 PCIe 根端口各占一槽，均 Gen3 **x8 / 8GT/s**（实测约 7.08 GB/s，两槽差 0.1%） |
| 显示输出 | 全部 headless，7 个显示口均 `disconnected` |

### 两个影响设计的硬件事实

**1. BIOS 的 BAR 路线走过，走不通 —— 这就是本项目存在的全部理由。**

BIOS 里有 BAR 大小的设置项（出厂默认 256MB）。这条路本机是**实际试过的**，结果是：

| BIOS 里设成 | 结果 |
|---|---|
| 256MB（出厂默认） | 正常启动 |
| **512MB** | 正常启动，**这是能起来的最大值** —— 本机最终停在这一档 |
| 1GB 及以上 | **卡在 POST**，显卡初始化不过，整机起不来（试到 1GB 就卡住了，更大的档位没再试 —— 没必要，卡一次就是一次现场作业） |

于是变成两难：**能起来的档位只到 512MB，显卡本身却支持 256MB ~ 16GB 共 7 档（N=8..14），
12GB 显存的完整访问需要 16GB 窗口。能起来的都不够大，够大的都起不来。**

更糟的是这台机器**无显示输出、无 IPMI**（见下一条）：卡在 POST 时既看不到卡在哪一步，
也没法远程重启或把设置改回去，只能到现场断电、清 CMOS 恢复默认。**一次试错就是一次现场作业。**
这是"BIOS 路线不可行"里比 512MB 这个能起来的上限更硬的那一半理由。

> 卡 POST 的推测原因：BIOS 按"最大 512MB"规划上游桥窗口（下述 520MB 窗口是侧证），
> 设成更大的 BAR 时桥窗口放不下，显卡 option ROM 初始化失败。这与运行时 `xe` 驱动自己
> 扩窗报 `-ENOSPC` 是同一个根因 —— 区别只是固件层的这个失败会直接把整机拖死在 POST，
> 而运行时的失败只是一个返回码。

> 一个侧证：BIOS 设为 512MB 时，实测根端口 prefetchable 窗口是 **520MB** —— 只比 BIOS 设的
> 512MB 多 8MB。说明固件是按"最大 512MB"这个前提在规划上游桥窗口的，它压根没为更大的
> BAR 预留空间。

**2. 没有 IPMI，也没有任何带外管理。** 所有操作只能在系统内完成，搞砸了不能
"从管理口重来一次"。这一点直接决定了工具的设计原则：每条破坏性路径都必须
先过只读检查（`check`）、先演练（`rehearse`），且不写任何持久化配置 ——
最坏情况断电重启即回到 BIOS 设定值（本机 512MB），可以重来一遍。

这也是 BIOS 路线代价高的地方：它在启动早期生效，恰恰落在"带外管理能救、而没有带外
管理就救不了"的那一段。本工具则相反 —— 它只在系统起来之后动作，出问题断电重启就
回到原状，不需要任何人到现场。

---

## 二、软件

| 项 | 值 |
|---|---|
| 发行版 | **Ubuntu 24.04.5 LTS** (noble) |
| 内核 | **7.0.0-38-generic**（x86_64） |
| 内核参数 | `pci=realloc`（其余为 `ro quiet splash vt.handoff=7`，`root=UUID=<系统盘>` 已脱敏） |
| 显卡驱动 | `xe`（内核内置，`/lib/modules/<ver>/kernel/drivers/gpu/drm/xe/xe.ko.zst`） |
| pciutils | **1:3.10.0-2build1**（`setpci version 3.10.0`） |
| 系统 Mesa | `mesa-vulkan-drivers` **25.2.8**-0ubuntu0.24.04.4 |
| 实际生效的 Vulkan ICD | **Mesa 26.3.0-rc1**，`/etc/vulkan/icd.d/10-intel-26.3.json` |

### 为什么 Mesa 要单独列出来

系统包自带的 Vulkan 驱动是 25.2.8，但**实测用的不是它**。实测环境另外装了
Mesa 26.3.0-rc1，通过 `/etc/vulkan/icd.d/10-intel-26.3.json` 显式指定为默认 ICD，
并把系统自带的 `intel_icd.json` 用 `dpkg-divert` 改名为 `intel_icd.json.distrib` 停用。

所以 `bench/reports/` 里 **Vulkan 后端的数字（4B Q8_0 pp4096 约 1156 t/s）是在
Mesa 26.3.0-rc1 下测得的**。用系统自带的 25.2.8 复现会得到不同的绝对值 ——
这是复现时最容易忽略的一条。

> 排查 SYCL 时还会遇到：`sycl-ls` 只列出 `opencl`、`level_zero` 消失。
> 那不是 BAR 的问题，是缺 `libumf.so.1`，需要把 `/opt/intel/oneapi/umf/1.2/lib`
> 加进 `LD_LIBRARY_PATH`。详见 `NEXT.md`。

---

## 三、基准用的构建与模型

| 项 | 值 |
|---|---|
| llama.cpp | 官方 nightly **b11925**（`commit fae9ac561`，`0.7.0-dev`） |
| 后端包 | `vulkan-x64` 与 `sycl-fp16-x64`，**同一构建号，只差后端** |
| oneAPI 运行库 | compiler 2026.2 / mkl 2026.2 / tbb 2023.2 / umf 1.2 |
| 模型 1 | `Qwen3.5-9B-Q6_K`（约 7 GB） |
| 模型 2 | `Qwen3-4B-Instruct-2507-Q8_0`（约 4 GB） |

**为什么强调"同一构建号"**：SYCL 与 Vulkan 的对比必须排除构建差异。用不同 nightly
比较，pp 数字差个 10% 都可能是构建本身带来的，那这个对比就没有意义了。

**为什么要连带测 4B**：SYCL 的可用性跟"模型能否整体映射进 BAR2 窗口"有关，
模型越大越吃紧。4B（约 4GB）与 9B（约 7GB）两个尺寸一起测，才能说明 16GB 窗口
对常见模型都够用，而不是刚好卡在某个尺寸上。

---

## 四、测吞吐时的现场状态

测 `bench/reports/` 那些数字时，同一台机器上还有 3 个推理服务在跑（rerank / ASR /
OCR，全部 `-ngl 99` 满载到 GPU），各占用一部分显存与算力。

因此：

- 报告里的**绝对值偏保守**，不代表这台机器的上限；
- 跨机器比较请看**同机比值**（如 SYCL/Vulkan 的 3.45×），那才是本项目的结论所在。

---

## 五、哪些条件必须满足，哪些可以不同

### 必须

| 条件 | 原因 |
|---|---|
| 内核 ≥ 6.12 且命令行带 `pci=realloc` | 更早的内核里 `pbus_reassign_bridge_resources()` 不会扩大上游桥窗口，改完 Control 也拿不到空间（`-ENOSPC`） |
| `pciutils`（`setpci` / `lspci`） | `setpci` 是唯一能在用户态写 PCI 配置空间的工具 |
| root | 写配置空间、写 sysfs 的 `remove` / `rescan` 都需要 |

### 可以不同

| 条件 | 影响 |
|---|---|
| 主板 / BIOS | 决定 BAR 档位上限多大（256 / 512 / 更大）与桥窗口初始多大 → **必须重新跑 `tools/gpu-topology.sh --plan`**，别抄本文的 BDF |
| CPU / 内存 | 只影响模型加载等非 GPU 侧动作，不影响 BAR 扩容本身 |
| Mesa 版本 | 只影响 Vulkan 后端的绝对吞吐，不影响 SYCL 能否用 |
| 显卡张数 | 单卡、双卡都支持；多卡必须用 `--gpu <BDF>` 指定，工具会拒绝自动猜 |
| 是否有 IPMI | 只影响操作习惯，不影响工具行为 |

---

## 六、这台机器特有的取值（**别抄**）

以下全部是 `tools/lib/topology.sh` 探测出来的结果，换机器必然不同：

| 项 | 本机值 | 怎么得到 |
|---|---|---|
| GPU BDF | `0000:04:00.0`、`0000:08:00.0` | `tools/gpu-topology.sh --plan` |
| 根端口 | `0000:00:02.0`、`0000:00:03.0` | 同上（沿 sysfs 祖先链上溯） |
| 卡内桥 | `8086:e2ff`（上游）/ `e2f0` / `e2f1` | `lspci -nn` |
| ReBAR ECAP 偏移 | `0x420` | 能力链表遍历，不写死 |
| 支持尺寸 | N=8..14（256MB ~ 16GB） | 读 Capability 寄存器 `0x0007f000` |
| 当前 Control | `0x00000e22`（BAR 索引 2，size=14 → 16GB） | `setpci -s <BDF> 0x420.l` |

工具里没有任何一处硬编码这些值 —— 这是刻意的，见 README 里那条
「探测层是唯一的"机器长什么样"来源」。

---

## 七、复现检查清单

拿到一台新机器，按这个顺序对齐：

```bash
# 1) 版本对照（对照本页第二节）
. /etc/os-release && echo "$PRETTY_NAME"
uname -r
cat /proc/cmdline | tr ' ' '\n' | grep pci=
setpci --version | head -1
dpkg -l mesa-vulkan-drivers | tail -1

# 2) 拓扑（这一步决定后面所有命令里的 BDF）
sudo tools/gpu-topology.sh --plan

# 3) 能力探测：确认卡支持 ReBAR、窗口现在多大
sudo ./b580-bar-tool.sh status
sudo ./b580-bar-tool.sh check

# 4) 演练：不改任何寄存器，只验 remove/rescan 通不通
sudo ./b580-bar-tool.sh rehearse --gpu <上一步给出的 BDF>
```

`rehearse` 通过之后才轮到 `apply`。版本若与本页差异较大（尤其内核 < 6.12、
或缺 `pci=realloc`），先补齐再动 Control。
