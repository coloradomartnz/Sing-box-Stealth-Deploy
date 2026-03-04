[Unit]
Description=Sing-box Stealth+ Residential Proxy Watchdog
After=sing-box.service
Requires=sing-box.service

[Service]
Type=simple
ExecStart=/usr/local/bin/singbox-residential-watchdog.sh

# O-Secure 5.3: 动态注入挂载安全凭据
LoadCredential=dash_secret:/usr/local/etc/sing-box/.credentials/dash_secret
LoadCredential=res_pass:/usr/local/etc/sing-box/.credentials/res_pass
LoadCredential=res_user:/usr/local/etc/sing-box/.credentials/res_user

Restart=always
RestartSec=5
# 限制日志大小
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
