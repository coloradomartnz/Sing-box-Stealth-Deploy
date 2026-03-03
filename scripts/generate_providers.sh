#!/usr/bin/env bash
#
# sing-box deployment project - providers.json generator
#

set -euo pipefail

# args: <config_template_path> <airport_urls_comma_separated> <airport_tags_comma_separated>
TEMPLATE_PATH="$1"
URLS_CSV="$2"
TAGS_CSV="$3"
OUTPUT_PATH="${4:-/usr/local/etc/sing-box/providers.json}"

[ -f "$TEMPLATE_PATH" ] || { echo "Template not found: $TEMPLATE_PATH" >&2; exit 1; }

IFS=',' read -r -a URLS <<< "$URLS_CSV"
IFS=',' read -r -a TAGS <<< "$TAGS_CSV"

# 构造 providers.json
# sing-box-subscribe 期望的字段:
#   "subscribes": [ {"tag": "...", "url": "..."} ]  — 注意是 subscribes 不是 sublinks
#   "save_config_path": "..." — 输出配置文件路径
#   "config_template": "" — 留空，使用 --template_index 从 config_template/ 目录选择
#
# 不要将本地文件路径设入 config_template，否则 main.py 会 requests.get() 导致 MissingSchema 错误

# O-E3 优化: 单次 jq 调用构造所有订阅，避免 O(N) 次 fork
# 构造 subscribes JSON 数组
subs_json="[]"
for i in "${!URLS[@]}"; do
  subs_json=$(printf '%s' "$subs_json" | jq --arg tag "${TAGS[$i]}" --arg url "${URLS[$i]}" \
    '. + [{"tag": $tag, "url": $url}]')
done

jq -n \
  --argjson subs "$subs_json" \
  --arg save_path "/usr/local/etc/sing-box/config.json" \
  '{"subscribes": $subs, "save_config_path": $save_path}' > "$OUTPUT_PATH"

# C-1 安全加固: 收紧权限，防止订阅 URL (含 token) 被未授权进程读取
chmod 640 "$OUTPUT_PATH"
chown root:sing-box "$OUTPUT_PATH" 2>/dev/null || true

echo "[INFO] providers.json generated at $OUTPUT_PATH (permissions: 640)"
