#!/usr/bin/env bash
#
# Step 03: Setup sing-box-subscribe
#

deploy_step_03() {
	log_step "========== [3/7] 配置 sing-box-subscribe =========="

	if [ "${UPGRADE_MODE:-0}" -eq 1 ]; then
		log_info "[升级模式] 已存在订阅转换工具，检查更新..."
		if [ -d "$SB_SUB" ]; then
			if cd "$SB_SUB"; then
				git pull 2>/dev/null || true
			fi
		fi
	else
		log_info "从 GitHub 克隆 sing-box-subscribe..."
		if [ -d "$SB_SUB" ]; then
			_run rm -rf "$SB_SUB"
		fi
		_run git clone https://github.com/Toperlock/sing-box-subscribe "$SB_SUB"
		# O-C3 安全加固: 收紧目录权限，防止 providers.json (含 token) 被未授权进程读取
		_run chmod 750 "$SB_SUB"
		
		log_info "配置 Python 虚拟环境..."
		_run python3 -m venv "$SB_SUB/venv"
		_run "$SB_SUB/venv/bin/pip" install --upgrade pip
		_run "$SB_SUB/venv/bin/pip" install -r "$SB_SUB/requirements.txt"
	fi

	# 保存 commit 记录用于文档
	if [ -d "$SB_SUB" ]; then
		# shellcheck disable=SC2034
		SUBSCRIBE_COMMIT=$(cd "$SB_SUB" && git rev-parse --short HEAD 2>/dev/null || echo "unknown")
		
		# [优化] 自动修复第三方工具中误导性的提示语 (Hot Patch)
		if [ -f "$SB_SUB/main.py" ]; then
			_run sed -i 's/会导致sing-box无法运行，请检查config模板是否正确/会导致部分功能不可用，请检查订阅链接是否有效或模板是否正确/g' "$SB_SUB/main.py"
		fi
	fi

	echo ""
}
