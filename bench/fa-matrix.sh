#!/bin/bash
# fa-matrix.sh — flash-attention 开关 × 后端 的对照矩阵
# 背景：Vulkan 默认 -fa auto 会启用 FA，但在这块 B580 上 FA 让 prefill 明显变慢。
#   要判断"后端差异"必须把这个开关分开算。
#
# 踩坑（2026-10-27 实测）：同一 shell 里先跑 SYCL 再跑 Vulkan，SYCL 的 LD_LIBRARY_PATH
# 会残留，导致 Vulkan 二进制额外加载 libggml-sycl.so，表格 backend 列变成 "SYCL,Vulkan"，
# 数据完全作废。所以每次 measurement 都用 env -i 起干净环境，并打印 backend 列自证。
set -u
BASE=${BASE:-$PWD/b11925}
M4=${M4:-$PWD/model/Qwen3-4B-Instruct-2507-Q8_0.gguf}
M9=${M9:-$PWD/model/Qwen3.5-9B-Q6_K.gguf}
RUNPATH=/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin

SYCL_LDP="$BASE/sycl-fp16-x64:$BASE/dnnl-root/opt/intel/oneapi/redist/lib:/opt/intel/oneapi/compiler/2026.2/lib:/opt/intel/oneapi/compiler/2026.2/lib/x86_64-linux-gnu:/opt/intel/oneapi/mkl/2026.2/lib:/opt/intel/oneapi/tbb/2023.2/lib:/opt/intel/oneapi/umf/1.2/lib"

run() {  # run <vulkan|sycl> <模型标签> <模型路径> <pp> <fa>
  local be=$1 lbl=$2 m=$3 pp=$4 fa=$5 out
  if [ "$be" = "vulkan" ]; then
    out=$(env -i PATH=$RUNPATH HOME="$HOME" GGML_VK_VISIBLE_DEVICES=0 \
      "$BASE/vulkan-x64/llama-bench" -m "$m" -ngl 99 -p "$pp" -n 128 -r 2 -fa "$fa" 2>/dev/null)
  else
    out=$(env -i PATH=$RUNPATH HOME="$HOME" LD_LIBRARY_PATH="$SYCL_LDP" \
      ONEAPI_DEVICE_SELECTOR=level_zero:0 ZES_ENABLE_SYSMAN=1 \
      "$BASE/sycl-fp16-x64/llama-bench" -m "$m" -ngl 99 -p "$pp" -n 128 -r 2 -fa "$fa" 2>/dev/null)
  fi
  printf "%-6s %-3s p%-5s fa=%s | " "$be" "$lbl" "$pp" "$fa"
  echo "$out" | grep -E "^\| qwen" | sed -e "s/|/ /g" -e "s/  */ /g" -e "s/^ //"
  echo
}

echo "########## pp512 ##########"
for fa in 0 1; do for be in vulkan sycl; do
  run $be M4 "$M4" 512 $fa
  run $be M9 "$M9" 512 $fa
done; done

echo "########## pp4096 ##########"
for fa in 0 1; do for be in vulkan sycl; do
  run $be M4 "$M4" 4096 $fa
  run $be M9 "$M9" 4096 $fa
done; done
