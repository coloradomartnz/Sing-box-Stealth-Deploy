[Unit]
Description=Sing-box Stealth+ Residential Proxy Watchdog
After=sing-box.service
Requires=sing-box.service

[Service]
Type=simple
ExecStart=/usr/local/bin/singbox-residential-watchdog.sh
Restart=always
RestartSec=5
# 限制日志大小
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
