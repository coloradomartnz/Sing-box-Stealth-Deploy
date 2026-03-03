#!/usr/bin/env bash
#
# sing-box deployment project - ruleset management
#

ruleset_ok() {
	local f="$1"
	[ -s "$f" ]
}

download_ruleset() {
	local url="$1"
	local out="$2"
	local tmp
	tmp=$(mktemp -p "$(dirname "$out")" "$(basename "$out").tmp.XXXXXX")

	# 1) 已有可用文件就跳过
	if ruleset_ok "$out"; then
		if [ -n "$(find "$out" -mtime +30 2>/dev/null)" ]; then
			log_warn "规则集已过期（>30天），强制更新：$out"
		else
			log_info "已存在且可用（未过期），跳过下载：$out"
			chmod 0644 "$out" 2>/dev/null || true
			chown sing-box:sing-box "$out" 2>/dev/null || chown root:sing-box "$out" 2>/dev/null || true
			return 0
		fi
	fi

	# 2) 下载
	log_info "下载：$url"
	if curl -fsSL --fail \
		--retry 10 --retry-delay 2 --retry-all-errors \
		--connect-timeout 10 --max-time 60 \
		-o "$tmp" "$url"; then
		if [ -s "$tmp" ]; then
			local fsize
			fsize=$(stat -c '%s' "$tmp" 2>/dev/null || echo 0)

			if [ "$fsize" -ge 1024 ]; then
				mv "$tmp" "$out"
				chmod 0644 "$out" 2>/dev/null || true
				chown sing-box:sing-box "$out" 2>/dev/null || chown root:sing-box "$out" 2>/dev/null || true
				log_info "下载成功：$out (${fsize} bytes)"
				return 0
			else
				log_warn "文件校验失败 (过小: ${fsize} bytes)：$url"
				rm -f "$tmp"
			fi
		fi
	fi

	rm -f "$tmp"

	# 3) 下载失败但本地后来已经有了（并发场景），也放行
	if ruleset_ok "$out"; then
		log_warn "下载失败，但本地已有可用文件，继续：$out"
		return 0
	fi

	log_error "下载失败且本地无可用文件：$out"
	return 1
}
