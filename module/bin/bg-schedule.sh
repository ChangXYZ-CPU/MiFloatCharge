#!/system/bin/sh
# bg-schedule.sh — 定时切换预设（夜间/日常）
#
# 按 SCHEDULE_START~SCHEDULE_END 时段切到「夜间」预设(2)，段外切「日常」预设(1)。
# 省电要点：不在循环里频繁轮询时间，而是算「距下次边界还有多少秒」一次长睡，
# 封顶 1 小时（跨过长睡期间系统时间异常的风险窗口）；配置改动由 SIGUSR1 立刻唤醒。
# 参考了 bypass-charger 的 secs_until 思路，但这里切的是整套预设而非单个阈值。

MODDIR=${MODDIR:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd)}
DATA_DIR=/data/adb/MiFloatCharge
CFG=$MODDIR/config.conf
LOG=$DATA_DIR/float.log
PIDF=$DATA_DIR/schedule.pid
CTL="$MODDIR/bin/float-ctl.sh"

# 夜间 / 日常 的预设序号（对应 presets.conf 里的 2 / 1）
# 预设顺序：1日常 2夜间 3游戏 4固定 5自定义
NIGHT_PRESET=${NIGHT_PRESET:-2}
DAY_PRESET=${DAY_PRESET:-1}

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

# HH:MM → 当天分钟数。用数值比较，不用字符串比较：
# 字符串比较会在「0:00 / 9:45」这种无前导零写法上翻车——"20:39" > "9:45" 竟是 false，
# 导致白天被误判成夜间、切错预设。数值比较对有无前导零都正确，兼容旧配置。
hhmm2min() {
  _hh=$(strip0 "${1%%:*}")
  _mm=$(strip0 "${1##*:}")
  echo $(( _hh * 60 + _mm ))
}

# 当前时间是否落在夜间时段 [START, END)，支持跨午夜（START > END）
# 边界语义：START 整点算进入夜间，END 整点算退出夜间（左闭右开）。
# 旧代码用 > END 判断，导致到 END 那一分钟仍算夜间、不切换；配合 secs_until
# 的"睡到整点"就会错过切换窗口（实测 9:45 没切回日常）。
in_night() {
  _now=$(hhmm2min "$(date '+%H:%M')")
  _st=$(hhmm2min "$SCHEDULE_START")
  _en=$(hhmm2min "$SCHEDULE_END")
  if [ "$_st" -lt "$_en" ]; then
    # 不跨天，如 19:11~19:13：now >= START 且 now < END 是夜间
    { [ "$_now" -lt "$_st" ] || [ "$_now" -ge "$_en" ]; } && return 1
  else
    # 跨天，如 23:45~09:45：now >= START 或 now < END 是夜间
    { [ "$_now" -ge "$_st" ] || [ "$_now" -lt "$_en" ]; } || return 1
  fi
  return 0
}

# 预设序号 → 名称（从 presets.conf 读，日志里能看出切的是哪个预设）
preset_name() {
  grep "^$1=" "$DATA_DIR/presets.conf" 2>/dev/null | head -1 | cut -d= -f2 | cut -d, -f1
}

# 下个边界的时刻 + 倒计时（日志里写清「下次切是什么时候」）
# 输出形如：20:00 进入夜间（约 1 小时 23 分后）
next_boundary_desc() {
  if in_night; then
    _bt="$SCHEDULE_END"; _bn="退出夜间"
  else
    _bt="$SCHEDULE_START"; _bn="进入夜间"
  fi
  _sec=$(secs_until "$_bt")
  _h=$(( _sec / 3600 )); _m=$(( (_sec % 3600) / 60 ))
  if [ "$_h" -gt 0 ]; then
    echo "${_bt} ${_bn}（约 ${_h} 小时 ${_m} 分后）"
  else
    echo "${_bt} ${_bn}（约 ${_m} 分后）"
  fi
}

# 距下一次进入/退出边界还有多少秒（今天过了算明天）
secs_until() {
  _h=$(strip0 "${1%%:*}")
  _m=$(strip0 "${1##*:}")
  # 一次读取时分秒，避免三次 date 跨秒/跨分钟边界拼出不存在的时间点。
  # 用字符串切割而非 set --，不碰位置参数。
  _t=$(date '+%H:%M:%S')
  _r=${_t#*:}
  _nh=$(strip0 "${_t%%:*}"); _nm=$(strip0 "${_r%%:*}"); _ns=$(strip0 "${_r##*:}")
  _d=$(( _h*3600 + _m*60 - _nh*3600 - _nm*60 - _ns ))
  # 刚过边界的 0~59 秒容差：nap 睡到边界整点醒来时 _d 常是 -1~-3（sleep 精度/调度），
  # 旧代码 `-le 0 → +86400` 会把它当成"下次是明天"，再被封顶睡 3600 秒，
  # 醒来已是边界后 1 小时、错过切换窗口（实测 9:45 到点没切回日常就是这么来的）。
  # 给 59 秒容差：边界后 1 分钟内仍返回"马上到点"，让醒来后立刻重新裁决。
  # 注意必须同时限定 <=0，否则所有正常倒计时（正数）都会被错误设成 1 秒（回归 bug）。
  if [ "$_d" -ge -59 ] && [ "$_d" -le 0 ]; then
    _d=1
  elif [ "$_d" -le 0 ]; then
    _d=$(( _d + 86400 ))
  fi
  echo "$_d"
}

# 切换预设脚本：段内→夜间(2)、段外→日常(1)。返回应用的预设序号
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
slog "=== 定时脚本启动 pid=$$ 时段 ${SCHEDULE_START}~${SCHEDULE_END}（夜间→预设${NIGHT_PRESET}/日常→预设${DAY_PRESET}）==="

# 启动即按当前时段切一次（用户选择：立即切）
if in_night; then NOW="夜间"; else NOW="日常"; fi
CUR_PRESET=$(apply_by_time)
slog "启动裁决：当前 $(date '+%H:%M') 属${NOW}时段 → 应用预设 ${CUR_PRESET}（$(preset_name "$CUR_PRESET")）；下次 $(next_boundary_desc)"

while true; do
  load_conf

  if [ "$RELOAD" = "1" ]; then
    RELOAD=0
    slog "配置已更新（现为 ${SCHEDULE_START}~${SCHEDULE_END}），重新裁决时段"
    # 保存时段 = 用户主动"重新确定状态"，和开关/启动一样无条件按当前时段 apply。
    # 不能只在"目标 != CUR_PRESET"时才 apply：CUR_PRESET 只是脚本自己记的上次目标，
    # 不反映用户中途手动切了什么预设。若手动切到游戏后保存时段，目标(日常)==记录(日常)
    # 会被误判"未变跳过"，结果停在游戏、与时段目标不符，直到下个边界才纠正。
    # 无条件 apply 的代价是短时间内可能两次 kick daemon（启动+保存），但正确性优先。
    if in_night; then NOW="夜间"; else NOW="日常"; fi
    OLD=$CUR_PRESET
    CUR_PRESET=$(apply_by_time)
    slog "重裁决：$(date '+%H:%M') 属${NOW}时段 → 应用预设 ${CUR_PRESET}（$(preset_name "$CUR_PRESET")）[原 ${OLD}（$(preset_name "$OLD")）]；下次 $(next_boundary_desc)"
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
  if in_night; then NOW="夜间"; else NOW="日常"; fi
  NOW_PRESET=$(in_night && echo "$NIGHT_PRESET" || echo "$DAY_PRESET")
  if [ "$NOW_PRESET" != "$CUR_PRESET" ]; then
    OLD=$CUR_PRESET
    sh "$CTL" preset-apply "$NOW_PRESET" >/dev/null 2>&1
    CUR_PRESET=$NOW_PRESET
    slog "★ 到点切换：$(date '+%H:%M') 进入${NOW}时段，预设 ${OLD}（$(preset_name "$OLD")）→ ${CUR_PRESET}（$(preset_name "$CUR_PRESET")）；下次 $(next_boundary_desc)"
  fi
done

rm -f "$PIDF" 2>/dev/null
slog "=== 定时脚本退出（收到关闭信号或总开关关闭）==="
