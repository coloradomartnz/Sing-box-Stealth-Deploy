#!/usr/bin/env bash
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "[!] 请用 root 运行：sudo $0"
  exit 1
fi

TEMPLATE="/usr/local/etc/sing-box/config_template.json"
AUTO_YES=0
EBPF_TC_MODE=0

# 读取部署配置
if [ -f "/usr/local/etc/sing-box/.deployment_config" ]; then
  # 收紧正则，禁止反引号、$()、${} 等 shell 扩展
  if grep -qvE '^[A-Za-z_][A-Za-z0-9_]*="[A-Za-z0-9_./:, @*=%+\[\]-]*"$|^[[:space:]]*$|^#' "/usr/local/etc/sing-box/.deployment_config"; then
    echo "[!] 部署配置格式异常，包含非法字符，停止加载" >&2
    exit 1
  fi
  # shellcheck source=/dev/null
  source "/usr/local/etc/sing-box/.deployment_config"
fi

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

# ── 旁路表 CIDR 转 LPM key 辅助函数 ────────────────────────────────────
cidr_to_lpm_key() {
    local cidr="$1"
    local ip="${cidr%/*}"
    local prefix="${cidr#*/}"
    local o1 o2 o3 o4
    # Split IP into 4 octets to avoid word splitting
    IFS=. read -r o1 o2 o3 o4 <<< "$ip"
    # 4-byte prefixlen(LE) + 4-byte IP(BE) = 8 parameters total
    printf 'hex %02x 00 00 00 %02x %02x %02x %02x' \
        "$prefix" "$o1" "$o2" "$o3" "$o4"
}

# ── 降级路径（内核不支持时保留）────────────────────────────────────────────
setup_fwmark_fallback() {
    local docker_iface="${1:-docker0}"
    ip rule add fwmark 0x162 table 200 2>/dev/null || true
    ip route add default dev singbox_tun table 200 2>/dev/null || true
    iptables -t mangle -A PREROUTING -i "$docker_iface" \
        -p tcp -m tcp --dport 1:65535 \
        -j MARK --set-mark 0x162 2>/dev/null || true
    echo "[+] 已配置 fwmark 0x162 iptables 回退路径"
}

setup_ebpf_tc_redirect() {
    local docker_iface="${1:-docker0}"
    local bpf_obj="/usr/local/share/sing-box/tproxy_tc.bpf.o"

    if [ "${EBPF_TC_MODE:-0}" -eq 0 ]; then
        echo "eBPF TC 模式未启用，使用原 iptables fwmark 回退路径"
        setup_fwmark_fallback "$docker_iface"
        return 0
    fi

    # ── 1. 获取 singbox_tun ifindex（动态，不硬编码）──────────────────
    local tun_ifindex
    tun_ifindex=$(ip link show singbox_tun 2>/dev/null \
        | awk 'NR==1{print $1}' | tr -d ':')
    if [ -z "$tun_ifindex" ]; then
        echo "[ERROR] singbox_tun 接口不存在，请先启动 sing-box" >&2
        return 1
    fi
    echo "[+] singbox_tun ifindex = $tun_ifindex"

    # ── 2. 挂载 TC clsact qdisc + BPF filter ─────────────────────────
    tc qdisc del dev "$docker_iface" clsact 2>/dev/null || true
    tc qdisc add dev "$docker_iface" clsact
    tc filter add dev "$docker_iface" ingress \
        bpf direct-action \
        obj "$bpf_obj" \
        sec tc/ingress \
        verbose 2>&1 | grep -i bpf

    # ── 3. 向 BPF Map 写入 singbox_tun ifindex ───────────────────────
    # bpftool map update: key = 4 字节 LE(0), value = 4 字节 LE(ifindex)
    local key_hex value_hex
    key_hex=$(printf '%08x' 0 | fold -w2 | tac | tr -d '\n')  # LE bytes
    value_hex=$(printf '%08x' "$tun_ifindex" | fold -w2 | tac | tr -d '\n')
    bpftool map update \
        pinned /sys/fs/bpf/tun_ifindex_map \
        key hex "$key_hex" \
        value hex "$value_hex" 2>/dev/null || \
    bpftool map update \
        name tun_ifindex_map \
        key 0 0 0 0 \
        value "$(printf '%d 0 0 0' "$tun_ifindex")" 2>/dev/null || \
        echo "[WARNING] bpftool map 写入失败，ifindex 将触发 pass-through 回退"

    # ── 4. 填充旁路 CIDR Map（Docker 内部不劫持）────────────────────
    # 与原 add_docker_route.sh 逻辑对齐，LAN 段直连
    for cidr in "172.16.0.0/12" "10.0.0.0/8" "192.168.0.0/16"; do
        # shellcheck disable=SC2046
        bpftool map update name bypass_cidr_map \
            key $(cidr_to_lpm_key "$cidr") value 1 2>/dev/null || true
    done

    echo "[+] ✓ eBPF TC redirect 已激活: $docker_iface → singbox_tun (ifindex=$tun_ifindex)"

    # ── 5. 写入持久化 systemd 服务（重启恢复）────────
    cat > /etc/systemd/system/singbox-ebpf-tc.service << EOF
[Unit]
Description=sing-box eBPF TC Hook Restore
After=network.target sing-box.service docker.service
Requires=sing-box.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/etc/sing-box/scripts/add_docker_route.sh --auto-yes
ExecStop=tc qdisc del dev ${docker_iface} clsact

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable singbox-ebpf-tc.service 2>/dev/null || true
}

# 设置路由策略
setup_ebpf_tc_redirect "docker0"

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
