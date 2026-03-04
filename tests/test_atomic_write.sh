#!/usr/bin/env bash
set -eo pipefail

echo "=== 测试原子写入 (test_atomic_write.sh) ==="

# 加载测试目标
PROJECT_DIR="$(readlink -f "$(dirname "$0")/..")"
source "$PROJECT_DIR/lib/utils.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

TARGET="$TEST_DIR/config.json"
echo '{"status": "old"}' > "$TARGET"
chmod 644 "$TARGET"

echo "[1] 测试基本写入"
_atomic_write "$TARGET" '{"status": "new"}'
if ! grep -q '"new"' "$TARGET"; then
	echo "❌ 基本写入失败"
	exit 1
fi
echo "  ✓ 写入成功"

echo "[2] 测试权限继承"
chmod 600 "$TARGET"
_atomic_write "$TARGET" '{"status": "newer"}'
PERM=$(stat -c "%a" "$TARGET")
if [ "$PERM" != "600" ]; then
	echo "❌ 权限继承失败，当前权限为: $PERM"
	exit 1
fi
echo "  ✓ 权限继承正常 (600)"

echo "[3] 测试大段内容管道写入"
cat <<EOF | _atomic_write "$TARGET"
{
  "multi": "line",
  "data": true
}
EOF
if ! grep -q '"multi": "line"' "$TARGET"; then
	echo "❌ 管道写入失败"
	exit 1
fi
echo "  ✓ 管道写入工作正常"

echo "=== 测试通过 ==="
exit 0
