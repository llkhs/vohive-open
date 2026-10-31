#!/bin/bash
# ==============================================================================
# VoHive 一键完全卸载与原厂基带恢复向导
# 适用平台：Linux (ARM64 / aarch64, x86_64 / amd64, ARMv7)
# ==============================================================================

set -e

[ "$(id -u)" -ne 0 ] && echo "[-] 错误：请使用 root 权限运行此脚本：sudo bash $0" && exit 1

VOHIVE_DIR="/opt/vohive"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RESTORE_MODEM=true
NON_INTERACTIVE=false

for arg in "$@"; do
    case "$arg" in
        --keep-modem)
            RESTORE_MODEM=false
            ;;
        --restore-modem)
            RESTORE_MODEM=true
            ;;
        --non-interactive|-y)
            NON_INTERACTIVE=true
            ;;
    esac
done

echo "======================================================================"
echo "               VoHive 完全卸载与环境清理向导                         "
echo "======================================================================"

# 1. 停止并禁用主服务
echo "[+] 1. 正在停止并注销 VoHive 核心服务..."
systemctl disable --now vohive 2>/dev/null || true
rm -f /etc/systemd/system/vohive.service
rm -rf /etc/systemd/system/vohive.service.d
systemctl daemon-reload

# 2. 清理安装目录
echo "[+] 2. 正在清理 VoHive 应用程序目录 ($VOHIVE_DIR)..."
rm -rf "$VOHIVE_DIR"

# 3. 随身 WiFi 基带调优状态检测与原厂恢复询问
IS_OPENSTICK=false
if [ -e "/dev/wwan0qmi0" ] || [ -f "/etc/systemd/system/modem-init.service" ] || [ -f "/etc/systemd/system/openstick-sim-switch.service" ]; then
    IS_OPENSTICK=true
fi

if [ "$IS_OPENSTICK" = true ]; then
    echo "----------------------------------------------------------------------"
    echo "[*] 检测到本机已部署随身 WiFi (MSM8916) 基带优化与硬件卡槽接管设置。"
    
    DO_RESTORE="$RESTORE_MODEM"
    if [ "$NON_INTERACTIVE" != true ]; then
        read -r -p "是否同时将基带与硬件配置恢复为原厂状态（恢复蜂窝自动拨号/解除频段锁）？[Y/n, 默认 Y]: " user_choice
        case "$user_choice" in
            [nN]|[nN][oO])
                DO_RESTORE=false
                ;;
            *)
                DO_RESTORE=true
                ;;
        esac
    fi

    if [ "$DO_RESTORE" = true ]; then
        echo
        SETUP_SCRIPT="$SCRIPT_DIR/hardware/openstick-msm8916-setup.sh"
        if [ ! -f "$SETUP_SCRIPT" ]; then
            SETUP_SCRIPT="/tmp/openstick-msm8916-setup.sh"
            curl -fsSL "https://raw.githubusercontent.com/llkhs/vohive-open/main/scripts/hardware/openstick-msm8916-setup.sh" -o "$SETUP_SCRIPT" 2>/dev/null || true
        fi

        if [ -f "$SETUP_SCRIPT" ]; then
            bash "$SETUP_SCRIPT" --restore
        else
            echo "[-] 警告：未找到基带恢复脚本，跳过基带原厂还原"
        fi
    else
        echo "[*] 已保留随身 WiFi 优化配置与自愈守护。"
    fi
fi

echo
echo "======================================================================"
echo "[✓] VoHive 核心组件与运行环境已成功卸载完毕！"
echo "======================================================================"
