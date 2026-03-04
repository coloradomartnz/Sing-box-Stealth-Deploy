#!/usr/bin/env bash
# shellcheck disable=SC2034
#
# sing-box deployment project - global variables
#

SCRIPT_VERSION="3.0"
DEPLOYMENT_START_TIME=$(date '+%Y-%m-%d %H:%M:%S')

# 网络超时设置 (秒)
CONNECT_TIMEOUT=5
MAX_TIME=10

# sing-box 二进制路径（统一引用点，安装后赋值）
SING_BOX_BIN=$(command -v sing-box 2>/dev/null || echo "/usr/bin/sing-box")

# 运行模式标志
DRY_RUN=${DRY_RUN:-0}
UPGRADE_MODE=${UPGRADE_MODE:-0}

# 部署配置持久化文件
DEPLOYMENT_CONFIG="/usr/local/etc/sing-box/.deployment_config"
DEPLOY_LOCK="/run/lock/singbox-deploy.lock"
DEPLOY_LOCK_PID="/run/lock/singbox-deploy.lock.pid"
SB_SUB="/opt/sing-box-subscribe"
DIRECT_LIST="/usr/local/etc/sing-box/direct_list.txt"
PROXY_LIST="/usr/local/etc/sing-box/proxy_list.txt"

# ============================================================================
# 默认配置
# ============================================================================
DEFAULT_REGION="auto"
LAN_SUBNET="192.168.0.0/16" # 默认，会被 detect_lan_subnet 覆盖
MAIN_IFACE=""
PHYSICAL_MTU=1500
RECOMMENDED_TUN_MTU=1400
HAS_IPV6=0

# Dashboard / Clash API 配置
DASHBOARD_PORT=9090
DASHBOARD_SECRET="sing-box"
METACUBEXD_URL="https://github.com/MetaCubeX/MetacubexD/releases/latest/download/compressed-dist.tgz"

# Sub-Store 集成配置
SUBSTORE_PORT=2999
SUBSTORE_DIR="/opt/sub-store"
SUBSTORE_DATA_DIR="/usr/local/etc/sub-store"
SUBSTORE_COLLECTION_NAME="MySubs"

# 规则集 URL (按原脚本 lyc8503 版本)
RULESET_GEOSITE_CN_URL="https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cn.srs"
RULESET_GEOSITE_GEOLOC_NONCN_URL="https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-geolocation-!cn.srs"
RULESET_GEOIP_CN_URL="https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cn.srs"
# lyc8503 仓库无 openai 规则集，改用 MetaCubeX 源；FALLBACK 在主源失败时自动尝试
RULESET_GEOSITE_OPENAI_URL="https://raw.githubusercontent.com/MetaCubeX/meta-rules-dat/sing/geo/geosite/openai.srs"
RULESET_GEOSITE_OPENAI_URL_FALLBACK="https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs"
