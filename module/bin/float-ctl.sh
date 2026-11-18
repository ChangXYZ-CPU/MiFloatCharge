#!/system/bin/sh
# float-ctl.sh — 启动 / 停止 / 状态 / 切换
# 用法: float-ctl.sh start|stop|toggle|status

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
DATA_DIR=/data/adb/float_charge
CFG=$MODDIR/config.conf
LOG=$DATA_DIR/float.log
PIDF=$DATA_DIR/daemon.pid
ORIG=$DATA_DIR/orig_cm
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
  if [ -f "$ORIG" ] && [ -e "$CM" ]; then
    o=$(cat "$ORIG" 2>/dev/null)
    case "$o" in ''|*[!0-9]*) o=9999999;; esac
    chmod 666 "$CM" 2>/dev/null
    echo "$o" > "$CM" 2>/dev/null
    now=$(cat "$CM" 2>/dev/null)
    echo "已还原电流上限: $now µA"
    echo "$(date '+%m-%d %H:%M:%S') === stopped，CM 还原为 $now ===" >> "$LOG"
    rm -f "$ORIG" 2>/dev/null
  fi
  echo "⏹ 已关闭悬浮供电"
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
  *)
    echo "用法: $0 start|stop|toggle|status"
    ;;
esac
