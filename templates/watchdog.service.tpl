[Unit]
Description=Sing-box Stealth+ Residential Proxy Watchdog
After=sing-box.service
Requires=sing-box.service

[Service]
Type=simple
# 审计修复(C-10): 使用专用用户运行，增加安全沙箱
User=sing-box
Group=sing-box
ExecStart=/usr/local/bin/singbox-residential-watchdog.sh

# O-Secure 5.3: 动态注入挂载安全凭据
LoadCredential=dash_secret:/usr/local/etc/sing-box/.credentials/dash_secret
LoadCredential=res_pass:/usr/local/etc/sing-box/.credentials/res_pass
LoadCredential=res_user:/usr/local/etc/sing-box/.credentials/res_user

Restart=always
RestartSec=5

# 审计修复(C-10): 安全沙箱加固
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=true
PrivateTmp=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
# Watchdog 只需要网络访问和读取凭据
ReadOnlyPaths=/usr/local/etc/sing-box

# 限制日志大小
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
