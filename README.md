# MiFloatCharge — 悬浮供电（平板）

Magisk 模块：把充电电流钳到 ≈ 系统功耗，**让电池不充不放**（净电流 ≈ 0），
功耗全部由适配器承担。电池全程几乎不参与充放电，发热和老化都降到最低。

和"真旁路"不同，它不需要驱动提供旁路位，只靠一个可写的电流上限节点，
**任何暴露 `constant_charge_current_max` 的小米设备理论上都能用**。

- 实测机型：**小米平板 5 Pro**（`elish` 平台 / HyperOS / Magisk 30.6）
- 系统：实测 Android 13 + Magisk 30.6
- Root：**Magisk**（KernelSU / APatch 也能用，脚本不依赖特定 root 实现）
- 模块只有 shell 脚本 + WebUI，**不安装任何 App**

> 本人做这个模块是自用，可能因学业原因维护不及时，欢迎提 Issue，但不保证响应时效。

## 原理

平板的供电拓扑是：**适配器 → 充电 IC → 电池 → 系统负载**（电池与系统并联）。

```
适配器输入 = 系统耗电 + 电池充电电流
电池净电流 = 充电电流 − 系统耗电
```

把 `constant_charge_current_max`（给电池的电流上限）压到约等于系统耗电时：

```
充电电流 ≈ 系统耗电  →  电池净电流 ≈ 0
```

电池既不充也不放，系统功耗全部由适配器直供。

### 实测数据（小米平板5 Pro，PD 充电器，屏幕点亮，系统功耗约 370mA）

| CM 设定 | 电池净电流 | 状态 |
|---|---|---|
| 600 mA 以上 | -4.5 A | 限流失效，仍是满速快充 |
| 300 mA | -268 mA | 正常限流 |
| 150 mA | -114 mA | 正常限流 |
| 100 mA | -63 mA | 接近零点 |
| **50 ~ 80 mA** | **+13 ~ 15 mA** | **悬浮（净电流 ≈ 0）** |
| 40 mA 以下 | +310 mA | 滑入断充（驱动放弃充电） |

**注意死区**：CM 低于约 40mA 时，驱动会判定"这点电流不值得充"而直接放弃，
电池反而开始放电（+310mA）。所以模块有 `MIN_CM_MA` 下限，默认 50mA。

### 稳定性

CM 设 60mA 后连续采样 30 秒：

```
净电流: +15, +17, +17, +17, +17, +15, +15, +13, +13, +13 mA
输入:   390, 238, 305, 323, 248, 310, 256, 279, 345, 270 mA
电压:   5.10V（稳定）
电量:   91%（纹丝不动）
```

净电流波动在 ±2mA 内，电量 30 秒没有变化。持续观察 5~6 分钟，
电流上限**没有被系统重置**（该节点不属于 HAL 管理范围，没有服务回写它）。

## 为什么不用官方接口

小米充电 HAL（`vendor.xiaomi.hardware.micharge`）的完整可写路径清单里，
**没有 `constant_charge_current` 或 `constant_charge_current_max`**：

```
battery/charge_control_limit   ← PD 电压档位
battery/input_suspend          ← 断输入
battery/night_charging         ← 限充开关
battery/smart_batt
qcom-battery/{input_suspend, night_charging, cool_mode, power_max}
```

HAL 方法也只有 `setMiChargePath` / `setNightChargingState` /
`setInputSuspendState` / `setCoolModeState`，**没有 `setCurrent`**。

所以官方能力上限只是"到 80% 断充"，做不到任意电流限流。
本模块和 Scene 的充电调速一样，都是**绕过 HAL 直接写 sysfs**。

## 目录

```
module/                    模块本体（可直接打包成 zip 刷入）
  module.prop              模块信息
  config.conf              参数配置（运行时会被 daemon 周期重读）
  service.sh               开机自启（ENABLED=0 时直接退出，不占资源）
  action.sh                Magisk「操作」按钮：有 KsuWebUI 就直接打开图形界面
  uninstall.sh             卸载时还原电流上限，避免留下"一直限流"
  bin/float-daemon.sh      守护主循环：采样 → 求平均 → 增量调整 → 写节点
  bin/float-ctl.sh         控制接口：start / stop / toggle / status
  webroot/index.html       WebUI 单页（HTML 内联 JS，无外链）

docs/
  参数说明.md              每个参数的详细说明、常见调法、日志读法
  原理与实测.md            机制分析、官方接口调研、完整实测数据
  test.sh                  回归测试脚本（可逆，跑完自动还原）

build.sh                   打包：读 module/module.prop 版本号，生成 MiFloatCharge-v<版本>.zip
```

## 安装

1. 下载 `MiFloatCharge-v*.zip`
2. Magisk App → 模块 → 从本地安装
3. 重启

模块默认 `ENABLED=0`，**装完不会自动生效**，需要手动开启。

## 使用

### 图形界面（推荐）

装了 **KsuWebUI**（`io.github.a13e300.ksuwebui`）的话，
点模块卡片的「操作」按钮会**直接打开图形界面**：

- 大圆按钮一键开关
- 实时显示电量 / 电池净电流 / 电流上限 / 充电器状态
- 参数可视化调整，改完点保存
- 底部运行日志（首屏不显示，往上滑查看）

> KsuWebUI 虽然是 KernelSU 生态的工具，但它通过 `su` 执行命令，
> **Magisk 一样能用**。

### 命令行

```sh
# 开关
sh /data/adb/modules/float_charge/bin/float-ctl.sh start
sh /data/adb/modules/float_charge/bin/float-ctl.sh stop
sh /data/adb/modules/float_charge/bin/float-ctl.sh toggle
sh /data/adb/modules/float_charge/bin/float-ctl.sh status

# 看日志
tail -50 /data/adb/float_charge/float.log
```

### 改参数

编辑 `/data/adb/modules/float_charge/config.conf`，改完不用重启，下个采样周期自动生效。

最常用的两个：

```conf
SAMPLE_WINDOW=60   # 多久写一次电流（秒）。60 = 每 12 秒采 1 次，采满 5 次写 1 次
SAMPLE_COUNT=5     # 每个周期采样次数
```

完整参数见 **[docs/参数说明.md](docs/参数说明.md)**。

## 算法（增量反馈）

每个周期：

1. 采 `SAMPLE_COUNT` 次 `battery/current_now`（µA，负=充电，正=放电）
2. 求平均 `avg`
3. 按方向微调 `constant_charge_current_max`：
   - `avg < -死区` → 还在充，CM 减一个步长
   - `avg > +死区` → 在放电，CM 加一个步长
   - 落在死区内 → 不动
4. 限幅到 `[MIN_CM, MAX_CM]` 后写回

**为什么不用"断充测功耗再赋值"**：那样每轮都要让电池放电十几秒，
电池反复充放反而增加负担。增量反馈全程不断充，代价是收敛慢（几个周期到稳态）。

启动时从 `MIN_CM_MA`（50mA）起步，所以不会一上来就大量充电。

## 和 MiBypassCharge 的区别

| | [MiBypassCharge](https://github.com/ChangXYZ-CPU/MiBypassCharge)（K70） | 本项目（平板） |
|---|---|---|
| 手段 | 官方旁路位 `smart_chg` | 直接写 `constant_charge_current_max` |
| 电池电流 | 精确 0（驱动级旁路） | +13~17mA（噪声级） |
| 依赖 | 需要驱动暴露 `smart_chg` | 任意有电流上限节点的机器 |
| 稳定性 | 驱动保持，拔插不丢 | 依靠模块周期维持 |
| Root | 仅 KernelSU | Magisk / KSU / APatch |

K70 有官方旁路位所以能用真旁路；平板没有（`persist.vendor.smartchg` 为空、
`smart_chg` 节点不存在），只能退而求其次做"伪旁路"。

## 已知问题

- 反复快速修改充电电流，可能让 PD 协商掉到 5V 档、输入功率骤降，
  **需要物理拔插充电器**才能恢复
- 高电量（>90%，进入 CV 阶段）时，部分低电流设置会被驱动归零
- 部分机型 `constant_charge_current_max` 写入会被拒绝（日志有 `WARN 写CM失败`）
- 悬浮状态下电量基本不动；想正常充电就关掉模块

## 免责

修改系统充电行为有风险，详见 [DISCLAIMER.md](DISCLAIMER.md)。

## 许可

[GPL-3.0](LICENSE)
