#!/usr/bin/env bash
#
# sing-box deployment project - uninstall subcommand
#

do_uninstall() {
	echo ""
	echo "=========================================="
	echo "  sing-box 完整卸载程序"
	echo "=========================================="
	echo ""
	echo -e "${RED}⚠️  警告：此操作将：${NC}"
	echo "  1. 停止并删除所有 sing-box 相关服务"
	echo "  2. 删除配置文件、脚本、规则集"
	echo "  3. 移除 APT 源和软件包"
	echo "  4. 恢复系统原始配置"
	echo ""
	echo "  保留的内容："
	echo "  - 备份文件（可选移至 /root/singbox-backups/）"
	echo "  - 日志（journalctl -u sing-box）"
	echo ""
	read -r -p "确认卸载？请输入 yes 继续: " CONFIRM
	if [[ "$CONFIRM" != "yes" ]]; then
		echo "[!] 已取消卸载"
		exit 0
	fi

	echo ""
	echo "[*] 开始卸载..."

	# [1/10] 停止并禁用所有 systemd 服务和 timer
	echo "[1/10] 停止并禁用 systemd 单元..."
	local units=(
		sing-box.service
		singbox-healthcheck.service singbox-healthcheck.timer
		singbox-ruleset-weekly-update.service singbox-ruleset-weekly-update.timer
		singbox-dns-failover.service singbox-dns-failover.timer
		singbox-backup.service singbox-backup.timer
	)
	for unit in "${units[@]}"; do
		if systemctl list-unit-files "$unit" &>/dev/null; then
			systemctl stop "$unit" 2>/dev/null || true
			systemctl disable "$unit" 2>/dev/null || true
			echo "  ✓ 已停止: $unit"
		fi
	done

	# [2/10] 删除 systemd 单元文件
	echo "[2/10] 删除 systemd 单元文件..."
	rm -f /etc/systemd/system/sing-box.service
	rm -rf /etc/systemd/system/sing-box.service.d
	rm -f /etc/systemd/system/singbox-healthcheck.{service,timer}
	rm -f /etc/systemd/system/singbox-dns-failover.{service,timer}
	rm -f /etc/systemd/system/singbox-ruleset-weekly-update.{service,timer}
	rm -f /etc/systemd/system/singbox-backup.{service,timer}
	systemctl daemon-reload
	echo "  ✓ 已删除所有 systemd 单元"

	# [3/10] 删除管理脚本
	echo "[3/10] 删除管理脚本..."
	rm -f /usr/local/bin/singbox_health_check.sh
	rm -f /usr/local/bin/singbox_dns_failover.sh
	rm -f /usr/local/bin/singbox_ruleset_weekly_update.sh
	rm -f /usr/local/bin/add_docker_route.sh
	rm -f /usr/local/bin/singbox_build_region_groups.py
	# O-C2 修复: 清理共享锁库目录
	rm -rf /usr/local/lib/singbox
	echo "  ✓ 已删除管理脚本"

	# [4/10] 删除配置目录（保留备份）
	echo "[4/10] 删除配置文件（保留备份）..."
	if [ -d /usr/local/etc/sing-box ]; then
		# 先把备份移到临时位置
		local BACKUP_TEMP
		BACKUP_TEMP="/tmp/singbox-backups-$(date +%Y%m%d-%H%M%S)"
		if [ -d /usr/local/etc/sing-box/backups ]; then
			mv /usr/local/etc/sing-box/backups "$BACKUP_TEMP"
			echo "  ✓ 备份已暂存到: $BACKUP_TEMP"
		fi

		# 清理部署配置
		rm -f /usr/local/etc/sing-box/.deployment_config
		rm -rf /usr/local/etc/sing-box

		# 询问是否恢复备份到新位置
		if [ -d "${BACKUP_TEMP:-}" ]; then
			read -p "  是否将备份移到 /root/singbox-backups？[y/N]: " -n 1 -r KEEP_BACKUP
			echo
			if [[ "$KEEP_BACKUP" =~ ^[Yy]$ ]]; then
				mv "$BACKUP_TEMP" /root/singbox-backups
				echo "  ✓ 备份已移至: /root/singbox-backups"
			else
				rm -rf "$BACKUP_TEMP"
				echo "  ✓ 备份已删除"
			fi
		fi
	fi
	echo "  ✓ 配置目录已清理"

	# [5/10] 删除规则集和状态目录
	echo "[5/10] 删除规则集和状态目录..."
	rm -rf /var/lib/sing-box
	# 运行时锁文件
	rm -f /run/lock/singbox-dns-failover.lock /run/lock/singbox-dns-failover.lock.pid
	rm -f /run/lock/sing-box-update.lock /run/lock/sing-box-update.lock.pid
	# O-5 修复: 清理遗漏的主部署锁
	rm -f /run/lock/singbox-deploy.lock /run/lock/singbox-deploy.lock.pid
	# O-C2 修复: 清理健康检查和备份锁
	rm -f /run/lock/singbox-healthcheck.lock /run/lock/singbox-healthcheck.lock.pid
	rm -f /run/lock/singbox-backup.lock
	# O-C2 修复: 清理 DNS 切换备份文件
	rm -f /usr/local/etc/sing-box/config.json.pre-dns-switch.* 2>/dev/null || true
	rm -f /usr/local/etc/sing-box/config_template.json.pre-dns-switch.* 2>/dev/null || true
	echo "  ✓ 已删除 /var/lib/sing-box"

	# [6/10] 删除系统钩子和相关配置
	echo "[6/10] 删除系统钩子和相关配置..."
	rm -f /usr/lib/systemd/system-sleep/sing-box-resume
	rm -f /etc/systemd/journald.conf.d/sing-box.conf
	rm -f /etc/systemd/resolved.conf.d/sing-box.conf
	rm -f /etc/tmpfiles.d/tun.conf
	echo "  ✓ 已删除恢复钩子、journald、resolved 和 TUN 持久化配置"

	# [7/10] 恢复 NetworkManager 配置
	echo "[7/10] 恢复 NetworkManager 配置..."
	rm -f /etc/NetworkManager/conf.d/sing-box.conf
	if [ -f /etc/NetworkManager/NetworkManager.conf ]; then
		if grep -q "unmanaged-devices=interface-name:singbox_tun" /etc/NetworkManager/NetworkManager.conf; then
			sed -i '/unmanaged-devices=interface-name:singbox_tun/d' /etc/NetworkManager/NetworkManager.conf
			sed -i '/^\[keyfile\]$/{N;/^\[keyfile\]\n$/d}' /etc/NetworkManager/NetworkManager.conf
		fi
	fi
	systemctl restart NetworkManager 2>/dev/null || true
	echo "  ✓ 已清理 NetworkManager 配置"

	# [8/10] 卸载 sing-box 软件包
	echo "[8/10] 卸载 sing-box 软件包..."
	if dpkg-query -W sing-box &>/dev/null; then
		apt-get purge -y sing-box 2>/dev/null || true
		apt-get autoremove -y 2>/dev/null || true
		echo "  ✓ 已卸载 sing-box"
	else
		echo "  - sing-box 未安装，跳过"
	fi

	# [9/10] 删除 APT 源和安全策略
	echo "[9/10] 删除 APT 源与安全策略..."
	rm -f /etc/apt/sources.list.d/sagernet.sources
	rm -f /etc/apt/keyrings/sagernet.asc
	rm -f /etc/apt/preferences.d/sing-box
	rm -f /etc/apt/apt.conf.d/51sing-box-no-auto-upgrade
	
	# AppArmor
	if [ -f /etc/apparmor.d/usr.bin.sing-box ]; then
		_run apparmor_parser -R /etc/apparmor.d/usr.bin.sing-box 2>/dev/null || true
		rm -f /etc/apparmor.d/usr.bin.sing-box
	fi
	
	# IPv6 Stealth Hardening Cleanup
	if [ -f /etc/sysctl.d/99-sing-box-stealth.conf ]; then
		rm -f /etc/sysctl.d/99-sing-box-stealth.conf
		_run sysctl --system >/dev/null 2>&1 || true
	fi
	
	apt-get update -qq 2>/dev/null || true
	echo "  ✓ 已删除 APT 源、Pinning 和 AppArmor 配置"

	# [9.5/10] 移除系统用户
	echo "[9.5/10] 移除 sing-box 系统用户..."
	if id -u sing-box >/dev/null 2>&1; then
		userdel sing-box 2>/dev/null || true
		echo "  ✓ 已移除用户: sing-box"
	fi

	# [10/10] 清理 sing-box-subscribe（可选）
	echo "[10/10] 清理 sing-box-subscribe..."
	if [ -d /opt/sing-box-subscribe ]; then
		read -p "  是否删除 /opt/sing-box-subscribe？[y/N]: " -n 1 -r REMOVE_SUBSCRIBE
		echo
		if [[ "$REMOVE_SUBSCRIBE" =~ ^[Yy]$ ]]; then
			rm -rf /opt/sing-box-subscribe
			echo "  ✓ 已删除 /opt/sing-box-subscribe"
		else
			echo "  - 保留 /opt/sing-box-subscribe"
		fi
	else
		echo "  - /opt/sing-box-subscribe 不存在，跳过"
	fi

	echo ""
	# O-14: 清理 journald 中可能包含敏感信息的日志
	if command -v journalctl &>/dev/null; then
		read -p "  是否清理 sing-box 相关日志（可能含敏感信息）？[y/N]: " -n 1 -r CLEAN_LOGS
		echo
		if [[ "$CLEAN_LOGS" =~ ^[Yy]$ ]]; then
			journalctl --vacuum-time=0 --unit=sing-box 2>/dev/null || true
			echo "  ✓ 已清理 sing-box 日志"
		fi
	fi

	echo ""
	echo -e "${GREEN}==========================================${NC}"
	echo -e "${GREEN}  ✅ 卸载完成${NC}"
	echo -e "${GREEN}==========================================${NC}"
	echo ""
	exit 0
}
