#!/bin/bash
# 把 stop-gpu.sh 停掉的服务按原样拉回来，并复查设备与 BAR2 状态。
# 用法: sudo -v && ./start-gpu.sh                   # 推荐：先缓存凭据，脚本仍以本人身份跑
#       GPU_USER=<用户名> sudo -E ./start-gpu.sh     # 以 root 跑时必须给出用户级服务归属
#
# 不收密码参数：命令行会留在 ps / history / journal 里，等于泄露 root 凭据。
#
# 恢复哪些服务不靠名单，靠 stop-gpu.sh 写下的记录（/run/b580-bar-tool/stopped-units）。
# 记录不在（机器重启过、或压根没跑过 stop）时不猜 —— 重启后服务本就按 enable 状态自启，
# 猜错反而会把本来该停的服务拉起来。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/gpu-services.sh
. "$HERE/lib/gpu-services.sh" || { echo "缺少 lib/gpu-services.sh（与本脚本同目录的 lib/）" >&2; exit 1; }

SUDO_CMD=()
if [ "$(id -u)" -ne 0 ]; then
    if ! sudo -n true 2>/dev/null; then
        if [ -t 0 ]; then
            echo "需要 sudo 权限，请输入一次密码（缓存 5 分钟）：" >&2
            sudo -v || { echo "获取 sudo 权限失败" >&2; exit 1; }
        else
            echo "需要 sudo 权限：请先运行 'sudo -v' 再执行本脚本" >&2
            exit 1
        fi
    fi
    SUDO_CMD=(sudo -n)
fi

run_sudo() {
    if [ "${#SUDO_CMD[@]}" -gt 0 ]; then "${SUDO_CMD[@]}" "$@"; else "$@"; fi
}

# 同 stop-gpu.sh：root 直接跑时 `systemctl --user` 连不上总线，且错误被 2>/dev/null
# 吞掉，表现为"启动失败但一个字不说"。切到真人用户的 user manager 才有效。
USER_SESSION_USER="${GPU_USER:-${SUDO_USER:-}}"
if [ -z "$USER_SESSION_USER" ] && [ "$(id -u)" -eq 0 ]; then
    echo "WARN 以 root 直接运行且未提供 SUDO_USER/GPU_USER：用户级服务将无法操作" >&2
    echo "WARN 正确用法：sudo -v && ./start-gpu.sh   或   GPU_USER=<用户名> sudo -E ./start-gpu.sh" >&2
fi
userctl() {
    if [ -n "$USER_SESSION_USER" ]; then
        runuser -u "$USER_SESSION_USER" -- \
            env XDG_RUNTIME_DIR="/run/user/$(id -u "$USER_SESSION_USER")" \
            systemctl --user "$@"
    else
        systemctl --user "$@"
    fi
}

# ------------------------------------------------------------- 按记录恢复 ----

REC="$(gs_record_load)"
START_SYS="$(gs_units_of_scope system "$REC")"
START_USER="$(gs_units_of_scope user "$REC")"

echo "===== A. 按 stop 记录恢复（$GS_RECORD）====="
if [ -z "${REC// /}" ]; then
    echo "  没有记录可恢复。"
    echo "  说明：记录只在 stop-gpu.sh 成功停过服务后生成，放在 /run 下，重启即清空。"
    echo "  如果你的服务本来就该自启，重启后不用跑这个脚本；要手工确认见下面 C/D 段。"
else
    if [ -n "${START_SYS// /}" ]; then
        printf '  system: %s\n' "$(printf '%s' "$START_SYS" | tr '\n' ' ')"
        run_sudo systemctl start $START_SYS 2>/dev/null
    fi
    if [ -n "${START_USER// /}" ]; then
        printf '  user:   %s\n' "$(printf '%s' "$START_USER" | tr '\n' ' ')"
        userctl start $START_USER 2>/dev/null
    fi
fi

# ------------------------------------------------------------------ 复查 ----

echo
echo "===== B. 复查 ====="
bad=0; checked=0
for u in $START_SYS; do
    checked=$((checked + 1))
    st="$(run_sudo systemctl is-active "$u" 2>/dev/null)"
    printf '  %-40s %s\n' "$u" "${st:-unknown}"
    [ "$st" = "active" ] || bad=$((bad + 1))
done
for u in $START_USER; do
    checked=$((checked + 1))
    st="$(userctl is-active "$u" 2>/dev/null)"
    printf '  %-40s %s\n' "$u" "${st:-unknown}"
    [ "$st" = "active" ] || bad=$((bad + 1))
done
[ "$checked" -eq 0 ] && echo "  （无可复查对象）"

# 只有全部起来了才清记录；否则留着，修好问题可以再跑一次。
if [ "$checked" -gt 0 ] && [ "$bad" -eq 0 ]; then
    gs_record_clear
    echo "  全部 active，记录已清除"
elif [ "$bad" -gt 0 ]; then
    echo "  WARN $bad 个未 active —— 记录保留，处理后重跑本脚本" >&2
fi

echo
echo "===== C. GPU 设备占用 ====="
SNAP="$(gs_snapshot | sort -u)"
if [ -z "${SNAP// /}" ]; then
    echo "  无进程占用渲染节点（空闲状态）"
else
    printf '%s\n' "$SNAP" | while read -r scope id; do
        case "$scope" in
            system|user) printf '  [%s] %s\n' "$scope" "$id" ;;
            raw)         printf '  [手工] PID %s\n' "$id" ;;
        esac
    done
fi
echo "  渲染节点：$(gs_render_nodes | tr '\n' ' ')"

echo
echo "===== D. BAR2 现状 ====="
TOPO_SH="$HERE/gpu-topology.sh"
[ -x "$TOPO_SH" ] || TOPO_SH="/opt/b580-bar-tool/gpu-topology.sh"
if [ -x "$TOPO_SH" ]; then
    run_sudo bash "$TOPO_SH" --plan
else
    echo "  （未找到 gpu-topology.sh，跳过）"
fi

echo "DONE"
[ "$bad" -eq 0 ] || exit 1
