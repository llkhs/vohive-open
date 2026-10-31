#!/bin/bash
# ==============================================================================
# 高通 MSM8916 (OpenStick / UFI001C / UFI003 / 随身 WiFi) 基带与硬件配置工具
# 支持功能：
#   1. 一键优化基带设置：解决掉卡/断网/CPU 100%/端口冲突/Hexagon DSP 断言崩溃
#   2. 一键恢复原厂设置：完全撤销优化，还原蜂窝自动拨号、解除频段锁、恢复系统原生状态
# 适用环境：Armbian / Debian / Ubuntu (Linux 5.x / 6.x, ARM64 / aarch64)
# ==============================================================================

set -e

[ "$(id -u)" -ne 0 ] && echo "[-] 错误：请使用 root 权限运行此脚本！" && exit 1

ACTION=""
SLOT_MODE="external"
NON_INTERACTIVE=false

# 解析命令行参数
for arg in "$@"; do
    case "$arg" in
        --optimize|--apply)
            ACTION="optimize"
            ;;
        --restore|--revert|--uninstall)
            ACTION="restore"
            ;;
        --internal-sim|--onboard|--slot=internal)
            SLOT_MODE="internal"
            ;;
        --external-sim|--nano-sim|--slot=external)
            SLOT_MODE="external"
            ;;
        --non-interactive|-y)
            NON_INTERACTIVE=true
            ;;
        --help|-h)
            echo "用法: $0 [选项]"
            echo "选项:"
            echo "  --optimize          优化基带设置 (解决掉卡/断网/CPU 100%/端口冲突，推荐)"
            echo "  --restore           恢复原厂基带设置 (完全撤销所有优化)"
            echo "  --slot=external     指定为外部 Nano-SIM 卡槽 (默认)"
            echo "  --slot=internal     指定为板载贴片 eSIM 芯片"
            echo "  --non-interactive   非交互执行 (不等待键盘输入)"
            exit 0
            ;;
    esac
done

print_banner() {
    echo "======================================================================"
    echo "       高通 MSM8916 (OpenStick) 随身 WiFi 基带与硬件配置工具"
    echo "======================================================================"
    echo "  [系统架构] $(uname -m) / 内核: $(uname -r)"
    local qmi_present="否"
    [ -e "/dev/wwan0qmi0" ] && qmi_present="是 (/dev/wwan0qmi0)"
    echo "  [基带接口] $qmi_present"
    echo "----------------------------------------------------------------------"
}

# 若未指定操作，进入终端交互菜单
if [ -z "$ACTION" ]; then
    print_banner
    echo "  请选择操作模式:"
    echo "    1) 优化基带与硬件设置 (推荐：接管卡槽/防断网/防掉线/消除冲突)"
    echo "    2) 恢复原厂设置 (完全撤销所有修改，恢复系统原生蜂窝拨号)"
    echo "    3) 退出"
    echo "----------------------------------------------------------------------"

    if [ "$NON_INTERACTIVE" = true ]; then
        ACTION="optimize"
        echo "[*] 非交互模式，默认选择: [1] 优化基带与硬件设置"
    else
        read -r -p "请输入选项 [1-3, 默认 1]: " user_choice
        case "$user_choice" in
            2)
                ACTION="restore"
                ;;
            3)
                echo "[-] 已取消操作。"
                exit 0
                ;;
            *)
                ACTION="optimize"
                ;;
        esac
    fi

    # 若选择优化模式且未显式指定卡槽，询问卡槽类型
    if [ "$ACTION" = "optimize" ] && [ "$NON_INTERACTIVE" != true ]; then
        echo
        echo "  请选择使用的 SIM 卡槽:"
        echo "    1) 外部 Nano-SIM 物理卡槽 (含外插实体可写 eSIM 卡，推荐)"
        echo "    2) 板载贴片 eSIM / 内部卡槽"
        read -r -p "请输入卡槽选项 [1-2, 默认 1]: " slot_choice
        case "$slot_choice" in
            2)
                SLOT_MODE="internal"
                ;;
            *)
                SLOT_MODE="external"
                ;;
        esac
    fi
    echo "======================================================================"
fi

# ==============================================================================
# 模块 A: 恢复原厂设置 (Restore / Revert)
# ==============================================================================
restore_factory() {
    print_banner
    echo "[*] 正在执行：[2] 恢复原厂基带与硬件默认设置..."
    echo

    # 1. 停止并移除常驻守护服务
    echo "[+] 1. 停止并注销基带常驻守护与选通服务..."
    systemctl disable --now modem-init.service 2>/dev/null || true
    systemctl disable --now openstick-sim-switch.service 2>/dev/null || true
    rm -f /etc/systemd/system/modem-init.service
    rm -f /etc/systemd/system/openstick-sim-switch.service
    rm -f /usr/local/bin/modem-init.sh
    rm -f /usr/local/bin/lock-band3
    systemctl daemon-reload

    # 2. 还原 /etc/rc.local
    echo "[+] 2. 还原 /etc/rc.local 启动自愈脚本..."
    if [ -f "/etc/rc.local.vohive.bak" ]; then
        mv "/etc/rc.local.vohive.bak" /etc/rc.local
        chmod +x /etc/rc.local
        echo "    -> 已恢复原始 /etc/rc.local 备份"
    else
        cat << 'EOF_RC' > /etc/rc.local
#!/bin/sh -e
exit 0
EOF_RC
        chmod +x /etc/rc.local
        echo "    -> 已重置为标准默认 /etc/rc.local"
    fi

    # 3. 恢复 SIM 引脚为默认状态
    echo "[+] 3. 恢复 SIM 选通引脚为默认状态..."
    [ -e /sys/class/leds/sim:sel/brightness ] && echo 0 > /sys/class/leds/sim:sel/brightness 2>/dev/null || true
    [ -e /sys/class/leds/sim:en/brightness ] && echo 0 > /sys/class/leds/sim:en/brightness 2>/dev/null || true
    [ -e /sys/class/leds/sim:sel2/brightness ] && echo 0 > /sys/class/leds/sim:sel2/brightness 2>/dev/null || true
    [ -e /sys/class/leds/sim:en2/brightness ] && echo 0 > /sys/class/leds/sim:en2/brightness 2>/dev/null || true

    # 4. 恢复 NetworkManager 蜂窝自动拨号设置 (让随身 WiFi 恢复上网卡功能)
    echo "[+] 4. 恢复 NetworkManager 蜂窝自动拨号与网络设置..."
    rm -f /etc/NetworkManager/conf.d/99-disable-modem-autoconnect.conf
    rm -f /etc/NetworkManager/conf.d/default-wifi-powersave-off.conf
    rm -f /usr/local/bin/wifi-keepalive.sh /etc/cron.d/wifi-keepalive
    systemctl restart cron 2>/dev/null || systemctl restart crond 2>/dev/null || true

    MODEM_CONF="/etc/NetworkManager/system-connections/modem.nmconnection"
    if [ -f "$MODEM_CONF" ]; then
        sed -i 's/autoconnect=.*/autoconnect=true/g' "$MODEM_CONF" 2>/dev/null || true
        sed -i 's/autoconnect-retries=.*/autoconnect-retries=3/g' "$MODEM_CONF" 2>/dev/null || true
    fi
    if command -v nmcli >/dev/null 2>&1; then
        nmcli connection modify modem connection.autoconnect yes 2>/dev/null || true
    fi
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        systemctl restart NetworkManager 2>/dev/null || true
    fi

    # 5. 恢复系统原生 ModemManager
    echo "[+] 5. 重新解禁原生 ModemManager 服务..."
    systemctl unmask ModemManager 2>/dev/null || true
    systemctl enable ModemManager 2>/dev/null || true
    systemctl start ModemManager 2>/dev/null || true

    # 6. 清理虚拟内存调优与 CGroup 隔离
    echo "[+] 6. 清理系统虚拟内存调优与进程限制..."
    rm -f /etc/sysctl.d/99-vohive-msm8916.conf
    rm -rf /etc/systemd/system/vohive.service.d
    sysctl --system >/dev/null 2>&1 || true

    # 7. 解除频段限制并恢复在线模式
    echo "[+] 7. 恢复基带全频段自动搜索模式与在线状态..."
    QMI_DEV="/dev/wwan0qmi0"
    AT_DEV="/dev/wwan0at0"
    if [ -e "$QMI_DEV" ]; then
        qmicli -p -d "$QMI_DEV" --dms-set-operating-mode=online >/dev/null 2>&1 || true
    fi
    if [ -e "$AT_DEV" ]; then
        perl -e '
            use strict; use IO::Select;
            my $p = "/dev/wwan0at0"; open(my $fh, "+<", $p) or exit 0;
            system("stty -F $p 115200 raw -echo");
            my $sel = IO::Select->new($fh);
            syswrite($fh, "AT+COPS=0\r\n");
            my $b = ""; while($sel->can_read(5.0)){ my $t; last unless sysread($fh,$t,1024); $b.=$t; last if $b=~/(OK|ERROR)/; }
            close($fh);
        ' 2>/dev/null || true
    fi

    echo
    echo "======================================================================"
    echo "[✓] 随身 WiFi 基带与系统硬件设置已成功恢复原厂！"
    echo "    - 所有自愈守护与选通服务已卸载清理"
    echo "    - 蜂窝网络自动拨号与 ModemManager 已恢复可用"
    echo "    - 设备现在已恢复为标准的 Linux 原厂 USB 上网卡环境"
    echo "======================================================================"
}

# ==============================================================================
# 模块 B: 优化基带与硬件设置 (Optimize / Apply)
# ==============================================================================
optimize_hardware() {
    print_banner
    echo "[*] 正在执行：[1] 优化基带与硬件设置..."
    echo "    - 目标卡槽模式: $SLOT_MODE"
    echo

    # 1. 检查必要基础依赖
    echo "[+] 1. 检查基础依赖 (libqmi-utils, perl-base, cron)..."
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        command -v qmicli >/dev/null 2>&1 || apt-get install -y -qq libqmi-utils 2>/dev/null || true
        command -v perl >/dev/null 2>&1 || apt-get install -y -qq perl-base 2>/dev/null || true
        command -v crontab >/dev/null 2>&1 || apt-get install -y -qq cron 2>/dev/null || true
    fi

    # 2. 彻底禁用冲突的 ModemManager (避免与 QMI / AT 产生端口争抢)
    echo "[+] 2. 禁用系统自带 ModemManager，根除串口/QMI 并发争抢冲突..."
    systemctl disable --now ModemManager 2>/dev/null || true
    systemctl mask ModemManager 2>/dev/null || true

    # 3. 根除 NetworkManager 蜂窝自动拨号无限死循环 (防 CPU 100% 满载)
    echo "[+] 3. 关闭 NetworkManager 蜂窝自动拨号，解除 CPU 100% 狂转与死循环..."
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

    # 4. WiFi 防休眠与心跳保活
    echo "[+] 4. 配置 WiFi 永久关闭节能省电模式 (防休眠断连)..."
    cat << 'EOF_NM_WIFI' > /etc/NetworkManager/conf.d/default-wifi-powersave-off.conf
[connection]
wifi.powersave = 2
EOF_NM_WIFI
    if systemctl is-active --quiet NetworkManager 2>/dev/null; then
        systemctl restart NetworkManager 2>/dev/null || true
    fi

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

    # 5. 虚拟内存与 Swap 调优 (适配 512MB/376MB 小内存)
    echo "[+] 5. 优化系统虚拟内存与 Swap 参数 (适配低内存环境)..."
    mkdir -p /etc/sysctl.d
    cat << 'EOF_SYSCTL' > /etc/sysctl.d/99-vohive-msm8916.conf
vm.swappiness = 100
vm.vfs_cache_pressure = 50
EOF_SYSCTL
    sysctl -p /etc/sysctl.d/99-vohive-msm8916.conf >/dev/null 2>&1 || sysctl --system >/dev/null 2>&1 || true

    # 6. 配置早期 SIM 选通引脚 (openstick-sim-switch.service & /etc/rc.local)
    echo "[+] 6. 配置 SIM 卡槽选通引脚与自愈 (模式: $SLOT_MODE)..."
    local sim_en=0
    local sim_sel=1
    local sim_en2=0
    local sim_sel2=0

    if [ "$SLOT_MODE" = "internal" ]; then
        sim_en=0
        sim_sel=0
        sim_en2=0
        sim_sel2=1
        echo "    -> 选通: 板载贴片 eSIM 芯片 (sim:sel2=1)"
    else
        sim_en=0
        sim_sel=1
        sim_en2=0
        sim_sel2=0
        echo "    -> 选通: 外部物理 Nano-SIM 卡槽 (sim:sel=1, sim:en=0)"
    fi

    # 备份原始 /etc/rc.local
    if [ -f "/etc/rc.local" ] && [ ! -f "/etc/rc.local.vohive.bak" ]; then
        cp /etc/rc.local /etc/rc.local.vohive.bak
    fi

    cat << EOF_RCLOCAL > /etc/rc.local
#!/bin/sh -e
# MSM8916 SIM 卡槽引脚开机自愈配置 (模式: $SLOT_MODE)
[ -e /sys/class/leds/sim:en/brightness ] && echo $sim_en > /sys/class/leds/sim:en/brightness 2>/dev/null || true
[ -e /sys/class/leds/sim:sel/brightness ] && echo $sim_sel > /sys/class/leds/sim:sel/brightness 2>/dev/null || true
[ -e /sys/class/leds/sim:en2/brightness ] && echo $sim_en2 > /sys/class/leds/sim:en2/brightness 2>/dev/null || true
[ -e /sys/class/leds/sim:sel2/brightness ] && echo $sim_sel2 > /sys/class/leds/sim:sel2/brightness 2>/dev/null || true
exit 0
EOF_RCLOCAL
    chmod +x /etc/rc.local

    cat << EOF_SIM_SVC > /etc/systemd/system/openstick-sim-switch.service
[Unit]
Description=Switch SIM slot on OpenStick MSM8916
DefaultDependencies=no
After=systemd-modules-load.service
Before=sysinit.target basic.target qrtr-ns.service rmtfs.service modem-init.service vohive.service

[Service]
Type=oneshot
ExecStart=/bin/sh -c "echo $sim_en > /sys/class/leds/sim:en/brightness 2>/dev/null; echo $sim_sel > /sys/class/leds/sim:sel/brightness 2>/dev/null; echo $sim_en2 > /sys/class/leds/sim:en2/brightness 2>/dev/null; echo $sim_sel2 > /sys/class/leds/sim:sel2/brightness 2>/dev/null; exit 0"
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF_SIM_SVC

    # 立即生效引脚
    [ -e /sys/class/leds/sim:en/brightness ] && echo $sim_en > /sys/class/leds/sim:en/brightness 2>/dev/null || true
    [ -e /sys/class/leds/sim:sel/brightness ] && echo $sim_sel > /sys/class/leds/sim:sel/brightness 2>/dev/null || true
    [ -e /sys/class/leds/sim:en2/brightness ] && echo $sim_en2 > /sys/class/leds/sim:en2/brightness 2>/dev/null || true
    [ -e /sys/class/leds/sim:sel2/brightness ] && echo $sim_sel2 > /sys/class/leds/sim:sel2/brightness 2>/dev/null || true

    # 7. 部署安全防崩溃开机驻网脚本 /usr/local/bin/modem-init.sh
    echo "[+] 7. 生成安全防崩溃基带初始化脚本 /usr/local/bin/modem-init.sh ..."
    cat << 'EOF_MODEM_INIT' > /usr/local/bin/modem-init.sh
#!/bin/bash
QMI_DEV="/dev/wwan0qmi0"
AT_DEV="/dev/wwan0at0"

# 1. 等待 QMI 节点就绪
for i in $(seq 1 30); do
    [ -e "$QMI_DEV" ] && break
    sleep 1
done

[ ! -e "$QMI_DEV" ] && exit 0

# 2. 确保基带射频处于 online 模式（严禁处于 low-power 或 shutting-down）
for i in $(seq 1 5); do
    OP_MODE=$(qmicli -p -d "$QMI_DEV" --dms-get-operating-mode 2>/dev/null || true)
    if echo "$OP_MODE" | grep -q "Mode: 'online'"; then
        break
    fi
    qmicli -p -d "$QMI_DEV" --dms-set-operating-mode=online >/dev/null 2>&1 || true
    sleep 2
done

# 3. 等待 SIM 卡自动初始化就绪（绝不下发破坏性的 uim-sim-power-off，避免触发 Hexagon DSP sys_m 复位）
for i in $(seq 1 15); do
    CARD_STATUS=$(qmicli -p -d "$QMI_DEV" --uim-get-card-status 2>/dev/null || true)
    if echo "$CARD_STATUS" | grep -q "Card state: 'present'"; then
        break
    fi
    sleep 1
done

# 4. 锁定 LTE 频段为 Band 1+3 (若包含 lock-band3 工具)
[ -x /usr/local/bin/lock-band3 ] && /usr/local/bin/lock-band3 >/dev/null 2>&1 || true

# 5. 检查是否已经正常驻网
SERV_INFO=$(qmicli -p -d "$QMI_DEV" --nas-get-serving-system 2>/dev/null || true)
if echo "$SERV_INFO" | grep -q "Registration state: 'registered'"; then
    exit 0
fi

# 6. 优先尝试自动选网 (AUTO)
if [ -e "$AT_DEV" ]; then
    perl -e '
        use strict; use IO::Select;
        my $p = "/dev/wwan0at0"; open(my $fh, "+<", $p) or exit 0;
        system("stty -F $p 115200 raw -echo");
        my $sel = IO::Select->new($fh);
        syswrite($fh, "AT+COPS=0\r\n");
        my $b = ""; while($sel->can_read(8.0)){ my $t; last unless sysread($fh,$t,1024); $b.=$t; last if $b=~/(OK|ERROR)/; }
        close($fh);
    ' 2>/dev/null || true
    sleep 3
fi

# 7. 若仍未附着，依次尝试联通(46001)、移动(46000)、电信(46011)
SERV_INFO=$(qmicli -p -d "$QMI_DEV" --nas-get-serving-system 2>/dev/null || true)
if ! echo "$SERV_INFO" | grep -q "Registration state: 'registered'"; then
    for TARGET_PLMN in "46001" "46000" "46011"; do
        perl -e "
            use strict; use IO::Select;
            my \$p = '/dev/wwan0at0'; open(my \$fh, '+<', \$p) or exit 0;
            system('stty -F \$p 115200 raw -echo');
            my \$sel = IO::Select->new(\$fh);
            syswrite(\$fh, qq(AT+COPS=1,2,\\\"$TARGET_PLMN\\\",7\\r\\n));
            my \$b = ''; while(\$sel->can_read(10.0)){ my \$t; last unless sysread(\$fh,\\$t,1024); \$b.=\\$t; last if \$b=~/(OK|ERROR|\\+CME ERROR)/; }
            close(\$fh);
        " 2>/dev/null || true
        sleep 2
        SERV_INFO=$(qmicli -p -d "$QMI_DEV" --nas-get-serving-system 2>/dev/null || true)
        echo "$SERV_INFO" | grep -q "Registration state: 'registered'" && break
    done
fi

exit 0
EOF_MODEM_INIT
    chmod +x /usr/local/bin/modem-init.sh

    cat << 'EOF_MODEM_SVC' > /etc/systemd/system/modem-init.service
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
EOF_MODEM_SVC

    # 8. 配置 VoHive 进程 Systemd 资源隔离
    echo "[+] 8. 配置 VoHive 进程资源隔离 (MemoryMax=90M, CPUQuota=70%, GOMAXPROCS=2)..."
    mkdir -p /etc/systemd/system/vohive.service.d
    cat << 'EOF_LIMIT' > /etc/systemd/system/vohive.service.d/resource-limits.conf
[Service]
MemoryMax=90M
MemoryHigh=75M
CPUQuota=70%
Environment="GOMAXPROCS=2"
EOF_LIMIT

    # 9. 重载服务并自启
    echo "[+] 9. 正在更新并使能自启服务 (openstick-sim-switch / modem-init)..."
    systemctl daemon-reload
    systemctl enable openstick-sim-switch.service modem-init.service 2>/dev/null || true

    echo
    echo "======================================================================"
    echo "[✓] 高通 MSM8916 (OpenStick) 基带与硬件优化全部完成！"
    echo "    - 外部 Nano-SIM 卡槽已完成极早期选通并固化"
    echo "    - 根除 ModemManager 与 NetworkManager 串口争抢与 CPU 100% 满载"
    echo "    - 部署安全在线模式探测与自动注网守护 (防 DSP 崩溃断言)"
    echo "    - 512MB 内存加固与 CGroup 硬隔离已部署"
    echo "======================================================================"
}

# 执行对应操作
case "$ACTION" in
    restore)
        restore_factory
        ;;
    optimize)
        optimize_hardware
        ;;
    *)
        echo "[-] 未知操作: $ACTION"
        exit 1
        ;;
esac
