#!/usr/bin/env bash
set -euo pipefail

log_info(){ echo "[INFO] $*"; }
log_warn(){ echo "[WARN] $*" >&2; }
log_error(){ echo "[ERROR] $*" >&2; }

LOCK_FILE="/run/lock/sing-box-update.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "[WARN] 另一个 sing-box 更新任务正在运行，当前实例退出 (Another update task is running, exiting)" >&2
  exit 0
fi

RULESET_DIR="/var/lib/sing-box/ruleset"
SERVICE="sing-box"

# 占位符——部署时由 sed 替换为主脚本中定义的 URL（单一来源）
RULESET_GEOSITE_CN_URL="%%RULESET_GEOSITE_CN_URL%%"
RULESET_GEOSITE_GEOLOC_NONCN_URL="%%RULESET_GEOSITE_GEOLOC_NONCN_URL%%"
RULESET_GEOIP_CN_URL="%%RULESET_GEOIP_CN_URL%%"

mkdir -p "$RULESET_DIR"
chmod 755 "$RULESET_DIR"

ts="$(date +%Y%m%d-%H%M%S)"
bak_dir="${RULESET_DIR}/backups"
mkdir -p "$bak_dir"
chmod 755 "$bak_dir"

FILES=( "geosite-cn.srs" "geosite-geolocation-!cn.srs" "geoip-cn.srs" )

rollback() {
  set +e
  trap - ERR

  echo "[!] Weekly ruleset update failed, rolling back..." >&2

  # 1) 回滚规则文件
  for f in "${FILES[@]}"; do
    if [ -f "$bak_dir/$f.$ts" ]; then
      cp -f "$bak_dir/$f.$ts" "$RULESET_DIR/$f"
    fi
    rm -f "$RULESET_DIR/$f.tmp" 2>/dev/null || true
  done

  # 2) 尝试恢复服务：先重启；失败则 reset-failed + 再次启动
  systemctl restart "$SERVICE" 2>/dev/null || true

  if ! systemctl is-active --quiet "$SERVICE"; then
    systemctl reset-failed "$SERVICE" 2>/dev/null || true
    sleep 2
    systemctl start "$SERVICE" 2>/dev/null || true
  fi


  # 3) 最终检查，不行就吐日志
  if ! systemctl is-active --quiet "$SERVICE"; then
    echo "[CRITICAL] rollback done but service still not active; check logs (回滚完成但服务依然宕机):" >&2
    journalctl -u "$SERVICE" -n 200 --no-pager >&2 || true
  fi

  exit 1
}


# A-5: 引入公共规则集下载逻辑 (DRY)
 source /usr/local/etc/sing-box/lib/utils.sh
 source /usr/local/etc/sing-box/lib/ruleset.sh

# 1) 备份现有规则（本次更新专用快照）
for f in "${FILES[@]}"; do
  if [ -d "$RULESET_DIR" ]; then
    find "$RULESET_DIR" -maxdepth 1 -type f -mtime +30 -name "*.srs.*" -delete
    # 确保 sing-box 用户有权读取规则集
    if id -u sing-box >/dev/null 2>&1; then
      chown -R sing-box:sing-box "$RULESET_DIR"
    fi
  fi
  if [ -f "$RULESET_DIR/$f" ]; then
    cp -f "$RULESET_DIR/$f" "$bak_dir/$f.$ts"
  fi
done

# 从这里开始：关键失败才回滚（下载失败会保留旧文件，不触发回滚）
trap rollback ERR

# 2) 下载并原子替换（逐个检查，允许部分失败）
DOWNLOAD_FAILED=0

download_ruleset "$RULESET_GEOSITE_CN_URL" "$RULESET_DIR/geosite-cn.srs" || DOWNLOAD_FAILED=1
download_ruleset "$RULESET_GEOSITE_GEOLOC_NONCN_URL" "$RULESET_DIR/geosite-geolocation-!cn.srs" || DOWNLOAD_FAILED=1
download_ruleset "$RULESET_GEOIP_CN_URL" "$RULESET_DIR/geoip-cn.srs" || DOWNLOAD_FAILED=1

# 检查是否至少有一个文件成功存在
MISSING_COUNT=0
for file in "geosite-cn.srs" "geosite-geolocation-!cn.srs" "geoip-cn.srs"; do
  [ ! -f "$RULESET_DIR/$file" ] && MISSING_COUNT=$((MISSING_COUNT + 1))
done

if [ $MISSING_COUNT -eq 3 ]; then
  echo "[CRITICAL] 所有规则集文件缺失，无法继续 (All ruleset files are missing, cannot continue)" >&2
  exit 1
fi

if [ $DOWNLOAD_FAILED -eq 1 ]; then
  echo "[WARN] 部分规则集更新失败，但保留旧文件继续运行 (Partial rulesets update failed, continuing with old files)" >&2
fi

# 3) 重启 + 健康检查
systemctl restart "$SERVICE"
systemctl is-active --quiet "$SERVICE"

# 4) 清理过期 ruleset 备份（保留 30 天）
find "$bak_dir" -type f -mtime +30 -delete 2>/dev/null || true

# 成功后取消 trap
trap - ERR
exit 0
