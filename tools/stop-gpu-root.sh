#!/bin/bash
# 以 root 身份停 GPU 服务 —— nsenter / 容器内调用 stop-gpu.sh 的入口。
#
# 本脚本只剩一件事：确定"用户级服务归属哪个账号"，然后交给 stop-gpu.sh。
# 真正的逻辑（反查占用、分组停止、写恢复记录）在 stop-gpu.sh 与
# lib/gpu-services.sh 里，不在这里复制第二份 —— 两份实现必然漂移。
#
# 用法：
#   GPU_USER=baow ./stop-gpu-root.sh
#   docker run --privileged --pid=host ... \
#     nsenter -t 1 -m -u -i -n -p -- env GPU_USER=baow /opt/b580-bar-tool/stop-gpu-root.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || {
    echo "本脚本是 root / nsenter 场景的入口，需要 root 身份。" >&2
    echo "  普通场景请直接用：sudo -v && ./stop-gpu.sh" >&2
    exit 1
}

USER_ARG="${GPU_USER:-${SUDO_USER:-}}"
[ -n "$USER_ARG" ] || {
    echo "需要指定用户级服务的归属账号：GPU_USER=<用户名> $0" >&2
    echo "  （root 下 systemctl --user 连不上总线，必须切到真实用户的 user manager）" >&2
    exit 2
}

exec env GPU_USER="$USER_ARG" "$HERE/stop-gpu.sh" "$@"
