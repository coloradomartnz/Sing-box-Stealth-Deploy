{
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:${DASHBOARD_PORT}",
      "external_ui": "/usr/local/etc/sing-box/ui",
      "secret": "${DASHBOARD_SECRET}",
      "default_mode": "rule"
    },
    "cache_file": {
      "enabled": true,
      "path": "/var/lib/sing-box/cache.db",
      "store_fakeip": true
    }
  },
  "log": {
    "disabled": false,
    "level": "info",
    "output": "stdout",
    "timestamp": true
  },
  "dns": {
    ${DNS_STRATEGY}
    "servers": [
      {
        "tag": "google",
        "type": "udp",
        "server": "8.8.8.8",
        "server_port": 53,
        "detour": "🤖 AI专用-精准分流"
      },
      {
        "tag": "bootstrap",
        "type": "udp",
        "server": "${BOOTSTRAP_DNS_IPV4}",
        "server_port": 53
      },
      {
        "tag": "local",
        "type": "https",
        "server": "${LOCAL_DOH_HOST}",
        "path": "${LOCAL_DOH_PATH}",
        "domain_resolver": "bootstrap"
      },
      {
        "tag": "remote_cf",
        "type": "https",
        "server": "${REMOTE_CF_HOST}",
        "path": "${REMOTE_CF_PATH}",
        "detour": "🚀 节点选择",
        "domain_resolver": "bootstrap"
      },
      {
        "tag": "fallback",
        "type": "udp",
        "server": "8.8.8.8",
        "server_port": 53,
        "detour": "🚀 节点选择"
      }
    ],
    "rules": [
      { "rule_set": ["geosite-cn"], "server": "local" },
      { "domain_suffix": [".cn", ".中国", ".公司", ".网络"], "server": "local" },
      {
        "domain": ["openai.com", "anthropic.com", "claude.ai"],
        "rule_set": ["geosite-openai"],
        "server": "google"
      },
      { "rule_set": ["geosite-geolocation-!cn"], "server": "${REMOTE_MAIN_TAG}" }
    ],
    "final": "${REMOTE_MAIN_TAG}"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "singbox_tun",
      "address": [${TUN_ADDRESS}],
      "mtu": ${RECOMMENDED_TUN_MTU},
      "auto_route": true,
      "strict_route": true,
      "auto_redirect": true,
      "stack": "mixed",
      "route_exclude_address": [
        "${LAN_SUBNET}",
        "192.168.0.0/16",
        "10.0.0.0/8",
        "172.16.0.0/12",
        "fe80::/10",
        "::1/128"
      ],
      "sniff": true,
      "sniff_override_destination": true
    }
  ],
  "outbounds": [
    {
      "type": "urltest",
      "tag": "auto",
      "outbounds": ["{all}"],
      "interval": "3m",
      "tolerance": 50
    },
    {
      "type": "selector",
      "tag": "🚀 节点选择",
      "outbounds": ["auto", "direct"],
      "default": "auto"
    },
    {
      "type": "socks",
      "tag": "🏠 住宅代理-中转出口",
      "server": "${RES_HOST}",
      "server_port": ${RES_PORT_INT},
      "username": "${RES_USER}",
      "password": "${RES_PASS}",
      "detour": "🚀 节点选择"
    },
    {
      "type": "selector",
      "tag": "🤖 AI专用-精准分流",
      "outbounds": ["🏠 住宅代理-中转出口", "🚀 节点选择", "direct"],
      "default": "🏠 住宅代理-中转出口"
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": { "server": "local" },
    "rule_set": [
      { "tag": "geosite-cn", "type": "local", "format": "binary", "path": "/var/lib/sing-box/ruleset/geosite-cn.srs" },
      { "tag": "geosite-geolocation-!cn", "type": "local", "format": "binary", "path": "/var/lib/sing-box/ruleset/geosite-geolocation-!cn.srs" },
      { "tag": "geosite-openai", "type": "local", "format": "binary", "path": "/var/lib/sing-box/ruleset/geosite-openai.srs" },
      { "tag": "geoip-cn", "type": "local", "format": "binary", "path": "/var/lib/sing-box/ruleset/geoip-cn.srs" }
    ],
    "rules": [
      { "action": "hijack-dns", "protocol": ["dns"] },
      { "action": "hijack-dns", "port": [53] },
      {
        "domain": ["claude.ai", "anthropic.com"],
        "rule_set": ["geosite-openai"],
        "outbound": "🤖 AI专用-精准分流"
      },
      { "rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct" },
      { "outbound": "🚀 节点选择" }
    ]
  }
}
