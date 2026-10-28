# ReBAR 扩容踩坑总表

> 汇总 `b580-bar-tool` 从立项到 2026-10-28 全部实测踩到的坑，按「坑的层次」分类。
> 来源标注：`[R]` README · `[N]` NEXT.md · `[D]` DISCLAIMER · `[C]` 案例文档 · **`[新]` 2026-10-28 本轮实操新踩**
>
> 一句话结论：**这个工具真正难的地方不是写寄存器，而是「失败被伪装成成功」以及「你以为的链路/能力其实读错了层级」。**

---

## 零、速查：如果只记五条

| # | 坑 | 后果 |
|---|---|---|
| 1 | 走 BIOS 改 BAR 大小这条路 | 最大只能到 512MB，再大 **卡 POST**；headless 无 IPMI ⇒ 必须到现场断电清 CMOS |
| 2 | 指望 `xe` 驱动自己扩 BAR | 必然 `-ENOSPC`。`pci_resize_resource()` 只在现有桥窗口内找空间，**不会扩上游桥** |
| 3 | 以为扩完就永久生效 | BAR 是**运行时状态**，断电/重启回 512MB，配置空间由 BIOS 重置 |
| 4 | 用普通用户跑主脚本 | `setpci` 读不到扩展配置空间（offset ≥ 256），误报**「该卡没有 Resizable BAR 扩展能力」** `[新]` |
| 5 | 双卡共享锚点时逐张 `apply` | 第二次 rescan 把先扩好的那张挤小，而 `apply` 只校验目标卡 ⇒ **报"成功"，另一张静默降级** |

---

## 一、认知层：会让你做错决策的误读

### 1.1 BIOS 路线是死路，不是没试过 `[R]`

BIOS 确实暴露了 BAR 大小选项（默认 256MB），但**能开机的最大值是 512MB**，再大 GPU 初始化失败、
系统卡在 POST。能开机的档位太小、够用的档位开不了机 —— 这才是本工具存在的理由。

> 这台机器**没有显示输出、没有 IPMI**。卡在 POST 意味着看不到停在哪、也无法远程回退，
> 必须有人走过去断电 + 清 CMOS。所以任何"先试试 BIOS 设 16GB"的建议在这台机器上都不是选项。

### 1.2 `xe` 自己扩不了，原因在函数边界 `[R]`

```
xe: BAR 2 [mem size 0x400000000 64bit pref]: can't assign; no space
xe: Failed to resize BAR2 to 16384MiB (-ENOSPC). Consider enabling 'Resizable BAR' support in your BIOS
```

`pci_resize_resource()` 只找**现有桥窗口内**的空洞；本项目"先写 Control 再全量 re-enumeration"
走的是 `pbus_reassign_bridge_resources()`，它会重排并**扩大桥窗口**。差别在这一层，不在显卡能力。

### 1.3 卡内链路 `x1 / 2.5GT/s` 是误读，不是插错槽 `[C]`

```
0000:04:00.0  cur=1  max=1  2.5 GT/s   ← GPU 核心，卡内链路
0000:02:00.0  cur=8  max=8  8.0 GT/s   ← 卡内桥，这才是槽位链路
```

`max_link_width=1` 会让人以为金手指坏了或插错槽。**判断插槽看卡内桥**（`e2ff`）的 `current_link_width`。
B580 本身是 x8 卡，Gen3 x8 是这颗 CPU 的上限，两者都正常。

### 1.4 BDF 不可预测，只能枚举 `[C]`

插第二张卡前预期 `06:00.0`，实际是 `08:00.0` —— 卡内桥自己占了总线 06，把 GPU 顶到 07 段之后的 08。
任何写死 BDF 的脚本/笔记换一次插槽就失效。

### 1.5 起始 256MB 不影响能不能扩到 16GB `[R]`

脚本写入的是**绝对目标值** `new = (old & ~0x3F00) | (N << 8)`，与旧值无关。出厂 256MB 的板子照样一步跳到 16GB，
而且收益更大（作者在 C602 平台实测带宽 15 → 392 GB/s）。**真正的三个前提**见第二节。

---

## 二、硬件 / 固件层：真正的三个门槛 `[R]`

| 前提 | 说明 | 怎么查 |
|---|---|---|
| Capability 位图含 N=14 | 这是 **GPU 自身**能力，同一块 B580 恒为 `0x0007f000`（N=8..14），与主板无关 | `status` 的「卡支持上限」 |
| `pci=realloc` 在内核命令行 | 没有它，rescan 时内核不被允许扩大桥窗口；脚本会直接 ERROR 拒绝执行 | `cat /proc/cmdline` |
| Above-4G 有 ≥16GB **连续且 16GB 对齐**的空闲 | **最容易成为真瓶颈的一条** | `sudo grep "PCI Bus 0000:00" /proc/iomem` |
| 芯片组容忍全量重枚举 | 少数芯片组会挂死，恢复只能断电。先跑 `rehearse`（不改寄存器）单独验证 | `rehearse` |

本机（C610）父窗口 `20000000000-2ffffffffff`（1TB），base 恰好 16GB 对齐，所以一次成功。

**装不下 16GB 怎么办**：退到 `--size 13`（8GB），把 12GB 显存的前 8GB 映射给 CPU，仍远好于 256MB；
dmesg 里 `CPU accessible size` 会相应变小。

---

## 三、脚本实现层：bash / setpci / sysfs 的工具坑 `[R]`

| # | 坑 | 说明 |
|---|---|---|
| 1 | `seq 0x100 4 0xFFC` | GNU `seq` **不认十六进制参数**，ECAP 扫描会静默失效 |
| 2 | `[ "$x" -eq 0x0015 ]` | `test` 不支持十六进制字面量，报 `integer expression expected` 并**恒为假**。必须用 `(( ))`。**这条被违反过两次** |
| 3 | `setpci ... .d` | 宽度合法值只有 `.b` / `.w` / `.l`，**没有 `.d`**。`cand-minimax.sh` 因此完全读写不了寄存器 |
| 4 | 读 `/sys/.../resource2` | 部分内核返回 **EIO**，必须读 `resource` 的第 3 行 |
| 5 | 用 `.w` 读 Capability | 只拿到低 16 位，丢掉高 16 位 → 误判上限。`cand-hy3.sh` 因此认为本机上限只有 2GB 并**自我拒绝执行** |
| 6 | `lspci -n` 取 `$3` | 字段是 `BDF` / `class:`（**带尾冒号，第 2 字段**）/ `vendor:device`。取 `$3` 会拿到 vendor:device，本项目曾因此让 `apply` 误拒，并会去 **unbind `pcieport`** |
| 7 | 解绑驱动范围 | **只解绑终端设备**（`xe` / `snd_hda_intel`），`pcieport` 保持绑定，由锚点级联移除。带绑定 remove = 内核 UAF |
| 8 | `GROUPS` 是 bash 保留变量 | 它是"当前用户组 ID 数组"，root 恒为 `("0")`。`GROUPS=()` / `GROUPS+=(...)` 会被 bash 接管 ⇒ 分组显示"锚点 0、本组 0 张"，**数组看着有值内容全是假的**。同类危险名：`PIPESTATUS` `RANDOM` `SECONDS` `LINENO` `UID` `PPID`。数组一律加业务前缀（现用 `ANCHOR_GROUPS`） |
| 9 | `readarray` 收集多行 | 先确认命令**在同样上下文（root、同 namespace）真的输出了多行**。`for x in "${arr[@]}"` 在只有一个假元素时不报错，只会安静少跑 |

### 其他已知未修的边角 `[N]`

| 优先级 | 问题 |
|---|---|
| P1 | `ECAP` 只读第一组 `(Cap, Control)` —— 换 Arc A 系卡会写到错误的 BAR 索引（B580 不受影响） |
| P2 | `0x0403` 音频类**无条件放行** —— 根端口下挂独立声卡会被误摘 |
| P2 | `grep -qw 'pci=realloc'` 会把 `pci=realloc=off` 误判为已开启 |
| P2 | `TOPO_DEV_IDS` 不做大小写/前导零归一 |
| P2 | `topo_window_mb` 的 `setpci` fallback 用了错位的 `0x28`（<4GB 窗口会算成 0） |
| P2 | `unbind_leaves` 中途失败不反绑；late unit 存在 ordering cycle |

---

## 四、最危险的一类：失败被伪装成成功 `[N]`

三席独立评审（互不可见、只读、未动硬件）的一致结论：**误伤别的 PCIe 设备这条防线是成立的，
真问题集中在"失败被伪装成成功"**。已修 5 处：

| 问题 | 修法 |
|---|---|
| `--check` 零设备返回 **0** | 改为返回 **3**（否则 late unit 的 `ExecCondition='! --check'` 变假，**设备消失时兜底反而跳过**） |
| 幂等判据只看 Control 字段 | 改为「Control 字段 **且** BAR2 实际值」双条件；字段达标但 BAR 仍 512MB 时打 WARN 并继续修 |
| 求不出安全锚点的卡被 `\|\| continue` 静默丢弃 | 新增 `topo_ungrouped`，直接拒绝执行 |
| `remove` 与 `rescan` 之间无 trap | 新增 `PCI_TREE_REMOVED` 标志 + `INT/TERM/HUP/EXIT` 四 trap，任何退出路径补一次 rescan |
| 回滚 `setpci` 写回不比对、失败静默 | 写回后**回读比对**；顺带补 `rebind_leaves` |

**trap 的边界**：只抓 `INT/TERM/HUP/EXIT`，**`SIGKILL`（`kill -9`、OOM、断电、硬复位）抓不到**。
所以 `check` 里的残留检测必须保留 —— 它是 SIGKILL 场景下唯一的补救线索。

**实测补充**：真实 `remove → rescan` 窗口在本机是**毫秒级**（同一秒内完成），正常操作几乎不可能恰好打断。
trap 的价值不在高频故障，而在"remove 本身卡住时仍能收到信号"和"防未来改动拉长这个间隙"。

---

## 五、运行 / 运维层（含本轮新踩）

### 5.1 ⚠️ 必须用 root 跑主脚本，否则错误信息会骗你 `[新]`

```bash
# ✗ 错：普通用户
./b580-bar-tool.sh apply --gpu 0000:04:00.0 --size 14 --yes
# → ERROR 该卡没有 Resizable BAR 扩展能力

# ✓ 对：整条命令走 root
sudo ./b580-bar-tool.sh apply --gpu 0000:04:00.0 --size 14 --yes
```

根因：`ecap_find()` 用 `setpci -s BDF <off>.l` 遍历扩展能力链，**offset ≥ 256 的配置空间
普通用户读不到** ⇒ 返回空 ⇒ `|| die "该卡没有 Resizable BAR 扩展能力"`。

**这条错误信息严重误导**：它会让人以为卡不支持 ReBAR（而 `status` 里明明写着 `ECAP = 0x420`）。
`status` 之所以能过，是因为那次用 `sudo` 跑的。

> 建议给项目提一个 issue：`ecap_find` 失败时应区分「读不到（权限）」和「链里没有 ReBAR」，
> 或者在 `main()` 开头加 `[ "$(id -u)" -eq 0 ] || die "需要 root：扩展配置空间普通用户读不到"`。

### 5.2 `stop-gpu.sh` 要求同 tty 的 sudo 时间戳，非交互 ssh 会直接退出 `[新]`

```
需要 sudo 权限：请先运行 'sudo -v' 再执行本脚本
```

即使已经 `echo PASS | sudo -S -v`，在**非交互 ssh 会话**里时间戳仍可能不共享。
解决：`ssh -tt`（分配 tty）后再 `sudo -S -v` + 跑脚本；或者整条用 `sudo` 包住。

### 5.3 平铺部署会停在旧版本，而且没有版本标识 `[新]`

`/opt/b580-bar-tool` 的**平铺布局**（把 `tools/` 的内容复制到同一层，主脚本与辅助脚本同级）
是**有意设计**，不是垃圾文件 —— `find_tool()` 明说认两种布局：仓库布局（`tools/` 是子目录）
和部署布局（平铺）。

**但它是一份复制，不是链接。** 仓库更新后不会同步，平铺目录里也没有任何版本标识。

本轮实测：`/opt/b580-bar-tool` 的 HEAD 是 `d2e6998`（10-27 16:53），而仓库已到 `448c640`，
**落后 41 个提交**。于是根目录那版 `stop-gpu.sh` 还是"写死服务清单"的旧实现 ——
`tools/stop-gpu.sh` 早在 `508190d` 就改成了 `fuser` 反查 unit。

后果：我跑的是旧版，于是 **`xestrata-iq3s`（用户级）和 `ollama-embed`（系统级）漏停**，
必须手动补；同时 `/run/b580-bar-tool/stopped-units` **没有生成**，`start-gpu.sh` 无法自动恢复，得自己列清单起回来。

> **新版 `stop-gpu.sh` 的设计是"不带清单、现场反查"**：`fuser /dev/dri/renderD*` → PID →
> `/proc/<pid>/cgroup` → unit 名。理由很实在：这台机器有 9 个推理服务，实测那一刻**只有 3 个
> 真的占着 GPU**；写死清单既会误停空闲的，又会漏掉新加的。
>
> **对策**（已写进 README「部署」小节）：每次同步后留版本戳
> `git -C <repo> describe --always --dirty > /opt/b580-bar-tool/VERSION`，
> 排查时先看它，与主脚本首行日志的 `v$VER` 对照 —— 对不上就是没同步。

### 5.4 重启后 BAR 必回 512MB，而开机自愈 unit 是 disabled `[新][N]`

这是本轮故障的**起点**：10-28 00:50 已经成功双卡扩到 16384MB，21:38 再看又是 **512MB**（`Control=0x00000922`）。
`b580-rebar.service` / `b580-rebar-late.service` 一直是 **disabled** —— 项目有意的设计（全手动工具，不写持久配置），
但对"跑大模型"这个用途来说，**每次重启都必须记着重新 apply**。

**核对命令**（一条看清三件事）：

```bash
ssh -tt baow@<SERVER_IP> "echo '<PASS>' | sudo -S -v; \
  sudo /opt/b580-bar-tool/b580-bar-tool.sh status --gpu 0000:04:00.0 2>&1 | grep -E 'size 字段|BAR2 实际|根端口窗口'; \
  systemctl is-enabled b580-rebar.service b580-rebar-late.service"
```

### 5.5 DRM 节点号会变，别写死 `[R]`

`rescan`（尤其 `rollback`）之后实测 `renderD128/renderD129` → `renderD129/renderD130`。
服务重启后自己按新节点打开不受影响，但**任何记过节点号的监控/脚本会指错设备**。
取节点一律通配 `/dev/dri/renderD*`，或从 `/sys/class/drm/*/device` 反查 BDF。

### 5.6 `rollback` 不是空操作 `[R]`

只要 `/var/lib/b580-bar-tool.state` 还在（上次 `apply` 留下的），`rollback` 就会**真的把 BAR 改回记录值**
（实测 `16384MB → 512MB`）。想"什么都不做"先看 `status`，别把报错当保护。

### 5.7 停服务是硬要求，不是建议 `[R]`

**GPU 有 DMA 在途时移除根端口，是最可能挂死的场景。** `check` 用 `fuser` 判断，只要还有进程抓着节点就**直接拒绝** `apply`/`rehearse`。
双卡时**两个 render 节点都要查** —— 只查 `renderD128` 会漏掉第二张卡上的进程（旧脚本的 bug，已修）。

### 5.8 其他运维项 `[N][R]`

- **服务启动有依赖顺序**（8095/8094 相关），用 `start-gpu-root.sh`，别单独 `systemctl start`
- **`remove` 根端口时内核挂死** → 只能断电重启。兜底可以开硬件看门狗（走 PCH 的 iTCO_wdt，60 秒自动复位整机）：`tools/wd-enable.sh`
- **回滚风险**：解绑到系统盘所在的存储控制器会让根文件系统不可访问（工具已用子树判据 fail-closed 挡住，但别自己绕）
- **`--allow-any-gpu` 是危险开关**：它绕过 `vendor:device` 身份校验，指定错 BDF 和自动选错卡后果完全一样

---

## 六、双卡特有

| 坑 | 说明 |
|---|---|
| 共享锚点不能逐张跑 | 第 2 次 rescan 需要两倍窗口，内核分配不理想时会把先扩好的那张挤小；`apply` 只校验目标卡 ⇒ 报成功，另一张静默降级。必须 `rebar-batch.sh` 整组一次结算 |
| 独立锚点才能 atomic 逐张 | 本机两卡各占 `00:02.0` / `00:03.0`，互不影响，逐张 `apply` 即可。**换机器先跑 `tools/gpu-topology.sh --plan` 看策略** |
| `class 0x030000` 不能区分是哪张卡 | 必须用 `vendor:device` 校验；检测到 ≥2 张带 ReBAR 的显示设备时**拒绝自动选择**，要求 `--gpu` |
| 两张卡要**串行**，卡1 完全返回后才动卡2 | 本轮实测：卡1 21:40:31→:35 完成，卡2 21:40:50→:54 完成，各 4 秒 |
| SYCL 的 `level_zero:N` 索引 ≠ BDF | `sycl-ls` 这版不打印 BDF，要拿对应关系得用带 `ext_intel_pci_address` 的查询程序。别假定 `level_zero:0` 就是 `04:00.0` |
| `sycl-ls` 必须带 umf 路径 | 否则 `level_zero` 后端**静默消失**（只剩 `opencl`），原因 `libur_adapter_level_zero.so.0: libumf.so.1: cannot open shared object file`，只在 `--verbose` 里可见 |

---

## 七、与推理引擎的耦合（本轮新发现，**假设待验证**）

BAR 只有 512MB 时，dmesg 显示 `Small BAR device`，**CPU 可访问显存仅约 1GB**；
扩到 16GB 后变成 11.9GB、`Small BAR` 标记消失。

本轮遇到的问题链：

1. 双 B580 跑 XeStrata（SYCL/XE 双卡 layer split，`--layer-split` 跨卡边界在 **layer 24/25**）
2. 引擎反复在 **`host at layer step 24/25`** 卡死，`mtp draft: waiting for the GPU -1` → 60 秒 → `FATAL SIGABRT`
3. 内核里 **卡0 的 `bcs`（拷贝引擎）每秒 page fault**，`Fault response: Unsuccessful -EBUSY`，驱动自动 reset 失败（`state=0x249`）
4. 回退配置、重绑驱动、PCI FLR 都救不回来；最终 **GuC 固件死锁**（`Timed out wait for G2H` / `enabled GuC scheduling policies: -ETIME`），只能整机断电
5. 重启后 **BAR 回到 512MB**，而这些现象在 00:50–19:05 那段 BAR=16GB 的窗口里**没有出现**

**推断**：512MB BAR 下，跨卡搬运（`bcs`）走的是最差路径（主机代理拷贝 + 1GB 小窗口反弹），
高并发长 prompt 把它压垮 → page fault → 引擎级 reset 堆积 → GuC 死锁。

**验证方法**（本次已扩到 16GB，尚未复测）：`dmesg | grep -c 'Engine reset.*bcs'` 应为 0；
跑 12k / 32k / 100k prompt；对比 decode 是否回到 51 tok/s、长 prompt 是否不再崩。

---

## 八、本轮实操记录（2026-10-28 21:38–21:41，双卡扩容成功）

| 阶段 | 结果 |
|---|---|
| 初始 | 两卡 `BAR2=512MB`，`Control=0x00000922`（size 字段 9），根端口 `00:02.0`/`00:03.0` 各 **520MB** |
| 拓扑计划 | `整体策略：atomic`（各占独立锚点，可逐张） |
| 停服务 | 手动停 11 个（`xestrata-iq3s` / `ollama-embed` / `ollama` / `paddleocr-vl-8094` / `paddlex-8095` / `llama-asr` / `llama-rerank` / `tei-rerank-gpu` / `model-watch` / `model-watch-11434` / `headroom-proxy`），`renderD*` 与 `/dev/dri/card*` 全部无占用 |
| 卡1 apply | **4 秒成功**，`BAR2=16384MB`，`Control=00000e22`，`Region 2 @ 0x20000000000 [size=16G]` |
| 卡2 apply | **4 秒成功**，`BAR2=16384MB` |
| 副作用核查 | PCI 设备数 **197 → 197**（无丢设备），`xe` / `snd_hda_intel` 均自动回绑，`card0`/`card1` 节点回归，dmesg 无 error / timeout |
| 未做 | 服务回起与长 prompt 复测（用户中断）；`b580-rebar.service` 仍为 disabled |

**一条命令复现**（服务器端）：

```bash
sudo /opt/b580-bar-tool/b580-bar-tool.sh apply --gpu 0000:04:00.0 --size 14 --yes
sudo /opt/b580-bar-tool/b580-bar-tool.sh apply --gpu 0000:08:00.0 --size 14 --yes
sudo /opt/b580-bar-tool/rebar-batch.sh --check     # 期望两行 BAR2 = 16384MB
```

---

## 九、给项目的待办（按价值排序）

| # | 事项 | 状态 | 说明 |
|---|---|---|---|
| 1 | `ecap_find` 区分「权限不足」与「没有 ReBAR 能力」 | **已修** | 三处：`need_root` 消息点明 setpci 因果；`gather()` 按 `id -u` 分两种报错；`cmd_plan_or_apply` 把 `need_root` 提到 `gather` **之前**（原先只写在本函数的 apply 分支里，于是 plan 和 apply 都先死在 gather） |
| 2 | 平铺部署的版本漂移 | **已修（文档）** | README 新增「部署」小节：两种布局对照 + `VERSION` 戳做法。`/opt` 本身仍需人工同步到 HEAD |
| 3 | `stop-gpu.sh` 非 tty 时的指引 | **已修** | 改为列出三种可操作解法（`ssh -tt` / 整条 `sudo` / 免密），不再只说"请先 `sudo -v`" |
| 4 | README 首屏「重启后必须重新 apply」 | **已修** | 表格那行由「当前大小」改为「实测结果」，加醒目提示 + 核对命令；中英两版同步并过 `check-i18n.sh` |
| 5 | 补一节「BAR 容量对下游框架（SYCL/oneAPI、Vulkan、推理引擎）的影响」 | 待办 | 本文第七节目前只有推断，还没进 README |
| 6 | 三个 P2 边角（`0x0403` 放行、`pci=realloc=off` 误判、`topo_window_mb` 的 `0x28`） | 待办 | 换主板 / 换卡时才咬人，但咬人很难查 |

---

## 十、仓库协作层：压平快照会把「真源」锁死在远端

### 10.1 症状：每次发版都得 `--force`，普通 push 一律被拒 `[新]`

```
$ git push github main
 ! [rejected]  main -> main (non-fast-forward)
```

原因不是权限，也不是分支保护，而是**两边历史互不相干**：本仓库长期是
「本地一条演进历史（几十个提交）+ GitHub 上一个孤立提交（压平快照）」，
两个根提交没有共同祖先，任何普通 push 都是非快进。

压平本身有正当理由——早期提交里带着内网 IP、BDF、绝对路径，压平是最省事的脱敏手段。
但它有个副作用：**快照一旦推出去就成了公开历史的唯一根**，此后每次发布都得再压一次，
而且这一层关系只记在人的脑子里，新人 clone 下来会以为仓库只有一个提交、没有历史可查。

### 10.2 2026-10-28 的处理：以远端快照为唯一根，三边归一 `[新]`

```bash
# 1. 保留完整历史（仅本地，不推）
git branch archive-full-history-<日期> main

# 2. 让 main 指向远端快照（两者文件树逐字节一致，工作区不会变动）
git reset --hard <远端快照 sha>

# 3. 重建服务端裸库，推一次（此时是 fast-forward）
git init --bare -b main <repo>.git && git push origin main
```

结果：本地 `main` / 服务端裸库 / GitHub **三边 SHA 完全相同**，
之后任意一边 push 都是普通快进，`git push --dry-run` 两端都返回
`Everything up-to-date`。完整历史留在本地存档分支，需要考古时 `git log` 即可。

### 10.3 两个必须一起改的配置 `[新]`

**① 仓库级身份必须换成 noreply 邮箱。** 否则 push 到公开仓时会把内网邮箱写进提交元数据：

```bash
git config --local user.name  <github-用户名>
git config --local user.email "<数字ID>+<用户名>@users.noreply.github.com"
```

**② 双远端用一个别名推。** 裸库和 GitHub 内容必须一致，别靠记忆手动跑两次：

```bash
git config alias.pushall '!git push origin main && git push github main'
```

### 10.4 教训

**脱敏要在第一次提交之前做完，不要指望事后靠压平来救。** 压平的代价不是一次性的：
它把「远端快照」抬成了真源，本地历史降级为旁支，之后每次同步都要特殊处理。
一旦发现已经在压平，就尽早做一次 10.2 那种归一，别让它拖到几十次发布之后。
