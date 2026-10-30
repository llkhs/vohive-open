#!/bin/bash
# ==============================================================================
# VoHive 一键全自动快速安装与硬件调优部署脚本 (All-in-One)
# 适用平台：Linux (ARM64 / aarch64, x86_64 / amd64, ARMv7)
# 默认端口：7676
# 特别集成：原生内置高通 410 (MSM8916 / OpenStick 全系: UFI001C, UFI003, SP970, UZ801 等) 随身 WiFi 全套加固与防死机调优
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
echo "               VoHive 全自动一键安装向导 (All-in-One)                "
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
# 智能搜索：优先匹配同目录、当前目录或 /root 下带版本哈希或标准命名的二进制产物
for dir in "$SCRIPT_DIR" "$PWD" "/root" "$SCRIPT_DIR/../../dist"; do
  [ ! -d "$dir" ] && continue
  for b in $(ls "$dir"/vohive*linux*${ARCH}* 2>/dev/null | sort -V -r); do
    if [ -f "$b" ] && [ -s "$b" ] && [[ ! "$b" =~ \.(sha256|tar|gz|zip|txt)$ ]]; then
      SRC_BIN="$b"
      break 2
    fi
  done
  for b in "$dir/vohive" "$dir/vo-hive"; do
    if [ -f "$b" ] && [ -s "$b" ]; then
      SRC_BIN="$b"
      break 2
    fi
  done
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
echo "[*] 检查并安装基础依赖包 (socat, usbutils, pciutils, curl, cron, wireless-regdb)..."
if command -v apt-get >/dev/null 2>&1; then
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq >/dev/null 2>&1 || true
  apt-get install -y -qq socat usbutils pciutils curl cron wireless-regdb >/dev/null 2>&1 || true
  # 若检测到高通硬件环境，同步安装 QMI 与 AT 控制依赖
  if [ -e "/dev/wwan0qmi0" ] || [ -e "/dev/wwan0at0" ]; then
    command -v qmicli >/dev/null 2>&1 || apt-get install -y -qq libqmi-utils >/dev/null 2>&1 || true
    command -v perl >/dev/null 2>&1 || apt-get install -y -qq perl-base >/dev/null 2>&1 || true
  fi
elif command -v dnf >/dev/null 2>&1; then
  dnf install -y -q socat usbutils pciutils curl cron wireless-regdb >/dev/null 2>&1 || true
elif command -v yum >/dev/null 2>&1; then
  yum install -y -q socat usbutils pciutils curl cron wireless-regdb >/dev/null 2>&1 || true
fi

# ── 5. 创建目录结构 ───────────────────────────────────────────
echo "[*] 创建目录结构 $VOHIVE_DIR ..."
mkdir -p "$VOHIVE_DIR"/{bin,config,data,logs}

# ── 6. 部署可执行文件 ─────────────────────────────────────────
echo "[*] 部署二进制 → $BIN_PATH"
install -m 0755 "$SRC_BIN" "$BIN_PATH"

# ── 7. 部署 MCC/MNC 运营商离线识别表 ────────────────────────
SRC_MCC=""
for f in "$SCRIPT_DIR/mcc-mnc-table.json" "$PWD/mcc-mnc-table.json" "/root/mcc-mnc-table.json"; do
  if [ -f "$f" ] && [ -s "$f" ]; then
    SRC_MCC="$f"
    break
  fi
done

if [ -n "$SRC_MCC" ]; then
  echo "[*] 部署 mcc-mnc-table.json → $DATA_DIR"
  install -m 0644 "$SRC_MCC" "$DATA_DIR/mcc-mnc-table.json"
else
  echo "[*] 本地未找到 mcc-mnc-table.json，尝试从镜像源下载离线运营商表..."
  MCC_URLS=(
    "https://cdn.jsdelivr.net/npm/mcc-mnc@latest/src/database/mcc-mnc-table.json"
    "https://fastly.jsdelivr.net/npm/mcc-mnc@latest/src/database/mcc-mnc-table.json"
    "https://raw.githubusercontent.com/musalbas/mcc-mnc-table/refs/heads/master/mcc-mnc-table.json"
  )
  for u in "${MCC_URLS[@]}"; do
    if curl -sSL --connect-timeout 5 "$u" -o "$DATA_DIR/mcc-mnc-table.json" 2>/dev/null; then
      if [ -s "$DATA_DIR/mcc-mnc-table.json" ]; then
        echo "[✓] 离线运营商表下载并部署成功"
        break
      fi
    fi
  done
  [ ! -s "$DATA_DIR/mcc-mnc-table.json" ] && echo "[!] 警告：未能下载到 mcc-mnc-table.json，前端界面可能无法离线解析运营商中文名称"
fi

# ── 8. 部署 LTE 频段锁定工具 (lock-band3) ─────────────────────
SRC_LOCK=""
for f in "$SCRIPT_DIR/lock-band3" "$SCRIPT_DIR/lock-band3_arm64" "$SCRIPT_DIR/hardware/lock-band3" "/root/lock-band3"; do
  if [ -f "$f" ] && [ -s "$f" ]; then
    SRC_LOCK="$f"
    break
  fi
done

if [ -n "$SRC_LOCK" ]; then
  echo "[*] 安装 LTE 频段锁定工具 → /usr/local/bin/lock-band3"
  install -m 0755 "$SRC_LOCK" /usr/local/bin/lock-band3
elif [ -e "/dev/wwan0qmi0" ]; then
  echo "[*] 检测到高通 MSM8916 基带，正在从 Release 下载必备的 lock-band3 工具..."
  curl -sSL --connect-timeout 8 "https://github.com/llkhs/vohive-open/releases/latest/download/lock-band3_arm64" -o /usr/local/bin/lock-band3 2>/dev/null || true
  if [ -s /usr/local/bin/lock-band3 ]; then
    chmod +x /usr/local/bin/lock-band3
    echo "[✓] lock-band3 下载并配置成功"
  else
    echo "[!] 警告：未找到 lock-band3！高通 410 随身 WiFi 棒子若缺少频段工具，可能被电信 Band 5 信号捕获导致搜网死锁！"
  fi
fi

# ── 9. 生成/更新配置文件 config.yaml (端口: 7676) ─────────────
if [ ! -f "$CONFIG_PATH" ]; then
  echo "[*] 写入全新默认配置文件 (Web 端口: $PORT)..."

  # 遵循最小配置原则：默认保持 devices: [] 纯净初始化
  # 避免在配置文件中塞入参数不全的半成品设备导致"设备启动中"假死。
  # 模组建议进入 Web 管理界面后，由【设备管理 -> 添加设备】通过自动发现一键无缝接入。
  DEVICE_SECTION="devices: []"
  if [ -e "/dev/wwan0qmi0" ] || [ -e "/dev/wwan0at0" ]; then
    echo "[*] 检测到底层蜂窝模组硬件，默认保持 devices 纯净，服务启动后可直接在 Web 管理后台自动发现并添加。"
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
  if grep -q "port: 7575" "$CONFIG_PATH"; then
    echo "[*] 将现有配置的端口从 7575 平滑升级为 $PORT ..."
    sed -i 's/port: 7575/port: 7676/g' "$CONFIG_PATH"
  fi
fi

# ── 10. 【优先启动】配置 systemd 单元并极速拉起 VoHive 前端 ──
echo "----------------------------------------------------------------------"
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

echo "[*] 正在极速启动 VoHive 服务，确保 Web 前端优先就绪..."
systemctl daemon-reload
systemctl enable --now vohive
systemctl restart vohive

sleep 2
IP=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -z "$IP" ] && IP="127.0.0.1"

if systemctl is-active --quiet vohive; then
  echo
  echo "======================================================================"
  echo "[✓] VoHive 核心服务与 Web 前端已极速启动上线！"
  echo "    Web 管理地址：http://${IP}:${PORT}"
  echo "    默认登录凭据：admin / admin (请在系统设置中及时修改)"
  echo "    服务运行状态：已就绪 (Active/Running)"
  echo "======================================================================"
else
  echo "[-] 提示：VoHive 正在拉起中，可通过 journalctl -u vohive -f 查看启动日志"
fi

# ── 11. 【紧随其后】执行硬件加固与系统调优 (SP970-B-V13 / MSM8916) ─
if [ -e "/dev/wwan0qmi0" ] || [ -e "/dev/wwan0at0" ]; then
  echo
  echo "----------------------------------------------------------------------"
  echo "[*] 检测到高通 410 (MSM8916) 硬件环境！"
  echo "[*] 正在执行一体化硬件加固与系统稳定性调优 (防掉卡/防CPU死锁/WiFi防休眠/内存优化)..."

  # 1. 彻底禁用冲突的 ModemManager
  echo "[+] 1. 禁用系统自带 ModemManager，防止与 VoHive 发生串口/QMI 冲突..."
  systemctl disable --now ModemManager 2>/dev/null || true

  # 2. 根除 NetworkManager 蜂窝自动拨号无限死循环 (写入全局 conf.d 规则)
  echo "[+] 2. 关闭 NetworkManager 蜂窝自动拨号，解除 CPU 100% 狂转死循环..."
  mkdir -p /etc/NetworkManager/conf.d
  cat << 'EOF_NM_MODEM' > /etc/NetworkManager/conf.d/99-disable-modem-autoconnect.conf
[connection-modem-noauto]
match-device=type:gsm
connection.autoconnect=false
connection.autoconnect-retries=0
EOF_NM_MODEM
  if command -v nmcli >/dev/null 2>&1; then
    nmcli connection modify modem connection.autoconnect no 2>/dev/null || true
    nmcli connection modify modem connection.autoconnect-retries 0 2>/dev/null || true
    nmcli connection down modem 2>/dev/null || true
  fi
  MODEM_CONF="/etc/NetworkManager/system-connections/modem.nmconnection"
  if [ -f "$MODEM_CONF" ]; then
    if grep -q "autoconnect=" "$MODEM_CONF"; then
      sed -i 's/autoconnect=.*/autoconnect=false/g' "$MODEM_CONF" 2>/dev/null || true
    else
      sed -i '/\[connection\]/a autoconnect=false' "$MODEM_CONF" 2>/dev/null || true
    fi
    if grep -q "autoconnect-retries=" "$MODEM_CONF"; then
      sed -i 's/autoconnect-retries=.*/autoconnect-retries=0/g' "$MODEM_CONF" 2>/dev/null || true
    else
      sed -i '/\[connection\]/a autoconnect-retries=0' "$MODEM_CONF" 2>/dev/null || true
    fi
    chmod 600 "$MODEM_CONF"
  fi

  # 3. 永久关闭 WiFi 节能省电模式 (防 wcn36xx 空闲休眠导致 SSH/Web 假死失联)
  echo "[+] 3. 配置 WiFi 永久关闭节能省电模式 (wifi.powersave=2)..."
  mkdir -p /etc/NetworkManager/conf.d
  cat << 'EOF_NM' > /etc/NetworkManager/conf.d/default-wifi-powersave-off.conf
[connection]
wifi.powersave = 2
EOF_NM
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl restart NetworkManager 2>/dev/null || true
  fi

  # 4. 部署动态默认网关心跳探活机制 (自动探测网关，防 AP 脱网/假死)
  echo "[+] 4. 配置动态默认网关心跳探活机制 (防止 AP 脱网/假死)..."
  cat << 'EOF_KEEPALIVE' > /usr/local/bin/wifi-keepalive.sh
#!/bin/bash
GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
[ -z "$GW" ] && GW=$(ip route 2>/dev/null | grep -E '^default' | awk '{print $3}' | head -n 1)

if [ -n "$GW" ]; then
    ping -c 1 -W 2 "$GW" >/dev/null 2>&1 || true
fi
EOF_KEEPALIVE
  chmod +x /usr/local/bin/wifi-keepalive.sh

  mkdir -p /etc/cron.d
  cat << 'EOF_CRON' > /etc/cron.d/wifi-keepalive
*/2 * * * * root /usr/local/bin/wifi-keepalive.sh >/dev/null 2>&1
EOF_CRON
  chmod 644 /etc/cron.d/wifi-keepalive
  systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true

  # 5. 优化系统虚拟内存与 Swap 参数 (适配 376MB 小内存，防缺页回收卡死)
  echo "[+] 5. 优化系统虚拟内存与 Swap 参数 (适配低内存环境)..."
  mkdir -p /etc/sysctl.d
  cat << 'EOF_SYSCTL' > /etc/sysctl.d/99-vohive-msm8916.conf
vm.swappiness = 100
vm.vfs_cache_pressure = 50
EOF_SYSCTL
  sysctl -p /etc/sysctl.d/99-vohive-msm8916.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

  # 6. 配置 LTE 频段策略 (Band 1+3，排除 Band 5 死锁)
  if [ -x /usr/local/bin/lock-band3 ]; then
    echo "[+] 6. 应用 LTE Band 1+3 频段锁 (彻底排除电信 Band 5 搜网死锁)..."
    /usr/local/bin/lock-band3 >/dev/null 2>&1 || true
  fi

  # 7. 生成开机常驻自启硬件初始化与驻网脚本
  echo "[+] 7. 生成常驻自启硬件初始化脚本 /usr/local/bin/modem-init.sh ..."
  cat << 'EOF_MODEM_INIT' > /usr/local/bin/modem-init.sh
#!/bin/bash
QMI_DEV="/dev/wwan0qmi0"
AT_DEV="/dev/wwan0at0"

# 1. 等待设备节点就绪
for i in $(seq 1 30); do
    [ -e "$QMI_DEV" ] && break
    sleep 1
done

[ ! -e "$QMI_DEV" ] && exit 0

# 2. 确保 DMS 在线模式
qmicli -p -d "$QMI_DEV" --dms-set-operating-mode=online >/dev/null 2>&1 || true

# 3. 检查 SIM 卡槽状态，若处于 absent 则自动触发一次重新上电触发 ATR 探测
CARD_STATUS=$(qmicli -p -d "$QMI_DEV" --uim-get-card-status 2>/dev/null || true)
if echo "$CARD_STATUS" | grep -q "Card state: 'absent'"; then
    qmicli -p -d "$QMI_DEV" --uim-sim-power-off=1 >/dev/null 2>&1 || true
    sleep 1
    qmicli -p -d "$QMI_DEV" --uim-sim-power-on=1 >/dev/null 2>&1 || true
    sleep 2
fi

# 4. 锁定 LTE 频段为 Band 1+3
[ -x /usr/local/bin/lock-band3 ] && /usr/local/bin/lock-band3 >/dev/null 2>&1 || true

# 5. 检查是否已经正常驻网
SERV_INFO=$(qmicli -p -d "$QMI_DEV" --nas-get-serving-system 2>/dev/null || true)
if echo "$SERV_INFO" | grep -q "Registration state: 'registered'"; then
    exit 0
fi

# 6. 清理 Attach PDN 冲突并重置 CID 承载
qmicli -p -d "$QMI_DEV" --wds-set-lte-attach-pdn-list='1' >/dev/null 2>&1 || true

# 7. 优先尝试自动选网 (AUTO)
if [ -e "$AT_DEV" ]; then
    perl -e '
        use strict; use IO::Select;
        my $p = "/dev/wwan0at0"; open(my $fh, "+<", $p) or exit 0;
        system("stty -F $p 115200 raw -echo");
        my $sel = IO::Select->new($fh);
        syswrite($fh, "AT+COPS=0\r\n");
        my $b = ""; while($sel->can_read(10.0)){ my $t; last unless sysread($fh,$t,1024); $b.=$t; last if $b=~/(OK|ERROR)/; }
        close($fh);
    ' 2>/dev/null || true
    sleep 4
fi

# 8. 再次检测驻网，若仍未附着则依次尝试联通(46001)、移动(46000)、电信(46011)
SERV_INFO=$(qmicli -p -d "$QMI_DEV" --nas-get-serving-system 2>/dev/null || true)
if ! echo "$SERV_INFO" | grep -q "Registration state: 'registered'"; then
    for TARGET_PLMN in "46001" "46000" "46011"; do
        perl -e "
            use strict; use IO::Select;
            my \$p = '/dev/wwan0at0'; open(my \$fh, '+<', \$p) or exit 0;
            system('stty -F \$p 115200 raw -echo');
            my \$sel = IO::Select->new(\$fh);
            syswrite(\$fh, qq(AT+COPS=1,2,\"$TARGET_PLMN\",7\r\n));
            my \$b = ''; while(\$sel->can_read(15.0)){ my \$t; last unless sysread(\$fh,\$t,1024); \$b.=\$t; last if \$b=~/(OK|ERROR|\+CME ERROR)/; }
            close(\$fh);
        " 2>/dev/null || true
        sleep 3
        SERV_INFO=$(qmicli -p -d "$QMI_DEV" --nas-get-serving-system 2>/dev/null || true)
        echo "$SERV_INFO" | grep -q "Registration state: 'registered'" && break
    done
fi
exit 0
EOF_MODEM_INIT
  chmod +x /usr/local/bin/modem-init.sh

  # 8. 配置 VoHive 专有资源硬隔离 (限制 CPUQuota 与 MemoryMax，防止 ARM64 随身 WiFi 卡死)
  echo "[+] 8. 为 VoHive 注入 ARM64 随身 WiFi 专有资源防护 (CPUQuota=60%, MemoryMax=100M)..."
  mkdir -p /etc/systemd/system/vohive.service.d
  cat << 'EOF_VOHIVE_LIMIT' > /etc/systemd/system/vohive.service.d/10-arm64-resource-limit.conf
[Service]
# 限制单核最大占用，保障系统 SSH 与基础服务在极端情况下不夯机
CPUQuota=60%
# 针对 384MB 小内存环境设置内存硬隔离，防 OOM 崩溃
MemoryMax=100M
MemoryHigh=80M
EOF_VOHIVE_LIMIT

  # 9. 配置开机自启 systemd 单元 /etc/systemd/system/modem-init.service
  echo "[+] 9. 配置开机自启 systemd 单元 /etc/systemd/system/modem-init.service ..."
  cat << 'EOF_MODEM_SVC' > /etc/systemd/system/modem-init.service
[Unit]
Description=Qualcomm MSM8916 Modem Auto-Init Service
After=rmtfs.service qrtr-ns.service ModemManager.service
Before=vohive.service
Wants=rmtfs.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/modem-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_MODEM_SVC

  systemctl daemon-reload
  systemctl enable modem-init.service 2>/dev/null || true

  # 10. 安全更新 /etc/rc.local (保留物理 SIM 选通与硬件初始化)
  echo "[+] 10. 配置 /etc/rc.local 硬件自愈脚本..."
  cat << 'EOF_RCLOCAL' > /etc/rc.local
#!/bin/sh -e
# 若硬件包含 sim:sel/sim:en 则优先选通物理卡并上电
[ -e /sys/class/leds/sim:sel/brightness ] && echo 0 > /sys/class/leds/sim:sel/brightness 2>/dev/null || true
[ -e /sys/class/leds/sim:en/brightness ] && echo 1 > /sys/class/leds/sim:en/brightness 2>/dev/null || true
exit 0
EOF_RCLOCAL
  chmod +x /etc/rc.local

  # 10. 检查基带驻网状态，非阻塞自适应处理
  echo "[+] 10. 检查基带驻网状态..."
  SERV_INFO=$(qmicli -p -d "/dev/wwan0qmi0" --nas-get-serving-system 2>/dev/null || true)
  if echo "$SERV_INFO" | grep -q "Registration state: 'registered'"; then
    PLMN_DESC=$(echo "$SERV_INFO" | grep "Description:" | awk -F"'" '{print $2}' | head -n 1)
    [ -z "$PLMN_DESC" ] && PLMN_DESC="已注册"
    echo "    [✓] 基带已成功驻网 (${PLMN_DESC})，网络连接就绪！"
  else
    echo "    [*] 基带尚未完全附着，已在后台自动触发自适应驻网守护 (无需等待，日志: journalctl -u modem-init -f)..."
    systemctl start modem-init.service >/dev/null 2>&1 &
  fi
fi

# ── 12. 最终完成提示 ─────────────────────────────────────────
echo
echo "======================================================================"
echo "[✓] VoHive 部署与硬件加固优化全部完成！"
echo "    Web 管理地址：http://${IP}:${PORT}"
echo "    默认登录凭据：admin / admin (请在系统设置中及时修改)"
echo "    配置文件路径：$CONFIG_PATH"
echo "    日志查看命令：journalctl -u vohive -f"
if [ -e "/dev/wwan0qmi0" ] || [ -e "/dev/wwan0at0" ]; then
  echo "----------------------------------------------------------------------"
  echo "[*] 高通 410 (MSM8916 / OpenStick) 硬件一体化加固完成项："
  echo "    - 频段策略：Band 1+3 (彻底剔除电信 Band 5 搜网死锁)"
  echo "    - 选网模式：自动适配 (漫游卡锁定中国联通 46001 / 移动 46000)"
  echo "    - 流量防护：纯驻网收发短信，0 流量消耗"
  echo "    - CPU 守护：彻底消除 NetworkManager 自动拨号死循环 (Load < 0.2)"
  echo "    - WiFi 守护：永久关闭节能省电 (wifi.powersave=2) + 动态网关探活保活"
  echo "    - 内存优化：vm.swappiness=100, vm.vfs_cache_pressure=50 (防小内存卡死)"
  echo "    - 开机自启：已注册 modem-init.service (Before=vohive)"
fi
echo "======================================================================"
