#!/system/bin/sh
# action.sh — Magisk App 模块卡片上的「操作」按钮
#
# 行为：
#   装了 KsuWebUI  → 直接打开图形界面（里面有开关、参数、日志）
#   没装          → 回退成命令行切换（点一下开 / 再点一下关）

MODDIR=${0%/*}
CTL="$MODDIR/bin/float-ctl.sh"

# ---------- 优先走图形界面 ----------
if pm list packages 2>/dev/null | grep -q "io.github.a13e300.ksuwebui"; then
  echo "正在用 KsuWebUI 打开图形界面…"
  am start -n io.github.a13e300.ksuwebui/.WebUIActivity -e id float_charge > /dev/null 2>&1
  sleep 1
  echo ""
  echo "───────── 当前状态 ─────────"
  CM=$(cat /sys/class/power_supply/battery/constant_charge_current_max 2>/dev/null)
  CUR=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
  CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
  echo "电流上限 : $CM µA"
  echo "电池电流 : $CUR µA（负=充 / 正=放）"
  echo "电量     : $CAP%"
  echo ""
  echo "▶ 开关、参数、日志都在图形界面里操作"
  exit 0
fi

# ---------- 回退：命令行切换 ----------
is_on() {
  p=$(cat /data/adb/float_charge/daemon.pid 2>/dev/null)
  if [ -n "$p" ] && [ -d "/proc/$p" ]; then
    return 0
  fi
  [ "$(grep '^ENABLED=' "$MODDIR/config.conf" 2>/dev/null | cut -d= -f2)" = "1" ]
}

if is_on; then
  sh "$CTL" stop > /dev/null 2>&1
  NEW=off
else
  sh "$CTL" start > /dev/null 2>&1
  NEW=on
fi

CM=$(cat /sys/class/power_supply/battery/constant_charge_current_max 2>/dev/null)
CUR=$(cat /sys/class/power_supply/battery/current_now 2>/dev/null)
CAP=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null)
ONLINE=$(cat /sys/class/power_supply/usb/online 2>/dev/null)

echo "════════════════════════"
if [ "$NEW" = "on" ]; then
  echo "   悬浮供电 · 已开启"
else
  echo "   悬浮供电 · 已关闭"
fi
echo "════════════════════════"
echo "电流上限 : $CM µA"
echo "电池电流 : $CUR µA（负=充 / 正=放）"
echo "电量     : $CAP%"
if [ "$ONLINE" = "1" ]; then
  echo "充电器   : 已连接"
else
  echo "充电器   : 未连接（接上后自动开始）"
fi
echo "━━━━━━━━━━━━━━━━━━━━━━━━"

if [ "$NEW" = "on" ]; then
  echo "▶ 关闭方法：再点一次「操作」按钮"
else
  echo "▶ 开启方法：再点一次「操作」按钮"
  echo "  电流上限已还原为正常值"
fi
echo ""
echo "（图形界面需自备第三方 App「KsuWebUI」；本模块不自带也不安装它）"
