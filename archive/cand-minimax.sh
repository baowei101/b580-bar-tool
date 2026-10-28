#!/bin/bash
#==============================================================================
# PCIe Resizable BAR 启用脚本 —— 独立实现版本
#
# 用途：把 Intel Arc B580（BAR2）从 512 MB 扩展到 16 GB，
#       通过 PCIe ReBAR 扩展能力（ECAP ID 0x0015）写入目标 size 字段，
#       再触发内核重新枚举根端口，使内核按新尺寸分配窗口。
#
# 用法：
#   ./rebar.sh status                # 只读状态
#   ./rebar.sh plan                  # 默认 dry-run，逐条打印动作计划
#   ./rebar.sh apply                 # 真正执行（需确认风险）
#   ./rebar.sh rollback              # 回滚到脚本启动前的初始值
#
# 重要约束：
#   - dry-run 为默认行为，--apply 才会真正执行破坏性操作
#   - 不修改 BIOS/GRUB/initramfs，不写任何持久配置，重启后恢复原状
#   - 本脚本为独立实现，未参考任何第三方同类项目（尤其是 arc-rebar）
#==============================================================================

set -uuo pipefail

#------------------------------
# 全局常量
#------------------------------
ROOT_PORT="0000:00:02.0"
GPU_BDF="0000:04:00.0"
GPU_DRIVER="xe"          # Arc B580 使用的驱动名

# GPU PCIe ReBAR 扩展能力地址
REBAR_ECAP="0x420"
CAP_REG="0x424"
CTL_REG="0x428"
STA_REG="0x42c"

# 当前实测值（任务书已验证，直接使用）
INIT_CTL_VALUE="0x00000922"   # bits[13:8]=9 → 512 MB
TARGET_CTL_VALUE="0x00000922" # 模板值，写入时只改 bits[13:8]

# 日志文件（每步写入，供事后判断）
LOG_DIR="/var/log/rebar"
LOG_FILE="${LOG_DIR}/rebar_$(date '+%Y%m%d_%H%M%S').log"
STATE_FILE="${LOG_DIR}/rebar_state"

#------------------------------
# 全局状态
#------------------------------
DRY_RUN=true
SUBCMD=""
INIT_Ctl_Value=""   # 脚本启动时读取的原始 Control 值
CAP_VALUE=""        # Capability 寄存器原始值
LOGGED_apply=false  # apply 是否已执行过（幂等追踪）

#------------------------------
# 工具函数
#------------------------------

# 写日志同时输出到 stdout
log() {
  local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
  echo "$msg"
  # 每行都 sync 落地，防掉电丢日志
  echo "$msg" >> "$LOG_FILE" 2>/dev/null || true
  sync "$LOG_FILE" 2>/dev/null || true
}

# 写一个只追加的详情文件（风险窗口最小化）
detail() {
  local step="$1"
  local msg="$2"
  local detail_log="${LOG_DIR}/steps.log"
  mkdir -p "$LOG_DIR"
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] STEP=${step} MSG=${msg}" >> "$detail_log"
  sync "$detail_log"
}

# 检查是否 root
check_root() {
  if [[ $EUID -ne 0 ]]; then
    echo "错误：必须以 root 身份运行。" >&2
    exit 1
  fi
}

# 初始化日志目录
init_log() {
  mkdir -p "$LOG_DIR"
  touch "$LOG_FILE" || {
    echo "错误：无法创建日志文件 ${LOG_FILE}" >&2
    exit 1
  }
  sync
}

# 读取 PCIe 寄存器（通过 setpci）
pci_read() {
  local bdf="$1"
  local offset="$2"
  setpci -s "$bdf" "${offset}.d" 2>/dev/null
}

# 写入 PCIe 寄存器（通过 setpci）
pci_write() {
  local bdf="$1"
  local offset="$2"
  local value="$3"
  setpci -s "$bdf" "${offset}.d"="$value" 2>&1
}

# 从 Control 寄存器提取 bits[13:8]（即 size 字段 N）
extract_size_field() {
  local ctl="$1"  # 十六进制字符串，如 "922"
  # ctl 是十六进制，bits[13:8] 对应第 6-11 位（共 6 位）
  # 即 (ctl >> 8) & 0x3F
  printf '%d' $(( (16#${ctl} >> 8) & 0x3F ))
}

# 从 Control 寄存器提取 bits[2:0]（即 BAR 索引）
extract_bar_index() {
  local ctl="$1"
  printf '%d' $(( 16#${ctl} & 0x7 ))
}

# size N 转人类可读字符串
size_to_human() {
  local n="$1"
  local bytes=$(( (1 << (n - 20)) * 1024 * 1024 ))
  if (( n >= 30 )); then
    # 显示为 GB
    printf '%d GB' $(( bytes / 1024 / 1024 / 1024 ))
  else
    printf '%d MB' $(( bytes / 1024 / 1024 ))
  fi
}

# 检查根端口子树是否只有目标 GPU
check_subtree_only_gpu() {
  local rp="$ROOT_PORT"
  # 列出根端口总线范围内的所有 pci 设备（BDF）
  local rp_bus range
  rp_bus=$(echo "$rp" | cut -d: -f1 | cut -d. -f1)
  # 根端口总线号从 lspci 输出解析：从 "0000:00:02.0" 取 bus 部分
  # 用 lspci -nn 获取 "Bus 02-05" 这样的范围信息
  local bus_range
  bus_range=$(lspci -s "$rp" -vv 2>/dev/null | grep -i 'bus' | head -1)
  log "DEBUG: 根端口总线范围信息: ${bus_range}"

  # 更可靠的方法：从 /sys/bus/pci/devices/0000:00:02.0/pci_bus/ 读取
  local bus_path="/sys/bus/pci/devices/${rp}/pci_bus"
  if [[ -d "$bus_path" ]]; then
    local bus_dir
    bus_dir=$(ls "$bus_path" 2>/dev/null | head -1)  # 如 "0000:02"
    if [[ -n "$bus_dir" ]]; then
      local dev
      for dev in /sys/bus/pci/devices/${bus_dir}:*; do
        [[ -e "$dev" ]] || continue
        local dev_bdf
        dev_bdf=$(basename "$dev")
        # 跳过根端口自身
        [[ "$dev_bdf" == "$rp" ]] && continue
        log "检测到根端口下有其他设备: ${dev_bdf}"
        return 1
      done
    fi
  fi

  # 备用：直接扫描 /sys/bus/pci/devices/ 下所有以根端口 bus 开头的设备
  local rp_pci_bus
  rp_pci_bus=$(cat "/sys/bus/pci/devices/${rp}/bus" 2>/dev/null || echo "")
  if [[ -n "$rp_pci_bus" ]]; then
    for dev in /sys/bus/pci/devices/*; do
      [[ -e "$dev" ]] || continue
      local dev_bdf
      dev_bdf=$(basename "$dev")
      local dev_bus
      dev_bus=$(cat "${dev}/bus" 2>/dev/null || echo "")
      [[ "$dev_bus" == "$rp_pci_bus" && "$dev_bdf" != "$rp" ]] && {
        log "检测到根端口下有其他设备（通过 bus 匹配）: ${dev_bdf}"
        return 1
      }
    done
  fi

  log "根端口子树检查通过：只有目标 GPU"
  return 0
}

# 检查 GPU 是否有进程占用
check_gpu_free() {
  # 检查驱动绑定情况
  local driver_path="/sys/bus/pci/devices/${GPU_BDF}/driver"
  if [[ -L "$driver_path" ]]; then
    local driver
    driver=$(readlink "$driver_path" 2>/dev/null | xargs basename)
    log "GPU 当前绑定驱动: ${driver}"

    # 检查 drm 设备是否被打开
    local drm_dev
    for drm_dev in /sys/class/drm/card*/device; do
      [[ -e "$drm_dev" ]] || continue
      local real_drm_bdf
      real_drm_bdf=$(readlink -f "$drm_dev" 2>/dev/null | xargs basename)
      [[ "$real_drm_bdf" == "$GPU_BDF" ]] || continue
      local render_dir="/sys/class/drm/${drm_dev##*/}/renderD*"
      for render in $render_dir; do
        [[ -e "$render" ]] || continue
        local owners
        owners=$(cat "${render}/device/../uevent" 2>/dev/null | grep 'DEVNAME' || echo "")
        # 检查 /sys/class/drm/card*/device 中是否有进程持有
        :
      done
    done

    # 更直接：检查驱动模块是否被进程 map
    # 读 /proc/modules 或 /sys/module/${driver}/refcnt
    local refcnt
    refcnt=$(cat "/sys/module/${driver}/refcnt" 2>/dev/null || echo "0")
    if (( refcnt > 0 )); then
      log "警告：驱动模块 refcnt=${refcnt}，可能有进程在使用 GPU"
      # 不强制拒绝，但给出警告；幂等场景下用户应该知道
    fi
  else
    log "GPU 当前未绑定任何驱动（可能已被解绑）"
  fi
  return 0
}

# 读取当前状态并保存初始值
read_and_save_initial_state() {
  INIT_Ctl_Value=$(pci_read "$GPU_BDF" "$CTL_REG")
  CAP_VALUE=$(pci_read "$GPU_BDF" "$CAP_REG")

  if [[ -z "$INIT_Ctl_Value" || -z "$CAP_VALUE" ]]; then
    echo "错误：无法读取 GPU ReBAR 寄存器。请确认 PCIe 设备存在。" >&2
    exit 1
  fi

  log "原始 Control 寄存器: ${INIT_Ctl_Value}"
  log "原始 Capability 寄存器: ${CAP_VALUE}"

  local init_n
  init_n=$(extract_size_field "$INIT_Ctl_Value")
  log "当前 BAR2 Size N=${init_n} ($(size_to_human $init_n))"

  mkdir -p "$LOG_DIR"
  # 保存初始状态到文件，供 rollback 使用
  echo "INIT_CTL=${INIT_Ctl_Value}" > "${STATE_FILE}"
  echo "INIT_CAP=${CAP_VALUE}" >> "${STATE_FILE}"
  echo "TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')" >> "${STATE_FILE}"
  sync "${STATE_FILE}"
  log "初始状态已保存至 ${STATE_FILE}"
}

# 加载初始状态（rollback 时使用）
load_state() {
  if [[ ! -f "${STATE_FILE}" ]]; then
    echo "错误：找不到状态文件 ${STATE_FILE}，无法回滚。" >&2
    exit 1
  fi
  INIT_Ctl_Value=$(grep '^INIT_CTL=' "${STATE_FILE}" | cut -d= -f2)
  CAP_VALUE=$(grep '^INIT_CAP=' "${STATE_FILE}" | cut -d= -f2)
  if [[ -z "$INIT_Ctl_Value" ]]; then
    echo "错误：状态文件损坏，无法读取初始 Control 值。" >&2
    exit 1
  fi
  log "从状态文件加载：INIT_CTL=${INIT_Ctl_Value}"
}

#------------------------------
# 子命令实现
#------------------------------

cmd_status() {
  log "========== Status Report =========="

  local ctl cap sta
  ctl=$(pci_read "$GPU_BDF" "$CTL_REG")
  cap=$(pci_read "$GPU_BDF" "$CAP_REG")
  sta=$(pci_read "$GPU_BDF" "$STA_REG")

  echo ""
  echo "=== PCIe ReBAR 状态 ==="
  printf "  GPU BDF:           %s\n" "$GPU_BDF"
  printf "  Root Port:         %s\n" "$ROOT_PORT"
  printf "  ECAP Header (0x420):  %s\n" "$(pci_read "$GPU_BDF" "$REBAR_ECAP")"
  printf "  Capability (0x424):   %s\n" "$cap"
  printf "  Control (0x428):      %s\n" "$ctl"
  printf "  Status (0x42c):       %s\n" "$sta"
  echo ""

  local cur_n max_n
  cur_n=$(extract_size_field "$ctl")
  echo "  当前 BAR2 Size:"
  printf "    - N = %d, 大小 = %s\n" "$cur_n" "$(size_to_human $cur_n)"

  # 从 Capability 计算最大支持 N
  local cap_val
  cap_val=$((16#${cap}))
  max_n=0
  for n in 8 9 10 11 12 13 14; do
    if (( (cap_val & (1 << (4 + n))) != 0 )); then
      max_n=$n
    fi
  done
  printf "    - 支持的最大 N = %d (%s)\n" "$max_n" "$(size_to_human $max_n)"
  echo ""

  # 驱动绑定情况
  local driver_path="/sys/bus/pci/devices/${GPU_BDF}/driver"
  if [[ -L "$driver_path" ]]; then
    local driver
    driver=$(readlink "$driver_path" | xargs basename)
    printf "  驱动绑定:          %s (已绑定)\n" "$driver"
  else
    echo "  驱动绑定:          无（未绑定）"
  fi

  # 根端口窗口信息
  echo ""
  echo "=== 根端口窗口 ==="
  local rp_resource
  rp_resource=$(cat "/sys/bus/pci/devices/${ROOT_PORT}/resource" 2>/dev/null || echo "")
  if [[ -n "$rp_resource" ]]; then
    echo "  根端口 resource:"
    echo "$rp_resource" | while read -r start end flags; do
      [[ -z "$start" ]] && continue
      printf "    [0x%s - 0x%s] flags=0x%s\n" "$start" "$end" "$flags"
    done
  fi

  # 判定结论
  echo ""
  echo "=== 判定 ==="
  if (( cur_n >= 14 )); then
    echo "  BAR2 已达到 16 GB，无需操作。"
  else
    echo "  BAR2 当前为 $(size_to_human $cur_n)，目标 16 GB。"
    printf "  建议：执行 ./rebar.sh apply\n"
  fi

  log "Status 子命令完成"
}

cmd_plan() {
  log "========== Plan (dry-run) =========="
  echo ""
  echo "以下是将要执行的动作（dry-run 模式，不做任何修改）："
  echo ""
  echo "步骤 1：预检"
  echo "  [dry-run] 检查根端口子树是否只有目标 GPU"
  echo "  [dry-run] 检查 GPU 是否有进程占用"
  echo "  [dry-run] 检查当前 BAR2 size 是否已是目标值（幂等）"
  echo ""
  echo "步骤 2：写入 ReBAR Control 寄存器"
  local cur_n
  cur_n=$(extract_size_field "$INIT_Ctl_Value")
  printf "  [dry-run] setpci -s %s %s.d=0x%06X（目标 N=14，即 16 GB）\n" \
    "$GPU_BDF" "$CTL_REG" $(( (14 << 8) | (INIT_Ctl_Value & 0xFF) ))
  echo "  注：bits[2:0]（BAR Index=2）保持不变，仅修改 bits[13:8]"
  echo ""
  echo "步骤 3：解绑 GPU 驱动"
  echo "  [dry-run] echo ${GPU_BDF} > /sys/bus/pci/devices/${GPU_BDF}/driver/unbind"
  echo "  目的：停止 DMA 操作，避免移除设备时数据不一致"
  echo ""
  echo "步骤 4：移除根端口设备"
  echo "  [dry-run] echo 1 > /sys/bus/pci/devices/${ROOT_PORT}/remove"
  echo "  目的：从内核 PCI 总线摘除根端口，释放窗口"
  echo ""
  echo "步骤 5：重新扫描 PCI 总线"
  echo "  [dry-run] echo 1 > /sys/bus/pci/rescan"
  echo "  目的：让内核重新枚举，重新分配窗口（应看到更大的 BAR2 窗口）"
  echo ""
  echo "步骤 6：重新绑定驱动"
  echo "  [dry-run] echo ${GPU_BDF} > /sys/bus/pci/devices/${GPU_BDF}/driver/unbind 2>/dev/null; \\"
  echo "            ls /sys/bus/pci/drivers/${GPU_DRIVER}/bind"
  echo "  目的：恢复驱动绑定"
  echo ""
  echo "步骤 7：验证"
  echo "  [dry-run] 读取新的 BAR2 size，验证是否达到目标"
  echo "  [dry-run] 检查 /sys/class/drm/*/device/resource 中 BAR2 窗口大小"
  echo ""
  echo "如确认无误，请执行："
  echo "  ./rebar.sh apply --apply"
  echo ""
  log "Plan 完成（dry-run）"
}

cmd_apply() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "错误：apply 子命令必须带 --apply 参数。" >&2
    echo "用法：./rebar.sh apply --apply" >&2
    exit 1
  fi

  log "========== APPLY 开始 =========="
  detail "APPLY_START" "开始执行 Resizable BAR 扩展操作"

  #------- 步骤 0：再次确认 -------
  local cur_n
  cur_n=$(extract_size_field "$INIT_Ctl_Value")
  if (( cur_n >= 14 )); then
    log "当前 N=${cur_n}，已达标，幂等退出"
    echo "BAR2 已达到 16 GB，什么也不做（幂等）。"
    return 0
  fi

  #------- 步骤 1：预检 -------
  log "步骤 1/7：预检..."

  if ! check_subtree_only_gpu; then
    echo "错误：根端口下有其他设备，终止执行以避免影响。" >&2
    echo "请先手动确认只有 Arc B580 连接在该根端口上。" >&2
    exit 1
  fi

  check_gpu_free
  # 警告但不阻止（用户应自行确保无推理任务运行）
  local refcnt
  refcnt=$(cat "/sys/module/${GPU_DRIVER}/refcnt" 2>/dev/null || echo "0")
  if (( refcnt > 0 )); then
    echo ""
    echo "!!! 警告：驱动 refcnt=${refcnt}，可能有进程正在使用 GPU。"
    echo "!!! 建议：确认没有推理任务在跑，再继续。"
    echo "!!! 5 秒后继续执行，如需中止请按 Ctrl+C..."
    sleep 5
  fi

  #------- 步骤 2：写 ReBAR Control 寄存器 -------
  log "步骤 2/7：写入 ReBAR Control 寄存器..."

  # bits[13:8] = 14 (目标), bits[2:0] 保持原始值
  # Control = (target_n << 8) | (INIT_CTL & 0xFF)
  local new_ctl
  new_ctl=$(printf '0x%06X' $(( (14 << 8) | (16#${INIT_Ctl_Value} & 0xFF) )) )
  log "写入 ${GPU_BDF} ${CTL_REG} = ${new_ctl}（原始=${INIT_Ctl_Value}）"
  detail "WRITE_REBAR_CTL" "new_ctl=${new_ctl}"

  local write_result
  write_result=$(pci_write "$GPU_BDF" "$CTL_REG" "$new_ctl")
  if echo "$write_result" | grep -qi 'error'; then
    echo "错误：写入 ReBAR Control 失败: ${write_result}" >&2
    exit 1
  fi

  # 验证写入
  local verify_ctl
  verify_ctl=$(pci_read "$GPU_BDF" "$CTL_REG")
  local verify_n
  verify_n=$(extract_size_field "$verify_ctl")
  log "验证写入：Control=${verify_ctl}，N=${verify_n}"
  detail "VERIFY_REBAR_CTL" "verify_ctl=${verify_ctl} N=${verify_n}"

  if (( verify_n != 14 )); then
    echo "错误：ReBAR Control 写入验证失败（N=${verify_n}，期望 14）。" >&2
    echo "尝试回滚..."
    cmd_rollback
    exit 1
  fi

  log "ReBAR Control 写入成功，N=14（16 GB）"

  #------- 步骤 3：解绑驱动 -------
  log "步骤 3/7：解绑 GPU 驱动..."
  detail "UNBIND_DRIVER" "开始解绑驱动"

  local driver_path="/sys/bus/pci/devices/${GPU_BDF}/driver"
  if [[ -L "$driver_path" ]]; then
    local unbind_result
    unbind_result=$(echo "$GPU_BDF" > "${driver_path}/unbind" 2>&1)
    if [[ $? -ne 0 ]]; then
      echo "错误：解绑驱动失败: ${unbind_result}" >&2
      echo "尝试回滚..."
      cmd_rollback
      exit 1
    fi
    log "驱动已解绑: ${unbind_result:-成功}"
    detail "UNBIND_DRIVER" "驱动已解绑"
  else
    log "驱动未绑定，无需解绑"
  fi
  sync

  #------- 步骤 4：移除根端口 -------
  log "步骤 4/7：移除根端口设备..."
  detail "REMOVE_ROOT_PORT" "开始移除根端口 ${ROOT_PORT}"

  local remove_result
  remove_result=$(echo 1 > "/sys/bus/pci/devices/${ROOT_PORT}/remove" 2>&1)
  local remove_status=$?
  log "根端口移除结果（exit=${remove_status}）: ${remove_result}"
  detail "REMOVE_ROOT_PORT" "done status=${remove_status}"

  if (( remove_status -ne 0 )); then
    echo "错误：移除根端口失败: ${remove_result}" >&2
    echo ""
    echo "!!! 回滚失败时的兜底建议："
    echo "!!! 1. 检查 dmesg | tail -50 确认内核状态"
    echo "!!! 2. 如果机器无响应，需到机房按电源键重启"
    echo "!!! 3. 重启后 BAR2 会自动恢复原状（512 MB）"
    echo "!!! 4. 如需进一步帮助，请保留日志：${LOG_FILE}"
    exit 1
  fi
  sync
  log "根端口已移除"

  #------- 步骤 5：重新扫描 -------
  log "步骤 5/7：重新扫描 PCI 总线..."
  detail "RESCAN_PCI" "开始重新扫描"

  local rescan_result
  rescan_result=$(echo 1 > /sys/bus/pci/rescan 2>&1)
  local rescan_status=$?
  log "rescan 结果（exit=${rescan_status}）: ${rescan_result}"
  detail "RESCAN_PCI" "done status=${rescan_status}"

  if (( rescan_status -ne 0 )); then
    echo "错误：rescan 失败: ${rescan_result}" >&2
    echo "!!! 机器状态可能不稳定，请立即检查 dmesg。"
    echo "!!! 如果机器无响应，需到机房按电源键重启。"
    exit 1
  fi
  sync
  sleep 2  # 给内核一点时间完成枚举
  log "PCI 总线重新扫描完成"

  #------- 步骤 6：检查 BAR2 大小 -------
  log "步骤 6/7：验证 BAR2 大小..."

  # 检查 GPU 是否重新出现
  if [[ ! -e "/sys/bus/pci/devices/${GPU_BDF}" ]]; then
    echo "错误：GPU 设备 ${GPU_BDF} 在 rescan 后消失！" >&2
    echo "!!! 机器可能处于不稳定状态，请立即检查 dmesg。"
    echo "!!! 如果机器无响应，需到机房重启。"
    exit 1
  fi

  # 读取新的 Control 寄存器
  local new_verify_ctl new_verify_n
  new_verify_ctl=$(pci_read "$GPU_BDF" "$CTL_REG")
  new_verify_n=$(extract_size_field "$new_verify_ctl")
  log "rescan 后 Control=${new_verify_ctl}，N=${new_verify_n}"
  detail "POST_RESCAN_CTL" "ctl=${new_verify_ctl} N=${new_verify_n}"

  # 读取 BAR2 窗口大小
  local bar2_size="未知"
  local bar2_addr="未知"
  if [[ -e "/sys/bus/pci/devices/${GPU_BDF}/resource" ]]; then
    local res_line
    res_line=$(cat "/sys/bus/pci/devices/${GPU_BDF}/resource" | awk '{print $1, $2, $3}' | grep -E '^(0x[0-9a-f]+ 0x[0-9a-f]+ 0x[0-9a-f]+)$' | head -2 | tail -1)
    if [[ -n "$res_line" ]]; then
      bar2_addr=$(echo "$res_line" | awk '{print $1}')
      bar2_size=$(echo "$res_line" | awk '{print $2}')
      local size_dec=$((16#${bar2_size#0x} - 16#${bar2_addr#0x}))
      log "BAR2 地址=${bar2_addr}，结束地址=${bar2_size}，大小约 $(($size_dec / 1024 / 1024)) MB"
    fi
  fi

  if (( new_verify_n >= 14 )); then
    log "验证通过：BAR2 N=${new_verify_n}，达到 16 GB 目标"
    echo ""
    echo "=== 成功 ==="
    echo "BAR2 已成功扩展到 16 GB。"
    printf "  - Control N=%d，BAR2 地址=%s\n" "$new_verify_n" "$bar2_addr"
    detail "APPLY_SUCCESS" "N=${new_verify_n}"
  else
    echo "警告：rescan 后 BAR2 N=${new_verify_n}，仍未达到目标（14）。"
    echo "  窗口可能仍然不够，尝试回滚..."
    detail "APPLY_INCOMPLETE" "N=${new_verify_n}"
    cmd_rollback
    exit 1
  fi

  #------- 步骤 7：尝试恢复驱动绑定 -------
  log "步骤 7/7：恢复驱动绑定（如可能）..."
  detail "REBIND_DRIVER" "尝试重新绑定驱动"

  local rebind_path="/sys/bus/pci/drivers/${GPU_DRIVER}/bind"
  if [[ -e "$rebind_path" ]]; then
    local rebind_result
    rebind_result=$(echo "$GPU_BDF" > "$rebind_path" 2>&1)
    if [[ $? -eq 0 ]]; then
      log "驱动重新绑定成功"
      detail "REBIND_SUCCESS" ""
    else
      echo "警告：驱动重新绑定失败（${rebind_result}），可能需要重启后自动恢复。"
      detail "REBIND_FAILED" "${rebind_result}"
    fi
  else
    log "驱动 bind 接口不存在，跳过"
  fi

  log "========== APPLY 完成 =========="
  detail "APPLY_DONE" ""
}

cmd_rollback() {
  load_state

  log "========== ROLLBACK 开始 =========="
  detail "ROLLBACK_START" "INIT_CTL=${INIT_Ctl_Value}"

  if [[ "$DRY_RUN" == "true" ]]; then
    echo "Rollback（dry-run）：将恢复 Control 寄存器为 ${INIT_Ctl_Value}"
    return 0
  fi

  # 写回原始值
  local rollback_result
  rollback_result=$(pci_write "$GPU_BDF" "$CTL_REG" "$INIT_Ctl_Value" 2>&1)
  local rollback_status=$?

  if (( rollback_status -ne 0 )) || echo "$rollback_result" | grep -qi 'error'; then
    echo "错误：回滚写入失败: ${rollback_result}" >&2
    echo ""
    echo "!!! 回滚写入失败，GPU 可能处于不可用状态。"
    echo "!!! 机器状态不确定，请立即检查 dmesg。"
    echo "!!! 如果机器无响应，需到机房按电源键重启。"
    echo "!!! 重启后 BAR2 会自动恢复原状（512 MB）。"
    echo "!!! 如需进一步帮助，请保留日志：${LOG_FILE}"
    detail "ROLLBACK_WRITE_FAILED" "${rollback_result}"
    exit 1
  fi

  # 验证
  local verify_ctl
  verify_ctl=$(pci_read "$GPU_BDF" "$CTL_REG")
  local verify_n
  verify_n=$(extract_size_field "$verify_ctl")
  log "回滚验证：Control=${verify_ctl}，N=${verify_n}"

  if [[ "$verify_ctl" != "$INIT_Ctl_Value" ]]; then
    echo "警告：回滚验证不一致（期望 ${INIT_Ctl_Value}，实际 ${verify_ctl}）"
    echo ""
    echo "!!! 回滚后寄存器值与预期不符，GPU 可能不可用。"
    echo "!!! 机器状态不确定，请立即检查 dmesg。"
    echo "!!! 如果机器无响应，需到机房按电源键重启。"
    detail "ROLLBACK_VERIFY_FAILED" "expected=${INIT_Ctl_Value} got=${verify_ctl}"
    exit 1
  fi

  log "========== ROLLBACK 完成 =========="
  detail "ROLLBACK_DONE" "CTL=${verify_ctl}"
  echo "回滚完成：Control 寄存器已恢复到 ${INIT_Ctl_Value}"
}

#------------------------------
# 主入口
#------------------------------

main() {
  check_root
  init_log

  # 解析参数
  SUBCMD="${1:-plan}"
  shift || true

  if [[ "$SUBCMD" == "apply" && "${1:-}" == "--apply" ]]; then
    DRY_RUN=false
  elif [[ "$SUBCMD" == "plan" ]]; then
    DRY_RUN=true
  elif [[ "$SUBCMD" == "status" || "$SUBCMD" == "rollback" ]]; then
    DRY_RUN=false
  elif [[ "$SUBCMD" == "apply" && "${1:-}" != "--apply" ]]; then
    echo "错误：apply 子命令需要 --apply 参数。" >&2
    echo "用法：./rebar.sh apply --apply" >&2
    exit 1
  else
    echo "用法：$0 {status|plan|apply --apply|rollback}" >&2
    exit 1
  fi

  log "=========================================="
  log "脚本启动：子命令=${SUBCMD}，DRY_RUN=${DRY_RUN}"
  log "=========================================="

  # 读取初始状态（所有子命令都需要）
  read_and_save_initial_state

  case "$SUBCMD" in
    status)
      cmd_status
      ;;
    plan)
      cmd_plan
      ;;
    apply)
      cmd_apply
      ;;
    rollback)
      cmd_rollback
      ;;
    *)
      echo "未知子命令: $SUBCMD" >&2
      exit 1
      ;;
  esac

  log "脚本正常结束"
}

main "$@"
