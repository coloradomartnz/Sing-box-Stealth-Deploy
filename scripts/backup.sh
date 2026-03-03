#!/usr/bin/env bash
#
# sing-box 配置备份脚本（分层保留策略）
# 每日：保留 7 天
# 每周：保留 4 周  
# 每月：保留 12 个月
#
set -euo pipefail

# O-7 修复: 加文件锁防止与 update_and_restart.sh 并发导致备份不完整配置
LOCK_FILE="/run/lock/singbox-backup.lock"
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
  echo "[WARN] 另一个备份/更新任务正在运行，跳过本次备份" >&2
  exit 0
fi

cd /usr/local/etc/sing-box

ts="$(date +%Y%m%d-%H%M%S)"
day_of_week=$(date +%u)  # 1-7 (周一到周日)
day_of_month=$(date +%d) # 01-31

# 创建目录结构
mkdir -p backups/{daily,weekly,monthly}

# 每日备份
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 执行每日备份..."
for f in config.json providers.json config_template.json; do
  if [ -f "$f" ]; then
    cp "$f" "backups/daily/$f.$ts"
    echo "  ✓ $f → backups/daily/$f.$ts"
  fi
done

# 每周备份（仅周日执行）
if [ "$day_of_week" -eq 7 ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 今天是周日，执行每周备份..."
  for f in config.json providers.json config_template.json; do
    if [ -f "$f" ]; then
      cp "$f" "backups/weekly/$f.$ts"
      echo "  ✓ $f → backups/weekly/$f.$ts"
    fi
  done
fi

# 每月备份（仅每月1日执行）
if [ "$day_of_month" = "01" ]; then
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] 今天是每月1日，执行每月备份..."
  for f in config.json providers.json config_template.json; do
    if [ -f "$f" ]; then
      cp "$f" "backups/monthly/$f.$ts"
      echo "  ✓ $f → backups/monthly/$f.$ts"
    fi
  done
fi

# 清理过期备份 (分文件类型保留)
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 清理过期备份..."

# 定义清理函数：保留每个文件类型的最新 N 个副本
cleanup_backups() {
  local dir="$1"
  local keep="$2"
  # 针对每种配置文件分别清理
  for prefix in config.json providers.json config_template.json; do
    # 列出该类型的所有备份，按时间倒序
    # 注意：文件名格式为 prefix.timestamp
    # 使用 grep 确保只匹配该前缀的文件
    (cd "$dir" && ls -1t "${prefix}"* 2>/dev/null | tail -n +$((keep + 1)) | xargs -r rm -f) || true
  done
}

# 每日备份：保留 7 个
cleanup_backups "backups/daily" 7

# 每周备份：保留 4 个
cleanup_backups "backups/weekly" 4

# 每月备份：保留 12 个
cleanup_backups "backups/monthly" 12

daily_count=$(find backups/daily -name "*.json.*" -type f 2>/dev/null | wc -l)
weekly_count=$(find backups/weekly -name "*.json.*" -type f 2>/dev/null | wc -l)
monthly_count=$(find backups/monthly -name "*.json.*" -type f 2>/dev/null | wc -l)

echo "  每日备份: $daily_count 个文件"
echo "  每周备份: $weekly_count 个文件"
echo "  每月备份: $monthly_count 个文件"

backup_size=$(du -sh backups/ 2>/dev/null | awk '{print $1}' || echo "未知")
echo "[$(date '+%Y-%m-%d %H:%M:%S')] 备份完成，总空间占用: $backup_size"
