#!/bin/bash
# =============================================================================
# rebar-autofix.sh — 自动发现目标设备并扩 BAR2（供 systemd 调用，也可手工跑）
#
# 它只做三件事：探测 → 选路 → 交给执行脚本。所有"机器长什么样"的判断
# 都来自 lib/topology.sh，脚本本身不含任何 BDF / 槽位 / ECAP 偏移。
#
# 选路规则（由探测结果决定，不是写死的）：
#   topo_strategy = atomic  每张卡独占锚点，互不影响
#                            → 逐张调 b580-bar-tool.sh apply（最成熟的单卡路径）
#   topo_strategy = batch   存在"同一锚点下多张卡"的分组
#                            → 交给 rebar-batch.sh 一次性结算
#                              （逐张 apply 会让后一张把前一张挤小，
#                                而 apply 只校验目标卡 → 报成功、静默降级）
#
# 为什么不能把 BDF 写死：
#   换卡/插卡后 BDF 会变。写死某个 BDF 的后果是 Condition 不满足直接 skip ——
#   BAR 没扩、上层推理全废，而且日志里一个字都没有。
#
# 用法：
#   rebar-autofix.sh           # 扩到 16GB（N=14）
#   rebar-autofix.sh 13        # 扩到 8GB
#   rebar-autofix.sh --check   # 只检查并报警，不修改
#
# 退出码（三档）：
#   0 = 全部目标设备 BAR2 已达标
#   1 = 有目标设备未达标，或某张卡求不出安全锚点
#   3 = 一个目标设备都没找到（--check 也返回 3，不能返回 0）
#
#   TOPO_DEV_IDS="8086:e20b 8086:1234" rebar-autofix.sh   # 多型号
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 主脚本位置要认两种布局：部署布局（tools/ 内容平铺到 /opt/b580-bar-tool/，
# 主脚本同级）与仓库布局（tools/ 是子目录，主脚本在上一级）。只认前者时，
# 从仓库直接跑会在 atomic 分支里对着不存在的路径执行，systemd 下表现为
# "ExecStart 成功但 BAR 没变"。
find_tool() {
    local c
    for c in "$HERE/b580-bar-tool.sh" "$HERE/../b580-bar-tool.sh"; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
TOOL="${B580_TOOL:-$(find_tool)}"
BATCH="${B580_BATCH:-$HERE/rebar-batch.sh}"

# shellcheck source=lib/topology.sh
. "$HERE/lib/topology.sh" || { echo "缺少 lib/topology.sh" >&2; exit 1; }

SIZE_N=14                 # 14 → 2^(14+20) = 16GB
CHECK_ONLY=0

case "${1:-}" in
    --check) CHECK_ONLY=1 ;;
    "" ) ;;
    *[!0-9]*) echo "参数无效：$1（要 4-28 的数字，或 --check）" >&2; exit 2 ;;
    * ) SIZE_N="$1" ;;
esac

WANT_MB=$(( (1 << (SIZE_N + 20)) / TOPO_MB ))

# 退出码语义（三档，全脚本一致）：
#   0 = 全部目标设备 BAR2 已达标
#   1 = 有目标设备未达标（或无法判定锚点）
#   3 = 一个目标设备都没找到（卡被拔/未上电/型号不匹配）
# ★ --check 必须返回 3 而不是 0：b580-rebar-late.service 的 ExecCondition 是
#   '! rebar-autofix.sh --check'，返回 0 会让兜底在"设备根本没回来"这个
#   最需要它的场景里直接跳过 —— 那正是早期 unit 超时被打断后的状态。
mapfile -t BFDS < <(topo_enumerate)
if [ "${#BFDS[@]}" -eq 0 ]; then
    echo "未检测到目标设备（$TOPO_DEV_IDS）—— 卡被拔掉、未上电，或型号不匹配"
    echo "  型号不匹配时用 TOPO_DEV_IDS=\"厂商:设备\" 指定"
    [ "$CHECK_ONLY" -eq 1 ] && { echo "CHECK 无法判定：没有可检查的目标设备" >&2; exit 3; }
    exit 0
fi

echo "检测到 ${#BFDS[@]} 张目标设备：${BFDS[*]}"

# 求不出安全锚点的卡会被分组逻辑跳过（它所在子树里还有别人的设备）。
# 绝不静默放过：宁可不做，也不能让"这张卡没扩"藏在成功的日志里。
MISSING_ANCHOR="$(topo_ungrouped | tr '\n' ' ')"
if [ -n "${MISSING_ANCHOR// /}" ]; then
    echo "ERROR 以下目标设备求不出安全锚点（子树上还挂着别的设备，不做）：" >&2
    for b in $MISSING_ANCHOR; do echo "        $b" >&2; done
    echo "      先看拓扑：$HERE/gpu-topology.sh" >&2
    echo "      原因通常是同一条根端口/桥下还有 NVMe、网卡或独立声卡。" >&2
    exit 1
fi

# ---------------------------------------------------------------- 自检模式 ----

# 自检要覆盖三件事：BAR2 是否达标、锚点是否识别得出、驱动是否绑定。
# 只看 BAR2 会漏掉"BAR 够了但驱动没起来"这种半好状态。
run_check() {
    local bad=0 b mb anc drv
    for b in "${BFDS[@]}"; do
        mb="$(topo_bar2_mb "$b")"
        anc="$(topo_anchor "$b" 2>/dev/null || echo '?')"
        drv="$(basename "$(readlink "/sys/bus/pci/devices/$b/driver" 2>/dev/null)" 2>/dev/null)"
        if [ "$mb" -eq "$WANT_MB" ]; then
            echo "OK   $b  BAR2 = ${mb}MB  锚点 $anc  驱动 ${drv:-none}"
        else
            echo "FAIL $b  BAR2 = ${mb}MB，期望 ${WANT_MB}MB  （锚点 $anc  驱动 ${drv:-none}）" >&2
            bad=$((bad + 1))
        fi
    done
    if [ "$bad" -gt 0 ]; then
        local msg="【警告】${bad} 张目标设备的 BAR2 未达 ${WANT_MB}MB，SYCL 将不可用（详见 journalctl -u b580-rebar）"
        echo "$msg" | systemd-cat -t b580-rebar -p err 2>/dev/null || true
        echo "$msg" >&2
        wall "$msg" 2>/dev/null || true
        return 1
    fi
    return 0
}

if [ "$CHECK_ONLY" -eq 1 ]; then
    run_check
    exit $?
fi

# ---------------------------------------------------------------- 选路 --------

STRATEGY="$(topo_strategy "$SIZE_N")"
echo "探测结论：策略 = $STRATEGY"

if [ "$STRATEGY" = "batch" ]; then
    if [ -x "$BATCH" ]; then
        echo "存在多卡共用锚点的分组 → 转批量模式（先写全部 Control，再一次 rescan）"
        exec "$BATCH" "$SIZE_N"
    fi
    echo "WARN 需要批量模式但 $BATCH 不可执行 —— 拒绝退回逐张 apply" >&2
    echo "WARN 逐张跑可能把先扩好的卡挤小且不报错，宁可不动" >&2
    exit 1
fi

# atomic：每张独占锚点，逐张走最成熟的单卡路径
if [ ! -x "$TOOL" ]; then
    echo "ERROR 找不到可执行的主脚本 b580-bar-tool.sh" >&2
    echo "      已试：$HERE/b580-bar-tool.sh 与 $HERE/../b580-bar-tool.sh" >&2
    echo "      用 B580_TOOL=<绝对路径> 指定，或检查部署布局是否完整" >&2
    exit 1
fi
fail=0
for b in "${BFDS[@]}"; do
    echo "===== 处理 $b（锚点 $(topo_anchor "$b" 2>/dev/null || echo '?')）====="
    if "$TOOL" apply --gpu "$b" --size "$SIZE_N" --yes; then
        echo "---- $b 完成，BAR2 = $(topo_bar2_mb "$b")MB ----"
    else
        echo "!!!! $b 扩容失败（见上方日志）" >&2
        fail=1
    fi
done

exit "$fail"
