#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# sing-box deployment project - global variables
#

SCRIPT_VERSION="3.5"
GITHUB_OWNER="coloradomartnz"
GITHUB_REPO="Sing-box-Stealth-Deploy"
DEPLOYMENT_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# Network timeout settings (seconds)
CONNECT_TIMEOUT=5
MAX_TIME=60

# sing-box binary path (unified reference, set after install)
SING_BOX_BIN=$(command -v sing-box 2>/dev/null || echo "/usr/bin/sing-box")

# Runtime mode flags
DRY_RUN=${DRY_RUN:-0}
UPGRADE_MODE=${UPGRADE_MODE:-0}

# Deployment config persistence file
DEPLOYMENT_CONFIG="/usr/local/etc/sing-box/.deployment_config"
DEPLOY_LOCK="/run/lock/singbox-deploy.lock"
DEPLOY_LOCK_PID="/run/lock/singbox-deploy.lock.pid"
SB_SUB="/opt/sing-box-subscribe"
DIRECT_LIST="/usr/local/etc/sing-box/direct_list.txt"
PROXY_LIST="/usr/local/etc/sing-box/proxy_list.txt"

# ============================================================================
# Default config
# ============================================================================
DEFAULT_REGION="auto"
LAN_SUBNET="192.168.0.0/16" # Default, overridden by detect_lan_subnet
MAIN_IFACE=""
PHYSICAL_MTU=1500
RECOMMENDED_TUN_MTU=1400
HAS_IPV6=0

# Dashboard / Clash API config
DASHBOARD_PORT=9090
DASHBOARD_SECRET="sing-box"
METACUBEXD_URL="https://github.com/MetaCubeX/MetacubexD/releases/latest/download/compressed-dist.tgz"

# Sub-Store integration config
SUBSTORE_PORT=2999
SUBSTORE_DIR="/opt/sub-store"
SUBSTORE_DATA_DIR="/usr/local/etc/sub-store"
SUBSTORE_COLLECTION_NAME="MySubs"

# Ruleset URLs (lyc8503 source)
RULESET_GEOSITE_CN_URL="https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cn.srs"
RULESET_GEOSITE_GEOLOC_NONCN_URL="https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-geolocation-!cn.srs"
RULESET_GEOIP_CN_URL="https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cn.srs"
# lyc8503 has no openai ruleset; use MetaCubeX source; FALLBACK tries on primary failure
RULESET_GEOSITE_OPENAI_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/openai.srs"
RULESET_GEOSITE_OPENAI_URL_FALLBACK="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs"
RULESET_GEOSITE_ANTHROPIC_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/anthropic.srs"
RULESET_GEOSITE_GEMINI_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/google-gemini.srs"
