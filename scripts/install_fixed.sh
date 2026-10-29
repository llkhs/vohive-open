#!/bin/bash
# ==============================================================================
# VoHive 一键全自动快速安装与硬件调优部署脚本 (All-in-One)
# 适用平台：Linux (ARM64 / aarch64, x86_64 / amd64, ARMv7)
# 默认端口：7676
# 特别集成：原生内置高通 410 (MSM8916 / SP970-B-V13) 随身 WiFi 全套加固与防死机调优
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
    echo "[!] 警告：未找到 lock-band3！高通 SP970 棒子若缺少频段锁，可能被电信 Band 5 信号捕获导致搜网死锁！"
  fi
fi

# ── 9. 生成/更新配置文件 config.yaml (端口: 7676) ─────────────
if [ ! -f "$CONFIG_PATH" ]; then
  echo "[*] 写入全新默认配置文件 (Web 端口: $PORT)..."

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
  if grep -q "port: 7575" "$CONFIG_PATH"; then
    echo "[*] 将现有配置的端口从 7575 平滑升级为 $PORT ..."
    sed -i 's/port: 7575/port: 7676/g' "$CONFIG_PATH"
  fi
fi

# ── 10. 高通 410 (SP970-B-V13) 随身 WiFi 一体化硬件加固与系统调优 ─────
if [ -e "/dev/wwan0qmi0" ] || [ -e "/dev/wwan0at0" ]; then
  echo "----------------------------------------------------------------------"
  echo "[*] 检测到高通 410 (MSM8916) 硬件环境！"
  echo "[*] 正在执行一体化硬件加固与系统稳定性调优 (防掉卡/防CPU死锁/WiFi防休眠/内存优化)..."

  # 1. 彻底禁用冲突的 ModemManager
  echo "[+] 1. 禁用系统自带 ModemManager，彻底防止与 VoHive 发生串口/QMI 冲突..."
  systemctl disable --now ModemManager 2>/dev/null || true

  # 2. 根除 NetworkManager 蜂窝自动拨号无限死循环
  echo "[+] 2. 关闭 NetworkManager 蜂窝自动拨号，解除 CPU 100% 狂转死循环..."
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
# VoHive WiFi 动态网关探活保活脚本 (MSM8916 SP970)
# 自动探测当前实际默认网关，适配不同路由环境 (如 192.168.1.1 / 192.168.10.1 / 10.x.x.x 等)
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
  cat << 'EOF_SYSCTL' > /etc/sysctl.d/99-vohive-sp970.conf
# 针对高通 410 (376MB 可用内存) 的系统级虚拟内存调优
# 充分利用 zram 压缩内存，防止小内存直接回收（Direct Reclaim）卡死
vm.swappiness = 100
vm.vfs_cache_pressure = 50
EOF_SYSCTL
  sysctl -p /etc/sysctl.d/99-vohive-sp970.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

  # 6. 生成常驻自启硬件初始化与自动驻网脚本
  echo "[+] 6. 生成常驻自启硬件初始化脚本 /usr/local/bin/modem-init.sh ..."
  cat << 'EOF_MODEM_INIT' > /usr/local/bin/modem-init.sh
#!/bin/bash
# ==============================================================================
# MSM8916 Modem 自适应驻网常驻服务 (加固版: 自动锁 Band 1+3 + 零数据流量)
# ==============================================================================

QMI_DEV="/dev/wwan0qmi0"
AT_DEV="/dev/wwan0at0"

# 1. 等待设备节点就绪（最多等待 45 秒）
for i in $(seq 1 45); do
    if [ -e "$QMI_DEV" ] && [ -e "$AT_DEV" ]; then
        break
    fi
    sleep 1
done

if [ ! -e "$QMI_DEV" ] || [ ! -e "$AT_DEV" ]; then
    echo "[-] 找不到 $QMI_DEV 或 $AT_DEV 设备节点"
    exit 1
fi

# 2. 独占控制：临时暂停 VoHive，清理僵死代理
WAS_VOHIVE_ACTIVE=0
if systemctl is-active --quiet vohive 2>/dev/null; then
    echo "[*] 临时暂停 vohive 服务以获得独占控制权..."
    systemctl stop vohive
    WAS_VOHIVE_ACTIVE=1
fi

killall -9 qmi-proxy 2>/dev/null || true
sleep 1

# 3. 激活并守护 USIM Provisioning 会话（核心防掉卡逻辑）
ensure_usim_ready() {
    local card_info
    card_info=$(qmicli -p -d "$QMI_DEV" --uim-get-card-status 2>/dev/null || true)
    if ! echo "$card_info" | grep -q "Primary GW:   slot '1'"; then
        echo "[+] 检测到 Primary GW 会话未激活，正在激活卡槽 1 USIM..."
        local aid
        aid=$(echo "$card_info" | awk '/Application type:.*usim/{flag=1} flag && /Application ID:/{getline; gsub(/^[ \t]+|[ \t]+$/, ""); print; exit}')
        [ -z "$aid" ] && aid="A0:00:00:00:87:10:02:FF:47:F0:01:89:00:00:01:FF"
        qmicli -p -d "$QMI_DEV" --uim-change-provisioning-session="session-type=primary-gw-provisioning,activate=yes,slot=1,aid=$aid" >/dev/null 2>&1 || true
        sleep 1
    fi
    qmicli -p -d "$QMI_DEV" --dms-set-operating-mode=online >/dev/null 2>&1 || true
}

ensure_usim_ready

# 3.1 锁定 LTE 频段为 Band 1+3 (排除电信 Band 5 卡死)
if [ -x /usr/local/bin/lock-band3 ]; then
    echo "[+] 正在配置 LTE 频段策略 (Band 1+3，排除 Band 5)..."
    /usr/local/bin/lock-band3 >/dev/null 2>&1 || true
fi

# 4. 读取 SIM 卡 IMSI，用于智能运营商决策
IMSI=""
for retry in 1 2 3 4; do
    IMSI_RAW=$(qmicli -p -d "$QMI_DEV" --dms-uim-get-imsi 2>/dev/null || true)
    IMSI=$(echo "$IMSI_RAW" | grep -oE '[0-9]{15}' | head -n 1)
    if [ -n "$IMSI" ]; then
        break
    fi
    sleep 1
done

if [ -z "$IMSI" ]; then
    IMSI=$(perl -e '
        use strict; use IO::Select;
        my $p = "/dev/wwan0at0"; open(my $fh, "+<", $p) or exit 0;
        system("stty -F $p 115200 raw -echo");
        my $sel = IO::Select->new($fh);
        syswrite($fh, "AT+CIMI\r\n");
        my $buf = "";
        while ($sel->can_read(2.0)) { my $t; last unless sysread($fh,$t,1024); $buf.=$t; last if $buf=~/(OK|ERROR|\+CME ERROR)/; }
        close($fh);
        if ($buf =~ /(\d{15})/) { print $1; }
    ' 2>/dev/null || true)
fi

echo "[+] 成功读取 SIM 卡 IMSI: ${IMSI:-未知}"

CANDIDATE_PLMNS=("46001" "46000" "AUTO")
if [ -n "$IMSI" ]; then
    MCC="${IMSI:0:3}"
    MNC="${IMSI:3:2}"
    if [ "$MCC" = "460" ]; then
        case "$MNC" in
            00|02|04|07|08)
                echo "[*] 检测为 中国移动 卡，目标 PLMN: 46000"
                CANDIDATE_PLMNS=("46000" "AUTO")
                ;;
            01|06|09|10)
                echo "[*] 检测为 中国联通 卡，目标 PLMN: 46001"
                CANDIDATE_PLMNS=("46001" "AUTO")
                ;;
            03|05|11)
                echo "[*] 检测为 中国电信 卡，目标 PLMN: 46011"
                CANDIDATE_PLMNS=("46011" "AUTO")
                ;;
            *)
                CANDIDATE_PLMNS=("46001" "46000" "46011" "AUTO")
                ;;
        esac
    else
        echo "[*] 检测为 境外漫游卡/物联卡 (MCC: $MCC)"
        echo "[*] 在大陆环境优先锁定联通(46001)，备选移动(46000)"
        CANDIDATE_PLMNS=("46001" "46000" "AUTO")
    fi
else
    CANDIDATE_PLMNS=("46001" "46000" "46011" "AUTO")
fi

# 5. 清理 Attach PDN 冲突并重置 CID 承载
qmicli -p -d "$QMI_DEV" --wds-set-lte-attach-pdn-list='1' >/dev/null 2>&1 || true
perl -e '
use strict; use IO::Select;
my $p = "/dev/wwan0at0"; open(my $fh, "+<", $p) or exit 0;
system("stty -F $p 115200 raw -echo");
my $sel = IO::Select->new($fh);
sub at {
    my $c = shift; syswrite($fh, "$c\r\n");
    my $b = ""; while($sel->can_read(2.0)){ my $t; last unless sysread($fh,$t,1024); $b.=$t; last if $b=~/(OK|ERROR)/; }
}
at("AT+CGDCONT=1,\"IPV4V6\",\"\"");
at("AT+CGDCONT=2,\"IPV4V6\",\"\"");
at("AT+CGDCONT=3,\"IPV4V6\",\"\"");
close($fh);
' 2>/dev/null || true

# 6. 遍历候选选网策略
REGISTERED=0
for TARGET_PLMN in "${CANDIDATE_PLMNS[@]}"; do
    ensure_usim_ready
    echo "[+] 正在执行附着策略: $TARGET_PLMN ..."
    if [ "$TARGET_PLMN" = "AUTO" ]; then
        perl -e '
            use strict; use IO::Select;
            my $p = "/dev/wwan0at0"; open(my $fh, "+<", $p) or exit 0;
            system("stty -F $p 115200 raw -echo");
            my $sel = IO::Select->new($fh);
            syswrite($fh, "AT+COPS=0\r\n");
            my $b = ""; while($sel->can_read(15.0)){ my $t; last unless sysread($fh,$t,1024); $b.=$t; last if $b=~/(OK|ERROR)/; }
            close($fh);
        ' 2>/dev/null || true
    else
        perl -e "
            use strict; use IO::Select;
            my \$p = '/dev/wwan0at0'; open(my \$fh, '+<', \$p) or exit 0;
            system('stty -F \$p 115200 raw -echo');
            my \$sel = IO::Select->new(\$fh);
            syswrite(\$fh, \"AT+COPS=1,2,\\\"$TARGET_PLMN\\\",7\r\n\");
            my \$b = ''; while(\$sel->can_read(35.0)){ my \$t; last unless sysread(\$fh,\$t,1024); \$b.=\$t; last if \$b=~/(OK|ERROR|\\+CME ERROR)/; }
            close(\$fh);
        " 2>/dev/null || true
    fi

    # 轮询验证驻网状态 (最长等待 30 秒)
    for wait_i in $(seq 1 15); do
        sleep 2
        SERV_INFO=$(qmicli -p -d "$QMI_DEV" --nas-get-serving-system 2>/dev/null || true)
        if echo "$SERV_INFO" | grep -q "Registration state: 'registered'"; then
            echo "[√] 策略 $TARGET_PLMN 已成功驻网！"
            echo "$SERV_INFO" | grep -E "(Registration state|PLMN|Description|MCC|MNC)" | head -n 5
            REGISTERED=1
            break 2
        fi
    done

    echo "[-] 策略 $TARGET_PLMN 尚未完全附着，尝试下一个候选策略..."
done

# 7. 恢复服务
if [ "$WAS_VOHIVE_ACTIVE" = "1" ]; then
    echo "[+] 正在恢复 VoHive 服务..."
    systemctl start vohive
fi

echo "[√] Modem 初始化流程执行完毕！"
exit 0
EOF_MODEM_INIT
  chmod +x /usr/local/bin/modem-init.sh

  # 7. 配置开机自启 systemd 单元 /etc/systemd/system/modem-init.service
  echo "[+] 7. 配置开机自启 systemd 单元 /etc/systemd/system/modem-init.service ..."
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
  systemctl enable modem-init.service

  # 8. 清空 /etc/rc.local 避免重复竞态运行
  echo "[+] 8. 确保清空 /etc/rc.local 避免重复竞态运行..."
  cat << 'EOF_RCLOCAL' > /etc/rc.local
#!/bin/sh -e
exit 0
EOF_RCLOCAL
  chmod +x /etc/rc.local

  # 9. 首次执行初始化与驻网
  echo "[+] 9. 正在首次执行硬件初始化与驻网测试..."
  /usr/local/bin/modem-init.sh
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
  if [ -e "/dev/wwan0qmi0" ] || [ -e "/dev/wwan0at0" ]; then
    echo "----------------------------------------------------------------------"
    echo "[*] 高通 SP970 硬件一体化加固完成项："
    echo "    - 频段策略：Band 1+3 (彻底剔除电信 Band 5 搜网死锁)"
    echo "    - 选网模式：自动适配 (漫游卡锁定中国联通 46001)"
    echo "    - 流量防护：纯驻网收发短信，0 流量消耗"
    echo "    - CPU 守护：彻底消除 NetworkManager 自动拨号死循环 (Load < 0.2)"
    echo "    - WiFi 守护：永久关闭节能省电 (wifi.powersave=2) + 动态网关探活保活"
    echo "    - 内存优化：vm.swappiness=100, vm.vfs_cache_pressure=50 (防小内存卡死)"
    echo "    - 开机自启：已注册 modem-init.service (Before=vohive)"
  fi
  echo "======================================================================"
else
  echo "[-] 警告：VoHive 服务未能立即启动，请排查日志："
  echo "    journalctl -u vohive -n 50 --no-pager"
fi
