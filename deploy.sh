#!/bin/bash
# ============================================
# srvpulse 安装脚本（在已克隆的仓库目录内执行）
#
# 首次部署:
#   sudo git clone git@github.com:gejigang2008/srvpulse.git /opt/srvpulse
#   cd /opt/srvpulse
#   sudo ./deploy.sh
#
# 更新版本:
#   cd /opt/srvpulse && git pull && sudo ./deploy.sh
# ============================================
set -e

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
CRON_FILE="/etc/cron.d/srvpulse"
LOGROTATE_FILE="/etc/logrotate.d/srvpulse"
LOG_FILE="/var/log/srvpulse.log"
CONFIG_FILE="$INSTALL_DIR/config.yaml"

INTERACTIVE=0
for arg in "$@"; do
    case "$arg" in
        --interactive|-i) INTERACTIVE=1 ;;
        -h|--help)
            echo "用法: sudo ./deploy.sh [--interactive]"
            echo "  --interactive  强制交互式填写飞书 webhook 与 secret"
            echo ""
            echo "说明: 请先在目标目录 git clone 代码，再在本脚本所在目录执行。"
            exit 0
            ;;
    esac
done

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

# ============ 安装目录检查 ============
if [ ! -f "$INSTALL_DIR/monitor.py" ]; then
    echo_error "未找到 monitor.py，请在 srvpulse 仓库目录内运行本脚本"
    exit 1
fi

chmod +x "$INSTALL_DIR/monitor.py"
echo_info "安装目录: $INSTALL_DIR"

# ============ Python 虚拟环境 ============
if [ ! -d "$INSTALL_DIR/venv" ]; then
    echo_info "创建 Python 虚拟环境..."
    $PYTHON -m venv "$INSTALL_DIR/venv"
else
    echo_info "虚拟环境已存在，跳过创建"
fi

echo_info "安装 Python 依赖..."
"$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" -q

VENV_PYTHON="$INSTALL_DIR/venv/bin/python"

# ============ 配置文件 ============
if [ ! -f "$CONFIG_FILE" ]; then
    cp "$INSTALL_DIR/config.yaml.example" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo_info "已从模板创建配置文件: $CONFIG_FILE"
else
    echo_info "配置文件已存在: $CONFIG_FILE"
fi

config_needs_feishu_setup() {
    ! $VENV_PYTHON - "$CONFIG_FILE" <<'PY'
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

feishu = cfg.get("feishu", {})
url = str(feishu.get("webhook_url", "")).strip()
secret = str(feishu.get("secret", "")).strip()

needs = (
    not url
    or not secret
    or "xxxxxxxxxx" in url
    or secret == "YOUR_SECRET_KEY"
)
sys.exit(0 if needs else 1)
PY
}

interactive_feishu_config() {
    local webhook_url secret

    echo ""
    echo_info "交互式配置飞书机器人（需开启签名校验）"
    read -rp "Webhook URL: " webhook_url
    read -rsp "Secret: " secret
    echo ""

    if [ -z "$webhook_url" ] || [ -z "$secret" ]; then
        echo_error "Webhook URL 和 Secret 不能为空"
        exit 1
    fi

    WEBHOOK_URL="$webhook_url" SECRET="$secret" $VENV_PYTHON - "$CONFIG_FILE" <<'PY'
import os
import sys
import yaml

path = sys.argv[1]
with open(path, encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

cfg.setdefault("feishu", {})
cfg["feishu"]["webhook_url"] = os.environ["WEBHOOK_URL"]
cfg["feishu"]["secret"] = os.environ["SECRET"]

with open(path, "w", encoding="utf-8") as f:
    yaml.dump(cfg, f, allow_unicode=True, default_flow_style=False, sort_keys=False)
PY

    chmod 600 "$CONFIG_FILE"
    echo_info "飞书配置已写入 $CONFIG_FILE"
}

ensure_feishu_config() {
    if ! config_needs_feishu_setup; then
        echo_info "飞书配置检查通过"
        return
    fi

    echo_warn "飞书配置未填写或仍为模板占位符"

    if [ "$INTERACTIVE" = "1" ]; then
        interactive_feishu_config
    elif [ -t 0 ] && [ -t 1 ]; then
        read -rp "是否现在交互式配置飞书? [Y/n] " answer
        case "${answer:-Y}" in
            [Yy]*)
                interactive_feishu_config
                ;;
            *)
                echo_error "请先完成配置后再部署:"
                echo "  vim $CONFIG_FILE"
                echo "  或: sudo ./deploy.sh --interactive"
                exit 1
                ;;
        esac
    else
        echo_error "非交互终端无法自动配置，请先完成配置:"
        echo "  vim $CONFIG_FILE"
        echo "  或: sudo ./deploy.sh --interactive"
        exit 1
    fi

    if config_needs_feishu_setup; then
        echo_error "飞书配置仍不完整，部署中止"
        exit 1
    fi
}

ensure_feishu_config

# ============ 配置校验 ============
echo_info "校验配置文件..."
if $VENV_PYTHON "$INSTALL_DIR/monitor.py" --check; then
    echo_info "配置校验通过"
else
    echo_error "配置校验失败，请检查 $CONFIG_FILE"
    exit 1
fi

# ============ Cron 定时任务 ============
echo_info "配置 Cron 定时任务..."
cat > "$CRON_FILE" << EOF
# srvpulse 资源监控 - 每5分钟执行一次
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
echo_info "  srvpulse 部署完成！"
echo_info "========================================"
echo ""
echo_info "安装目录:  $INSTALL_DIR"
echo_info "配置文件:  $CONFIG_FILE"
echo_info "日志文件:  $LOG_FILE"
echo_info "Cron 配置: $CRON_FILE"
echo ""
echo_info "建议验证:"
echo "  测试告警: $INSTALL_DIR/venv/bin/python $INSTALL_DIR/monitor.py --test"
echo "  手动执行: $INSTALL_DIR/venv/bin/python $INSTALL_DIR/monitor.py"
echo "  查看日志: tail -f $LOG_FILE"
echo ""
