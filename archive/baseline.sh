#!/bin/bash
# ==============================================================================
# rebar-b580.sh — 通过 PCIe Resizable BAR 扩展 Intel Arc 显卡的 BAR2 窗口
#
# 用途：把 GPU 的 BAR2 从当前的较小尺寸（如 512MB）扩展到此卡支持的最大值
#       （B580 为 16GB），使驱动可完整映射 12GB 显存。
#
# 声明：本脚本为独立实现，仅依据 PCI-SIG 公开的 PCI Express Resizable BAR
#       扩展能力规范（ECAP ID 0x0015）与本人对目标机器的实测数据编写，
#       未参考、未复制任何第三方同类项目的代码、脚本或文档。
#
# 风险：过程中会移除并重新扫描 PCIe 根端口。少数芯片组无法容忍根端口重新
#       枚举，可能导致内核挂死，此类情况只能断电重启。本脚本不写入任何持久
#       配置（不碰 BIOS / GRUB / initramfs），重启后一切回到原状。
#
# 用法：
#   ./rebar-b580.sh status     只读体检，不做任何修改
#   ./rebar-b580.sh plan       默认子命令；dry-run，打印将要执行的步骤
#   ./rebar-b580.sh apply      真正执行
#   ./rebar-b580.sh rollback   把尺寸恢复为脚本启动前记录的初始值
#
# 可选参数（放在子命令之后）：
#   --gpu <BDF>     指定 GPU 的 PCI 地址，默认自动探测
#   --size <N>      指定目标 size 字段 N（实际大小 2^(N+20) 字节），默认取卡上限
#   --yes           跳过 apply 前的交互确认（无人值守用）
#   --log <path>    日志文件路径，默认 /var/log/rebar-b580.log
# ==============================================================================

set -uo pipefail

readonly SCRIPT_VERSION="1.0.0"
readonly ECAP_OFFSET_HINT=0x420     # 本机实测位置；真实值由探测得到
readonly REG_CAP=0x04               # 相对 ECAP 基址：Capability
readonly REG_CTL=0x08               # 相对 ECAP 基址：Control
readonly SIZE_SHIFT=8               # Control bits[13:8] = size field
readonly SIZE_MASK=0x3F00
readonly BAR_INDEX_MASK=0x07
readonly SIZE_BASE_EXP=20           # 实际字节数 = 2^(N+20)

GPU_BDF=""
TARGET_N=""
ASSUME_YES=0
LOG_FILE="/var/log/rebar-b580.log"
CMD="plan"

# ------------------------------------------------------------------ 基础设施 --

log() {
    local level="$1"; shift
    local msg="$*"
    local ts; ts="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '[%s] %-5s %s\n' "$ts" "$level" "$msg"
    if [ -n "$LOG_FILE" ] && [ -w "$(dirname "$LOG_FILE")" ]; then
        printf '[%s] %-5s %s\n' "$ts" "$level" "$msg" >> "$LOG_FILE"
        sync -f "$LOG_FILE" 2>/dev/null || true
    fi
    # 同步进内核日志，便于挂死后用 journalctl -b -1 追查
    logger -t rebar-b580 -- "$level: $msg" 2>/dev/null || true
}

die() { log ERROR "$*"; exit 1; }

need_root() {
    [ "$(id -u)" -eq 0 ] || die "需要 root 权限运行（sudo $0 $*）"
}

hex2dec() {
    local v="${1//[[:space:]]/}"
    v="${v#0x}"; v="${v#0X}"
    [ -n "$v" ] || { echo 0; return; }
    printf '%d' "$((16#$v))"
}
dec2hex8() { printf '%08x' "$1"; }

# ------------------------------------------------------------------ 参数解析 --

parse_args() {
    if [ $# -gt 0 ]; then
        case "$1" in
            status|plan|apply|rollback) CMD="$1"; shift ;;
            -h|--help) sed -n '2,26p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        esac
    fi
    while [ $# -gt 0 ]; do
        case "$1" in
            --gpu)  GPU_BDF="$2"; shift 2 ;;
            --size) TARGET_N="$2"; shift 2 ;;
            --log)  LOG_FILE="$2"; shift 2 ;;
            --yes)  ASSUME_YES=1; shift ;;
            *) die "未知参数：$1（用 --help 查看用法）" ;;
        esac
    done
}

# ------------------------------------------------------ 探测 GPU 与根端口 ----

# 找第一个带 Resizable BAR 扩展能力（ECAP ID 0x0015）的 Intel VGA 设备
detect_gpu() {
    [ -n "$GPU_BDF" ] && return 0
    local dev class
    for dev in /sys/bus/pci/devices/*/; do
        class="$(cat "$dev/class" 2>/dev/null)"
        # 0x03xxxx = 显示类设备
        [ "${class:0:4}" = "0x03" ] || continue
        local bdf; bdf="$(basename "$dev")"
        if ecap_find "$bdf" >/dev/null 2>&1; then
            GPU_BDF="$bdf"
            return 0
        fi
    done
    die "未找到带 Resizable BAR 扩展能力的显示设备"
}

# 在指定偏移处判断是否为 Resizable BAR ECAP（低 16 位 = ID 0x0015）
# 注意：test 的 -eq 不支持十六进制字面量，必须用 (( )) 算术上下文
_is_rebar_ecap() {
    local bdf="$1" off="$2" raw
    raw="$(setpci -s "$bdf" "$(printf '%x' "$off").l" 2>/dev/null)"
    [ -n "$raw" ] || return 1
    (( ( $(hex2dec "$raw") & 0xFFFF ) == 0x0015 ))
}

# 找 ECAP ID 0x0015 的位置，成功则回显基址（十进制）
# 注意：GNU seq 不支持十六进制参数，区间一律用十进制（0x100=256, 0xFFC=4092）
ecap_find() {
    local bdf="$1" off
    # 快速路径：先试已知位置，绝大多数情况一次命中
    if _is_rebar_ecap "$bdf" "$ECAP_OFFSET_HINT"; then
        echo "$ECAP_OFFSET_HINT"; return 0
    fi
    # 慢速路径：全配置空间扫描（步长 4 字节）
    for off in $(seq 256 4 4092); do
        if _is_rebar_ecap "$bdf" "$off"; then
            echo "$off"
            return 0
        fi
    done
    return 1
}

# 从 GPU 的 sysfs 真实路径推出所在根端口
detect_root_port() {
    local path; path="$(realpath "/sys/bus/pci/devices/$GPU_BDF")"
    # 形如 /sys/devices/pci0000:00/0000:00:02.0/0000:02:00.0/.../0000:04:00.0
    # 紧跟在 pciDDDD:BB 之后的第一段就是根端口
    echo "$path" | sed -nE 's#.*/pci[0-9a-f]{4}:[0-9a-f]{2}/([0-9a-f]{4}:[0-9a-f]{2}:[0-9a-f]{2}\.[0-9a-f])/.*#\1#p'
}

# 列出某根端口子树下的全部设备
subtree_devices() {
    local root="$1" rootpath dev
    rootpath="$(realpath "/sys/bus/pci/devices/$root")"
    for dev in /sys/bus/pci/devices/*/; do
        realpath "$dev" 2>/dev/null | grep -q "^${rootpath}/" && basename "$dev"
    done
}

# ------------------------------------------------------------ 寄存器读写 ----

# 读取 Control 寄存器原始值（十六进制，8 位）
ctl_read() {
    local ecap="$1"
    local off; off="$(printf '%x' $((ecap + REG_CTL)))"
    setpci -s "$GPU_BDF" "${off}.l"
}

# 读取 Capability 寄存器原始值
cap_read() {
    local ecap="$1"
    local off; off="$(printf '%x' $((ecap + REG_CAP)))"
    setpci -s "$GPU_BDF" "${off}.l"
}

# 写入 Control 寄存器（保留除 size 外的所有位）
ctl_write() {
    local ecap="$1" newval="$2"
    local off; off="$(printf '%x' $((ecap + REG_CTL)))"
    setpci -s "$GPU_BDF" "${off}.l=$(dec2hex8 "$newval")"
}

# 从 Capability 求本卡支持的最大 size 字段 N
max_supported_n() {
    local cap_hex="$1" bit n max_n=0
    local cap_val; cap_val="$(hex2dec "$cap_hex")"
    for bit in $(seq 4 24); do
        if [ $(( (cap_val >> bit) & 1 )) -eq 1 ]; then
            n=$(( bit - 4 ))
            [ "$n" -gt "$max_n" ] && max_n="$n"
        fi
    done
    echo "$max_n"
}

# 从 sysfs resource 读 BAR2 实际大小（MB）
bar2_size_mb() {
    local res="/sys/bus/pci/devices/$GPU_BDF/resource"
    [ -r "$res" ] || { echo 0; return; }
    local line start end s e
    line="$(sed -n '3p' "$res")"
    start="$(echo "$line" | awk '{print $1}')"
    end="$(echo "$line" | awk '{print $2}')"
    if [ -z "$start" ] || [ "$start" = "0x0000000000000000" ]; then
        echo 0; return
    fi
    # 显式求值，避免把变量值直接塞进算术表达式
    s=$((start)); e=$((end))
    echo $(( (e - s + 1) / 1048576 ))
}

# 根端口 prefetchable 窗口大小（MB）
root_prefetch_mb() {
    local out size
    out="$(lspci -vv -s "$1" 2>/dev/null | grep -m1 'Prefetchable memory behind bridge')"
    size="$(echo "$out" | sed -nE 's/.*\[size=([0-9]+[MG])\].*/\1/p')"
    case "$size" in
        *G) echo $(( ${size%G} * 1024 )) ;;
        *M) echo "${size%M}" ;;
        *)  echo 0 ;;
    esac
}

# ------------------------------------------------------------ 前置检查 ----

# 返回 0=可以执行，1=不可以（并打印原因）
preflight() {
    local ecap="$1" root="$2" rc=0

    if ! grep -qw 'pci=realloc' /proc/cmdline; then
        log WARN "内核命令行没有 pci=realloc —— 重扫时内核可能不被允许扩大桥窗口"
        log WARN "可在 /etc/default/grub 的 GRUB_CMDLINE_LINUX_DEFAULT 中追加后 update-grub 并重启"
        rc=1
    fi

    if [ -z "$root" ]; then
        log ERROR "无法从 GPU 路径推断根端口"
        return 1
    fi

    local devs; devs="$(subtree_devices "$root")"
    log INFO "根端口 $root 子树下的设备："
    local d
    while read -r d; do
        [ -n "$d" ] || continue
        local cls drv
        cls="$(lspci -n -s "$d" 2>/dev/null | awk '{print $3}')"
        drv="$(basename "$(readlink "/sys/bus/pci/devices/$d/driver" 2>/dev/null)" 2>/dev/null)"
        log INFO "  - $d  class=$cls  driver=${drv:-none}"
    done <<< "$devs"

    # 安全判据：子树内除 GPU 自身外，只允许 PCIe 桥和同卡的 HDMI 音频
    local extra=0
    while read -r d; do
        [ -n "$d" ] || continue
        [ "$d" = "$GPU_BDF" ] && continue
        local cls; cls="$(lspci -n -s "$d" 2>/dev/null | awk '{print $3}')"
        case "$cls" in
            0x0604*|0x0403*) ;;                 # PCIe 桥 / 音频设备，允许
            *) log ERROR "根端口下存在其他设备 $d (class=$cls)，移除根端口会把它一起摘掉"
               extra=1 ;;
        esac
    done <<< "$devs"
    [ "$extra" -eq 1 ] && rc=1

    # 是否有进程占用 GPU
    local holders
    holders="$(fuser /dev/dri/renderD* /dev/dri/card0 2>/dev/null | tr -d ' ' )"
    if [ -n "$holders" ]; then
        log WARN "有进程正占用 GPU 设备节点：$holders"
        log WARN "推理/渲染任务在跑时移除根端口风险很高，请先停掉相关服务"
        rc=1
    fi

    return $rc
}

# ------------------------------------------------------------ 执行动作 ----

unbind_driver() {
    local bdf="$1" drv link
    link="$(readlink "/sys/bus/pci/devices/$bdf/driver" 2>/dev/null)" || true
    if [ -z "$link" ]; then
        log INFO "$bdf 当前无驱动绑定，跳过"
        return 0
    fi
    drv="$(basename "$link")"
    log INFO "解绑 $bdf 的驱动：$drv"
    echo "$bdf" > "/sys/bus/pci/drivers/$drv/unbind" 2>/dev/null \
        || log WARN "解绑 $bdf 失败（可能已解绑或驱动拒绝）"
}

do_resize() {
    local ecap="$1" root="$2" target_n="$3" orig_ctl="$4"
    local new_ctl
    new_ctl=$(( (orig_ctl & ~SIZE_MASK) | ((target_n << SIZE_SHIFT) & SIZE_MASK) ))

    log INFO "Control 寄存器：$orig_ctl → $new_ctl（size field $(( (orig_ctl & SIZE_MASK) >> SIZE_SHIFT )) → $target_n）"

    # 1) 解绑子树内所有驱动
    local d
    while read -r d; do
        [ -n "$d" ] || continue
        unbind_driver "$d"
    done <<< "$(subtree_devices "$root")"

    # 2) 写 size 字段
    log INFO "步骤 1/4：写入 ReBAR Control 寄存器"
    ctl_write "$ecap" "$new_ctl" || { log ERROR "写 Control 寄存器失败"; return 1; }
    local verify; verify="$(ctl_read "$ecap")"
    if [ "$((16#$verify))" != "$new_ctl" ]; then
        log ERROR "写入校验失败：期望 $(dec2hex8 "$new_ctl")，实际 $verify"
        return 1
    fi
    log INFO "  写入校验通过：$verify"

    # 3) 移除根端口
    log INFO "步骤 2/4：从内核移除根端口 $root（此处为风险点，可能挂死）"
    if ! echo 1 > "/sys/bus/pci/devices/$root/remove" 2>/dev/null; then
        log ERROR "移除根端口失败"
        return 1
    fi
    log INFO "  根端口已移除"

    # 4) 重新扫描
    log INFO "步骤 3/4：触发 PCI 总线重新扫描"
    echo 1 > /sys/bus/pci/rescan 2>/dev/null
    sleep 1

    # 若 GPU 没回来，重试最多 3 次
    local tries=0
    while [ ! -e "/sys/bus/pci/devices/$GPU_BDF" ] && [ "$tries" -lt 3 ]; do
        tries=$((tries + 1))
        log WARN "GPU 未出现，重试扫描（第 $tries 次）"
        echo 1 > /sys/bus/pci/rescan 2>/dev/null
        sleep 1
    done

    # 5) 验证
    log INFO "步骤 4/4：验证结果"
    if [ ! -e "/sys/bus/pci/devices/$GPU_BDF" ]; then
        log ERROR "GPU 未重新出现，BAR2 无法分配"
        return 2
    fi

    local now_mb; now_mb="$(bar2_size_mb)"
    if [ "$now_mb" -eq 0 ]; then
        log ERROR "GPU 已回来但 BAR2 没有分配到地址"
        return 2
    fi

    local want_mb=$(( 1 << (target_n + SIZE_BASE_EXP - 20) ))
    if [ "$now_mb" -ne "$want_mb" ]; then
        log ERROR "BAR2 实际 ${now_mb}MB，期望 ${want_mb}MB —— 窗口不够大，可能被降级分配"
        return 2
    fi

    log OK "成功：BAR2 = ${now_mb}MB"
    return 0
}

rollback_to() {
    local ecap="$1" root="$2" orig_ctl="$3"
    log WARN "开始回滚到原始 Control 值 $orig_ctl"
    ctl_write "$ecap" "$orig_ctl" || log ERROR "回滚写寄存器失败"
    if [ -e "/sys/bus/pci/devices/$root" ]; then
        echo 1 > "/sys/bus/pci/devices/$root/remove" 2>/dev/null || true
    fi
    echo 1 > /sys/bus/pci/rescan 2>/dev/null
    sleep 1
    if [ -e "/sys/bus/pci/devices/$GPU_BDF" ]; then
        log OK "回滚完成，BAR2 = $(bar2_size_mb)MB"
        return 0
    fi
    log ERROR "回滚后 GPU 仍未出现 —— 请立即重启机器"
    return 1
}

# ------------------------------------------------------------ 各子命令 ----

cmd_status() {
    detect_gpu
    local root; root="$(detect_root_port)"
    local ecap; ecap="$(ecap_find "$GPU_BDF")" || die "该卡没有 Resizable BAR 扩展能力"

    log INFO "GPU            : $GPU_BDF"
    log INFO "根端口         : ${root:-未识别}"
    log INFO "ReBAR ECAP 位置: 0x$(printf '%x' "$ecap")"

    local cap ctl cur_n max_n
    cap="$(cap_read "$ecap")"
    ctl="$(ctl_read "$ecap")"
    cur_n=$(( ($(hex2dec "$ctl") & SIZE_MASK) >> SIZE_SHIFT ))
    max_n="$(max_supported_n "$cap")"

    log INFO "Capability     : $cap"
    log INFO "Control        : $ctl"
    log INFO "BAR 索引       : $(( $(hex2dec "$ctl") & BAR_INDEX_MASK ))"
    log INFO "当前 size 字段 : $cur_n  (=$(( 1 << (cur_n + SIZE_BASE_EXP - 20) ))MB)"
    log INFO "卡支持上限     : $max_n  (=$(( 1 << (max_n + SIZE_BASE_EXP - 20) ))MB)"
    log INFO "BAR2 实际大小  : $(bar2_size_mb)MB"
    log INFO "根端口窗口     : $(root_prefetch_mb "$root")MB (prefetchable)"
    log INFO "驱动           : $(basename "$(readlink "/sys/bus/pci/devices/$GPU_BDF/driver" 2>/dev/null)" 2>/dev/null || echo none)"

    echo
    if [ "$cur_n" -eq "$max_n" ]; then
        log OK "判定：BAR2 已是本卡最大尺寸，无需处理"
    else
        log INFO "判定：可扩展 $cur_n → $max_n，运行 apply 执行"
    fi
}

cmd_plan_or_apply() {
    local mode="$1"
    detect_gpu
    local root; root="$(detect_root_port)"
    local ecap; ecap="$(ecap_find "$GPU_BDF")" || die "该卡没有 Resizable BAR 扩展能力"

    local cap ctl cap_val ctl_val cur_n max_n target_n
    cap="$(cap_read "$ecap")"; ctl="$(ctl_read "$ecap")"
    cap_val="$(hex2dec "$cap")"; ctl_val="$(hex2dec "$ctl")"
    cur_n=$(( (ctl_val & SIZE_MASK) >> SIZE_SHIFT ))
    max_n="$(max_supported_n "$cap")"
    target_n="${TARGET_N:-$max_n}"

    [ "$target_n" -le "$max_n" ] || die "目标 N=$target_n 超过本卡上限 $max_n"
    [ "$target_n" -ge "$cur_n" ] || die "目标 N=$target_n 小于当前 $cur_n，缩容不在本脚本职责内"

    echo "=========== 执行计划 ==========="
    echo "  GPU            : $GPU_BDF"
    echo "  根端口         : ${root:-未识别}"
    echo "  ReBAR ECAP     : 0x$(printf '%x' "$ecap")"
    echo "  Capability     : $cap"
    echo "  Control 现值   : $ctl  (size field $cur_n = $(( 1 << (cur_n + SIZE_BASE_EXP - 20) ))MB)"
    echo "  目标 size 字段 : $target_n = $(( 1 << (target_n + SIZE_BASE_EXP - 20) ))MB"
    local new_ctl; new_ctl=$(( (ctl_val & ~SIZE_MASK) | ((target_n << SIZE_SHIFT) & SIZE_MASK) ))
    echo "  目标 Control   : $(dec2hex8 "$new_ctl")"
    echo "  根端口窗口     : $(root_prefetch_mb "$root")MB"
    echo "  将执行的步骤："
    echo "    1. 解绑根端口子树内全部驱动（含 xe 与 snd_hda_intel）"
    echo "    2. 写 ReBAR Control 寄存器 size field：$cur_n → $target_n"
    echo "    3. 从内核移除根端口 $root"
    echo "    4. 触发 /sys/bus/pci/rescan 重新枚举"
    echo "    5. 校验 BAR2 是否等于 $(( 1 << (target_n + SIZE_BASE_EXP - 20) ))MB；不符则回滚"
    echo "================================"
    echo

    if [ "$mode" = "plan" ]; then
        log INFO "dry-run 结束。未做任何修改。确认无误后执行：sudo $0 apply"
        return 0
    fi

    # ---- apply ----
    need_root "$@"
    if ! preflight "$ecap" "$root"; then
        die "前置检查未通过，拒绝执行。请逐条处理上面的 WARN/ERROR 后重试。"
    fi

    if [ "$ASSUME_YES" -ne 1 ]; then
        echo
        log WARN "即将移除并重新扫描根端口。若芯片组不容忍该操作，内核可能挂死，需断电重启。"
        log WARN "本操作不写入任何持久配置，重启即恢复原状。"
        printf '继续？输入 YES 确认：'
        read -r ans
        [ "$ans" = "YES" ] || die "已取消"
    fi

    do_resize "$ecap" "$root" "$target_n" "$ctl_val"
    local rc=$?
    case "$rc" in
        0) log OK "完成。建议重启一次，让 xe 以此尺寸重新初始化。" ;;
        2) log WARN "BAR2 分配失败，执行回滚"
           rollback_to "$ecap" "$root" "$ctl_val" || log ERROR "回滚失败，请重启机器" ;;
        *) log ERROR "执行中断（rc=$rc），尝试回滚"
           rollback_to "$ecap" "$root" "$ctl_val" || log ERROR "回滚失败，请重启机器" ;;
    esac
    return 0
}

cmd_rollback() {
    need_root "$@"
    detect_gpu
    local root; root="$(detect_root_port)"
    local ecap; ecap="$(ecap_find "$GPU_BDF")" || die "该卡没有 Resizable BAR 扩展能力"
    local ctl cur_n target_n
    ctl="$(ctl_read "$ecap")"
    cur_n=$(( ($(hex2dec "$ctl") & SIZE_MASK) >> SIZE_SHIFT ))
    target_n="${TARGET_N:-8}"    # 默认回到 256MB（N=8）
    log WARN "回滚：size field $cur_n → $target_n（注意：这是降到 256MB，不是恢复到某次运行前的值）"
    local new_ctl; new_ctl=$(( ($(hex2dec "$ctl") & ~SIZE_MASK) | ((target_n << SIZE_SHIFT) & SIZE_MASK) ))
    rollback_to "$ecap" "$root" "$new_ctl"
}

# ------------------------------------------------------------------ 主流程 --

main() {
    parse_args "$@"
    case "$CMD" in
        status)   need_root "$@"; cmd_status ;;
        plan)     cmd_plan_or_apply plan ;;
        apply)    cmd_plan_or_apply apply ;;
        rollback) cmd_rollback ;;
        *)        die "未知子命令：$CMD" ;;
    esac
}

main "$@"
