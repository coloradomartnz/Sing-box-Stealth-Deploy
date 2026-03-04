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

# 审计修复(E-08): 校验 URL 和 TAG 数量必须一致，防止静默生成错误的 tag 映射
if [ "${#URLS[@]}" -ne "${#TAGS[@]}" ]; then
	echo "[ERROR] URL 数量 (${#URLS[@]}) 与 TAG 数量 (${#TAGS[@]}) 不一致，请检查输入参数" >&2
	exit 1
fi

# 构造 providers.json
# sing-box-subscribe 期望的字段:
#   "subscribes": [ {"tag": "...", "url": "..."} ]  — 注意是 subscribes 不是 sublinks
#   "save_config_path": "..." — 输出配置文件路径
#   "config_template": "" — 留空，使用 --template_index 从 config_template/ 目录选择
#
# 不要将本地文件路径设入 config_template，否则 main.py 会 requests.get() 导致 MissingSchema 错误

# H-4 修复: 单次 jq 调用构造所有订阅，避免 O(N) 次 fork
# 构造 JSON 数组: 将 URL 和 TAG 交错传入，单次 jq 分组
# 审计修复(E-08): 移除冗余 tonumber（--argjson 已将 count 解析为数字）
subs_json=$(jq -n \
  --argjson count "${#URLS[@]}" \
  '[$ARGS.positional | to_entries | .[] |
    if .key < $count then
      {"url": .value, "tag": $ARGS.positional[.key + $count]}
    else empty end]' \
  --args -- "${URLS[@]}" "${TAGS[@]}")

jq -n \
  --argjson subs "$subs_json" \
  --arg save_path "/usr/local/etc/sing-box/config.json" \
  '{"subscribes": $subs, "save_config_path": $save_path}' > "$OUTPUT_PATH"

# C-1 安全加固: 收紧权限，防止订阅 URL (含 token) 被未授权进程读取
chmod 640 "$OUTPUT_PATH"
chown root:sing-box "$OUTPUT_PATH" 2>/dev/null || true

echo "[INFO] providers.json generated at $OUTPUT_PATH (permissions: 640)"
