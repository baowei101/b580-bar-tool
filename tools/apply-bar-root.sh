#!/bin/bash
# 在宿主机 root 上下文里跑 ReBAR 扩容，全程落日志。
#
# 所有参数原样转发给 b580-bar-tool.sh，例如：
#   apply-bar-root.sh                       # 单卡机器：自动选唯一一张
#   apply-bar-root.sh --gpu 0000:BB:DD.F    # 多卡机器：显式指定
#   apply-bar-root.sh --size 13 --gpu 0000:BB:DD.F
#
# 本脚本不写死任何 BDF —— 旧版末尾用 sed 读 0000:04:00.0 的 BAR2，
# 换槽位后打印空白，看起来像"扩容成功但读不到"，其实是读错了设备。
set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# 主脚本位置要认两种布局：
#   部署布局 —— tools/ 的内容平铺到 /opt/b580-bar-tool/，主脚本与它同级
#   仓库布局 —— tools/ 是子目录，主脚本在上一级
# 只认前者时，从仓库直接跑会因为找不到主脚本而失败；而本脚本把全部输出
# 导进日志，屏幕上只剩一行"日志: /var/log/..."，看起来像跑完了。
find_tool() {
    local c
    for c in "$HERE/b580-bar-tool.sh" "$HERE/../b580-bar-tool.sh"; do
        [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}
TOOL="${B580_TOOL:-$(find_tool)}"
if [ ! -x "$TOOL" ]; then
    echo "找不到可执行的 b580-bar-tool.sh，未执行任何操作。" >&2
    echo "  已试：$HERE/b580-bar-tool.sh" >&2
    echo "        $HERE/../b580-bar-tool.sh" >&2
    echo "  用 B580_TOOL=<绝对路径> 显式指定。" >&2
    exit 1
fi
LOG="${B580_APPLY_LOG:-/var/log/b580-apply-$(date +%H%M%S).log}"

# 探测层可选：有就逐张列出目标卡的 BAR2，没有就只报 tool 的 status
TOPO_OK=0
if [ -r "$HERE/lib/topology.sh" ]; then
    # shellcheck source=lib/topology.sh
    . "$HERE/lib/topology.sh"
    TOPO_OK=1
fi

list_bar2() {
    if [ "$TOPO_OK" -eq 1 ]; then
        local b
        for b in $(topo_enumerate); do
            printf '  %-14s BAR2 = %sMB  锚点 %s\n' \
                   "$b" "$(topo_bar2_mb "$b")" "$(topo_anchor "$b" 2>/dev/null || echo '?')"
        done
    else
        echo "  （无 lib/topology.sh，跳过逐张 BAR2 复查）"
    fi
}

{
  echo "===== 开始 $(date) ====="
  echo "参数：$*"
  [ "$TOPO_OK" -eq 1 ] && { echo "--- 扩容前 ---"; list_bar2; }

  "$TOOL" "$@"
  rc=$?
  echo "===== apply 退出码=$rc ====="

  echo "--- 复查 status ---"
  "$TOOL" status

  echo "--- BAR2 ---"
  list_bar2
} >> "$LOG" 2>&1

echo "日志: $LOG"
