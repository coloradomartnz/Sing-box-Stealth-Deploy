#!/usr/bin/env bash
#
# Step 06: Templates and Configuration Generation
#

deploy_step_06() {
	log_step "========== [Step ${CURRENT_STEP_INDEX:-?} / ${TOTAL_STEPS_COUNT:-?}] Generate config templates and initial subscription =========="

	local config_dir="/usr/local/etc/sing-box"
	local template_src_dir
	template_src_dir="$(dirname "$(readlink -f "$0")")/templates"

	# Deploy base config template
	log_info "Processing config template..."
	
	# Set template variables
	local tun_address dns_strategy bootstrap_dns
	if [ "${HAS_IPV6:-0}" -eq 1 ]; then
		tun_address='["172.18.0.1/30", "fd00::1/126"]'
		dns_strategy='"prefer_ipv4"'
	else
		tun_address='["172.18.0.1/30"]'
		dns_strategy='"ipv4_only"'
	fi

	# Select bootstrap DNS
	# [Risk note]
	# Initial plaintext DNS (223.5.5.5 / 8.8.8.8) is used as bootstrap (UDP/53)
	# Only used to resolve DoH infrastructure domains before tunnel is established
	# strict_route:true blocks regular app DNS leaks after tunnel is up
	# Once DoH resolves and tunnel establishes, daily DNS is protected
	bootstrap_dns="223.5.5.5"
	if ! timeout 2 ping -c1 -W1 223.5.5.5 >/dev/null 2>&1; then
		bootstrap_dns="8.8.8.8"
	fi

	# Generate NextDNS server block based on toggle
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

	# Process custom routing rules (JQ-native generation)
	log_info "Processing custom routing rules..."
	
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

	# Process config_template.json.tpl
	if [ -f "$template_src_dir/config_template.json.tpl" ]; then
		local safe_secret="${DASHBOARD_SECRET:-sing-box}"
		local safe_res_pass="${RES_PASS:-}"
		local safe_res_user="${RES_USER:-}"
		
		# Extract sensitive values to secure credentials directory
		local cred_dir="/usr/local/etc/sing-box/.credentials"
		_run mkdir -p "$cred_dir"
		_run chmod 700 "$cred_dir"
		echo -n "$safe_secret" > "$cred_dir/dash_secret"
		echo -n "$safe_res_pass" > "$cred_dir/res_pass"
		echo -n "$safe_res_user" > "$cred_dir/res_user"
		_run chmod 600 "$cred_dir"/*

		# Phase 1: Build temporary JSON with parameter vars
		local vars_json
		vars_json=$(mktemp /tmp/singbox-vars.XXXXXX)
		jq -n \
		   --arg tun_address "$tun_address" \
		   --arg dns_strategy "$dns_strategy" \
		   --arg bootstrap_dns "$bootstrap_dns" \
		   --arg remote_tag "${REMOTE_MAIN_TAG:-remote_cf}" \
		   --arg dash_port "${DASHBOARD_PORT:-9090}" \
		   --arg mtu "${RECOMMENDED_TUN_MTU:-1400}" \
		   --arg lan_subnet "${LAN_SUBNET:-192.168.0.0/16}" \
		   --arg res_host "${RES_HOST:-127.0.0.1}" \
		   --arg res_port "${RES_PORT:-0}" \
		  '{
		     tun_address: ($tun_address | fromjson),
		     dns_strategy: ($dns_strategy | fromjson),
		     bootstrap_dns: $bootstrap_dns, 
		     remote_tag: $remote_tag, 
		     dash_port: $dash_port,
		     mtu: ($mtu | tonumber), 
		     lan_subnet: $lan_subnet, 
		     res_host: $res_host,
		     res_port: ($res_port | tonumber)
		   }' > "$vars_json"

		# Phase 2: Lossless JQ object injection (no secrets injected here)
		jq --slurpfile vars "$vars_json" \
		   --argjson cr "$cr_arr" \
		   --argjson cd "$cd_arr" \
		   --arg nd "$nd_json" \
		   --arg has_res "${RES_HOST:+1}" \
		   '
		   ($vars[0]) as $v |
		   .experimental.clash_api.external_controller = "127.0.0.1:\($v.dash_port)" |
		   .dns.strategy = $v.dns_strategy |
		   (.dns.servers[] | select(.tag == "bootstrap").server) = $v.bootstrap_dns |
		   (.dns.rules[] | select(.rule_set == ["geosite-geolocation-!cn"]).server) = $v.remote_tag |
		   .dns.final = $v.remote_tag |
		   .inbounds[0].address = $v.tun_address |
		   .inbounds[0].mtu = $v.mtu |
		   .inbounds[0].route_exclude_address[0] = $v.lan_subnet |
		   (.outbounds[] | select(.tag == "🏠 住宅代理-中转出口") | .server) = $v.res_host |
		   (.outbounds[] | select(.tag == "🏠 住宅代理-中转出口") | .server_port) = $v.res_port |
		   # 注入自定义规则 (保留索引 1 之后的位置，因为移除了 sniffing 之外的固定规则)
		   .route.rules = (.route.rules[:1] + $cr + .route.rules[1:]) |
		   .dns.rules = ($cd + .dns.rules) |
		   # ND JSON 注入
		   (if $nd != "null" then .dns.servers = (.dns.servers[:2] + [$nd|fromjson] + .dns.servers[2:]) else . end) |
		   # Stealth+ 逻辑: 动态注入 AI 精准分流
		   (if $has_res == "1" then
		     # 注入 AI Selector
		     .outbounds += [{
		       "type": "selector",
		       "tag": "🤖 AI专用-精准分流",
		       "outbounds": ["🏠 住宅代理-中转出口", "🚀 节点选择", "direct"],
		       "default": "🏠 住宅代理-中转出口"
		     }] |
		     # 注入 AI 规则到 route (索引 1，在 sniffing 之后)
		     # 这里也建议用 logical AND 如果有对应 geoname 可用，但目前 AI 规则通常直接匹配 geosite 且走专线
		     .route.rules = [.route.rules[0]] + [{"rule_set": ["geosite-openai"], "outbound": "🤖 AI专用-精准分流"}] + .route.rules[1:] |
		     .
		   else
		     # 彻底清理未使用的住宅出口
		     del(.outbounds[] | select(.tag == "🏠 住宅代理-中转出口"))
		   end)
		   ' "$template_src_dir/config_template.json.tpl" | _atomic_write "$config_dir/config_template.json"
		
		rm -f "$vars_json"
		
		# [New] 同时部署文档模板
		if [ -f "$template_src_dir/config_template.md.tpl" ]; then
			local safe_nextdns_id
			safe_nextdns_id=$(_sed_escape_replacement "${NEXTDNS_ID:-}")
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
			    -e "s|\${NEXTDNS_ID}|${safe_nextdns_id}|g" \
			    -e "s|\${DASHBOARD_PORT}|${DASHBOARD_PORT}|g" \
			    -e "s|\${DASHBOARD_SECRET}|${safe_secret}|g" \
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
	
	if [ "${SUBSTORE_MODE:-0}" -eq 1 ]; then
		log_info "[Sub-Store 模式] 跳过初次订阅拉取，使用直连骨架配置冷启动..."
		jq '.outbounds |= map(
			if .type == "selector" then .outbounds = ["direct"] | .default = "direct"
			elif .type == "urltest" then .outbounds = ["direct"]
			else . end
		)' "$config_dir/config_template.json" | _atomic_write "$config_dir/config.json"
		log_warn "⚠ 当前暂无代理节点 (直连状态)，请在 Web UI 配置完成后运行: sudo substore-update.sh"
	elif [ -f "$py_bin" ]; then
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

		if ! (cd "$SB_SUB" && PYTHONWARNINGS="ignore" "$py_bin" main.py --template_index=0); then
			log_error "订阅转换执行失败"
			exit "${E_CONFIG:-11}"
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

	# 4.5 DNS 最终修复 (确保在所有后处理之后)
	# ── DNS 修复: 移除任何注入的非法 ":53" DNS 条目 ──
	# sing-box 1.10+ 不接受 address/server 只有端口的写法
	log_info "执行 DNS 配置终极修复（清除所有非法 :53 条目）..."
	local _fixed_config
	_fixed_config=$(mktemp /tmp/singbox-dns-fix.XXXXXX)

	if jq '
	  # 1. 彻底删掉所有 address 或 server 字段值为 ":53" 的 dns.servers 条目
	  .dns.servers |= map(select(.address != ":53" and .server != ":53")) |
	  # 2. 补回/修正 tag=="local" 的条目，确保它指向可靠的地址
	  if (.dns.servers | map(select(.tag == "local")) | length) == 0 then
	    .dns.servers = [{
	      "tag": "local",
	      "type": "https",
	      "server": "dns.alidns.com",
	      "path": "/dns-query",
	      "domain_resolver": "bootstrap"
	    }] + .dns.servers
	  else . end
	' "$config_dir/config.json" > "$_fixed_config"; then
		mv "$_fixed_config" "$config_dir/config.json"
	else
		log_warn "DNS 终极修复失败"
		rm -f "$_fixed_config"
	fi

	# 4.6 配置校验
	log_info "配置最终校验..."
	_run chown root:sing-box "$config_dir/config.json"
	_run chmod 640 "$config_dir/config.json"
	if ! validate_sing_box_config "$config_dir/config.json"; then
		log_error "生成的配置校验不通过"
		exit "${E_CONFIG:-11}"
	fi

	# 审计修复(E-01): 语义级校验——确保配置中存在有效代理节点
	# 防止订阅返回空内容时生成一个语法正确但没有任何代理的配置
	if [ "${SUBSTORE_MODE:-0}" -ne 1 ]; then
		local _outbound_count
		_outbound_count=$(jq '[.outbounds[] | select(.type != "direct" and .type != "block" and .type != "dns" and .type != "selector" and .type != "urltest")] | length' "$config_dir/config.json" 2>/dev/null || echo "0")
		if [ "$_outbound_count" -eq 0 ]; then
			log_error "配置文件不包含任何有效代理节点，可能是订阅拉取失败或订阅为空"
			log_error "请检查 providers.json 中的订阅链接是否有效"
			exit "${E_CONFIG:-11}"
		fi
		log_info "  ✓ 检测到 $_outbound_count 个有效代理节点"
	fi

	echo ""
}
