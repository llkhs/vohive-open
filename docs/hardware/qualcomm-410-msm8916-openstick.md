# 高通 410 (MSM8916 / OpenStick) 随身 WiFi 全系硬件适配与加固指南

> 本指南针对搭载高通骁龙 410 (MSM8916) 芯片的各类 USB 随身 WiFi 棒子（包括但不限于 **UFI001B / UFI001C / UFI003 系列、SP970 / SP970-B-V13、UZ801、Handsome OpenStick** 等常见型号）。为在刷入 Debian / Armbian 固件并部署 VoHive 时遇到的掉卡、双卡槽切换、搜网死锁、CPU 100% 负载发烫及实体 eSIM / 境外漫游卡支持等常见问题提供完整的原理分析与官方一键加固方案。

---

## 一、支持的硬件板型与特征

高通 410 (MSM8916) 随身 WiFi 常见衍生板型庞大，硬件特征如下：

| 型号系列 | 典型板载丝印 | 常见基带版本 | 物理/板载卡槽特征 |
| :--- | :--- | :--- | :--- |
| **UFI 系列** | `UFI001C`, `UFI003`, `UFI_MB_V01` | `UFI003_CT`, `UFI001CT` | 多数带外部 Nano-SIM 卡槽 + 板载贴片 eSIM |
| **SP 系列** | `SP970-B-V13`, `SP970` | `SP970-B-V13_CT` | 常见外置 Nano-SIM 卡槽 |
| **UZ 系列** | `UZ801`, `UZ-801-V3` | `UZ801_V...` | 外置标准或 Micro/Nano SIM 卡槽 |
| **OpenStick** | `Handsome OpenStick`, 耕跃等 | 多种通用基带 | 开源固件最成熟，设备树原生支持 GPIO 控制 |

### 核心系统接口节点
- **QMI 控制接口**: `/dev/wwan0qmi0`
- **AT 命令终端**: `/dev/wwan0at0`
- **网络数据接口**: `wwan0`
- **默认 Web 管理端口**: **`7676`**

---

## 二、双卡槽控制引脚与实体卡/eSIM 切换（最核心）

MSM8916 随身 WiFi 板载通常集成了 **物理卡槽使能（EN）** 与 **多路复用切换（SEL）** 的 GPIO 引脚。在 Linux 系统下，这些引脚映射在 `/sys/class/leds/sim:*`：

- `sim:en`: 外部卡槽电源开关（**低电平有效 Active-Low**，写入 `0` 为开启供电，写入 `1` 为切断电源）
- `sim:sel`: 卡槽多路复用通道 1
- `sim:sel2`: 卡槽多路复用通道 2

### 1. 切换至外部 Nano-SIM 物理卡槽（含实体可写 eSIM 卡，如 5ber / 9esim / estk）
```bash
echo 0 > /sys/class/leds/sim:en/brightness    # 开启物理卡槽供电 (低电平有效)
echo 1 > /sys/class/leds/sim:sel/brightness   # 选通外部物理卡槽
echo 0 > /sys/class/leds/sim:en2/brightness
echo 0 > /sys/class/leds/sim:sel2/brightness
```

### 2. 切换至内部板载贴片 eSIM 芯片（如有）
```bash
echo 0 > /sys/class/leds/sim:en/brightness
echo 0 > /sys/class/leds/sim:sel/brightness
echo 0 > /sys/class/leds/sim:en2/brightness
echo 1 > /sys/class/leds/sim:sel2/brightness   # 选通板载贴片芯片
```

> **重要提示**：基带 DSP（`remoteproc0`）在系统启动极早期（约开机 2 秒）就会初始化 SIM 接口。因此，卡槽选通引脚必须通过 Systemd 早周期服务（`openstick-sim-switch.service`）固化在 `sysinit.target` 阶段执行，避免冷启动时由于没通电导致基带将卡标记为 `absent`。

---

## 三、仓库配套脚本清单

所有硬件相关加固脚本均已集成在 [`scripts/hardware/`](file:///D:/OT/vohive-open/scripts/hardware) 目录中：

| 脚本路径 | 功能说明 |
| :--- | :--- |
| **[`scripts/hardware/openstick-msm8916-setup.sh`](file:///D:/OT/vohive-open/scripts/hardware/openstick-msm8916-setup.sh)** | **高通 410 全系随身 WiFi 通用一键初始化与加固脚本**（推荐优先使用）。自动部署早周期 SIM 选通服务、根除 ModemManager 与 NetworkManager 冲突死循环、配置自适应 APN 与全自动选网、优化 512MB 内存及 VoHive CGroup 资源隔离。 |
| [`scripts/hardware/fix-cpu-loop.sh`](file:///D:/OT/vohive-open/scripts/hardware/fix-cpu-loop.sh) | **CPU 100% 狂转高负载急救脚本**。瞬间解除 NetworkManager 对 modem 蜂窝接口的无限自动拨号死循环，清理僵死进程，使设备恢复常温（Load < 0.2）。 |
| [`scripts/hardware/sp970-setup.sh`](file:///D:/OT/vohive-open/scripts/hardware/sp970-setup.sh) | SP970 系列历史兼容初始化脚本。 |
| [`scripts/install.sh`](file:///D:/OT/vohive-open/scripts/install.sh) | VoHive 全局安装部署脚本，自动识别 410 架构并调用硬件加固。 |

---

## 四、核心痛点与技术解决方案

### 1. 境外漫游卡 / 实体 eSIM 搜网与 APN 自适应
- **现象**: 插入境外漫游卡（如爱沙尼亚卡、英国卡等）或运营商纯流量卡后，始终停留在 `searching` 或 `registration-denied`。
- **根因**: 基带开机时 Attach APN 若为空或被固化为其他运营商 APN（如电信 `ctnet`），基站核心网鉴权直接拒网 (`EMM attach failed`)。
- **修复**: 在 `modem-init.sh` 中增加智能 IMSI 识别，开机自动动态配置对应的 LTE Attach APN：
  - 电信（MCC/MNC `46003`/`46011`）-> 自动写入 `ctlte`
  - 移动（MCC/MNC `46000`/`46002`/`46007`）-> 自动写入 `cmiot`
  - 联通（MCC/MNC `46001`/`46006`/`46009`）-> 自动写入 `wonet`
  - 国际漫游卡（如爱沙尼亚 MCC `248`）-> 自动写入 `globaldata`

### 2. 网页端搜网扫描报错 `QMI error: error=0x0046`
- **现象**: 在前端点击“扫描可用网络”，弹出 `QMI error: service=0x03 msg=0x0021 result=0x0001 error=0x0046`。
- **根因**: 高通基带内部若正处于后台自动搜网或 Attach 过程中，射频状态机被底层独占，外部发起 QMI 网络扫描会返回 `0x0046 (Device In Use)`。
- **修复**: VoHive 最新版本已增强容错：
  1. 识别 `0x0046` 繁忙状态并友好提示为“模组正在搜网或无线信令处理中，请稍后重试”；
  2. 若设备暴露了 AT 端口（`/dev/wwan0at0`），自动降级执行 `AT+COPS=?` 进行全网运营商扫描，完美绕过高通 QMI 状态机冲突。

### 3. NetworkManager 无限重拨导致 CPU 100% 狂转
- **现象**: 系统负载飙升至 4.0 以上，410 棒子剧烈发烫、严重降频卡死。
- **修复**:
  1. 彻底禁用原生 `ModemManager` (`systemctl disable --now ModemManager`)。
  2. 关闭蜂窝网卡的 `autoconnect` 并将 `autoconnect-retries` 设为 `0`。

### 4. 适配 512MB 极小内存环境（防 OOM Crash）
- **修复**:
  1. 配置虚拟内存换页策略：`vm.swappiness = 100`，`vm.vfs_cache_pressure = 50`，充分利用 zram；
  2. 在 `vohive.service` 中注入硬件资源隔离：
     ```ini
     [Service]
     MemoryMax=90M
     MemoryHigh=75M
     CPUQuota=70%
     Environment="GOMAXPROCS=2"
     ```

---

## 五、极速安装与部署

如果你手头有一块刷好 Debian / Armbian 的高通 410 随身 WiFi（MSM8916）：

### 推荐：使用一站式全量解压即用包
从 GitHub Releases 下载专为 410 / ARM64 打包的完整包：
```bash
# 下载并解压全量包
tar -zxvf vohive_openstick_arm64_bundle.tar.gz
cd vohive_openstick_arm64

# 执行一键加固与部署 (默认为外置 Nano-SIM / 实体 eSIM)
sudo bash hardware/openstick-msm8916-setup.sh
sudo bash install.sh
```
若使用板载贴片卡，加固命令换为：
```bash
sudo bash hardware/openstick-msm8916-setup.sh --internal-sim
```
安装完成后访问 `http://<棒子IP>:7676` 即可开始使用。
