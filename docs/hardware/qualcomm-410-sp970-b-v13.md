# 高通 410 (MSM8916) 随身 WiFi 棒子 (丝印 SP970-B-V13) 适配与加固指南

> 本指南针对搭载高通骁龙 410 (MSM8916) 芯片、主板丝印为 **SP970-B-V13** 的常见 USB 随身 WiFi 棒子，在刷入 Debian / Armbian 固件并部署 VoHive 时遇到的掉卡、搜网死锁、CPU 100% 负载发烫及境外漫游卡防跑流量等常见问题提供完整说明与解决方案。所有相关脚本均已集成在项目代码仓库的 [`scripts/`](file:///D:/OT/vohive-open/scripts) 目录下。

---

## 硬件与固件特征
- **主控平台**: Qualcomm Snapdragon 410 (MSM8916 / 4× Cortex-A53, ARM64 / aarch64)
- **主板丝印型号**: **`SP970-B-V13`** (板载通常有 SP970-B-V13 丝印字样)
- **基带固件版本**: `M8916-BP_SP970-B-V13_CT_V4.3_20220310 1 [Jul 9 2021 15:09:09]` (常见为中国电信定制基带固件)
- **接口节点**:
  - QMI 控制口: `/dev/wwan0qmi0`
  - AT 命令终端: `/dev/wwan0at0`
  - 网络数据接口: `wwan0`
- **默认 Web 端口**: **`7676`**

---

## 仓库配套脚本清单

| 脚本 / 源码路径 | 功能说明 |
| :--- | :--- |
| [`scripts/install.sh`](file:///D:/OT/vohive-open/scripts/install.sh) | **VoHive 一键全自动部署脚本**。自动识别架构、下载/部署二进制、配置默认端口 **7676**，若检测到高通棒子自动执行硬件加固。 |
| [`scripts/hardware/sp970-setup.sh`](file:///D:/OT/vohive-open/scripts/hardware/sp970-setup.sh) | **SP970 专用硬件全自动初始化与加固脚本**。实现频段锁 Band 1+3 (剔除电信 Band 5)、自动选网、清除 CTNET 承载冲突、注册 `modem-init.service` 开机常驻自启。 |
| [`scripts/hardware/fix-cpu-loop.sh`](file:///D:/OT/vohive-open/scripts/hardware/fix-cpu-loop.sh) | **CPU 100% 狂转高负载急救脚本**。瞬间解除 NetworkManager 对 modem 蜂窝接口的无限自动拨号死循环，清理僵死进程，使设备恢复常温（Load < 0.2）。 |
| [`cmd/lock-band3/main.go`](file:///D:/OT/vohive-open/cmd/lock-band3/main.go) | **LTE 频段锁定工具源码**。使用 QMI NAS 协议将 `LTEBandPreference` 永久固化为 `0x05`（Band 1 + Band 3），GitHub Actions 编译产物中直接提供 `lock-band3_arm64`。 |

---

## 核心痛点与技术解决方案

### 1. 境外卡 / 联通卡搜网死锁（频段优先级陷阱）
- **现象**: 插入境外漫游卡（如爱沙尼亚卡、英国卡等）或中国联通卡后，设备始终停留在 `not-registered-searching`，信号显示极弱或断续，甚至错误显示为中国电信。
- **根因**: MSM8916 电信定制固件默认的 LTE 频段偏好掩码为 `0x15`（包含 Band 1、Band 3、Band 5）。基带自动搜网时会优先接入信号极强的电信 850MHz (Band 5, EARFCN 2452)。由于漫游卡在电信基站被核心网拒绝 (`EMM attach failed`)，基带进入 3GPP T3402 长时间退避计时器，导致射频死锁在 Band 5，不再搜寻联通 Band 3。
- **修复**: 使用 QMI 频段工具 `lock-band3` 将基带 `LTEBandPreference` 设定为 `0x05`（仅允许 Band 1 + Band 3，彻底剔除电信 Band 5）。基带开机即可在 2~3 秒内精准接入中国联通主力 1800MHz 频段 (Band 3, EARFCN 1500)，信号强度可达 -70 多 dBm，SINR > 18 dB。

### 2. NetworkManager 无限重拨导致 CPU 100% 狂转
- **现象**: 系统负载 (Load Average) 飙升至 4.0 以上，`NetworkManager`、`dbus-daemon`、`polkitd` 和 `ModemManager` 占用极高 CPU，棒子发热严重、降频卡死。
- **根因**: 系统检测到 `wwan0qmi0` 后，默认蜂窝配置会在基带未就绪时陷入每秒数十次的自动重试循环 (`disconnected -> prepare -> disabled`)。
- **修复**:
  1. 彻底禁用原生 `ModemManager` (`systemctl disable --now ModemManager`)，防止其与 VoHive 抢占 QMI/AT 端口。
  2. 将 `/etc/NetworkManager/system-connections/modem.nmconnection` 的 `autoconnect` 和 `autoconnect-retries` 设为 `false` 和 `0`。修复后系统负载稳定在 0.1~0.2，恢复常温运行。

### 3. USIM Provisioning 会话掉线（掉卡）
- **现象**: 开机时经常提示 SIM 卡未检测到 (`no-atr-received`) 或 SIM busy。
- **修复**: 严禁在初始化时下发破坏性的基带 `low-power` 模式。必须使用 QMI UIM 显式激活卡槽 1 的 `primary-gw-provisioning` 会话并置为 online。

### 4. 境外漫游卡防流量扣费（纯驻网收短信）
- **需求**: 大多数用户将海外卡插在棒子上仅用于接收验证码与短信，高额数据漫游流量极易扣费。
- **修复**:
  1. 脚本彻底清除电信默认固化的 CTNET 承载 (`AT+CGDCONT=1,"IPV4V6",""`)。
  2. 保护卡策略数据库，严禁脚本强开数据开关，保持 `network_enabled: false`。
  3. VoHive 在蜂窝数据关闭状态下，仅维持射频物理层驻网（中国联通）与 NAS 短信接收通道，实现 **0 字节流量消耗、短信 100% 畅通**。

### 5. 选网模式与开机自愈全闭环
- **修复**:
  - VoHive 内部已支持将 `operator_selection_mode: manual` 与 `operator_selection_plmn: "46001"` 持久化写入 `config.yaml`，重启不丢失选网。
  - 配置 `modem-init.service` (`Before=vohive.service`)，在开机阶段首先完成卡槽激活、锁频与选网，VoHive 启动后直接进入正常服务状态。

---

## 快速复现与部署步骤（新板子一键配置）

如果你有另一块一模一样的 **SP970-B-V13** 棒子，刷好 Debian / Armbian 固件后，**只需执行一键部署脚本即可完成全部配置**：

### 极速部署（推荐）

1. **将编译好的发布资产上传至棒子 `/root` 目录**：
   - `vohive_dev_linux_arm64`（或 `vohive`）
   - `lock-band3_arm64`（可选，重命名为 `lock-band3`）
   - `mcc-mnc-table.json`（可选）
   - `install.sh`（位于项目 [`scripts/install.sh`](file:///D:/OT/vohive-open/scripts/install.sh)）

2. **在棒子上以 root 身份运行一键安装脚本**：
   ```bash
   bash install.sh
   ```

   **脚本将自动执行以下全套工序**：
   - 自动识别 ARM64 架构并安装 `socat`, `usbutils`, `pciutils`, `libqmi-utils`, `perl-base`。
   - 部署 `vohive` 到 `/opt/vohive/bin/vohive` 并配置软硬件权限。
   - 配置默认端口为 **`7676`**。
   - 自动生成包含 `wwan0` (QMI 后端) 的配置 `/opt/vohive/config/config.yaml`。
   - 自动触发高通 SP970 专用硬件加固：
     - 禁用系统原生 `ModemManager`，消除接口抢占；
     - 根除 `NetworkManager` 自动拨号死循环，解除 CPU 100% 负载发热；
     - 设置 Band 1+3 频段锁，剔除电信 Band 5 搜网死锁；
     - 注册 `modem-init.service` 开机常驻自启服务；
     - 保持蜂窝数据网络关闭，杜绝高额漫游资费。
   - 启动并启用 `vohive.service`。

3. **进入 VoHive Web 页面验证**：
   - 浏览器访问：`http://棒子IP:7676`
   - 默认账号：`admin` / `admin`
   - 检查设备状态：已稳定锁定在“中国联通 (46001)”，信号强度通常在 -70 ~ -80 dBm。
   - 检查蜂窝网络：显示为未连接 / 关闭状态（纯短信零流量）。
