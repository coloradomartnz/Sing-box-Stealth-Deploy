#!/usr/bin/env bash
#
# Step 06: Templates and Configuration Generation
#

deploy_step_06() {
	log_step "========== [6/7] 生成配置模板与初次订阅 =========="

	local config_dir="/usr/local/etc/sing-box"
	local template_src_dir
	template_src_dir="$(dirname "$(readlink -f "$0")")/templates"

	# 4.1 部署底座模板 (config_template.json.tpl)
	log_info "处理配置模板..."
	
	# 设置模板变量
	local tun_address dns_strategy bootstrap_dns
	if [ "${HAS_IPV6:-0}" -eq 1 ]; then
		tun_address='"172.18.0.1/30", "fd00::1/126"'
		dns_strategy='"strategy": "prefer_ipv4",'
	else
		tun_address='"172.18.0.1/30"'
		dns_strategy='"strategy": "ipv4_only",'
	fi

	# 自动选择 Bootstrap DNS
	bootstrap_dns="223.5.5.5"
	if ! timeout 2 ping -c1 -W1 223.5.5.5 >/dev/null 2>&1; then
		bootstrap_dns="8.8.8.8"
	fi

	# 生成 NextDNS 服务器块（根据 ENABLE_NEXTDNS 开关）
	local nextdns_server_block="null"
	if [ "${ENABLE_NEXTDNS:-0}" -eq 1 ]; then
		nextdns_server_block=',
      {
        "tag": "remote_nextdns",
        "type": "https",
        "server": "dns.nextdns.io",
        "path": "/'"${NEXTDNS_ID:-}"'",
        "detour": "🚀 节点选择",
        "domain_resolver": "bootstrap"
      }'
	fi

	# 处理自定义分流规则 [O-1: 采用 JQ 原生生成]
	log_info "处理自定义分流规则..."
	
	_gen_custom_rules_jq() {
		local list_file="$1"
		local outbound="$2" # "direct" or "proxy" (or "local" for DNS)
		local is_dns="$3"   # 1 for DNS, 0 for Route
		
		if [ ! -f "$list_file" ]; then
			echo "{}"
			return
		fi
		
		local domains=()
		while IFS= read -r line || [ -n "$line" ]; do
			line=$(echo "$line" | sed 's/#.*//' | xargs)
			[ -z "$line" ] && continue
			domains+=("$line")
		done < "$list_file"
		
		if [ ${#domains[@]} -gt 0 ]; then
			if [ "$is_dns" -eq 1 ]; then
				jq -n --arg out "$outbound" '{domain: $ARGS.positional, server: $out}' --args "${domains[@]}"
			else
				jq -n --arg out "$outbound" '{domain: $ARGS.positional, outbound: $out}' --args "${domains[@]}"
			fi
		else
			echo "{}"
		fi
	}

	local cr_direct cr_proxy cd_direct cd_proxy
	cr_direct=$(_gen_custom_rules_jq "/usr/local/etc/sing-box/direct_list.txt" "direct" 0)
	cr_proxy=$(_gen_custom_rules_jq "/usr/local/etc/sing-box/proxy_list.txt" "🚀 节点选择" 0)
	cd_direct=$(_gen_custom_rules_jq "/usr/local/etc/sing-box/direct_list.txt" "local" 1)
	cd_proxy=$(_gen_custom_rules_jq "/usr/local/etc/sing-box/proxy_list.txt" "${REMOTE_MAIN_TAG:-remote_cf}" 1)
	
	local cr_arr cd_arr nd_json
	cr_arr=$(jq -s 'map(select(length > 0))' <<< "$cr_direct $cr_proxy")
	cd_arr=$(jq -s 'map(select(length > 0))' <<< "$cd_direct $cd_proxy")
	nd_json=${nextdns_server_block:-null}

	# 处理 config_template.json.tpl
	if [ -f "$template_src_dir/config_template.json.tpl" ]; then
		local tmp_tpl
		tmp_tpl=$(mktemp /tmp/singbox-tpl.XXXXXX)
		
		# 第一阶段: sed 处理简单标量变量 (变成 100% 格式合法的基础 JSON)
		sed -e "s|\${TUN_ADDRESS}|${tun_address}|g" \
		    -e "s|\${DNS_STRATEGY}|${dns_strategy}|g" \
		    -e "s|\${BOOTSTRAP_DNS_IPV4}|${bootstrap_dns}|g" \
		    -e "s|\${LOCAL_DOH_HOST}|dns.alidns.com|g" \
		    -e "s|\${LOCAL_DOH_PATH}|/dns-query|g" \
		    -e "s|\${REMOTE_CF_HOST}|cloudflare-dns.com|g" \
		    -e "s|\${REMOTE_CF_PATH}|/dns-query|g" \
		    -e "s|\${REMOTE_MAIN_TAG}|${REMOTE_MAIN_TAG:-remote_cf}|g" \
		    -e "s|\${DASHBOARD_PORT}|${DASHBOARD_PORT:-9090}|g" \
		    -e "s|\${DASHBOARD_SECRET}|${DASHBOARD_SECRET:-sing-box}|g" \
		    -e "s|\${RECOMMENDED_TUN_MTU}|${RECOMMENDED_TUN_MTU:-1400}|g" \
		    -e "s|\${LAN_SUBNET}|${LAN_SUBNET:-192.168.0.0/16}|g" \
		    "$template_src_dir/config_template.json.tpl" > "$tmp_tpl"
		
		# 第二阶段: 依托 JQ 进行对象级无损注入
		jq --argjson cr "$cr_arr" \
		   --argjson cd "$cd_arr" \
		   --argjson nd "$nd_json" \
		   '
		   .route.rules = (.route.rules[:2] + $cr + .route.rules[2:]) |
		   .dns.rules = ($cd + .dns.rules) |
		   (if $nd != null then .dns.servers = (.dns.servers[:3] + [$nd] + .dns.servers[3:]) else . end)
		   ' "$tmp_tpl" | _atomic_write "$config_dir/config_template.json"
		
		rm -f "$tmp_tpl"
		
		# [New] 同时部署文档模板
		if [ -f "$template_src_dir/config_template.md.tpl" ]; then
			sed -e "s|\${MAIN_IFACE}|${MAIN_IFACE}|g" \
			    -e "s|\${LAN_SUBNET}|${LAN_SUBNET}|g" \
			    -e "s|\${PHYSICAL_MTU}|${PHYSICAL_MTU}|g" \
			    -e "s|\${RECOMMENDED_TUN_MTU}|${RECOMMENDED_TUN_MTU}|g" \
			    -e "s|\${HAS_IPV6}|${HAS_IPV6}|g" \
			    -e "s|\${BOOTSTRAP_DNS_IPV4}|${bootstrap_dns}|g" \
			    -e "s|\${LOCAL_DOH_HOST}|dns.alidns.com|g" \
			    -e "s|\${LOCAL_DOH_PATH}|/dns-query|g" \
			    -e "s|\${REMOTE_CF_HOST}|cloudflare-dns.com|g" \
			    -e "s|\${REMOTE_CF_PATH}|/dns-query|g" \
			    -e "s|\${NEXTDNS_HOST}|dns.nextdns.io|g" \
			    -e "s|\${NEXTDNS_ID}|${NEXTDNS_ID}|g" \
			    -e "s|\${DASHBOARD_PORT}|${DASHBOARD_PORT}|g" \
			    -e "s|\${DASHBOARD_SECRET}|${DASHBOARD_SECRET}|g" \
			    -e "s|\${REMOTE_MAIN_TAG}|${REMOTE_MAIN_TAG:-remote_cf}|g" \
			    "$template_src_dir/config_template.md.tpl" | _atomic_write "$config_dir/docs/config_template.md"
		fi
	fi

	# 4.2 生成 providers.json
	# 仅当升级模式 && (已有 providers.json 且不为空) && (未输入新 URL) 时跳过
	if [ "${UPGRADE_MODE:-0}" -eq 1 ] && [ -f "$config_dir/providers.json" ] && \
	   grep -qv '"subscribes": \[\]' "$config_dir/providers.json" && [ ${#AIRPORT_URLS[@]} -eq 0 ]; then
		log_info "升级模式: 复用现有订阅配置"
	else
		log_info "生成订阅配置文件..."
		local urls_csv tags_csv
		urls_csv=$(printf "%s," "${AIRPORT_URLS[@]}")
		tags_csv=$(printf "%s," "${AIRPORT_TAGS[@]}")
		# 去掉末尾逗号
		urls_csv="${urls_csv%,}"
		tags_csv="${tags_csv%,}"
		
		if [ -f "/usr/local/bin/generate_providers.sh" ]; then
			/usr/local/bin/generate_providers.sh "$config_dir/config_template.json" "$urls_csv" "$tags_csv" "$config_dir/providers.json"
		elif [ -f "$(dirname "$0")/scripts/generate_providers.sh" ]; then
			"$(dirname "$0")/scripts/generate_providers.sh" "$config_dir/config_template.json" "$urls_csv" "$tags_csv" "$config_dir/providers.json"
		fi
	fi

	# 4.3 首次执行配置生成
	log_info "执行初次配置生成..."
	local py_bin="$SB_SUB/venv/bin/python"
	if [ -f "$py_bin" ]; then
		# [安全检测] 如果 providers.json 为空数组，告警
		if grep -q '"subscribes": \[\]' "$config_dir/providers.json"; then
			log_warn "检测到订阅列表为空！如果你在测试中，可以忽略。如果是正式环境，请确保 providers.json 配置正确。"
		fi
		# 将我们的配置模板复制到 sing-box-subscribe 的 config_template/ 目录
		# main.py 通过 --template_index 从该目录选择模板（不使用 providers.json 的 config_template 字段）
		_run mkdir -p "$SB_SUB/config_template"
		install -m 644 "$config_dir/config_template.json" "$SB_SUB/config_template/00-local-tun.json"
		log_info "  ✓ 配置模板已同步到 sing-box-subscribe"

		# 将 providers.json 链接/复制到 sing-box-subscribe 目录 (main.py 从 CWD 加载)
		install -m 640 "$config_dir/providers.json" "$SB_SUB/providers.json"

		if ! (cd "$SB_SUB" && "$py_bin" main.py --template_index=0); then
			log_error "订阅转换执行失败"
			exit 1
		fi

		# C-2 安全修复: 立即删除 sing-box-subscribe 目录下的 providers.json 副本
		# 该副本包含订阅 URL (含 token)，运行完成后无需保留
		rm -f "$SB_SUB/providers.json" 2>/dev/null || true

		# 如果 save_config_path 未生效，手动移动（兼容性）
		if [ -f "$SB_SUB/config.json" ]; then
			mv "$SB_SUB/config.json" "$config_dir/config.json"
		fi
	fi

	# 4.4 地区自动分组
	log_info "扫描地区并生成分组..."
	if [ -f "/usr/local/bin/singbox_build_region_groups.py" ]; then
		DEFAULT_REGION="${DEFAULT_REGION}" python3 /usr/local/bin/singbox_build_region_groups.py "$config_dir/config.json"
	fi

	# 4.5 配置校验
	log_info "配置最终校验..."
	if ! validate_sing_box_config "$config_dir/config.json"; then
		log_error "生成的配置校验不通过"
		exit 1
	fi

	echo ""
}
