#!/usr/bin/env bash
#
# sing-box deployment project - lock management
# 审计修复(C-04/R-02): 合并两套锁实现，消除 trap 字符串拼接注入

# 全局锁 fd 清理栈（函数引用，不做字符串拼接）
declare -a _LOCK_CLEANUP_PID_FILES=()
declare -a _LOCK_CLEANUP_FDS=()

_lock_cleanup_handler() {
	local i
	for i in "${!_LOCK_CLEANUP_PID_FILES[@]}"; do
		rm -f "${_LOCK_CLEANUP_PID_FILES[$i]}" 2>/dev/null || true
	done
	for i in "${!_LOCK_CLEANUP_FDS[@]}"; do
		eval "exec ${_LOCK_CLEANUP_FDS[$i]}>&-" 2>/dev/null || true
	done
	_LOCK_CLEANUP_PID_FILES=()
	_LOCK_CLEANUP_FDS=()
}

# 统一锁获取接口
# 用法: acquire_lock <lock_file> [timeout_seconds]
# 返回: 0=成功 1=超时/失败
# 自动注册 EXIT/INT/TERM trap 进行清理
acquire_lock() {
	local lock_file="$1"
	local timeout="${2:-300}"
	local lock_fd
	local pid_file="${lock_file}.pid"

	# 确保目录存在
	mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true

	# 原子性打开文件 (安全语法，无 eval)
	exec {lock_fd}>"$lock_file"

	local start
	start=$(date +%s)

	while ! flock -n "$lock_fd"; do
		local elapsed=$(($(date +%s) - start))

		# 僵尸锁检测：PID 文件存在但进程已死
		if [ -f "$pid_file" ]; then
			local lock_pid
			lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")

			if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
				echo "[INFO] 检测到僵尸锁（PID $lock_pid），自动清理..." >&2
				rm -f "$pid_file" 2>/dev/null || true
				# 僵尸锁清理后立即重试
				continue
			fi
		fi

		if [ "$elapsed" -ge "$timeout" ]; then
			echo "[ERROR] 获取锁超时（${timeout}s）" >&2
			echo "[INFO] 锁文件: $lock_file" >&2
			[ -f "$pid_file" ] && echo "[INFO] 占用进程: $(cat "$pid_file" 2>/dev/null || echo "未知")" >&2
			# 关闭 fd，不占用资源
			eval "exec ${lock_fd}>&-" 2>/dev/null || true
			return 1
		fi

		sleep 2
	done

	# 写入 PID
	echo $$ > "$pid_file" 2>/dev/null || true

	# 注册清理（使用数组+函数引用，避免 trap 字符串拼接注入）
	_LOCK_CLEANUP_PID_FILES+=("$pid_file")
	_LOCK_CLEANUP_FDS+=("$lock_fd")

	# 只在第一次注册 trap（后续调用只是往数组追加）
	if [ "${#_LOCK_CLEANUP_PID_FILES[@]}" -eq 1 ]; then
		# 保存已有的 EXIT trap
		local _existing_exit_trap
		_existing_exit_trap=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/" 2>/dev/null || echo "")

		if [ -n "$_existing_exit_trap" ] && [ "$_existing_exit_trap" != "trap -p EXIT" ]; then
			# shellcheck disable=SC2064
			trap "_lock_cleanup_handler; $_existing_exit_trap" EXIT
		else
			trap '_lock_cleanup_handler' EXIT
		fi
		trap '_lock_cleanup_handler' INT TERM
	fi

	return 0
}

# 向后兼容别名
acquire_deploy_lock() {
	local lock_file="$1"
	# $2 = pid_file (旧 API，忽略，统一用 .pid 后缀)
	local timeout="${3:-300}"
	acquire_lock "$lock_file" "$timeout"
}

acquire_script_lock() {
	acquire_lock "$1" "${2:-300}"
}

cleanup_deploy_lock() {
	local lock_file="$1"
	# 旧 API 兼容：仅清理 PID 文件
	rm -f "${lock_file}.pid" 2>/dev/null || true
	# 如果传了第二个参数 (旧 pid_file 路径)，也清理
	[ -n "${2:-}" ] && rm -f "$2" 2>/dev/null || true
}
