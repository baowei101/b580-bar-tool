# Glossary / 术语对照表

> 本文件定义中英两版文档里所有关键术语的**唯一译法**。翻译前先查这里，不要临时造词。
> 新增术语请追加到对应分组，不要另起一套。
>
> This file fixes the **only** accepted translation for each term used across the Chinese
> and English documents. Check here before translating; do not invent synonyms.

---

## 1. 为什么需要这张表 / Why this exists

同一个中文词在不同段落被译成三个英文词，读者会以为是三件不同的事。例如：

- 「窗口」既可能指 **BAR 本身能占的地址范围**（aperture），也可能指 **上游桥分配给下游的地址范围**（bridge window）。这两者在本文档里必须分开，因为整个工具做的事就是"把桥窗口扩到能装下 BAR"。
- 「移除」既可能是 sysfs 的 `remove` 操作，也可能泛指"拔掉设备"。前者必须译作 `remove` 并保持代码字体。

---

## 2. PCIe / 硬件层

| 中文 | English | 备注 |
|---|---|---|
| 可调整 BAR / ReBAR | Resizable BAR (ReBAR) | 首次出现写全称，之后只用 `ReBAR` |
| BAR | BAR (Base Address Register) | 首次出现给全称 |
| BAR2 窗口 / BAR 2 孔径 | BAR2 aperture | 指 GPU 自身 BAR 能覆盖的地址范围，**译 aperture** |
| 桥窗口 | bridge window | 指上游桥分配给下游总线的地址范围，**译 window** |
| 根端口 | root port | 不译 `root complex port` |
| 上游桥 | upstream bridge | |
| 卡内桥 | on-card bridge | Intel Arc 卡内集成的 PCIe switch，如 B580 的 `8086:e2ff` |
| 子树 | subtree | |
| 叶子设备 | leaf device | 指子树末端、不再有下游的设备 |
| 能力链 / 扩展能力链 | capability chain / extended capability chain | |
| 扩展能力（ECAP） | extended capability (ECAP) | |
| 偏移 | offset | |
| 档位 / 尺寸档 | size step | 指 `N` 值，如 `N=8..14`；不说 `level` |
| 幂次 / N 值 | exponent / `N` | 尺寸字段收的是 2 的幂次，`字节数 = 2^(N+20)`；`N=14` 即 16GB。**不译成 power index**，英文侧统一写 `N` 或 `exponent` |
| 重新枚举 | re-enumerate / re-enumeration | |
| 全量重新枚举 | full re-enumeration | |
| 解绑 | unbind | sysfs 操作，保持代码字体 |
| 重绑 | rebind | |
| 移除（设备） | remove | sysfs 操作，保持代码字体 |
| 重扫 | rescan | sysfs 操作，保持代码字体 |
| 显存 | VRAM | |
| CPU 可访问显存 | CPU-accessible VRAM | |
| 统一共享内存（USM） | Unified Shared Memory (USM) | SYCL 概念 |
| 链路速率 | link speed | |
| 链路宽度 | link width | |

---

## 3. 本项目自造概念（译法已定，不要改）

| 中文 | English | 定义 |
|---|---|---|
| **安全锚点** / 锚点 | **safe anchor** / anchor | 从目标设备往上找到的、**最高一级"子树里只剩自己人"**的祖先桥。`remove` 它不会误伤别人的设备。它通常等于根端口，但代码不假设这点 —— 根端口下若挂 NVMe/网卡，锚点会自动降级到卡内桥。 |
| **演练** | **rehearsal**（命令名 `rehearse`） | 完整走一遍 `unbind → remove → rescan → 验证 → 重绑`，但**不写 ReBAR 寄存器**。用于证明"这条路径在这台机器上不会挂死"。**不要译成 `dry run`** —— 它真的会移除设备，只是不改寄存器。 |
| 回滚 | rollback | 把 Control 写回原值并重新枚举 |
| 只读自检 | read-only check（命令名 `check`） | 不改任何状态 |
| 自愈 | self-healing（脚本名 `rebar-autofix`） | 开机 oneshot 检测并恢复；默认**不** enable |
| 执行计划 | execution plan（命令名 `plan`） | 打印将要做的每一步，不做修改 |
| 幂等 | idempotent | |
| 残留检测 | leftover detection | 检测"消失了但没回来"的子树 |

---

## 4. 测量与推理

| 中文 | English | 备注 |
|---|---|---|
| 预填充 / prefill | prefill (`pp`) | `pp4096` = 4096 token 的 prefill |
| 解码 / 生成 | decode / token generation (`tg`) | |
| 吞吐 | throughput | 单位 `t/s` 不用改 |
| 基准 / 实测 | benchmark / measurement | 「实测」强调真实硬件，译 `measured`，不译 `estimated` |
| 双卡 | dual-GPU | |
| 单卡 | single-GPU | |
| 并行损耗 | parallel-efficiency loss | |
| 后端 | backend | SYCL / Vulkan |

---

## 5. 工程与流程

| 中文 | English | 备注 |
|---|---|---|
| 洁净室 | clean room | 指独立实现方法，不译 `cleanroom` 时保持一致即可 |
| 独立实现 | independent implementation | |
| 接触范围披露 | disclosure of exposure | 指"读过对方哪些材料" |
| 可复现自检 | reproducible self-check | |
| 未修清单 | known-unfixed list | |
| 待办 | TODO | |
| 真机验证 | on-hardware verification | |
| 评审 / 交叉评审 | review / cross-review | |
| 三席 | three reviewers | 指三个不同模型各出一份独立报告 |
| 致谢 | credits / acknowledgements | |
| 规范 | specification | |
| 公开出处 | public provenance | |

---

## 6. 翻译约定 / Conventions

> **翻译方向固定：中文 → 英文。** 中文是本项目的主语言，中文稿是原文，英文稿是译文。新增或修订
> 内容一律先写中文、再据中文译出；**不允许只改英文侧** —— 那样中文就不再是权威版本了。

1. **代码、命令、路径、寄存器名一律不译**，并用反引号包裹：`setpci`、`/sys/bus/pci/rescan`、`0x420`、`pci=realloc`。
2. **数字与单位原样保留**：`16384MB`、`520MB → 16392MB`、`4004 t/s`、`7.08 GB/s`。不要换算成 GiB 或其它单位。
3. **产品名与型号**：`Intel Arc B580`、`Supermicro X10DAL-i`、`Ubuntu 24.04.5 LTS` 原样。
4. **厂商名不加冠词**：写 `Intel`、`Supermicro`，不写 `the Intel`。
5. **命令示例块不翻译注释以外的内容**；注释可以译，命令本身逐字节保留。
6. **标题编号保持一致**：中文 `## 一、` 对应英文 `## 1.`，层级与顺序必须一一对应（漂移检查脚本只比对二级标题数量，所以顺序也要对）。
7. **语气**：英文版用直陈式、短句，不用 `we would like to`、`it should be noted that` 这类填充语。中文版的"务必""一定要"在英文里用 `must`，不用 `please make sure to`。
8. **法律措辞**：`DISCLAIMER` 里的担保免责按 MIT 原文用 `AS IS`、`WITHOUT WARRANTY OF ANY KIND`，不要自行改写。

---

## 7. 已知易错点 / Common traps

| 容易译错 | 正确 | 原因 |
|---|---|---|
| 窗口 → `window`（全部） | BAR2 **aperture** / bridge **window** | 两者是不同对象，混用会让"扩窗"这个核心动作讲不清 |
| 演练 → `dry run` | **`rehearsal`** | 它会真的 remove 设备，`dry run` 会让人以为完全无副作用 |
| 移除 → `unplug` / `detach` | **`remove`** | 特指 sysfs 的 `remove` 写操作 |
| 档位 → `level` | **`size step`** | 指 ReBAR 的 `N` 值序列 |
| 实测 → `estimated` | **`measured`** | 全部来自真实硬件 |
| 锚点 → `anchor point` | **`anchor`** | 项目内固定术语 |
