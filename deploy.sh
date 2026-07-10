#!/bin/bash
# ============================================
# srvpulse install script (run inside cloned repo)
#
# First deploy:
#   sudo git clone git@github.com:gejigang2008/srvpulse.git /opt/srvpulse
#   cd /opt/srvpulse
#   sudo ./deploy.sh
#
# Debian/Ubuntu without python3-venv:
#   sudo ./deploy.sh --system-python
#
# Update:
#   cd /opt/srvpulse && git pull && sudo ./deploy.sh
# ============================================
set -e

INSTALL_DIR="$(cd "$(dirname "$0")" && pwd)"
CRON_FILE="/etc/cron.d/srvpulse"
LOGROTATE_FILE="/etc/logrotate.d/srvpulse"
LOG_FILE="/var/log/srvpulse.log"
CONFIG_FILE="$INSTALL_DIR/config.yaml"

INTERACTIVE=0
USE_VENV=1
for arg in "$@"; do
    case "$arg" in
        --interactive|-i) INTERACTIVE=1 ;;
        --system-python|-s) USE_VENV=0 ;;
        -h|--help)
            echo "Usage: sudo ./deploy.sh [options]"
            echo "  --interactive, -i     Interactive Feishu webhook/secret setup"
            echo "  --system-python, -s   Use system python3 (no venv)"
            echo ""
            echo "Run this script from the srvpulse repo directory after git clone."
            exit 0
            ;;
    esac
done

if [ -n "${SRVPULSE_NO_VENV:-}" ]; then
    USE_VENV=0
fi

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
echo_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
echo_error() { echo -e "${RED}[ERROR]${NC} $1"; }

if [ "$EUID" -ne 0 ]; then
    echo_error "Please run as root: sudo ./deploy.sh"
    exit 1
fi

PYTHON=$(command -v python3 || true)
if [ -z "$PYTHON" ]; then
    echo_error "python3 not found, need Python 3.6+"
    exit 1
fi

PYTHON_VERSION=$($PYTHON --version 2>&1 | awk '{print $2}')
echo_info "Python version: $PYTHON_VERSION"

if ! $PYTHON -c 'import sys; raise SystemExit(0 if sys.version_info >= (3, 6) else 1)'; then
    echo_error "Python 3.6+ required, current: $PYTHON_VERSION"
    exit 1
fi

PYTHON_MAJOR_MINOR=$($PYTHON -c 'import sys; print("{}.{}".format(sys.version_info.major, sys.version_info.minor))')

if [ ! -f "$INSTALL_DIR/monitor.py" ]; then
    echo_error "monitor.py not found, run inside srvpulse repo directory"
    exit 1
fi

chmod +x "$INSTALL_DIR/monitor.py"
echo_info "Install directory: $INSTALL_DIR"

install_apt_packages() {
    local packages=("$@")
    if ! command -v apt-get >/dev/null 2>&1; then
        return 1
    fi
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get install -y "${packages[@]}"
}

install_venv_system_package() {
    if install_apt_packages "python${PYTHON_MAJOR_MINOR}-venv"; then
        return 0
    fi
    echo_warn "Trying package python3-venv ..."
    install_apt_packages python3-venv
}

ensure_system_pip() {
    if $PYTHON -m pip --version >/dev/null 2>&1; then
        return 0
    fi
    echo_info "Installing python3-pip ..."
    if install_apt_packages python3-pip; then
        return 0
    fi
    echo_error "pip not available. Try: apt install python3-pip"
    exit 1
}

venv_is_usable() {
    [ -x "$INSTALL_DIR/venv/bin/python" ] && [ -x "$INSTALL_DIR/venv/bin/pip" ]
}

create_virtualenv() {
    if venv_is_usable; then
        echo_info "Virtualenv exists, skip create"
        return
    fi

    if [ -d "$INSTALL_DIR/venv" ]; then
        echo_warn "Removing incomplete venv directory ..."
        rm -rf "$INSTALL_DIR/venv"
    fi

    echo_info "Creating virtualenv ..."
    if $PYTHON -m venv "$INSTALL_DIR/venv"; then
        return
    fi

    echo_warn "venv failed (often missing python3-venv on Debian/Ubuntu)"
    if install_venv_system_package; then
        echo_info "Retry creating virtualenv ..."
        if $PYTHON -m venv "$INSTALL_DIR/venv"; then
            return
        fi
    fi

    echo_error "Cannot create virtualenv. Options:"
    echo "  apt install python${PYTHON_MAJOR_MINOR}-venv && sudo ./deploy.sh"
    echo "  sudo ./deploy.sh --system-python"
    exit 1
}

setup_python_runtime() {
    if [ "$USE_VENV" = "1" ]; then
        create_virtualenv
        if ! venv_is_usable; then
            echo_error "Virtualenv is incomplete (missing python or pip)"
            exit 1
        fi
        RUN_PYTHON="$INSTALL_DIR/venv/bin/python"
        echo_info "Using virtualenv: $RUN_PYTHON"
        echo_info "Installing Python dependencies ..."
        "$INSTALL_DIR/venv/bin/pip" install -r "$INSTALL_DIR/requirements.txt" -q
        return
    fi

    echo_info "Using system Python (no venv)"
    if [ -d "$INSTALL_DIR/venv" ]; then
        echo_warn "Removing unused venv directory ..."
        rm -rf "$INSTALL_DIR/venv"
    fi
    ensure_system_pip
    RUN_PYTHON="$PYTHON"
    echo_info "Installing Python dependencies ..."
    $PYTHON -m pip install -r "$INSTALL_DIR/requirements.txt" -q
}

setup_python_runtime

if [ ! -f "$CONFIG_FILE" ]; then
    cp "$INSTALL_DIR/config.yaml.example" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    echo_info "Created config from template: $CONFIG_FILE"
else
    echo_info "Config exists: $CONFIG_FILE"
fi

config_needs_feishu_setup() {
    ! $RUN_PYTHON - "$CONFIG_FILE" <<'PY'
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
    echo_info "Interactive Feishu bot setup (signature required)"
    read -rp "Webhook URL: " webhook_url
    read -rsp "Secret: " secret
    echo ""

    if [ -z "$webhook_url" ] || [ -z "$secret" ]; then
        echo_error "Webhook URL and Secret cannot be empty"
        exit 1
    fi

    WEBHOOK_URL="$webhook_url" SECRET="$secret" $RUN_PYTHON - "$CONFIG_FILE" <<'PY'
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
    echo_info "Feishu config saved to $CONFIG_FILE"
}

ensure_feishu_config() {
    if ! config_needs_feishu_setup; then
        echo_info "Feishu config OK"
        return
    fi

    echo_warn "Feishu config missing or still using template placeholders"

    if [ "$INTERACTIVE" = "1" ]; then
        interactive_feishu_config
    elif [ -t 0 ] && [ -t 1 ]; then
        read -rp "Configure Feishu interactively now? [Y/n] " answer
        case "${answer:-Y}" in
            [Yy]*)
                interactive_feishu_config
                ;;
            *)
                echo_error "Complete config first:"
                echo "  vim $CONFIG_FILE"
                echo "  or: sudo ./deploy.sh --interactive"
                exit 1
                ;;
        esac
    else
        echo_error "Non-interactive terminal, configure first:"
        echo "  vim $CONFIG_FILE"
        echo "  or: sudo ./deploy.sh --interactive"
        exit 1
    fi

    if config_needs_feishu_setup; then
        echo_error "Feishu config still incomplete"
        exit 1
    fi
}

ensure_feishu_config

echo_info "Validating config ..."
if $RUN_PYTHON "$INSTALL_DIR/monitor.py" --check; then
    echo_info "Config validation passed"
else
    echo_error "Config validation failed, check $CONFIG_FILE"
    exit 1
fi

echo_info "Configuring cron ..."
cat > "$CRON_FILE" << EOF
# srvpulse - every 5 minutes
*/5 * * * * root cd $INSTALL_DIR && $RUN_PYTHON monitor.py >> $LOG_FILE 2>&1
EOF
chmod 644 "$CRON_FILE"

echo_info "Configuring logrotate ..."
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

echo ""
echo_info "========================================"
echo_info "  srvpulse deploy complete"
echo_info "========================================"
echo ""
echo_info "Install dir: $INSTALL_DIR"
echo_info "Config:      $CONFIG_FILE"
echo_info "Log:         $LOG_FILE"
echo_info "Cron:        $CRON_FILE"
echo_info "Python:      $RUN_PYTHON"
echo ""
echo_info "Verify:"
echo "  $RUN_PYTHON $INSTALL_DIR/monitor.py --test"
echo "  $RUN_PYTHON $INSTALL_DIR/monitor.py"
echo "  tail -f $LOG_FILE"
echo ""
