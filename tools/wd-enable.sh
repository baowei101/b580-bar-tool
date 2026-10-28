#!/bin/bash
# 启用 systemd 运行时看门狗（iTCO_wdt 硬件 TCO 定时器）
# 可逆：把 RuntimeWatchdogSec 改回注释再 daemon-reexec 即恢复
set -uo pipefail

CONF=/etc/systemd/system.conf
TS=$(date +%Y%m%d-%H%M%S)
BAK="$CONF.bak-rebar-$TS"

[ "$(id -u)" -eq 0 ] || { echo "need root"; exit 1; }

echo "===== 1. 备份 ====="
cp -a "$CONF" "$BAK" && echo "备份: $BAK"

echo "===== 2. 修改前 ====="
grep -n 'RuntimeWatchdog' "$CONF" || echo "(无该行)"

echo "===== 3. 写入 RuntimeWatchdogSec=60s ====="
if grep -q '^RuntimeWatchdogSec=' "$CONF"; then
    sed -i 's/^RuntimeWatchdogSec=.*/RuntimeWatchdogSec=60s/' "$CONF"
elif grep -q '^#RuntimeWatchdogSec=' "$CONF"; then
    sed -i 's/^#RuntimeWatchdogSec=.*/RuntimeWatchdogSec=60s/' "$CONF"
else
    printf '\nRuntimeWatchdogSec=60s\n' >> "$CONF"
fi
grep -n 'RuntimeWatchdog' "$CONF"

echo "===== 4. 确保 iTCO_wdt 已加载 ====="
if [ ! -e /dev/watchdog ]; then
    modprobe iTCO_wdt && echo "已 modprobe iTCO_wdt"
else
    echo "/dev/watchdog 已存在"
fi
ls -l /dev/watchdog* 2>/dev/null

echo "===== 5. daemon-reexec（不重启任何服务）====="
systemctl daemon-reexec
sleep 3

echo "===== 6. 验证 ====="
systemctl show -p RuntimeWatchdogUSec
echo -n "watchdog0 state = "; cat /sys/class/watchdog/watchdog0/state 2>/dev/null
echo -n "watchdog0 timeout = "; cat /sys/class/watchdog/watchdog0/timeout 2>/dev/null

echo "===== 7. 服务健康快照 ====="
# 不点名任何服务：reexec 之后真正该看的是"有没有单元挂了"。写死几个名字既
# 换不了机器，也会漏掉真正 failed 的那个。
echo -n "systemd 全局状态: "; systemctl is-system-running 2>/dev/null || true
echo "失败单元（应为空）："
systemctl --failed --no-legend --no-pager 2>/dev/null | sed 's/^/  /'
echo "GPU 渲染节点占用："
busy=0
for r in /dev/dri/renderD*; do
    [ -e "$r" ] || continue
    holders="$(fuser "$r" 2>/dev/null | tr -s ' ')"
    printf '  %-18s %s\n' "$(basename "$r")" "${holders:-无}"
    [ -n "${holders// /}" ] && busy=1
done
[ "$busy" -eq 0 ] && echo "  （当前空闲 —— 扩容前需要的就是这个状态）"
