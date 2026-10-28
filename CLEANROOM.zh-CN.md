# 独立实现声明（Clean Room Statement）

[English](CLEANROOM.md) | **简体中文**

> **中文是本项目的主语言**：脚本输出、日志、`docs/` 与本文都直接以中文写成，英文版是为国际读者
> 做的翻译。两版说法不一致时，**以中文版为准**。
> English readers: see [`CLEANROOM.md`](CLEANROOM.md) — the English file is a translation; the Chinese one governs.

本文档用于说明本仓库 `b580-bar-tool` 的来源、技术依据与开发过程，供审阅者核查。

**与 [`CREDITS.md`](CREDITS.md) 的分工**：本文证明"代码不是抄的"；CREDITS 说明"方法和思想来自谁"、
以及为什么要把功劳记在他们名下。两者不冲突 —— 致谢第三方不等于使用其代码，反之亦然。

---

## 1. 结论

本仓库全部代码为独立实现，**不包含、不衍生自任何第三方同类项目的代码、脚本或文档**。

本项目与公开的第三方同类项目的共同点仅限于**公开的技术方法**：向 PCIe Resizable BAR 扩展能力（ECAP ID `0x0015`）的 Control 寄存器写入 BAR 尺寸，并重新枚举 PCIe 根端口。该方法的公开性由三方共同确认：

1. **PCI-SIG 规范**：Resizable BAR 扩展能力的寄存器布局与操作语义由 PCI-SIG 公开规范定义
2. **Linux 内核公开 ABI**：`/sys/bus/pci/devices/*/remove`、`/sys/bus/pci/rescan` 是内核对外暴露的标准接口
3. **第三方项目作者本人**：其 LICENSE §4.2 明文说明该方法属公开知识、不受其协议约束（见 §4）

---

## 2. 技术依据

实现所依据的全部信息来源，均为公开规范或本机实测：

| 依据 | 具体内容 |
|---|---|
| PCI-SIG | ECAP ID `0x0015`；Capability 寄存器 `bit(4+N)` 表示支持 `2^(N+20)`；Control 寄存器 `bits[2:0]` = BAR 索引、`bits[13:8]` = size 字段 |
| Linux 内核文档与 ABI | `pci=realloc` 内核参数语义；`/sys/bus/pci/devices/<BDF>/remove` 移除设备；`/sys/bus/pci/rescan` 触发重新枚举；`/sys/bus/pci/drivers/<drv>/{bind,unbind}` 驱动绑定控制 |
| 本机实测 | ECAP 实际位于偏移 `0x420`；Capability 实测值 `0x0007f000`；Control 实测值 `0x00000922`；根端口窗口与 MMIO 布局；以上均通过 `setpci` / `lspci` / sysfs 读取核对 |

**脚本中没有任何硬编码的第三方项目常量。** 唯一的固定偏移 `ECAP_HINT = 0x420` 来自本机 `setpci` dump 实测结果，且脚本仍会校验 ECAP ID，若校验失败则遍历配置空间 `0x100-0xFFC` 兜底查找。

---

## 3. 接触范围披露

开发过程中，实现方接触过的第三方项目材料如下（如实列全）：

| 接触对象 | 内容 | 是否进入本实现 |
|---|---|---|
| `README.md` | 项目功能描述、硬件兼容性、风险声明 | 否（仅用于评估风险） |
| `DISCLAIMER.md` | 免责声明、失败模式说明 | 否（仅用于评估风险） |
| `INSTALL.md` | 安装流程、排障步骤 | 否（仅用于评估风险） |
| `LICENSE` | 许可协议全文 | 否（仅用于合规分析） |
| `live-test.sh` | **共 6 行**，内容为：停止 display-manager → 调用主流程脚本 → 启动 display-manager | **否**，见下 |
| `diagnose` 命令输出 | 一次性只读诊断的终端输出文本 | 否（仅用于判断可行性） |

**未接触**的部分：核心实现脚本（`scripts/init-premount/` 下的主流程）、检测与安全逻辑、打包脚本、initramfs hook 实现。

### 关于那 6 行 `live-test.sh`

其全部行为是"停 display-manager → 调主流程 → 起 display-manager"。可以在本仓库验证：**这三件事一件都不存在**。

```bash
grep -niE "display-manager|gdm|lightdm|sddm" b580-bar-tool.sh     # 无匹配
grep -nE "^\s*(source|\.)\s|exec "           b580-bar-tool.sh     # 无匹配（单文件内函数调用，无子脚本架构）
```

原因很直接：目标服务器是全 headless，7 个显示口全部 `disconnected`，根本不需要停 display-manager；本项目采用单文件内函数调用，不存在"主脚本调子脚本"的架构。

### 发布前调研才接触的第二个同类项目

2026-10-28 准备开源、补全致谢时，检索 GitHub 上的同类项目，才发现
[`Emvo10/Intel-Arc-B580-ReBar`](https://github.com/Emvo10/Intel-Arc-B580-ReBar)
（B580 专用、2026-09-05 公开、比本项目早约 7 周）。**实现期间并不知道它的存在** ——
接触发生在全部代码已提交之后（时间线见 §7）。

| 项 | 情况 |
|---|---|
| 接触时间 | 2026-10-28，**发布前**调研，实现已冻结 |
| 已读 | 仅 `README.md`（公开文档：功能描述、8 步流程、共享根端口时拒绝的安全策略、致谢段） |
| 未读 | `b580-rebar` 主脚本（7046 字节）、`install.sh`、`uninstall.sh`、`b580-rebar.service` |
| 是否进入本实现 | **否** —— 接触时实现与全部提交已完成，仅用于补致谢与对比表 |
| 许可证 | **无 LICENSE 文件**。按"保留所有权利"处理，因此刻意只读 README，不读实现 |

之所以不读代码：它没有声明任何许可，读代码对本项目没有价值（实现早已独立完成），
只会给洁净室引入不必要的争议。README 已足够支撑致谢与差异对比（见 [`CREDITS.md`](CREDITS.md) 第二节 2.4）。

---

## 4. 与第三方实现的路线差异

这是比"代码不同"更强的一点：两者的**技术路线本身不同**，不只是写法不同。

| 维度 | 第三方项目 | 本项目 |
|---|---|---|
| 生效时机 | initramfs 启动早期，GPU 尚未被驱动占用 | 系统运行中，主动 unbind 驱动后操作 |
| 持久化 | 安装 hook、写入 initramfs，重启后长期生效 | **不写任何持久配置**，一次性生效，重启即还原 |
| 回退方式 | 内核参数 `norebar` 绕过 hook | 直接重启（配置空间由 BIOS 重置） |
| 代码形态 | 多脚本 + initramfs hook | 单文件 bash，无外部依赖 |
| 主要工程难点 | initramfs 环境下工具缺失 | 运行中移除设备的 DMA 安全（本实现以 `fuser` 强制探测 + 前置拒绝应对） |

第三方项目选择启动早期动手以避免驱动抢占设备；本项目选择运行时操作，并在目标硬件上以演练实测验证可行性。

---

## 5. 法律依据

### 5.1 《计算机软件保护条例》第六条

> 本条例对软件著作权的保护不延及开发软件所用的**思想、处理过程、操作方法**或者数学概念等。

向 ECAP Control 寄存器写 BAR 尺寸、移除并重枚举根端口，属于**操作方法 / 处理过程**，不在著作权保护范围内。

### 5.2 第三方项目 LICENSE §4.2（作者自述）

> Nothing in this Agreement grants or claims any rights in the underlying technical method of programming the PCI Express Resizable BAR control register and re-enumerating a PCI Express root port, **which is publicly known** and was first documented by andersevenrud. This Agreement applies to the Licensor's implementation: all of the Software's code, scripts, detection and safety logic, packaging, and documentation are the Licensor's original work.

作者明确承认：技术方法属公开知识、协议不主张任何权利；协议仅覆盖其**具体实现**（代码、脚本、检测与安全逻辑、打包、文档）。

**本项目未使用其软件的任何部分，因此不适用该协议，也不构成其 §1.1 定义的任何形式使用。**

---

## 6. 关于"操作序列相似"的说明

若有人逐行比对两份实现，会观察到以下相似：

- 解绑终端设备驱动
- 写入 ReBAR Control 寄存器
- 移除 PCIe 根端口
- 触发 rescan
- 校验 BAR 尺寸，不符则回滚

**该序列没有第二种写法**，原因是硬性约束：

1. PCIe 规范要求修改 BAR 尺寸时设备不得处于活动状态 → 必须先解绑驱动
2. Linux 内核重新枚举设备的唯一用户态入口是 remove + rescan → 序列固定
3. 尺寸可能分配失败 → 任何负责任的实现都必须校验并回滚

序列一致是规范约束的必然结果，不构成表达上的实质性相似。著作权法保护**表达**，不保护**思想与操作方法**（见 §5.1）。

---

## 7. 开发过程时间线

| 时间（2026-10-27） | 事件 | 可核查痕迹 |
|---|---|---|
| 上午 | 调研根端口 rescan 的失败案例，评估第三方方案可行性 | 会话记录 |
| 上午 | 阅读第三方 `LICENSE`，确认其 §1.1 排除机构使用、§3.2 禁止修改 ⇒ 不可用 | 会话记录 |
| 上午 | 确认 §4.2 承认技术方法公开 ⇒ 决定独立实现 | 会话记录 |
| 上午 | 上机读取本机 ReBAR 寄存器原始值（`setpci` / `lspci` / sysfs） | `docs/` 记录 |
| 09:xx | 编写 `docs/rebar-task.md`：只写规范与实测数据，**不写实现步骤** | 文件 mtime |
| 09:22 | 编写 `archive/baseline.sh`（主脚本前身） | 文件 mtime |
| 09:13 / 09:17 | 派发三个不同家族的模型独立实现（`cand-hy3` / `cand-minimax`），三者在提示中均被明确禁止参考任何第三方同类项目 | 文件 mtime |
| 上午 | 上机实测三个候选：hy3 误判上限、minimax 使用非法 `setpci` 宽度、第三个因上游 502 未产出 | 会话记录 |
| 09:23 | 合并为 `b580-bar-tool.sh`，修掉 `lspci -n` 字段取错的缺陷 | 文件 mtime |
| 15:22 | 启用硬件看门狗（`tools/wd-enable.sh`） | `system.conf.bak-rebar-20261027-152256` |
| 15:24 | 执行 `rehearse` 演练：remove + rescan 成功，4 秒，零挂死 | `/var/log/b580-bar-tool.steps`（目标机） |

派发三个模型独立实现的目的一是获得多方交叉验证，二是留下"从零推导"的独立证据链。三者均因实测缺陷不合格，最终交付为自行实现的版本，并吸收了 hy3 的 ECAP ID 校验思路与 minimax 的显式驱动重绑思路（二者均为通用工程做法，非第三方代码）。

---

## 8. 核查方法

任何人均可自行验证。以下三条命令给出**可预期的确切结果**，不是"应该没问题"：

```bash
# 1) 实现代码里不应出现第三方项目的实现痕迹
grep -rniE "arc-rebar|burlamaqui|init-premount|update-initramfs" \
  --include='*.sh' --include='*.py' --include='*.service' . --exclude-dir=.git
# 预期：只命中 archive/ 两个候选脚本的自述注释，无任何实现代码

# 2) 本项目脚本不得含 display-manager 相关逻辑（这是第三方 live-test.sh 的唯一行为）
grep -niE "display-manager|gdm|lightdm|sddm" b580-bar-tool.sh tools/*.sh
# 预期：无命中

# 3) 本项目脚本不得出现第二个同类项目（Emvo10/Intel-Arc-B580-ReBar）的独有标识
#    这些是它 README 里独有的：配置项名、配置路径、检查输出文案
grep -rniE "emvo10|B580_GPU|B580_ROOT_PORT|/etc/default/b580-rebar|16 GB ACTIVE" \
  --include='*.sh' --include='*.service' . --exclude-dir=.git
# 预期：无命中

# 4) 提交历史
git log --format='%H %ai %s'
```

### 会命中项目名的地方，及原因

| 位置 | 为什么出现项目名 |
|---|---|
| `archive/cand-hy3.sh:30`、`archive/cand-minimax.sh:18` | 早期候选实现在文件头**自述**："未参考任何第三方同类项目（尤其是 arc-rebar）" |
| `docs/rebar-task.md:13` | 派发候选实现时的**禁令原文**：禁止参考该项目 |
| `CREDITS.md` | **公开致谢**（方法来源说明；第二节 2.3 与 2.4 分别是两个同类项目） |
| `README.md` / `README.zh-CN.md` | 致谢表格中的两行（「同款卡上的邻作」「同类项目的先例」） |
| 本文件 | 合规分析需要引用项目名，并记录接触时间与范围 |

**除了"声明没参考它"和"感谢它"这两类文字，代码里没有它们的任何东西。** 这两类文字恰好说明接触是被记录、被限制的。

---

*本文档为工程合规说明，不构成法律意见。正式落地前建议由本单位法务复核 §5 引用的法律条文。*
