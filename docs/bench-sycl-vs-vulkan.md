# SYCL vs Vulkan 实测对照（Arc B580 / b11925 官方包）

> 日期：2026-10-27 · 机器：<SERVER_IP> · 卡：Arc B580 12GB（`8086:e20b`，单卡）
> 目的：判断今后 GPU 推理该用 Vulkan 还是 SYCL 后端
>
> **本文全部为单卡数据。双卡（两卡对称性、并行损耗）见
> [`bench/reports/dual-gpu-sycl-vs-vulkan.md`](../bench/reports/dual-gpu-sycl-vs-vulkan.md)（2026-10-28）。**

## 1. 前置条件（不做这些，SYCL 根本跑不起来）

| 项 | 要求 | 本机做法 |
|---|---|---|
| BAR 大小 | 必须 16GB | `b580-bar-tool.sh apply --size 14`（重启后会退回 512MB） |
| 包 | `llama-bXXXXX-bin-ubuntu-sycl-fp16-x64.tar.gz` | 官方每晚 release（**没有**笼统的 `sycl-x64` 了，按精度拆成 fp16 / fp32） |
| oneAPI 运行库 | libsycl.so.9 / libimf / libsvml / libirng / libintlc / libiomp5 / MKL / TBB | 系统已有 `/opt/intel/oneapi`（compiler 2026.2 / mkl 2026.2 / tbb 2023.2 / umf 1.2） |
| `libdnnl.so.3` | `libggml-sycl.so` 的**硬依赖**，系统没装 | `apt-get download intel-oneapi-runtime-dnnl` + `dpkg-deb -x` 解到 `dnnl-root/`，只走 `LD_LIBRARY_PATH`，**不装系统包、不动 root** |

运行时环境（`bench/run-bench.sh` 已封装）：

```bash
export LD_LIBRARY_PATH="<sycl包目录>:<dnnl-root>/opt/intel/oneapi/redist/lib:/opt/intel/oneapi/compiler/2026.2/lib:/opt/intel/oneapi/mkl/2026.2/lib:/opt/intel/oneapi/tbb/2023.2/lib:/opt/intel/oneapi/umf/1.2/lib"
export ONEAPI_DEVICE_SELECTOR=level_zero:0   # 单卡，钉死索引防选错
```

## 2. 测试方法

- 同一构建号 **b11925**，官方 `vulkan-x64` 与 `sycl-fp16-x64` 两个包，只差后端
- 同一模型、同一参数：`-ngl 99 -n 128 -r 2`
- 两个模型：Qwen3.5-9B Q6_K（稠密 9B）、Qwen3-4B-Instruct-2507 Q8_0（稠密 4B）
- 两种 prefill 长度：512 / 4096
- **flash-attention 单列一维**（`-fa 0/1`）—— 见第 4 节，FA 在 Vulkan 上是负优化
- 每次测量用 `env -i` 起干净环境：同一 shell 里先跑 SYCL 再跑 Vulkan，残留的
  `LD_LIBRARY_PATH` 会让 Vulkan 二进制额外加载 `libggml-sycl.so`，表格 backend 列变成
  `SYCL,Vulkan`，数据作废（实测踩到过一次）

## 3. 结果（t/s，越高越好）

### 9B Q6_K

| 测试 | Vulkan fa=0 | Vulkan fa=1 | SYCL fa=0 | SYCL fa=1 |
|---|---:|---:|---:|---:|
| pp512 | 1858.5 | 1815.2 | 2224.7 | **2236.2** |
| tg128（512 上下文） | 45.57 | 45.35 | 53.04 | **53.12** |
| pp4096 | 1856.6 | 1460.7 | 2094.7 | **2207.8** |
| tg128（4096 上下文） | 45.45 | 45.61 | 52.97 | **53.13** |

### 4B Q8_0

| 测试 | Vulkan fa=0 | Vulkan fa=1 | SYCL fa=0 | SYCL fa=1 |
|---|---:|---:|---:|---:|
| pp512 | 3822.5 | 3217.2 | 3425.8 | **4277.1** |
| tg128（512 上下文） | 76.07 | 76.37 | 48.29 | **80.61** |
| pp4096 | 2749.9 | 1155.6 | 2049.0 | **3932.4** |
| tg128（4096 上下文） | 76.21 | 75.72 | 49.09 | **80.55** |

### 各自最优配置对比

| 指标 | Vulkan 最优 | SYCL 最优 | SYCL 领先 |
|---|---:|---:|---:|
| 9B pp512 | 1858.5 | 2236.2 | **+20.3%** |
| 9B pp4096 | 1856.6 | 2207.8 | **+18.9%** |
| 9B tg | 45.6 | 53.1 | **+16.5%** |
| 4B pp512 | 3822.5 | 4277.1 | **+11.9%** |
| 4B pp4096 | 2749.9 | 3932.4 | **+43.0%** |
| 4B tg | 76.4 | 80.6 | **+5.5%** |

**6 项全胜，没有一项落后。**

## 4. 最意外的发现：flash-attention 在两个后端上方向相反

| 模型 / 长度 | Vulkan fa=0 → fa=1 | SYCL fa=0 → fa=1 |
|---|---|---|
| 4B pp4096 | 2749.9 → 1155.6（**砍 58%**） | 2049.0 → 3932.4（**+92%**） |
| 9B pp4096 | 1856.6 → 1460.7（砍 21%） | 2094.7 → 2207.8（+5%） |
| 4B tg | 76.1 → 76.4（无差） | 48.3 → 80.6（**+67%**） |

而 b11925 的默认是 `-fa auto`，在 Vulkan 上等价于**开**。也就是说：

- **Vulkan 现状是被 FA 拖累的**：4B 在 4096 上下文下关掉 FA 能从 1156 回到 2750（+138%）
- **SYCL 必须开 FA**：关掉后 4B 的 tg 从 80.6 掉到 48.3

这条比"选哪个后端"更容易立刻见效 —— 现役 8092/8093/8094 三个 Vulkan 服务如果没有显式设 `-fa`，
值得查一下是不是也被这个默认值拖慢了。

## 5. 结论与建议

1. **新部署一律优先 SYCL**：prefill 尤其长上下文优势明显（4B 4096 上下文 +43%），tok/s 生成也稳定更高。
2. **旧 Vulkan 服务先查 `-fa`**：若默认 auto 且卡上 FA 是负优化，加 `-fa 0` 可能比换后端更省事。
3. **SYCL 上别关 FA**，两个模型 tg 都依赖它。
4. 上生产前必须解决 **BAR 扩容不持久**（重启回 512MB，SYCL 随之不可用）→ 需要 systemd oneshot 开机自愈。
5. **双卡场景已测**（2026-10-28）：两张卡完全对称（同后端差 ≤0.8%），两个后端双卡并行都近乎零损耗
   （Vulkan −0.01%、SYCL −0.7%），因此分片/并行可以放心用。详见双卡报告。

## 6. 数据可信度与局限

- 测量时目标机上另有 3 个 llama-server（8092 rerank / 8093 ASR / 8094 OCR）在跑，占用部分显存与算力。
  两个后端在**相同干扰条件下**测得，横向对比成立；绝对值会低于空载机器。
- `-r 2` 重复次数偏少（默认 5），标准差已记录在 `reports/fa-matrix.txt`，均 <1%。
- 只测了稠密模型，未测 MoE（Qwen3.6-35B-A3B 22GB 超出 12GB 显存）。
- 只测了 `llama-bench`，未测 `llama-server` 真实并发/批处理路径。

## 7. 复现

```bash
# 在目标机器上（BASE / MODEL 均可用同名环境变量覆盖，默认取当前目录）
cd <b11925 包解压目录>
./run-bench.sh                 # 两个后端 × 512 上下文
PP=4096 ./run-bench.sh         # 4096 上下文
./fa-matrix.sh                 # FA 开关 × 后端 完整矩阵
# 原始数据：bench/reports/fa-matrix.txt（完整矩阵）+ 各轮 md
```
