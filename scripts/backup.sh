#!/usr/bin/env bash
#
# sing-box 配置备份脚本（分层保留策略）
# 每日：保留 7 天
# 每周：保留 4 周  
# 每月：保留 12 个月
#
set -euo pipefail

# 使用共享锁库（含 stale-lock 检测），与其他脚本保持一致
_SHARED_LOCK="/usr/local/etc/sing-box/lib/lock.sh"
if [ -f "$_SHARED_LOCK" ]; then
  # shellcheck source=/dev/null
  source "$_SHARED_LOCK"
fi

if type acquire_script_lock &>/dev/null; then
  if ! acquire_script_lock /run/lock/singbox-backup.lock 30; then
    echo "[WARN] 另一个备份/更新任务正在运行，跳过本次备份" >&2
    exit 0
  fi
else
  # Fallback: 原始 flock
  exec 200>/run/lock/singbox-backup.lock
  if ! flock -n 200; then
    echo "[WARN] 另一个备份/更新任务正在运行，跳过本次备份" >&2
    exit 0
  fi
fi

cd /usr/local/etc/sing-box

ts="$(date +%Y%m%d-%H%M%S)"
day_of_week=$(date +%u)  # 1-7 (周一到周日)
day_of_month=$(date +%d) # 01-31

# 创建目录结构
mkdir -p backups/{daily,weekly,monthly}

# 每日备份：压缩归档（减少磁盘占用 ~70%）
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 执行每日备份..."
_files_to_backup=()
for f in config.json providers.json config_template.json; do
  [ -f "$f" ] && _files_to_backup+=("$f")
done
if [ ${#_files_to_backup[@]} -gt 0 ]; then
  tar -czf "backups/daily/snapshot-${ts}.tar.gz" "${_files_to_backup[@]}"
  echo "  ✓ snapshot-${ts}.tar.gz → backups/daily/ (${_files_to_backup[*]})"
fi

# 每周备份（仅周日执行）
if [ "$day_of_week" -eq 7 ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 今天是周日，执行每周备份..."
  if [ ${#_files_to_backup[@]} -gt 0 ]; then
    tar -czf "backups/weekly/snapshot-${ts}.tar.gz" "${_files_to_backup[@]}"
    echo "  ✓ snapshot-${ts}.tar.gz → backups/weekly/"
  fi
fi

# 每月备份（仅每月1日执行）
if [ "$day_of_month" = "01" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 今天是每月1日，执行每月备份..."
  if [ ${#_files_to_backup[@]} -gt 0 ]; then
    tar -czf "backups/monthly/snapshot-${ts}.tar.gz" "${_files_to_backup[@]}"
    echo "  ✓ snapshot-${ts}.tar.gz → backups/monthly/"
  fi
fi

# 清理过期备份：单次 find 调用处理所有前缀，减少 fork 次数
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 清理过期备份..."

cleanup_backups() {
  local dir="$1"
  local keep="$2"
  # 单次 find 列出目录内所有 .tar.gz 快照文件，按时间排序后删除超出 keep 数量的旧文件
  find "$dir" -maxdepth 1 \( -name "snapshot-*.tar.gz" -o -name "*.json.*" \) -type f \
    -printf '%T@\t%p\n' 2>/dev/null |
    sort -t$'\t' -k1 -rn | tail -n +$((keep + 1)) | cut -f2- |
    while IFS= read -r f; do rm -f "$f"; done
}

# 每日备份：保留 7 个
cleanup_backups "backups/daily" 7

# 每周备份：保留 4 个
cleanup_backups "backups/weekly" 4

# 每月备份：保留 12 个
cleanup_backups "backups/monthly" 12

daily_count=$(find backups/daily -maxdepth 1 \( -name "snapshot-*.tar.gz" -o -name "*.json.*" \) -type f 2>/dev/null | wc -l)
weekly_count=$(find backups/weekly -maxdepth 1 \( -name "snapshot-*.tar.gz" -o -name "*.json.*" \) -type f 2>/dev/null | wc -l)
monthly_count=$(find backups/monthly -maxdepth 1 \( -name "snapshot-*.tar.gz" -o -name "*.json.*" \) -type f 2>/dev/null | wc -l)

echo "  每日备份: $daily_count 个文件"
echo "  每周备份: $weekly_count 个文件"
echo "  每月备份: $monthly_count 个文件"

backup_size=$(du -sh backups/ 2>/dev/null | awk '{print $1}' || echo "未知")
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 备份完成，总空间占用: $backup_size"
