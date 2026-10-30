# VoHive

[![License: PolyForm Noncommercial 1.0.0](https://img.shields.io/badge/License-PolyForm--Noncommercial--1.0.0-blue.svg)](https://polyformproject.org/licenses/noncommercial/1.0.0)
[![Go](https://img.shields.io/badge/Go-1.26%2B-00ADD8?logo=go)](go.mod)
[![Vue 3](https://img.shields.io/badge/Vue-3-42b883?logo=vue.js)](web/package.json)

> 面向高通 4G/LTE/5G 模组（移远 Quectel EC20/EC25/EC21/EG25/EM20、高通骁龙 410 等）的综合管理与代理服务平台。

VoHive 把模组热插拔管理、SOCKS5/HTTP 代理编排、短信全渠道收发、VoWiFi/IMS 通话、eSIM 全生命周期管理整合到一个独立服务中，并提供现代化响应式 Web 管理后台。

---

## 核心特性

| 模块 | 说明 |
| :--- | :--- |
| **多模组并发管理** | 支持 USB 热插拔自动发现（ttyUSB、QMI、MBIM）、多设备多卡实时状态监控。 |
| **轻量级代理引擎** | 内建高并发 SOCKS5 / HTTP 代理内核，基于 `SO_BINDTODEVICE` 按设备网卡严格绑定出站流量。 |
| **通信与短信中心** | 统一 Web 与 API 处理短信收发、会话与联系人管理、USSD 交互，短信落库可查。 |
| **eSIM 管理** | 通过 AT 指令通道直接管理 eSIM 芯片，支持 Profile 下载、启用、停用、重命名与删除。 |
| **全渠道告警通知** | 重要短信及系统告警可无缝推送至 Telegram、Bark、PushPlus、飞书 (Lark)、QQ、Email 等。 |
| **硬件优化与防护** | 原生集成高通 410 随身 WiFi 防掉卡、防电信 Band 5 搜网死锁、防 CPU 100% 重试发烫及漫游 0 流量保护。 |

---

## 快速使用方式

### 方式一：一键自动安装（推荐）

适用于通用 Linux 主机（Ubuntu/Debian/Armbian 等，支持 `amd64`、`arm64`、`armv7` 架构）以及高通 410 随身 WiFi 棒子。

#### 1. 在线克隆运行（最简单）：
```bash
git clone https://github.com/llkhs/vohive-open.git
cd vohive-open/scripts
sudo bash install.sh
```

#### 2. 离线整合包安装（推荐随身 WiFi 使用）：
从 [Releases 页面](https://github.com/llkhs/vohive-open/releases) 下载一站式全量包并解压安装：
```bash
tar -zxvf vohive_openstick_arm64_bundle.tar.gz
cd vohive_openstick_arm64
sudo bash install.sh
```

> **自动化特性**：`install.sh` 脚本会自动识别系统架构并拉取/安装必要依赖，配置默认端口为 **`7676`**；若检测到高通随身 WiFi 硬件，会自动应用频段锁定与降载防死锁调优。

---

### 方式二：Docker 容器运行

创建工作目录与基础配置：
```bash
mkdir -p vohive/{config,data,logs}
cp config/config.example.yaml vohive/config/config.yaml
cd vohive
```

创建并启动 `docker-compose.yml`：
```yaml
services:
  vohive:
    image: skyhotspur/vohive:${VOHIVE_TAG:-latest}
    container_name: vohive
    restart: unless-stopped
    network_mode: host
    privileged: true
    volumes:
      - ./config:/app/config
      - ./data:/app/data
      - ./logs:/app/logs
      - /dev:/dev
    environment:
      TZ: Asia/Shanghai
      CONFIG_PATH: /app/config/config.yaml
```

```bash
docker compose up -d
```

---

### 访问与服务管理

- **Web 管理界面**：浏览器访问 `http://<设备IP>:7676`
- **默认登录凭据**：用户名 `admin`，密码 `admin`（首次登录后请在“系统设置”中及时修改密码）。
- **常用服务控制命令（系统服务模式）**：
  ```bash
  sudo systemctl status vohive    # 查看运行状态
  sudo systemctl restart vohive   # 重启服务
  sudo journalctl -u vohive -f    # 实时查看运行日志
  ```

---

## 卸载方式

如需彻底移除 VoHive 服务及其运行环境，可根据部署方式按以下步骤操作：

### 1. 系统服务模式（脚本安装）的完全卸载

以 `root` 权限依次执行以下命令：

```bash
# 步骤 1：停止并彻底禁用 VoHive 主服务
sudo systemctl disable --now vohive 2>/dev/null || true

# 步骤 2：删除 systemd 服务注册文件并重载系统服务管理
sudo rm -f /etc/systemd/system/vohive.service
sudo systemctl daemon-reload

# 步骤 3：清理安装目录、二进制文件及数据文件
# （注意：如需保留短信记录或配置文件，请先备份 /opt/vohive/data 和 /opt/vohive/config）
sudo rm -rf /opt/vohive

# 步骤 4：（可选）若使用了随身 WiFi 硬件初始化守护服务，一并清理
sudo systemctl disable --now modem-init.service 2>/dev/null || true
sudo rm -f /etc/systemd/system/modem-init.service
sudo rm -f /usr/local/bin/modem-init.sh
sudo rm -f /usr/local/bin/lock-band3
sudo systemctl daemon-reload

echo "[✓] VoHive 及相关组件已完全卸载清理干净！"
```

---

### 2. Docker 部署模式的卸载

进入原 `docker-compose.yml` 所在的目录，执行：

```bash
# 停止并删除容器
docker compose down

# （可选）如需彻底清空所有本地数据与配置
cd .. && rm -rf vohive
```

---

## 硬件适配指南

- **[高通 410 (MSM8916 / OpenStick) 随身 WiFi 全系适配与加固指南](docs/hardware/qualcomm-410-msm8916-openstick.md)**: 全面支持搭载高通骁龙 410 (MSM8916) 芯片的各类随身 WiFi 设备（涵盖 **UFI001C, UFI003, SP970, UZ801, Handsome** 等系列），针对外部/板载双 SIM 槽切换、搜网死锁、CPU 100% 狂转高负载发烫、WiFi 休眠掉线以及实体/漫游 eSIM 卡支持等问题，提供完整的根因分析、引脚固化与一键部署加固方案。

---

## 本地源码构建

```bash
# 1. 编译前端资源
npm ci --prefix web
npm run build --prefix web
rm -rf internal/web/dist
mkdir -p internal/web
cp -R web/dist internal/web/dist

# 2. 编译各架构后端二进制
# AMD64 (x86_64)
GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=amd64 \
  go build -trimpath -buildvcs=false -tags "with_utls nomsgpack" \
  -o dist/vohive_linux_amd64 ./cmd/vohive

# ARM64 (aarch64)
GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
  go build -trimpath -buildvcs=false -tags "with_utls nomsgpack" \
  -o dist/vohive_linux_arm64 ./cmd/vohive

# ARMv7 (32位 ARM)
GOWORK=off CGO_ENABLED=0 GOOS=linux GOARCH=arm GOARM=7 \
  go build -trimpath -buildvcs=false -tags "with_utls nomsgpack" \
  -o dist/vohive_linux_armv7 ./cmd/vohive
```

---

## 典型应用场景

- **私有 IP 代理池**: 单主机挂载多张物理 SIM 卡或多张 eSIM，每张网卡对应独立的 SOCKS5/HTTP 实例，组建自己的移动网络代理池。
- **统一接码/验证码中心**: Web 界面与 API 并行收发多卡短信，并通过 Webhook/Bot 实时推送到个人终端或自建业务平台。
- **VoWiFi 零信号通信**: 地下室、弱覆盖场景下，借助宽带网络隧道建立运营商 IMS 连接，保证语音与短信业务不掉线。

---

## 架构与技术栈

- **Backend**: Go 1.26+ (Gin、GORM、Viper、euicc-go)
- **Frontend**: Vue 3 + Vite + TailwindCSS + Element Plus
- **Database**: SQLite (`vohive.db`)
- **CI/CD**: GitHub Actions 自动化多架构交叉编译与全量 Release 打包

---

## 免责声明

- **用途定义**: 本项目主要面向个人学习、技术研究与功能测试场景，不建议直接用于生产环境或关键业务系统；由此产生的部署及使用风险由使用者自行承担。
- **非官方项目**: VoHive 为第三方独立开发的开源软件，与 Quectel (移远模组厂商)、高通公司及其他任何模组/芯片厂商均无官方关联、授权或合作关系，亦不对模组硬件本身的功能、质量或安全性负责。
- **合规使用**: 使用本项目搭建的服务前，请自行确保符合所在地区的法律法规及电信运营商的服务条款，不得用于任何违法违规用途。因违规使用造成的一切法律责任由使用者自行承担，与本项目作者及贡献者无关。
- **无担保声明**: 本软件按"现状"提供，不附带任何明示或暗示的担保，包括但不限于适销性、特定用途适用性及不侵权担保。因使用或无法使用本软件（含数据丢失、设备异常、业务中断等）造成的任何直接或间接损失，作者及贡献者不承担任何责任。

---

## License

本源码整合树不是单一许可项目。根项目基于 [PolyForm Noncommercial License 1.0.0](LICENSE)，`third_party/vowifi-go` 使用 AGPL-3.0，`third_party/quectel-qmi-go`、`third_party/netlink`、`third_party/qqbot` 等组件按各自许可证授权。发布公开二进制或 Docker 镜像前，请先确认组合分发的许可证义务；详情见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
