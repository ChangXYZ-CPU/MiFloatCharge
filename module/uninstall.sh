#!/system/bin/sh
# uninstall.sh — 卸载前还原电流上限，避免卸载后还被限流
MODDIR=${0%/*}
DATA_DIR=/data/adb/MiFloatCharge
ORIG=$DATA_DIR/orig_cm
CM=/sys/class/power_supply/battery/constant_charge_current_max

# 停 daemon
if [ -f "$DATA_DIR/daemon.pid" ]; then
  p=$(cat "$DATA_DIR/daemon.pid" 2>/dev/null)
  [ -n "$p" ] && kill "$p" 2>/dev/null
  sleep 1
  [ -n "$p" ] && [ -d "/proc/$p" ] && kill -9 "$p" 2>/dev/null
fi

# 还原
if [ -f "$ORIG" ] && [ -e "$CM" ]; then
  o=$(cat "$ORIG" 2>/dev/null)
  case "$o" in ''|*[!0-9]*) o=9999999;; esac
  chmod 666 "$CM" 2>/dev/null
  echo "$o" > "$CM" 2>/dev/null
fi
