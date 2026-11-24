#!/system/bin/sh
# service.sh — 开机自启（late_start）
MODDIR=${0%/*}
DATA_DIR=/data/adb/MiFloatCharge
mkdir -p "$DATA_DIR" 2>/dev/null

# 等 sysfs 就绪
i=0
while [ ! -e /sys/class/power_supply/battery/constant_charge_current_max ] && [ $i -lt 60 ]; do
  sleep 2
  i=$((i + 1))
done

# 读配置：只有 ENABLED=1 才启动守护，否则完全退出不占资源
EN=$(grep '^ENABLED=' "$MODDIR/config.conf" 2>/dev/null | head -1 | cut -d= -f2)
if [ "$EN" = "1" ]; then
  echo "$(date '+%m-%d %H:%M:%S') service.sh: ENABLED=1，启动 daemon" >> "$DATA_DIR/float.log"
  # 记录原始值（若没有）
  ORIG=$DATA_DIR/orig_cm
  if [ ! -f "$ORIG" ]; then
    cat /sys/class/power_supply/battery/constant_charge_current_max > "$ORIG" 2>/dev/null
  fi
  setsid sh "$MODDIR/bin/float-daemon.sh" > /dev/null 2>&1 &
else
  echo "$(date '+%m-%d %H:%M:%S') service.sh: ENABLED=${EN:-0}，不启动（零占用）" >> "$DATA_DIR/float.log"
fi

# 定时切换预设：总开关和定时开关都开着才拉起（关总开关时两个进程联动停止，
# 开机也保持一致；SCHEDULE_ENABLED 配置不清，开总开关时会自动恢复）
SCHED=$(grep '^SCHEDULE_ENABLED=' "$MODDIR/config.conf" 2>/dev/null | head -1 | cut -d= -f2)
if [ "$EN" = "1" ] && [ "$SCHED" = "1" ]; then
  # 清掉上次残留的 pid（重启后 pid 可能复用）
  rm -f "$DATA_DIR/schedule.pid" 2>/dev/null
  pkill -f "bg-schedule[.]sh" 2>/dev/null
  setsid sh "$MODDIR/bin/bg-schedule.sh" > /dev/null 2>&1 &
fi
