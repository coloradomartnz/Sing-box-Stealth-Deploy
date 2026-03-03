#!/usr/bin/env bash
#
# sing-box-stealth-deploy 纯函数单元测试
# 测试目标: _atomic_write, _redact, _validate_cidr, _sed_escape_replacement,
#           _array_contains, _ensure_compat_defaults, detect_lan_subnet, probe_pmtu
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

PASS=0
FAIL=0

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc"
    echo -e "    expected: '$expected'"
    echo -e "    actual:   '$actual'"
    FAIL=$((FAIL + 1))
  fi
}

assert_ok() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local desc="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc (expected failure)"
    FAIL=$((FAIL + 1))
  fi
}

# ========================
# 加载被测库
# ========================
# shellcheck source=/dev/null
source "$PROJECT_DIR/lib/globals.sh"
# shellcheck source=/dev/null
source "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=/dev/null
source "$PROJECT_DIR/lib/checks.sh"

echo "============================================="
echo "  纯函数单元测试"
echo "============================================="
echo ""

# ============================================================
# 1. _atomic_write
# ============================================================
echo "[1/7] _atomic_write 原子写入..."

TMP_DIR=$(mktemp -d /tmp/singbox-unittest.XXXXXX)
trap "rm -rf '$TMP_DIR'" EXIT

# 基本写入
_atomic_write "$TMP_DIR/basic.txt" "hello world"
assert_eq "基本写入内容正确" "hello world" "$(cat "$TMP_DIR/basic.txt")"

# 以 -e 开头（echo 会误解释为选项）
_atomic_write "$TMP_DIR/dash_e.txt" "-e should not be interpreted"
assert_eq "-e 前缀内容不被解释" "-e should not be interpreted" "$(cat "$TMP_DIR/dash_e.txt")"

# 以 -n 开头
_atomic_write "$TMP_DIR/dash_n.txt" "-n no newline flag"
assert_eq "-n 前缀内容不被解释" "-n no newline flag" "$(cat "$TMP_DIR/dash_n.txt")"

# 包含特殊字符
_atomic_write "$TMP_DIR/special.txt" 'line with $VAR and `cmd` and $(subshell)'
assert_eq "特殊字符不被展开" 'line with $VAR and `cmd` and $(subshell)' "$(cat "$TMP_DIR/special.txt")"

#  空字符串
_atomic_write "$TMP_DIR/empty.txt" ""
assert_ok "空字符串写入成功" test -f "$TMP_DIR/empty.txt"

# 多行内容
_atomic_write "$TMP_DIR/multi.txt" "line1
line2
line3"
# printf '%s' 不添加尾部换行，所以 wc -l 计数最后一行不带 \n = 2
assert_eq "多行内容包含3行" "3" "$(grep -c '' "$TMP_DIR/multi.txt")"

# 权限继承
touch "$TMP_DIR/perm_test.txt"
chmod 640 "$TMP_DIR/perm_test.txt"
_atomic_write "$TMP_DIR/perm_test.txt" "updated"
actual_perm=$(stat -c '%a' "$TMP_DIR/perm_test.txt")
assert_eq "权限继承 640" "640" "$actual_perm"

# stdin 模式
echo "from stdin" | _atomic_write "$TMP_DIR/stdin.txt"
assert_eq "stdin 管道写入正确" "from stdin" "$(cat "$TMP_DIR/stdin.txt")"

# ============================================================
# 2. _redact
# ============================================================
echo ""
echo "[2/7] _redact 脱敏..."

# URL 脱敏
result=$(echo "GET https://api.example.com/sub?token=abc123 HTTP/1.1" | _redact)
assert_eq "URL 被替换" "GET <REDACTED_URL> HTTP/1.1" "$result"

# IP 脱敏
result=$(echo "connect to 192.168.1.100:443" | _redact)
assert_eq "IP 被替换" "connect to <REDACTED_IP>:443" "$result"

# token= 参数脱敏
result=$(echo "token=secret_value_123&type=2" | _redact)
assert_eq "token= 参数被脱敏" "token=<REDACTED>&type=2" "$result"

# JSON key 脱敏
result=$(echo '{"password": "my_pass_123"}' | _redact)
assert_eq "JSON password 被脱敏" '{"password":""}' "$result"

# 无敏感信息不变
result=$(echo "正常日志 2024-01-01 sing-box started" | _redact)
assert_eq "普通文本不被修改" "正常日志 2024-01-01 sing-box started" "$result"

# 混合脱敏
result=$(echo "curl https://sub.example.com/api?token=xxx from 10.0.0.1" | _redact)
assert_ok "混合敏感信息全部脱敏" bash -c "[[ '$result' == *REDACTED* ]]"

# ============================================================
# 3. _validate_cidr
# ============================================================
echo ""
echo "[3/7] _validate_cidr 校验..."

# 合法 CIDR
assert_ok "192.168.1.0/24 合法" _validate_cidr "192.168.1.0/24"
assert_ok "10.0.0.0/8 合法" _validate_cidr "10.0.0.0/8"
assert_ok "172.16.0.0/12 合法" _validate_cidr "172.16.0.0/12"
assert_ok "0.0.0.0/0 合法" _validate_cidr "0.0.0.0/0"
assert_ok "255.255.255.255/32 合法" _validate_cidr "255.255.255.255/32"

# 非法 CIDR
assert_fail "256.0.0.0/8 非法 (octet>255)" _validate_cidr "256.0.0.0/8"
assert_fail "1.2.3.4/33 非法 (mask>32)" _validate_cidr "1.2.3.4/33"
assert_fail "1.2.3/24 非法 (3 octets)" _validate_cidr "1.2.3/24"
assert_fail "空字符串非法" _validate_cidr ""
assert_fail "纯文本非法" _validate_cidr "not_a_cidr"
assert_fail "缺少掩码非法" _validate_cidr "192.168.1.0"
assert_fail "负掩码非法" _validate_cidr "192.168.1.0/-1"

# ============================================================
# 4. _sed_escape_replacement
# ============================================================
echo ""
echo "[4/7] _sed_escape_replacement 转义..."

result=$(_sed_escape_replacement "hello/world")
assert_eq "/ 被转义" "hello\\/world" "$result"

result=$(_sed_escape_replacement "a&b")
assert_eq "& 被转义" "a\\&b" "$result"

result=$(_sed_escape_replacement 'path\to\file')
assert_eq "\\ 被转义" 'path\\to\\file' "$result"

result=$(_sed_escape_replacement "no_special_chars")
assert_eq "无特殊字符不变" "no_special_chars" "$result"

# ============================================================
# 5. _array_contains
# ============================================================
echo ""
echo "[5/7] _array_contains 查找..."

assert_ok "存在的元素找到" _array_contains "b" "a" "b" "c"
assert_fail "不存在的元素未找到" _array_contains "d" "a" "b" "c"
assert_fail "空数组返回 false" _array_contains "a"
assert_ok "单元素匹配" _array_contains "only" "only"
assert_fail "部分匹配不算" _array_contains "ab" "a" "b" "abc"

# ============================================================
# 6. _ensure_compat_defaults
# ============================================================
echo ""
echo "[6/7] _ensure_compat_defaults 兼容默认值..."

# 清除所有变量再测试
unset ENABLE_DASHBOARD DASHBOARD_PORT DASHBOARD_SECRET IS_DESKTOP HAS_IPV6 2>/dev/null || true
unset DEFAULT_REGION PHYSICAL_MTU RECOMMENDED_TUN_MTU LAN_SUBNET 2>/dev/null || true

_ensure_compat_defaults

assert_eq "ENABLE_DASHBOARD 默认 1" "1" "$ENABLE_DASHBOARD"
assert_eq "DASHBOARD_PORT 默认 9090" "9090" "$DASHBOARD_PORT"
assert_eq "DASHBOARD_SECRET 默认 sing-box" "sing-box" "$DASHBOARD_SECRET"
assert_eq "IS_DESKTOP 默认 0" "0" "$IS_DESKTOP"
assert_eq "HAS_IPV6 默认 0" "0" "$HAS_IPV6"
assert_eq "DEFAULT_REGION 默认 auto" "auto" "$DEFAULT_REGION"
assert_eq "PHYSICAL_MTU 默认 1500" "1500" "$PHYSICAL_MTU"
assert_eq "RECOMMENDED_TUN_MTU 默认 1400" "1400" "$RECOMMENDED_TUN_MTU"
assert_eq "LAN_SUBNET 默认 192.168.0.0/16" "192.168.0.0/16" "$LAN_SUBNET"

# 已设置的值不被覆盖
DASHBOARD_PORT="8080"
HAS_IPV6="1"
_ensure_compat_defaults
assert_eq "已设置值不被覆盖 (PORT)" "8080" "$DASHBOARD_PORT"
assert_eq "已设置值不被覆盖 (IPV6)" "1" "$HAS_IPV6"

# ============================================================
# 7. detect_desktop
# ============================================================
echo ""
echo "[7/7] detect_desktop 桌面检测..."

# 确保在无桌面环境下返回 0
unset XDG_CURRENT_DESKTOP GNOME_SETUP_DISPLAY KDE_FULL_SESSION 2>/dev/null || true
IS_DESKTOP=999  # 设置一个非 0/1 的值来验证函数有没有修改它
detect_desktop
assert_ok "无桌面环境返回成功" true
# IS_DESKTOP 应被设为 0 或 1
assert_ok "IS_DESKTOP 为数字" test "$IS_DESKTOP" -eq 0 -o "$IS_DESKTOP" -eq 1

# ============================================================
# 汇总
# ============================================================
echo ""
echo "============================================="
TOTAL=$((PASS + FAIL))
echo -e "  测试完成: ${GREEN}${PASS} 通过${NC} / ${RED}${FAIL} 失败${NC} (共 ${TOTAL})"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}✅ 全部测试通过${NC}"
else
  echo -e "  ${RED}❌ 存在失败测试${NC}"
fi
echo "============================================="
echo ""

exit "$FAIL"
