#!/bin/bash
# ============================================
# srvpulse 卸载脚本
# 用法: sudo ./uninstall.sh
# ============================================
set -e

INSTALL_DIR="/opt/srvpulse"
CRON_FILE="/etc/cron.d/srvpulse"
LOGROTATE_FILE="/etc/logrotate.d/srvpulse"
LOG_FILE="/var/log/srvpulse.log"

# 旧版路径（v1.0 兼容清理）
LEGACY_INSTALL_DIR="/opt/monitor"
LEGACY_CRON_FILE="/etc/cron.d/monitor"
LEGACY_LOGROTATE_FILE="/etc/logrotate.d/monitor"
LEGACY_LOG_FILE="/var/log/monitor.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    echo_error "请使用 root 权限运行: sudo ./uninstall.sh"
    exit 1
fi

echo_info "移除 srvpulse Cron 任务..."
rm -f "$CRON_FILE"

echo_info "删除 srvpulse 安装目录..."
rm -rf "$INSTALL_DIR"

echo_info "删除 srvpulse 日志轮转配置..."
rm -f "$LOGROTATE_FILE"

echo_info "清理 srvpulse 日志文件..."
rm -f "$LOG_FILE"

# 旧版清理
if [ -f "$LEGACY_CRON_FILE" ] || [ -d "$LEGACY_INSTALL_DIR" ]; then
    echo_warn "检测到旧版 monitor 安装，一并清理..."
    rm -f "$LEGACY_CRON_FILE"
    rm -f "$LEGACY_LOGROTATE_FILE"
    rm -f "$LEGACY_LOG_FILE"
    rm -rf "$LEGACY_INSTALL_DIR"
fi

echo ""
echo_info "srvpulse 卸载完成"
