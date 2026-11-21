#!/system/bin/sh
# test.sh — MiFloatCharge 回归测试
# 用法: su -c "sh test.sh"
#
# 会在真机上实际开关模块、读写电流节点，**跑完自动还原**（stop + 还原 CM）。
# 建议插着充电器跑，否则部分项会跳过。

MOD=/data/adb/modules/MiFloatCharge
CTL="$MOD/bin/float-ctl.sh"
DATA=/data/adb/MiFloatCharge
CFG="$MOD/config.conf"
BAT=/sys/class/power_supply/battery
CM=$BAT/constant_charge_current_max
CUR=$BAT/current_now
CAP=$BAT/capacity

PASS=0; FAIL=0; SKIP=0
pass(){ PASS=$((PASS+1)); echo "  [ok]   $1"; }
fail(){ FAIL=$((FAIL+1)); echo "  [FAIL] $1"; }
skip(){ SKIP=$((SKIP+1)); echo "  [skip] $1"; }

ORIG_CM=$(cat "$CM" 2>/dev/null)
ORIG_EN=$(grep '^ENABLED=' "$CFG" 2>/dev/null | cut -d= -f2)

restore(){
  sh "$CTL" stop >/dev/null 2>&1
  if [ -e "$CM" ] && [ -n "$ORIG_CM" ]; then
    chmod 666 "$CM" 2>/dev/null
    echo "$ORIG_CM" > "$CM" 2>/dev/null
  fi
  [ -n "$ORIG_EN" ] && [ -f "$CFG" ] && \
    sed -i "s|^ENABLED=.*|ENABLED=$ORIG_EN|" "$CFG" 2>/dev/null
}
trap 'echo ""; echo "中断，正在还原…"; restore; exit 1' INT TERM

echo "================================================"
echo " MiFloatCharge 回归测试"
echo " 原始 CM = $ORIG_CM µA   原始 ENABLED = $ORIG_EN"
echo "================================================"

# ---------------- 1. 环境 ----------------
echo ""
echo "[1] 环境"
if [ "$(id -u)" = "0" ]; then pass "root 权限"; else fail "不是 root"; fi

if [ -e "$CM" ]; then pass "节点存在: ${CM#$BAT/}"; else fail "节点不存在 $CM"; fi
[ -r "$CM" ] && pass "节点可读（$(cat $CM) µA）" || fail "节点不可读"

ONLINE=$(cat /sys/class/power_supply/usb/online 2>/dev/null)
if [ "$ONLINE" = "1" ]; then pass "已插充电器"; else skip "未插电，限流相关项会跳过"; fi

# 写入能力（写原值，不改状态）
chmod 666 "$CM" 2>/dev/null
if [ -n "$ORIG_CM" ]; then
  echo "$ORIG_CM" > "$CM" 2>/dev/null
  if [ "$(cat $CM)" = "$ORIG_CM" ]; then pass "节点可写（chmod 666 后）"; else fail "节点写不进去"; fi
fi

# ---------------- 2. 文件完整性 ----------------
echo ""
echo "[2] 模块文件"
[ -f "$MOD/module.prop" ] && pass "module.prop" || fail "缺 module.prop"
for k in id name version versionCode author; do
  grep -q "^$k=" "$MOD/module.prop" 2>/dev/null || fail "module.prop 缺 $k"
done
[ -f "$CFG" ] && pass "config.conf" || fail "缺 config.conf"
[ -f "$MOD/webroot/index.html" ] && pass "webroot/index.html" || fail "缺 WebUI 页面"
for f in "$MOD/service.sh" "$MOD/action.sh" "$MOD/uninstall.sh" \
         "$MOD/bin/float-daemon.sh" "$MOD/bin/float-ctl.sh"; do
  if [ -f "$f" ]; then pass "$(basename $f)"; else fail "缺 $(basename $f)"; fi
done
# 语法
bad=0
for f in "$MOD"/*.sh "$MOD"/bin/*.sh; do
  sh -n "$f" 2>/dev/null || { bad=1; fail "语法错误: $(basename $f)"; }
done
[ "$bad" = "0" ] && pass "全部脚本语法正确"

# ---------------- 3. 控制接口 ----------------
echo ""
echo "[3] 控制接口"
out=$(sh "$CTL" status 2>&1)
case "$out" in
  *开关*) pass "status 正常输出" ;;
  *) fail "status 输出异常" ;;
esac

sh "$CTL" stop >/dev/null 2>&1
sleep 1
sh "$CTL" start >/dev/null 2>&1
sleep 3
PID=$(cat "$DATA/daemon.pid" 2>/dev/null)
if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then
  pass "start 后 daemon 存活 (pid=$PID)"
else
  fail "start 后 daemon 没起来"
fi

if [ "$ONLINE" = "1" ]; then
  sleep 3
  cm=$(cat "$CM" 2>/dev/null)
  min=$(( $(grep '^MIN_CM_MA=' "$CFG" | cut -d= -f2) * 1000 ))
  if [ "$cm" = "$min" ]; then pass "初始化 CM=$cm（等于 MIN_CM）"; else skip "CM=$cm，可能已开始调整"; fi
else
  skip "未插电，跳过 CM 初始化检查"
fi

sh "$CTL" stop >/dev/null 2>&1
sleep 2
if [ -n "$PID" ] && [ -d "/proc/$PID" ]; then fail "stop 后 daemon 还活着"; else pass "stop 后 daemon 已退出"; fi

now=$(cat "$CM" 2>/dev/null)
if [ "$now" = "$ORIG_CM" ]; then pass "stop 后 CM 已还原 ($now)"; else fail "CM 没还原: $now != $ORIG_CM"; fi

# toggle 两次应回到原状态
sh "$CTL" toggle >/dev/null 2>&1; sleep 2
a=$(grep '^ENABLED=' "$CFG" | cut -d= -f2)
sh "$CTL" toggle >/dev/null 2>&1; sleep 2
b=$(grep '^ENABLED=' "$CFG" | cut -d= -f2)
if [ "$a" != "$b" ]; then pass "toggle 能来回切换"; else fail "toggle 没变化"; fi

# ---------------- 4. 配置 ----------------
echo ""
echo "[4] 配置读写"
w0=$(grep '^SAMPLE_WINDOW=' "$CFG" | cut -d= -f2)
sed -i "s|^SAMPLE_WINDOW=.*|SAMPLE_WINDOW=99|" "$CFG" 2>/dev/null
w1=$(grep '^SAMPLE_WINDOW=' "$CFG" | cut -d= -f2)
if [ "$w1" = "99" ]; then pass "配置可写"; else fail "配置写不进去"; fi
sed -i "s|^SAMPLE_WINDOW=.*|SAMPLE_WINDOW=$w0|" "$CFG" 2>/dev/null
w2=$(grep '^SAMPLE_WINDOW=' "$CFG" | cut -d= -f2)
if [ "$w2" = "$w0" ]; then pass "配置已还原 ($w2)"; else fail "配置还原失败"; fi

# ---------------- 5. 还原 ----------------
echo ""
echo "[5] 还原"
restore
sleep 2
fin=$(cat "$CM" 2>/dev/null)
if [ "$fin" = "$ORIG_CM" ]; then pass "最终 CM = $fin（已还原）"; else fail "最终 CM=$fin 未还原"; fi
PID2=$(cat "$DATA/daemon.pid" 2>/dev/null)
if [ -n "$PID2" ] && [ -d "/proc/$PID2" ]; then fail "daemon 仍在运行"; else pass "daemon 已停止"; fi

echo ""
echo "================================================"
echo " 结果: 通过 $PASS / 失败 $FAIL / 跳过 $SKIP"
echo " 当前 CM = $(cat $CM 2>/dev/null) µA"
echo "================================================"
[ "$FAIL" = "0" ] && exit 0 || exit 1
