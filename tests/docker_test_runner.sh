#!/usr/bin/env bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

echo "============================================="
echo "  Docker Deployment Simulation Test"
echo "============================================="

# 使用 Ubuntu 24.04 容器运行测试
# 模拟非交互环境，并传入占位订阅地址
docker run --rm \
    -v "$PROJECT_DIR":/workspace \
    -w /workspace \
    -e DRY_RUN=1 \
    -e AUTO_YES=1 \
    -e AIRPORT_URLS_STR="https://example.com/sub" \
    -e MAIN_IFACE="eth0" \
    ubuntu:24.04 \
    bash -c "
        find /var/lib/apt/lists -type f -exec touch -t \$(date +%Y%m%d%H%M.%S) {} + 2>/dev/null || true && \
        apt-get update -o Acquire::Check-Valid-Until=false -qq && \
        apt-get install -y -qq curl jq python3-yaml iproute2 openssl git gnupg > /dev/null && \
        echo '[LOG] 依赖安装完成，设置 mock 环境...' && \
        cat > /var/lib/dpkg/status <<EOF
Package: sing-box
Status: install ok installed
Version: 1.10.0-1
EOF
        mkdir -p /var/lib/sing-box/ruleset && \
        touch /var/lib/sing-box/ruleset/geoip-cn.srs /var/lib/sing-box/ruleset/geosite-geolocation-!cn.srs /var/lib/sing-box/ruleset/geosite-openai.srs && \
        echo '[LOG] 开始模拟部署...' && \
        bash singbox-deploy.sh --dry-run --auto-yes
    "

echo "============================================="
echo "  Simulation finished. Check output above."
echo "============================================="
