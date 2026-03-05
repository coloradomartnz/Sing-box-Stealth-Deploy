#!/usr/bin/env bash
#
# Step 05: Setup MetacubexD Dashboard UI
#

deploy_step_05() {
	log_step "========== [Step ${CURRENT_STEP_INDEX:-?} / ${TOTAL_STEPS_COUNT:-?}] Install MetacubexD dashboard =========="

	if [ "${ENABLE_DASHBOARD:-0}" -ne 1 ]; then
		log_info "Dashboard disabled by user, skipping"
		return 0
	fi

	local ui_dir="/usr/local/etc/sing-box/ui"
	
	# Check if dashboard is already installed
	local ui_installed=0
	if [ -d "$ui_dir" ] && [ "$(find "$ui_dir" -maxdepth 1 -type f 2>/dev/null | wc -l)" -gt 0 ]; then
		ui_installed=1
	fi
	
	if [ "$ui_installed" -eq 1 ] && [ "${UPGRADE_MODE:-0}" -eq 1 ]; then
		# Dashboard exists; in upgrade mode, skip unless user explicitly requests
		if [ "${AUTO_YES:-0}" -eq 1 ]; then
			log_info "Dashboard exists, skipping download in upgrade mode"
			return 0
		fi
		read -r -p "Dashboard exists, re-download latest assets? [y/N]: " REINSTALL_UI
		if [[ ! "$REINSTALL_UI" =~ ^[Yy]$ ]]; then
			return 0
		fi
	elif [ "$ui_installed" -eq 0 ]; then
		# Dashboard missing or empty, always install
		log_info "Dashboard not installed, downloading..."
	fi

	log_info "Downloading MetacubexD assets from GitHub..."
	local tmp_file="/tmp/metacubexd.tgz"
	
	if ! curl -fsSL --connect-timeout 10 -m 120 -o "$tmp_file" "$METACUBEXD_URL"; then
		log_warn "MetacubexD download failed, skipping dashboard (core proxy unaffected)"
		return 0
	fi

	log_info "Extracting to $ui_dir..."
	_run mkdir -p "$ui_dir"
	if ! _run tar -zxf "$tmp_file" -C "$ui_dir"; then
		log_warn "Dashboard extraction failed, skipping installation"
		rm -f "$tmp_file"
		return 0
	fi

	_run rm -f "$tmp_file"
	log_info "MetacubexD dashboard installed OK"
}
