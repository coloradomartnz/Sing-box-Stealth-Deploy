#!/usr/bin/env bash
#
# 审计修复回归测试
# 覆盖: C-04/R-02(lock合并) R-05(trap标签) E-01(语义校验)
#        E-07(正则) E-08(数量校验) C-06(config-gen)
#
set -euo pipefail

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

PASS=0; FAIL=0

assert_ok() {
  local desc="$1"; shift
  if "$@" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc"; FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local desc="$1"; shift
  if ! "$@" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc (应该失败但成功了)"; FAIL=$((FAIL + 1))
  fi
}

assert_eq() {
  local desc="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo -e "  ${GREEN}✓${NC} $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc"; echo "    expected='$expected' actual='$actual'"; FAIL=$((FAIL + 1))
  fi
}

assert_output_contains() {
  local desc="$1" pattern="$2" output="$3"
  if echo "$output" | grep -q "$pattern" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $desc"; PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc (输出不包含: $pattern)"; FAIL=$((FAIL + 1))
  fi
}

echo "============================================="
echo "  审计修复回归测试"
echo "============================================="
echo ""

# 加载被测库
# shellcheck source=/dev/null
source "$PROJECT_DIR/lib/globals.sh"
# shellcheck source=/dev/null
source "$PROJECT_DIR/lib/utils.sh"
# shellcheck source=/dev/null
source "$PROJECT_DIR/lib/lock.sh"

TMP_DIR=$(mktemp -d /tmp/audit-test.XXXXXX)
trap 'rm -rf "$TMP_DIR"' EXIT

# ============================================================
# 1. C-04/R-02: 统一锁 acquire_lock
# ============================================================
echo "[1/6] C-04/R-02: 统一锁实现..."

# 基本获取与释放
lock_file="$TMP_DIR/test.lock"
assert_ok "acquire_lock 获取成功" acquire_lock "$lock_file" 5
assert_ok "PID 文件已创建" test -f "${lock_file}.pid"
pid_content=$(cat "${lock_file}.pid" 2>/dev/null || echo "")
assert_eq "PID 文件内容为当前进程" "$$" "$pid_content"

# 向后兼容别名
assert_ok "acquire_deploy_lock 别名可调用" bash -c "
  source '$PROJECT_DIR/lib/lock.sh'
  acquire_deploy_lock '$TMP_DIR/compat_deploy.lock' '' 5
"
assert_ok "acquire_script_lock 别名可调用" bash -c "
  source '$PROJECT_DIR/lib/lock.sh'
  acquire_script_lock '$TMP_DIR/compat_script.lock' 5
"

# 清理函数
cleanup_deploy_lock "$lock_file"
assert_fail "cleanup 后 PID 文件已删除" test -f "${lock_file}.pid"

# ============================================================
# 2. R-05: push_trap/pop_trap 名称标签校验
# ============================================================
echo ""
echo "[2/6] R-05: Trap 栈名称标签校验..."

TRAP_STACK=()
push_trap 'tag_alpha' 'echo alpha_trap'
assert_eq "push 后栈大小为 1" "1" "${#TRAP_STACK[@]}"

# 正确名称 pop
pop_trap 'tag_alpha'
assert_eq "正确名称 pop 后栈为空" "0" "${#TRAP_STACK[@]}"

# 名称不匹配时应输出 warn
push_trap 'tag_beta' 'echo beta_trap'
mismatch_output=$(pop_trap 'tag_gamma' 2>&1 || true)
assert_output_contains "名称不匹配输出 warn" "不匹配" "$mismatch_output"

# ============================================================
# 3. E-01: 语义级节点校验 (jq 表达式)
# ============================================================
echo ""
echo "[3/6] E-01: 语义级节点校验..."

# 空出站 (仅 direct/block/dns) → 应返回 0
empty_config='{"outbounds":[{"type":"direct","tag":"direct"},{"type":"block","tag":"block"},{"type":"dns","tag":"dns-out"}]}'
empty_count=$(echo "$empty_config" | jq '[.outbounds[] | select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest")] | length')
assert_eq "空出站配置节点数为 0" "0" "$empty_count"

# 有效出站 → 应返回 >0
valid_config='{"outbounds":[{"type":"direct","tag":"direct"},{"type":"vless","tag":"proxy-hk"},{"type":"shadowsocks","tag":"proxy-jp"}]}'
valid_count=$(echo "$valid_config" | jq '[.outbounds[] | select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest")] | length')
assert_eq "有效出站配置节点数为 2" "2" "$valid_count"

# ============================================================
# 4. E-07: Node.js 版本检测正则
# ============================================================
echo ""
echo "[4/6] E-07: Node.js 版本检测正则..."

assert_ok   "v20.18.0 匹配"  bash -c "echo 'v20.18.0' | grep -qE 'v(20|22|23)\.'"
assert_ok   "v22.1.0 匹配"   bash -c "echo 'v22.1.0'  | grep -qE 'v(20|22|23)\.'"
assert_ok   "v23.0.0 匹配"   bash -c "echo 'v23.0.0'  | grep -qE 'v(20|22|23)\.'"
assert_fail "v18.0.0 不匹配" bash -c "echo 'v18.0.0'  | grep -qE 'v(20|22|23)\.'"
assert_fail "v21.5.0 不匹配" bash -c "echo 'v21.5.0'  | grep -qE 'v(20|22|23)\.'"
assert_fail "v19.9.0 不匹配" bash -c "echo 'v19.9.0'  | grep -qE 'v(20|22|23)\.'"

# ============================================================
# 5. E-08: URL/TAG 数量校验 (generate_providers.sh)
# ============================================================
echo ""
echo "[5/6] E-08: URL/TAG 数量校验..."

# 先创建 dummy template 文件
echo '{}' > "$TMP_DIR/dummy_template.json"

# 数量一致 → 成功
assert_ok "URL=TAG 数量一致时成功" bash "$PROJECT_DIR/scripts/generate_providers.sh" \
  "$TMP_DIR/dummy_template.json" \
  "https://a.com,https://b.com" \
  "TagA,TagB" \
  "$TMP_DIR/providers_ok.json"

# 数量不一致 → 失败
assert_fail "URL≠TAG 数量不一致时失败" bash "$PROJECT_DIR/scripts/generate_providers.sh" \
  "$TMP_DIR/dummy_template.json" \
  "https://a.com,https://b.com" \
  "TagA" \
  "$TMP_DIR/providers_bad.json"

# ============================================================
# 6. C-06: config-gen.sh CREDENTIALS_DIRECTORY 检查
# ============================================================
echo ""
echo "[6/6] C-06: config-gen.sh CREDENTIALS_DIRECTORY 检查..."

# 未设置 CREDENTIALS_DIRECTORY → 应 exit 1
assert_fail "CREDENTIALS_DIRECTORY 未设置时失败" env -u CREDENTIALS_DIRECTORY \
  bash "$PROJECT_DIR/templates/sing-box-config-gen.sh"

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
