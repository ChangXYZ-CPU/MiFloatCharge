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

load_conf() {
  # 默认值
  ENABLED=0; SAMPLE_WINDOW=60; SAMPLE_COUNT=5; DEADBAND_MA=50
  STEP_MA=30; MIN_CM_MA=50; MAX_CM_MA=500; BATT_MAX=95; BATT_MIN=20
  BIG_MA=100; MAX_ADJ_MA=800; INIT_CM_MA=100; NORMAL_CM_MA=22000
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
  case "$BIG_MA" in ''|*[!0-9]*) BIG_MA=100;; esac
  case "$MAX_ADJ_MA" in ''|*[!0-9]*) MAX_ADJ_MA=800;; esac
  case "$INIT_CM_MA" in ''|*[!0-9]*) INIT_CM_MA=100;; esac
  case "$NORMAL_CM_MA" in ''|*[!0-9]*) NORMAL_CM_MA=22000;; esac
  [ "$MAX_CM_MA" -lt "$MIN_CM_MA" ] && MAX_CM_MA=$MIN_CM_MA
  # 电量上下限必须留出差距：下限≥上限会同时命中"到顶断电"和"低电量充满"，
  # 逻辑互相打架（实测用户填反后表现为一到上限就断电、永远不悬浮）
  [ "$BATT_MIN" -ge "$BATT_MAX" ] && BATT_MIN=$((BATT_MAX - 5))
  [ "$BATT_MIN" -lt 5 ] && BATT_MIN=5
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
      # 拔电时清掉"到顶断电"标记：否则插回来会带着 night=1，
      # 表现成"插电却不充电"，要等下一轮才解除
      if [ "$(cat "$TOPFLAG" 2>/dev/null)" = "1" ]; then
        echo 0 > "$NIGHT" 2>/dev/null
        rm -f "$TOPFLAG" 2>/dev/null
        log "拔电，已清除断电标记"
      fi
      log "未插电，暂停"
      LAST_ONLINE=0
      INITED=0
    fi
    # 10 秒而不是 30：拔电时没有充电任务，多唤醒几次代价很小，
    # 但插回后能更快被感知（实测 30 秒会让用户以为"插了没反应"）
    sleep 10
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

  if [ "$cap" -gt "$BATT_MAX" ]; then
    # 超过上限才断：等于上限时仍归悬浮（CM 会压到平衡点，不再往上充）
    if [ "$(cat "$TOPFLAG" 2>/dev/null)" != "1" ]; then
      chmod 666 "$NIGHT" 2>/dev/null
      echo 1 > "$NIGHT" 2>/dev/null
      echo 1 > "$TOPFLAG" 2>/dev/null
      log "电量 ${cap}% > ${BATT_MAX}%，已断电（等回落到 ${BATT_MAX}% 及以下）"
    fi
    sleep "${SAMPLE_WINDOW}"
    continue
  fi
  # 曾因到顶断电，现在已回落 → 解除
  if [ "$(cat "$TOPFLAG" 2>/dev/null)" = "1" ]; then
    echo 0 > "$NIGHT" 2>/dev/null
    rm -f "$TOPFLAG" 2>/dev/null
    log "电量 ${cap}% 已回落，解除断电，重新悬浮"
    INITED=0
  fi
  if [ "$cap" -lt "$BATT_MIN" ]; then
    # 低电量优先充满：必须放开限流。判断用「当前 CM 是否已经是正常值」，
    # 不看 orig_cm 文件（那个文件在非 ctl 启动时可能不存在）
    want=$((NORMAL_CM_MA * 1000))
    c_now=$(cat "$CM" 2>/dev/null)
    if [ "$c_now" != "$want" ]; then
      restore_cm
      log "电量 ${cap}% < ${BATT_MIN}%，已放开限流（${NORMAL_CM_MA}mA，优先充满）"
      INITED=0
    else
      log "电量 ${cap}% < ${BATT_MIN}%，暂停（低电量优先充满）"
    fi
    # 30 秒：充到下限需要时间，不需要太频繁；但 60 秒会让切预设后响应太钝
    sleep 30
    continue
  fi

  lo=$((MIN_CM_MA * 1000)); hi=$((MAX_CM_MA * 1000))
  # 物理下限：实测低于 50mA 驱动会关闭充电（电池转为放电），写多少都一样。
  # 用户仍可在配置里填更低的值（尊重设置），但实际执行不会低于 50。
  [ "$lo" -lt 50000 ] && lo=50000

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
    log "初始化 CM=${init}µA（经验起点）"
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

  if [ "$adj" != "0" ]; then
    write_cm "$cm"
  fi
  case "$adj" in
    -2|2) tag='大步' ;;
    *)    tag='' ;;
  esac
  log "cap=${cap}% avg=${avg}µA cm=${cm}µA adj=${adj}${tag:+ $tag}"
done
