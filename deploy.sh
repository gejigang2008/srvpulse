#!/bin/bash
# ============================================
# srvpulse install script (run inside cloned repo)
#
# First deploy:
#   sudo git clone git@github.com:gejigang2008/srvpulse.git /opt/srvpulse
#   cd /opt/srvpulse
#   sudo ./deploy.sh
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
for arg in "$@"; do
    case "$arg" in
        --interactive|-i) INTERACTIVE=1 ;;
        -h|--help)
            echo "Usage: sudo ./deploy.sh [options]"
            echo "  --interactive, -i     Interactive Feishu webhook/secret setup"
            echo ""
            echo "Run this script from the srvpulse repo directory after git clone."
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

read_tty() {
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        read -r "$@" </dev/tty
    else
        read -r "$@"
    fi
}

read_secret_tty() {
    if [ -r /dev/tty ] && [ -w /dev/tty ]; then
        read -rs "$@" </dev/tty
    else
        read -rs "$@"
    fi
}

can_interact() {
    [ "$INTERACTIVE" = "1" ] || [ -t 0 ] || { [ -r /dev/tty ] && [ -w /dev/tty ]; }
}

mask_secret() {
    local s="$1"
    local len=${#s}
    if [ "$len" -le 4 ]; then
        echo "****"
    else
        echo "${s:0:4}****"
    fi
}

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

setup_python_runtime() {
    if [ -d "$INSTALL_DIR/venv" ]; then
        echo_warn "Removing legacy venv directory ..."
        rm -rf "$INSTALL_DIR/venv"
    fi
    ensure_system_pip
    RUN_PYTHON="$PYTHON"
    echo_info "Installing Python dependencies ..."
    $PYTHON -m pip install -r "$INSTALL_DIR/requirements.txt" -q
}

setup_python_runtime

CONFIG_JUST_CREATED=0
if [ ! -f "$CONFIG_FILE" ]; then
    cp "$INSTALL_DIR/config.yaml.example" "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
    CONFIG_JUST_CREATED=1
    echo_info "Created config from template: $CONFIG_FILE"
else
    echo_info "Config exists: $CONFIG_FILE"
fi

load_feishu_config() {
    eval "$($RUN_PYTHON - "$CONFIG_FILE" <<'PY'
import shlex
import sys
import yaml

with open(sys.argv[1], encoding="utf-8") as f:
    cfg = yaml.safe_load(f) or {}

feishu = cfg.get("feishu", {})
url = str(feishu.get("webhook_url", "")).strip()
secret = str(feishu.get("secret", "")).strip()

placeholder = (
    not url
    or not secret
    or "xxxxxxxxxx" in url
    or secret == "YOUR_SECRET_KEY"
)

print("FEISHU_URL=" + shlex.quote(url))
print("FEISHU_SECRET=" + shlex.quote(secret))
print("FEISHU_IS_PLACEHOLDER=" + ("1" if placeholder else "0"))
PY
)"
}

save_feishu_config() {
    local webhook_url="$1"
    local secret="$2"

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

interactive_feishu_config() {
    local default_url="${1:-}"
    local default_secret="${2:-}"
    local webhook_url secret url_default secret_default

    if [ -n "$default_url" ] && [[ "$default_url" != *"xxxxxxxxxx"* ]]; then
        url_default="$default_url"
    fi
    if [ -n "$default_secret" ] && [ "$default_secret" != "YOUR_SECRET_KEY" ]; then
        secret_default="$default_secret"
    fi

    echo ""
    echo_info "========================================"
    echo_info "  Feishu bot setup (required)"
    echo_info "========================================"
    echo_info "Get Webhook URL and Secret from Feishu group bot settings."
    echo ""

    if [ -n "$url_default" ]; then
        read_tty -p "Webhook URL [$url_default]: " webhook_url
        webhook_url="${webhook_url:-$url_default}"
    else
        read_tty -p "Webhook URL: " webhook_url
    fi

    if [ -n "$secret_default" ]; then
        read_secret_tty -p "Secret [$(mask_secret "$secret_default")] (Enter to keep): " secret
        secret="${secret:-$secret_default}"
    else
        read_secret_tty -p "Secret: " secret
    fi
    echo ""

    if [ -z "$webhook_url" ] || [ -z "$secret" ]; then
        echo_error "Webhook URL and Secret cannot be empty"
        exit 1
    fi
    if [[ "$webhook_url" == *"xxxxxxxxxx"* ]] || [ "$secret" = "YOUR_SECRET_KEY" ]; then
        echo_error "Please replace template placeholders with real Feishu values"
        exit 1
    fi

    save_feishu_config "$webhook_url" "$secret"
}

confirm_feishu_config() {
    echo ""
    echo_info "Current Feishu config:"
    echo "  Webhook URL: $FEISHU_URL"
    echo "  Secret:      $(mask_secret "$FEISHU_SECRET")"
    echo ""

    local answer
    read_tty -p "Use this config? [Y/n] " answer
    case "${answer:-Y}" in
        [Yy]*)
            echo_info "Feishu config confirmed"
            ;;
        [Nn]*)
            interactive_feishu_config "$FEISHU_URL" "$FEISHU_SECRET"
            ;;
        *)
            echo_error "Invalid input"
            exit 1
            ;;
    esac
}

ensure_feishu_config() {
    load_feishu_config

    if [ "$FEISHU_IS_PLACEHOLDER" = "0" ]; then
        if can_interact; then
            confirm_feishu_config
        else
            echo_info "Feishu config OK"
        fi
    else
        echo_warn "Feishu config incomplete (template placeholders in config.yaml)"

        if ! can_interact; then
            echo_error "No interactive terminal. Configure Feishu first:"
            echo "  vim $CONFIG_FILE"
            echo "  or: sudo ./deploy.sh --interactive"
            exit 1
        fi

        if [ "$CONFIG_JUST_CREATED" = "1" ] || [ "$INTERACTIVE" = "1" ]; then
            interactive_feishu_config "$FEISHU_URL" "$FEISHU_SECRET"
        else
            local answer
            read_tty -p "Configure Feishu now? [Y/n] " answer
            case "${answer:-Y}" in
                [Yy]*)
                    interactive_feishu_config "$FEISHU_URL" "$FEISHU_SECRET"
                    ;;
                *)
                    echo_error "Feishu config is required. Either:"
                    echo "  sudo ./deploy.sh --interactive"
                    echo "  vim $CONFIG_FILE"
                    exit 1
                    ;;
            esac
        fi
    fi

    load_feishu_config
    if [ "$FEISHU_IS_PLACEHOLDER" = "1" ]; then
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
