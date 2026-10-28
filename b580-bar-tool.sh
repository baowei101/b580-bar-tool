#!/bin/bash
# ==============================================================================
# b580-bar-tool.sh — 扩展 Intel Arc 显卡的 PCIe Resizable BAR 窗口
#
# 用途  : 把 GPU 的 BAR2 扩到本卡支持的最大尺寸（B580 = 16GB），使驱动可完整
#         映射 12GB 显存。适用于 BIOS 没有 Resizable BAR 选项的老主板。
#
# 声明  : 本脚本为独立实现。仅依据 PCI-SIG 公开的 PCI Express Resizable BAR
#         扩展能力规范（ECAP ID 0x0015）与本机实测寄存器值编写，未参考、
#         未复制任何第三方同类项目的代码、脚本或文档。
#
# 用法  :
#   ./b580-bar-tool.sh status                只读体检（寄存器与窗口现状）
#   ./b580-bar-tool.sh gpu                   列出全部显示设备身份（双卡必跑）
#   ./b580-bar-tool.sh check                 只读前置检查（apply 的前置条件逐条验）
#   ./b580-bar-tool.sh plan                  默认；dry-run，只打印计划
#   ./b580-bar-tool.sh rehearse              只做 remove+rescan 演练，不改 BAR（可安全试）
#   ./b580-bar-tool.sh apply                 真正执行（会二次确认）
#   ./b580-bar-tool.sh apply --yes           跳过确认，无人值守
#   ./b580-bar-tool.sh rollback              恢复到 apply 前记录的尺寸
#
# 选项  :
#   --gpu <BDF>        显式指定目标显卡（双显卡环境必须给，否则脚本拒绝执行）
#   --size <N>         BAR 尺寸的 2 的幂次 N（字节数 = 2^(N+20)），默认取本卡上限；
#                      换更大的卡通常不用填 —— 上限读自卡本身的能力位图
#   --allow-any-gpu    跳过 vendor:device 身份校验（目标不是 B580 时才用）
#   --yes              跳过二次确认
#
# 风险  : 过程中会移除并重扫 PCIe 根端口。少数芯片组不容忍根端口重新枚举，
#         可能导致内核挂死，此情况只能断电重启。本脚本不写任何持久配置
#         （不碰 BIOS / 固件 / GRUB / initramfs），重启后一切回到原状。
#
# 版本  : 1.2.0
# ==============================================================================

set -uo pipefail

readonly VER="1.2.0"
# Resizable BAR 的 ECAP 偏移不再写死：由 ecap_find() 遍历扩展能力链表得到。
# （偏移随卡型号/固件而变，写死必然在别的机器上失效。）
readonly REG_CAP=0x04           # 相对 ECAP 基址
readonly REG_CTL=0x08
readonly REG_STA=0x0C
readonly SIZE_MASK=0x3F00       # Control bits[13:8]
readonly BARIDX_MASK=0x07       # Control bits[2:0]
readonly SIZE_EXP=20            # 实际字节数 = 2^(N+20)
# 本项目真机验证过的最大档位（B580 = N=14 = 16GB）。换算逻辑对 N 完全通用，但更大的卡
# 没有实测数据，见 README「更大的卡」一节。这里只用于在 plan/apply 时提醒一句，不拦。
readonly TESTED_MAX_N=14
readonly ECAP_ID_REBAR=0x0015
# 目标卡的 PCI vendor:device。B580 = Battlemage G21 = 8086:e20b。
# 双显卡环境下这是唯一能把"B580"与核显/第二张卡分开的判据 ——
# 仅凭 class 0x030000 会把所有显示设备一视同仁，选错就是去改另一张卡的 BAR。
readonly EXPECT_ID_DEFAULT="8086:e20b"

GPU_BDF=""
ROOT_BDF=""
ECAP_OFF=""
TARGET_N=""
ASSUME_YES=0
EXPECT_ID="$EXPECT_ID_DEFAULT"
ALLOW_ANY_GPU=0
LOG_FILE="/var/log/b580-bar-tool.log"
STEP_FILE="/var/log/b580-bar-tool.steps"
STATE_FILE="/var/lib/b580-bar-tool.state"
CMD="plan"

# ----------------------------------------------------------------- 基础设施 --

log() {
    local lvl="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] %-5s %s\n' "$ts" "$lvl" "$msg"
    if [ -n "$LOG_FILE" ]; then
        printf '[%s] %-5s %s\n' "$ts" "$lvl" "$msg" >> "$LOG_FILE" 2>/dev/null || true
    fi
    logger -t b580-bar-tool -- "$lvl: $msg" 2>/dev/null || true
}

# 危险步骤前的落盘痕迹：单独文件 + 立即 sync，挂死后据此定位死在哪一步
step() {
    printf '[%s] STEP %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$STEP_FILE" 2>/dev/null || true
    sync 2>/dev/null || true
}

die() { log ERROR "$*"; exit 1; }

need_root() {
    # 为什么消息里要点明 setpci：普通用户读 PCI 扩展配置空间（offset >= 256）会拿到空串，
    # 而空串在 ecap_find 里与「能力链里没有 ReBAR」完全同形，最终报出的是
    # 「该卡没有 Resizable BAR 扩展能力」—— 把权限问题伪装成硬件能力问题，
    # 使用者会去查显卡规格，方向完全错。所以提权提示必须带上这层因果。
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限：sudo $0 $CMD（普通用户下 setpci 读不到扩展配置空间，会被误判成「该卡没有 Resizable BAR 扩展能力」）"
}

hex2dec() {
    local v="${1//[[:space:]]/}"
    v="${v#0x}"; v="${v#0X}"
    [ -n "$v" ] || { echo 0; return; }
    printf '%d' "$((16#$v))"
}
dec2hex8() { printf '%08x' "$1"; }

# 寄存器读值校验：非空且形如 1~8 位十六进制，否则立即中止。
# 依据：setpci 读取失败时返回空串，若被 hex2dec 当成 0，会让
# "目标 N(0) >= 当前 N(0)" 成立，从而报告"已是目标尺寸，幂等退出"——
# 什么都不做却以成功退出，是最危险的假阳性。
assert_reg() {
    local name="$1" v="$2"
    if [ -z "$v" ] || ! printf '%s' "$v" | grep -qE '^[0-9a-fA-F]{1,8}$'; then
        die "读取 $name 失败（得到 \"$v\"）。设备可能已不可访问，拒绝继续。"
    fi
}

# 可读大小
n_to_human() {
    local n="$1"
    local mb=$(( 1 << (n + SIZE_EXP - 20) ))
    if [ "$mb" -ge 1024 ]; then echo "$(( mb / 1024 ))GB"; else echo "${mb}MB"; fi
}

bar2_mb_of_n() { echo $(( 1 << ($1 + SIZE_EXP - 20) )); }

# ----------------------------------------------------------------- 参数解析 --

parse_args() {
    [ $# -gt 0 ] || return 0
    case "$1" in
        status|gpu|check|plan|rehearse|apply|rollback) CMD="$1"; shift ;;
        # 头部注释范围按结构取（第二个 ==== 分隔线为止），不写死行号：
        # 以前是 sed -n '2,33p'，头部每加一行注释，--help 就悄悄少一行。
        -h|--help) awk 'NR==1{next} /^# =+$/{if(++s==2) exit; next} {sub(/^# ?/,""); print}' "$0"; exit 0 ;;
        *) die "未知子命令：$1（--help 查看用法）" ;;
    esac
    while [ $# -gt 0 ]; do
        case "$1" in
            --gpu)  [ $# -ge 2 ] || die "--gpu 缺少参数（BDF 形如 0000:BB:DD.F）"
                    GPU_BDF="$2"; shift 2 ;;
            --size) [ $# -ge 2 ] || die "--size 缺少参数（N 为整数）"
                    case "$2" in
                        ''|*[!0-9]*) die "--size 只收整数幂次 N（字节数 = 2^(N+20)：13 = 8GB，14 = 16GB，15 = 32GB），不认 16GB 这类写法" ;;
                    esac
                    TARGET_N="$2"; shift 2 ;;
            --log)  [ $# -ge 2 ] || die "--log 缺少参数（文件路径）"
                    LOG_FILE="$2"; shift 2 ;;
            --allow-any-gpu) ALLOW_ANY_GPU=1; shift ;;
            --yes)  ASSUME_YES=1; shift ;;
            *) die "未知参数：$1" ;;
        esac
    done
}

# ------------------------------------------------------------ 设备与拓扑探测 --

# 自动定位 Resizable BAR 扩展能力（ECAP ID 0x0015）。
#
# 做法：从扩展能力链表头 0x100 开始，逐项读头部 dword ——
#   低 16 位 = Capability ID，bits[19:16] = 版本，bits[31:20] = 下一项的偏移。
# 找到 ID == 0x0015 即返回其偏移；走到 next==0 说明链表到头，返回失败。
#
# 历史上这里写死过 0x420（本机实测位置），换卡/换固件就失效；后来改成
# "先猜 0x420，不中再逐 4 字节扫 0x100~0xFFC"，但那种扫法会把**任何**
# 低 16 位恰好等于 0x0015 的 dword 误判成 ECAP 基址 —— 一旦命中错误位置，
# 后面写 Control 就是往不相干的寄存器里写数，后果不可预期。故改为链式遍历。
ecap_find() {
    local bdf="$1" off=256 hops=0 raw capid next
    while [ "$hops" -lt 48 ]; do
        raw="$(setpci -s "$bdf" "$(printf '%x' "$off").l" 2>/dev/null)"
        [ -n "$raw" ] || return 1
        capid=$(( $(hex2dec "$raw") & 0xFFFF ))
        next=$(( ( $(hex2dec "$raw") >> 20 ) & 0xFFF ))
        # 必须用算术上下文比较：bash 的 [ -eq ] 不认 0x 前缀，
        # 写成 [ "$capid" -eq "$ECAP_ID_REBAR" ] 会报
        # "integer expression expected" 并恒为假 —— 探测永远失败。
        if (( capid == ECAP_ID_REBAR )); then echo "$off"; return 0; fi
        [ "$next" -eq 0 ] && return 1
        off="$next"
        hops=$((hops + 1))
    done
    return 1
}

# 校验目标卡的 vendor:device 是否为本卡预期型号。
# 显式 --gpu 也必须过这一关：指定错 BDF 和自动选错卡的后果完全一样。
verify_gpu_ident() {
    local id; id="$(gpu_ident "$GPU_BDF")"
    if [ "$id" != "$EXPECT_ID" ]; then
        if [ "$ALLOW_ANY_GPU" -eq 1 ]; then
            log WARN "目标卡 $GPU_BDF 的 vendor:device=$id，与预期 $EXPECT_ID 不符（已用 --allow-any-gpu 放行）"
        else
            die "目标卡 $GPU_BDF 的 vendor:device=$id，与预期 B580($EXPECT_ID) 不符。确认要操作它请加 --allow-any-gpu"
        fi
    else
        log INFO "目标卡身份校验通过：$GPU_BDF = $id (Arc B580)"
    fi
}

detect_gpu() {
    local dev class bdf found=()

    if [ -n "$GPU_BDF" ]; then
        class="$(dev_class "$GPU_BDF")"
        case "$class" in
            0x03*) ;;
            *) die "指定的 $GPU_BDF 不是显示设备（class=${class:-读取失败}）" ;;
        esac
        log INFO "使用显式指定的显卡：$GPU_BDF ($(gpu_ident "$GPU_BDF"))"
        verify_gpu_ident
        return 0
    fi

    for dev in /sys/bus/pci/devices/*/; do
        class="$(cat "$dev/class" 2>/dev/null)"
        [ "${class:0:4}" = "0x03" ] || continue
        bdf="$(basename "$dev")"
        ecap_find "$bdf" >/dev/null 2>&1 && found+=("$bdf")
    done

    case "${#found[@]}" in
        0) die "未找到带 Resizable BAR 扩展能力的显示设备" ;;
        1) GPU_BDF="${found[0]}" ;;
        *)
            log ERROR "检测到 ${#found[@]} 个带 ReBAR 的显示设备，拒绝自动选择 —— 选错会去改另一张卡的 BAR："
            for bdf in "${found[@]}"; do
                log ERROR "  - $bdf  $(gpu_ident "$bdf")  $(lspci -s "$bdf" 2>/dev/null | cut -d' ' -f2-)"
            done
            die "请用 --gpu <BDF> 明确指定目标显卡"
            ;;
    esac

    verify_gpu_ident
}

# 列出全部显示设备及其身份，用于确认"哪张卡才是 B580"。
# 双显卡环境务必先跑这个，再决定 apply 的 --gpu 参数。
cmd_gpu() {
    local dev class bdf id drv ecap bar2 mark n=0
    echo "=================== 显示设备身份清单 ==================="
    printf "%-14s %-10s %-12s %-10s %-8s %-9s %s\n" BDF CLASS VENDOR:DEV DRIVER REBAR BAR2 说明
    for dev in /sys/bus/pci/devices/*/; do
        class="$(cat "$dev/class" 2>/dev/null)"
        [ "${class:0:4}" = "0x03" ] || continue
        bdf="$(basename "$dev")"; n=$((n+1))
        id="$(gpu_ident "$bdf")"
        drv="$(driver_of "$bdf")"
        ecap="$(ecap_find "$bdf" 2>/dev/null)" || ecap=""
        if [ -n "$ecap" ]; then ecap="$(printf '0x%x' "$ecap")"; else ecap="无"; fi
        bar2="$(bar2_mb "$bdf")MB"
        if [ "$id" = "$EXPECT_ID" ]; then mark="← B580（预期目标）"; else mark="非预期型号"; fi
        printf "%-14s %-10s %-12s %-10s %-8s %-9s %s\n" \
            "$bdf" "$class" "$id" "${drv:-none}" "$ecap" "$bar2" "$mark"
    done
    echo "========================================================"
    if [ "$n" -eq 0 ]; then
        log ERROR "系统内没有任何显示类设备（class 0x03xxxx）"
        return 1
    fi
    if [ "$n" -gt 1 ]; then
        log WARN "存在 $n 个显示设备：apply / rehearse 必须用 --gpu <BDF> 显式指定，否则脚本会拒绝执行"
    else
        log INFO "仅 1 个显示设备，无歧义"
    fi
    log INFO "预期身份 EXPECT_ID=$EXPECT_ID（B580 = Battlemage G21）"
}

detect_root_port() {
    local path; path="$(realpath "/sys/bus/pci/devices/$GPU_BDF")"
    echo "$path" | sed -nE \
        's#.*/pci[0-9a-f]{4}:[0-9a-f]{2}/([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f])/.*#\1#p'
}

subtree_devices() {
    local root="$1" rootpath dev
    # 空 BDF 会让 realpath 退化成 /sys/bus/pci/devices 本身，前缀匹配随之命中
    # 整机每一个 PCI 设备 —— 调用方（unbind_leaf_drivers）会去解绑网卡/存储驱动。
    if [ -z "$root" ]; then
        log ERROR "subtree_devices 收到空 BDF，拒绝枚举（否则会匹配整机所有 PCI 设备）"
        return 1
    fi
    rootpath="$(realpath "/sys/bus/pci/devices/$root")"
    for dev in /sys/bus/pci/devices/*/; do
        realpath "$dev" 2>/dev/null | grep -q "^${rootpath}/" && basename "$dev"
    done
}

# 根端口子树里"不属于这张卡"的设备 —— 移除根端口会连带摘掉它们。
# 放行两类：PCIe 桥（随根端口级联消失，本来就要一起走）、0x0403 音频。
# 音频整类放行是因为 B580 的 HDMI 音频挂在卡内桥下（实测 GPU 04:00.0、
# 音频 05:00.0，连 slot 都不同），按 slot 判会把自家音频误判成外来设备。
# 代价是同一根端口下的**独立**声卡也会被误放行 —— 记为已知 P2，比误拦自家音频好。
# preflight（拦截）与 rollback_to（只告警）共用这一个判据，避免两处规则漂移。
subtree_foreign_devices() {
    local d cls
    while read -r d; do
        [ -n "$d" ] || continue
        cls="$(dev_class "$d")"
        case "$cls" in
            0x0604*|0x0403*) continue ;;
        esac
        [ "$d" = "$GPU_BDF" ] && continue
        printf '%s\n' "$d"
    done <<< "$(subtree_devices "$ROOT_BDF")"
}

# 设备 class 一律取自 sysfs，格式 0x060400（class<<16 | subclass<<8 | progif）。
# 不要用 lspci -n 的 $3：那一列是 vendor:device（如 8086:e20b），class 在 $2 且带尾冒号。
# 用错字段的后果不是"少判一个设备"，而是①桥被当成异物导致 apply 直接拒绝②
# pcieport 被误判为非桥而被 unbind（正是本脚本要避免的危险动作）。
dev_class() {
    local c
    c="$(cat "/sys/bus/pci/devices/$1/class" 2>/dev/null)"
    if [ -z "$c" ]; then
        c="$(lspci -n -s "$1" 2>/dev/null | awk '{print $2}' | tr -d ':')"
        [ -n "$c" ] || { echo ""; return; }
        c="0x${c}00"
    fi
    echo "$c"
}

# ------------------------------------------------------------ 寄存器读写 ----
# 注意：setpci 的宽度说明符只有 .b / .w / .l，没有 .d；一律用 .l 读 32 位

cap_read()  { setpci -s "$GPU_BDF" "$(printf '%x' $((ECAP_OFF + REG_CAP))).l" 2>/dev/null; }
ctl_read()  { setpci -s "$GPU_BDF" "$(printf '%x' $((ECAP_OFF + REG_CTL))).l" 2>/dev/null; }
sta_read()  { setpci -s "$GPU_BDF" "$(printf '%x' $((ECAP_OFF + REG_STA))).l" 2>/dev/null; }
ctl_write() {
    local val="$1"
    setpci -s "$GPU_BDF" "$(printf '%x' $((ECAP_OFF + REG_CTL))).l=$(dec2hex8 "$val")"
}

ctl_size_n()  { local v; v="$(hex2dec "$1")"; echo $(( (v & SIZE_MASK) >> 8 )); }
ctl_baridx()  { local v; v="$(hex2dec "$1")"; echo $(( v & BARIDX_MASK )); }

# Capability: bit(4+N) 置位表示支持 2^(N+20)
max_supported_n() {
    local v; v="$(hex2dec "$1")"
    local bit n max=0
    for bit in $(seq 4 28); do
        if (( (v >> bit) & 1 )); then n=$((bit - 4)); [ "$n" -gt "$max" ] && max="$n"; fi
    done
    echo "$max"
}

# BAR2 实际大小（MB）。resource 文件第 3 行即 BAR2；resource2 在部分内核上读会返回 EIO
bar2_mb() {
    local bdf="${1:-$GPU_BDF}"
    local res="/sys/bus/pci/devices/$bdf/resource"
    [ -r "$res" ] || { echo 0; return; }
    local line start end s e
    line="$(sed -n '3p' "$res" 2>/dev/null)"
    start="$(echo "$line" | awk '{print $1}')"
    end="$(echo "$line" | awk '{print $2}')"
    case "$start" in ""|0x0000000000000000) echo 0; return ;; esac
    s=$((start)); e=$((end))
    (( e > s )) && echo $(( (e - s + 1) / 1048576 )) || echo 0
}

root_window_mb() {
    local out size
    out="$(lspci -vv -s "$1" 2>/dev/null | grep -m1 'Prefetchable memory behind bridge')"
    size="$(echo "$out" | sed -nE 's/.*\[size=([0-9]+)([MG])\].*/\1 \2/p')"
    [ -n "$size" ] || { echo 0; return; }
    set -- $size
    case "$2" in G) echo $(( $1 * 1024 )) ;; *) echo "$1" ;; esac
}

driver_of() { basename "$(readlink "/sys/bus/pci/devices/$1/driver" 2>/dev/null)" 2>/dev/null; }

# 取 PCI vendor:device（如 8086:e20b）。注意 lspci -n 的字段分布：
#   $1=BDF  $2=class（带尾冒号）  $3=vendor:device
# 这是区分"B580"与其它显示设备的唯一可靠身份判据。
gpu_ident() { lspci -n -s "$1" 2>/dev/null | awk '{print $3}'; }

# ------------------------------------------------------------ 前置检查 ----

preflight() {
    local rc=0 d cls drv

    if ! grep -qw 'pci=realloc' /proc/cmdline; then
        log ERROR "内核命令行缺少 pci=realloc，重扫时内核不会被允许扩大桥窗口"
        log ERROR "请在 GRUB_CMDLINE_LINUX_DEFAULT 中追加 pci=realloc 后 update-grub 并重启"
        rc=1
    else
        log INFO "内核命令行已含 pci=realloc"
    fi

    [ -n "$ROOT_BDF" ] || { log ERROR "无法从 GPU 路径推断根端口"; return 1; }

    log INFO "根端口 $ROOT_BDF 子树（窗口 $(root_window_mb "$ROOT_BDF")MB）："
    while read -r d; do
        [ -n "$d" ] || continue
        cls="$(dev_class "$d")"; drv="$(driver_of "$d")"
        log INFO "  - $d class=$cls driver=${drv:-none}"
    done <<< "$(subtree_devices "$ROOT_BDF")"

    # 判据来自 subtree_foreign_devices()，rollback_to 用的是同一个函数。
    local foreign
    foreign="$(subtree_foreign_devices)"
    if [ -n "${foreign//[$'\n']/}" ]; then
        while read -r d; do
            [ -n "$d" ] || continue
            log ERROR "  ↑ 根端口下存在非本卡设备：$d class=$(dev_class "$d") driver=$(driver_of "$d")"
        done <<< "$foreign"
        log ERROR "移除根端口会把它们一起摘掉（解绑驱动 → 设备消失 → 重新枚举），拒绝执行"
        log ERROR "共享根端口请改用 tools/rebar-batch.sh —— 它会把锚点降级到卡内桥，不越界"
        rc=1
    fi

    # 窗口容量核对。只告警不阻断：全量 re-enumeration 有机会把根端口窗口扩到
    # 64-bit 空间的 1TB 池里，而 xe 的 in-place resize 做不到——本机已实测
    # 两次 -ENOSPC（开机 6.78s 与 15:24 演练时），所以这个数值必须显式呈现。
    local win_mb tgt_n tgt_mb
    win_mb="$(root_window_mb "$ROOT_BDF")"
    tgt_n="${TARGET_N:-$(max_supported_n "$(cap_read)")}"
    tgt_mb="$(bar2_mb_of_n "$tgt_n")"
    if [ "$win_mb" -lt "$tgt_mb" ]; then
        log WARN "根端口窗口 ${win_mb}MB < 目标 ${tgt_mb}MB：需靠 pci=realloc 扩窗，失败则落回旧值"
    else
        log INFO "根端口窗口 ${win_mb}MB 足以容纳目标 ${tgt_mb}MB"
    fi

    # GPU 是否被进程占用（DMA 在途风险）
    local holders=""
    if command -v fuser >/dev/null 2>&1; then
        holders="$(fuser /dev/dri/renderD* /dev/dri/card* 2>/dev/null | tr -s ' ' ' ')"
    fi
    if [ -n "${holders// /}" ]; then
        log ERROR "有进程正占用 GPU 设备节点：$holders"
        log ERROR "推理/渲染任务在跑时移除根端口风险很高，请先停掉相关服务"
        rc=1
    else
        log INFO "未检测到进程占用 GPU 设备节点"
    fi

    return $rc
}

# ------------------------------------------------------------ 驱动解绑/重绑 --

unbind_one() {
    local bdf="$1" drv
    drv="$(driver_of "$bdf")"
    [ -n "$drv" ] || { log INFO "$bdf 无驱动绑定，跳过"; return 0; }
    log INFO "解绑 $bdf 的驱动：$drv"
    echo "$bdf" > "/sys/bus/pci/drivers/$drv/unbind" 2>/dev/null \
        || { log ERROR "解绑 $bdf 的驱动 $drv 失败（EBUSY/设备忙）"; return 1; }
    return 0
}

# 只解绑终端设备；pcieport 保持绑定，由根端口 remove 时级联移除
unbind_leaf_drivers() {
    local d cls
    while read -r d; do
        [ -n "$d" ] || continue
        cls="$(dev_class "$d")"
        case "$cls" in
            0x0604*) log INFO "$d 是 PCIe 桥，保持绑定（由根端口级联移除）"; continue ;;
        esac
        unbind_one "$d" || return 1
    done <<< "$(subtree_devices "$ROOT_BDF")"
}

rebind_leaf_drivers() {
    local d drv
    while read -r d; do
        [ -n "$d" ] || continue
        case "$(dev_class "$d")" in 0x0604*) continue ;; esac   # 桥不重绑
        [ -n "$(driver_of "$d")" ] && continue                  # 已被 udev 自动绑回
        drv="$(lspci -k -s "$d" 2>/dev/null | sed -nE 's/.*Kernel modules: *([^ ]+).*/\1/p' | head -1)"
        [ -n "$drv" ] || continue
        log INFO "重新绑定 $d → $drv"
        echo "$d" > "/sys/bus/pci/drivers/$drv/bind" 2>/dev/null \
            || log WARN "重绑 $d 失败，udev 或下次启动会自行恢复"
    done <<< "$(subtree_devices "$ROOT_BDF")"
}

# ------------------------------------------------------------ 执行 ----

# ------------------------------------------------------- 异常安全 ----
# remove 根端口会让它和下面所有设备从 sysfs 一起消失，只有 rescan 才回来。
# 若恰好在这两步之间被打断（Ctrl-C、systemd 超时、SSH 断开、SIGKILL），
# 子树就会一直处于"消失"状态：GPU 不见了，但寄存器已经被改过。
# 用一个标志记住"已 remove 未 rescan"，在任何退出路径上补一次扫描。
PCI_TREE_REMOVED=0

pci_tree_restore() {
    [ "${PCI_TREE_REMOVED:-0}" = "1" ] || return 0
    log WARN "检测到中断发生在 remove 与 rescan 之间，正在恢复 PCI 子树"
    local i=0
    while [ "$i" -lt 4 ]; do
        echo 1 > /sys/bus/pci/rescan 2>/dev/null || true
        sleep 1
        [ -e "/sys/bus/pci/devices/${GPU_BDF:-}" ] && break
        i=$((i + 1))
    done
    if [ -e "/sys/bus/pci/devices/${GPU_BDF:-}" ]; then
        PCI_TREE_REMOVED=0
        log OK "PCI 子树已恢复，GPU ${GPU_BDF} 回到 sysfs"
    else
        log ERROR "自动恢复失败，请手动执行：echo 1 | sudo tee /sys/bus/pci/rescan"
        log ERROR "若仍不出现，只能重启。寄存器可能已改为目标尺寸，重启后请先跑 check"
    fi
}

on_interrupt() {
    trap - INT TERM HUP EXIT
    pci_tree_restore
    log ERROR "已被中断（信号），未完成的步骤需要重新执行"
    exit 130
}

trap 'on_interrupt' INT TERM HUP
trap 'pci_tree_restore' EXIT

rescan_wait() {
    echo 1 > /sys/bus/pci/rescan 2>/dev/null
    local tries=0
    while [ ! -e "/sys/bus/pci/devices/$GPU_BDF" ] && [ "$tries" -lt 3 ]; do
        tries=$((tries + 1))
        log WARN "GPU 尚未出现，重试扫描（第 $tries 次）"
        sleep 1
        echo 1 > /sys/bus/pci/rescan 2>/dev/null
    done
    sleep 1
    # 扫描已发出且重试过，内核侧不再处于"设备已移除"的空洞状态
    PCI_TREE_REMOVED=0
}

# 返回 0 成功；1 中断；2 BAR2 分配失败（需回滚）
do_resize() {
    local orig_ctl="$1" target_n="$2"
    local orig_val new_val
    orig_val="$(hex2dec "$orig_ctl")"
    new_val=$(( (orig_val & ~SIZE_MASK) | ((target_n << 8) & SIZE_MASK) ))

    step "BEGIN resize gpu=$GPU_BDF root=$ROOT_BDF from=$(ctl_size_n "$orig_ctl") to=$target_n"
    log INFO "Control 将自 $orig_ctl 改为 $(dec2hex8 "$new_val")"

    step "PHASE unbind"
    if ! unbind_leaf_drivers; then
        log ERROR "终端设备解绑失败，中止。带绑定驱动写 BAR size 再 remove 根端口会触发内核 UAF。"
        return 3
    fi
    sync

    step "PHASE write-ctl"
    log INFO "步骤 1/4：写入 ReBAR Control 寄存器"
    ctl_write "$new_val" || { log ERROR "写 Control 寄存器失败"; return 1; }
    local chk; chk="$(ctl_read)"
    if [ "$(hex2dec "$chk")" != "$new_val" ]; then
        log ERROR "写入校验失败：期望 $(dec2hex8 "$new_val")，实际 $chk"
        return 1
    fi
    log INFO "  写入校验通过：$chk"
    sync

    # 这里是最危险的一步：内核可能在此挂死
    step "PHASE remove-root-port DANGER"
    log INFO "步骤 2/4：移除根端口 $ROOT_BDF（风险点，内核可能挂死）"
    PCI_TREE_REMOVED=1
    if ! echo 1 > "/sys/bus/pci/devices/$ROOT_BDF/remove" 2>/dev/null; then
        PCI_TREE_REMOVED=0
        log ERROR "移除根端口失败"
        return 1
    fi
    step "PHASE remove-root-port DONE"
    sync

    step "PHASE rescan DANGER"
    log INFO "步骤 3/4：触发 PCI 重新扫描"
    rescan_wait
    step "PHASE rescan DONE"
    sync

    step "PHASE verify"
    log INFO "步骤 4/4：验证"
    if [ ! -e "/sys/bus/pci/devices/$GPU_BDF" ]; then
        log ERROR "GPU 未重新出现 —— BAR2 未能分配"
        return 2
    fi
    local now_mb want_mb
    now_mb="$(bar2_mb)"
    want_mb="$(bar2_mb_of_n "$target_n")"
    if [ "$now_mb" -eq 0 ]; then
        log ERROR "GPU 已回来但 BAR2 没有分配地址"
        return 2
    fi
    if [ "$now_mb" -ne "$want_mb" ]; then
        log ERROR "BAR2 实际 ${now_mb}MB，期望 ${want_mb}MB —— 窗口不足，被降级分配"
        return 2
    fi

    log OK "成功：BAR2 = ${now_mb}MB"
    rebind_leaf_drivers
    return 0
}

rollback_to() {
    local orig_ctl="$1"
    local orig_val
    orig_val="$(hex2dec "$orig_ctl")"
    step "PHASE rollback to=$orig_ctl"
    log WARN "回滚：把 Control 恢复为 $orig_ctl（size N=$(ctl_size_n "$orig_ctl")）"

    # rollback 不走 preflight（它是恢复路径，恢复原值优先于安全闸门），但它同样会
    # 解绑子树设备、remove 根端口 —— 至少要把"还有别人的设备在下面"说出来。
    # 可达性极低：rollback 依赖上次成功 apply 留下的状态文件，而 apply 已被 preflight
    # 拦住；只有"先在小窗口下 apply 成功、事后又把卡换到共享根端口"才会走到这里。
    local foreign
    foreign="$(subtree_foreign_devices)"
    if [ -n "${foreign//[$'\n']/}" ]; then
        log WARN "根端口 $ROOT_BDF 下还有非本卡设备（$(printf '%s' "$foreign" | tr '\n' ' ')）"
        log WARN "它们会被一起解绑并摘除；回滚不阻断，请自行确认这些设备可以中断"
    fi

    if [ -e "/sys/bus/pci/devices/$GPU_BDF" ]; then
        unbind_leaf_drivers || log WARN "回滚时解绑失败，仍继续写回寄存器（恢复原值是首要目标）"
        ctl_write "$orig_val" || log ERROR "回滚写寄存器失败"
        sync
    else
        log ERROR "GPU 当前不可见，无法写回寄存器"
    fi

    if [ -e "/sys/bus/pci/devices/$ROOT_BDF" ]; then
        PCI_TREE_REMOVED=1
        echo 1 > "/sys/bus/pci/devices/$ROOT_BDF/remove" 2>/dev/null || true
    fi
    step "PHASE rollback-rescan"
    rescan_wait
    sync

    # 判据必须是"恢复到原始尺寸"，不能只判 >0：
    # 若 GPU 一度不可见、写回被跳过，rescan 后可能仍按 16GB 分配，
    # 此时 bar2_mb>0 成立会报"回滚完成，BAR2=16384MB"的矛盾结果。
    local want_mb now_mb
    want_mb="$(bar2_mb_of_n "$(ctl_size_n "$orig_ctl")")"
    now_mb="$(bar2_mb)"
    if [ -e "/sys/bus/pci/devices/$GPU_BDF" ] && [ "$now_mb" = "$want_mb" ]; then
        log OK "回滚完成，BAR2 = ${now_mb}MB（与原始 size N=$(ctl_size_n "$orig_ctl") 一致）"
        rebind_leaf_drivers
        return 0
    fi
    log ERROR "回滚未达预期：期望 ${want_mb}MB，实际 ${now_mb}MB"
    fallback_notice
    return 1
}

fallback_notice() {
    # 原始尺寸不能写死：同样一块 B580，改过 BIOS 的板子给 512MB，
    # 出厂默认的板子只给 256MB。写死会让提示在 256MB 的机器上报错误值。
    local _orig_n="" _orig_desc=""
    if [ -f "$STATE_FILE" ]; then
        _orig_n="$(sed -nE 's/^CTL=//p' "$STATE_FILE" | head -1)"
        if [ -n "$_orig_n" ]; then _orig_n="$(ctl_size_n "$_orig_n")"; fi
    fi
    case "$_orig_n" in
        ''|*[!0-9]*) _orig_desc="BIOS 重置后的小窗口（出厂 256MB / 改过 BIOS 的 512MB）" ;;
        *)           _orig_desc="原来的 $(n_to_human "$_orig_n") 窗口" ;;
    esac
    echo
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "  自动恢复失败，请到机房对服务器断电重启（长按电源键 5 秒）。"
    echo "  本脚本只改了运行时的 PCI 配置空间与 sysfs，没有写任何持久配置，"
    echo "  重启后 BIOS 会重置设备配置空间，GPU 回到${_orig_desc}，"
    echo "  系统会正常起来。不要把这一步当成故障，它只是预期内的兜底。"
    echo "  重启后请把以下两个文件保留下来以便排查："
    echo "    $LOG_FILE"
    echo "    $STEP_FILE"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
}

# ------------------------------------------------------------ 子命令 ----

gather() {
    detect_gpu
    ROOT_BDF="$(detect_root_port)"
    if ! ECAP_OFF="$(ecap_find "$GPU_BDF")"; then
        # 两种完全不同的原因，报错必须分开：
        #   非 root —— setpci 读 offset >= 256 返回空串
        #   真没有 —— 能力链遍历完也没找到 ECAP ID 0x0015
        # 合成一句「该卡没有 Resizable BAR 扩展能力」会让人去怀疑显卡，
        # 而实际只是没加 sudo（2026-10-28 在目标机上真的因此走了一趟弯路）。
        [ "$(id -u)" -eq 0 ] || die "读不到 $GPU_BDF 的扩展配置空间：非 root 时 setpci 无法访问 offset >= 256，请用 sudo 运行"
        die "该卡没有 Resizable BAR 扩展能力"
    fi
}

cmd_status() {
    gather
    local cap ctl sta cur_n max_n
    cap="$(cap_read)"; ctl="$(ctl_read)"; sta="$(sta_read)"
    assert_reg Capability "$cap"
    assert_reg Control "$ctl"
    cur_n="$(ctl_size_n "$ctl")"
    max_n="$(max_supported_n "$cap")"

    log INFO "GPU            : $GPU_BDF"
    log INFO "根端口         : ${ROOT_BDF:-未识别}"
    log INFO "ReBAR ECAP     : 0x$(printf '%x' "$ECAP_OFF")"
    log INFO "Capability     : $cap"
    log INFO "Control        : $ctl"
    log INFO "Status         : $sta"
    log INFO "BAR 索引       : $(ctl_baridx "$ctl")"
    log INFO "当前 size 字段 : $cur_n (= $(n_to_human "$cur_n"))"
    log INFO "卡支持上限     : $max_n (= $(n_to_human "$max_n"))"
    log INFO "BAR2 实际大小  : $(bar2_mb)MB"
    log INFO "根端口窗口     : $(root_window_mb "$ROOT_BDF")MB (prefetchable)"
    log INFO "驱动           : $(driver_of "$GPU_BDF" || echo none)"
    echo
    if [ "$cur_n" -ge "$max_n" ]; then
        log OK "判定：BAR2 已是本卡最大尺寸，无需处理"
    else
        log INFO "判定：可扩展 $cur_n → $max_n，运行 apply 执行"
    fi
}

# 只读前置检查：把 apply 会验的每一项单独跑一遍，绝不改动任何状态。
# 存在的意义是让"能不能安全 apply"这件事可以在不碰根端口的前提下被验证。
cmd_check() {
    need_root
    gather
    echo "================= 前置检查（只读）================"
    local rc=0
    preflight || rc=1
    echo
    # 额外提示：这些不是硬性失败，但会让风险放大
    if ! command -v fuser >/dev/null 2>&1; then
        log WARN "本机没有 fuser，无法检测 GPU 节点占用（需人工确认推理服务已停）"
    fi
    local wd=""
    [ -e /dev/watchdog ] && wd="$(ls /dev/watchdog 2>/dev/null | tr '\n' ' ')"
    if [ -n "$wd" ]; then
        log INFO "硬件看门狗可用：$wd —— 内核挂死会被自动复位"
    else
        log WARN "无 /dev/watchdog：一旦内核挂死，只能到机房断电重启"
        log WARN "X99/C610 平台可尝试 modprobe iTCO_wdt 后再执行 apply"
    fi
    echo "=================================================="
    if [ "$rc" -eq 0 ]; then
        log OK "前置条件全部满足，可以执行 apply"
    else
        log ERROR "前置条件不满足，apply 会被拒绝执行"
    fi
    return "$rc"
}

cmd_plan_or_apply() {
    local mode="$1"
    # 必须在 gather 之前。gather → ecap_find 要读扩展配置空间，非 root 读到空串后会
    # 误判成「该卡没有 Resizable BAR 扩展能力」；原先这项检查只写在本函数的 apply
    # 分支里（gather 之后），于是 plan 和 apply 都先死在 gather，报的是假原因。
    need_root
    gather

    local cap ctl cur_n max_n target_n new_val
    cap="$(cap_read)"; ctl="$(ctl_read)"
    assert_reg Capability "$cap"
    assert_reg Control "$ctl"
    cur_n="$(ctl_size_n "$ctl")"
    max_n="$(max_supported_n "$cap")"
    target_n="${TARGET_N:-$max_n}"

    # 尺寸字段是 2 的幂次，换更大的卡只需换个 N —— 但没有真机数据，先说清楚。
    # 放在这里而不是 check 里：只在真要动手（plan/apply）时打扰，日常体检不刷屏。
    if [ "$max_n" -gt "$TESTED_MAX_N" ]; then
        log WARN "本卡声明上限 N=$max_n（$(n_to_human "$max_n")），高于实测过的 N=$TESTED_MAX_N（$(n_to_human "$TESTED_MAX_N")）"
        log WARN "换算按 2 的幂通用，但更大档位没有真机验证。建议先跑 rehearse，失败会自动回滚"
    fi

    [ "$target_n" -le "$max_n" ] || die "目标 N=$target_n 超过本卡上限 $max_n"
    [ "$target_n" -ge "$cur_n" ] || die "目标 N=$target_n 小于当前 $cur_n，缩容请用 rollback"
    new_val=$(( ($(hex2dec "$ctl") & ~SIZE_MASK) | ((target_n << 8) & SIZE_MASK) ))

    echo "================= 执行计划 ================="
    echo "  GPU            : $GPU_BDF"
    echo "  根端口         : ${ROOT_BDF:-未识别}"
    echo "  ReBAR ECAP     : 0x$(printf '%x' "$ECAP_OFF")"
    echo "  Capability     : $cap"
    echo "  Control 现值   : $ctl  (size field $cur_n = $(n_to_human "$cur_n"))"
    echo "  目标 size 字段 : $target_n = $(n_to_human "$target_n")"
    echo "  目标 Control   : $(dec2hex8 "$new_val")"
    echo "  根端口窗口     : $(root_window_mb "$ROOT_BDF")MB"
    echo "  将要执行："
    echo "    1. 解绑终端设备驱动（xe / snd_hda_intel；pcieport 保持绑定）"
    echo "    2. 写 ReBAR Control：size field $cur_n → $target_n"
    echo "    3. 从内核移除根端口 $ROOT_BDF          ← 风险点"
    echo "    4. 触发 /sys/bus/pci/rescan 重新枚举   ← 风险点"
    echo "    5. 校验 BAR2 是否等于 $(bar2_mb_of_n "$target_n")MB；不符则回滚"
    echo "    6. 成功则重新绑定驱动"
    echo "============================================"
    echo

    if [ "$mode" = "plan" ]; then
        log INFO "dry-run 结束，未做任何修改。确认后执行：sudo $0 apply"
        return 0
    fi

    # ---- apply ----
    need_root
    # 幂等判据必须同时看 BAR2 实际大小，不能只看 Control 的 size 字段：
    # 上一次写完 Control、却在 remove/rescan 之前被打断（Ctrl-C / systemd 超时 /
    # 断电）时，字段已是目标值而 BAR2 仍是 512MB。只看字段就会判"已完成"退出，
    # 自愈从此每次开机都报 OK 却什么也不做，而 --check 每天报 FAIL 修不好。
    local cur_mb want_mb
    cur_mb="$(bar2_mb)"
    want_mb="$(bar2_mb_of_n "$target_n")"
    if [ "$cur_n" -ge "$target_n" ] && [ "$cur_mb" -eq "$want_mb" ]; then
        log OK "BAR2 已是目标尺寸（N=$cur_n，实际 ${cur_mb}MB），幂等退出"
        return 0
    fi
    if [ "$cur_n" -ge "$target_n" ]; then
        log WARN "Control 已是 N=$cur_n，但 BAR2 实际只有 ${cur_mb}MB —— 上次被中断，继续修复"
    fi
    if ! preflight; then
        die "前置检查未通过，拒绝执行。请逐条处理上面的 ERROR 后重试"
    fi

    if [ "$ASSUME_YES" -ne 1 ]; then
        echo
        log WARN "即将移除并重扫根端口。若芯片组不容忍该操作，内核可能挂死，需断电重启。"
        log WARN "全程不写任何持久配置，重启即恢复原状。"
        printf '确认继续？输入 YES：'
        local ans; read -r ans
        [ "$ans" = "YES" ] || die "已取消"
    fi

    mkdir -p "$(dirname "$STATE_FILE")" 2>/dev/null || true
    echo "CTL=$ctl" > "$STATE_FILE" 2>/dev/null || true
    log INFO "已记录初始 Control=$ctl 到 $STATE_FILE"

    # 动手前落一份完整配置空间快照，挂死后重启仍可对比排查
    local cfgdump="/var/log/b580-bar-tool.cfgspace.before"
    lspci -xxx -s "$GPU_BDF" > "$cfgdump" 2>/dev/null && log INFO "配置空间快照：$cfgdump"
    sync 2>/dev/null || true

    do_resize "$ctl" "$target_n"
    case $? in
        0) log OK "完成。建议重启一次，让 xe 以新窗口重新初始化" ;;
        3) log ERROR "执行在写寄存器前中止，系统未做任何修改，无需回滚" ;;
        2) log WARN "BAR2 分配失败，执行回滚"
           rollback_to "$ctl" || log ERROR "回滚失败" ;;
        *) log ERROR "执行中断，尝试回滚"
           rollback_to "$ctl" || log ERROR "回滚失败" ;;
    esac
}

# 演练：完整走一遍 unbind → remove 根端口 → rescan → 验证 → rebind，
# 唯独【不写 ReBAR Control】。目的是单独验证芯片组是否容忍根端口重新枚举。
# 挂了断电重启即恢复（配置空间由 BIOS 重置，BAR 从未被改）；不挂则证明可安全 apply。
# 返回 0 成功；1 中断；2 GPU 未能恢复
do_rehearse() {
    local ctl="$1" ctl_before="$1"
    step "BEGIN rehearse gpu=$GPU_BDF root=$ROOT_BDF ctl=$ctl"
    log INFO "演练模式：不写 ReBAR Control，只验证根端口重新枚举"

    step "PHASE rehearse-unbind"
    if ! unbind_leaf_drivers; then
        log ERROR "终端设备解绑失败，拒绝进入 remove 根端口（风险点）"
        return 1
    fi
    sync

    step "PHASE rehearse-remove-root-port DANGER"
    log INFO "步骤 1/3：移除根端口 $ROOT_BDF（风险点，内核可能挂死）"
    PCI_TREE_REMOVED=1
    if ! echo 1 > "/sys/bus/pci/devices/$ROOT_BDF/remove" 2>/dev/null; then
        PCI_TREE_REMOVED=0
        log ERROR "移除根端口失败"
        return 1
    fi
    step "PHASE rehearse-remove-root-port DONE"
    sync

    step "PHASE rehearse-rescan DANGER"
    log INFO "步骤 2/3：触发 PCI 重新扫描（风险点）"
    rescan_wait
    step "PHASE rehearse-rescan DONE"
    sync

    step "PHASE rehearse-verify"
    log INFO "步骤 3/3：验证"
    if [ ! -e "/sys/bus/pci/devices/$GPU_BDF" ]; then
        log ERROR "GPU 未重新出现 —— 根端口未能重新枚举"
        return 2
    fi
    local now_ctl now_mb
    now_ctl="$(ctl_read)"
    now_mb="$(bar2_mb)"
    log INFO "Control   : $now_ctl（演练前 $ctl_before，应当不变）"
    log INFO "BAR2      : ${now_mb}MB"
    if [ "$(hex2dec "$now_ctl")" != "$(hex2dec "$ctl_before")" ]; then
        log WARN "Control 在演练中发生变化，请核对上面两行"
    fi
    if [ "$now_mb" -eq 0 ]; then
        log ERROR "GPU 已回来但 BAR2 没有分配到地址"
        return 2
    fi
    log OK "演练成功：芯片组容忍根端口重新枚举，BAR2 仍为 ${now_mb}MB"
    log OK "结论：可以安全执行 apply，风险已从「未知」降为「实测通过」"
    rebind_leaf_drivers
    return 0
}

cmd_rehearse() {
    need_root
    gather
    local ctl
    ctl="$(ctl_read)"

    echo "================= 演练计划 ==================="
    echo "  GPU        : $GPU_BDF"
    echo "  根端口     : $ROOT_BDF"
    echo "  Control    : $ctl（保持不动）"
    echo "  BAR2 现值  : $(bar2_mb)MB（演练后应仍是这个值）"
    echo "  将要执行：解绑驱动 → 移除根端口 → rescan → 验证 → 重绑"
    echo "  不会写入 ReBAR Control，不会改动任何持久配置"
    echo "=============================================="
    echo

    if ! preflight; then
        die "前置检查未通过（GPU 仍被占用？），请先停掉相关服务再演练"
    fi

    if [ "$ASSUME_YES" -ne 1 ]; then
        echo
        log WARN "演练同样会移除并重扫根端口。若芯片组不容忍，内核可能挂死，需断电重启。"
        printf '确认演练？输入 YES：'
        local ans; read -r ans
        [ "$ans" = "YES" ] || die "已取消"
    fi

    do_rehearse "$ctl"
    local rc=$?
    case $rc in
        0) log OK "演练结束。接下来可执行：sudo $0 apply" ;;
        *) log ERROR "演练未完成（rc=$rc），请保留 $STEP_FILE 排查"
           fallback_notice ;;
    esac
    return $rc
}

cmd_rollback() {
    need_root
    gather
    local ctl cur_n target_n
    ctl="$(ctl_read)"
    cur_n="$(ctl_size_n "$ctl")"
    if [ -f "$STATE_FILE" ]; then
        local saved; saved="$(sed -nE 's/^CTL=//p' "$STATE_FILE" | head -1)"
        [ -n "$saved" ] && TARGET_N="${TARGET_N:-$(ctl_size_n "$saved")}"
    fi
    # 无状态文件时不得凭空假定目标值：原始 size field 因主板而异
    # （出厂 BIOS 通常 8 = 256MB，改过 BIOS 的可能 9 = 512MB），
    # 硬编码任何一个都会把 BAR2 缩到比原状更小。以"当前值"兜底最安全。
    target_n="${TARGET_N:-$cur_n}"
    if [ "$target_n" -eq "$cur_n" ]; then
        log OK "当前已是 N=$cur_n，无需回滚（不做任何破坏性动作）"
        return 0
    fi
    log WARN "回滚：size field $cur_n → $target_n"
    local new_val
    new_val=$(( ($(hex2dec "$ctl") & ~SIZE_MASK) | ((target_n << 8) & SIZE_MASK) ))
    rollback_to "$(dec2hex8 "$new_val")"
}

# ------------------------------------------------------------ 主流程 ----

main() {
    parse_args "$@"
    [ -w "$(dirname "$LOG_FILE")" ] || LOG_FILE="./b580-bar-tool.log"
    [ -w "$(dirname "$STEP_FILE")" ] || STEP_FILE="./b580-bar-tool.steps"
    log INFO "b580-bar-tool v$VER  子命令=$CMD"

    case "$CMD" in
        status)   need_root; cmd_status ;;
        gpu)      cmd_gpu ;;
        check)    cmd_check ;;
        plan)     cmd_plan_or_apply plan ;;
        rehearse) cmd_rehearse ;;
        apply)    cmd_plan_or_apply apply ;;
        rollback) cmd_rollback ;;
        *)        die "未知子命令：$CMD" ;;
    esac
}

main "$@"
