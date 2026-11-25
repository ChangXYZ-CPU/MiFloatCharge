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
DATA_DIR=/data/adb/MiFloatCharge
CFG=$MODDIR/config.conf
LOG=$DATA_DIR/float.log
PIDF=$DATA_DIR/daemon.pid

BAT=/sys/class/power_supply/battery
CM=$BAT/constant_charge_current_max
CUR=$BAT/current_now
CAP=$BAT/capacity
ONLINE=/sys/class/power_supply/usb/online
ORIG=$DATA_DIR/orig_cm
NIGHT=/sys/class/power_supply/battery/night_charging
TOPFLAG=$DATA_DIR/top_cut

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

# µA → mA 字符串（保留一位小数），仅用于日志显示
ua2ma() {
  v=$1; s=
  [ "$v" -lt 0 ] && { s=-; v=$((-v)); }
  echo "${s}$((v / 1000)).$(((v % 1000) / 100))"
}

load_conf() {
  # 默认值
  ENABLED=0; SAMPLE_WINDOW=60; SAMPLE_COUNT=5; DEADBAND_MA=50
  STEP_MA=30; MIN_CM_MA=50; MAX_CM_MA=500; BATT_MAX=95; BATT_MIN=20
  BIG_MA=100; MAX_ADJ_MA=800; INIT_CM_MA=100; NORMAL_CM_MA=22000
  PLUG_POLL=30; LOG_MAX_LINES=400
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
  case "$BIG_MA" in ''|*[!0-9]*) BIG_MA=100;; esac
  case "$MAX_ADJ_MA" in ''|*[!0-9]*) MAX_ADJ_MA=800;; esac
  case "$INIT_CM_MA" in ''|*[!0-9]*) INIT_CM_MA=100;; esac
  case "$NORMAL_CM_MA" in ''|*[!0-9]*) NORMAL_CM_MA=22000;; esac
  case "$PLUG_POLL" in ''|*[!0-9]*|0) PLUG_POLL=30;; esac
  [ "$MAX_CM_MA" -lt "$MIN_CM_MA" ] && MAX_CM_MA=$MIN_CM_MA
  # 电量上下限必须留出差距：下限≥上限会同时命中"到顶断电"和"低电量充满"，
  # 逻辑互相打架（实测用户填反后表现为一到上限就断电、永远不悬浮）
  [ "$BATT_MIN" -ge "$BATT_MAX" ] && BATT_MIN=$((BATT_MAX - 5))
  [ "$BATT_MIN" -lt 5 ] && BATT_MIN=5
  # 断电恢复阈值 = 上限低 2 格点。到顶断电后要掉到这里才恢复，
  # 避免"掉 1% 就恢复→又充到顶"的夜间横跳（例：90 → 88 才恢复）
  BATT_RESUME=$(( BATT_MAX - 2 ))
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

# 把限流还原成开启前的原始值。
# 低电量暂停时必须调用：否则钳住的电流会让系统"看似在充、实际充不进"，
# 电量永远到不了阈值，只能靠重启开关（走 ctl 的还原逻辑）才能恢复。
# 放开限流：直接写原厂正常上限（22000mA）。
# 不再依赖 orig_cm 文件——之前 daemon 没走 ctl 启动时文件不存在，
# 还原逻辑被跳过，导致「日志说放开、实际还钳着」。
restore_cm() {
  o=$((NORMAL_CM_MA * 1000))
  now=$(cat "$CM" 2>/dev/null)
  [ "$now" = "$o" ] && return 0
  chmod 666 "$CM" 2>/dev/null
  echo "$o" > "$CM" 2>/dev/null
  return 0
}

echo $$ > "$PIDF"
load_conf
log "=== daemon start pid=$$ window=${SAMPLE_WINDOW}s count=${SAMPLE_COUNT} ==="

# 可打断的等待：WebUI 保存设置 / 切预设后发 SIGUSR1，立刻中断当前 sleep，
# 让主循环用新配置从第一轮重新开始（不用等本周期结束）。
# 实现：sleep 放后台 + wait，信号来了 kill 掉 sleep，wait 立刻返回。
SLEEP_PID=""
trap 'RESTART=1; if [ -n "$SLEEP_PID" ]; then kill "$SLEEP_PID" 2>/dev/null; fi' USR1
nap() {
  sleep "${1:-30}" &
  SLEEP_PID=$!
  wait "$SLEEP_PID" 2>/dev/null
  SLEEP_PID=""
}

INITED=0
LAST_ONLINE=""
LAST_ENABLED=""
RESTART=0
SKIP_HOLD_TICK=0
TICK=0

while true; do
  TICK=$((TICK + 1))
  load_conf

  # 收到 SIGUSR1（保存/切预设）→ 用新配置从第一轮重新开始
  if [ "$RESTART" = "1" ]; then
    RESTART=0
    INITED=0
    LAST_ONLINE=""
    # 保存设置/切预设是用户主动等着的，跳过 60s 初始保持，立刻用新参数采样。
    # 只对「本轮」有效：若本轮因故（如低电量）continue 没走到初始化块，
    # 下一轮 TICK 变了标志自动失效——否则残留到后续真·快充切入时会漏掉 60s 保护。
    SKIP_HOLD_TICK=$TICK
    log "配置已更新，重新开始周期"
  fi

  # 开关关闭 → 若之前开着，把电流上限还原，退出循环前的清理由 ctl 负责
  if [ "$ENABLED" != "1" ]; then
    if [ "$LAST_ENABLED" = "1" ]; then
      log "ENABLED=0，停止调整"
      INITED=0
    fi
    LAST_ENABLED=0
    nap 10
    continue
  fi
  LAST_ENABLED=1

  # 没插电 → 等
  on=$(cat "$ONLINE" 2>/dev/null)
  if [ "$on" != "1" ]; then
    if [ "$LAST_ONLINE" != "0" ]; then
      # 拔电时清掉"到顶断电"标记：否则插回来会带着 night=1，
      # 表现成"插电却不充电"，要等下一轮才解除
      if [ "$(cat "$TOPFLAG" 2>/dev/null)" = "1" ]; then
        echo 0 > "$NIGHT" 2>/dev/null
        rm -f "$TOPFLAG" 2>/dev/null
        log "[拔电] 已清除到顶断电标记（避免插回后 night=1 不充电）"
      fi
      log "[拔电] 未检测到充电器，暂停（每 ${PLUG_POLL}s 复查一次，插上自动恢复）"
      LAST_ONLINE=0
      INITED=0
    fi
    # 插电检测周期由 PLUG_POLL 控制（默认 30s，可在界面调）。
    # 默认从 10 调到 30 是为了省电；想要插电秒发现就调小。
    nap "$PLUG_POLL"
    continue
  fi
  # 重新插电 → 重置，下轮重新初始化
  if [ "$LAST_ONLINE" = "0" ]; then
    log "[插电] 检测到充电器接入，重新初始化 CM 并开始悬浮"
    INITED=0
  fi
  LAST_ONLINE=1

  cap=$(cat "$CAP" 2>/dev/null)
  case "$cap" in ''|*[!0-9]*) cap=0;; esac

  if [ "$cap" -gt "$BATT_MAX" ]; then
    # 超过上限才断：等于上限时仍归悬浮（CM 会压到平衡点，不再往上充）
    if [ "$(cat "$TOPFLAG" 2>/dev/null)" != "1" ]; then
      chmod 666 "$NIGHT" 2>/dev/null
      echo 1 > "$NIGHT" 2>/dev/null
      echo 1 > "$TOPFLAG" 2>/dev/null
      log "[到顶] 电量 ${cap}% > 上限 ${BATT_MAX}%，已断电；等回落到 ${BATT_RESUME}% 才恢复（迟滞 $((BATT_MAX-BATT_RESUME))%）"
    fi
    nap "${SAMPLE_WINDOW}"
    continue
  fi
  # 曾因到顶断电：必须回落到均值以下才解除。
  # 直接掉 1% 就恢复会造成"90 断 / 89 充 / 90 断"的夜间横跳。
  if [ "$(cat "$TOPFLAG" 2>/dev/null)" = "1" ]; then
    if [ "$cap" -gt "$BATT_RESUME" ]; then
      nap "${SAMPLE_WINDOW}"
      continue
    fi
    echo 0 > "$NIGHT" 2>/dev/null
    rm -f "$TOPFLAG" 2>/dev/null
    log "[恢复] 电量 ${cap}% <= 恢复线 ${BATT_RESUME}%，解除断电，重新初始化 CM 进入悬浮"
    INITED=0
  fi
  if [ "$cap" -lt "$BATT_MIN" ]; then
    # 低电量优先充满：必须放开限流。判断用「当前 CM 是否已经是正常值」，
    # 不看 orig_cm 文件（那个文件在非 ctl 启动时可能不存在）
    want=$((NORMAL_CM_MA * 1000))
    c_now=$(cat "$CM" 2>/dev/null)
    if [ "$c_now" != "$want" ]; then
      restore_cm
      log "[低电量] 电量 ${cap}% < 下限 ${BATT_MIN}%，已放开限流至正常充电（${NORMAL_CM_MA}mA，优先充满）；充到 ${BATT_MIN}% 会重新限流"
      INITED=0
    else
      log "[低电量] 电量 ${cap}% < 下限 ${BATT_MIN}%，已处于正常充电，暂停采样（30s 后复查；切预设会立即打断）"
    fi
    # 30 秒：充到下限需要时间，不需要太频繁；切预设会被 SIGUSR1 立刻打断
    nap 30
    continue
  fi

  lo=$((MIN_CM_MA * 1000)); hi=$((MAX_CM_MA * 1000))

  # 首次进入 → 直接用经验起点 INIT_CM_MA（默认 100mA）。
  # 不用「当前净电流」当起点：CM 是上限，设成当前流入量等于不限制，
  # 那一轮完全没有限制作用（系统本来就在那个电流上充）。
  # 实测这台平板的平衡点在 60~270mA 之间，从 100 起步低负载基本一轮到位；
  # 高负载时会先放电一阵，靠后面的比例逼近快速爬升，也比高位起步少绕几轮。
  # 下限必须避开失效区：实测 CM 低于约 40 时驱动会忽略该值、反而全速充。
  if [ "$INITED" != "1" ]; then
    init=$((INIT_CM_MA * 1000))
    [ "$init" -lt "$lo" ] && init=$lo
    [ "$init" -gt "$hi" ] && init=$hi
    write_cm "$init"
    log "初始化 CM=$(ua2ma "$init")mA（经验起点）"
    INITED=1
    # 刚从快充切到限流时，写 CM 会触发 PD 重新协商、充电断约一分钟。
    # 这段时间采样会把"断充"误判成大幅偏离，下一轮就大步调整、CM 突然波动。
    # 所以保持初始 CM 60 秒不采样，让 PD 稳定后再按设定参数采样。
    #
    # 切预设/保存设置（SIGUSR1）：初始 CM 已经立即写入（参数马上生效），
    # 但同样不能在暂态期采样。睡眠预设 SAMPLE_COUNT=1，"立即采样"就是抓单个
    # 暂态点直接矫正（实测把 INIT_CM=50 一步改成 55）。改为睡满一个完整采样
    # 窗口再采样：初始 CM 立即生效，但矫正要等这个周期过去——符合"过了周期再写"。
    if [ "$SKIP_HOLD_TICK" = "$TICK" ]; then
      SKIP_HOLD_TICK=0
      log "切预设：初始 CM 已生效，保持一个采样周期(${SAMPLE_WINDOW}s)后再采样矫正"
      nap "$SAMPLE_WINDOW"
    else
      log "保持初始 CM 60 秒后开始采样"
      nap 60
    fi
    continue
  fi

  # 采样
  interval=$((SAMPLE_WINDOW / SAMPLE_COUNT))
  [ "$interval" -lt 1 ] && interval=1
  sum=0
  i=0
  while [ "$i" -lt "$SAMPLE_COUNT" ]; do
    # 采样中收到 SIGUSR1（保存/切预设）：上一轮 nap 已被 trap 打断，
    # 这里立刻跳出，别再把剩余采样点睡完才生效（COUNT=3 时最坏多等 20s）
    [ "$RESTART" = "1" ] && break
    c=$(cat "$CUR" 2>/dev/null)
    case "$c" in -*) ok=1;; ''|*[!0-9-]*) ok=0;; *) ok=1;; esac
    if [ "$ok" = "1" ]; then
      sum=$((sum + c))
    fi
    i=$((i + 1))
    [ "$i" -lt "$SAMPLE_COUNT" ] && nap "$interval"
  done
  # 采样被 SIGUSR1 打断（配置刚改）→ 本轮数据作废，回顶部用新配置重来
  [ "$RESTART" = "1" ] && continue
  avg=$((sum / SAMPLE_COUNT))

  cm=$(cat "$CM" 2>/dev/null)
  case "$cm" in ''|*[!0-9]*) cm=$((MIN_CM_MA * 1000));; esac
  cm_before=$cm

  db=$((DEADBAND_MA * 1000))
  step=$((STEP_MA * 1000))
  big=$((BIG_MA * 1000))
  adj=0
  if [ "$avg" -lt "-$db" ]; then
    # 还在充（净电流为负）→ 上限调小
    if [ "$avg" -lt "-$big" ]; then
      # 偏离大：按差值比例大步逼近。
      # 不能直接 cm+=avg（全量）：充电电流有惯性，CM 改了电池侧要过一会儿才跟上，
      # 砍全量必然过冲、再反向过冲，实测会在 20mA 和 400mA 之间反复横跳。
      # 取 60% 并限制单次幅度，几轮就能收敛且不震荡。
      d=$((avg * 6 / 10)); cm=$((cm + d)); adj=-2
    else
      cm=$((cm - step)); adj=-1
    fi
  elif [ "$avg" -gt "$db" ]; then
    # 在放电（净电流为正）→ 上限调大
    if [ "$avg" -gt "$big" ]; then
      d=$((avg * 6 / 10)); cm=$((cm + d)); adj=2
    else
      cm=$((cm + step)); adj=1
    fi
  fi

  # 单次调整幅度上限：防止一次挪太多导致来回震荡
  maxadj=$((MAX_ADJ_MA * 1000))
  if [ "$adj" = "-2" ] || [ "$adj" = "2" ]; then
    [ "$d" -gt "$maxadj" ] && cm=$((cm_before + maxadj))
    [ "$d" -lt "-$maxadj" ] && cm=$((cm_before - maxadj))
  fi

  # 限幅
  [ "$cm" -lt "$lo" ] && cm=$lo
  [ "$cm" -gt "$hi" ] && cm=$hi
  # 限幅后和原值相同 = 已抵到设定的电流下限/上限，调不动了。
  # adj 归零：跳过 write_cm，日志也如实显示没动作。
  # 判据用限幅后的实际值（lo/hi 来自配置），不写死任何具体数值。
  [ "$cm" = "$cm_before" ] && adj=0

  if [ "$adj" != "0" ]; then
    write_cm "$cm"
  fi
  case "$adj" in
    -2|2) tag='大步' ;;
    *)    tag='' ;;
  esac
  # 日志里把净电流符号翻成和界面一致：正=充电、负=放电。
  # 内部 avg 仍是节点原始值（负=充），控制逻辑全部不动，只改这里显示。
  log "cap=${cap}% avg=$(ua2ma $((-avg)))mA cm=$(ua2ma "$cm")mA adj=${adj}${tag:+ $tag}"

  # 补齐周期：采样循环里只在采样点之间睡了 COUNT-1 次，
  # 这里再睡最后一次，让「写一次电流」的真正间隔 = SAMPLE_WINDOW。
  # （之前 COUNT=3/WINDOW=30 时实际只睡 2×10=20s，写电流频率比设定快 1/3。）
  # 注意：SIGUSR1 打断同样会走 nap，下一轮顶部 RESTART 生效。
  nap "$interval"
done
