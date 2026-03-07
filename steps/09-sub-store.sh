#!/usr/bin/env bash

# ============================================================================
# Step 09: Deploy Sub-Store (only in --substore mode)
# ============================================================================

deploy_step_09() {
	if [ "${SUBSTORE_MODE:-0}" -ne 1 ]; then
		log_info "Skipping Sub-Store deployment (--substore not set)"
		return 0
	fi

	log_info "========================================================"
	log_info "Deploying Sub-Store subscription manager..."
	log_info "========================================================"

	# Install Node.js 20.x LTS
	# Fix version detection regex for Node.js
	if ! command -v node >/dev/null 2>&1 || ! node -v | grep -qE 'v(20|22|23)\.'; then
		log_info "Installing Node.js LTS..."
		# Avoid curl|bash anti-pattern: download then execute
		local _nodesource_script
		_nodesource_script=$(mktemp /tmp/nodesource_setup_XXXXXX.sh)
		if ! _run curl -fsSL --connect-timeout 10 --max-time 60 \
			-o "$_nodesource_script" "https://deb.nodesource.com/setup_20.x"; then
			log_error "Node.js setup script download failed"
			rm -f "$_nodesource_script"
			return 1
		fi
		_run bash "$_nodesource_script"
		rm -f "$_nodesource_script"
		_run apt-get install -y nodejs
	else
		log_info "Node.js installed: $(node -v)"
	fi

	# Create system user and directories
	log_info "Configuring runtime user and credentials..."
	if ! id -u substore >/dev/null 2>&1; then
		useradd -r -s /usr/sbin/nologin -M substore || true
	fi

	_run mkdir -p "${SUBSTORE_DIR:-/opt/sub-store}"
	_run mkdir -p "${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}"
	chown -R substore:substore "${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}"
	chmod 700 "${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}"

	# Download Sub-Store release bundle
	log_info "Downloading Sub-Store backend release bundle..."
	_run curl -fsSL "https://github.com/sub-store-org/Sub-Store/releases/latest/download/sub-store.bundle.js" \
		-o "${SUBSTORE_DIR:-/opt/sub-store}/sub-store.bundle.js"

	# Download and Deploy Sub-Store Frontend (Fix 404 Dashboard issue)
	log_info "Deploying Sub-Store Frontend Dashboard..."
	local _fe_dir="${SUBSTORE_DIR:-/opt/sub-store}/frontend"
	local _fe_zip="/tmp/substore-frontend.zip"
	_run mkdir -p "$_fe_dir"
	if ! _run curl -fsSL --connect-timeout 10 --max-time 120 \
		-o "$_fe_zip" "https://github.com/sub-store-org/Sub-Store-Front-End/releases/latest/download/dist.zip"; then
		log_error "Failed to download Sub-Store Frontend assets"
		return 1
	fi
	_run unzip -o "$_fe_zip" -d "$_fe_dir"
	_run rm -f "$_fe_zip"

	chown -R substore:substore "${SUBSTORE_DIR:-/opt/sub-store}"

	# Generate auth token and env file
	local env_file="${SUBSTORE_DIR:-/opt/sub-store}/substore.env"
	if [ ! -f "$env_file" ]; then
		log_info "Generating high-strength Sub-Store auth token..."
		local rand_token
		rand_token=$(openssl rand -hex 16)
		cat >"$env_file" <<EOF
SUB_STORE_FRONTEND_BACKEND_PATH=/${rand_token}
SUB_STORE_DATA_BASE_PATH=${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}
SUB_STORE_BACKEND_API_PORT=${SUBSTORE_PORT:-2999}
SUB_STORE_BACKEND_MERGE=true
SUB_STORE_FRONTEND_PATH=$_fe_dir
EOF
		# Persist token to global config for management scripts
		sed -i '/^SUBSTORE_TOKEN=/d' "$DEPLOYMENT_CONFIG" 2>/dev/null || true
		echo "SUBSTORE_TOKEN=\"$rand_token\"" >> "$DEPLOYMENT_CONFIG"
	else
		# Ensure necessary variables exist in current env
		if ! grep -q "SUB_STORE_BACKEND_MERGE" "$env_file"; then
			echo "SUB_STORE_BACKEND_MERGE=true" >> "$env_file"
			echo "SUB_STORE_FRONTEND_PATH=$_fe_dir" >> "$env_file"
		fi
		# Back-fill token if missing from deployment config
		if ! grep -q "^SUBSTORE_TOKEN=" "$DEPLOYMENT_CONFIG"; then
			local _existing_token
			_existing_token=$(grep "SUB_STORE_FRONTEND_BACKEND_PATH" "$env_file" | cut -d'/' -f2)
			[ -n "$_existing_token" ] && echo "SUBSTORE_TOKEN=\"$_existing_token\"" >> "$DEPLOYMENT_CONFIG"
		fi
	fi
	chown substore:substore "$env_file"
	chmod 600 "$env_file"

	# Generate sub-store-2.json to pre-load subscriptions (Zero-config)
	local storage_file="${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}/sub-store-2.json"
	if [ ! -f "$storage_file" ]; then
		log_info "Pre-configuring Sub-Store subscriptions and collections..."
		
		# Build subs array
		local subs_json="[]"
		local sub_names=()
		for i in "${!AIRPORT_URLS[@]}"; do
			local name="${AIRPORT_TAGS[$i]:-sub_$((i+1))}"
			local url="${AIRPORT_URLS[$i]}"
			sub_names+=("\"$name\"")
			subs_json=$(jq -n --arg name "$name" --arg url "$url" --argjson existing "$subs_json" \
				'$existing + [{"name": $name, "url": $url, "source": "remote"}]')
		done
		
		# Build collections array
		local coll_name="${SUBSTORE_COLLECTION_NAME:-MySubs}"
		local subs_ref_json
		subs_ref_json=$(printf ",%s" "${sub_names[@]}")
		subs_ref_json="[${subs_ref_json:1}]"
		
		local coll_json
		coll_json=$(jq -n --arg name "$coll_name" --argjson subs "$subs_ref_json" \
			'[{"name": $name, "subscriptions": $subs}]')
			
		# Assemble final JSON
		jq -n \
			--argjson subs "$subs_json" \
			--argjson coll "$coll_json" \
			'{
				"schemaVersion": "2.0",
				"subs": $subs,
				"collections": $coll,
				"artifacts": [],
				"files": [],
				"rules": [],
				"tokens": [],
				"settings": {}
			}' > "$storage_file"
			
		chown substore:substore "$storage_file"
		chmod 600 "$storage_file"
	fi

	# Install config update script
	if [ -f "$(dirname "$0")/scripts/substore-update.sh" ]; then
		install -m 755 "$(dirname "$0")/scripts/substore-update.sh" /usr/local/bin/substore-update.sh
	fi

	# Configure systemd service
	log_info "Registering Sub-Store systemd service..."
	cat >/etc/systemd/system/sub-store.service <<EOF
[Unit]
Description=Sub-Store Subscription Manager
After=network.target

[Service]
Type=simple
User=substore
Group=substore
WorkingDirectory=${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}
EnvironmentFile=${env_file}
ExecStart=/usr/bin/node ${SUBSTORE_DIR:-/opt/sub-store}/sub-store.bundle.js
Restart=on-failure
RestartSec=5
# Restrict permissions
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}

[Install]
WantedBy=multi-user.target
EOF

	_run systemctl daemon-reload
	_run systemctl enable --now sub-store
	
	log_info "Sub-Store deployment complete"
}
