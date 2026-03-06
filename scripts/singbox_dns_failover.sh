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

command -v jq    >/dev/null
command -v curl  >/dev/null
command -v base64 >/dev/null

# config 不存在就退出（首次部署阶段 timer 可能先启动）
[ -f "$CONFIG" ] || exit 0

# 一次性提取所有需要的 DNS 信息，避免多次 jq 进程 fork
_dns_info=$(jq -r '
  (.dns.servers[] | select(.tag == "remote_nextdns") | "PATH=" + (.path // "")) // "",
  "MODE=" + (.dns.final // "remote_nextdns"),
  "HAS_NEXTDNS=" + (if (.dns.servers[] | select(.tag == "remote_nextdns")) then "1" else "0" end)
' "$CONFIG" 2>/dev/null | head -3)

HAS_NEXTDNS=$(echo "$_dns_info" | grep "^HAS_NEXTDNS=" | cut -d= -f2-)
if [ "${HAS_NEXTDNS:-0}" != "1" ]; then
  exit 0
fi

NEXTDNS_PATH=$(echo "$_dns_info" | grep "^PATH=" | cut -d= -f2-)
[ -n "$NEXTDNS_PATH" ] || exit 0

MODE=$(echo "$_dns_info" | grep "^MODE=" | cut -d= -f2-)
[ -n "$MODE" ] || MODE="remote_nextdns"

# 计数器（成功/失败连续次数）
OK_COUNT=0
FAIL_COUNT=0
if [ -f "$STATE" ]; then
  read -r OK_COUNT FAIL_COUNT < "$STATE" || true
  if ! [[ "$OK_COUNT" =~ ^[0-9]+$ ]] || ! [[ "$FAIL_COUNT" =~ ^[0-9]+$ ]]; then
      OK_COUNT=0
      FAIL_COUNT=0
  fi
fi
OK_COUNT="${OK_COUNT:-0}"
FAIL_COUNT="${FAIL_COUNT:-0}"

# 构造固定的 DNS wire-format 查询报文（A example.com）
# 用 bash/openssl 替代 python3 子进程，消除 ~200ms 启动开销。
# 报文结构: 2字节随机TxID + flags(0x0100) + qdcount(1) + 3×zero_u16
#           + qname(7\x65\x78\x61...\x03\x63\x6f\x6d\x00) + qtype(1) + qclass(1)
# TxID 用 $RANDOM（16-bit，满足要求）
_build_dns_query() {
  local txid_hi=$(( (RANDOM & 0xFF) ))
  local txid_lo=$(( (RANDOM & 0xFF) ))
  # printf each byte as \xNN then base64-encode
  printf '\x%02x\x%02x\x01\x00\x00\x01\x00\x00\x00\x00\x00\x00\x07example\x03com\x00\x00\x01\x00\x01' \
    "$txid_hi" "$txid_lo" | base64 -w0
}
DNS_Q_B64=$(_build_dns_query)

doh_post_ok() {
  local url="$1"
  local code
  code="$(
    printf '%s' "$DNS_Q_B64" | base64 -d 2>/dev/null | \
      timeout 8s curl -sS -o /dev/null \
        -w '%{http_code}' \
        -X POST \
        -H 'content-type: application/dns-message' \
        -H 'accept: application/dns-message' \
        --data-binary @- \
        "$url" || true
  )"
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
  sync "$tmp" 2>/dev/null || sync
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
  local target="$1"
  local ts backup_cfg backup_tpl
  ts="$(date +%Y%m%d-%H%M%S)"
  backup_cfg="${CONFIG}.pre-dns-switch.${ts}"
  backup_tpl="${TEMPLATE}.pre-dns-switch.${ts}"

  cp -f "$CONFIG" "$backup_cfg"
  [ -f "$TEMPLATE" ] && cp -f "$TEMPLATE" "$backup_tpl"

  # 仅保留最近 3 份 pre-switch 备份，防止磁盘被无限积累的备份文件写满
  find "$(dirname "$CONFIG")" -maxdepth 1 -name "$(basename "$CONFIG").pre-dns-switch.*" \
    -type f -printf '%T@\t%p\n' 2>/dev/null | sort -t$'\t' -k1 -rn |
    tail -n +4 | cut -f2- | xargs rm -f 2>/dev/null || true
  find "$(dirname "$TEMPLATE")" -maxdepth 1 -name "$(basename "$TEMPLATE").pre-dns-switch.*" \
    -type f -printf '%T@\t%p\n' 2>/dev/null | sort -t$'\t' -k1 -rn |
    tail -n +4 | cut -f2- | xargs rm -f 2>/dev/null || true

  if [ "$target" = "remote_cf" ]; then
    patch_dns_tag_in_file "$CONFIG"   "remote_nextdns" "remote_cf"
    patch_dns_tag_in_file "$TEMPLATE" "remote_nextdns" "remote_cf"
  else
    patch_dns_tag_in_file "$CONFIG"   "remote_cf" "remote_nextdns"
    patch_dns_tag_in_file "$TEMPLATE" "remote_cf" "remote_nextdns"
  fi

  if ! "${SING_BOX_BIN:-/usr/bin/sing-box}" check -c "$CONFIG" >/dev/null; then
    rollback_and_restart "$backup_cfg"
    exit 0
  fi

  if ! systemctl restart sing-box; then
    rollback_and_restart "$backup_cfg"
    exit 0
  fi
}

# 重新从配置文件读取当前模式（patch 可能已修改）
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
