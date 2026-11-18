#!/usr/bin/env bash
# 打包模块：读 module/module.prop 的 version，生成 MiFloatCharge-<版本>.zip
# zip 内是平铺结构（module.prop 在根），符合 Magisk 模块安装规范
set -e
cd "$(dirname "$0")"

VER=$(awk -F= '/^version=/{print $2}' module/module.prop | tr -d '\r')
[ -n "$VER" ] || { echo "读不到版本号"; exit 1; }
OUT="MiFloatCharge-${VER}.zip"
[ -f "$OUT" ] && rm -f "$OUT"

python - "$OUT" "$VER" <<'PY'
import os, sys, zipfile, hashlib

out, ver = sys.argv[1], sys.argv[2]
root = os.path.join(os.path.dirname(os.path.abspath(__file__)), 'module')

README = """MiFloatCharge -- 悬浮供电 (平板)
版本: %s

把充电电流钳到约等于系统功耗，让电池不充不放（净电流约 0），
功耗全部由适配器承担。电池全程几乎不参与充放电，发热和老化都降到最低。

原理：写 /sys/class/power_supply/battery/constant_charge_current_max，
把给电池的电流上限压到与系统耗电相当。

Magisk / KernelSU / APatch 均可，纯脚本（含 WebUI），不安装任何 App。
实测 小米平板5 Pro / HyperOS / Magisk 30.6；其他暴露该节点的机型理论上可用。

安装后默认不启用（config.conf 里 ENABLED=0），需手动开启：
  Magisk 点模块「操作」按钮（装了 KsuWebUI 会直接开图形界面）
  或执行 sh /data/adb/modules/float_charge/bin/float-ctl.sh start

开源地址: https://github.com/ChangXYZ-CPU/MiFloatCharge
使用说明 / 参数详解 / 免责声明见仓库 README.md 与 docs/参数说明.md。

修改系统充电行为有风险，请自行承担。安装前请备份数据。
""" % ver

SKIP = {'.DS_Store', 'Thumbs.db'}
SKIP_EXT = ('.zip', '.pyc')

files = []
for dirpath, dirnames, filenames in os.walk(root):
    dirnames[:] = [d for d in dirnames if d not in ('__pycache__', '.git')]
    for name in filenames:
        if name in SKIP or name.endswith(SKIP_EXT):
            continue
        full = os.path.join(dirpath, name)
        rel = os.path.relpath(full, root)
        files.append((full, rel))
files.sort(key=lambda x: x[1])

with zipfile.ZipFile(out, 'w', zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for full, rel in files:
        zi = zipfile.ZipInfo(rel)
        # 脚本保持可执行
        mode = 0o755 if rel.endswith('.sh') else 0o644
        zi.external_attr = (0o100000 | mode) << 16
        with open(full, 'rb') as fh:
            z.writestr(zi, fh.read(), compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)
    z.writestr('README.txt', README, compress_type=zipfile.ZIP_DEFLATED, compresslevel=9)

h = hashlib.md5(open(out, 'rb').read()).hexdigest()
print("打包完成: %s" % out)
print("大小   : %d bytes" % os.path.getsize(out))
print("MD5    : %s" % h)
print("文件   :")
for _, rel in files:
    print("         %s" % rel)
print("         README.txt")
PY
