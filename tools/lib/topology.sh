#!/bin/bash
# =============================================================================
# lib/topology.sh — 拓扑探测层（只读、无副作用、不写任何文件）
#
# 设计原则：**不假设槽位、不假设 BDF、不假设"根端口"这一层级存在**
# -----------------------------------------------------------------------------
# 早期版本把 "0000:04:00.0"、"ECAP 在 0x420"、"两个 x16 槽共享 00:02.0"
# 写死在脚本里 —— 换一台机器、换一个槽、换一个 BIOS 版本就全部失效，
# 而且失效方式是静默的（Condition 不满足直接 skip，连日志都没有）。
#
# 本层把"机器长什么样"变成运行时探测的结果，上层只消费结论：
#
#   1. 目标设备      按 vendor:device 枚举，ID 可由 TOPO_DEV_IDS 覆盖
#   2. ReBAR ECAP    遍历扩展能力链表找 Capability ID 0x0015，偏移不写死
#   3. 桥梁链        从设备沿 sysfs 父链往上走，逐级记录（卡内桥 / 上游桥 / 根端口）
#   4. 安全锚点      最高的那一级"子树里只有目标卡及其桥、音频"的祖先
#                    —— 它碰巧通常是根端口，但代码不假设这一点
#   5. 分组与计划    按锚点分组，算出每组需求窗口与应采用的策略
#
# 为什么用"安全锚点"而不是"根端口"：
#   remove 一个桥会摘掉它整个子树。要扩桥窗口必须摘掉窗口所在的那一级；
#   能摘到多高，取决于"再高一级的子树里有没有别人的设备"。
#   显卡自带内部桥（如 Intel Arc 的 8086:e2ff）时，锚点通常落在根端口；
#   若根端口下还挂着 NVMe / 网卡，锚点自动降级到卡内桥，绝不越界。
#
# 依赖：bash 4+、pciutils（lspci / setpci）、coreutils
# 用法：source lib/topology.sh 后调用 topo_* 函数
# =============================================================================

TOPO_DEV_IDS="${TOPO_DEV_IDS:-8086:e20b}"   # 空格分隔，支持多种型号
TOPO_MB=$((1024 * 1024))

# ---------------------------------------------------------------- 基础查询 ----

# 设备 vendor:device（小写，形如 8086:e20b）
topo_vendor_dev() {
    local v d
    v="$(cat "/sys/bus/pci/devices/$1/vendor" 2>/dev/null)"
    d="$(cat "/sys/bus/pci/devices/$1/device" 2>/dev/null)"
    [ -n "$v" ] && [ -n "$d" ] || return 1
    printf '%04x:%04x\n' "$((v))" "$((d))"
}

# 设备 class 前 4 位（0604 = PCIe 桥，0300 = VGA，0403 = 音频）
# 只读 sysfs，不解析 lspci 文本（lspci -n 第二列带尾冒号，曾导致全量误判）
topo_class() {
    local c
    c="$(cat "/sys/bus/pci/devices/$1/class" 2>/dev/null)"
    [ -n "$c" ] || return 1
    c="${c#0x}"
    echo "${c:0:4}"
}

# 该 BDF 是否属于本工具的目标设备
topo_is_target() {
    local id one
    id="$(topo_vendor_dev "$1")" || return 1
    for one in $TOPO_DEV_IDS; do
        [ "$id" = "$one" ] && return 0
    done
    return 1
}

# 枚举全部目标设备的 BDF（按 BDF 排序，保证输出稳定）
topo_enumerate() {
    local d b
    for d in /sys/bus/pci/devices/*/; do
        b="$(basename "$d")"
        topo_is_target "$b" && echo "$b"
    done | sort
}

# 直接父设备（显卡核心的父级通常是卡内桥；桥的父级是上游桥/根端口）
topo_parent() {
    local p
    p="$(dirname "$(realpath "/sys/bus/pci/devices/$1" 2>/dev/null)")" || return 1
    p="$(basename "$p")"
    # 父级是 pci0000:XX 这种总线容器时无设备名，视为到顶
    case "$p" in pci[0-9a-f]*) return 1 ;; esac
    [ -e "/sys/bus/pci/devices/$p" ] || return 1
    echo "$p"
}

# 从近到远的祖先链（不含自身）
topo_ancestors() {
    local cur="$1" p n=0
    while [ "$n" -lt 16 ]; do
        p="$(topo_parent "$cur")" || return 0
        echo "$p"
        cur="$p"
        n=$((n + 1))
    done
}

# 某设备子树下的全部 BDF（含自身）
topo_subtree() {
    local d real
    real="$(realpath "/sys/bus/pci/devices/$1" 2>/dev/null)" || return 1
    for d in /sys/bus/pci/devices/*/; do
        case "$(realpath "$d" 2>/dev/null)" in "$real"/*) basename "$d" ;; esac
    done
    basename "$1"
}

# 根端口 = 直接挂在 pci 总线下、且自身是桥的那一级祖先
topo_root_port() {
    local b
    for b in $(topo_ancestors "$1"); do
        realpath "/sys/bus/pci/devices/$b" 2>/dev/null \
            | grep -qE "/pci[0-9a-f]{4}:[0-9a-f]{2}/$b$" && { echo "$b"; return 0; }
    done
    return 1
}

# drm 节点（cardN / renderDN），按 device 软链反查；可能是多个，空格分隔
topo_drm() {
    local c out=""
    for c in /sys/class/drm/card[0-9]* /sys/class/drm/renderD[0-9]*; do
        [ -e "$c/device" ] || continue
        [ "$(basename "$(realpath "$c/device" 2>/dev/null)")" = "$1" ] || continue
        out="$out $(basename "$c")"
    done
    echo "${out:- }"
}

# ------------------------------------------------------------ 配置寄存器层 ----

# 遍历扩展能力链表，返回 Resizable BAR (Capability ID 0x0015) 的偏移（十进制）
# 不依赖 lspci 输出格式、不写死偏移；需要 root
declare -A TOPO_ECAP_CACHE=()
topo_ecap() {
    local bdf="$1"
    [ -n "${TOPO_ECAP_CACHE[$bdf]:-}" ] && { echo "${TOPO_ECAP_CACHE[$bdf]}"; return 0; }
    local off=256 hops=0 hdr capid next
    while [ "$hops" -lt 48 ]; do
        hdr="$(setpci -s "$bdf" "$(printf '%x' "$off").l" 2>/dev/null)"
        [ -n "$hdr" ] || return 1
        capid=$(( 0x$hdr & 0xffff ))
        next=$(( (0x$hdr >> 20) & 0xfff ))
        if [ "$capid" -eq 21 ]; then
            TOPO_ECAP_CACHE[$bdf]="$off"
            echo "$off"
            return 0
        fi
        [ "$next" -eq 0 ] && return 1
        off="$next"
        hops=$((hops + 1))
    done
    return 1
}

# 某个桥的 prefetchable 窗口大小（MB）
# 优先用 lspci 的 size= 字段（非 root 也能读桥窗口），拿不到再读配置空间
topo_window_mb() {
    local bdf="$1" out num unit lo hi up
    out="$(lspci -vv -s "$bdf" 2>/dev/null | grep -m1 'Prefetchable memory behind bridge')"
    if [ -n "$out" ]; then
        num="$(printf '%s' "$out" | sed -nE 's/.*\[size=([0-9]+)([KMGT])\].*/\1/p')"
        unit="$(printf '%s' "$out" | sed -nE 's/.*\[size=([0-9]+)([KMGT])\].*/\2/p')"
        if [ -n "$num" ]; then
            case "$unit" in
                K) echo $(( num / 1024 )) ;;
                M) echo "$num" ;;
                G) echo $(( num * 1024 )) ;;
                T) echo $(( num * 1024 * 1024 )) ;;
            esac
            return 0
        fi
    fi
    # fallback：0x24/0x28 是 prefetchable base/limit 低 16 位，0x2c 是高 32 位
    lo="$(setpci -s "$bdf" 24.w 2>/dev/null)"
    hi="$(setpci -s "$bdf" 28.w 2>/dev/null)"
    up="$(setpci -s "$bdf" 2c.l 2>/dev/null)"
    [ -n "$lo" ] && [ -n "$hi" ] || { echo 0; return 1; }
    local base lim
    base=$(( (0x$up & 0xffffffff) << 32 | ((0x$lo & 0xfff0) << 16) ))
    lim=$((  (0x$up & 0xffffffff) << 32 | ((0x$hi & 0xfff0) << 16) | 0xfffff ))
    (( lim > base )) && echo $(( (lim - base + 1) / TOPO_MB )) || echo 0
}

# BAR2 实际大小（MB）；读 resource 第 3 行，未分配返回 0
topo_bar2_mb() {
    local res="/sys/bus/pci/devices/$1/resource" line s e
    [ -r "$res" ] || { echo 0; return; }
    line="$(sed -n '3p' "$res" 2>/dev/null)"
    s="$(echo "$line" | awk '{print $1}')"
    e="$(echo "$line" | awk '{print $2}')"
    case "$s" in ""|0x0000000000000000) echo 0; return ;; esac
    s=$((s)); e=$((e))
    (( e > s )) && echo $(( (e - s + 1) / TOPO_MB )) || echo 0
}

# -------------------------------------------------------------- 安全锚点 ------

# 子树是否"只剩自己人"：除锚点本身外，只允许
#   桥(0604) / 本工具的目标设备 / 音频(0403)
# 任何其它 class 都算"别人的设备"，说明这一级不能再往上摘。
topo_subtree_safe() {
    local anc="$1" b cls
    for b in $(topo_subtree "$anc"); do
        [ "$b" = "$anc" ] && continue
        cls="$(topo_class "$b")" || return 1
        case "$cls" in
            0604) : ;;
            0300|0302|0380) topo_is_target "$b" || return 1 ;;
            0403) : ;;
            *) return 1 ;;
        esac
    done
    return 0
}

# 安全锚点：从设备往上，取最高的那个"子树安全"的祖先
# 返回值含义：
#   锚点 == 根端口   正常情况，remove 它即可让内核重算该端口窗口
#   锚点 <  根端口   根端口下还有别人的设备 → 只能摘到卡内桥，
#                    窗口能否变大取决于内核 pci=realloc 行为，需调用方提示
topo_anchor() {
    local b best=""
    for b in $(topo_ancestors "$1"); do
        if topo_subtree_safe "$b"; then best="$b"; else break; fi
    done
    [ -n "$best" ] || return 1
    echo "$best"
}

# ------------------------------------------------------------------ 分组 ------

# 按安全锚点把目标设备分组，输出 "锚点 BDF1 BDF2 ..." 每行一组（按锚点排序）
topo_groups() {
    local b anc
    declare -A g=()
    for b in $(topo_enumerate); do
        anc="$(topo_anchor "$b")" || continue
        g["$anc"]="${g[$anc]:-} $b"
    done
    local a
    for a in $(printf '%s\n' "${!g[@]}" | sort); do
        echo "$a${g[$a]}"
    done
}

# 求不出安全锚点的目标设备（逐个一行）
# 这些卡会被 topo_groups 的 `|| continue` 跳过 —— 调用方必须显式校验，
# 否则会出现"一张卡被静默丢弃、另一张成功、结尾报全部达标"的假成功。
topo_ungrouped() {
    local b
    for b in $(topo_enumerate); do
        topo_anchor "$b" >/dev/null 2>&1 || echo "$b"
    done
}

# ------------------------------------------------------------------ 计划 ------

# topo_plan <目标N>  → 每行：锚点|卡数|当前窗口MB|需求MB|策略|备注
# 策略取值范围：
#   atomic   组内只有 1 张卡 → 可以逐张 apply，只动这一个锚点
#   batch    组内多张卡     → 必须先把所有 Control 写好，再一次性 remove+rescan
topo_plan() {
    local n="${1:-14}" want_mb need win cards cnt rp note strategy
    want_mb=$(( (1 << (n + 20)) / TOPO_MB ))
    while read -r line; do
        [ -n "$line" ] || continue
        set -- $line
        rp="$1"                 # 锚点
        shift                   # 剩下的是该组的目标卡
        cnt=$#
        [ "$cnt" -eq 0 ] && continue
        cards="$*"
        win="$(topo_window_mb "$rp" 2>/dev/null)"; win="${win:-0}"
        need=$(( cnt * want_mb ))
        if [ "$cnt" -eq 1 ]; then strategy="atomic"; else strategy="batch"; fi
        note=""
        real_rp="$(topo_root_port "$1" 2>/dev/null || true)"
        if [ -n "$real_rp" ] && [ "$rp" != "$real_rp" ]; then
            note="锚点低于根端口 $real_rp（该端口下还有别的设备），窗口增长依赖 pci=realloc"
        fi
        echo "$rp|$cnt|$win|$need|$strategy|$note"
    done < <(topo_groups)
}

# 汇总策略：任一组的 anchor 下有多卡就整体走 batch
topo_strategy() {
    local n="${1:-14}" s multi=0
    while IFS='|' read -r _ _ _ _ s _; do
        [ "$s" = "batch" ] && multi=1
    done < <(topo_plan "$n")
    if [ "$multi" -eq 1 ]; then echo batch; else echo atomic; fi
}
