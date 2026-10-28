#!/bin/bash
# =============================================================================
# gpu-topology.sh — 拓扑体检报告（装机 / 换卡 / 换槽 / 拔卡后的第一条命令）
#
# 只读脚本，不改动任何设备状态。它做两件事：
#   1. 把 lib/topology.sh 探测到的结果**原样呈现**（不掺任何写死的假设）
#   2. 据此给出"下一步该跑什么"的结论
#
# 为什么要先探测再动手：
#   扩 BAR 需要 remove 桥设备，而 remove 一个桥会摘掉它**整个子树**。
#   能摘到多高取决于子树里有没有别人的设备 —— 这在不同的主板、不同的
#   插槽、不同代的 BIOS 上都不相同，无法写死，只能现场探测。
#
# 输出三段：
#   [A] 每张卡的逐项事实（身份 / 驱动 / drm / ECAP / BAR2 / 锚点 / 窗口）
#   [B] 按安全锚点分组（同组必须一起处理）
#   [C] 结论：策略（atomic / batch）、每张需要的窗口、命令
#
# 用法：
#   gpu-topology.sh            # 人类可读报告
#   gpu-topology.sh --plan     # 只打印计划（不看表格）
#   gpu-topology.sh --env      # 输出可 source 的变量，供其它脚本消费
#   gpu-topology.sh -v         # 附加 sysfs 路径链
#
#   TOPO_DEV_IDS="8086:e20b 8086:1234" gpu-topology.sh   # 指定目标型号（可多选）
#
# 需要 root 才能读配置空间（ECAP / ReBAR 能力）。非 root 时这些列显示 "?"，
# 其余信息仍可读；完整体检请走 root 通道（见文件末尾提示）。
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/topology.sh
. "$HERE/lib/topology.sh" || { echo "缺少 lib/topology.sh（与本脚本同目录的 lib/）" >&2; exit 1; }

TARGET_N="${TARGET_N:-14}"          # 14 → 2^(14+20) = 16GB
MODE=report
VERBOSE=0
for a in "$@"; do
    case "$a" in
        --plan) MODE=plan ;;
        --env)  MODE=env ;;
        -v)     VERBOSE=1 ;;
        *) echo "未知参数：$a（可用 --plan / --env / -v）" >&2; exit 2 ;;
    esac
done

WANT_MB=$(( (1 << (TARGET_N + 20)) / TOPO_MB ))
AM_ROOT=0
[ "$(id -u)" -eq 0 ] && AM_ROOT=1

# 非 root 读不到配置空间：ReBAR 能力给 "?"，绝不能报成 "no"
rebar_state() {
    if [ "$AM_ROOT" -eq 0 ]; then echo "?"; return; fi
    if [ -n "$(topo_ecap "$1" 2>/dev/null)" ]; then echo "yes"; else echo "no"; fi
}

# ECAP 偏移 / 支持档位（仅 root 可读）
rebar_detail() {
    local bdf="$1" off caps n list=""
    off="$(topo_ecap "$bdf" 2>/dev/null)" || return 0
    caps="$(setpci -s "$bdf" "$(printf '%x' $((off + 4))).l" 2>/dev/null)"
    [ -n "$caps" ] || return 0
    local v; v=$(( 0x$caps ))
    for n in 8 9 10 11 12 13 14 15; do
        (( (v >> (4 + n)) & 1 )) && list="$list $(( (1 << (n + 20)) / TOPO_MB ))MB"
    done
    echo "ecap=0x$(printf '%x' "$off")  支持档位:${list:- 无}"
}

# ---------------------------------------------------------------- 报告头 -----

echo "================= 显示设备拓扑体检 $(date '+%F %T') =================="
echo "目标型号: $TOPO_DEV_IDS     目标 BAR2: ${WANT_MB}MB (N=$TARGET_N)"
echo

mapfile -t BFDS < <(topo_enumerate)
if [ "${#BFDS[@]}" -eq 0 ]; then
    echo "未发现目标设备（$TOPO_DEV_IDS）。"
    echo "  · 卡没插好/没上电 → dmesg | grep -iE 'xe|0000:'"
    echo "  · 不是这个型号 → TOPO_DEV_IDS=\"厂商:设备\" $0"
    exit 1
fi

# ---------------------------------------------------------------- [A] 明细 ----

printf "%-14s %-11s %-8s %-18s %-6s %-9s %-13s %-9s\n" \
       BDF ID DRIVER DRM REBAR BAR2 安全锚点 锚点窗口
printf "%-14s %-11s %-8s %-18s %-6s %-9s %-13s %-9s\n" \
       -------------- ----------- -------- ------------------ ------ --------- ------------- ---------

for bdf in "${BFDS[@]}"; do
    drv="$(basename "$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null)" 2>/dev/null)"
    drm="$(topo_drm "$bdf" | xargs)"
    anc="$(topo_anchor "$bdf" 2>/dev/null || echo '?')"
    win="$(topo_window_mb "$anc" 2>/dev/null || echo 0)"
    printf "%-14s %-11s %-8s %-18s %-6s %-9s %-13s %-9s\n" \
           "$bdf" "$(topo_vendor_dev "$bdf")" "${drv:-none}" "${drm:--}" \
           "$(rebar_state "$bdf")" "$(topo_bar2_mb "$bdf")MB" "$anc" "${win}MB"
    detail="$(rebar_detail "$bdf")"
    [ -n "$detail" ] && echo "    能力   : $detail"
    if [ "$VERBOSE" -eq 1 ]; then
        echo "    祖先链 : $(topo_ancestors "$bdf" | xargs)"
        echo "    根端口 : $(topo_root_port "$bdf" 2>/dev/null || echo '-')"
        echo "    sysfs  : $(realpath "/sys/bus/pci/devices/$bdf")"
    fi
done

# [B] 分组 -------------------------------------------------------------------

echo
echo "--------------------- 按安全锚点分组 ---------------------"
echo "（安全锚点 = 再往上摘就会碰到别人设备的那一级；优先摘它）"
echo
while IFS='|' read -r anc cnt win need strategy note; do
    echo "锚点 $anc   卡片数 $cnt   当前窗口 ${win}MB   需要 ${need}MB   策略 $strategy"
    [ -n "$note" ] && echo "   ⚠ $note"
    # 列出该组内的卡
    while read -r line; do
        set -- $line
        [ "$1" = "$anc" ] || continue
        shift
        for b in "$@"; do
            printf "   └─ %-14s BAR2=%sMB\n" "$b" "$(topo_bar2_mb "$b")"
        done
    done < <(topo_groups)
    [ "$win" -lt "$need" ] && echo "   窗口不足，需内核 rescan 重新分配（pci=realloc 生效时可行）"
    echo
done < <(topo_plan "$TARGET_N")

# [C] 结论 -------------------------------------------------------------------

STRATEGY="$(topo_strategy "$TARGET_N")"
n=${#BFDS[@]}

if [ "$MODE" = "env" ]; then
    echo "------- 可 source 的变量 -------"
    echo "TOPO_CARD_COUNT=$n"
    echo "TOPO_CARDS=\"${BFDS[*]}\""
    echo "TOPO_STRATEGY=$STRATEGY"
    i=0
    while IFS='|' read -r anc cnt win need strategy note; do
        echo "TOPO_G${i}_ANCHOR=$anc"
        echo "TOPO_G${i}_COUNT=$cnt"
        echo "TOPO_G${i}_WINDOW=$win"
        echo "TOPO_G${i}_NEED=$need"
        echo "TOPO_G${i}_STRATEGY=$strategy"
        i=$((i + 1))
    done < <(topo_plan "$TARGET_N")
    echo "TOPO_GROUP_COUNT=$i"
    exit 0
fi

echo "--------------------- 结论与下一步 ---------------------"
echo "目标设备 $n 张，整体策略：$STRATEGY"

case "$STRATEGY" in
    atomic)
        echo "→ 每张卡独占一个锚点，互不影响，**逐张处理即可**。"
        echo "  单卡原子命令（对每张重复一次）："
        for bdf in "${BFDS[@]}"; do
            echo "    b580-bar-tool.sh apply --gpu $bdf --size $TARGET_N --yes"
        done
        ;;
    batch)
        echo "→ 存在「同一锚点下多张卡」的分组，**必须整组一次结算**："
        echo "  逐张 apply 时，第 2 次 rescan 可能把先扩好的那张挤小，"
        echo "  而 apply 只校验目标卡 → 会报成功、另一个静默降级。"
        echo "    rebar-batch.sh            # 按锚点分组，逐组一次性 remove+rescan"
        ;;
esac

[ "$AM_ROOT" -eq 0 ] && {
    echo
    echo "⚠ 非 root 运行：REBAR / ECAP 列为 \"?\"，窗口值可能不全。完整体检请走 root 通道："
    echo "    sudo $0"
}
echo "======================================================"
