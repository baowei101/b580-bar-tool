#!/bin/bash
# run-bench.sh — 同一模型、同一参数，对比官方 Vulkan 与 SYCL 构建
# 用法:
#   ./run-bench.sh                 # 跑两个后端，默认模型 Qwen3.5-9B-Q6_K
#   MODEL=/path/to.gguf ./run-bench.sh
#   ONLY=sycl ./run-bench.sh       # 只跑一个：vulkan | sycl
set -u

BASE=${BASE:-$PWD/b11925}
MODEL=${MODEL:-$PWD/model/Qwen3.5-9B-Q6_K.gguf}
REPS=${REPS:-3}
PP=${PP:-512}
TG=${TG:-128}
ONLY=${ONLY:-both}

VK_DIR=$BASE/vulkan-x64
SYCL_DIR=$BASE/sycl-fp16-x64
OUT=$BASE/reports

# oneAPI 运行库：官方 SYCL 二进制不发静态链接，需要系统里的 libsycl + libumf
# libdnnl.so.3 是 libggml-sycl.so 的硬依赖，系统没装（也不想为此装系统包），
# 用 apt-get download + dpkg-deb -x 解到本地 dnnl-root，只走 LD_LIBRARY_PATH
oneapi_env() {
  local dnnl="$BASE/dnnl-root/opt/intel/oneapi/redist/lib"
  export LD_LIBRARY_PATH="$SYCL_DIR:$dnnl:/opt/intel/oneapi/compiler/2026.2/lib:/opt/intel/oneapi/compiler/2026.2/lib/x86_64-linux-gnu:/opt/intel/oneapi/mkl/2026.2/lib:/opt/intel/oneapi/tbb/2023.2/lib:/opt/intel/oneapi/umf/1.2/lib:${LD_LIBRARY_PATH:-}"
  export ONEAPI_DEVICE_SELECTOR="level_zero:0"
  export ZES_ENABLE_SYSMAN=1
}

die() { echo "✗ $*" >&2; exit 1; }

[ -f "$MODEL" ] || die "模型不存在: $MODEL"
mkdir -p "$OUT"

# llama-bench 输出会带后端信息，统一 md 表格方便并排比
bench() {
  local tag=$1 dir=$2
  local bin=$dir/llama-bench
  [ -x "$bin" ] || die "找不到 llama-bench: $bin"

  echo "=============================================================="
  echo ">>> $tag   ($dir)"
  echo "=============================================================="
  # 加载一段日志留证：实际用的是哪个后端、哪块卡
  "$bin" -m "$MODEL" -ngl 99 -p "$PP" -n "$TG" -r "$REPS" 2>&1 \
    | tee "$OUT/$tag.log" \
    | grep -vE "^(ggml_|load_|llama_model_loader:)" || true
  # 只保留表格部分成报告
  grep -E "^\|" "$OUT/$tag.log" > "$OUT/$tag.md" 2>/dev/null || true
}

if [ "$ONLY" = "both" ] || [ "$ONLY" = "vulkan" ]; then
  export GGML_VK_VISIBLE_DEVICES=0
  bench vulkan "$VK_DIR"
fi

if [ "$ONLY" = "both" ] || [ "$ONLY" = "sycl" ]; then
  oneapi_env
  bench sycl-fp16 "$SYCL_DIR"
fi

echo
echo "=== 汇总 ==="
for f in "$OUT"/*.md; do [ -s "$f" ] && { echo "--- $f"; cat "$f"; }; done
