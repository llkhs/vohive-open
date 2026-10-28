#!/bin/bash
# ==============================================================================
# VoHive 一键快速安装与部署脚本
# 适用平台：Linux (ARM64 / aarch64, x86_64 / amd64, ARMv7)
# 默认端口：7676
# 特别优化：深度适配高通 410 (MSM8916 / SP970-B-V13) 随身 WiFi 棒子及标准 Linux 主机
# ==============================================================================

set -e

VOHIVE_DIR=/opt/vohive
BIN_PATH=$VOHIVE_DIR/bin/vohive
DATA_DIR=$VOHIVE_DIR/data
CONFIG_PATH=$VOHIVE_DIR/config/config.yaml
SERVICE_PATH=/etc/systemd/system/vohive.service
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

PORT=7676

echo "======================================================================"
echo "                   VoHive 快速安装与部署向导                         "
echo "======================================================================"

# ── 1. root 检查 ──────────────────────────────────────────────
if [ "$EUID" -ne 0 ]; then
  echo "[-] 错误：请使用 root 权限运行此脚本：sudo bash $0"
  exit 1
fi

# ── 2. 架构识别 ──────────────────────────────────────────────
RAW_ARCH=$(uname -m)
case "$RAW_ARCH" in
  x86_64|amd64)
    ARCH="amd64"
    ;;
  aarch64|arm64)
    ARCH="arm64"
    ;;
  armv7l|armhf)
    ARCH="armv7"
    ;;
  *)
    ARCH="$RAW_ARCH"
    echo "[!] 警告：未识别的系统架构 $RAW_ARCH，尝试作为 $ARCH 处理"
    ;;
esac
echo "[*] 系统架构：$RAW_ARCH (适配类别: $ARCH)"

# ── 3. 寻找并准备安装资产 ─────────────────────────────────────
SRC_BIN=""
# 优先匹配本地同目录或当前目录下的二进制
CANDIDATE_BINS=(
  "$SCRIPT_DIR/vohive"
  "$SCRIPT_DIR/vohive_linux_${ARCH}"
  "$SCRIPT_DIR/vohive_dev_linux_${ARCH}"
  "$SCRIPT_DIR/../../dist/vo-hive"
  "$PWD/vohive"
  "$PWD/vohive_dev_linux_${ARCH}"
  "/root/vohive_dev_linux_${ARCH}"
)

for b in "${CANDIDATE_BINS[@]}"; do
  if [ -f "$b" ] && [ -s "$b" ]; then
    SRC_BIN="$b"
    break
  fi
done

if [ -z "$SRC_BIN" ]; then
  echo "[!] 本地未找到适用于 $ARCH 的 vohive 二进制文件。"
  echo "[*] 正在尝试从 GitHub Release 下载最新二进制..."
  DOWNLOAD_URL="https://github.com/llkhs/vohive-open/releases/latest/download/vohive_dev_linux_${ARCH}"
  if command -v curl >/dev/null 2>&1; then
    curl -fSL "$DOWNLOAD_URL" -o "$SCRIPT_DIR/vohive_dev_linux_${ARCH}" || true
  elif command -v wget >/dev/null 2>&1; then
    wget -q "$DOWNLOAD_URL" -O "$SCRIPT_DIR/vohive_dev_linux_${ARCH}" || true
  fi
  if [ -f "$SCRIPT_DIR/vohive_dev_linux_${ARCH}" ] && [ -s "$SCRIPT_DIR/vohive_dev_linux_${ARCH}" ]; then
    SRC_BIN="$SCRIPT_DIR/vohive_dev_linux_${ARCH}"
  else
    echo "[-] 错误：未能获取到二进制文件，请手动将 vohive_dev_linux_${ARCH} 放置在脚本同目录下再运行。"
    exit 1
  fi
fi

echo "[✓] 找到可用二进制文件: $SRC_BIN"

# ── 4. 安装基础系统依赖 ──────────────────────────────────────
echo "[*] 检查并安装基础依赖包 (socat, usbutils, pciutils, curl)..."
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq socat usbutils pciutils curl >/dev/null 2>&1 || true
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q socat usbutils pciutils curl >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q socat usbutils pciutils curl >/dev/null 2>&1 || true
fi

# ── 5. 创建目录结构 ───────────────────────────────────────────
echo "[*] 创建目录结构 $VOHIVE_DIR ..."
mkdir -p "$VOHIVE_DIR"/{bin,config,data,logs}

# ── 6. 部署可执行文件 ─────────────────────────────────────────
echo "[*] 部署二进制 → $BIN_PATH"
install -m 0755 "$SRC_BIN" "$BIN_PATH"

# ── 7. 部署 MCC/MNC 运营商表 ──────────────────────────────────
SRC_MCC=""
for f in "$SCRIPT_DIR/mcc-mnc-table.json" "$PWD/mcc-mnc-table.json" "/root/mcc-mnc-table.json"; do
  if [ -f "$f" ]; then
    SRC_MCC="$f"
    break
  fi
done

if [ -n "$SRC_MCC" ]; then
  echo "[*] 部署 mcc-mnc-table.json → $DATA_DIR"
  install -m 0644 "$SRC_MCC" "$DATA_DIR/mcc-mnc-table.json"
fi

# ── 8. 部署 LTE 频段锁定工具 (若存在) ─────────────────────────
for f in "$SCRIPT_DIR/lock-band3" "$SCRIPT_DIR/hardware/lock-band3" "/root/lock-band3"; do
  if [ -f "$f" ]; then
    echo "[*] 安装 LTE 频段锁定工具 → /usr/local/bin/lock-band3"
    install -m 0755 "$f" /usr/local/bin/lock-band3
    break
  fi
done

# ── 9. 生成/更新配置文件 config.yaml (端口: 7676) ─────────────
if [ ! -f "$CONFIG_PATH" ]; then
  echo "[*] 写入全新默认配置文件 (Web 端口: $PORT)..."

  # 检测是否具备高通 MSM8916 wwan0 蜂窝节点
  DEVICE_SECTION="devices: []"
  if [ -e "/dev/wwan0qmi0" ]; then
    echo "[+] 检测到高通 QMI 调制解调器 (/dev/wwan0qmi0)，自动配置 wwan0 设备..."
    DEVICE_SECTION=$(cat << 'DEVEOF'
devices:
  - id: wwan0
    device_backend: qmi
    operator_selection_mode: automatic
DEVEOF
)
  fi

  cat > "$CONFIG_PATH" <<EOF
server:
  debug: false
  port: $PORT

web:
  username: admin
  password: admin

$DEVICE_SECTION

vowifi:
  enabled: false

bark:
  enabled: false
  group: vohive
  icon: ""
  level: active
  urls: []

email:
  enabled: false
  from_address: ""
  password: ""
  smtp_host: ""
  smtp_port: 0
  to_addresses: []
  username: ""

feishu:
  app_id: ""
  app_secret: ""
  chat_ids: []
  enabled: false

pushplus:
  channel: wechat
  enabled: false
  token: ""
  topic: ""

qq:
  app_id: ""
  app_secret: ""
  direct_ids: ""
  enabled: false
  group_ids: ""

telegram:
  admin_id: 0
  base_url: ""
  bot_token: ""
  chat_id: 0
  enabled: false
  proxy: ""

webhook:
  enabled: false
  headers: {}
  retry_max: 3
  secret: ""
  text_template: '{{device_label}} {{text}}'
  timeout_ms: 5000
  urls: []
EOF
  chmod 0600 "$CONFIG_PATH"
  echo "    [✓] 配置文件已生成 (默认登录账号: admin / admin)"
else
  echo "[*] 检测到已存在配置文件 $CONFIG_PATH"
  # 如果当前端口是 7575，自动升级为 7676
  if grep -q "port: 7575" "$CONFIG_PATH"; then
    echo "[*] 将现有配置的端口从 7575 平滑升级为 $PORT ..."
    sed -i 's/port: 7575/port: 7676/g' "$CONFIG_PATH"
  fi
fi

# ── 10. 针对高通 410 (SP970-B-V13) 随身 WiFi 的自动加固 ─────
if [ -e "/dev/wwan0qmi0" ] || [ -e "/dev/wwan0at0" ]; then
  echo "----------------------------------------------------------------------"
  echo "[*] 检测到高通 410 (MSM8916) 硬件环境！"
  echo "[*] 正在执行防掉卡、防 CPU 100% 死循环与防漫游跑流量加固..."

  SP970_SCRIPT=""
  for s in "$SCRIPT_DIR/hardware/sp970-setup.sh" "$SCRIPT_DIR/sp970-setup.sh" "/root/setup-stick.sh" "/root/fix-modem-allnet.sh"; do
    if [ -f "$s" ]; then
      SP970_SCRIPT="$s"
      break
    fi
  done

  if [ -n "$SP970_SCRIPT" ]; then
    echo "[+] 正在调用硬件加固脚本: $SP970_SCRIPT ..."
    bash "$SP970_SCRIPT" || echo "[!] 硬件加固脚本执行完毕（有少许非致命告警，已安全继续）"
  else
    echo "[!] 未找到独立的 sp970-setup.sh，正在执行内置基础加固..."
    # 禁用冲突的 ModemManager
    systemctl disable --now ModemManager 2>/dev/null || true
    # 修复 NetworkManager 重拨死循环
    if command -v nmcli >/dev/null 2>&1; then
      nmcli connection modify modem connection.autoconnect no 2>/dev/null || true
      nmcli connection modify modem connection.autoconnect-retries 0 2>/dev/null || true
    fi
    MODEM_CONF="/etc/NetworkManager/system-connections/modem.nmconnection"
    if [ -f "$MODEM_CONF" ]; then
      sed -i 's/autoconnect=.*/autoconnect=false/g' "$MODEM_CONF" 2>/dev/null || true
      chmod 600 "$MODEM_CONF"
    fi
  fi
  echo "----------------------------------------------------------------------"
fi

# ── 11. 配置并启动 systemd 服务 ──────────────────────────────
echo "[*] 配置 systemd 服务单元 → $SERVICE_PATH"
cat > "$SERVICE_PATH" <<'EOF'
[Unit]
Description=VoHive Service
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=/opt/vohive
ExecStart=/opt/vohive/bin/vohive -c /opt/vohive/config/config.yaml
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF

echo "[*] 重载 systemd 并启动 VoHive 服务..."
systemctl daemon-reload
systemctl enable --now vohive
systemctl restart vohive

# ── 12. 验证与输出 ───────────────────────────────────────────
sleep 2
if systemctl is-active --quiet vohive; then
  IP=$(hostname -I 2>/dev/null | awk '{print $1}')
  [ -z "$IP" ] && IP="127.0.0.1"
  echo
  echo "======================================================================"
  echo "[✓] VoHive 部署成功并已正常运行！"
  echo "    Web 管理地址：http://${IP}:${PORT}"
  echo "    默认登录凭据：admin / admin (请在系统设置中及时修改)"
  echo "    配置文件路径：$CONFIG_PATH"
  echo "    日志查看命令：journalctl -u vohive -f"
  echo "======================================================================"
else
  echo "[-] 警告：VoHive 服务未能立即启动，请排查日志："
  echo "    journalctl -u vohive -n 50 --no-pager"
fi
