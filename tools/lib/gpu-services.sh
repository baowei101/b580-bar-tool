#!/bin/bash
# =============================================================================
# lib/gpu-services.sh —— "谁占着 GPU" 反查层（只读，本文件不做停止/启动动作）
#
# 为什么不用服务名清单
# --------------------
# 作者机器上占 GPU 的是 9 个推理服务（ollama / paddlex / llama-* / tei-* …），写成
# 清单对别人的机器毫无意义：换台机器一个都匹配不上，`systemctl stop` 静默失败，
# 回读 is-active 是空串，打印出来像"这些服务本来就没在跑"。
# systemd 里也没有"我依赖 GPU"这种可查声明（.service 文件不写这层信息），
# 所以按名字列举从来不是通用解，只是当年唯一的办法。
#
# 正确做法：设备 → 进程 → cgroup → unit
#   fuser /dev/dri/renderD*  → 占用 PID
#   /proc/<pid>/cgroup       → 0::/system.slice/paddlex-8095.service
#                              0::/user.slice/user-1000.slice/user@1000.service/app.slice/llama-rerank.service
#   basename                 → unit 名（.scope / .slice 不是 service，说明是登录会话
#                              或手工拉起的进程，只能报给人处理）
#
# 顺手的好处：以后新加一个推理服务，反查自动覆盖；写死清单会漏掉它，而漏掉的后果
# 是 apply 前的占用检查拦不住（或更糟，拦住了却不知道该停谁）。
#
# 本层只回答"谁占着"。用什么身份去停（sudo / runuser）由调用方决定 —— 同一台机器
# 上 system 级与 user 级 unit 需要不同的 systemctl 上下文。
# =============================================================================

# 记录"我停过哪些 unit"，供 start 侧原样恢复。放 /run：重启即清空，正合适 ——
# 重启后服务本来就该按 enable 状态自启，不需要这份记录。
GS_RECORD="${GS_RECORD:-/run/b580-bar-tool/stopped-units}"

gs_render_nodes() {
    ls /dev/dri/renderD* 2>/dev/null
}

# 占用 GPU 设备节点的进程 PID（去重）。没有 fuser 时返回 1，调用方据此降级。
gs_holder_pids() {
    command -v fuser >/dev/null 2>&1 || return 1
    local r
    for r in $(gs_render_nodes); do
        fuser "$r" 2>/dev/null
    done | tr -s ' ' '\n' | grep -E '^[0-9]+$' | sort -un
}

# PID → unit 名；不是 .service 则返回 1（该进程不归 systemd 的服务管）
gs_unit_of_pid() {
    local pid="$1" cg
    [ -r "/proc/$pid/cgroup" ] || return 1
    cg="$(sed -n '1p' "/proc/$pid/cgroup" 2>/dev/null)"
    [ -n "$cg" ] || return 1
    cg="${cg#*:*:}"                     # 去掉 "0::" 这一层前缀
    case "$cg" in
        *.service) printf '%s' "${cg##*/}" ;;
        *) return 1 ;;
    esac
}

# PID 属于 system 还是 user scope
gs_scope_of_pid() {
    local cg
    cg="$(sed -n '1p' "/proc/$1/cgroup" 2>/dev/null)"
    case "$cg" in
        *user@*|*/user.slice/*) printf 'user' ;;
        *) printf 'system' ;;
    esac
}

# 当前占用 GPU 的清单，每行 "scope unit" 或 "raw <pid>"（raw = 不归任何 service）。
# 调用方一般再 `sort -u`。无占用时无输出。
gs_snapshot() {
    local pid unit scope
    while read -r pid; do
        [ -n "$pid" ] || continue
        if unit="$(gs_unit_of_pid "$pid")"; then
            printf '%s %s\n' "$(gs_scope_of_pid "$pid")" "$unit"
        else
            printf 'raw %s\n' "$pid"
        fi
    done <<< "$(gs_holder_pids 2>/dev/null)"
}

# 从快照里按 scope 取 unit 名（去重、保持首次出现顺序）
gs_units_of_scope() {
    local want="$1" scope unit
    while read -r scope unit; do
        [ "$scope" = "$want" ] && printf '%s\n' "$unit"
    done <<< "$2" | awk '!seen[$0]++'
}

# 快照里的 raw PID（不归任何 service 的占用者）
gs_raw_pids() {
    local scope pid
    while read -r scope pid; do
        [ "$scope" = "raw" ] && printf '%s\n' "$pid"
    done <<< "$1"
}

# 把 "scope unit" 行追加进记录文件（与已有记录合并去重）。
# 只记"停之前确实 active"的 unit —— 否则 start 会把本来不该起的服务拉起来。
gs_record_add() {
    local incoming="$1" merged
    mkdir -p "$(dirname "$GS_RECORD")" 2>/dev/null || true
    merged="$( { gs_record_load; printf '%s\n' "$incoming"; } 2>/dev/null \
               | grep -E '^(system|user) ' | sort -u )"
    printf '%s\n' "$merged" > "$GS_RECORD" 2>/dev/null \
        || { echo "WARN 无法写入记录 $GS_RECORD，start 侧将无据可依" >&2; return 1; }
}

gs_record_load() {
    [ -r "$GS_RECORD" ] && sed -n 's/^\(system\|user\) /\1 /p' "$GS_RECORD"
}

gs_record_clear() {
    rm -f "$GS_RECORD" 2>/dev/null || true
}
