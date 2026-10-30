#!/bin/bash
# ==============================================================================
# 高通 MSM8916 (OpenStick / UFI001C / UFI003) 随身 WiFi 专有一键初始化与加固脚本
# 适用环境：Armbian / Debian (Linux 内核 5.x / 6.x, ARM64 / aarch64) + VoHive
# 特性：
#   1. 外部实体 SIM 卡槽 (含实体 eSIM) 与板载贴片卡 GPIO 智能早周期选通
#   2. 根治 ModemManager 冲突、NetworkManager 蜂窝轮询死循环 (CPU 100%) 与 WiFi 休眠
#   3. 运营商 Attach APN 智能自适应 (电信 ctlte / 移动 cmiot / 联通 wonet / 漫游卡)
#   4. 适配 512MB 小内存的虚拟内存调优与 VoHive 进程资源硬隔离 (防 OOM 死机)
# ==============================================================================

set -e

[ "$(id -u)" -ne 0 ] && echo "[-] 错误：请使用 root 权限运行此脚本！" && exit 1

SLOT_MODE="external"
for arg in "$@"; do
    case "$arg" in
        --internal-sim|--onboard)
            SLOT_MODE="internal"
            ;;
        --external-sim|--nano-sim)
            SLOT_MODE="external"
            ;;
    esac
done

echo "======================================================================"
echo "[*] 高通 410 (MSM8916 OpenStick) 随身 WiFi 硬件环境初始化与加固"
echo "[*] 目标卡槽模式: $SLOT_MODE (可传参 --external-sim 或 --internal-sim)"
echo "======================================================================"

# 1. 检查并安装必要依赖
echo "[+] 1. 检查并安装基础依赖 (libqmi-utils, perl-base, cron)..."
if command -v apt-get >/dev/null 2>&1; then
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >/dev/null 2>&1 || true
    command -v qmicli >/dev/null 2>&1 || apt-get install -y -qq libqmi-utils
    command -v perl >/dev/null 2>&1 || apt-get install -y -qq perl-base
    apt-get install -y -qq cron wireless-regdb >/dev/null 2>&1 || true
fi

# 2. 彻底禁用系统自带的 ModemManager (避免与 VoHive 发生 QMI / AT 端口冲突)
echo "[+] 2. 禁用系统原生 ModemManager，根治串口/QMI 并发冲突..."
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

# 4. 永久关闭 WiFi 节能省电模式 (防 wcn36xx 空闲休眠导致 SSH/Web 假死失联)
echo "[+] 4. 配置 WiFi 永久关闭节能省电模式 (wifi.powersave=2)..."
mkdir -p /etc/NetworkManager/conf.d
cat << 'EOF' > /etc/NetworkManager/conf.d/default-wifi-powersave-off.conf
[connection]
wifi.powersave = 2
EOF
if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    systemctl restart NetworkManager 2>/dev/null || true
fi

# 5. 配置动态默认网关心跳探活保活机制 (防 AP 脱网/假死)
echo "[+] 5. 配置动态默认网关心跳探活保活机制..."
cat << 'EOF' > /usr/local/bin/wifi-keepalive.sh
#!/bin/bash
GW=$(ip route show default 2>/dev/null | awk '/default/ {print $3}' | head -n 1)
[ -z "$GW" ] && GW=$(ip route 2>/dev/null | grep -E '^default' | awk '{print $3}' | head -n 1)
if [ -n "$GW" ]; then
    ping -c 1 -W 2 "$GW" >/dev/null 2>&1 || true
fi
EOF
chmod +x /usr/local/bin/wifi-keepalive.sh

mkdir -p /etc/cron.d
cat << 'EOF' > /etc/cron.d/wifi-keepalive
*/2 * * * * root /usr/local/bin/wifi-keepalive.sh >/dev/null 2>&1
EOF
chmod 644 /etc/cron.d/wifi-keepalive
systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true

# 6. 针对小内存（400MB 可用）的系统级虚拟内存调优
echo "[+] 6. 优化系统虚拟内存与 Swap 参数..."
mkdir -p /etc/sysctl.d
cat << 'EOF' > /etc/sysctl.d/99-vohive-msm8916.conf
# 针对高通 410 小内存环境的虚拟内存调优
vm.swappiness = 100
vm.vfs_cache_pressure = 50
EOF
sysctl -p /etc/sysctl.d/99-vohive-msm8916.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

# 7. 部署早周期硬件 SIM 卡选通服务 (openstick-sim-switch.service)
echo "[+] 7. 部署并启用早周期硬件 SIM 槽位选通服务 (sysinit.target)..."
if [ "$SLOT_MODE" = "internal" ]; then
    # 板载贴片卡
    SIM_EN=0
    SIM_SEL=0
    SIM_EN2=0
    SIM_SEL2=1
    echo "    -> 已配置为: 板载贴片 eSIM 芯片 (sim:sel2=1)"
else
    # 外部 Nano-SIM 卡槽 (含实体可写 eSIM)
    SIM_EN=0
    SIM_SEL=1
    SIM_EN2=0
    SIM_SEL2=0
    echo "    -> 已配置为: 外部 Nano-SIM 物理卡槽 (含实体 eSIM, sim:sel=1)"
fi

cat << EOF > /etc/systemd/system/openstick-sim-switch.service
[Unit]
Description=Switch SIM slot on OpenStick MSM8916
DefaultDependencies=no
After=systemd-modules-load.service
Before=sysinit.target basic.target qrtr-ns.service rmtfs.service modem-init.service vohive.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo $SIM_EN > /sys/class/leds/sim:en/brightness 2>/dev/null; echo $SIM_SEL > /sys/class/leds/sim:sel/brightness 2>/dev/null; echo $SIM_EN2 > /sys/class/leds/sim:en2/brightness 2>/dev/null; echo $SIM_SEL2 > /sys/class/leds/sim:sel2/brightness 2>/dev/null; exit 0"
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

cat << EOF > /etc/rc.local
#!/bin/sh -e
echo $SIM_EN > /sys/class/leds/sim:en/brightness 2>/dev/null || true
echo $SIM_SEL > /sys/class/leds/sim:sel/brightness 2>/dev/null || true
echo $SIM_EN2 > /sys/class/leds/sim:en2/brightness 2>/dev/null || true
echo $SIM_SEL2 > /sys/class/leds/sim:sel2/brightness 2>/dev/null || true
exit 0
EOF
chmod +x /etc/rc.local

# 立即应用引脚状态
echo $SIM_EN > /sys/class/leds/sim:en/brightness 2>/dev/null || true
echo $SIM_SEL > /sys/class/leds/sim:sel/brightness 2>/dev/null || true
echo $SIM_EN2 > /sys/class/leds/sim:en2/brightness 2>/dev/null || true
echo $SIM_SEL2 > /sys/class/leds/sim:sel2/brightness 2>/dev/null || true

# 8. 部署基带自适应初始化常驻脚本 /usr/local/bin/modem-init.sh
echo "[+] 8. 正在生成常驻自适应基带初始化脚本 /usr/local/bin/modem-init.sh ..."
cat << 'EOF' > /usr/local/bin/modem-init.sh
#!/bin/bash
# ==============================================================================
# MSM8916 Modem 自适应初始化常驻脚本 (自动重测 ATR + APN 智能匹配 + 自动选网)
# ==============================================================================

QMI_DEV="/dev/wwan0qmi0"
AT_DEV="/dev/wwan0at0"

# 1. 等待设备节点就绪（最多等待 30 秒）
for i in $(seq 1 30); do
    [ -e "$QMI_DEV" ] && break
    sleep 1
done

[ ! -e "$QMI_DEV" ] && exit 0

# 2. 循环触发一次 SIM 卡上电与 ATR 探测 (防冷启动 absent 状态)
qmicli -d "$QMI_DEV" --uim-sim-power-off=1 >/dev/null 2>&1 || true
sleep 0.5
qmicli -d "$QMI_DEV" --uim-sim-power-on=1 >/dev/null 2>&1 || true
sleep 1.5

# 3. 确保 DMS 在线模式
qmicli -d "$QMI_DEV" --dms-set-operating-mode=online >/dev/null 2>&1 || true

# 4. 读取 IMSI 并智能配置适配运营商的 LTE Attach APN
IMSI=""
for r in $(seq 1 10); do
    IMSI=$(qmicli -d "$QMI_DEV" --dms-uim-get-imsi 2>/dev/null | grep -oE '[0-9]{15}' || true)
    [ -n "$IMSI" ] && break
    sleep 1
done

APN=""
if [[ "$IMSI" =~ ^460(03|11) ]]; then
    APN="ctlte"
elif [[ "$IMSI" =~ ^460(00|02|04|07|08) ]]; then
    APN="cmiot"
elif [[ "$IMSI" =~ ^460(01|06|09) ]]; then
    APN="wonet"
elif [[ "$IMSI" =~ ^248 ]]; then
    APN="globaldata"
fi

if [ -n "$APN" ]; then
    qmicli -d "$QMI_DEV" --wds-modify-profile="3gpp,1,apn=$APN" >/dev/null 2>&1 || true
    qmicli -d "$QMI_DEV" --wds-set-lte-attach-pdn-list='1' >/dev/null 2>&1 || true
fi

# 5. 设置全自动选网 (AUTO)
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
fi

exit 0
EOF
chmod +x /usr/local/bin/modem-init.sh

cat << 'EOF' > /etc/systemd/system/modem-init.service
[Unit]
Description=Qualcomm MSM8916 Modem Auto-Init Service
After=rmtfs.service qrtr-ns.service openstick-sim-switch.service
Before=vohive.service
Wants=rmtfs.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/modem-init.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

# 9. 配置 VoHive 进程资源硬限制 (防 410 小内存 OOM 死机)
echo "[+] 9. 配置 VoHive 服务 Systemd 资源限制 (MemoryMax=90M, CPUQuota=70%)..."
mkdir -p /etc/systemd/system/vohive.service.d
cat << 'EOF' > /etc/systemd/system/vohive.service.d/resource-limits.conf
[Service]
MemoryMax=90M
MemoryHigh=75M
CPUQuota=70%
Environment="GOMAXPROCS=2"
EOF

# 10. 重新加载并使能服务
echo "[+] 10. 正在更新并使能自启服务..."
systemctl daemon-reload
systemctl enable openstick-sim-switch.service modem-init.service

echo "======================================================================"
echo "[✓] 高通 410 (MSM8916 OpenStick) 硬件环境初始化与加固全部完成！"
echo "    - 外部/板载 SIM 卡槽已完成极早期选通"
echo "    - ModemManager 与 NM 冲突死循环已根除"
echo "    - 智能 APN 与全自动选网守护已生效"
echo "    - 512MB 内存加固与 CGroup 硬隔离已部署"
echo "======================================================================"
