#!/bin/bash
# ============================================
# 一键部署到 /opt/monitor
# 用法: sudo ./deploy.sh
# ============================================
set -e

INSTALL_DIR="/opt/monitor"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CRON_FILE="/etc/cron.d/monitor"
LOGROTATE_FILE="/etc/logrotate.d/monitor"
LOG_FILE="/var/log/monitor.log"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

# ============ 权限检查 ============
if [ "$EUID" -ne 0 ]; then
    echo_error "请使用 root 权限运行: sudo ./deploy.sh"
    exit 1
fi

# ============ Python 版本检查 ============
PYTHON=$(command -v python3 || true)
if [ -z "$PYTHON" ]; then
    echo_error "未找到 python3，请先安装 Python 3.6+"
    exit 1
fi

PYTHON_VERSION=$($PYTHON --version 2>&1 | awk '{print $2}')
echo_info "Python 版本: $PYTHON_VERSION"

if ! $PYTHON -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 6) else 1)'; then
    echo_error "需要 Python 3.6 或更高版本，当前: $PYTHON_VERSION"
    exit 1
fi

# ============ 安装文件 ============
echo_info "创建安装目录: $INSTALL_DIR"
mkdir -p "$INSTALL_DIR"

echo_info "复制程序文件..."
cp "$SCRIPT_DIR/monitor.py" "$INSTALL_DIR/"
cp "$SCRIPT_DIR/requirements.txt" "$INSTALL_DIR/"
chmod +x "$INSTALL_DIR/monitor.py"

# 配置文件（不覆盖已有配置）
if [ ! -f "$INSTALL_DIR/config.yaml" ]; then
    cp "$SCRIPT_DIR/config.yaml.example" "$INSTALL_DIR/config.yaml"
    chmod 600 "$INSTALL_DIR/config.yaml"
    echo_warn "请填写配置文件: $INSTALL_DIR/config.yaml"
else
    echo_info "配置文件已存在，跳过覆盖"
fi

# ============ Python 虚拟环境 ============
echo_info "创建 Python 虚拟环境..."
$PYTHON -m venv "$INSTALL_DIR/venv"

echo_info "安装 Python 依赖..."
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" -q

# ============ 配置校验 ============
echo_info "校验配置文件..."
if "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/monitor.py" --check; then
    echo_info "配置校验通过"
else
    echo_error "配置校验失败，请检查配置文件后重新部署"
    exit 1
fi

# ============ Cron 定时任务 ============
echo_info "配置 Cron 定时任务..."
cat > "$CRON_FILE" << EOF
# 服务器资源监控 - 每5分钟执行一次
*/5 * * * * root cd $INSTALL_DIR && $INSTALL_DIR/venv/bin/python monitor.py >> $LOG_FILE 2>&1
EOF
chmod 644 "$CRON_FILE"

# ============ 日志轮转 ============
echo_info "配置日志轮转..."
cat > "$LOGROTATE_FILE" << EOF
$LOG_FILE {
    daily
    rotate 7
    compress
    missingok
    notifempty
    copytruncate
}
EOF
chmod 644 "$LOGROTATE_FILE"

# ============ 完成 ============
echo ""
echo_info "========================================"
echo_info "  部署完成！"
echo_info "========================================"
echo ""
echo_info "安装目录:  $INSTALL_DIR"
echo_info "配置文件:  $INSTALL_DIR/config.yaml"
echo_info "日志文件:  $LOG_FILE"
echo_info "Cron 配置: $CRON_FILE"
echo ""
echo_warn "下一步（可选）:"
echo "  测试告警: $INSTALL_DIR/venv/bin/python $INSTALL_DIR/monitor.py --test"
echo "  手动执行: $INSTALL_DIR/venv/bin/python $INSTALL_DIR/monitor.py"
echo "  查看日志: tail -f $LOG_FILE"
echo ""