#!/bin/bash
# ============================================
# srvpulse 一键部署到 /opt/srvpulse
#
# 推荐用法（Git 部署）:
#   sudo git clone git@github.com:gejigang2008/srvpulse.git /opt/srvpulse
#   cd /opt/srvpulse
#   sudo cp config.yaml.example config.yaml && sudo vim config.yaml
#   sudo ./deploy.sh
#
# 也可在任意已克隆目录执行，脚本会自动同步到 /opt/srvpulse
# ============================================
set -e

INSTALL_DIR="/opt/srvpulse"
GIT_REPO="${SRVPULSE_GIT_REPO:-git@github.com:gejigang2008/srvpulse.git}"
GIT_BRANCH="${SRVPULSE_GIT_BRANCH:-main}"
CRON_FILE="/etc/cron.d/srvpulse"
LOGROTATE_FILE="/etc/logrotate.d/srvpulse"
LOG_FILE="/var/log/srvpulse.log"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

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

# ============ Git 检查 ============
if ! command -v git >/dev/null 2>&1; then
    echo_error "未找到 git，请先安装: yum install -y git  或  apt install -y git"
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

# ============ 同步代码到安装目录 ============
sync_install_dir() {
  if [ -d "$INSTALL_DIR/.git" ]; then
    echo_info "更新代码: $INSTALL_DIR"
    git -C "$INSTALL_DIR" fetch origin "$GIT_BRANCH"
    git -C "$INSTALL_DIR" checkout "$GIT_BRANCH"
    git -C "$INSTALL_DIR" pull --ff-only origin "$GIT_BRANCH"
    return
  fi

  if [ "$SCRIPT_DIR" = "$INSTALL_DIR" ] && [ -d "$SCRIPT_DIR/.git" ]; then
    echo_info "在安装目录中部署: $INSTALL_DIR"
    return
  fi

  if [ -d "$INSTALL_DIR" ] && [ "$(ls -A "$INSTALL_DIR" 2>/dev/null)" ]; then
    echo_error "$INSTALL_DIR 已存在且不是 git 仓库，请手动处理后重试"
    exit 1
  fi

  echo_info "从 Git 克隆到 $INSTALL_DIR ..."
  mkdir -p "$(dirname "$INSTALL_DIR")"
  git clone -b "$GIT_BRANCH" "$GIT_REPO" "$INSTALL_DIR"
}

sync_install_dir

# ============ 安装/更新依赖 ============
echo_info "安装目录: $INSTALL_DIR"

if [ ! -f "$INSTALL_DIR/monitor.py" ]; then
    echo_error "未找到 $INSTALL_DIR/monitor.py，部署失败"
    exit 1
fi

chmod +x "$INSTALL_DIR/monitor.py"

# 配置文件（不覆盖已有配置）
if [ ! -f "$INSTALL_DIR/config.yaml" ]; then
    cp "$INSTALL_DIR/config.yaml.example" "$INSTALL_DIR/config.yaml"
    chmod 600 "$INSTALL_DIR/config.yaml"
    echo_warn "请填写配置文件: $INSTALL_DIR/config.yaml"
else
    echo_info "配置文件已存在，跳过覆盖"
fi

# ============ Python 虚拟环境 ============
if [ ! -d "$INSTALL_DIR/venv" ]; then
    echo_info "创建 Python 虚拟环境..."
    $PYTHON -m venv "$INSTALL_DIR/venv"
else
    echo_info "虚拟环境已存在，跳过创建"
fi

echo_info "安装 Python 依赖..."
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" -q

# ============ 配置校验 ============
echo_info "校验配置文件..."
if "$INSTALL_DIR/venv/bin/python" "$INSTALL_DIR/monitor.py" --check; then
    echo_info "配置校验通过"
else
    echo_error "配置校验失败，请检查 $INSTALL_DIR/config.yaml 后重新部署"
    exit 1
fi

# ============ Cron 定时任务 ============
echo_info "配置 Cron 定时任务..."
cat > "$CRON_FILE" << EOF
# srvpulse 资源监控 - 每5分钟执行一次
*/5 * * * * root cd $INSTALL_DIR && $INSTALL_DIR/venv/bin/python monitor.py >> $LOG_FILE 2>&1
EOF
chmod 644 "$CRON_FILE"

# 清理旧版 cron 配置（如曾部署过 /opt/monitor）
if [ -f /etc/cron.d/monitor ]; then
    echo_warn "检测到旧版 /etc/cron.d/monitor，已移除"
    rm -f /etc/cron.d/monitor
fi

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

if [ -f /etc/logrotate.d/monitor ]; then
    echo_warn "检测到旧版 /etc/logrotate.d/monitor，已移除"
    rm -f /etc/logrotate.d/monitor
fi

# ============ 完成 ============
echo ""
echo_info "========================================"
echo_info "  srvpulse 部署完成！"
echo_info "========================================"
echo ""
echo_info "安装目录:  $INSTALL_DIR"
echo_info "配置文件:  $INSTALL_DIR/config.yaml"
echo_info "日志文件:  $LOG_FILE"
echo_info "Cron 配置: $CRON_FILE"
echo ""
echo_warn "下一步:"
echo "  编辑配置: vim $INSTALL_DIR/config.yaml"
echo "  测试告警: $INSTALL_DIR/venv/bin/python $INSTALL_DIR/monitor.py --test"
echo "  手动执行: $INSTALL_DIR/venv/bin/python $INSTALL_DIR/monitor.py"
echo "  查看日志: tail -f $LOG_FILE"
echo "  更新版本: cd $INSTALL_DIR && git pull && sudo ./deploy.sh"
echo ""
