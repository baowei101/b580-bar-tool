# 双卡现场交接 —— 从这里往下走

> 更新于 2026-10-28 01:00（**双卡均已扩到 16GB，全程串行实测通过**）
> 通用逻辑在 `tools/lib/topology.sh`；具体机器的实测案例见
> `docs/case-dual-b580-separate-root-ports.md`。本文只留"现在在哪、下一步做什么"。

> **给读者**：本文是**作者本机的交接笔记**，不是使用文档。里面出现的端口号
> （`8091`–`8098`、`11434`/`11435`）、服务名（rerank / ASR / OCR）、主机代称
> 都只是"这台机器上恰好跑着什么"，**与本工具的功能无关，也不是依赖**。
> 你只需要看两样东西：实测数据（它记录了不同阶段的真实寄存器值）和坑清单（第七节）。
> 上手请回 [`README.md`](README.md)。

---

## 一、当前状态（实测，2026-10-28 00:50）

| 项 | 值 |
|---|---|
| 机器 | **已开机**，`22:42` 起来；`00:50` 完成双卡扩容 |
| 显卡 | **2 张** Arc B580（`8086:e20b`）：`0000:04:00.0`（`card0`/`renderD128`）、`0000:08:00.0`（`card1`/`renderD129`） |
| 根端口 | 两张**各占一个**：`00:02.0` 和 `00:03.0`（**不共享**） |
| BAR2 | 两张都 **16384 MB**（已扩） |
| 锚点窗口 | 两个根端口均 `16392M`（`20000000000-204007fffff` / `20800000000-20c007fffff`） |
| ReBAR Control | 两张 `0x428` 均 `00000e22`（size field = 14） |
| 探测结论 | **策略 = atomic**（每张独占锚点，逐张处理即可，不需要批量结算） |
| 开机自愈 | `b580-rebar.service` + `b580-rebar-late.service` 仍 **disabled** ⇒ 下次开机 BAR 会回到 512MB |
| 在跑的服务 | 8091 / 8092 / 8093 / 8094 / 8095 / 8096 / 11434 全部 active，4 个健康端口均 200 |
| SYCL | 两张均可枚举并实算通过，见下面「扩容实测结果」 |

### 扩容实测结果（已做，不用重做）

| 项 | 结果 |
|---|---|
| 卡1 `04:00.0` | 4 秒成功，BAR2 512→16384MB，`xe` 自动重绑，`card0` 恢复 |
| 卡2 `08:00.0` | 卡1 **完全返回后**才开始，同样 4 秒成功 |
| 整机影响 | PCI 设备总数 197 → 197，NVMe/网卡/两张声卡驱动全在，无一次报错 |
| `rebar-autofix.sh --check` | 退出码 **0**（两张都 OK） |
| SYCL 枚举 | `level_zero:0` = `0000:04:00.0`，`level_zero:1` = `0000:08:00.0`（**索引≠BDF 这个坑这次正好对上，但别假定**） |
| SYCL 内存 | 两张 `global=11.93 GiB`、**`max_mem_alloc=11.33 GiB`**（512MB BAR 时这个值不可能 >0.5GiB，这就是 ReBAR 生效的直接证据） |
| SYCL 实算 | 16MB `malloc_device` + 核函数 + reduction，两张分别 PASS（串行跑，卡1 exit 后才跑卡2） |

> ⚠️ **`sycl-ls` 必须带 `umf` 路径**，否则 `level_zero` 后端会静默消失（只剩 `opencl`），
> 报错只在 `--verbose` 里：`libur_adapter_level_zero.so.0: libumf.so.1: cannot open shared object file`。
>
> ```bash
> export LD_LIBRARY_PATH=/opt/intel/oneapi/compiler/2026.2/lib:/opt/intel/oneapi/umf/1.2/lib
> ZES_ENABLE_SYSMAN=1 /opt/intel/oneapi/compiler/2026.2/bin/sycl-ls
> ```

## 二、代码已重构完（这一步不用再做）

**探测层** `tools/lib/topology.sh` 是唯一的"机器长什么样"来源，上层不再写死任何东西：

| 原来写死的 | 现在 |
|---|---|
| BDF `0000:04:00.0` | `topo_enumerate` 按 vendor:device 枚举 |
| ECAP 偏移 `0x420` | `topo_ecap` 遍历扩展能力链表（ID `0x0015`） |
| "根端口"这一层级 | `topo_anchor` 求"最高的子树安全祖先" |
| `renderD128` | `topo_drm` 反查 `/sys/class/drm/*/device` |
| 多卡一律 batch | `topo_strategy` 按探测结果选 atomic / batch |

已在目标机上实测通过：`gpu-topology.sh --plan`、`rebar-batch.sh --plan`、
`rebar-autofix.sh --check`、主工具 `status --gpu <BDF>`。

---

## 三、下一步：扩 BAR（按 atomic 逐张）

### 1. 先停 GPU 服务（必须）

```bash
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host -v /tmp:/tmp -v /opt:/opt \
  ubuntu:24.04 nsenter -t 1 -m -u -i -n -p -- env GPU_USER=<USER> /opt/b580-bar-tool/stop-gpu-root.sh'
```

**验收标准**：所有 `renderD*` 节点都无进程占用。两个节点都要查（`renderD128` + `renderD129`），
只查一个是旧脚本的 bug，已修。

### 2. 再看一次计划（只读，确认探测结论）

```bash
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host -v /tmp:/tmp -v /opt:/opt -v /sys:/sys \
  ubuntu:24.04 nsenter -t 1 -m -u -i -n -p -- /opt/b580-bar-tool/gpu-topology.sh --plan'
```

应该看到 `整体策略：atomic`，并给出每张卡的命令。

### 3. 逐张扩（一张失败不影响另一张）

```bash
# 卡1
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host -v /tmp:/tmp -v /opt:/opt \
  -v /var/log:/var/log -v /var/lib:/var/lib ubuntu:24.04 nsenter -t 1 -m -u -i -n -p -- \
  /opt/b580-bar-tool/b580-bar-tool.sh apply --gpu 0000:04:00.0 --size 14 --yes'

# 卡2
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host -v /tmp:/tmp -v /opt:/opt \
  -v /var/log:/var/log -v /var/lib:/var/lib ubuntu:24.04 nsenter -t 1 -m -u -i -n -p -- \
  /opt/b580-bar-tool/b580-bar-tool.sh apply --gpu 0000:08:00.0 --size 14 --yes'
```

也可以用 `rebar-batch.sh`（它按锚点分组，两个组各 1 张，效果等价，且多做两件事：
误伤检查、rescan 前后全机 BAR 漂移比对）。**看命令行退出码不够，必须复查：**

```bash
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host -v /tmp:/tmp -v /opt:/opt \
  -v /sys:/sys ubuntu:24.04 nsenter -t 1 -m -u -i -n -p -- /opt/b580-bar-tool/rebar-batch.sh --check'
```

期望：两行 `OK ... BAR2 = 16384MB`。

### 4. 起服务并验证 SYCL 双卡

```bash
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host -v /tmp:/tmp -v /opt:/opt \
  ubuntu:24.04 nsenter -t 1 -m -u -i -n -p -- env GPU_USER=<USER> /opt/b580-bar-tool/start-gpu-root.sh'
```

`sycl-ls` 确认两张都能枚举（**`level_zero:0` 不等于 `04:00.0`，以 BDF 为准**）：

```bash
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host -v /tmp:/tmp -v /opt:/opt \
  ubuntu:24.04 nsenter -t 1 -m -u -i -n -p -- bash -c \
  "export LD_LIBRARY_PATH=/opt/intel/oneapi/compiler/2026.2/lib:/opt/intel/oneapi/umf/1.2/lib; ZES_ENABLE_SYSMAN=1 \
   /opt/intel/oneapi/compiler/2026.2/bin/sycl-ls"'
```

> ⚠️ `LD_LIBRARY_PATH` **必须带 `umf/1.2/lib`**，只给 `compiler/2026.2/lib` 时
> `level_zero` 适配器会因缺 `libumf.so.1` 加载失败，输出里只剩 `opencl` 两条 ——
> 看着像"L0 挂了"，其实是路径问题（2026-10-28 实测）。
> 要拿 device → BDF 对应关系，`sycl-ls --verbose` 在这版不打印 BDF，
> 用带 `ext_intel_pci_address` 的查询程序取（见 `docs/dual-gpu-checklist.md`）。

### 5. 一切正常后再恢复开机自愈

```bash
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host -v /tmp:/tmp -v /etc:/etc \
  ubuntu:24.04 nsenter -t 1 -m -u -i -n -p -- \
  systemctl enable b580-rebar.service b580-rebar-late.service'
```

> ⚠️ 开机自愈这次是**第一次真跑**新版（`Before=systemd-udevd.service` + 探测层）。
> 故意把它留到最后：先手动确认新代码在真机上没问题，再让它开机自动执行。

---

## 四、出问题怎么办

| 症状 | 处理 |
|---|---|
| 某张卡没到 16GB，另一张正常 | 说明两个锚点独立，只需重跑失败那张；先看它的锚点窗口：`lspci -vv -s <锚点> \| grep Prefetchable` |
| 两张都没到 16GB | 看根端口窗口是否仍是 520MB → `pci=realloc` 是否还在 `/proc/cmdline` |
| 卡缩回 512MB | `b580-bar-tool.sh apply --gpu <BDF> --size 9 --yes` |
| 内核在 remove 锚点时挂死 | **只能断电重启**（工具 README 声明的固有风险）；重启后两个 unit 是 disabled，需手动扩 |
| 服务起不来 | 8059/8094 有依赖顺序，用 `start-gpu-root.sh`，别单独 `systemctl start` |

回滚到 apply 前记录的 Control：`b580-bar-tool.sh rollback --gpu <BDF>`

> ⚠️ 重启代价取决于固件自检，**本机未做过可靠测量**（曾有单次长自检的观察，但属偶发，
> 不能当常态）。要重启就先安排好时间，别在赶时间的时候做。

---

## 五、还没解决的问题（不急）

| # | 问题 | 备注 |
|---|---|---|
| 1 | pp 与社区报告有差距（1010 vs 1593） | 社区 oneAPI 2026.1，本机 2026.2；也可能 `-ub`/`-b` 调优空间 |
| 2 | 8098 是手动 setsid 进程 | 重启即失、崩了不自愈，该做成 systemd |
| 3 | `ollama-embed`(:11435) enabled | 违反"勿启动"约定，重启会自启 |
| 4 | `/data` 有坏块（`Current_Pending_Sector=3`） | 已毁过一次模型文件；git 裸库也在同一块盘上 |
| 5 | 双卡**同时**跑 SYCL 推理 | 单卡已验证；双卡已确认各自可算（2026-10-28 串行实测），并发/分片仍未测 |
| 6 | **更大显存的卡（N>14）未实测** | 尺寸字段是 2 的幂次，`max_supported_n()` 读卡自身能力位图，理论上换张卡不用改代码（`EXPECT_ID` 要改或加 `--allow-any-gpu`）。但手上只有 B580（上限 N=14 = 16GB），N=15（32GB）没有任何真机数据 —— **等有卡的人补**，README「更大的卡」已把边界写明 |

---

## 六、三席独立审核后的修复（2026-10-28 00:40）

三席（`hy4-preview` / `mimo-v2.6-pro` / `glm-5.3-flash`）独立审核，互不可见、全程只读、
未动硬件。三席一致认为「误伤别的 PCIe 设备」这条防线是成立的（`topo_subtree` 递归枚举 +
未知 class 一律 fail-closed），真正的问题集中在**失败被伪装成成功**。已修：

| 类别 | 改动 | 位置 |
|---|---|---|
| **P0 自愈假成功** | `--check` 零设备返回 **3**（原为 0 ⇒ late unit 的 `ExecCondition='! --check'` 变假 ⇒ 设备消失时兜底跳过） | `tools/rebar-autofix.sh` |
| **P0 自愈假成功** | 幂等判据改为「Control 字段 **且** BAR2 实际值」双条件；字段已达标但 BAR 仍 512MB 时打印 WARN 并继续修复 | `b580-bar-tool.sh` |
| **P0 假成功** | 新增 `topo_ungrouped`，求不出安全锚点的卡不再被 `\|\| continue` 静默丢弃，直接拒绝执行 | `tools/lib/topology.sh` + 两个执行脚本 |
| **P0 无 trap** | `remove` 与 `rescan` 之间被打断（Ctrl-C / systemd 超时 / SSH 断开）会让子树一直消失。新增 `PCI_TREE_REMOVED` 标志 + `INT/TERM/HUP/EXIT` 四个 trap，任何退出路径都补一次 rescan；恢复失败时打印人工命令并提示重启后先跑 `check` | `b580-bar-tool.sh` |
| 回滚顺序 | 第 12 步 remove 前重新 `unbind_leaves` —— 原先直接 remove，正是脚本自己第 5 步禁止的「带绑定驱动 remove」（内核 UAF） | `tools/rebar-batch.sh` |
| 回滚静默失败 | 回滚 `setpci` 写回后**回读比对**；新增 `rebind_leaves`，第 8 步 remove 失败时把驱动绑回去 | `tools/rebar-batch.sh` |
| 合规 | 新增 `LICENSE`（MIT）+ README 风险声明；`stop-gpu.sh` / `start-gpu.sh` 不再从 argv 收 sudo 密码 | 仓库根 / `tools/` |

**实测（目标机，全部只读，未动 BAR）**：`--check` 无设备 → `3` ✓ ｜ 有卡未达标 → `1` ✓ ｜
正常 → `0` ✓ ｜ `topo_ungrouped` 在双卡机上输出为空 ✓ ｜ `batch --plan` 分组结果与改前一致 ✓

**已知未修**：

| 优先级 | 问题 | 备注 |
|---|---|---|
| P1 | `ECAP` 只读第一组 `(Cap,Control)`（换 Arc A 系卡会写到错误的 BAR 索引，B580 不受影响） | |
| P1 | **单卡脚本不降级锚点**（**不是安全缺口**，2026-10-28 03:10 读码+实测订正）：`preflight()`（`b580-bar-tool.sh:354`）里已有「根端口下存在非本卡设备」判断并置 `rc=1`，`check`、`rehearse`、`apply` 三条路径都会因此报错/中止；本轮又让 `rollback_to` 复用同一判据（只 WARN，恢复优先）。真正缺的是**能力**：单卡脚本不会像 `topo_anchor()` 那样把锚点降到卡内桥，所以共享根端口时它只会拒绝、要人改用 `tools/rebar-batch.sh`。上一版此条写「`cmd_plan_or_apply` 不调用该判断」，是没读代码的误记 | 见 `CREDITS.md` 第二节 2.4 |
| P2 | `0403` 音频类无条件放行（根端口下挂独立声卡会被误摘） | |
| P2 | `grep -qw 'pci=realloc'` 把 `pci=realloc=off` 误判为已开启 | |
| P2 | `TOPO_DEV_IDS` 不做大小写/前导零归一 | |
| P2 | `topo_window_mb` 的 `setpci` fallback 用了错位的 0x28（<4GB 窗口会算成 0） | |
| P2 | `unbind_leaves` 中途失败不反绑 · late unit 存在 `After=multi-user.target` + `WantedBy=multi-user.target` 的 ordering cycle | |

**trap 的边界（务必知道）**：trap 只能捕获 `INT` / `TERM` / `HUP` / 正常 `EXIT`。
`SIGKILL`（`kill -9`、内核 OOM、断电、硬复位）**捕获不到**，这几种情况下仍会留下消失的子树。
因此 `check` 里的残留检测必须保留 —— 它是 SIGKILL 场景下唯一的补救线索。

**真机验证（2026-10-28 02:10，目标双卡机，`0000:04:00.0` / 根端口 `0000:00:02.0`）**：

| 场景 | 做法 | 结果 |
|---|---|---|
| 正常路径不被干扰 | 直接 `rehearse` | 4 秒完成，BAR2 仍 16384MB，Control 仍 `00000e22`，trap **完全静默** |
| 信号落在 remove 之前 | `timeout -s TERM 1.8` | 打了「已被中断」，但**未做多余 rescan**（标志仍为 0，判定正确） |
| **信号落在 remove 之后** | 临时副本在 remove 后注入 `sleep 5`，`timeout -s TERM 3.5` | 打出「检测到中断发生在 remove 与 rescan 之间」→ **2 秒内自动恢复**，`04:00.0` 回到 sysfs，`xe` 驱动自动重绑 |

**实测得出的一条重要事实**：真实 `remove → rescan` 窗口在本机是**毫秒级**
（`rehearse` 里 remove 与 rescan 发生在同一秒内，中间只有 `step` 落盘和 `sync`）。
所以正常操作几乎不可能"恰好"打断在这一步 —— 这个 P0 的**实际触发概率远低于三席的估计**。

trap 的价值因此不在"高频故障"，而在两点：一是 `remove` 本身卡住时（内核挂死前的窗口）仍能收到信号；
二是防住未来改动把这段间隙拉长。第三点：代价极低（55 行、无外部依赖），
比"赌它不会发生"更划算。

逐条审核记录见 `docs/reviews/round2-2026-10-28.md`（含三席交叉结论与我们不采纳的定级理由）。


---

## 七、发布前的真机验收（2026-10-28 03:10）

这一轮把此前"只做过静态审查"的两条路径真的跑了一遍，三条新事实：

| 项 | 结果 |
|---|---|
| `stop-gpu.sh` 正式执行 | 停掉 3 个 unit（`paddleocr-vl-8094` / `llama-asr` / `llama-rerank`），1 秒内 renderD 全空，恢复记录写入 `/run/b580-bar-tool/stopped-units`，`rc=0` |
| `start-gpu.sh` 按记录恢复 | 3 个 unit 全回 `active`，记录文件被清除；之后 8092/8093/8094 的 `/health` 均 **200** |
| `rollback` 全链路 | **真的会回退**：用 `/var/lib/b580-bar-tool.state` 里记录的 `N=9`（512MB）写回，`BAR2 16384MB → 512MB` 成功；随后 `apply --size 14` 再扩回 16384MB，两卡最终 `Control=00000e22` |

**坑（这次新踩到的）**：`rollback` 之后根端口 rescan 会让 **DRM 节点编号变** —— 实测
`renderD128/renderD129` 变成 `renderD129/renderD130`。所以脚本里别写死 `renderD128`：
按 `/dev/dri/renderD*` 通配，或者从 `/sys/class/drm/*/device` 反查 BDF。服务本身不受影响
（重启后按新节点打开），但任何"记住节点号"的工具都会指错设备。

另：`rollback` 不是空操作 —— 只要 `/var/lib/b580-bar-tool.state` 存在（上次 apply 留下的），
它就会把 BAR 真改回那个值。想"什么都不做"别拿报错当保护，先看 `status`。

> **上面两条坑已同步进 `README.md` 的「除 BAR2 之外还会变什么」一节（中英双语）** ——
> 它们是工具的行为事实、不只是本机记录，所以放在读者看得到且会维护的两版里。本文保留
> 实测原始数据（当时的节点号、寄存器值），不再重复解释。
