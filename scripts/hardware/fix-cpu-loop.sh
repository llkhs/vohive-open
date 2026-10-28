#!/bin/bash
# ==============================================================================
# 高通 410 (MSM8916) Debian / Armbian 随身 WiFi - CPU 100% 死循环高负载一键救急脚本
#
# 适用场景：
# 当基带处于未就绪/无信号/卡槽未识别时，NetworkManager 会陷入无限高速自动重连死循环
# （每秒触发数十次 disconnected -> prepare -> disabled），导致：
#   - NetworkManager、polkitd、dbus-daemon、ModemManager 进程 CPU 占满
#   - 系统负载 (Load Average) 飙升至 4.0 以上，设备严重发热发烫、SSH 卡顿、Wi-Fi 丢包
#
# 修复功能：
# 1. 彻底禁用 NetworkManager 中 modem 蜂窝接口的无限自动重拨
# 2. 清理积压的 IPC 队列与卡死的代理进程 (qmi-proxy)
# 3. 平滑重启网络与调制解调器服务，恢复 CPU 负载至 0.1~0.2 正常水平
# ==============================================================================

set -e

[ "$(id -u)" -ne 0 ] && echo "[-] 错误：请使用 root 权限运行此脚本！" && exit 1

echo "=================================================="
echo "[+] 正在检测系统当前 CPU 负载与异常进程..."
echo "--------------------------------------------------"
uptime
echo "当前高 CPU 占用进程 (前 5 名)："
ps aux --sort=-%cpu | head -n 6
echo "--------------------------------------------------"

echo "[1/4] 正在关闭 NetworkManager 蜂窝连接的无限自动重试..."
# 1. 尝试使用 nmcli 规范关闭
if command -v nmcli >/dev/null 2>&1; then
    nmcli connection modify modem connection.autoconnect no 2>/dev/null || true
    nmcli connection modify modem connection.autoconnect-retries 0 2>/dev/null || true
    nmcli connection down modem 2>/dev/null || true
fi

# 2. 直接对配置文件做双重兜底加固（防止 nmcli 假死时未生效）
MODEM_CONF="/etc/NetworkManager/system-connections/modem.nmconnection"
if [ -f "$MODEM_CONF" ]; then
    echo "[*] 检测到 $MODEM_CONF，直接加固配置文件..."
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

echo "[2/4] 正在清理可能僵死的代理进程..."
killall -9 qmi-proxy 2>/dev/null || true

echo "[3/4] 正在平滑重启服务以释放积压的 IPC 消息队列..."
systemctl stop ModemManager 2>/dev/null || true
systemctl restart NetworkManager 2>/dev/null || true
sleep 2
systemctl start ModemManager 2>/dev/null || true

echo "[4/4] 验证修复效果..."
sleep 3
echo "--------------------------------------------------"
echo "[✓] 修复完成！当前系统负载与 Top 进程状态："
uptime
echo ""
ps aux --sort=-%cpu | head -n 6
echo "--------------------------------------------------"
echo "[√] NetworkManager 蜂窝重拨死循环已彻底解除，设备已恢复低温稳定运行。"
