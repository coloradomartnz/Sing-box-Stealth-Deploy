#!/usr/bin/env bash

# ============================================================================
# Step 09: 部署 Sub-Store (仅在 --substore 模式下)
# ============================================================================

deploy_step_09() {
	if [ "${SUBSTORE_MODE:-0}" -ne 1 ]; then
		log_info "跳过 Sub-Store 部署 (未启用 --substore)"
		return 0
	fi

	log_info "========================================================"
	log_info "开始部署 Sub-Store 节点管理服务..."
	log_info "========================================================"

	# 1. 安装 Node.js 20.x LTS
	# 审计修复(E-07): 修正版本检测正则，原\\|在grep基本正则中不生效
	if ! command -v node >/dev/null 2>&1 || ! node -v | grep -qE 'v(20|22|23)\.'; then
		log_info "正在安装 Node.js LTS..."
		# 审计修复(C-09): 消除 curl|bash 反模式，分步下载和执行
		local _nodesource_script
		_nodesource_script=$(mktemp /tmp/nodesource_setup_XXXXXX.sh)
		if ! _run curl -fsSL --connect-timeout 10 --max-time 60 \
			-o "$_nodesource_script" "https://deb.nodesource.com/setup_20.x"; then
			log_error "Node.js 安装脚本下载失败"
			rm -f "$_nodesource_script"
			return 1
		fi
		_run bash "$_nodesource_script"
		rm -f "$_nodesource_script"
		_run apt-get install -y nodejs
	else
		log_info "Node.js 已安装: $(node -v)"
	fi

	# 2. 准备系统用户与目录
	log_info "配置运行用户与凭据目录..."
	if ! id -u substore >/dev/null 2>&1; then
		useradd -r -s /usr/sbin/nologin -M substore || true
	fi

	_run mkdir -p "${SUBSTORE_DIR:-/opt/sub-store}"
	_run mkdir -p "${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}"
	chown -R substore:substore "${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}"
	chmod 700 "${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}"

	# 3. 下载 Sub-Store Bundle
	log_info "下载 Sub-Store Release Bundle..."
	_run curl -fsSL "https://github.com/sub-store-org/Sub-Store/releases/latest/download/sub-store.bundle.js" \
		-o "${SUBSTORE_DIR:-/opt/sub-store}/sub-store.bundle.js"
	chown -R substore:substore "${SUBSTORE_DIR:-/opt/sub-store}"

	# 4. 生成鉴权令牌与环境文件
	local env_file="${SUBSTORE_DIR:-/opt/sub-store}/substore.env"
	if [ ! -f "$env_file" ]; then
		log_info "生成 Sub-Store 高强度鉴权令牌..."
		local rand_token
		rand_token=$(openssl rand -hex 16)
		cat >"$env_file" <<EOF
SUB_STORE_FRONTEND_BACKEND_PATH=/${rand_token}
SUB_STORE_DATA_BASE_PATH=${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}
EOF
	fi
	chown substore:substore "$env_file"
	chmod 600 "$env_file"

	# 4.5 安装配置更新脚本
	if [ -f "$(dirname "$0")/scripts/substore-update.sh" ]; then
		install -m 755 "$(dirname "$0")/scripts/substore-update.sh" /usr/local/bin/substore-update.sh
	fi

	# 5. 配置 Systemd Service
	log_info "注册 Sub-Store Systemd 服务..."
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
# 限制权限
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=${SUBSTORE_DATA_DIR:-/usr/local/etc/sub-store}

[Install]
WantedBy=multi-user.target
EOF

	_run systemctl daemon-reload
	_run systemctl enable --now sub-store
	
	log_info "Sub-Store 部署完成！"
}
