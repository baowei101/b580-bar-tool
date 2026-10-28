#!/bin/bash
# =============================================================================
# rebar-batch.sh — 按"安全锚点"分组，逐组一次性扩 BAR2
#
# 为什么需要"分组"这个概念
# ------------------------
# 扩 BAR 必须 remove 一个桥（摘掉它整个子树），让内核重新分配窗口。
# 一个锚点下如果有多张卡，它们在同一次 rescan 里一起结算：
#
#   第 1 次 rescan：卡A=16G 卡B=512M   → 窗口 16.5G 够用，卡A 成功
#   第 2 次 rescan：卡A=16G 卡B=16G    → 窗口需 32.5G
#
# 第 2 次若内核分配不理想，可能把卡A 从 16G 挤成 8G，而"单卡原子"的 apply
# 只校验目标卡 —— 它会报成功，卡A 却静默降级，直到上层推理报错才发现。
#
# 所以本脚本反着做：先把**同一锚点下所有卡**的 Control 都写成目标值，
# 再一次 remove + 一次 rescan，让内核按总需求一次算窗口。
#   ⇒ 要么全部达标，要么全部回滚，没有中间态。
#
# 分组是探测出来的，不是写死的
# ---------------------------
# 目标设备、ECAP 偏移、锚点层级全部来自 lib/topology.sh：
#   · 各卡独占锚点 → 每组 1 张，跑起来等价于逐张 apply，互不影响
#   · 多卡共用锚点 → 本脚本的一次性结算才有意义
# 两种拓扑都处理，换主板不用改代码。
#
# 用法
# ----
#   rebar-batch.sh            # 全部扩到 16GB（N=14）
#   rebar-batch.sh 13         # 全部扩到 8GB
#   rebar-batch.sh --plan     # 只打印计划，不动任何硬件
#   rebar-batch.sh --check    # 只检查当前尺寸，不修改
#                             # 退出码：0 达标 / 1 未达标 / 3 无目标设备
#
#   TOPO_DEV_IDS="8086:e20b 8086:1234" rebar-batch.sh   # 多型号
#
# 安全
# ----
#   - 锚点子树内出现任何"别人的设备"（NVMe / 网卡 / RAID 卡等未知 class）
#     一律拒绝执行，绝不"试着摘一下"
#   - remove 之前解绑子树叶子驱动（桥保持绑定），避免内核 UAF
#   - 逐张记录原始 Control，失败时全部恢复原值再 rescan
#   - rescan 前后对整机 PCI 设备做 BAR 快照比对，用证据说明"没动别人"
#   - 不写任何持久配置；重启即恢复 BIOS 默认
# =============================================================================

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/topology.sh
. "$HERE/lib/topology.sh" || { echo "缺少 lib/topology.sh（与本脚本同目录的 lib/）" >&2; exit 1; }

readonly SIZE_MASK=0x3F00           # ReBAR Control bits[13:8]
readonly LOG_FILE="${B580_REBAR_LOG:-/var/log/b580-rebar-batch.log}"

TARGET_N=14                         # 14 → 2^(14+20) = 16GB
MODE=apply

# ---------------------------------------------------------------- 基础工具 ----

say() {
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    echo "[$ts] $*"
    [ -w "$(dirname "$LOG_FILE")" ] && echo "[$ts] $*" >> "$LOG_FILE" 2>/dev/null
    return 0
}

die() { say "ERROR $*" >&2; exit 1; }

hx() { echo $(( 0x$1 )); }          # setpci 输出（纯 hex，无 0x 前缀）转十进制

want_mb() { echo $(( (1 << (TARGET_N + 20)) / TOPO_MB )); }

# ------------------------------------------------------ 每张卡的寄存器操作 ----
# 偏移来自 topo_ecap()（遍历扩展能力链得到），不同型号的卡可以不同。

rebar_off() { topo_ecap "$1"; }     # 该卡 ReBAR ECAP 基址（十进制）

ctl_read() {                        # $1=BDF → Control 寄存器原始 hex
    local off; off="$(rebar_off "$1")" || return 1
    setpci -s "$1" "$(printf '%x' $((off + 0x08))).l" 2>/dev/null
}

cap_read() {
    local off; off="$(rebar_off "$1")" || return 1
    setpci -s "$1" "$(printf '%x' $((off + 0x04))).l" 2>/dev/null
}

ctl_size_n() { local v; v="$(hx "$1")"; echo $(( (v & SIZE_MASK) >> 8 )); }

supports_n() {                      # $1=BDF $2=N
    local cap; cap="$(cap_read "$1")" || return 1
    [ -n "$cap" ] || return 1
    local v; v="$(hx "$cap")"
    (( (v >> (4 + $2)) & 1 ))
}

verify_ecap() { rebar_off "$1" >/dev/null; }

# ------------------------------------------------------------ 子树与误伤 ------

# 本组目标卡判定（"显示设备必须属于本组"这条规则用）
in_group() {
    local b="$1" c
    for c in "${cards[@]}"; do [ "$c" = "$b" ] && return 0; done
    return 1
}

# ---------------------------------------------------------------------------
# 误伤检查：remove 锚点会把整个子树摘掉，unbind 也是全子树范围。
# 子树里若还挂着 NVMe / 网卡 / RAID 卡，会被一起拆下来 ——
# 系统盘若在其中就是不可逆的数据事故。
#
# 锚点本身是探测出来的（topo_anchor 只在"子树里只剩自己人"时才继续往上），
# 所以正常情况下这里必然通过。保留这层校验是为了 fail-closed：
# 万一探测逻辑在某种奇特拓扑下判断失误，这里会拦住，而不是"试着摘一下"。
#
# 放行规则：
#   0604 桥          —— 随锚点级联移除，本来就是这条路径
#   0300/0302/0380   —— 显示控制器，必须属于本组目标
#   0403 音频        —— 随卡一起下线；误摘独立声卡仅需重启恢复
#   其它一律阻断
# ---------------------------------------------------------------------------
preflight_subtree() {
    local anc="$1" bdf cls desc bad=0
    for bdf in $(topo_subtree "$anc"); do
        [ "$bdf" = "$anc" ] && continue
        cls="$(topo_class "$bdf")" || { bad=1; continue; }
        desc="$(lspci -s "$bdf" 2>/dev/null | cut -d' ' -f2- | cut -c1-46)"
        case "$cls" in
            0604) : ;;
            0300|0302|0380)
                in_group "$bdf" || {
                    say "  ERROR $bdf [$desc] 是本锚点下的另一张显示设备，不在本组目标内"
                    bad=1
                } ;;
            0403)
                say "  WARN  $bdf [$desc] 音频设备，会随卡一起摘除" ;;
            *)
                say "  ERROR $bdf [$desc] class=$cls 是非显卡设备 —— remove 锚点会误伤它"
                bad=1 ;;
        esac
    done
    return "$bad"
}

# rescan 前后所有 PCI 设备的 BAR 地址快照。
# /sys/bus/pci/rescan 是**全局**的（remove 锚点后只能靠它找回来），
# 无法只扫目标桥 —— 所以必须有事后比对，不能只凭"应该不会动"。
snapshot_bars() {
    local d b
    for d in /sys/bus/pci/devices/*/; do
        b="$(basename "$d")"
        [ -r "$d/resource" ] || continue
        printf '%s:%s\n' "$b" "$(awk 'NF>=2{printf "%s-%s,", $1, $2}' "$d/resource" 2>/dev/null)"
    done | sort
}

report_bar_drift() {
    local before="$1" after="$2" line b n=0
    while read -r line; do
        [ -n "$line" ] || continue
        b="${line%%:*}"
        topo_is_target "$b" && continue
        say "  NOTE 非目标设备 BAR 变化：$line"
        n=$((n + 1))
    done < <(diff <(printf '%s\n' "$before") <(printf '%s\n' "$after") 2>/dev/null \
             | grep '^[<>]' | sed 's/^[<>] //' | sort -u)
    [ "$n" -eq 0 ] && say "  OK   非目标设备的 BAR 地址无变化"
    return 0
}

unbind_leaves() {                    # 解绑锚点子树下的叶子驱动，桥保持绑定
    local anc="$1" bdf cls drv
    for bdf in $(topo_subtree "$anc"); do
        [ "$bdf" = "$anc" ] && continue
        cls="$(topo_class "$bdf")"
        case "$cls" in 0604) continue ;; esac
        [ -e "/sys/bus/pci/devices/$bdf/driver" ] || continue
        drv="$(basename "$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null)")"
        if echo "$bdf" > "/sys/bus/pci/devices/$bdf/driver/unbind" 2>/dev/null; then
            say "    unbind $bdf ($drv)"
        else
            return 1
        fi
    done
    return 0
}

rebind_leaves() {                    # 让内核为已解绑的叶子重新选驱动并绑定
    local anc="$1" bdf cls drv
    for bdf in $(topo_subtree "$anc"); do
        [ "$bdf" = "$anc" ] && continue
        cls="$(topo_class "$bdf")"
        [ "$cls" = "0604" ] && continue
        [ -e "/sys/bus/pci/devices/$bdf" ] || continue
        [ -e "/sys/bus/pci/devices/$bdf/driver" ] && continue
        if echo "$bdf" > /sys/bus/pci/drivers_probe 2>/dev/null; then
            drv="$(basename "$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null)")"
            say "    rebind $bdf (${drv:-无驱动})"
        else
            say "    WARN rebind $bdf 失败，需手工处理"
        fi
    done
}

rescan_and_wait() {                  # $@ = 期望回来的 BDF 列表    echo 1 > /sys/bus/pci/rescan 2>/dev/null || return 1
    local i b missing
    for i in 1 2 3 4 5; do
        missing=0
        for b in "$@"; do
            [ -e "/sys/bus/pci/devices/$b" ] || missing=1
        done
        [ "$missing" -eq 0 ] && { sleep 1; return 0; }
        say "    等待设备重新出现（第 $i 次）..."
        sleep 1
        echo 1 > /sys/bus/pci/rescan 2>/dev/null
    done
    return 1
}

# ------------------------------------------------------- 异常安全 ----
# remove 锚点会让它和整个子树从 sysfs 一起消失，只有 rescan 才回来。
# 若恰好在这两步之间被打断（Ctrl-C / systemd 超时 / SSH 断开），子树就一直消失：
# 卡看不见了，但 Control 寄存器已经改过。用标志 + 记录锚点，在任何退出路径上补 scan。
PCI_TREE_REMOVED=0
ANCHOR_GONE=""
CARDS_EXPECT=""                      # 空格分隔的 BDF 列表

pci_tree_restore() {
    [ "${PCI_TREE_REMOVED:-0}" = "1" ] || return 0
    say "WARN 中断发生在 remove 与 rescan 之间（锚点 ${ANCHOR_GONE:-?}），正在恢复 PCI 子树"
    if [ -n "$CARDS_EXPECT" ]; then
        # shellcheck disable=SC2086
        rescan_and_wait $CARDS_EXPECT && PCI_TREE_REMOVED=0
    fi
    if [ "${PCI_TREE_REMOVED:-0}" = "1" ]; then
        say "ERROR 自动恢复失败，请手动执行：echo 1 | sudo tee /sys/bus/pci/rescan"
        say "ERROR 若仍不出现只能重启；寄存器可能已改为目标尺寸，重启后先跑 --check"
    else
        say "OK PCI 子树已恢复"
    fi
}

on_interrupt() {
    trap - INT TERM HUP EXIT
    pci_tree_restore
    say "ERROR 已被中断（信号），未完成的步骤需要重新执行"
    exit 130
}

trap 'on_interrupt' INT TERM HUP
trap 'pci_tree_restore' EXIT

# ------------------------------------------------------------------ 参数 -----

case "${1:-}" in
    --plan|plan)  MODE=plan ;;
    --check|check) MODE=check ;;
    "") ;;
    *[!0-9]*) echo "参数无效：$1（要 4-28 的整数，或 --plan / --check）" >&2; exit 2 ;;
    *) TARGET_N="$1" ;;
esac

WANT_MB="$(want_mb)"

[ "$(id -u)" -eq 0 ] || [ "$MODE" = "check" ] || [ "$MODE" = "plan" ] \
    || die "执行模式需要 root"

# ------------------------------------------------------------------ 探测 -----

mapfile -t BFDS < <(topo_enumerate)
if [ "${#BFDS[@]}" -eq 0 ]; then
    say "未检测到目标设备（$TOPO_DEV_IDS）—— 卡被拔掉、未上电，或型号不匹配"
    say "  型号不匹配时用 TOPO_DEV_IDS=\"厂商:设备\" 指定"
    # 与 rebar-autofix.sh 同一套三档退出码：0 达标 / 1 未达标 / 3 无目标设备
    [ "$MODE" = "check" ] && exit 3
    exit 0
fi

# 分组来自探测层：每行 "锚点 BDF1 BDF2 ..."
ANCHOR_GROUPS=()
while IFS= read -r g; do [ -n "$g" ] && ANCHOR_GROUPS+=("$g"); done < <(topo_groups)
[ "${#ANCHOR_GROUPS[@]}" -gt 0 ] || die "无法为任何目标设备确定安全锚点"

# 部分卡求不出锚点时，topo_groups 已经把它跳过了 —— 必须挡住，
# 否则结尾会打印"全部目标卡 BAR2 = ..."，而其中一张根本没被处理过。
MISSING_ANCHOR="$(topo_ungrouped | tr '\n' ' ')"
[ -z "${MISSING_ANCHOR// /}" ] \
    || die "以下目标设备求不出安全锚点，已被分组跳过，拒绝执行：$MISSING_ANCHOR"

# ------------------------------------------------------------------ 检查 -----

if [ "$MODE" = "check" ]; then
    bad=0
    for b in "${BFDS[@]}"; do
        mb="$(topo_bar2_mb "$b")"
        anc="$(topo_anchor "$b" 2>/dev/null || echo '?')"
        win="$(topo_window_mb "$anc" 2>/dev/null || echo 0)"
        if [ "$mb" -eq "$WANT_MB" ]; then
            echo "OK   $b  BAR2 = ${mb}MB   锚点 $anc 窗口 ${win}MB"
        else
            echo "FAIL $b  BAR2 = ${mb}MB  期望 ${WANT_MB}MB   （锚点 $anc 窗口 ${win}MB）" >&2
            bad=$((bad + 1))
        fi
    done
    if [ "$bad" -gt 0 ]; then
        say "ERROR ${bad}/${#BFDS[@]} 张未达 ${WANT_MB}MB"
        exit 1
    fi
    exit 0
fi

# ------------------------------------------------------------------ 计划 -----

say "===== ReBAR 扩容器计划（锚点分组由探测得出）====="
say "目标型号 $TOPO_DEV_IDS，检测到 ${#BFDS[@]} 张，目标 BAR2 = ${WANT_MB}MB (N=$TARGET_N)"
say ""
for g in "${ANCHOR_GROUPS[@]}"; do
    set -- $g
    anc="$1"; shift
    cards=("$@")
    win="$(topo_window_mb "$anc" 2>/dev/null || echo 0)"
    echo "锚点 $anc  当前窗口 ${win}MB  本组 ${#cards[@]} 张："
    for b in "${cards[@]}"; do
        cur="$(ctl_read "$b" 2>/dev/null)" || cur=""
        ok="no"; supports_n "$b" "$TARGET_N" && ok="yes"
        printf '  %-14s 当前 N=%-2s (BAR2 %sMB)  ECAP=0x%s  支持 N=%s: %s\n' \
               "$b" "$(ctl_size_n "${cur:-0}")" "$(topo_bar2_mb "$b")" \
               "$(printf '%x' "$(rebar_off "$b" 2>/dev/null || echo 0)")" "$TARGET_N" "$ok"
    done
    echo "  需一次性申请 ${#cards[@]} × ${WANT_MB}MB = $(( ${#cards[@]} * WANT_MB ))MB 窗口"
    echo ""
done

[ "$MODE" = "plan" ] && { say "dry-run 结束，未做任何修改"; exit 0; }

# ------------------------------------------------------------------ 执行 -----

say "===== 开始执行 ====="
overall=0

for g in "${ANCHOR_GROUPS[@]}"; do
    set -- $g
    anc="$1"; shift
    cards=("$@")
    say "---- 锚点 $anc，${#cards[@]} 张卡 ----"

    # 1) 前置校验：每张都必须有 ReBAR 且支持目标尺寸
    for b in "${cards[@]}"; do
        verify_ecap "$b" || die "$b 未找到 Resizable BAR 扩展能力（ECAP ID 0x0015），拒绝继续"
        supports_n "$b" "$TARGET_N" || die "$b 不支持 N=$TARGET_N（${WANT_MB}MB），拒绝继续"
    done

    # 2) 记录原始 Control（回滚用）
    declare -A ORIG=()
    for b in "${cards[@]}"; do
        ORIG["$b"]="$(ctl_read "$b")"
        say "  $b 原始 Control = ${ORIG[$b]} (size N=$(ctl_size_n "${ORIG[$b]}"))"
    done

    # 3) 若全部已达标则跳过，零动作
    all_ok=1
    for b in "${cards[@]}"; do
        [ "$(topo_bar2_mb "$b")" -eq "$WANT_MB" ] || all_ok=0
    done
    if [ "$all_ok" -eq 1 ]; then
        say "  全部已是 ${WANT_MB}MB，跳过（幂等）"
        unset ORIG
        continue
    fi

    # 4) 误伤检查
    say "  检查锚点子树（remove 会连带拆掉整个子树）..."
    if ! preflight_subtree "$anc"; then
        say "  ERROR 锚点 $anc 下存在非本卡设备，拒绝执行"
        say "  ERROR 继续下去会把它一起拆掉（若含系统盘 = 数据事故）"
        unset ORIG
        overall=1
        continue
    fi

    # 5) 解绑叶子驱动
    say "  解绑子树叶子驱动..."
    unbind_leaves "$anc" || die "解绑失败，中止（带绑定驱动 remove 会触发内核 UAF）"
    sync

    # 6) rescan 前快照
    BAR_BEFORE="$(snapshot_bars)"

    # 7) 逐张写 Control（不 rescan）
    for b in "${cards[@]}"; do
        off="$(rebar_off "$b")" || die "$b 无法定位 ECAP"
        cur="$(ctl_read "$b")"
        newv=$(( ($(hx "$cur") & ~SIZE_MASK) | ((TARGET_N << 8) & SIZE_MASK) ))
        hexv="$(printf '%08x' "$newv")"
        say "  写 $b Control → $hexv（ECAP 0x$(printf '%x' "$off")）"
        setpci -s "$b" "$(printf '%x' $((off + 0x08))).l=$hexv" || die "$b 写 Control 失败"
        chk="$(ctl_read "$b")"
        [ "$chk" = "$hexv" ] || die "$b 写入校验失败：期望 $hexv 实际 $chk"
    done
    sync

    # 8) 一次 remove 锚点
    say "  移除锚点 $anc（风险点）"
    ANCHOR_GONE="$anc"
    CARDS_EXPECT="${cards[*]}"
    PCI_TREE_REMOVED=1
    if ! echo 1 > "/sys/bus/pci/devices/$anc/remove" 2>/dev/null; then
        PCI_TREE_REMOVED=0
        say "ERROR 移除锚点失败，回滚 Control"
        for b in "${cards[@]}"; do
            if [ ! -e "/sys/bus/pci/devices/$b" ]; then
                say "    ERROR $b 不在总线上，无法写回"
                continue
            fi
            if ! off="$(rebar_off "$b" 2>/dev/null)"; then
                say "    ERROR $b 定位不到 ReBAR ECAP，无法写回"
                continue
            fi
            # setpci 的退出码不代表真的写进去了，必须回读比对
            rb_want="$(printf '%08x' "$(hx "${ORIG[$b]}")")"
            if setpci -s "$b" "$(printf '%x' $((off + 8))).l=$rb_want" 2>/dev/null \
                && [ "$(ctl_read "$b")" = "$rb_want" ]; then
                say "    恢复 $b → ${ORIG[$b]}"
            else
                say "    ERROR $b 回滚写回失败或回读不符（期望 $rb_want）"
            fi
        done
        # 设备这次没被移除，但驱动在第 5 步已解绑 ⇒ 绑回去，否则"卡在、驱动不在"
        rebind_leaves "$anc"
        rescan_and_wait "${cards[@]}" || true
        die "已回滚，退出"
    fi
    sync

    # 9) 一次 rescan
    say "  重新扫描 PCI 总线（风险点）"
    rescan_and_wait "$anc" "${cards[@]}" || say "ERROR rescan 后设备未全部回来"
    sleep 1
    PCI_TREE_REMOVED=0               # 扫描已发出，内核侧不再是"已移除"状态

    # 10) 实证检查
    report_bar_drift "$BAR_BEFORE" "$(snapshot_bars)"

    # 11) 逐张验证
    fail=0
    for b in "${cards[@]}"; do
        mb="$(topo_bar2_mb "$b")"
        if [ "$mb" -eq "$WANT_MB" ]; then
            say "  OK   $b  BAR2 = ${mb}MB"
        else
            say "  FAIL $b  BAR2 = ${mb}MB，期望 ${WANT_MB}MB"
            fail=1
        fi
    done

    # 12) 失败 → 全部恢复原值
    if [ "$fail" -ne 0 ]; then
        say "  本次分配未全部达标，回滚本组所有卡的 Control"
        rb_bad=0
        for b in "${cards[@]}"; do
            if [ ! -e "/sys/bus/pci/devices/$b" ]; then
                say "    ERROR $b 不在总线上，无法写回"
                rb_bad=1
                continue
            fi
            if ! off="$(rebar_off "$b" 2>/dev/null)"; then
                say "    ERROR $b 定位不到 ReBAR ECAP，无法写回"
                rb_bad=1
                continue
            fi
            rb_want="$(printf '%08x' "$(hx "${ORIG[$b]}")")"
            if setpci -s "$b" "$(printf '%x' $((off + 8))).l=$rb_want" 2>/dev/null; then
                rb_got="$(ctl_read "$b")"
                if [ "$rb_got" = "$rb_want" ]; then
                    say "    恢复 $b → ${ORIG[$b]}"
                else
                    say "    ERROR $b 回读不符：期望 $rb_want 实际 ${rb_got:-空}"
                    rb_bad=1
                fi
            else
                say "    ERROR $b 写回 Control 失败（setpci 返回非 0）"
                rb_bad=1
            fi
        done
        # remove 之前必须重新 unbind：第 9 步 rescan 之后驱动早已自动重绑，
        # 直接 remove 正是本脚本第 5 步明令禁止的"带绑定驱动 remove"（内核 UAF）。
        if [ -e "/sys/bus/pci/devices/$anc" ]; then
            unbind_leaves "$anc" || say "    WARN 回滚前解绑未全部成功，仍继续 remove"
            ANCHOR_GONE="$anc"
            CARDS_EXPECT="$anc ${cards[*]}"
            PCI_TREE_REMOVED=1
            echo 1 > "/sys/bus/pci/devices/$anc/remove" 2>/dev/null \
                || { PCI_TREE_REMOVED=0; say "    ERROR 移除锚点失败"; rb_bad=1; }
        fi
        rescan_and_wait "$anc" "${cards[@]}" || true
        PCI_TREE_REMOVED=0
        for b in "${cards[@]}"; do
            say "    回滚后 $b BAR2 = $(topo_bar2_mb "$b")MB"
        done
        [ "$rb_bad" -ne 0 ] && say "  WARN 回滚未完全恢复（见上），建议尽快重启 —— BIOS 会把 BAR2 复位"
        overall=1
    fi

    unset ORIG
done

say "===== 结束 ====="
if [ "$overall" -ne 0 ]; then
    say "有分组未能全部达标，见上方明细"
    exit 1
fi
say "全部目标卡 BAR2 = ${WANT_MB}MB"
exit 0
