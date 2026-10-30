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

## 架构与技术栈

- **Backend**: Go 1.26+ (Gin、GORM、Viper、euicc-go)
- **Frontend**: Vue 3 + Vite + TailwindCSS + Element Plus
- **Database**: SQLite (`vohive.db`)
- **CI/CD**: GitHub Actions 自动化多架构交叉编译与全量 Release 打包

---

## 🤝 贡献与致谢 (Contributors & Credits)

本项目由社区与 AI 结对编程协作演进：

- **[@llkhs](https://github.com/llkhs)** — 核心架构设计、项目维护与实机真机验证
- **[Google Gemini](https://deepmind.google/technologies/gemini/) (DeepMind Antigravity)** — 全栈协同研发、高通 410 (MSM8916 / OpenStick) 硬件底层生态驱动与全系加固调优 (AI Pair Programmer & Co-author)

---

## ⚖️ 免责声明与法律合规 (Disclaimer & Compliance)

> [!CAUTION]
> **在下载、使用、分发或修改本项目代码前，请务必仔细阅读本声明。使用本项目即表示您已完全理解、接受并同意遵守以下所有条款。**

1. **学术研究与教学用途限定**: 本项目（包括但不限于所有源码、文档、脚本及预构建二进制资产）仅供**计算机网络、移动通信技术、嵌入式系统与硬件底层驱动研究等纯技术领域的个人学习、学术交流及技术可行性验证**。严禁将本项目直接或间接应用于任何关键业务、生产系统或非法环境。
2. **绝对严禁非法与黑灰产用途**:
   - 严禁将本项目用于任何形式的**电信网络诈骗、批量接码、网络水军、恶意群发、虚假刷量、黑灰产代理池搭建**等行为；
   - 严禁利用本项目侵入、干扰、破坏计算机信息系统或公共电信基础设施；
   - 严禁利用本项目规避任何国家、地区或平台的法定实名核验与安全监管机制。
3. **法律法规与电信合规义务**: 使用者在运行或部署本项目时，**必须严格遵守所在地所有适用的法律法规与行政监管规定**（包括但不限于《中华人民共和国反电信网络诈骗法》、《中华人民共和国网络安全法》、《中华人民共和国数据安全法》、《中华人民共和国电信条例》等相关法律法规）。使用者必须确保所使用的物理 SIM 卡、实体 eSIM 芯片及移动通信服务均为依法依规实名办理且享有合法使用权，严禁盗用、冒用、租借或非法转让通信资源。
4. **使用者独立全责与连带责任豁免（Strict Sole Liability）**:
   - 本项目为去中心化的开源技术代码库，**项目作者、核心维护者及代码贡献者既无法监控、也不可能控制任何使用者的具体部署行为与使用目的**；
   - 因任何自然人、法人或其他组织使用、下载、复制、修改、运行、部署、分发或二次开发本项目及其衍生版本，而直接、间接、意外、衍生或连带产生的**任何民事纠纷、行政处罚、索赔诉讼、监管调查或刑事法律责任，均由使用者本人（或组织）独立承担全部法律后果与经济赔偿**；
   - **项目作者、核心维护者及代码贡献者在任何情况下均不对使用者的任何违规或违法行为承担任何性质的直接、间接、连带、附带或惩罚性法律责任**。
5. **无担保与损害免责（AS-IS & Limitation of Liability）**: 本软件按“现状”（AS-IS）提供，不附带任何明示或暗示的保证，包括但不限于适销性、特定用途适用性及无侵权担保。因软硬件兼容性、底层指令执行、固件异常、电信资费扣除、硬件发热损坏或数据丢失而产生的一切损失，由使用者自行承担，原作者与贡献者不负任何赔偿责任。
6. **第三方商标与厂商独立声明**: 本项目为第三方独立开源项目，与高通公司（Qualcomm）、移远通信（Quectel）、任何电信运营商或随身 WiFi 硬件厂商均不存在任何官方合作、授权、赞助或背书关系。

---

## 📄 开源许可证 (License & Non-Commercial Policy)

本项目源码整合树遵循严格的非商业与多组件授权政策：

1. **根项目非商业开源许可**: 本项目的核心架构及业务源码基于 **[PolyForm Noncommercial License 1.0.0](LICENSE)** 授权分发。
   - **非商业用途限定**: 仅允许个人用于非商业目的的学习、研究与自用测试；
   - **严禁商业化牟利**: **严禁任何个人、团队或企业将本项目、打包产物、二次开发版本或衍生服务用于任何收费运营、有偿接口、商业代理平台搭建或任何形式的盈利活动**。任何未经作者书面许可的商业化行为均构成严重侵权，侵权方须立即停止侵权并承担全部民事赔偿与法律责任。
2. **第三方组件授权说明**: 本项目引用的第三方组件保留其原有开源许可证，其中 `third_party/vowifi-go` 基于 AGPL-3.0 许可，`third_party/quectel-qmi-go`、`third_party/netlink`、`third_party/qqbot` 等组件遵循各自的开源许可证授权。分发组合二进制产物时请务必遵守各第三方组件的许可证义务，详情请查阅 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
