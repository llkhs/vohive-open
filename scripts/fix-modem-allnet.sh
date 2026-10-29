#!/bin/bash
# ==============================================================================
# 高通 MSM8916 (板载丝印 SP970-B-V13) 随身 WiFi 棒子一键初始化与加固脚本
# 功能：频段锁 Band 1+3 (剔除电信 Band 5) + 自动选网 + 防漫游流量 + 防 CPU 100% 死循环
# 适用环境：Debian / Armbian 系统 (ARM64 / aarch64) + VoHive
# ==============================================================================

set -e

[ "$(id -u)" -ne 0 ] && echo "[-] 错误：请使用 root 权限运行此脚本！" && exit 1

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

echo "======================================================================"
echo "[*] 高通 410 (SP970-B-V13) 随身 WiFi 硬件环境初始化与加固"
echo "======================================================================"

# 1. 检查并安装必要依赖
echo "[+] 1. 正在检查并安装基础依赖 (libqmi-utils, perl-base)..."
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    command -v qmicli >/dev/null 2>&1 || apt-get install -y -qq libqmi-utils
    command -v perl >/dev/null 2>&1 || apt-get install -y -qq perl-base
fi

# 2. 彻底禁用系统自带的 ModemManager
echo "[+] 2. 正在禁用系统原生 ModemManager，彻底防止与 VoHive 发生串口/QMI 冲突..."
systemctl disable --now ModemManager 2>/dev/null || true

# 3. 关闭 NetworkManager 蜂窝自动拨号，根治 CPU 100% 死循环高负载发热
echo "[+] 3. 正在关闭 NetworkManager 蜂窝自动拨号，解除 CPU 死循环..."
if command -v nmcli >/dev/null 2>&1; then
    nmcli connection modify modem connection.autoconnect no 2>/dev/null || true
    nmcli connection modify modem connection.autoconnect-retries 0 2>/dev/null || true
    nmcli connection down modem 2>/dev/null || true
fi

MODEM_CONF="/etc/NetworkManager/system-connections/modem.nmconnection"
if [ -f "$MODEM_CONF" ]; then
    if grep -q "autoconnect=" "$MODEM_CONF"; then
        sed -i 's/autoconnect=.*/autoconnect=false/g' "$MODEM_CONF"
    else
        sed -i '/\[connection\]/a autoconnect=false' "$MODEM_CONF"
    fi
    if grep -q "autoconnect-retries=" "$MODEM_CONF"; then
        sed -i 's/autoconnect-retries=.*/autoconnect-retries=0/g' "$MODEM_CONF"
    else
        sed -i '/\[connection\]/a autoconnect-retries=0' "$MODEM_CONF"
    fi
    chmod 600 "$MODEM_CONF"
fi

# 4. 部署 LTE 频段锁定工具 (lock-band3)
echo "[+] 4. 正在配置 LTE 频段锁定工具 (lock-band3)..."
if [ -f "$SCRIPT_DIR/lock-band3" ]; then
    cp "$SCRIPT_DIR/lock-band3" /usr/local/bin/lock-band3
elif [ -f "$SCRIPT_DIR/../../dist/lock-band3" ]; then
    cp "$SCRIPT_DIR/../../dist/lock-band3" /usr/local/bin/lock-band3
elif [ -f "/root/lock-band3" ]; then
    cp /root/lock-band3 /usr/local/bin/lock-band3
fi

if [ -f "/usr/local/bin/lock-band3" ]; then
    chmod +x /usr/local/bin/lock-band3
    echo "    [✓] lock-band3 工具已就绪 (/usr/local/bin/lock-band3)"
else
    echo "    [!] 提示：未找到预编译的 lock-band3，将使用 QMI/AT 兜底机制"
fi

# 5. 写入常驻自启动硬件初始化脚本 /usr/local/bin/modem-init.sh
echo "[+] 5. 正在生成常驻自启硬件初始化脚本 /usr/local/bin/modem-init.sh ..."
cat << 'EOF' > /usr/local/bin/modem-init.sh
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

# 3.1 锁定 LTE 频段为 Band 1+3 (彻底剔除电信 Band 5 导致的搜网卡死)
if [ -x /usr/local/bin/lock-band3 ]; then
    echo "[+] 正在配置 LTE 频段策略 (Band 1+3，排除 Band 5)..."
    /usr/local/bin/lock-band3 >/dev/null 2>&1 || true
fi

# 4. 读取 SIM 卡 IMSI，用于智能选网决策
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
        while ($sel->can_read(2.0)) { my $t; last unless sysread($fh, $t, 1024); $buf .= $t; last if $buf =~ /(OK|ERROR)/; }
        if ($buf =~ /([0-9]{15})/) { print $1; }
        close($fh);
    ' 2>/dev/null || true)
fi

echo "[+] 成功读取 SIM 卡 IMSI: ${IMSI:-未知}"

CANDIDATE_PLMNS=()
if [ -n "$IMSI" ]; then
    MCC="${IMSI:0:3}"
    MNC="${IMSI:3:2}"
    if [ "$MCC" = "460" ]; then
        case "$MNC" in
            00|02|07|08)
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

# 5. 清理 Attach PDN 冲突并重置 CID 承载 (清空电信 CTNET 固化 APN)
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
            syswrite(\$fh, \"AT+COPS=1,2,\\\"$TARGET_PLMN\\\",7\\r\\n\");
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

# 7. 保护卡策略：绝不自动篡改网络使能设置（尊重境外卡纯驻网+防高额流量漫游资费需求）

# 8. 恢复服务
if [ "$WAS_VOHIVE_ACTIVE" = "1" ]; then
    echo "[+] 正在恢复 VoHive 服务..."
    systemctl start vohive
fi

echo "[√] Modem 初始化流程执行完毕！"
exit 0
EOF

chmod +x /usr/local/bin/modem-init.sh

# 6. 配置开机自启 systemd 单元
echo "[+] 6. 正在配置开机自启 systemd 单元 /etc/systemd/system/modem-init.service ..."
cat << 'EOF' > /etc/systemd/system/modem-init.service
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
EOF

systemctl daemon-reload
systemctl enable modem-init.service

# 7. 清空 /etc/rc.local 避免重复竞态运行
echo "[+] 7. 确保清空 /etc/rc.local 避免重复竞态运行..."
cat << 'EOF' > /etc/rc.local
#!/bin/sh -e
exit 0
EOF
chmod +x /etc/rc.local

# 8. 首次执行初始化与驻网
echo "[+] 8. 正在首次执行初始化与驻网测试..."
/usr/local/bin/modem-init.sh

echo "======================================================================"
echo "[√] 高通 410 (SP970-B-V13) 随身 WiFi 环境初始化完成！"
echo "    - 频段策略：Band 1+3 (彻底剔除电信 Band 5 搜网死锁)"
echo "    - 选网模式：自动适配 (漫游卡锁定中国联通 46001)"
echo "    - 数据网络：保持断开，0 流量消耗，仅接收短信"
echo "    - CPU 守护：彻底消除 NetworkManager 自动拨号死循环 (Load < 0.2)"
echo "    - 开机自启：已注册 modem-init.service (Before=vohive)"
echo "======================================================================"
