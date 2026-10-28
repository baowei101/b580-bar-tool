#!/bin/bash
# 以 root 身份恢复 GPU 服务 —— nsenter / 容器内调用 start-gpu.sh 的入口。
#
# 和 stop-gpu-root.sh 一样，只负责补上"用户级服务归属哪个账号"，逻辑全在
# start-gpu.sh：恢复哪些服务由 stop 阶段写下的记录决定，不靠名单。
#
# 用法：
#   GPU_USER=baow ./start-gpu-root.sh
#   docker run --privileged --pid=host ... \
#     nsenter -t 1 -m -u -i -n -p -- env GPU_USER=baow /opt/b580-bar-tool/start-gpu-root.sh
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[ "$(id -u)" -eq 0 ] || {
    echo "本脚本是 root / nsenter 场景的入口，需要 root 身份。" >&2
    echo "  普通场景请直接用：sudo -v && ./start-gpu.sh" >&2
    exit 1
}

USER_ARG="${GPU_USER:-${SUDO_USER:-}}"
[ -n "$USER_ARG" ] || {
    echo "需要指定用户级服务的归属账号：GPU_USER=<用户名> $0" >&2
    echo "  （root 下 systemctl --user 连不上总线，必须切到真实用户的 user manager）" >&2
    exit 2
}

exec env GPU_USER="$USER_ARG" "$HERE/start-gpu.sh" "$@"
