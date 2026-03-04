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
	local pids=() log_files=() optional_flags=()
	local dl_log_dir
	dl_log_dir=$(mktemp -d /tmp/singbox-dl.XXXXXX)
	register_cleanup_dir "$dl_log_dir"

	# ---- 必需规则集（下载失败 → 中止部署）----
	download_ruleset "$RULESET_GEOSITE_CN_URL" "$ruleset_dir/geosite-cn.srs" \
		> "$dl_log_dir/geosite-cn.log" 2>&1 &
	pids+=($!); log_files+=("$dl_log_dir/geosite-cn.log"); optional_flags+=(0)
	register_cleanup_pid "${pids[-1]}"

	download_ruleset "$RULESET_GEOSITE_GEOLOC_NONCN_URL" "$ruleset_dir/geosite-geolocation-!cn.srs" \
		> "$dl_log_dir/geosite-noncn.log" 2>&1 &
	pids+=($!); log_files+=("$dl_log_dir/geosite-noncn.log"); optional_flags+=(0)
	register_cleanup_pid "${pids[-1]}"

	download_ruleset "$RULESET_GEOIP_CN_URL" "$ruleset_dir/geoip-cn.srs" \
		> "$dl_log_dir/geoip-cn.log" 2>&1 &
	pids+=($!); log_files+=("$dl_log_dir/geoip-cn.log"); optional_flags+=(0)
	register_cleanup_pid "${pids[-1]}"

	# ---- 可选规则集（下载失败 → 仅 WARN，不中止）----
	# lyc8503 仓库不含此文件；首选 MetaCubeX，备选 SagerNet
	_download_optional_ruleset \
		"$RULESET_GEOSITE_OPENAI_URL" \
		"${RULESET_GEOSITE_OPENAI_URL_FALLBACK:-}" \
		"$ruleset_dir/geosite-openai.srs" \
		> "$dl_log_dir/geosite-openai.log" 2>&1 &
	pids+=($!); log_files+=("$dl_log_dir/geosite-openai.log"); optional_flags+=(1)
	register_cleanup_pid "${pids[-1]}"

	# ---- 等待所有下载并汇总结果 ----
	local download_fail=0
	for i in "${!pids[@]}"; do
		if ! wait "${pids[$i]}"; then
			if [ "${optional_flags[$i]}" -eq 1 ]; then
				# 可选规则集：降级为警告
				log_warn "可选规则集下载失败（不影响主要功能），日志如下:"
				cat "${log_files[$i]}" >&2
			else
				download_fail=1
				log_error "规则集下载失败，日志如下:"
				cat "${log_files[$i]}" >&2
			fi
		else
			# 成功也输出日志（包含 INFO 信息）
			cat "${log_files[$i]}"
		fi
	done

	rm -rf "$dl_log_dir"

	if [ "$download_fail" -eq 1 ]; then
		log_error "一个或多个必需规则集下载失败。详细日志已输出到上方"
		exit "${E_NETWORK:-10}"
	fi

	log_info "规则集准备完成 ✓"
	echo ""
}

# ---------------------------------------------------------------------------
# _download_optional_ruleset <primary_url> <fallback_url> <dest_path>
# 先尝试主 URL，失败后尝试备用 URL；两者均失败时以非零状态退出（由调用方降级处理）
# ---------------------------------------------------------------------------
_download_optional_ruleset() {
	local primary_url="$1"
	local fallback_url="$2"
	local dest="$3"

	if download_ruleset "$primary_url" "$dest"; then
		return 0
	fi

	if [ -n "$fallback_url" ]; then
		log_warn "主源下载失败，尝试备用源: $fallback_url"
		if download_ruleset "$fallback_url" "$dest"; then
			return 0
		fi
	fi

	return 1
}
