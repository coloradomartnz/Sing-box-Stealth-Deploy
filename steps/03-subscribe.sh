#!/usr/bin/env bash
#
# Step 03: Setup sing-box-subscribe
#

deploy_step_03() {
	log_step "========== [Step ${CURRENT_STEP_INDEX:-?} / ${TOTAL_STEPS_COUNT:-?}] Configure sing-box-subscribe =========="

	if [ "${UPGRADE_MODE:-0}" -eq 1 ]; then
		log_info "[Upgrade mode] Subscription converter exists, checking for updates..."
		if [ -d "$SB_SUB" ]; then
			# Run in subshell to isolate directory changes
			# Warn on update failure instead of silently swallowing errors
			(cd "$SB_SUB" && git pull 2>/dev/null) || log_warn "sing-box-subscribe update failed, continuing with existing version"
		fi
	else
		log_info "Cloning sing-box-subscribe from GitHub..."
		if [ -d "$SB_SUB" ]; then
			_run rm -rf "$SB_SUB"
		fi
		_run git clone https://github.com/Toperlock/sing-box-subscribe "$SB_SUB"
		# Restrict directory permissions to protect providers.json tokens
		_run chmod 750 "$SB_SUB"
		
		log_info "Configuring Python virtual environment..."
		_run python3 -m venv "$SB_SUB/venv"
		_run "$SB_SUB/venv/bin/pip" install --upgrade pip
		_run "$SB_SUB/venv/bin/pip" install -r "$SB_SUB/requirements.txt"
	fi

	# Save commit hash for documentation
	if [ -d "$SB_SUB" ]; then
		# shellcheck disable=SC2034
		SUBSCRIBE_COMMIT=$(cd "$SB_SUB" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
		
		# Patch misleading error messages in third-party tool
		if [ -f "$SB_SUB/main.py" ]; then
			_run sed -i 's/may cause sing-box to fail. Check if config template is correct/may cause some features to be unavailable. Check subscription URLs and template/g' "$SB_SUB/main.py"
		fi
	fi

	echo ""
}
