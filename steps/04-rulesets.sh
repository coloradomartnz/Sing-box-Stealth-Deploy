#!/usr/bin/env bash
#
# Step 04: Rulesets Pre-download
#

deploy_step_04() {
	log_step "========== [Step ${CURRENT_STEP_INDEX:-?} / ${TOTAL_STEPS_COUNT:-?}] Download and deploy rulesets =========="

	local ruleset_dir="/var/lib/sing-box/ruleset"
	_run mkdir -p "$ruleset_dir"
	_run chmod 755 "$ruleset_dir"

	# C-4 Fix: separate logs for background downloads to avoid mixed output
	local pids=() log_files=() optional_flags=()
	local dl_log_dir
	dl_log_dir=$(mktemp -d /tmp/singbox-dl.XXXXXX)
	register_cleanup_dir "$dl_log_dir"

	# ---- Required rulesets (Abort if download fails) ----
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

	# ---- Optional rulesets (WARN only if download fails, do not abort) ----
	# lyc8503 repository missing this file; prefer MetaCubeX, fallback SagerNet
	_download_optional_ruleset \
		"$RULESET_GEOSITE_OPENAI_URL" \
		"${RULESET_GEOSITE_OPENAI_URL_FALLBACK:-}" \
		"$ruleset_dir/geosite-openai.srs" \
		> "$dl_log_dir/geosite-openai.log" 2>&1 &
	pids+=($!); log_files+=("$dl_log_dir/geosite-openai.log"); optional_flags+=(1)
	register_cleanup_pid "${pids[-1]}"

	# ---- Claude (Anthropic) ----
	_download_optional_ruleset \
		"$RULESET_GEOSITE_ANTHROPIC_URL" \
		"" \
		"$ruleset_dir/geosite-anthropic.srs" \
		> "$dl_log_dir/geosite-claude.log" 2>&1 &
	pids+=($!); log_files+=("$dl_log_dir/geosite-claude.log"); optional_flags+=(1)
	register_cleanup_pid "${pids[-1]}"

	# ---- Gemini (Google) ----
	_download_optional_ruleset \
		"$RULESET_GEOSITE_GEMINI_URL" \
		"" \
		"$ruleset_dir/geosite-gemini.srs" \
		> "$dl_log_dir/geosite-gemini.log" 2>&1 &
	pids+=($!); log_files+=("$dl_log_dir/geosite-gemini.log"); optional_flags+=(1)
	register_cleanup_pid "${pids[-1]}"

	# ---- Wait for all downloads and summarize results ----
	local download_fail=0
	for i in "${!pids[@]}"; do
		if ! wait "${pids[$i]}"; then
			if [ "${optional_flags[$i]}" -eq 1 ]; then
				# Optional rulesets: downgrade to warning
				log_warn "Optional ruleset download failed (non-critical), logs below:"
				cat "${log_files[$i]}" >&2
			else
				download_fail=1
				log_error "Ruleset download failed, logs below:"
				cat "${log_files[$i]}" >&2
			fi
		else
			# Output log even on success (contains INFO messages)
			cat "${log_files[$i]}"
		fi
	done

	rm -rf "$dl_log_dir"

	if [ "$download_fail" -eq 1 ]; then
		log_error "One or more required rulesets failed to download. See logs above"
		exit "${E_NETWORK:-10}"
	fi

	log_info "Rulesets ready OK"
	echo ""
}

# ---------------------------------------------------------------------------
# _download_optional_ruleset <primary_url> <fallback_url> <dest_path>
# Try primary URL first, then fallback; non-zero exit lets caller downgrade
# ---------------------------------------------------------------------------
_download_optional_ruleset() {
	local primary_url="$1"
	local fallback_url="$2"
	local dest="$3"

	if download_ruleset "$primary_url" "$dest"; then
		return 0
	fi

	if [ -n "$fallback_url" ]; then
		log_warn "Primary source failed, trying fallback: $fallback_url"
		if download_ruleset "$fallback_url" "$dest"; then
			return 0
		fi
	fi

	return 1
}
