#!/bin/bash
# 停掉所有正在占用 GPU 的服务，为 ReBAR 扩容腾出干净的设备状态。
# 用法: sudo -v && ./stop-gpu.sh                    # 推荐：先缓存凭据，脚本仍以本人身份跑
#       sudo -v && ./stop-gpu.sh --dry-run           # 只看会停哪些 unit，不动任何服务
#       GPU_USER=<用户名> sudo -E ./stop-gpu.sh      # 以 root 跑时必须给出用户级服务归属
#
# 不收密码参数：命令行会留在 ps、/proc/*/cmdline、shell history 和
# journal 里，等于把 root 凭据写进日志。需要提权就先用 sudo -v 缓存。
#
# 不写死任何服务名：谁占着 /dev/dri/renderD* 就停谁，通过 PID → cgroup 反查 unit
# （见 lib/gpu-services.sh）。换一台机器、以后新增推理服务，都不需要改这里。
# 停掉的 unit 记在 /run/b580-bar-tool/stopped-units，供 start-gpu.sh 原样恢复。
set -uo pipefail

DRY=0
case "${1:-}" in
    --dry-run|-n) DRY=1 ;;
    "") ;;
    *) echo "未知参数：$1（只支持 --dry-run）" >&2; exit 2 ;;
esac

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
            # 非交互场景（ssh 跑单条命令、CI、systemd）没有 tty，sudo 无法弹密码提示。
            # 只说"请先 sudo -v"没有用：sudo 的时间戳默认按 tty 记账，换个会话就失效了，
            # 于是这句话会变成死循环——照做之后还是同一条报错（2026-10-28 实测踩到）。
            cat >&2 <<'EOF'
需要 sudo 权限，但当前会话没有 tty，无法交互输入密码。三种解法：

  1) 远程 ssh 时分配 tty（最省事）：
       ssh -tt <用户>@<主机> "sudo -v && ./stop-gpu.sh"

  2) 整条命令走 sudo（脚本内部不再提权；用户级服务靠 SUDO_USER 自动归属）：
       sudo ./stop-gpu.sh

  3) 若已配置免密 sudo（NOPASSWD），本脚本可直接运行，不需要这条提示。
EOF
            exit 1
        fi
    fi
    SUDO_CMD=(sudo -n)
fi

run_sudo() {
    if [ "${#SUDO_CMD[@]}" -gt 0 ]; then "${SUDO_CMD[@]}" "$@"; else "$@"; fi
}

# 用户级 unit 必须落到"真人用户"的 user manager 上。
# 以 root 直接跑时 `systemctl --user` 连不上总线（Failed to connect to bus: 找不到介质），
# 而 systemctl 的 stderr 往往被 2>/dev/null 吞掉、is-active 输出空串，
# 于是打印成 "  -> "（空到空），看起来像"这些服务本来就没在跑"，实际一个都没停。
USER_SESSION_USER="${GPU_USER:-${SUDO_USER:-}}"
if [ -z "$USER_SESSION_USER" ] && [ "$(id -u)" -eq 0 ]; then
    echo "WARN 以 root 直接运行且未提供 SUDO_USER/GPU_USER：用户级服务将无法操作" >&2
    echo "WARN 正确用法：sudo -v && ./stop-gpu.sh   或   GPU_USER=<用户名> sudo -E ./stop-gpu.sh" >&2
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

# ----------------------------------------------------------------- 占用清单 --

if ! command -v fuser >/dev/null 2>&1; then
    echo "缺少 fuser（psmisc 包），无法判定谁占着 GPU —— 拒绝盲停。" >&2
    echo "  apt install psmisc   之后重跑" >&2
    exit 1
fi

NODES="$(gs_render_nodes | tr '\n' ' ')"
if [ -z "${NODES// /}" ]; then
    echo "未找到 /dev/dri/renderD*，看起来没有 GPU 渲染节点。" >&2
    exit 1
fi

SNAP="$(gs_snapshot | sort -u)"
SYS_UNITS="$(gs_units_of_scope system "$SNAP")"
USER_UNITS="$(gs_units_of_scope user "$SNAP")"
RAW_PIDS="$(gs_raw_pids "$SNAP")"

echo "===== A. 当前占用 GPU 的进程（$NODES）====="
if [ -z "${SNAP// /}" ]; then
    echo "  无占用"
else
    printf '%s\n' "$SNAP" | while read -r scope id; do
        case "$scope" in
            system) printf '  [system] %s\n' "$id" ;;
            user)   printf '  [user]   %s\n' "$id" ;;
            raw)    printf '  [手工]   PID %s（不归任何 systemd 服务）\n' "$id" ;;
        esac
    done
fi

# 只停"此刻 active"的 unit：本来就没在跑的，不该被记进恢复清单。
STOP_SYS=(); STOP_USER=(); REC_LINES=""
for u in $SYS_UNITS; do
    if [ "$(run_sudo systemctl is-active "$u" 2>/dev/null)" = "active" ]; then
        STOP_SYS+=("$u"); REC_LINES="${REC_LINES}system $u"$'\n'
    fi
done
for u in $USER_UNITS; do
    if [ "$(userctl is-active "$u" 2>/dev/null)" = "active" ]; then
        STOP_USER+=("$u"); REC_LINES="${REC_LINES}user $u"$'\n'
    fi
done

echo
echo "===== B. 停止（systemd 自行处理依赖倒序）====="
if [ "$DRY" -eq 1 ]; then
    # 只报不动的意义：让"反查判得对不对"能在一台正常跑业务的机器上先验一遍，
    # 而不必为了验证去停服务。true 分支之后的等待/检查都无意义，直接退。
    echo "  --dry-run：以下 unit 会被停掉（本次未停任何东西）"
    [ "${#STOP_SYS[@]}"  -gt 0 ] && printf '  system: %s\n' "${STOP_SYS[*]}"
    [ "${#STOP_USER[@]}" -gt 0 ] && printf '  user:   %s\n' "${STOP_USER[*]}"
    [ "${#STOP_SYS[@]}" -eq 0 ] && [ "${#STOP_USER[@]}" -eq 0 ] && echo "  （没有需要停的 systemd 服务）"
    [ -n "${REC_LINES//[$'\n']/}" ] && printf '  会写入恢复记录：%s\n' "$(printf '%s' "$REC_LINES" | tr '\n' ';')"
    [ -n "${RAW_PIDS//[$'\n']/}" ] && echo "  注意：还有不属于任何 unit 的占用者（PID ${RAW_PIDS//$'\n'/ }），正式跑时需人工处理"
    echo
    echo "dry-run 结束，未停任何服务。正式执行去掉 --dry-run。"
    exit 0
fi
if [ "${#STOP_SYS[@]}" -gt 0 ]; then
    printf '  system: %s\n' "${STOP_SYS[*]}"
    run_sudo systemctl stop "${STOP_SYS[@]}" 2>/dev/null
fi
if [ "${#STOP_USER[@]}" -gt 0 ]; then
    printf '  user:   %s\n' "${STOP_USER[*]}"
    userctl stop "${STOP_USER[@]}" 2>/dev/null
fi
[ "${#STOP_SYS[@]}" -eq 0 ] && [ "${#STOP_USER[@]}" -eq 0 ] && echo "  （没有需要停的 systemd 服务）"

# 记录供 start 侧恢复。空记录不写，避免把上次的记录覆盖掉。
if [ -n "${REC_LINES//[$'\n']/}" ]; then
    gs_record_add "$REC_LINES" || true
    echo "  已记录到 $GS_RECORD（start-gpu.sh 按此恢复）"
fi

# 不归 systemd 的占用者（登录会话、手工拉起的进程、容器内进程）只能报给人。
if [ -n "${RAW_PIDS//[$'\n']/}" ]; then
    echo
    echo "  WARN 以下占用者不属于任何 systemd 服务，脚本不动它们，请人工处理：" >&2
    for p in $RAW_PIDS; do
        echo "        PID $p  $(readlink -f "/proc/$p/exe" 2>/dev/null || echo '?')  $(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null | cut -c1-100)" >&2
    done
fi

# --------------------------------------------------------------- 等待释放 ----

echo
echo "===== C. 等待设备释放 ====="
# 双卡时必须把所有渲染节点都查一遍：只查 renderD128 会漏掉第二张卡上的进程，
# 看起来"已无占用"，实际 remove 时还有进程抓着设备。
for i in 1 2 3 4 5; do
    sleep 1
    busy=""
    for r in $(gs_render_nodes); do
        h="$(run_sudo fuser "$r" 2>/dev/null | tr -s ' ')"
        [ -n "${h// /}" ] && busy="$busy $(basename "$r"):${h// /}"
    done
    printf '  第 %d 秒: 占用=[%s]\n' "$i" "${busy# }"
    [ -z "$busy" ] && break
done

echo
echo "===== D. 最终占用检查 ====="
still=0
for r in $(gs_render_nodes); do
    final="$(run_sudo fuser -v "$r" 2>&1)"
    if printf '%s' "$final" | grep -q "$(basename "$r"):"; then
        echo "  $r 仍有进程占用，明细："
        printf '%s\n' "$final"
        still=1
    fi
done
if [ "$still" -ne 0 ]; then
    echo "  <<< 请人工确认这些进程能否停掉" >&2
    exit 1
fi
echo "  所有渲染节点已无进程占用（$(gs_render_nodes | xargs)）"

# ------------------------------------------------------------- BAR2 基线 ----

echo
echo "===== E. 演练前 BAR2 基线 ====="
TOPO_SH="$HERE/gpu-topology.sh"
[ -x "$TOPO_SH" ] || TOPO_SH="/opt/b580-bar-tool/gpu-topology.sh"
if [ -x "$TOPO_SH" ]; then
    run_sudo bash "$TOPO_SH" --plan
else
    echo "  （未找到 gpu-topology.sh，跳过）"
fi

echo "DONE"
