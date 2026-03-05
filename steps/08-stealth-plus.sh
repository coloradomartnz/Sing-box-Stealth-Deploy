#!/usr/bin/env bash
#
# Step 08: Stealth+ Extension (Residential Proxy & Watchdog)
#

deploy_step_08() {
	log_step "========== [Step ${CURRENT_STEP_INDEX:-?} / ${TOTAL_STEPS_COUNT:-?}] Stealth+ residential IP enhancement (optional) =========="

	# Check if residential proxy config is needed
	local enable_res="n"
	if [ "${UPGRADE_MODE:-0}" -eq 1 ]; then
		# In upgrade mode, check for existing config
		if [ -f "$DEPLOYMENT_CONFIG" ]; then
			_safe_source_deployment_config "$DEPLOYMENT_CONFIG"
			if [ -n "${RES_HOST:-}" ]; then
				enable_res="y"
				log_info "Existing residential proxy config detected, maintaining watchdog"
			fi
		fi
	fi

	if [ "$UPGRADE_MODE" -eq 0 ] && [ "$AUTO_YES" -eq 0 ]; then
		read -r -p "Integrate residential IP proxy chain with auto-rollback watchdog? [y/N]: " enable_res_input
		enable_res=${enable_res_input:-n}
	fi

	if [[ ! "$enable_res" =~ ^[Yy]$ ]]; then
		log_info "Skipping Stealth+ enhancement"
		return 0
	fi

	# Input already collected by singbox-deploy.sh, validate here
	if [ -z "${RES_HOST:-}" ]; then
		log_info "No residential proxy host configured, skipping watchdog"
		return 0
	fi

	# Deploy watchdog monitoring script
	log_info "Deploying residential proxy watchdog..."
	local watchdog_tpl watchdog_dest
	watchdog_tpl="$(dirname "$(readlink -f "$0")")/templates/residential-watchdog.sh.tpl"
	watchdog_dest="/usr/local/bin/singbox-residential-watchdog.sh"

	if [ -f "$watchdog_tpl" ]; then
		# Escape user input to prevent sed delimiter injection
		local safe_res_host safe_res_port safe_dash_port
		safe_res_host=$(_sed_escape_replacement "$RES_HOST")
		safe_res_port=$(_sed_escape_replacement "$RES_PORT")
		safe_dash_port=$(_sed_escape_replacement "${DASHBOARD_PORT:-9090}")
		sed -e "s|\${RES_HOST}|$safe_res_host|g" \
		    -e "s|\${RES_PORT}|$safe_res_port|g" \
		    -e "s|\${DASHBOARD_PORT}|$safe_dash_port|g" \
		    "$watchdog_tpl" > "$watchdog_dest"
		chmod +x "$watchdog_dest"
		log_info "  OK watchdog script ready: $watchdog_dest"
	else
		log_error "Watchdog template not found: $watchdog_tpl"
		return 1
	fi

	# Deploy systemd service
	log_info "Configuring watchdog service..."
	local service_tpl service_dest
	service_tpl="$(dirname "$(readlink -f "$0")")/templates/watchdog.service.tpl"
	service_dest="/etc/systemd/system/singbox-residential-watchdog.service"

	if [ -f "$service_tpl" ]; then
		cp "$service_tpl" "$service_dest"
		systemctl daemon-reload
		systemctl enable singbox-residential-watchdog.service
		systemctl restart singbox-residential-watchdog.service
		log_info "  OK watchdog service started"
	else
		log_error "Service template not found: $service_tpl"
		return 1
	fi

	log_info "Stealth+ deployment complete"
	log_info "AI/streaming traffic routes via residential IP; auto-fallback to proxy nodes if unavailable"
	echo ""
}
