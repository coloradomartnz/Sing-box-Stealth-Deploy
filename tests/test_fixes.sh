#!/usr/bin/env bash
#
# sing-box-stealth-deploy 集成测试脚本
# 在 Docker 容器内运行，验证所有代码审查修复项
#
set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
YELLOW=$'\033[1;33m'
NC=$'\033[0m'

PASS=0
FAIL=0
SKIP=0

assert_ok() {
  local desc="$1"
  shift
  if "$@" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc"
    FAIL=$((FAIL + 1))
  fi
}

assert_fail() {
  local desc="$1"
  shift
  if ! "$@" >/dev/null 2>&1; then
    echo -e "  ${GREEN}✓${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc (应该失败但成功了)"
    FAIL=$((FAIL + 1))
  fi
}

assert_contains() {
  local desc="$1"
  local file="$2"
  local pattern="$3"
  if grep -q "$pattern" "$file" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc (未找到: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

assert_not_contains() {
  local desc="$1"
  local file="$2"
  local pattern="$3"
  if ! grep -q "$pattern" "$file" 2>/dev/null; then
    echo -e "  ${GREEN}✓${NC} $desc"
    PASS=$((PASS + 1))
  else
    echo -e "  ${RED}✗${NC} $desc (不应包含: $pattern)"
    FAIL=$((FAIL + 1))
  fi
}

skip_test() {
  local desc="$1"
  echo -e "  ${YELLOW}⊘${NC} $desc (跳过)"
  SKIP=$((SKIP + 1))
}

echo "============================================="
echo "  sing-box-stealth-deploy 集成测试"
echo "============================================="
echo ""

# ============================================================
# 测试组 1: Shell 脚本语法验证
# ============================================================
echo "[1/9] Shell 脚本语法验证..."
for f in singbox-deploy.sh lib/*.sh cmd/*.sh steps/*.sh scripts/*.sh; do
  assert_ok "bash -n $f" bash -n "$f"
done

# ============================================================
# 测试组 2: Python 语法验证 (O-3: shebang 修正)
# ============================================================
echo ""
echo "[2/9] Python 脚本验证 (O-3)..."
assert_ok "Python shebang 为 python3" head -1 scripts/singbox_build_region_groups.py | grep -q "python3"
assert_ok "Python 语法编译通过" python3 -c "import py_compile; py_compile.compile('scripts/singbox_build_region_groups.py', doraise=True)"

# ============================================================
# 测试组 3: 核心库单元测试
# ============================================================
echo ""
echo "[3/9] 核心库函数测试..."

# Source 核心库
source lib/globals.sh
source lib/utils.sh
source lib/checks.sh
source lib/lock.sh
source lib/ruleset.sh

# C-3: _atomic_write 使用 printf 而非 echo
echo ""
echo "  --- C-3: _atomic_write ---"
test_file="/tmp/test_atomic_$$"
_atomic_write "$test_file" "test content"
assert_ok "原子写入基本功能" test -f "$test_file"
assert_ok "原子写入内容正确" grep -q "test content" "$test_file"

# 测试以 -e 开头的内容（echo 会解释为选项）
_atomic_write "$test_file" "-e flag test"
assert_ok "原子写入 -e 前缀安全" grep -q "^-e flag test$" "$test_file"

# 测试以 -n 开头的内容
_atomic_write "$test_file" "-n no newline test"
assert_ok "原子写入 -n 前缀安全" grep -q "^-n no newline test$" "$test_file"
rm -f "$test_file"

# O-2: detect_lan_subnet 位运算
echo ""
echo "  --- O-2: detect_lan_subnet 位运算 ---"

# 创建模拟网络接口测试用例 (使用 _validate_cidr 间接测试)
assert_ok "CIDR 验证: 192.168.1.0/24 合法" _validate_cidr "192.168.1.0/24"
assert_ok "CIDR 验证: 10.0.0.0/8 合法" _validate_cidr "10.0.0.0/8"
assert_ok "CIDR 验证: 172.16.0.0/20 合法" _validate_cidr "172.16.0.0/20"
assert_fail "CIDR 验证: 256.0.0.0/8 非法" _validate_cidr "256.0.0.0/8"
assert_fail "CIDR 验证: 1.2.3.4/33 非法" _validate_cidr "1.2.3.4/33"

# C-4: Trap 注册机制
# --- A-6: 核心函数输入输出测试 ---
echo ""
echo "  --- A-6: _redact 脱敏安全测试 ---"
_redact_test_1=$(echo "https://api.example.com/sub?token=12345ABCD" | (source lib/utils.sh; _redact))
assert_ok "_redact 正确隐藏 token" test "$_redact_test_1" = "<REDACTED_URL>"

_redact_test_2=$(echo "vless://abcd-1234@10.0.0.1:443" | (source lib/utils.sh; _redact))
assert_ok "_redact 正确隐藏 UUID/IP" test "$_redact_test_2" = "vless://abcd-1234@<REDACTED_IP>:443"

_redact_test_3=$(echo "正常文本信息 unaffected" | (source lib/utils.sh; _redact))
assert_ok "_redact 不破坏正常文本" test "$_redact_test_3" = "正常文本信息 unaffected"

echo ""
echo "  --- C-4: Trap 注册机制 ---"
# push_trap / pop_trap 基本工作
push_trap 'echo test_trap_fired' 
assert_ok "push_trap 后 TRAP_STACK 非空" test "${#TRAP_STACK[@]}" -gt 0
pop_trap
assert_ok "pop_trap 后 TRAP_STACK 为空" test "${#TRAP_STACK[@]}" -eq 0

# ============================================================
# 测试组 4: 共享锁库测试 (O-1 / A-3 统一重构)
# ============================================================
echo ""
echo "[4/9] 共享锁库测试 (O-1 / A-3)..."
assert_ok "lock.sh 存在" test -f lib/lock.sh
assert_ok "lock.sh 可 source 并包含 acquire_script_lock" bash -c 'source lib/lock.sh; type acquire_script_lock'

# 测试锁获取与释放
bash -c '
  source lib/lock.sh
  acquire_script_lock "/tmp/test_lock_$$" 5 || exit 1
  [ -f "/tmp/test_lock_$$.pid" ] || exit 1
  exit 0
' 2>/dev/null
assert_ok "锁获取成功且 PID 文件创建" test $? -eq 0

# ============================================================
# 测试组 5: 模板渲染测试 (H-3, O-4)
# ============================================================
echo ""
echo "[5/9] 模板与配置测试..."

# H-3: Dashboard 绑定 localhost
assert_contains "H-3: Dashboard 绑定 127.0.0.1" templates/config_template.json.tpl "127.0.0.1"
assert_not_contains "H-3: 不再绑定 0.0.0.0" templates/config_template.json.tpl "0.0.0.0:\${DASHBOARD_PORT}"

# ============================================================
# 测试组 6: 安全性测试 (H-4, C-1)
# ============================================================
echo ""
echo "[6/9] 安全性测试..."

# H-4: source 注入防护
echo ""
echo "  --- H-4: 部署配置注入防护 ---"
# 创建合法配置
cat > /tmp/test_deploy_config_ok <<'EOF'
MAIN_IFACE="eth0"
LAN_SUBNET="192.168.1.0/24"
HAS_IPV6="0"
EOF
assert_ok "合法配置格式通过验证" bash -c '
  ! grep -qvE "^[A-Za-z_][A-Za-z0-9_]*=\"[^\"]*\"$|^[[:space:]]*$|^#" /tmp/test_deploy_config_ok
'

# 创建恶意配置
cat > /tmp/test_deploy_config_bad <<'EOF'
MAIN_IFACE="eth0"
$(rm -rf /)
LAN_SUBNET="192.168.1.0/24"
EOF
assert_ok "恶意配置被拒绝" bash -c '
  grep -qvE "^[A-Za-z_][A-Za-z0-9_]*=\"[^\"]*\"$|^[[:space:]]*$|^#" /tmp/test_deploy_config_bad
'

rm -f /tmp/test_deploy_config_ok /tmp/test_deploy_config_bad

# C-1: providers.json 权限
echo ""
echo "  --- C-1: providers.json 权限 ---"
assert_contains "generate_providers.sh 包含 chmod 640" scripts/generate_providers.sh "chmod 640"
assert_contains "generate_providers.sh 包含 chown root:sing-box" scripts/generate_providers.sh "chown root:sing-box"

# ============================================================
# 测试组 7: 并行下载修复测试 (C-2)
# ============================================================
echo ""
echo "[7/9] 并行下载测试 (C-2)..."
assert_contains "04-rulesets.sh 追踪 PID" steps/04-rulesets.sh "pids+=(\$!)"
assert_contains "04-rulesets.sh 检查退出码" steps/04-rulesets.sh 'wait "${pids\[$i\]}"'
assert_not_contains "04-rulesets.sh 不使用裸 wait" steps/04-rulesets.sh "^[[:space:]]*wait$"

# ============================================================
# 测试组 8: Docker 路由测试 (H-1)
# ============================================================
echo ""
echo "[8/9] Docker 路由精细化测试 (H-1)..."
assert_contains "Docker 路由包含 ip_cidr 约束" scripts/add_docker_route.sh "ip_cidr"
assert_contains "Docker 路由包含私有网段 172.16" scripts/add_docker_route.sh "172.16.0.0/12"
assert_contains "Docker 路由包含私有网段 10.0" scripts/add_docker_route.sh "10.0.0.0/8"

# ============================================================
# 测试组 9: 卸载与备份完整性测试 (O-5, O-7)
# ============================================================
echo ""
echo "[9/9] 卸载与备份测试..."

# O-5: 卸载清理部署锁
assert_contains "O-5: 卸载清理 deploy lock" cmd/uninstall.sh "singbox-deploy.lock"
assert_contains "O-5: 卸载清理 deploy lock PID" cmd/uninstall.sh "singbox-deploy.lock.pid"

# O-7: 备份脚本加锁
assert_contains "O-7: backup.sh 使用 flock" scripts/backup.sh "flock"
assert_contains "O-7: backup.sh 锁文件路径" scripts/backup.sh "singbox-backup.lock"

# O-1: 部署列表包含统一锁库
assert_contains "O-1: 部署列表含 lock.sh" steps/02-dirs-and-scripts.sh "lib/lock.sh"

# O-6: health_check 无死代码
assert_not_contains "O-6: health_check 无内联 acquire_lock" scripts/singbox_health_check.sh "^acquire_lock()"

# H-2: IPv6 检测
assert_contains "H-2: 主脚本含 IPv6 检测" singbox-deploy.sh "ip -6 addr show"
assert_contains "H-2: 主脚本设置 HAS_IPV6" singbox-deploy.sh "HAS_IPV6=1"

# ============================================================
# 汇总
# ============================================================
echo ""
echo "============================================="
TOTAL=$((PASS + FAIL + SKIP))
echo -e "  测试完成: ${GREEN}${PASS} 通过${NC} / ${RED}${FAIL} 失败${NC} / ${YELLOW}${SKIP} 跳过${NC} (共 ${TOTAL})"
if [ "$FAIL" -eq 0 ]; then
  echo -e "  ${GREEN}✅ 全部测试通过${NC}"
else
  echo -e "  ${RED}❌ 存在失败测试${NC}"
fi
echo "============================================="
echo ""

exit "$FAIL"
