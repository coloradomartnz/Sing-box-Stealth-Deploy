#!/usr/bin/env bash
#
# Step 02: Directories and Scripts
#

deploy_step_02() {
	log_step "========== [Step ${CURRENT_STEP_INDEX:-?} / ${TOTAL_STEPS_COUNT:-?}] Create directories and deploy scripts =========="

	# Create directory structure
	_run mkdir -p /usr/local/etc/sing-box/backups/{daily,weekly,monthly}
	_run mkdir -p /usr/local/etc/sing-box/docs
	_run mkdir -p /var/lib/sing-box/ruleset
	_run chown -R sing-box:sing-box /var/lib/sing-box 2>/dev/null || true
	_run chmod 750 /var/lib/sing-box
	# Ruleset dir needs read access by both root and sing-box user
	_run chmod 755 /var/lib/sing-box/ruleset
	# Clean up leftover .tmp files from previous deployments
	find /var/lib/sing-box/ruleset -name "*.tmp.*" -delete 2>/dev/null || true

	# Deploy management scripts from project root
	log_info "Deploying management scripts..."
	local project_root
	project_root="$(dirname "$(readlink -f "$0")")"
	
	local target_scripts=(
		"scripts/singbox_dns_failover.sh:/usr/local/bin/singbox_dns_failover.sh"
		"scripts/singbox_ruleset_weekly_update.sh.tpl:/usr/local/bin/singbox_ruleset_weekly_update.sh"
		"scripts/add_docker_route.sh:/usr/local/bin/add_docker_route.sh"
		"scripts/singbox_build_region_groups.py:/usr/local/bin/singbox_build_region_groups.py"
		"scripts/update_and_restart.sh:/usr/local/etc/sing-box/update_and_restart.sh"
		"scripts/backup.sh:/usr/local/etc/sing-box/backup.sh"
		"templates/sing-box-config-gen.sh:/usr/local/libexec/sing-box-config-gen.sh"
		"lib/globals.sh:/usr/local/etc/sing-box/lib/globals.sh"
		"lib/utils.sh:/usr/local/etc/sing-box/lib/utils.sh"
		"lib/checks.sh:/usr/local/etc/sing-box/lib/checks.sh"
		"lib/lock.sh:/usr/local/etc/sing-box/lib/lock.sh"
		"lib/ruleset.sh:/usr/local/etc/sing-box/lib/ruleset.sh"
		"lib/service.sh:/usr/local/etc/sing-box/lib/service.sh"
	)

	# Create secure credentials directory
	local cred_dir="/usr/local/etc/sing-box/.credentials"
	_run mkdir -p "$cred_dir"
	_run chown root:root "$cred_dir"
	_run chmod 700 "$cred_dir"

	for pair in "${target_scripts[@]}"; do
		local src="${pair%%:*}"
		local dst="${pair##*:}"
		if [ -f "$project_root/$src" ]; then
			# Ensure target directory exists
			_run mkdir -p "$(dirname "$dst")"
			# Perform variable substitution for template files
			if [[ "$src" == *.tpl ]]; then
				sed -e "s|%%RULESET_GEOSITE_CN_URL%%|${RULESET_GEOSITE_CN_URL}|g" \
				    -e "s|%%RULESET_GEOSITE_GEOLOC_NONCN_URL%%|${RULESET_GEOSITE_GEOLOC_NONCN_URL}|g" \
				    -e "s|%%RULESET_GEOIP_CN_URL%%|${RULESET_GEOIP_CN_URL}|g" \
				    "$project_root/$src" > "$dst"
			else
				cp "$project_root/$src" "$dst"
			fi
			chmod +x "$dst"
			log_info "  OK deployed: $dst"
		else
			log_warn "  Source file missing: $src (路径: $project_root/$src)"
		fi
	done

	# 2.2.5 Deploy Go Watchdog sidecar
	_deploy_watchdog_binary "$PROJECT_DIR"

	# 2.3 初始化自定义分流规则列表
	log_info "Initializing custom routing lists..."
	_run touch /usr/local/etc/sing-box/direct_list.txt
	_run touch /usr/local/etc/sing-box/proxy_list.txt
	_run chmod 644 /usr/local/etc/sing-box/direct_list.txt /usr/local/etc/sing-box/proxy_list.txt

	echo ""
}

# ---------------------------------------------------------------------------
# _deploy_watchdog_binary <project_root>
# Prefer pre-built binary from GitHub Release, fall back to local Go build
# ---------------------------------------------------------------------------
_deploy_watchdog_binary() {
	local project_root="$1"
	local target="/usr/local/bin/singbox-watchdog"
	local watchdog_src="$project_root/cmd/watchdog"

	log_info "Deploying singbox-watchdog (Go sidecar)..."

	# Download pre-built binary from GitHub Release
	if download_release_asset "singbox-watchdog" "$target"; then
		chmod +x "$target"
		log_info "  OK deployed pre-built watchdog binary"
		return 0
	fi
	log_warn "  Pre-built binary download failed, trying local build..."

	# Fall back to local build (requires Go)
	if command -v go &>/dev/null && [ -d "$watchdog_src" ]; then
		log_info "  Local Go environment found, building..."
		# Prevent Go from downloading new toolchains in sudo context
		if _run bash -c "export GOTOOLCHAIN=local && cd $watchdog_src && go build -ldflags \"-s -w\" -o $target ."; then
			chmod +x "$target"
			log_info "  OK deployed watchdog via local build"
			return 0
		else
			log_warn "  Local build failed."
		fi
	else
		[ ! -d "$watchdog_src" ] && log_warn "  cmd/watchdog source not found."
		! command -v go &>/dev/null && log_warn "  Go toolchain not detected."
	fi

	# Non-critical: watchdog is optional
	log_warn "  Cannot obtain watchdog binary. Running without watchdog."
	return 0
}

