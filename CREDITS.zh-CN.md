# 理论依据与致谢

[English](CREDITS.md) | **简体中文**

> **中文是本项目的主语言**：脚本输出、日志、`docs/` 与本文都直接以中文写成，英文版是为国际读者
> 做的翻译。两版说法不一致时，**以中文版为准**。
> English readers: see [`CREDITS.md`](CREDITS.md) — the English file is a translation; the Chinese one governs.

本工具不是凭空发明的做法，它的每一步都站在公开规范、内核实现和前人的肩膀上。
这份文件把这些出处逐条列清，一是便于核对，二是把功劳记到该记的人名下。

---

## 一、最原始的规范出处：Resizable BAR 能力

本工具写入的那个寄存器，定义来自 PCI-SIG。

| 项 | 内容 |
|---|---|
| 规范名称 | **Resizable BAR Capability ECN** |
| 提出日期 | 2008-01-22 |
| 批准 | 2008-04-24 由 PCI-SIG 的 PWG（Protocol Working Group）更新并批准 |
| 正式载体 | 作为 ECN 并入 **PCI Express Base Specification Revision 2.1**（2009-03-04 发布）的 Revision History；其后 **Revision 3.0**（2010-11-10）亦包含 |
| 扩展能力 ID | **`0015h`**（Extended Capability ID） |
| 发布组织 | PCI-SIG，<https://pcisig.com> |

**为什么说它是"最原始"的出处**：PCIe Base 2.1 的修订历史里逐条列出了本版并入的 ECN，
其中一条原文就是

> Resizable BAR Capability ECN (January 22, 2008, updated and approved by PWG April 24, 2008)

也就是说，这个能力在 2008 年以 ECN 形式定稿，2009 年（2.1 版）正式进入规范正文，
2010 年（3.0 版）随 8.0 GT/s 一并重新发布。**在这份 ECN 之前，不存在 ReBAR 这个机制**。

该能力在配置空间里定义三个寄存器（偏移相对扩展能力头）：

| 偏移 | 名称 | 本项目如何用 |
|---|---|---|
| `+00h` | Extended Capability Header | 读 bit[31:20] 得到下一个能力的偏移，用于遍历能力链 |
| `+04h` | Capability Register | bit[N] 置位表示支持 `2^N` 字节的 BAR 尺寸 |
| `+08h` | Control Register | bits[13:8] = BAR 索引，bits[5:0] = 目标尺寸的 N 值 |

> 规范原文由 PCI-SIG 分发，非成员无法获取全文，因此这里引用 ECN 名称、批准日期与
> 载入版本，不复制正文。B580 实测该能力位于 `0x420`，`Capability = 0007f000`
> 表示支持 N=8..14（256MB … 16GB）。

## 二、这个方法是谁先发现的

这一节要单独写，因为"把设备 remove 掉、让内核重新枚举"这个动作**不是从规范里读出来的** ——
规范只定义了 ReBAR 寄存器怎么改，没说改完之后怎么让内核接受新尺寸。这一步是有人先试出来、
再被 Intel 的内核工程师从机制上解释清楚。三方接力，缺一不可。

### 2.1 第一棒：andersevenrud（最早公开这个方法的人）

| 项 | 内容 |
|---|---|
| 公开形式 | GitHub Gist |
| 地址 | <https://gist.github.com/andersevenrud/eec93e9151117bc0d6b6133b40eaffa5> |
| 标题 | *Resizable BAR on SuperMicro H11SSL-I with Intel Arc B580* |
| 硬件 | Supermicro H11SSL-i + Intel Arc B580 |
| 贡献 | **首次公开**「`setpci` 写 ReBAR Control → `remove` 根端口 → `rescan`」这组动作，并证明它能把 256MB 窗口撑到 16GB |

这是整条工作流的起点。在它之前，公开资料里只有"刷固件改 BIОS"（ReBarUEFI）一条路，
而那条路要求改固件、有变砖风险。

### 2.2 第二棒：Intel 内核工程师解释了"为什么必须把整张卡移除"

andersevenrud 给出了"怎么做"，但没有说清"为什么非得把设备 remove 掉"。答案来自 Intel 的 PCI 维护者：

| 贡献者 | 产出 | 关键内容 |
|---|---|---|
| **Ilpo Järvinen** | `[PATCH] PCI: Release unused bridge resources during resize`（2024-05-13，linux-pci） | 用 DG2 / Arc A380 的真实拓扑说明：**卡内桥自己的 BAR0 占住了根端口窗口的一段**，于是 GPU 的 BAR2 扩不上去，报 `-ENOSPC` |
| **Ilpo Järvinen** | `[PATCH 14/24] PCI: Warn if bridge window cannot be released when resizing BAR`（2025-08-22） | 在 `pbus_reassign_bridge_resources()` 里加了那句 **`was not released (still contains assigned resources)`** 警告 |
| **Ilpo Järvinen** / **Lucas De Marchi** | `[PATCH 1/2] PCI: Release BAR0 of an integrated bridge to allow GPU BAR resize`（2025-09-18，intel-xe） | 针对 `0x4fa0`、`0x4fa1`、**`0xe2ff`（B580 的卡内桥就是它）** 加 quirk，主动释放桥 BAR0；标记 `Cc: # v6.12+` |
| **Ilpo Järvinen** | 2026-04-15 在 linux-kernel 的回复 | 给出明确的手工路径：*"It may be possible to manually remove the siblings first, resize the eGPU's BAR through sysfs, and finally rescan."* |

**最后那句是本项目最直接的方法论依据。** Intel 的 PCI 维护者自己承认：兄弟设备挡住了窗口，
你可以先手工移除它们、用 sysfs 改 BAR、最后 rescan。本项目做的事，就是把这套手工动作自动化，
并加上"别误伤别人"的安全边界。

顺带解释一个现象：**为什么 dmesg 里能看到 `was not released`。**
这条警告本身就是 Ilpo 那组补丁在 2025 年才加进内核的诊断信息。
看到它就等于确认"窗口被别的东西钉住了"—— 这不是我们的发明，是内核给的新线索。

### 2.3 第三棒：RodBurlamaqui 把它做成了完整工具

| 项 | 内容 |
|---|---|
| 项目 | [`RodBurlamaqui/Intel-ARC-Rebar`](https://github.com/RodBurlamaqui/Intel-ARC-Rebar)（命令名 `arc-rebar`） |
| 形态 | initramfs 启动期 POSIX sh + Debian 打包，开机时自动执行 |
| 许可证 | **非开源**：个人使用免费，商用/机构使用需单独授权，禁止衍生（协议 §3.1 / §3.2 / §9） |
| 对前人的致谢 | 其 README「Credits」明写 *"andersevenrud — the setpci + remove/rescan method, in a gist for the H11SSL-i + B580"* |
| 与本项目的关系 | 见 [`CLEANROOM.md`](CLEANROOM.md) §3：只读过其 `README` / `DISCLAIMER` / `INSTALL` / `LICENSE` / `live-test.sh`（6 行）/ `diagnose` 输出，**未接触核心实现脚本**；因其协议 §1.1 排除机构使用、§3.2 禁止修改，判定不可用，遂独立实现 |

它的 LICENSE §4.2 有一段对后来者很有价值的话（大意）：**协议只覆盖其自身实现**
（代码、脚本、检测与安全逻辑、打包、文档），**不主张"写 ReBAR Control 寄存器 + 重新枚举根端口"
这个底层方法本身的权利，并指明该方法最早由 andersevenrud 公开。**

也就是说：方法归方法，实现归实现。我们用的是方法，写的是自己的实现 —— 这正是 `CLEANROOM.md` 的立场。

### 2.4 同一路线上最近的邻作：Emvo10 的 B580 专用工具

| 项 | 内容 |
|---|---|
| 项目 | [`Emvo10/Intel-Arc-B580-ReBar`](https://github.com/Emvo10/Intel-Arc-B580-ReBar)（原名 `b580-rebar-linux`，旧地址会 302 到现名） |
| 公开时间 | **2026-09-05**创建，2026-09-11 最后更新 —— **比本项目早约 7 周** |
| 目标机器 | Intel Arc B580 12GB（`8086:e20b`），**与本项目完全同一款卡** |
| 形态 | POSIX sh 主脚本（`b580-rebar`）+ `install.sh` / `uninstall.sh` + systemd 服务，开机时自动执行 |
| 方法 | 与本项目同路：`setpci` 改 ReBAR Control → `remove` 上游根端口 → `rescan`，同样要求内核 `pci=realloc` |
| 许可证 | **无**（仓库无 LICENSE 文件）。公开可见不等于开源 —— 按默认著作权保留所有权利处理，因此本项目**只读其 README，未阅读也未参考其脚本实现** |
| 对前人的致谢 | README「Credits」明写 *"based on the Linux B580 `setpci` + PCI remove/rescan method documented by Anders Evenrud for the Supermicro H11SSL-i"*，并附同一个 gist 链接 |

**为什么必须单列一节把它记下来**：在 B580 这一款卡上，它是目前能找到的、**时间最早、目标机器与本项目完全重合**的公开实现。两者的结论独立收敛到同一套动作
（`setpci` 写 Control → remove → rescan → 验证），这说明那条路不是某个人的巧合，而是这张卡在旧平台上的必然解法。
它还是 "andersevenrud 的 gist 可以被工程化" 的第二个独立证据 —— 与本仓库的结论互为印证。

它与本项目的差别，如实记录：

| 维度 | Emvo10 | 本项目 |
|---|---|---|
| 面向场景 | 桌面游戏（Bazzite / Fedora / rpm-ostree 生态），目标是让 LACT 显示完整的 CPU 可访问显存 | headless 服务器的 SYCL 推理，目标是让 SYCL 能分配显存（512MB 下会 SIGBUS） |
| 生效时机 | 开机时 systemd 服务，装好即长期生效 | 默认运行时手动执行，`tools/rebar-autofix.sh` 是可选的开机 oneshot |
| 共享根端口 | **默认拒绝**：分支里若含 NVMe / 网络 / USB 就中止，不冒险 | **两种行为并存**：`tools/rebar-batch.sh` 用 `topo_anchor()` 把锚点自动**降级到卡内桥、绝不越界**（比拒绝更精细，仍能在共享根端口上尝试）；但单卡脚本的 `apply` **不复用** `check` 的这条判断，会照旧解绑子树内非桥设备后 remove 根端口 —— 这是缺陷，见下 |
| 工具面 | 单卡、一次性安装/卸载，聚焦"装完能玩" | `status` / `gpu` / `check` / `plan` / `rehearse` / `apply` / `restore` 七个子命令，含演练、回滚、双卡、批量、看门狗 |
| 多卡 | 不涉及 | 双卡独立根端口、批量脚本 |

> 上面「共享根端口」这一行要分开看，不宜笼统说谁更好：
> - **它的拒绝策略**在陌生主板上最保守，代价是共享根端口时完全用不了；
> - **本项目的批量脚本**是三者中粒度最细的 —— 不拒绝，而是把 remove 的范围缩小到"子树里只剩自己人"的那一级，越界风险为零；
> - **本项目的单卡脚本**是三者中最弱的 —— `check` 明明已经能识别"根端口下存在非本卡设备"并报 `ERROR`，`apply` 却没把这个判断接上。这条已按 **P1** 记入 [`NEXT.md`](NEXT.md)，修法就是让单卡脚本复用批量脚本那套锚点逻辑。

### 2.5 为什么这条路今天仍然必要

| 事实 | 出处 |
|---|---|
| 针对 `0xe2ff`（B580 卡内桥）的 quirk 尚未进入主线 | `[PATCH 1/2]` 作者自评 *"this feels quite hacky to me"*，属临时方案；据第三方报道该 quirk 仍在 review |
| 本机内核 `7.0.0-38-generic` + `pci=realloc`，开机 BAR2 依然是 512MB | 本仓库 `README.zh-CN.md`「实测结论」、`NEXT.md` |
| 内核 `pci_resize_resource()` 只在现有桥窗口内找空间 | xe 驱动两次 `-ENOSPC` 的实测日志 |

结论：**在 Intel 的 quirk 合入主线、或"资源分配算法考虑 ReBAR 最大尺寸"落地之前，
"手工移除 + rescan" 仍是唯一不需要刷固件的办法。**

## 三、Linux 内核侧的依据

本工具做的三件事 —— 读扩展能力、改 BAR 尺寸、让内核重新枚举 —— 各有一条内核实现作依据。

### 3.1 遍历扩展能力链

`drivers/pci/pci.c` 的 `pci_find_ext_capability()`。内核用「从 `0x100` 开始，
按 header 的 next pointer 逐跳前进」的方式找能力，本项目沿用同一逻辑，
因此**不需要写死 `0x420`** —— 换一张卡、换一代芯片也能找到。

### 3.2 让内核重排资源：`pci=realloc`

| 贡献者 | 提交 | 内容 |
|---|---|---|
| **Ram Pai**（IBM） | 2011-06-30，`[PATCH] PCI: conditional resource-reallocation through kernel parameter pci=realloc` | 引入 `pci=realloc`，允许在 BIOS 分配不足时由内核重新分配 PCI 资源 |
| **Yinghai Lu** | 2012-02-01，`[PATCH 5/7] PCI: Make pci bridge reallocating enabled/disabled` | 拆成 `pci=realloc=on` / `pci=realloc=off` |

讨论存档：<https://lore.kernel.org/linux-pci/1328136170-17613-6-git-send-email-yinghai@kernel.org/>

这两个补丁的背景值得一说：当时动态重分配一直有回归问题，Ram Pai 的补丁其实是
「**先默认关掉，需要的人自己开**」的临时妥协。这就是为什么很多机器上必须显式写
`pci=realloc` 才生效 —— 本项目的目标机器（`/proc/cmdline` 含 `pci=realloc`，
内核 `7.0.0-38-generic`）属于已经显式开启的情形。

### 3.3 内核自己"原地扩"为什么不够

内核有 `pci_resize_resource()`，但它**只在现有桥窗口内找空间**，不会去扩大上游桥的窗口。
实测报错就是这条：

```
xe: BAR 2 [mem size 0x400000000 64bit pref]: can't assign; no space
xe: Failed to resize BAR2 to 16384MiB (-ENOSPC). Consider enabling 'Resizable BAR' support in your BIOS
```

> 顺带纠一个流行说法：ReBarUEFI 的 FAQ 提到「较新版 Linux 会自动 resize 并分配 GPU BAR」。
> 在**本项目的目标机器上这件事没有发生** —— 内核 7.0 + `pci=realloc`，开机 BAR2 依然是 512MB，
> xe 驱动自己试了两次都失败。原因是根端口 prefetch 窗口只有 520MB，而
> `pci_resize_resource()` 不会去动它。**这正是本项目存在的理由。**

本项目改走另一条路：先写 Control 寄存器把尺寸字段定下来，再 remove 桥 + rescan，
由 `pbus_reassign_bridge_resources`（`drivers/pci/setup-bus.c`）重排并**扩大**桥窗口。
实测根端口窗口 520MB → 16392MB，BAR2 512MB → 16384MB。

### 3.4 移除与重扫：sysfs 接口

依据 `Documentation/ABI/testing/sysfs-bus-pci`：

| 接口 | 引入 | 官方描述 |
|---|---|---|
| `/sys/bus/pci/devices/.../remove` | 2009-01 | 写入非零值会热移除该 PCI 设备**及其全部子设备** |
| `/sys/bus/pci/devices/.../rescan` | 2009-01（**Alex Chiang** 引入） | 写入非零值强制重扫设备的父总线与所有子总线，重新发现此前被移除的设备 |
| `/sys/bus/pci/devices/.../pci_bus/.../rescan` | 2011-05 | 同上，作用域为该总线及其子总线 |

`remove` 那句「及其全部子设备」是本项目所有安全设计的出发点：**移除哪个设备，就决定了
风险的作用域**。因此工具不按固定 BDF 操作，而是先探测出一个"子树里只剩自己人"的锚点，
再动它（见 `README.zh-CN.md`「多卡为什么需要锚点分组」）。

## 四、Intel 官方对 Arc + ReBAR 的表态

| 来源 | 原文要点 |
|---|---|
| [Intel 支持文章 000091128《英特尔® Arc™ 显卡 – 台式机快速入门指南》](https://www.intel.com/content/www/cn/zh/support/articles/000091128/graphics/intel-arc-dedicated-graphics-family.html) | 「**必须启用 Resizable BAR 或 Smart Access Memory**，以便使用英特尔 Arc A 系列显卡在所有应用程序中实现最佳性能。」 |
| Intel 社区（Robert Q.，2022-11-25） | 「Arc 显卡**可以**在没有 ReBAR 的系统上工作……但性能会显著受影响。」 |
| Intel Gaming《Resizable BAR on Intel Arc Graphics》 | ReBAR 让「源自 CPU、目标为显存的事务」变大；没有它时内存控制器会被大量小事务淹没 |

后两条比第一条更精确：**Arc 不是"不亮"，是"性能显著下降"**。而 SYCL/oneAPI 这条路径更严格 ——
它需要的不是带宽而是**可映射的窗口** —— 分配长度与模型占用量同数量级（本仓库实测的
4B Q8_0 约 4GB、9B Q6_K 约 7GB），512MB 窗口连最小的都放不下，分配直接失败（表现为 SIGBUS）。
这是"必须扩窗"和"扩窗更快"两件事的分界线。

## 五、同类项目：我们做了什么、别人做了什么

| 项目 | 层次 | 与本项目的关系 |
|---|---|---|
| **[xCuri0/ReBarUEFI](https://github.com/xCuri0/ReBarUEFI)**（MIT） | **固件层**（UEFI DXE 驱动） | 替换 `PciHostBridgeResourceAllocationProtocol` 的 `PreprocessController`，在**每次开机枚举时**就把 BAR 设大。适用于"想一劳永逸、且敢刷固件"的人。本项目处在 **OS 层**（运行时改 + 重扫），不动固件、可随时回退，两者互补而非替代 |
| **ReBarState**（同仓库内） | 用户态配置工具 | 设置 ReBarUEFI 想要的 BAR 大小，写入 NVRAM 变量。与本项目的 `apply --size N` 目标相同，但作用对象是固件而非运行中的内核 |
| **NvStrapsReBar** | 固件层（NVIDIA Turing） | 同类思路的 NVIDIA 版本，本项目不涉及 |
| **[RodBurlamaqui/Intel-ARC-Rebar](https://github.com/RodBurlamaqui/Intel-ARC-Rebar)**（`arc-rebar`，非开源） | **OS 层**（initramfs 启动期） | 与本项目层次最接近：同样不动固件、同样用写寄存器 + remove/rescan。差别在**生效时机**（它开机早期、我们运行时）和**持久化**（它装 hook 每次开机生效、我们不写任何持久配置）。详见上文第二节 2.3 |
| **[Emvo10/Intel-Arc-B580-ReBar](https://github.com/Emvo10/Intel-Arc-B580-ReBar)**（无许可证） | **OS 层**（systemd 开机服务） | **同款卡（B580 `8086:e20b`）、同一套动作、比本项目早约 7 周** —— 是本项目最近的一件邻作。差别在场景（桌面游戏 vs headless 推理）、共享根端口策略（它默认拒绝、我们解绑后继续）与工具面。详见上文第二节 2.4 |
| **[pciutils](https://github.com/pciutils/pciutils)** | 用户态工具 | 本项目依赖其 `setpci` 读写配置空间、`lspci` 展示链路状态。没有它这个工具写不出来 |

**特别感谢四位（按接力顺序；第四位与本项目并列同一款卡）：**

1. **andersevenrud** —— 他是第一个把「写 ReBAR 寄存器 + 移除根端口 + rescan」这条路公开出来的人
   （H11SSL-i + B580 的 gist）。没有这一步，本项目无从谈起。
2. **Ilpo Järvinen、Lucas De Marchi（Intel）** —— 他们从内核角度解释了"为什么必须移除整张卡"
   （卡内桥的 BAR0 钉住了根端口窗口），并把 `was not released` 这条诊断警告加进内核。
   **Ilpo Järvinen 还明确写出了手工解决路径**，本项目的技术路线就是照着那句话走的。
3. **xCuri0** —— ReBarUEFI 把「厂商说 BIOS 不支持 ≠ 硅片做不到」这层窗户纸捅破了，
   并在 README 里写下 *"even required for Intel Arc GPUs to function optimally"* ——
   这句话是本项目立项时最重要的旁证之一。
4. **Emvo10** —— 在**同一款 B580、同一套 `setpci` + remove/rescan 动作**上，他比本项目早约 7 周
   把它做成了可安装的 systemd 服务。本项目在动手之前并不知道这个仓库的存在，事后核对发现
   两条独立路线收敛到同一组动作 —— 这本身就是对"这条路是对的"最有力的旁证，
   而"已经有人先做出来了"这件事，值得被记在名字上。

> **独立实现声明**：本项目未复制上述任何项目的代码，与第三方的接触记录见 [`CLEANROOM.md`](CLEANROOM.md)。
> 致谢是针对**思想与方法**，不是代码来源。方法本身不受著作权保护（见 `CLEANROOM.md` §5），
> 但把方法第一个说出来的人，值得被记住名字。

## 六、推理与测量侧（bench 部分依赖）

| 项目 | 用途 |
|---|---|
| [llama.cpp](https://github.com/ggml-org/llama.cpp)（ggml） | `llama-bench` 基准、SYCL / Vulkan 后端。`bench/` 下所有脚本都靠它 |
| [Intel oneAPI DPC++](https://github.com/intel/llvm) + [Level Zero](https://github.com/oneapi-src/level-zero) + [UMF](https://github.com/oneapi-src/unified-memory-framework) | SYCL 运行时。`libumf.so.1` 缺失会让 L0 适配器静默消失，这个坑记在 `NEXT.md` |
| [Mesa](https://gitlab.freedesktop.org/mesa/mesa) | Intel Vulkan 驱动（ANV）。Vulkan 对比数据全部来自它 |
| 社区维护的 ollama SYCL 构建 | 用于核对"ollama 官方二进制不含 SYCL"这一事实。仅作事实参考，未使用其代码 |

## 七、公开前的独立审核

本仓库在公开前做过两轮互相隔离的静态代码审核。每轮都是**多个独立席位只读源码、
不参考彼此结论**，且被明确禁止阅读 `docs/reviews/` 下的历史结论 —— 否则就变成互相抄作业。

### 第一轮（针对 v1.1.0，原始报告已归档）

| 席位 | 模型 | 产物 |
|---|---|---|
| A | `hy4-preview`（腾讯混元） | [`hy4-preview.md`](docs/reviews/hy4-preview.md)（24 KB，25 个缺陷） |
| B | `glm-5.3-flash`（智谱） | [`glm-5.3-flash.md`](docs/reviews/glm-5.3-flash.md)（17 KB，9 项冗余 + 缺陷） |
| C | `space-bunny`（MiniMax M3.1 Flash 匿名预览版） | **未产出**，上游链路 502，无结论 |

这一轮抓出 5 处经核对成立的高危缺陷（假幂等成功、回滚判据错误、解绑失败后仍移除桥、
空参数枚举整机、回滚默认值比原始更小），并留下 2 条**两席结论相反、经实测定案**的争议。

### 第二轮（针对引入拓扑探测层后的版本，汇总见 [`round2-2026-10-28.md`](docs/reviews/round2-2026-10-28.md)）

| 席位 | 模型 | 产物 |
|---|---|---|
| A | `hy4-preview` | 结论已并入汇总 |
| B | `mimo-v2.6-pro`（小米） | 结论已并入汇总 |
| C | `glm-5.3-flash` | 结论已并入汇总 |

本轮针对的是"去掉写死 BDF / ECAP 偏移"之后的重构版本，重点在失败路径与自愈链路。
三席的原始输出未逐字归档，但**结论、交叉验证结果、未采纳的意见**都记在汇总里 ——
包括我认为三席判偏的地方（例如"误伤其他 PCIe 设备"其实不是这套代码的弱点）。

> 为什么要归档"未采纳的结论"：审核的价值不只在挑出几个 bug，更在于留下
> "当时有哪些反对意见、为什么没采纳"。后来的维护者可以据此推翻我们。

## 八、引用

本项目采用 MIT 许可证，使用、修改、商用均无需事先许可，**保留版权与许可声明即可**
（见 [`LICENSE`](LICENSE)）。

如果你在文章、报告或产品里用到它，欢迎顺带提一句仓库地址 —— 不是许可要求，是让下一个人
搜得到。同样地，如果你在这个基础上改进了探测逻辑或踩到新的坑，欢迎提 issue 或 PR，
那份功劳会记在提交历史里。
