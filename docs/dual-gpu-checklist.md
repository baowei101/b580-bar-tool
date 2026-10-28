# 双卡装机现场清单（2026-10-27 晚）

> 场景：目标机箱装第二张 Arc B580，验证枚举/识别/BAR 扩容是否到位。
> 本机历史：10-08 双卡是 `04:00.0`+`08:00.0`，10-14 撤掉一张；当前只有 `04:00.0`。

---

## 一、到场先跑这三条（5 分钟看清局面）

```bash
# 1. 拓扑体检（只读，不改任何东西）
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host \
  -v /tmp:/tmp -v /opt:/opt -v /sys:/sys ubuntu:24.04 \
  nsenter -t 1 -m -u -i -n -p -- /opt/b580-bar-tool/gpu-topology.sh'

# 2. 内核有没有认到第二张卡（有 xe 报错会在这里露出来）
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host \
  -v /tmp:/tmp ubuntu:24.04 nsenter -t 1 -m -u -i -n -p -- \
  "dmesg | grep -iE \"xe 0000|GuC|failed to enable\" | tail -20"'

# 3. 确认 drm 节点与 BDF 的对应关系（双卡时这层最容易错位）
ssh <USER>@<SERVER_IP> 'for c in /sys/class/drm/card[0-9]*; do
  [ -e "$c/device" ] && echo "$(basename $c) -> $(basename $(realpath $c/device))"; done'
```

**判断标准**

| 现象 | 含义 |
|---|---|
| 拓扑表里出现两个 `8086:e20b` | 两张卡都认到了，往下走 |
| 只有一张 | 卡没插好 / 供电没到 / 槽不识别，先查 `dmesg \| grep -i xe` |
| 出现第三张显示设备（非 8086:e20b） | 可能是核显或别的卡，注意别误操作 |

---

## 二、这张主板的已知结构（决定性）

```
0000:00:00.0 [根总线]  64 位窗口 1 TB

  ├─ 0000:00:01.0 [Port#1, Cap x8]   Width x0  ← 空槽（x8）
  ├─ 0000:00:02.0 [Port#2, Cap x16]  Width x8  ← 卡1 所在，经 switch 分 x8+x8
  │    └─ 0000:02:00.0 [PCIe switch]
  │         ├─ 0000:03:01.0 ── 0000:04:00.0   B580 GPU  (8086:e20b)
  │         └─ 0000:03:02.0 ── 0000:05:00.0   B580 HDMI 音频 (8086:e2f7) ← 不是空槽
  ├─ 0000:00:03.0 [Port#7, Cap x16]  Width x0  ← 空槽（x16，优先插这条）
  ├─ 0000:00:1c.2 [x1] ── 0000:08:00.0  网卡 eno1
  └─ 0000:00:1c.3 [x1] ── 0000:09:00.0  网卡 eno2
```

**四条关键结论（2026-10-27 双卡实测）：**

1. **`05:00.0` 不是空槽**，它是卡1 的 HDMI 音频（`8086:e2f7`，`snd_hda_intel`）。
   中间的 `02:00.0` / `06:00.0`（`8086:e2ff`）也不是外置交换机，而是**显卡自带的内部桥**。
2. **第二张卡和卡1 不在同一根端口**：实测第二张插 `00:03.0`，BDF 落在
   **`08:00.0`**（不是预测的 `06:00.0` —— 卡内桥自己占了总线 06，把 GPU 推到 08）。
   ⇒ **不需要 32GB 的单窗口**，各自 16GB 即可。**BDF 无法预测，只能枚举。**
3. **两个根端口的 prefetchable 窗口开机后都是 520MB**，两张卡都要它涨到 16GB，
   这由内核 rescan 重新分配（`pci=realloc` 已生效）。
4. **GPU 核心自身在 sysfs 里显示 `x1 / 2.5GT/s` 是正常的** —— 那是卡内桥到核心的内部链路。
   判断插槽是否正常要看**卡内桥**（`e2ff`）：实测两张都是 `x8 / 8GT/s`（B580 本身是 x8 卡）。

> ✅ 地址空间不是瓶颈：根总线 `0000:00` 的 64 位窗口是 **1 TB**
> （`/proc/iomem` → `20000000000-2ffffffffff`），两张共 32GB 只用 3%。
> `pci=realloc` 已在 `/etc/default/grub` 里并生效，内核被允许扩桥窗口。

> ⚠️ **误伤面**：remove 锚点会把**整个子树**摘掉。本机两个根端口下都只有
> GPU + 它自己的音频，所以安全。但换板子、或把卡插到 PCH 下的槽（`00:1c.x`），
> 那个根端口可能与网卡或 NVMe 共用 —— 那种情况**必须先跑 `gpu-topology.sh`**：
> 它会求出"安全锚点"（子树里只剩自己人的最高一级），锚点会自动降级到卡内桥，
> 不会去摘别人的盘。`rebar-batch.sh` 另有独立的误伤检查，发现非显卡设备直接拒绝执行。

> 📄 完整的实测数据（拓扑、链路、ECAP 链路、探测输出）见
> `docs/case-dual-b580-separate-root-ports.md`。**那份是案例，不是通用前提。**

---

## 三、扩 BAR 的正确顺序

> 双卡一律用 **`rebar-batch.sh`**，不要逐张跑 `b580-bar-tool.sh apply`。
> 它比逐张 apply 多两层保护：
> ① `preflight_subtree` —— remove 根端口前先确认子树里只有显卡/桥/本卡音频，
>    发现 NVMe、网卡等其它设备**直接拒绝执行**（这一步是防数据事故的）；
> ② `snapshot_bars` / `report_bar_drift` —— rescan 前后对比**整机所有 PCI 设备**的
>    BAR 地址，有非目标设备被动过会打 `NOTE`。因为 `/sys/bus/pci/rescan` 是全局的，
>    这是唯一能证明"没误伤"的手段。
> 另外它先把所有卡 Control 写好、只 rescan 一次，减少 PCI 总线扰动次数。
> batch 先写全部 Control、再一次 rescan，全成或全不成，无中间态。

### 情况 A：根端口窗口自己涨上去了（最好）

如果 batch 跑完内核把窗口重算成 32GB+，两张都能到 16GB，一次搞定。

```bash
# 一次性扩全部 B580（先写全部 Control，再一次 rescan）
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host \
  -v /tmp:/tmp -v /opt:/opt -v /var/log:/var/log -v /var/lib:/var/lib \
  ubuntu:24.04 nsenter -t 1 -m -u -i -n -p -- \
  /opt/b580-bar-tool/rebar-batch.sh'
```

**跑完立刻复查两张的 BAR2**，别只看命令退出码：

```bash
ssh <USER>@<SERVER_IP> '/opt/b580-bar-tool/rebar-batch.sh --check'
```

### 情况 B：窗口不够（很可能发生）

症状：`apply` 报 `BAR2 实际 xxxxMB，期望 16384MB —— 窗口不足，被降级分配`。

工具会**自动回滚**该卡。但注意：回滚只保证这张卡回到原尺寸，
**另一张卡可能被 rescan 顺手挤掉**——所以无论成功失败，都要跑 `--check` 确认两张。

退路按优先级：

| 退路 | 做法 | 代价 |
|---|---|---|
| **B1. 只给 SYCL 卡 16GB** | 把要跑 SYCL 的那张扩 16GB，另一张保持 512MB | 另一张只能跑 Vulkan/轻负载，或闲置 |
| **B2. 两张各 8GB** | `--size 13` | 12GB 显存映射不全，SYCL 会走 GTT 补，性能下降 |
| **B3. 一张 SYCL + 一张 Vulkan** | 卡1 SYCL 16GB 跑 SYCL 负载，卡2 Vulkan 跑别的 | 各吃各的，互不抢窗口 |
| **B4. BIOS 里找 Above 4G / MMIO 高基址选项** | 把 64 位 MMIO 窗口开大 | 需重启。**本机实际试过：能正常起来的最大值只有 512MB，调到 1GB 及以上直接卡 POST，且无头无 IPMI 无法远程恢复，只能现场断电清 CMOS —— 此路已堵死**，仅适用于 BIOS 本身能设更大 BAR 且能正常自检的主板 |

---

## 四、SYCL 双卡选卡（易错）

`ONEAPI_DEVICE_SELECTOR=level_zero:0` 里的 **0 不等于 04:00.0**，drm/Level-Zero 编号与物理卡序是错位的
（10-08 记录过：双卡时 `/dev/dri` 是 card1/card2，**没有 card0**）。

现场确认哪个编号是哪张卡：

```bash
ssh <USER>@<SERVER_IP> 'docker run --rm --privileged --pid=host \
  -v /tmp:/tmp -v /opt:/opt ubuntu:24.04 nsenter -t 1 -m -u -i -n -p -- \
  bash -c "export LD_LIBRARY_PATH=/opt/intel/oneapi/compiler/2026.2/lib:/opt/intel/oneapi/umf/1.2/lib; \
           ZES_ENABLE_SYSMAN=1 /opt/intel/oneapi/compiler/2026.2/bin/sycl-ls"'
```

> ⚠️ 路径里的 **`umf/1.2/lib` 不能省**。只给 `compiler/2026.2/lib` 时 L0 适配器加载失败
> （缺 `libumf.so.1`），`sycl-ls` 只输出 `opencl` 两行，看着像 L0 没了。详细报错要加 `--verbose`。

**`sycl-ls` 本身不打印 BDF**（2026-10-28 在 2026.2 上核实，与早期版本的印象不同）。
要映射 device 编号 → BDF，用一个查 `ext_intel_pci_address` 的小程序：
`sycl::ext::intel::info::device::pci_address`，两张卡会分别返回 `0000:04:00.0` / `0000:08:00.0`。

**llama.cpp 双卡各跑一个实例的前提是单卡显存够**（本仓库实测的 9B Q6_K 约 7GB），
两张卡各自独立跑两个实例比跨卡分割更划算 —— 跨卡要 `--split-mode`，带宽不增加。

---

## 五、回滚

任何一步感觉不对，回到单卡可用状态：

```bash
# 单张回滚到 apply 前记录的尺寸
... b580-bar-tool.sh rollback --gpu 0000:xx:00.0

# 或者直接把某张卡缩回 512MB
... b580-bar-tool.sh apply --gpu 0000:xx:00.0 --size 9 --yes
```

最坏情况：内核在 remove 根端口时挂死 → **只能断电重启**（这是工具 README 已声明的固有风险）。
重启后 `b580-rebar.service` 会自动跑，不用手敲命令。

---

## 六、现场请记录这些数（回来我据此继续）

1. `gpu-topology.sh` 的**完整输出**（两张卡的 BDF / 根端口 / 窗口）
2. 第二张卡的**实际 BDF**（插 `00:03.0` 槽预期 `06:00.0`；**不是 05:00.0**，那个是卡1 的音频）
3. 扩完两张后的**根端口窗口大小**（涨到多少）
4. `sycl-ls` 输出里两张卡的 **device 编号 → BDF** 对应关系
5. `dmesg | grep -i xe` 有没有 `failed to enable GuC scheduling policies: -ETIME`
   （这张板子的 08:00.0 历史上有这个 GuC 挂死毛病）
6. 两张卡各自的**风扇转速 / 温度**（`hwmon`，双卡散热是机箱层面的实际约束）

---

## 七、已经做好的准备（无需现场再弄）

| 项 | 状态 |
|---|---|
| `b580-rebar.service` 开机自愈 | 已装、已 enable，**BDF 动态识别**，不再写死 04:00.0 |
| `b580-rebar-late.service` 兜底 | 已装、已 enable，`--check` 通过就 skip |
| `gpu-topology.sh` | 已装 `/opt/b580-bar-tool/`，单卡实测通过 |
| `rebar-autofix.sh` | 已装 `/opt/b580-bar-tool/`，单卡 `--check` 实测通过 |
| SYCL / Vulkan 双后端基线与双卡实测 | 已测、已入档 `bench/reports/dual-gpu-sycl-vs-vulkan.md` |
