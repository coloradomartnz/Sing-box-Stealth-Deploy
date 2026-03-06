#!/usr/bin/env bash
#
# sing-box deployment project - lock management
# Unified lock implementation (no trap string injection)

# Lock fd cleanup stack (function refs, no string concatenation)
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

# Unified lock acquisition
# Usage: acquire_lock <lock_file> [timeout_seconds]
# Returns: 0=success 1=timeout or failure
# Auto-registers EXIT/INT/TERM trap for cleanup
acquire_lock() {
	local lock_file="$1"
	local timeout="${2:-300}"
	local lock_fd
	local pid_file="${lock_file}.pid"

	# Ensure lock directory exists
	mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true

	# Atomically open lock file (safe syntax, no eval)
	exec {lock_fd}>"$lock_file"

	local start
	start=$(date +%s)

	while ! flock -n "$lock_fd"; do
		local elapsed=$(($(date +%s) - start))

		# Stale lock detection: PID file exists but process is dead
		if [ -f "$pid_file" ]; then
			local lock_pid
			lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")

			if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
				echo "[INFO] Stale lock detected (PID $lock_pid), auto-cleaning..." >&2
				rm -f "$pid_file" 2>/dev/null || true
				# Retry immediately after stale lock cleanup
				continue
			fi
		fi

		if [ "$elapsed" -ge "$timeout" ]; then
			echo "[ERROR] Lock acquisition timed out (${timeout}s)" >&2
			echo "[INFO] Lock file: $lock_file" >&2
			[ -f "$pid_file" ] && echo "[INFO] Held by PID: $(cat "$pid_file" 2>/dev/null || echo "unknown")" >&2
			# Close fd to free resources
			eval "exec ${lock_fd}>&-" 2>/dev/null || true
			return 1
		fi

		sleep 2
	done

	# Write PID
	echo $$ > "$pid_file" 2>/dev/null || true

	# Register cleanup (array+function refs, no trap string injection)
	_LOCK_CLEANUP_PID_FILES+=("$pid_file")
	_LOCK_CLEANUP_FDS+=("$lock_fd")

	# 只在第一次注册 trap（后续调用只是往数组追加）
	if [ "${#_LOCK_CLEANUP_PID_FILES[@]}" -eq 1 ]; then
		# 保存已有的 EXIT trap 并链接
		local _existing_exit_trap
		_existing_exit_trap=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/" 2>/dev/null || echo "")

		if [ -n "$_existing_exit_trap" ] && [ "$_existing_exit_trap" != "trap -p EXIT" ]; then
			# shellcheck disable=SC2064
			trap "_lock_cleanup_handler; $_existing_exit_trap" EXIT
		else
			trap '_lock_cleanup_handler' EXIT
		fi

		# P1 修复：同样链接已有的 INT trap，防止 Ctrl+C 时 _cleanup_all 被丢弃
		local _existing_int_trap
		_existing_int_trap=$(trap -p INT | sed -E "s/^trap -- '(.*)' INT$/\1/" 2>/dev/null || echo "")

		if [ -n "$_existing_int_trap" ] && [ "$_existing_int_trap" != "trap -p INT" ]; then
			# shellcheck disable=SC2064
			trap "_lock_cleanup_handler; $_existing_int_trap" INT TERM
		else
			trap '_lock_cleanup_handler' INT TERM
		fi
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
