#!/system/bin/sh
# service.sh — 开机自启（late_start）
MODDIR=${0%/*}
DATA_DIR=/data/adb/MiFloatCharge
mkdir -p "$DATA_DIR" 2>/dev/null
# 旧版数据目录迁移：模块 ID 由 float_charge 改为 MiFloatCharge
_OLD_DATA=/data/adb/float_charge
_OLD_MOD=/data/adb/modules/float_charge
if [ -d "$_OLD_DATA" ] || [ -d "$_OLD_MOD" ]; then
  mkdir -p "$DATA_DIR" 2>/dev/null
  # 运行时数据（预设/原始CM/断电标记）
  for _f in presets.conf orig_cm top_cut; do
    [ -f "$_OLD_DATA/$_f" ] && [ ! -f "$DATA_DIR/$_f" ] && cp "$_OLD_DATA/$_f" "$DATA_DIR/$_f" 2>/dev/null
  done
  # 配置在旧模块目录里。注意 zip 自带默认 config.conf，此时新模块目录里
  # 已经有文件了，不能只判断"文件不存在"；用一次性标记，避免覆盖用户
  # 装完新版后又改过的设置
  _OLD_CFG="$_OLD_MOD/config.conf"
  if [ -f "$_OLD_CFG" ] && [ ! -f "$DATA_DIR/.migrated" ]; then
    cp "$_OLD_CFG" "$MODDIR/config.conf" 2>/dev/null
    touch "$DATA_DIR/.migrated" 2>/dev/null
  fi
fi

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
