#!/system/bin/sh
# bg-schedule.sh — 定时切换预设（夜间/日常）
#
# 按 SCHEDULE_START~SCHEDULE_END 时段切到「睡眠」预设(2)，段外切「日常」预设(3)。
# 省电要点：不在循环里频繁轮询时间，而是算「距下次边界还有多少秒」一次长睡，
# 封顶 1 小时（跨过长睡期间系统时间异常的风险窗口）；配置改动由 SIGUSR1 立刻唤醒。
# 参考了 bypass-charger 的 secs_until 思路，但这里切的是整套预设而非单个阈值。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
DATA_DIR=/data/adb/MiFloatCharge
CFG=$MODDIR/config.conf
LOG=$DATA_DIR/float.log
PIDF=$DATA_DIR/schedule.pid
CTL="$MODDIR/bin/float-ctl.sh"

# 睡眠 / 日常 的预设序号（对应 presets.conf 里的 2 / 3）
NIGHT_PRESET=${NIGHT_PRESET:-2}
DAY_PRESET=${DAY_PRESET:-3}

slog() {
  echo "$(date '+%m-%d %H:%M:%S') [定时] $*" >> "$LOG" 2>/dev/null
}

SLEEP_PID=""
RELOAD=0
trap 'RELOAD=1; if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null; fi' USR1
nap() {
  sleep "${1:-60}" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
}

load_conf() {
  SCHEDULE_ENABLED=$(grep '^SCHEDULE_ENABLED=' "$CFG" 2>/dev/null | head -1 | cut -d= -f2)
  SCHEDULE_START=$(grep '^SCHEDULE_START=' "$CFG" 2>/dev/null | head -1 | cut -d= -f2)
  SCHEDULE_END=$(grep '^SCHEDULE_END=' "$CFG" 2>/dev/null | head -1 | cut -d= -f2)
  [ -z "$SCHEDULE_START" ] && SCHEDULE_START=23:00
  [ -z "$SCHEDULE_END" ] && SCHEDULE_END=07:00
  case "$SCHEDULE_START" in *:*) ;; *) SCHEDULE_START=23:00;; esac
  case "$SCHEDULE_END" in *:*) ;; *) SCHEDULE_END=07:00;; esac
}

# 去前导零（版号老的 sh 不支持 10# 语法）
strip0() { _v=${1#0}; echo "${_v:-0}"; }

# 当前时间是否落在夜间时段 [START, END]，支持跨午夜（START > END）
in_night() {
  _now=$(date '+%H:%M')
  if [ "$SCHEDULE_START" \< "$SCHEDULE_END" ]; then
    # 不跨天，如 08:00~20:00
    { [ "$_now" \< "$SCHEDULE_START" ] || [ "$_now" \> "$SCHEDULE_END" ]; } && return 1
  else
    # 跨天，如 23:00~07:00：now < START 且 now > END 才是段外
    [ "$_now" \< "$SCHEDULE_START" ] && [ "$_now" \> "$SCHEDULE_END" ] && return 1
  fi
  return 0
}

# 距下一次进入/退出边界还有多少秒（今天过了算明天）
secs_until() {
  _h=$(strip0 "${1%%:*}")
  _m=$(strip0 "${1##*:}")
  _nh=$(strip0 "$(date +%H)")
  _nm=$(strip0 "$(date +%M)")
  _ns=$(strip0 "$(date +%S)")
  _d=$(( _h*3600 + _m*60 - _nh*3600 - _nm*60 - _ns ))
  [ "$_d" -le 0 ] && _d=$(( _d + 86400 ))
  echo "$_d"
}

# 切换预设脚本：段内→睡眠、段外→日常。返回应用的预设序号
apply_by_time() {
  if in_night; then
    sh "$CTL" preset-apply "$NIGHT_PRESET" >/dev/null 2>&1
    echo "$NIGHT_PRESET"
  else
    sh "$CTL" preset-apply "$DAY_PRESET" >/dev/null 2>&1
    echo "$DAY_PRESET"
  fi
}

echo $$ > "$PIDF"
load_conf
slog "启动 pid=$$ 时段 ${SCHEDULE_START}~${SCHEDULE_END}"

# 启动即按当前时段切一次（用户选择：立即切）
CUR_PRESET=$(apply_by_time)
slog "已按当前时段应用预设 $CUR_PRESET"

while true; do
  load_conf

  if [ "$RELOAD" = "1" ]; then
    RELOAD=0
    slog "配置已更新，重新裁决时段"
    CUR_PRESET=$(apply_by_time)
    slog "应用预设 $CUR_PRESET"
    continue
  fi

  # 定时总开关关闭 → 本脚本不该被拉起（ctl stop 会杀），兜底退出
  if [ "$SCHEDULE_ENABLED" != "1" ]; then
    slog "定时开关已关，退出"
    break
  fi

  # 算到最近一个边界（进入或退出），睡到点；封顶 1 小时
  if in_night; then
    NEXT=$(secs_until "$SCHEDULE_END")
    NEXT_NAME="退出夜间"
  else
    NEXT=$(secs_until "$SCHEDULE_START")
    NEXT_NAME="进入夜间"
  fi
  [ "$NEXT" -gt 3600 ] && NEXT=3600
  [ "$NEXT" -lt 5 ] && NEXT=5
  nap "$NEXT"
  # 醒来后重新裁决：被 SIGUSR1 打断(RELOAD=1) 或睡满到边界，都按当前时段核对一次。
  # 只有预设真的该变才写，避免每轮重复 apply 刷配置。
  NOW_PRESET=$(in_night && echo "$NIGHT_PRESET" || echo "$DAY_PRESET")
  if [ "$NOW_PRESET" != "$CUR_PRESET" ]; then
    sh "$CTL" preset-apply "$NOW_PRESET" >/dev/null 2>&1
    CUR_PRESET=$NOW_PRESET
    slog "时段切换，应用预设 $CUR_PRESET"
  fi
done

rm -f "$PIDF" 2>/dev/null
slog "退出"
