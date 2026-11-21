#!/system/bin/sh
# float-ctl.sh — 启动 / 停止 / 状态 / 切换
# 用法: float-ctl.sh start|stop|toggle|status

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
DATA_DIR=/data/adb/MiFloatCharge
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
CFG=$MODDIR/config.conf
LOG=$DATA_DIR/float.log
PIDF=$DATA_DIR/daemon.pid
ORIG=$DATA_DIR/orig_cm
PRESETS=$DATA_DIR/presets.conf
CM=/sys/class/power_supply/battery/constant_charge_current_max
CUR=/sys/class/power_supply/battery/current_now
CAP=/sys/class/power_supply/battery/capacity

mkdir -p "$DATA_DIR" 2>/dev/null

set_conf() {
  # $1 = 键, $2 = 值
  [ -f "$CFG" ] || return 1
  grep -q "^$1=" "$CFG" 2>/dev/null || return 1
  sed "s|^$1=.*|$1=$2|" "$CFG" > "$CFG.tmp" 2>/dev/null && mv -f "$CFG.tmp" "$CFG"
}

get_conf() {
  grep "^$1=" "$CFG" 2>/dev/null | head -1 | cut -d= -f2
}

daemon_alive() {
  [ -f "$PIDF" ] || return 1
  p=$(cat "$PIDF" 2>/dev/null)
  [ -n "$p" ] || return 1
  [ -d "/proc/$p" ] || return 1
  # 确认是这个脚本，不是复用 pid 的别的进程
  cmd=$(tr '\0' ' ' < "/proc/$p/cmdline" 2>/dev/null)
  case "$cmd" in *float-daemon*) return 0;; *) return 1;; esac
}

do_start() {
  if daemon_alive; then
    echo "已经在运行（pid=$(cat $PIDF)）"
    return 0
  fi
  # 保存原始电流上限，停止时还原
  if [ ! -f "$ORIG" ] && [ -e "$CM" ]; then
    cat "$CM" > "$ORIG" 2>/dev/null
    echo "已记录原始 CM=$(cat $ORIG 2>/dev/null)"
  fi
  set_conf ENABLED 1
  setsid sh "$MODDIR/bin/float-daemon.sh" > /dev/null 2>&1 &
  sleep 2
  if daemon_alive; then
    echo "✅ 已开启悬浮供电（pid=$(cat $PIDF)）"
    echo "   采样窗口 $(get_conf SAMPLE_WINDOW)s / 每次 $(get_conf SAMPLE_COUNT) 点"
  else
    echo "❌ 启动失败，检查日志: $LOG"
    tail -5 "$LOG" 2>/dev/null
    return 1
  fi
}

do_stop() {
  set_conf ENABLED 0
  if daemon_alive; then
    p=$(cat "$PIDF" 2>/dev/null)
    kill "$p" 2>/dev/null
    sleep 1
    # 兜底
    if [ -d "/proc/$p" ]; then kill -9 "$p" 2>/dev/null; fi
    echo "已停止 daemon"
  else
    echo "daemon 未在运行"
  fi
  rm -f "$PIDF" 2>/dev/null
  # 还原原始电流上限（关键：不然关了还在限流）
  if [ -e "$CM" ]; then
    chmod 666 "$CM" 2>/dev/null
    echo 22000000 > "$CM" 2>/dev/null
    now=$(cat "$CM" 2>/dev/null)
    echo "已还原电流上限: $now µA（原厂 22000mA）"
    echo "$(date '+%m-%d %H:%M:%S') === stopped，CM 还原为 $now ===" >> "$LOG"
    rm -f "$ORIG" 2>/dev/null
  fi
  echo "⏹ 已关闭悬浮供电"
}

# 预设格式：序号=名称,窗口,次数,死区,步长,偏离阈值,单次限幅,CM下限,CM上限,电量上限,电量下限[,初始限流]
# 改完保存即生效；点击标签应用，长按标签用当前参数覆盖该预设
default_presets() {
  cat > "$PRESETS" <<'EOT'
1=游戏,60,5,30,15,100,100,50,5000,85,80,100
2=睡眠,120,1,10,5,50,20,0,500,85,80,60
3=日常,30,3,20,10,200,100,50,2000,85,80,80
4=自定义,30,2,20,10,100,100,50,2000,85,80,80
EOT
}

preset_line() {
  [ -f "$PRESETS" ] || default_presets
  grep "^$1=" "$PRESETS" 2>/dev/null | head -1 | cut -d= -f2-
}

do_apply_preset() {
  n=$1
  case "$n" in ''|*[!0-9]*) echo "ERR|需要预设序号"; return 1;; esac
  line=$(preset_line "$n")
  [ -n "$line" ] || { echo "ERR|预设 $n 不存在"; return 1; }
  _o=$IFS; IFS=','
  set -- $line
  IFS=$_o
  nm=$1
  set_conf SAMPLE_WINDOW "$2"
  set_conf SAMPLE_COUNT  "$3"
  set_conf DEADBAND_MA   "$4"
  set_conf STEP_MA       "$5"
  set_conf BIG_MA        "$6"
  set_conf MAX_ADJ_MA    "$7"
  set_conf MIN_CM_MA     "$8"
  set_conf MAX_CM_MA     "$9"
  shift 9
  bmax=$1; bmin=$2
  # 预设里可能存了填反的值（下限>上限），应用时自动纠正，避免又写回矛盾配置
  if [ -n "$bmax" ] && [ -n "$bmin" ] && [ "$bmin" -ge "$bmax" ] 2>/dev/null; then
    _t=$bmax; bmax=$bmin; bmin=$_t
  fi
  set_conf BATT_MAX      "$bmax"
  set_conf BATT_MIN      "$bmin"
  [ -n "$3" ] && set_conf INIT_CM_MA "$3"   # 第 12 项可选，兼容旧预设
  echo "OK|$nm"
}

# 用当前 config.conf 的值覆盖某个预设（长按标签保存）
do_save_preset() {
  n=$1
  case "$n" in ''|*[!0-9]*) echo "ERR|需要预设序号"; return 1;; esac
  line=$(preset_line "$n")
  [ -n "$line" ] || { echo "ERR|预设 $n 不存在"; return 1; }
  _o=$IFS; IFS=','
  set -- $line
  IFS=$_o
  nm=$1
  new="$nm,$(get_conf SAMPLE_WINDOW),$(get_conf SAMPLE_COUNT),$(get_conf DEADBAND_MA),$(get_conf STEP_MA),$(get_conf BIG_MA),$(get_conf MAX_ADJ_MA),$(get_conf MIN_CM_MA),$(get_conf MAX_CM_MA),$(get_conf BATT_MAX),$(get_conf BATT_MIN),$(get_conf INIT_CM_MA)"
  [ -f "$PRESETS" ] || default_presets
  grep -v "^$n=" "$PRESETS" > "$PRESETS.tmp" 2>/dev/null
  echo "$n=$new" >> "$PRESETS.tmp"
  sort -t= -k1 -n "$PRESETS.tmp" > "$PRESETS" 2>/dev/null && rm -f "$PRESETS.tmp"
  echo "OK|已用当前参数更新预设：$nm"
}

do_list_presets() {
  [ -f "$PRESETS" ] || default_presets
  cat "$PRESETS"
}

do_status() {
  en=$(get_conf ENABLED)
  echo "开关: ${en:-未知}"
  if daemon_alive; then
    echo "daemon: 运行中 (pid=$(cat $PIDF))"
  else
    echo "daemon: 未运行"
  fi
  echo "电流上限 CM: $(cat $CM 2>/dev/null) µA"
  echo "电池净电流: $(cat $CUR 2>/dev/null) µA（负=充 / 正=放）"
  echo "电量: $(cat $CAP 2>/dev/null)%"
  echo "采样: 窗口 $(get_conf SAMPLE_WINDOW)s × $(get_conf SAMPLE_COUNT) 次"
  echo "--- 最近日志 ---"
  tail -5 "$LOG" 2>/dev/null
}

case "$1" in
  start)  do_start ;;
  stop)   do_stop ;;
  toggle)
    if daemon_alive; then do_stop; else do_start; fi
    ;;
  status) do_status ;;
  preset-apply) do_apply_preset "$2" ;;
  preset-save)  do_save_preset "$2" ;;
  preset-list)  do_list_presets ;;
  *)
    echo "用法: $0 start|stop|toggle|status|preset-list|preset-apply N|preset-save N"
    ;;
esac
