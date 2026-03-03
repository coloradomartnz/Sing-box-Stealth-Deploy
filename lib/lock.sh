#!/usr/bin/env bash
#
# sing-box deployment project - lock management
#

acquire_deploy_lock() {
	local lock_file="$1"
	local pid_file="$2"
	local timeout="${3:-300}"
	local lock_fd=201 # 使用不同的 FD 避免冲突
	
	# 确保目录存在
	mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true

	# 原子性打开文件
	eval "exec ${lock_fd}>\"$lock_file\""
	
	local start
	start=$(date +%s)
	
	while ! flock -n "$lock_fd"; do
		local elapsed=$(($(date +%s) - start))
		
		if [ -f "$pid_file" ]; then
			local lock_pid
			lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
			
			if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
				log_warn "检测到过期部署锁 (PID $lock_pid)，继续尝试获取..."
			fi
		fi
		
		if [ "$elapsed" -ge "$timeout" ]; then
			log_error "获取安装锁超时 (${timeout}s)"
			[ -f "$pid_file" ] && log_info "当前锁定进程: $(cat "$pid_file" 2>/dev/null)"
			return 1
		fi
		
		log_warn "另一个安装程序正在运行，等待中... (${elapsed}/${timeout}s)"
		sleep 5
	done
	
	# 写入 PID
	echo $$ > "$pid_file"
	return 0
}

cleanup_deploy_lock() {
	local lock_file="$1"
	local pid_file="$2"
	rm -f "$pid_file" 2>/dev/null || true
}
acquire_script_lock() {
  local lock_file="$1"
  local timeout="${2:-300}"
  local lock_fd="${3:-200}"
  
  # 确保目录存在
  mkdir -p "$(dirname "$lock_file")" 2>/dev/null || true

  # 原子性打开文件
  eval "exec ${lock_fd}>\"$lock_file\""
  
  local start
  start=$(date +%s)
  local pid_file="${lock_file}.pid"
  
  while ! flock -n "$lock_fd"; do
    local elapsed=$(($(date +%s) - start))
    
    # 检查是否为僵尸锁
    if [ -f "$pid_file" ]; then
      local lock_pid
      lock_pid=$(cat "$pid_file" 2>/dev/null || echo "")
      
      if [ -n "$lock_pid" ] && ! kill -0 "$lock_pid" 2>/dev/null; then
        echo "[INFO] 检测到僵尸锁（PID $lock_pid），等待清理..." >&2
      fi
    fi
    
    if [ "$elapsed" -ge "$timeout" ]; then
      echo "[ERROR] 获取锁超时（${timeout}s）" >&2
      echo "[INFO] 锁文件: $lock_file" >&2
      [ -f "$pid_file" ] && echo "[INFO] 占用进程: $(cat "$pid_file" 2>/dev/null || echo "未知")" >&2
      return 1
    fi
    
    sleep 2
  done
  
  # 写入 PID
  echo $$ > "$pid_file" 2>/dev/null || true
  
  # C-2 修复: 链式 trap 注册，保留调用方已注册的 EXIT/INT/TERM trap
  local _prev_exit_trap
  _prev_exit_trap=$(trap -p EXIT | sed -E "s/^trap -- '(.*)' EXIT$/\1/" || echo "")
  local _lock_cleanup="rm -f '$pid_file' 2>/dev/null; eval \"exec ${lock_fd}>&-\""
  if [ -n "$_prev_exit_trap" ]; then
    # shellcheck disable=SC2064
    trap "${_lock_cleanup}; ${_prev_exit_trap}" EXIT INT TERM
  else
    # shellcheck disable=SC2064
    trap "${_lock_cleanup}" EXIT INT TERM
  fi
  
  return 0
}
