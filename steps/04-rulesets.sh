#!/usr/bin/env bash
#
# Step 04: Rulesets Pre-download
#

deploy_step_04() {
	log_step "========== [4/7] 预下载规则集（本地化） =========="

	local ruleset_dir="/var/lib/sing-box/ruleset"
	_run mkdir -p "$ruleset_dir"
	_run chmod 755 "$ruleset_dir"

	# C-4 修复: 每个后台下载使用独立日志，避免输出交织
	local pids=() log_files=()
	local dl_log_dir
	dl_log_dir=$(mktemp -d /tmp/singbox-dl.XXXXXX)
	register_cleanup_hook "rm -rf '$dl_log_dir'"

	download_ruleset "$RULESET_GEOSITE_CN_URL" "$ruleset_dir/geosite-cn.srs" \
		> "$dl_log_dir/geosite-cn.log" 2>&1 &
	pids+=($!); log_files+=("$dl_log_dir/geosite-cn.log")

	download_ruleset "$RULESET_GEOSITE_GEOLOC_NONCN_URL" "$ruleset_dir/geosite-geolocation-!cn.srs" \
		> "$dl_log_dir/geosite-noncn.log" 2>&1 &
	pids+=($!); log_files+=("$dl_log_dir/geosite-noncn.log")

	download_ruleset "$RULESET_GEOIP_CN_URL" "$ruleset_dir/geoip-cn.srs" \
		> "$dl_log_dir/geoip-cn.log" 2>&1 &
	pids+=($!); log_files+=("$dl_log_dir/geoip-cn.log")

	local download_fail=0
	for i in "${!pids[@]}"; do
		if ! wait "${pids[$i]}"; then
			download_fail=1
			log_error "规则集下载失败，日志如下:"
			cat "${log_files[$i]}" >&2
		else
			# 成功也输出日志（包含 INFO 信息）
			cat "${log_files[$i]}"
		fi
	done

	rm -rf "$dl_log_dir"

	if [ "$download_fail" -eq 1 ]; then
		log_error "一个或多个规则集下载失败"
		exit 1
	fi

	log_info "规则集准备完成 ✓"
	echo ""
}
