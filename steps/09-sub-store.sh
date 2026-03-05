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

	# Download Sub-Store bundle
	log_info "Downloading Sub-Store release bundle..."
	_run curl -fsSL "https://github.com/sub-store-org/Sub-Store/releases/latest/download/sub-store.bundle.js" \
		-o "${SUBSTORE_DIR:-/opt/sub-store}/sub-store.bundle.js"
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
EOF
	fi
	chown substore:substore "$env_file"
	chmod 600 "$env_file"

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
