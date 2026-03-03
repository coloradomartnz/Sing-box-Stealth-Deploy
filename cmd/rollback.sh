#!/usr/bin/env bash
#
# sing-box deployment project - rollback subcommand
#

do_rollback() {
	echo ""
	echo "========================================="
	echo "  sing-box 配置回滚向导"
	echo "========================================="
	echo ""

	local config_dir="/usr/local/etc/sing-box"
	local backup_daily="$config_dir/backups/daily"
	local backup_weekly="$config_dir/backups/weekly"
	local backup_monthly="$config_dir/backups/monthly"

	# Root 检查
	if [ "$(id -u)" -ne 0 ]; then
		log_error "回滚操作需要 root 权限（需要重启服务）"
		echo "请使用: sudo bash $0 --rollback"
		exit 1
	fi

	# 检测 sing-box 路径
	local sing_box_bin
	sing_box_bin=$(command -v sing-box 2>/dev/null || echo "/usr/bin/sing-box")

	# 当前配置信息
	if [ ! -f "$config_dir/config.json" ]; then
		log_error "未找到当前配置文件: $config_dir/config.json"
		exit 1
	fi

	echo "当前配置："
	echo "  文件: config.json"
	echo "  修改: $(stat -c '%y' "$config_dir/config.json" 2>/dev/null | cut -d. -f1)"
	echo "  大小: $(stat -c '%s' "$config_dir/config.json" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo '?')"
	echo ""

	# === [选项 1] 快速回滚点 ===
	if [ -f "$config_dir/rollback_point.tar.gz" ]; then
		local rp_timestamp rp_age_sec rp_age_min
		rp_timestamp=$(stat -c '%Y' "$config_dir/rollback_point.tar.gz" 2>/dev/null)
		rp_age_sec=$(($(date +%s) - rp_timestamp))
		rp_age_min=$((rp_age_sec / 60))

		echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
		echo "[选项 1] 快速回滚点（订阅更新前快照）"
		echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
		echo "  创建时间: $(date -d @${rp_timestamp} '+%Y-%m-%d %H:%M:%S')"
		echo "  距今: ${rp_age_min} 分钟前"

		if [ $rp_age_min -gt 10080 ]; then # 7 天
			log_warn "⚠️  回滚点超过 7 天，强烈建议检查备份列表"
		elif [ $rp_age_min -gt 1440 ]; then
			log_warn "⚠️  回滚点已超过 24 小时，可能不是最新配置"
		fi

		echo ""
		read -p "使用此回滚点？[Y/n]: " -n 1 -r USE_RP
		echo

		if [[ ! $USE_RP =~ ^[Nn]$ ]]; then
			local emergency_backup
			local emergency_dir="/usr/local/etc/sing-box/backups/emergency"
			mkdir -p "$emergency_dir"
			emergency_backup="${emergency_dir}/sing-box-emergency-$(date +%Y%m%d-%H%M%S).tar.gz"
			tar -czf "$emergency_backup" -C "$config_dir" \
				config.json config_template.json providers.json 2>/dev/null || {
				log_error "创建紧急备份失败"
				return 1
			}
			log_info "✓ 紧急备份: $emergency_backup"

			log_info "正在恢复配置..."
			if ! tar -xzf "$config_dir/rollback_point.tar.gz" -C "$config_dir" 2>/dev/null; then
				log_error "回滚点解压失败"
				return 1
			fi

			if ! "$sing_box_bin" check -c "$config_dir/config.json" &>/dev/null; then
				log_error "回滚后的配置无效"
				log_info "正在恢复..."
				tar -xzf "$emergency_backup" -C "$config_dir" 2>/dev/null || true
				return 1
			fi
			log_info "✓ 配置验证通过"

			systemctl restart sing-box
			sleep 3

			if systemctl is-active --quiet sing-box &&
				ip link show singbox_tun &>/dev/null 2>&1; then
				echo ""
				echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
				echo -e "${GREEN}✅ 回滚成功${NC}"
				echo -e "${GREEN}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
				echo ""
				systemctl status sing-box --no-pager -n 10
				echo ""
				echo "紧急备份: $emergency_backup"
				return 0
			else
				log_error "服务启动异常"
				journalctl -u sing-box -n 30 --no-pager
				return 1
			fi
		fi
	fi

	# === [选项 2] 定期备份 ===
	echo ""
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo "[选项 2] 从定期备份中选择"
	echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
	echo ""

	local all_backups=()
	local backup_types=()

	while IFS= read -r -d '' file; do
		all_backups+=("$file")
		backup_types+=("daily")
	done < <(find "$backup_daily" -name "config.json.*" -type f -print0 2>/dev/null |
		xargs -0 ls -t 2>/dev/null | head -10 | tr '\n' '\0')

	while IFS= read -r -d '' file; do
		all_backups+=("$file")
		backup_types+=("weekly")
	done < <(find "$backup_weekly" -name "config.json.*" -type f -print0 2>/dev/null |
		xargs -0 ls -t 2>/dev/null | head -3 | tr '\n' '\0')

	while IFS= read -r -d '' file; do
		all_backups+=("$file")
		backup_types+=("monthly")
	done < <(find "$backup_monthly" -name "config.json.*" -type f -print0 2>/dev/null |
		xargs -0 ls -t 2>/dev/null | head -3 | tr '\n' '\0')

	if [ ${#all_backups[@]} -eq 0 ]; then
		log_error "未找到任何备份文件"
		return 1
	fi

	echo "可用备份（最多 16 个）："
	echo ""

	for i in "${!all_backups[@]}"; do
		local file="${all_backups[$i]}"
		local type="${backup_types[$i]}"
		local timestamp=$(stat -c '%Y' "$file" 2>/dev/null)
		local size=$(stat -c '%s' "$file" 2>/dev/null | numfmt --to=iec 2>/dev/null || echo "?")
		local datetime=$(date -d @${timestamp} '+%Y-%m-%d %H:%M' 2>/dev/null || echo "未知")
		printf "[%2d] %-8s %-16s (%s)\n" "$((i + 1))" "$type" "$datetime" "$size"
	done

	echo ""
	read -r -p "请选择回滚点序号 (1-${#all_backups[@]})，输入 q 退出: " CHOICE

	if [[ "$CHOICE" == "q" ]]; then
		return 0
	elif [[ "$CHOICE" =~ ^[0-9]+$ ]] && [ "$CHOICE" -ge 1 ] && [ "$CHOICE" -le "${#all_backups[@]}" ]; then
		local selected_file="${all_backups[$((CHOICE - 1))]}"
		
		local emergency_backup
		local emergency_dir="/usr/local/etc/sing-box/backups/emergency"
		mkdir -p "$emergency_dir"
		emergency_backup="${emergency_dir}/sing-box-emergency-h-$(date +%Y%m%d-%H%M%S).tar.gz"
		tar -czf "$emergency_backup" -C "$config_dir" \
			config.json providers.json config_template.json 2>/dev/null || true
		log_info "✓ 紧急备份: $emergency_backup"

		log_info "正在从备份回滚: $selected_file"
		cp -f "$selected_file" "$config_dir/config.json"
		
		if ! "$sing_box_bin" check -c "$config_dir/config.json" &>/dev/null; then
			log_error "回滚后的配置无效"
			log_info "正在恢复紧急备份..."
			tar -xzf "$emergency_backup" -C "$config_dir" 2>/dev/null || true
			return 1
		fi

		systemctl restart sing-box
		sleep 3
		if systemctl is-active --quiet sing-box; then
			echo -e "${GREEN}✅ 回滚成功${NC}"
		else
			log_error "服务重启失败"
		fi
	else
		log_error "无效选择"
	fi
}
