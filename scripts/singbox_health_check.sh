#!/usr/bin/env bash
set -euo pipefail

# O-6 修复 + O-1: 使用共享锁库替代死代码 acquire_lock 函数
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

# 注意：锁在 __run_check 子进程中获取（见下方），而非外层调用
# P0 修复：外层调用持锁后派生子进程，子进程无法获锁而 exit 0，
#           导致 do_health_check() 从不执行。

export FAILED_TITLE="sing-box 健康检查失败"
export FAILED_BODY="代理服务异常，请检查"

do_health_check() {
  local FAILED=0
  local TIMESTAMP
  TIMESTAMP="$(date "+%Y-%m-%d %H:%M:%S")"

  # 1. 检查服务状态
  if ! timeout 2s systemctl is-active --quiet sing-box; then
    echo "[ERROR] [$TIMESTAMP] sing-box service is not running" >&2
    FAILED=1
  fi

  # 2. 检查 TUN 接口
  if ! timeout 2s ip link show singbox_tun &>/dev/null; then
    echo "[ERROR] [$TIMESTAMP] TUN interface singbox_tun does not exist" >&2
    FAILED=1
  fi

  # 3. 检查外网连通性
  local PROXY_TARGETS=(
    "https://www.google.com"
    "https://1.1.1.1"
    "https://www.cloudflare.com"
  )

  local PROXY_OK=0
  for target in "${PROXY_TARGETS[@]}"; do
    if timeout 8s curl -sf -m 7 "$target" >/dev/null 2>&1; then
      PROXY_OK=1
      break
    fi
  done

  if [ "$PROXY_OK" -eq 0 ]; then
    echo "[ERROR] [$TIMESTAMP] All proxy targets unreachable" >&2
    FAILED=1
  fi

  # 4. 检查直连（非致命）
  if ! timeout 5s curl -sf -m 4 "https://www.baidu.com" >/dev/null 2>&1; then
    echo "[WARN] [$TIMESTAMP] Direct route may be broken" >&2
  fi

  # 5. 桌面通知（如果失败）- 多层降级策略
  if [ "$FAILED" -eq 1 ]; then
    echo "[CRITICAL] [$TIMESTAMP] Health check FAILED" >&2
    send_notification "$FAILED_TITLE" "$FAILED_BODY"
    return 1
  fi

  echo "[OK] [$TIMESTAMP] Health check passed"
  return 0
}

send_notification() {
  local title="$1"
  local body="$2"
  
  # 方法 1: systemd 用户服务（推荐）
  if command -v systemctl &>/dev/null; then
    for user_id in $(loginctl list-users --no-legend 2>/dev/null | awk "{print \$1}"); do
      if systemctl --user -M "${user_id}@" is-active --quiet graphical-session.target 2>/dev/null; then
        systemd-run --user -M "${user_id}@" --no-block --quiet \
          notify-send -u critical -i network-error "$title" "$body" \
          2>/dev/null && return 0
      fi
    done
  fi
  
  # 方法 2: D-Bus 直接调用
  if command -v dbus-send &>/dev/null && command -v loginctl &>/dev/null; then
    while IFS= read -r session; do
      local session_id user_name session_type user_id
      session_id=$(echo "$session" | awk "{print \$1}")
      user_name=$(loginctl show-session "$session_id" -p Name --value 2>/dev/null || echo "")
      session_type=$(loginctl show-session "$session_id" -p Type --value 2>/dev/null || echo "")
      
      [[ "$session_type" != "x11" && "$session_type" != "wayland" ]] && continue
      [ -z "$user_name" ] && continue
      
      user_id=$(id -u "$user_name" 2>/dev/null || echo "")
      [ -z "$user_id" ] && continue
      
      sudo -u "$user_name" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$user_id/bus" \
        dbus-send --session --print-reply \
        --dest=org.freedesktop.Notifications \
        /org/freedesktop/Notifications \
        org.freedesktop.Notifications.Notify \
        string:"sing-box" uint32:0 string:"" \
        string:"$title" string:"$body" \
        array:string: dict:string:string: int32:5000 \
        2>/dev/null && return 0
    done < <(loginctl list-sessions --no-legend 2>/dev/null)
  fi
  
  # 方法 3: 传统 notify-send（兼容性）
  if command -v notify-send &>/dev/null; then
    for user_info in $(who | awk "{print \$1\":\"\$NF}" | grep "(:"); do
      local USER_NAME DISPLAY_NUM USER_ID
      USER_NAME="${user_info%%:*}"
      DISPLAY_NUM="${user_info##*:}"
      DISPLAY_NUM="${DISPLAY_NUM/)/}"
      DISPLAY_NUM=":${DISPLAY_NUM#(}"
      
      USER_ID=$(id -u "$USER_NAME" 2>/dev/null || echo "")
      [ -z "$USER_ID" ] && continue
      
      sudo -u "$USER_NAME" \
        DISPLAY="$DISPLAY_NUM" \
        DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$USER_ID/bus" \
        notify-send -u critical -i network-error "$title" "$body" \
        2>/dev/null && return 0
    done
  fi
  
  # 方法 4: 降级到系统日志
  logger -t sing-box -p user.crit "$title: $body"
  return 1
}

if [[ "${1:-}" == "__run_check" ]]; then
  # 在真正执行检查的子进程中加锁，阻止并发实例（P0 修复）
  if type acquire_script_lock &>/dev/null; then
    acquire_script_lock "/run/lock/singbox-healthcheck.lock" 30 || exit 0
  fi
  do_health_check
  exit $?
fi

# 审计修复(E-06): 使用绝对路径自引用，防止 $0 被 symlink 劫持
_self_path="$(readlink -f "$0")"
timeout 45s "$_self_path" __run_check || {
  echo "[CRITICAL] [$(date '+%Y-%m-%d %H:%M:%S')] Health check TIMEOUT" >&2
  exit 1
}
