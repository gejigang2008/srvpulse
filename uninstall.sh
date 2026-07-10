#!/bin/bash
# ============================================
# 卸载脚本
# 用法: sudo ./uninstall.sh
# ============================================
set -e

INSTALL_DIR="/opt/monitor"
CRON_FILE="/etc/cron.d/monitor"
LOGROTATE_FILE="/etc/logrotate.d/monitor"
LOG_FILE="/var/log/monitor.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'

echo_info() { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    echo_error "请使用 root 权限运行: sudo ./uninstall.sh"
    exit 1
fi

echo_info "移除 Cron 任务..."
rm -f "$CRON_FILE"

echo_info "删除安装目录..."
rm -rf "$INSTALL_DIR"

echo_info "删除日志轮转配置..."
rm -f "$LOGROTATE_FILE"

echo_info "清理日志文件..."
rm -f "$LOG_FILE"

echo ""
echo_info "卸载完成"