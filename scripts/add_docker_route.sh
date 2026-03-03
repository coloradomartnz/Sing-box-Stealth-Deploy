#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] 请用 root 运行：sudo $0"
  exit 1
fi

TEMPLATE="/usr/local/etc/sing-box/config_template.json"
AUTO_YES=0

while [[ $# -gt 0 ]]; do
  case $1 in
    --auto-yes) AUTO_YES=1; shift ;;
    *) echo "未知参数: $1"; exit 1 ;;
  esac
done

if ! command -v docker &>/dev/null; then
  echo "[!] Docker 未安装，无需配置"
  exit 0
fi

if ! systemctl is-active --quiet docker; then
  echo "[!] Docker 服务未运行"
  exit 1
fi

echo "[*] 正在检测 Docker 网络..."
# 同时检测 IPv4 和 IPv6 网段
# shellcheck disable=SC2046
DOCKER_SUBNETS=$(docker network inspect $(docker network ls -q) 2>/dev/null | \
  jq -r '.[].IPAM.Config[]? | select(.Subnet != null and .Subnet != "") | .Subnet' | \
  grep -E '^([0-9.]+(/[0-9]+)?|[0-9a-fA-F:]+(/[0-9]+)?)$' | sort -u)

if [ -z "$DOCKER_SUBNETS" ]; then
  echo "[!] 未检测到 Docker 网络"
  exit 1
fi

echo "[+] 检测到以下 Docker 网段："
# shellcheck disable=SC2001
echo "$DOCKER_SUBNETS" | sed 's/^/    /'

SUBNET_JSON=$(echo "$DOCKER_SUBNETS" | jq -R . | jq -s .)

EXISTING_RULE=$(jq -e '.route.rules[] | select(.source_ip_cidr != null)' "$TEMPLATE" 2>/dev/null || echo "")

if [ -n "$EXISTING_RULE" ]; then
  if [ "$AUTO_YES" -eq 0 ]; then
    echo ""
    read -p "是否替换为新检测到的网段？[y/N] " -n 1 -r
    echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && exit 0
  fi
  
  BACKUP="${TEMPLATE}.before-docker.$(date +%Y%m%d-%H%M%S)"
  cp "$TEMPLATE" "$BACKUP"
  
  jq 'del(.route.rules[] | select(.source_ip_cidr != null))' "$TEMPLATE" > "${TEMPLATE}.tmp"
  mv "${TEMPLATE}.tmp" "$TEMPLATE"
fi

# 修复：使用简单的数组插入逻辑
# 安全更新 Docker 路由规则
update_docker_routes() {
  local template="$1"
  local subnets="$2"
  local tmp="${template}.tmp"
  
  # 1. 验证输入文件
  if ! jq empty "$template" 2>/dev/null; then
    echo "[ERROR] 配置文件 JSON 格式错误" >&2
    return 1
  fi
  
  # 2. 执行更新
  if ! jq --argjson subnets "$subnets" '
    # 确保 route.rules 存在
    .route.rules //= [] |
    # 移除旧的 Docker 规则
    .route.rules |= map(select(.source_ip_cidr == null or (.source_ip_cidr | type) != "array")) |
    # 添加新规则到开头
    # H-1 安全修复: 仅对 Docker 容器间/到宿主机的流量直连
    # 不再将所有 Docker 出站流量标记为直连，避免容器代理需求被绕过
    .route.rules = [{"source_ip_cidr": $subnets, "ip_cidr": ["172.16.0.0/12","10.0.0.0/8","192.168.0.0/16","fc00::/7"], "outbound": "direct"}] + .route.rules
  ' "$template" > "$tmp" 2>/dev/null; then
    echo "[ERROR] jq 更新失败" >&2
    rm -f "$tmp"
    return 1
  fi
  
  # 3. 验证输出
  if ! jq empty "$tmp" 2>/dev/null; then
    echo "[ERROR] 生成的 JSON 无效" >&2
    rm -f "$tmp"
    return 1
  fi
  
  mv "$tmp" "$template"
  return 0
}

if ! update_docker_routes "$TEMPLATE" "$SUBNET_JSON"; then
  echo "[!] Docker 路由更新失败"
  exit 1
fi
echo "[+] 已插入 Docker 直连规则到路由表开头"

if [ "$AUTO_YES" -eq 1 ]; then
  APPLY="y"
else
  echo ""
  read -p "是否立即重新生成配置并重启服务？[y/N] " -n 1 -r APPLY
  echo
fi

if [[ $APPLY =~ ^[Yy]$ ]]; then
  /usr/local/etc/sing-box/update_and_restart.sh
fi
