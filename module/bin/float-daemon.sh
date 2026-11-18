#!/system/bin/sh
# float-daemon.sh — 悬浮供电主循环（增量反馈）
#
# 思路：把 constant_charge_current_max 当成"给电池的电流上限"，
# 每周期采样若干次电池净电流（负=充 / 正=放），取平均，
# 再按平均值方向微调上限，目标是让平均净电流落在死区内（≈0）。
#
# 为什么不直接测系统功耗再赋值：净电流不等于功耗，需要断充才能测准，
# 每轮断充会让电池反复放电；增量反馈全程不断充，电池负担最小。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
DATA_DIR=/data/adb/float_charge
CFG=$MODDIR/config.conf
LOG=$DATA_DIR/float.log
PIDF=$DATA_DIR/daemon.pid

BAT=/sys/class/power_supply/battery
CM=$BAT/constant_charge_current_max
CUR=$BAT/current_now
CAP=$BAT/capacity
ONLINE=/sys/class/power_supply/usb/online

mkdir -p "$DATA_DIR" 2>/dev/null

log() {
  ts=$(date '+%m-%d %H:%M:%S')
  echo "$ts $*" >> "$LOG"
  # 截断日志
  n=${LOG_MAX_LINES:-400}
  total=$(wc -l < "$LOG" 2>/dev/null | tr -d ' ')
  if [ -n "$total" ] && [ "$total" -gt "$n" ]; then
    tail -n "$n" "$LOG" > "$LOG.tmp" 2>/dev/null && mv -f "$LOG.tmp" "$LOG"
  fi
}

load_conf() {
  # 默认值
  ENABLED=0; SAMPLE_WINDOW=60; SAMPLE_COUNT=5; DEADBAND_MA=50
  STEP_MA=30; MIN_CM_MA=50; MAX_CM_MA=500; BATT_MAX=95; BATT_MIN=20
  LOG_MAX_LINES=400
  [ -f "$CFG" ] && . "$CFG"
  # 防错
  case "$SAMPLE_COUNT" in ''|*[!0-9]*|0) SAMPLE_COUNT=5;; esac
  case "$SAMPLE_WINDOW" in ''|*[!0-9]*|0) SAMPLE_WINDOW=60;; esac
  case "$DEADBAND_MA" in ''|*[!0-9]*) DEADBAND_MA=50;; esac
  case "$STEP_MA" in ''|*[!0-9]*) STEP_MA=30;; esac
  case "$MIN_CM_MA" in ''|*[!0-9]*) MIN_CM_MA=50;; esac
  case "$MAX_CM_MA" in ''|*[!0-9]*) MAX_CM_MA=500;; esac
  case "$BATT_MAX" in ''|*[!0-9]*) BATT_MAX=95;; esac
  case "$BATT_MIN" in ''|*[!0-9]*) BATT_MIN=20;; esac
  [ "$MAX_CM_MA" -lt "$MIN_CM_MA" ] && MAX_CM_MA=$MIN_CM_MA
}

write_cm() {
  v=$1
  [ -e "$CM" ] || { log "ERR 节点不存在 $CM"; return 1; }
  chmod 666 "$CM" 2>/dev/null
  cur=$(cat "$CM" 2>/dev/null)
  [ "$cur" = "$v" ] && return 0
  echo "$v" > "$CM" 2>/dev/null
  now=$(cat "$CM" 2>/dev/null)
  if [ "$now" != "$v" ]; then
    # 部分机型写入被拒，记一次就够，不要刷屏
    log "WARN 写CM失败 want=$v got=$now"
    return 1
  fi
  return 0
}

echo $$ > "$PIDF"
load_conf
log "=== daemon start pid=$$ window=${SAMPLE_WINDOW}s count=${SAMPLE_COUNT} ==="

INITED=0
LAST_ONLINE=""
LAST_ENABLED=""

while true; do
  load_conf

  # 开关关闭 → 若之前开着，把电流上限还原，退出循环前的清理由 ctl 负责
  if [ "$ENABLED" != "1" ]; then
    if [ "$LAST_ENABLED" = "1" ]; then
      log "ENABLED=0，停止调整"
      INITED=0
    fi
    LAST_ENABLED=0
    sleep 10
    continue
  fi
  LAST_ENABLED=1

  # 没插电 → 等
  on=$(cat "$ONLINE" 2>/dev/null)
  if [ "$on" != "1" ]; then
    if [ "$LAST_ONLINE" != "0" ]; then
      log "未插电，暂停"
      LAST_ONLINE=0
      INITED=0
    fi
    sleep 30
    continue
  fi
  # 重新插电 → 重置，下轮重新初始化
  if [ "$LAST_ONLINE" = "0" ]; then
    log "已插电，重新初始化"
    INITED=0
  fi
  LAST_ONLINE=1

  cap=$(cat "$CAP" 2>/dev/null)
  case "$cap" in ''|*[!0-9]*) cap=0;; esac

  if [ "$cap" -ge "$BATT_MAX" ]; then
    # 电量到顶：保持当前限流（继续悬浮），不往上推
    log "电量 ${cap}% >= ${BATT_MAX}%，保持悬浮不调整"
    sleep "${SAMPLE_WINDOW}"
    continue
  fi
  if [ "$cap" -lt "$BATT_MIN" ]; then
    log "电量 ${cap}% < ${BATT_MIN}%，暂停（低电量优先充满）"
    sleep 60
    continue
  fi

  # 首次进入 → 从下限起步（安全，不会一上来充过头）
  if [ "$INITED" != "1" ]; then
    write_cm $((MIN_CM_MA * 1000))
    log "初始化 CM=$((MIN_CM_MA * 1000))µA（从下限起步）"
    INITED=1
  fi

  # 采样
  interval=$((SAMPLE_WINDOW / SAMPLE_COUNT))
  [ "$interval" -lt 1 ] && interval=1
  sum=0
  i=0
  while [ "$i" -lt "$SAMPLE_COUNT" ]; do
    c=$(cat "$CUR" 2>/dev/null)
    case "$c" in -*) ok=1;; ''|*[!0-9-]*) ok=0;; *) ok=1;; esac
    if [ "$ok" = "1" ]; then
      sum=$((sum + c))
    fi
    i=$((i + 1))
    [ "$i" -lt "$SAMPLE_COUNT" ] && sleep "$interval"
  done
  avg=$((sum / SAMPLE_COUNT))

  cm=$(cat "$CM" 2>/dev/null)
  case "$cm" in ''|*[!0-9]*) cm=$((MIN_CM_MA * 1000));; esac

  db=$((DEADBAND_MA * 1000))
  step=$((STEP_MA * 1000))
  adj=0
  if [ "$avg" -lt "-$db" ]; then
    # 还在充（净电流为负）→ 上限调小
    cm=$((cm - step)); adj=-1
  elif [ "$avg" -gt "$db" ]; then
    # 在放电（净电流为正）→ 上限调大
    cm=$((cm + step)); adj=1
  fi

  # 限幅
  lo=$((MIN_CM_MA * 1000)); hi=$((MAX_CM_MA * 1000))
  [ "$cm" -lt "$lo" ] && cm=$lo
  [ "$cm" -gt "$hi" ] && cm=$hi

  if [ "$adj" != "0" ]; then
    write_cm "$cm"
  fi
  log "cap=${cap}% avg=${avg}µA cm=${cm}µA adj=${adj}"
done
