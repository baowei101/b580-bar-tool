#!/usr/bin/env bash
#
# ============================================================================
# 脚本名称 : rebar_cand_hy3.sh
# 用途     : 在 Linux x86 服务器上为 Intel Arc B580（12GB）显卡启用 PCIe
#            Resizable BAR，将 BAR2 从 512 MB 扩展到 16 GB，并让内核重新枚举
#            根端口子树以接受新的地址窗口尺寸。
#
# 用法     :
#   ./rebar_cand_hy3.sh status             # 只读查看当前 ReBAR 状态
#   ./rebar_cand_hy3.sh plan               # 默认子命令：dry-run，打印将执行的全部动作
#   ./rebar_cand_hy3.sh apply              # 默认 dry-run，仅打印动作（不修改）
#   ./rebar_cand_hy3.sh apply --apply      # 真正执行扩展
#   ./rebar_cand_hy3.sh rollback           # dry-run 打印回滚动作
#   ./rebar_cand_hy3.sh rollback --apply   # 真正执行回滚
#
# 风险     :
#   本脚本会移除 PCIe 根端口子树并触发内核重新扫描，该过程在极少数情况下可能
#   使内核挂死。本机无 IPMI / 无带外管理，一旦挂死需到机房手动按电源键。
#   对策（见下方设计说明）：
#     1) 所有修改均为“运行时”操作（仅动 PCI 配置空间与 sysfs），不写任何持久
#        配置（不动 BIOS/固件/GRUB/initramfs），因此关机重启后 BIOS/UEFI 会
#        重置设备配置空间，ReBAR 控制寄存器回到出厂默认，即“重启后状态干净”。
#     2) 最危险的窗口（移除根端口 + 重新扫描）被压缩到仅两步，且每步执行前均
#        先把日志落盘并 sync，便于事后判断死在哪一步。
#     3) 任何破坏性步骤都需显式 --apply；默认全部 dry-run。
#
# 独立性声明 :
#   本脚本为完全独立实现，仅依据任务书给出的 PCIe 规范（Resizable BAR 扩展能力
#   ECAP ID 0x0015）与实测寄存器数值编写，未参考、搜索或回忆任何名为 arc-rebar
#   的第三方项目（作者 Rod Burlamaqui）的源码、脚本或文档。
# ============================================================================

# 注意：未开启 set -e，因为本脚本需自行捕获失败并触发回滚逻辑。
set -u

# ----------------------------- 常量定义 ------------------------------------
GPU="0000:04:00.0"        # 目标 GPU（Arc B580）
SW_UP="0000:02:00.0"      # 显卡板载 PCIe switch 上游端口
ROOT="0000:00:02.0"       # PCIe 根端口（bus 02-05）
AUDIO="0000:05:00.0"      # 同卡 HDMI 音频
DS1="0000:03:01.0"        # switch 下游端口（bus 04）
DS2="0000:03:02.0"        # switch 下游端口（bus 05）

ECAP_OFF=0x420            # Resizable BAR 扩展能力头
CAP_OFF=0x424             # Capability 寄存器
CTRL_OFF=0x428            # Control 寄存器
STAT_OFF=0x42c            # Status 寄存器

TARGET_N=14               # 目标 size 字段 N=14 -> 2^(14+20)=16GB
BAR_IDX=2                 # 操作的是 BAR2
STATE_FILE="/tmp/.rebar_orig_ctrl"   # 记录初始 Control 值供回滚

# 全局开关
SUBCMD="plan"
APPLY=0

# 日志：优先写 /var/log（磁盘），不可写则退到当前目录
LOG_FILE="/var/log/rebar_cand_hy3.log"
if ! touch "$LOG_FILE" 2>/dev/null; then
    LOG_FILE="./rebar_cand_hy3.log"
fi

# ----------------------------- 基础工具函数 --------------------------------
log() {
    # 写一行带时间戳的日志（不依赖终端）
    { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; } >> "$LOG_FILE" 2>/dev/null
}

size_human() {
    # 输入 size 字段 N，输出人类可读大小
    local n=$1
    local bytes=$(( 1 << (n + 20) ))
    local gb=$(( bytes / 1073741824 ))
    local mb=$(( bytes / 1048576 ))
    echo "${gb}GB (${mb}MB)"
}

compute_max_n() {
    # 从 Capability 寄存器值解析最大支持的 N（bit(4+N) 置位表示支持 2^(N+20)）
    local caps=$1 v=$((0x$caps)) i maxn=-1
    for i in $(seq 4 19); do
        if (( (v >> i) & 1 )); then maxn=$((i - 4)); fi
    done
    echo "$maxn"
}

read_ctrl() {
    # 读 Control 寄存器（16 位）原值，例如 0922
    setpci -s "$GPU" ${CTRL_OFF}.W 2>/dev/null
}

read_caps() {
    setpci -s "$GPU" ${CAP_OFF}.W 2>/dev/null
}

read_stat() {
    setpci -s "$GPU" ${STAT_OFF}.W 2>/dev/null
}

read_ecap_header() {
    # 读 ECAP header（32 位）
    setpci -s "$GPU" ${ECAP_OFF}.L 2>/dev/null
}

ctrl_to_n() {
    # 从 Control 原值取出 size 字段 N = bits[13:8]
    local c=$1
    echo $(( (0x$c >> 8) & 0x3F ))
}

ctrl_to_baridx() {
    # 从 Control 原值取出 BAR 索引 = bits[2:0]
    local c=$1
    echo $(( 0x$c & 0x7 ))
}

# ----------------------------- 动作执行器 ----------------------------------
# act <描述> <命令字符串>
#   若 APPLY=1 则真正执行并把“执行前”日志落盘+sync；否则仅打印（dry-run）。
act() {
    local label="$1" cmd="$2"
    if (( APPLY )); then
        echo ">> 执行: $label"
        log "PRE-EXEC: $label | cmd=[$cmd]"
        sync            # 关键：确保“即将执行”的痕迹已落盘，便于内核挂死后定位
        eval "$cmd"
        local rc=$?
        sync
        log "POST-EXEC: $label rc=$rc"
        return $rc
    else
        echo ">> [dry-run] $label"
        echo "     命令: $cmd"
        return 0
    fi
}

# ----------------------------- 前置安全检查 --------------------------------
check_ecap_header() {
    # 确认 0x420 处确为 Resizable BAR 扩展能力（ID=0x0015），避免误改寄存器
    local hdr
    hdr=$(read_ecap_header) || { echo "!! 无法读取 ECAP header"; return 1; }
    local id=$(( 0x$hdr & 0xFFFF ))
    if (( id != 0x0015 )); then
        echo "!! 警告：0x420 处扩展能力 ID=0x$(printf %04x $id)，非预期 0x0015（Resizable BAR）"
        echo "   偏移可能与任务书不一致，已停止以防误改。请人工核实。"
        return 1
    fi
    echo "   已确认 0x420 为 Resizable BAR 扩展能力 (ID=0x0015)。"
    return 0
}

check_root_port_subtree() {
    # 枚举根端口子树（bus 02-05）上的全部设备，确认没有“显卡卡之外”的其他设备。
    # 若存在外来设备，移除根端口会误伤它们，必须拒绝。
    echo ">> 检查根端口 $ROOT 子树下是否存在非本显卡卡的其他设备..."
    local expected="0000:02:00.0 0000:03:01.0 0000:03:02.0 0000:04:00.0 0000:05:00.0"
    local found=""
    for dev in /sys/bus/pci/devices/0000:0[2345]:*; do
        [ -e "$dev" ] || continue
        found="$found $(basename "$dev")"
    done
    # 去重排序
    found=$(echo "$found" | tr ' ' '\n' | grep -v '^$' | sort -u | tr '\n' ' ')
    for d in $found; do
        local ok=0
        for e in $expected; do
            [ "$d" = "$e" ] && ok=1 && break
        done
        if [ $ok -eq 0 ]; then
            echo "!! 发现非预期设备 $d 位于根端口子树下。"
            echo "!! 移除根端口会误伤该设备，拒绝执行。"
            if (( APPLY )); then return 1; else return 0; fi
        fi
    done
    echo "   子树设备均在预期显卡卡拓扑内（switch/下游端口/GPU/音频），安全。"
    return 0
}

check_gpu_in_use() {
    # 检测 GPU 是否正被进程占用（DMA 在途风险）。best-effort：优先 fuser/lsof，
    # 若工具不可用则跳过，依赖后续“解绑驱动返回 EBUSY”作为权威兜底。
    echo ">> 检查 GPU 是否被进程占用（DMA 在途风险）..."
    local nodes=""
    nodes=$(ls /dev/dri/* 2>/dev/null)
    local busy=0
    if [ -n "$nodes" ]; then
        if command -v fuser >/dev/null 2>&1; then
            fuser -s $nodes 2>/dev/null && busy=1
        elif command -v lsof >/dev/null 2>&1; then
            lsof -t $nodes 2>/dev/null | grep -q . && busy=1
        fi
    fi
    if [ $busy -eq 1 ]; then
        echo "!! GPU 正被进程占用，移除会导致 DMA 在途数据被破坏。"
        echo "!! 请先停止推理/显示等占用进程后再执行。"
        if (( APPLY )); then return 1; else return 0; fi
    fi
    if [ -z "$nodes" ]; then
        echo "   未找到 /dev/dri 节点（可能驱动未加载），继续。"
    else
        echo "   GPU 未被 fuser/lsof 检测到占用（工具不可用时跳过该检测）。"
    fi
    return 0
}

# ----------------------------- 驱动解绑 ------------------------------------
unbind_drivers() {
    # 解绑 GPU 的 xe 驱动，确保改写 BAR 尺寸时设备不被内核访问。
    if [ -e /sys/bus/pci/devices/$GPU/driver ]; then
        local drv
        drv=$(basename "$(readlink -f /sys/bus/pci/devices/$GPU/driver)")
        act "解绑 $GPU 的驱动 $drv（释放 BAR 占用）" \
            "echo $GPU > /sys/bus/pci/drivers/$drv/unbind"
    else
        echo "   $GPU 当前未绑定驱动，跳过解绑。"
    fi
    # 同卡 HDMI 音频若绑定了驱动也一并解绑，避免 remove 冲突
    if [ -e /sys/bus/pci/devices/$AUDIO/driver ]; then
        local adrv
        adrv=$(basename "$(readlink -f /sys/bus/pci/devices/$AUDIO/driver)")
        act "解绑 $AUDIO 的驱动 $adrv" \
            "echo $AUDIO > /sys/bus/pci/drivers/$adrv/unbind"
    fi
}

# ----------------------------- 验证函数 ------------------------------------
verify_after_rescan() {
    # 重新枚举后验证：Control size 字段是否达到目标，且 BAR2 是否真正分到地址。
    echo ">> 验证重新枚举结果..."
    local new_ctrl new_n
    new_ctrl=$(read_ctrl 2>/dev/null) || {
        echo "!! 无法读取 Control 寄存器，设备可能未重新出现。"
        return 1
    }
    new_n=$(ctrl_to_n "$new_ctrl")
    echo "   重新枚举后 Control size 字段 N=$new_n（目标 $TARGET_N）"

    local res2 start end size
    if [ ! -e /sys/bus/pci/devices/$GPU/resource2 ]; then
        echo "!! 找不到 $GPU/resource2，设备未恢复。"
        return 1
    fi
    res2=$(cat /sys/bus/pci/devices/$GPU/resource2 2>/dev/null)
    start=$(( ${res2%% *} ))
    end=$(( ${res2##* } ))
    size=$(( end - start + 1 ))
    echo "   BAR2 资源: start=0x$(printf %x $start) end=0x$(printf %x $end) size=$(( size / 1073741824 ))GB"

    if (( new_n == TARGET_N )) && (( size >= 0x400000000 )); then
        echo "== 成功：BAR2 已扩展为 16 GB 并被内核分配地址。"
        return 0
    else
        echo "!! 验证失败：size 字段 N=$new_n, 分配尺寸=$(printf 0x%x $size) (需 >= 0x400000000)。"
        return 1
    fi
}

# ----------------------------- 回滚函数 ------------------------------------
do_rollback() {
    # 将 size 字段恢复到脚本启动前记录的初始值（STATE_FILE）。
    # 在 apply 中途失败时被自动调用，也可作为独立子命令 rollback 调用。
    echo "====== 回滚：将 BAR2 size 字段恢复到初始值 ======"
    local orig_ctrl
    if [ -f "$STATE_FILE" ]; then
        orig_ctrl=$(cat "$STATE_FILE")
        echo "   从 $STATE_FILE 读取初始 Control=0x$orig_ctrl"
    else
        echo "!! 未找到初始值记录，回退到默认 N=9 (0x0922, 512MB)。"
        orig_ctrl="0922"
    fi
    local orig_n
    orig_n=$(ctrl_to_n "$orig_ctrl")

    # 设备可能仍在线，先解绑（若已不可见则跳过）
    if [ -e /sys/bus/pci/devices/$GPU ]; then
        unbind_drivers
    else
        echo "   $GPU 当前不可见，尝试直接恢复。"
    fi

    local cur_ctrl new_ctrl
    cur_ctrl=$(read_ctrl 2>/dev/null) || {
        echo "!! 设备未出现，无法回滚。"
        rollback_fallback
        return 1
    }
    new_ctrl=$(( (0x$cur_ctrl & 0xC0FF) | (orig_n << 8) ))
    # 仅改 bits[13:8]，原样保留 bits[2:0] 与其他位
    act "回滚 Control size 字段为 N=$orig_n（0x$cur_ctrl -> 0x$(printf %04x $new_ctrl)）" \
        "setpci -s $GPU ${CTRL_OFF}.W=0x$(printf %04x $new_ctrl)"
    act "移除根端口 $ROOT 子树以触发重新枚举" \
        "echo 1 > /sys/bus/pci/devices/$ROOT/remove"
    act "触发全总线重新扫描" \
        "echo 1 > /sys/bus/pci/rescan"

    if (( APPLY )); then
        if verify_after_rescan; then
            echo "== 回滚成功，GPU 恢复为初始尺寸。"
            return 0
        else
            echo "!! 回滚后仍无法分配地址，GPU 可能暂时不可用。"
            rollback_fallback
            return 1
        fi
    else
        echo "   [dry-run] 回滚后将验证 BAR2 资源是否恢复。"
        return 0
    fi
}

rollback_fallback() {
    # 兜底提示：回滚也失败时的明确指引
    echo ""
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    echo "!! 兜底提示：自动回滚未能恢复 GPU 的可正常工作状态。"
    echo "!! 请直接到机房对服务器执行硬重启（长按电源键）。"
    echo "!! 本脚本仅修改运行时 PCI 配置空间与 sysfs，未改动任何持久配置；"
    echo "!! 重启后 BIOS/UEFI 会重置设备配置空间，ReBAR 控制寄存器回到出厂默认"
    echo "!! （512MB），xe 驱动可正常以 512MB 小窗口加载，系统恢复干净状态。"
    echo "!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!!"
    log "ROLLBACK FALLBACK TRIGGERED: 需人工硬重启"
}

# ----------------------------- 主流程：apply / plan ------------------------
do_apply() {
    log "===== apply/plan 开始 (APPLY=$APPLY) ====="
    check_ecap_header || return 1

    local orig_ctrl
    orig_ctrl=$(read_ctrl) || { echo "!! 无法读取 $GPU Control 寄存器"; return 1; }
    local orig_n
    orig_n=$(ctrl_to_n "$orig_ctrl")

    if (( APPLY )); then
        echo "$orig_ctrl" > "$STATE_FILE"
        echo "   已记录初始 Control=0x$orig_ctrl 到 $STATE_FILE"
    else
        echo "   [dry-run] 将记录初始 Control=0x$orig_ctrl 到 $STATE_FILE"
    fi

    # 幂等检查：尺寸已达标直接安全退出
    if (( orig_n == TARGET_N )); then
        echo "BAR2 当前 size 字段 N=$orig_n 已是目标 16 GB，无需操作，安全退出（幂等）。"
        return 0
    fi

    echo "当前 N=$orig_n ($(size_human $orig_n))，目标 N=$TARGET_N ($(size_human $TARGET_N))"

    # 前置安全检查（apply 模式下不通过则中止；plan 模式仅告警）
    check_root_port_subtree || return 1
    check_gpu_in_use || return 1

    echo ""
    echo "====== 将执行的动作序列 ======"

    # 步骤 1：解绑驱动
    unbind_drivers

    # 步骤 2：改写 Control size 字段（仅改 bits[13:8]，保留 bits[2:0] 及其他位）
    local cur_ctrl new_ctrl
    cur_ctrl=$(read_ctrl)
    new_ctrl=$(( (0x$cur_ctrl & 0xC0FF) | (TARGET_N << 8) ))
    act "改写 Control size 字段 N=$TARGET_N（0x$cur_ctrl -> 0x$(printf %04x $new_ctrl)）" \
        "setpci -s $GPU ${CTRL_OFF}.W=0x$(printf %04x $new_ctrl)"

    # 步骤 3：移除根端口子树（最危险步骤）
    echo "   [注意] 下一步为最危险操作（移除根端口子树），内核有极低概率挂死。"
    echo "   [注意] 本操作纯运行时、无持久配置，若挂死请硬重启，重启后状态干净。"
    act "移除根端口 $ROOT 子树（最危险步骤，可能使内核挂死）" \
        "echo 1 > /sys/bus/pci/devices/$ROOT/remove"

    # 步骤 4：触发重新扫描
    act "触发全总线重新扫描（内核按新尺寸重分配窗口）" \
        "echo 1 > /sys/bus/pci/rescan"

    if (( APPLY )); then
        if verify_after_rescan; then
            echo "== 全部完成：BAR2 已成功扩展为 16 GB。"
            return 0
        else
            echo "!! 执行后验证失败，启动自动回滚..."
            do_rollback
            return 1
        fi
    else
        echo "   [dry-run] 真正执行（--apply）后将验证 BAR2 资源是否达到 16GB，"
        echo "            失败会自动回滚；若回滚仍失败会提示硬重启。"
        return 0
    fi
}

# ----------------------------- 状态查看 ------------------------------------
do_status() {
    echo "=== PCIe Resizable BAR 状态 ($GPU) ==="
    check_ecap_header
    local ctrl caps stat n maxn baridx
    ctrl=$(read_ctrl)
    caps=$(read_caps)
    stat=$(read_stat)
    n=$(ctrl_to_n "$ctrl")
    maxn=$(compute_max_n "$caps")
    baridx=$(ctrl_to_baridx "$ctrl")
    echo "Control =0x$ctrl | BAR索引=$baridx | size字段N=$n -> $(size_human $n)"
    echo "Capability=0x$caps | 最大支持N=$maxn -> $(size_human $maxn)"
    echo "Status  =0x$stat"
    echo "目标     : N=$TARGET_N -> $(size_human $TARGET_N)"
    echo ""
    echo "--- 根端口 $ROOT 预取窗口 ---"
    lspci -s "$ROOT" -vvv 2>/dev/null | grep -i "Prefetchable memory behind bridge" | head -1
    echo ""
    echo "--- 驱动绑定与 BAR2 资源 ---"
    if [ -e /sys/bus/pci/devices/$GPU/driver ]; then
        echo "GPU 驱动: $(basename "$(readlink -f /sys/bus/pci/devices/$GPU/driver)")"
    else
        echo "GPU 驱动: 无（未绑定）"
    fi
    if [ -e /sys/bus/pci/devices/$GPU/resource2 ]; then
        local r2 start end size
        r2=$(cat /sys/bus/pci/devices/$GPU/resource2)
        start=$(( ${r2%% *} )); end=$(( ${r2##* } )); size=$(( end - start + 1 ))
        echo "BAR2 当前资源: $r2  (size=$(( size / 1073741824 ))GB)"
    fi
    echo ""
    echo "--- 判定结论 ---"
    if (( n == TARGET_N )); then
        echo "已为 16 GB，无需操作。"
    elif (( maxn >= TARGET_N )); then
        echo "未达目标但硬件支持 16GB，可执行 plan / apply --apply 扩展。"
    else
        echo "硬件最大仅支持 N=$maxn，无法达到 16GB。"
    fi
}

# ----------------------------- 用法说明 ------------------------------------
print_usage() {
    cat <<EOF
用法: $0 <status|plan|apply|rollback> [--apply]

  status    只读查看当前 ReBAR 状态
  plan      默认子命令，dry-run 打印将执行的全部动作（不修改任何东西）
  apply     默认 dry-run 仅打印动作；加 --apply 才真正执行扩展
  rollback  默认 dry-run 打印回滚动作；加 --apply 才真正执行回滚

所有破坏性操作默认 dry-run，必须显式 --apply 才会真正修改。
需要 root 权限（setpci / sysfs remove 均要求 root）。
EOF
}

# ----------------------------- 参数解析 ------------------------------------
for a in "$@"; do
    case "$a" in
        status|plan|apply|rollback) SUBCMD="$a" ;;
        --apply) APPLY=1 ;;
        -h|--help) print_usage; exit 0 ;;
        *) echo "未知参数: $a"; print_usage; exit 1 ;;
    esac
done

# 非 root 提示（setpci / sysfs 写需要 root）
if [ "$(id -u)" -ne 0 ]; then
    echo "警告：本脚本需要 root 权限才能读写 PCI 配置空间与 sysfs；"
    echo "       当前非 root，只读类操作可能部分失败。建议 sudo 运行。"
fi

# ----------------------------- 子命令分发 ----------------------------------
case "$SUBCMD" in
    status)
        do_status
        ;;
    plan)
        # 默认子命令：强制 dry-run
        APPLY=0
        do_apply
        ;;
    apply)
        if (( APPLY )); then
            do_apply
        else
            echo "apply 为危险操作，默认仅 dry-run 打印动作。"
            echo "如需真正执行，请加 --apply： $0 apply --apply"
            echo ""
            do_apply
        fi
        ;;
    rollback)
        if (( APPLY )); then
            do_rollback
        else
            echo "rollback 为危险操作，默认仅 dry-run 打印动作。"
            echo "如需真正执行，请加 --apply： $0 rollback --apply"
            echo ""
            do_rollback
        fi
        ;;
esac

exit 0
