#!/usr/bin/env bash
set -euo pipefail

# O-1 修复: 使用共享锁库替代内联 acquire_lock
SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
SHARED_LOCK="${SCRIPT_DIR}/lib/lock.sh"
# shellcheck source=/dev/null
if [ -f "$SHARED_LOCK" ]; then
  # shellcheck source=/dev/null
  source "$SHARED_LOCK"
elif [ -f "/usr/local/etc/sing-box/lib/lock.sh" ]; then
  # shellcheck source=/dev/null
  source "/usr/local/etc/sing-box/lib/lock.sh"
fi

# 使用示例
if type acquire_script_lock &>/dev/null; then
  if ! acquire_script_lock /run/lock/singbox-dns-failover.lock 60; then
    echo "[WARN] 无法获取锁，跳过本次检查" >&2
    exit 0
  fi
else
  # Fallback: 简单 flock
  exec 200>/run/lock/singbox-dns-failover.lock
  if ! flock -n 200; then
    echo "[WARN] 无法获取锁，跳过本次检查" >&2
    exit 0
  fi
fi

CONFIG="/usr/local/etc/sing-box/config.json"
TEMPLATE="/usr/local/etc/sing-box/config_template.json"
STATE_DIR="/var/lib/sing-box"
STATE="$STATE_DIR/dns_failover.state"

mkdir -p "$STATE_DIR"
chmod 700 "$STATE_DIR"

command -v jq >/dev/null
command -v curl >/dev/null
command -v python3 >/dev/null
command -v base64 >/dev/null

# config 不存在就退出（首次部署阶段 timer 可能先启动）
[ -f "$CONFIG" ] || exit 0

# 没有 NextDNS tag 就不启用故障切换
if ! jq -e '.dns.servers[]? | select(.tag=="remote_nextdns")' "$CONFIG" >/dev/null 2>&1; then
  exit 0
fi

# 获取 NextDNS path（形如 "/xxxxxx"）
NEXTDNS_PATH="$(jq -r '.dns.servers[]? | select(.tag=="remote_nextdns") | .path // empty' "$CONFIG")"
[ -n "$NEXTDNS_PATH" ] || exit 0

# 当前模式（dns.final）
MODE="$(jq -r '.dns.final // empty' "$CONFIG")"
[ -n "$MODE" ] || MODE="remote_nextdns"

# 计数器（成功/失败连续次数）
OK_COUNT=0
FAIL_COUNT=0
if [ -f "$STATE" ]; then
  read -r OK_COUNT FAIL_COUNT < "$STATE" || true
  # ✅ 修复：校验状态并重置异常值
  if ! [[ "$OK_COUNT" =~ ^[0-9]+$ ]] || ! [[ "$FAIL_COUNT" =~ ^[0-9]+$ ]]; then
      OK_COUNT=0
      FAIL_COUNT=0
  fi
fi
OK_COUNT="${OK_COUNT:-0}"
FAIL_COUNT="${FAIL_COUNT:-0}"

# 构造一个最小 DNS 查询（A example.com），输出 base64（标准 base64，后续 base64 -d）
DNS_Q_B64="$(
python3 - <<'PY'
import os, base64, struct, random
def qname(name: str) -> bytes:
    out = b""
    for part in name.split("."):
        out += bytes([len(part)]) + part.encode()
    return out + b"\x00"

tid = random.randint(0, 65535)
flags = 0x0100  # RD
qdcount = 1
header = struct.pack("!HHHHHH", tid, flags, qdcount, 0, 0, 0)
question = qname("example.com") + struct.pack("!HH", 1, 1)  # A IN
msg = header + question
print(base64.b64encode(msg).decode())
PY
)"

doh_post_ok() {
  # 参数：URL
  local url="$1"
  local code
  code="$(
    (printf '%s' "$DNS_Q_B64" | base64 -d 2>/dev/null || printf '%s' "$DNS_Q_B64" | base64 --decode) | \
      timeout 8s curl -sS -o /dev/null \
        -w '%{http_code}' \
        -X POST \
        -H 'content-type: application/dns-message' \
        -H 'accept: application/dns-message' \
        --data-binary @- \
        "$url" || true
  )"
  # 只认 200，避免把 400/404 当作“可用”
  [ "$code" = "200" ]
}

# NextDNS / Cloudflare 探测 URL
NEXTDNS_URL="https://dns.nextdns.io${NEXTDNS_PATH}"
CF_URL="https://cloudflare-dns.com/dns-query"

NEXTDNS_OK=0
CF_OK=0

if doh_post_ok "$NEXTDNS_URL"; then
  NEXTDNS_OK=1
fi

if doh_post_ok "$CF_URL"; then
  CF_OK=1
fi

# 更新连续计数
if [ "$NEXTDNS_OK" -eq 1 ]; then
  OK_COUNT=$((OK_COUNT + 1))
  FAIL_COUNT=0
else
  FAIL_COUNT=$((FAIL_COUNT + 1))
  OK_COUNT=0
fi
echo "$OK_COUNT $FAIL_COUNT" > "$STATE"
chmod 600 "$STATE"
if id -u sing-box >/dev/null 2>&1; then
  chown sing-box:sing-box "$STATE"
fi

patch_dns_tag_in_file() {
  # 替换 dns.final，并替换 dns.rules 里 server 的 tag
  local file="$1"
  local from="$2"
  local to="$3"

  [ -f "$file" ] || return 0

  local tmp="${file}.tmp"
  jq --arg from "$from" --arg to "$to" '
    .dns.final = $to
    | (.dns.rules // []) as $r
    | .dns.rules = ($r | map(if (.server // "") == $from then .server = $to else . end))
  ' "$file" > "$tmp"

  jq empty "$tmp" >/dev/null
  mv "$tmp" "$file"
  if id -u sing-box >/dev/null 2>&1; then
    chown sing-box:sing-box "$file"
  fi
}

rollback_and_restart() {
  local bak="$1"
  cp -f "$bak" "$CONFIG"
  if id -u sing-box >/dev/null 2>&1; then
    chown sing-box:sing-box "$CONFIG"
  fi
  "${SING_BOX_BIN:-/usr/bin/sing-box}" check -c "$CONFIG" >/dev/null
  systemctl restart sing-box
}

switch_to() {
  # target: remote_cf 或 remote_nextdns
  local target="$1"
  local ts backup_cfg backup_tpl
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_cfg="${CONFIG}.pre-dns-switch.${ts}"
  backup_tpl="${TEMPLATE}.pre-dns-switch.${ts}"

  cp -f "$CONFIG" "$backup_cfg"
  [ -f "$TEMPLATE" ] && cp -f "$TEMPLATE" "$backup_tpl"

  if [ "$target" = "remote_cf" ]; then
    patch_dns_tag_in_file "$CONFIG"   "remote_nextdns" "remote_cf"
    # 同时修改模板文件，确保下次 sing-box-subscribe 重新生成时保留切换后的 DNS 选择
    patch_dns_tag_in_file "$TEMPLATE" "remote_nextdns" "remote_cf"
  else
    patch_dns_tag_in_file "$CONFIG"   "remote_cf" "remote_nextdns"
    # 同时修改模板文件，确保下次 sing-box-subscribe 重新生成时保留切换后的 DNS 选择
    patch_dns_tag_in_file "$TEMPLATE" "remote_cf" "remote_nextdns"
  fi

  # 门禁 + 重启，失败则回滚
  if ! "${SING_BOX_BIN:-/usr/bin/sing-box}" check -c "$CONFIG" >/dev/null; then
    rollback_and_restart "$backup_cfg"
    exit 0
  fi

  if ! systemctl restart sing-box; then
    rollback_and_restart "$backup_cfg"
    exit 0
  fi
}

# 决策：失败切 CF；恢复切回 NextDNS
MODE="$(jq -r '.dns.final // "remote_nextdns"' "$CONFIG" 2>/dev/null || echo remote_nextdns)"

if [ "$MODE" = "remote_nextdns" ] && [ "$FAIL_COUNT" -ge 2 ] && [ "$CF_OK" -eq 1 ]; then
  switch_to "remote_cf"
  echo "0 0" > "$STATE"
  exit 0
fi

if [ "$MODE" = "remote_cf" ] && [ "$OK_COUNT" -ge 2 ] && [ "$NEXTDNS_OK" -eq 1 ]; then
  switch_to "remote_nextdns"
  echo "0 0" > "$STATE"
  exit 0
fi

exit 0
