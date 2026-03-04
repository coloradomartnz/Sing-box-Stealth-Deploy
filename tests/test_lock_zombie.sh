#!/usr/bin/env bash
set -eo pipefail

echo "=== 测试僵死进程锁抢占 (test_lock_zombie.sh) ==="

PROJECT_DIR="$(readlink -f "$(dirname "$0")/..")"
source "$PROJECT_DIR/lib/utils.sh"
source "$PROJECT_DIR/lib/lock.sh"

TEST_DIR=$(mktemp -d)
trap 'rm -rf "$TEST_DIR"' EXIT

LOCK_FILE="$TEST_DIR/test.lock"
PID_FILE="$TEST_DIR/test.pid"

echo "[1] 测试后台进程正常获取互斥锁"
(
	acquire_deploy_lock "$LOCK_FILE" "$PID_FILE" 5
	# 保持锁定 10 秒
	sleep 10
) &
BG_PID=$!

# 等待后台实际拿到锁
sleep 1

echo "[2] 测试存活周期内的写冲突"
if acquire_deploy_lock "$LOCK_FILE" "$PID_FILE" 2 >/dev/null 2>&1; then
	echo "❌ 存活期间被异常抢占"
	kill "$BG_PID" || true
	exit 1
fi
echo "  ✓ 锁被正确互斥保护"

# 杀掉持有锁的进程（此时内核会自动释放文件锁）
kill "$BG_PID" || true
wait "$BG_PID" 2>/dev/null || true

echo "[3] 测试系统清理机制获取上一个被内核释放的锁"
# 后台进程虽然被杀，由于是内核抛弃它的 flock 返回态，此时可以直接抢到
if ! acquire_deploy_lock "$LOCK_FILE" "$PID_FILE" 2 >/dev/null 2>&1; then
	echo "❌ 未能获取上一个死掉进程留下的无主锁"
	exit 1
fi
echo "  ✓ 成功获取无主锁"

echo "=== 测试通过 ==="
exit 0
