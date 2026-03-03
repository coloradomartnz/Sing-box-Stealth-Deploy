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
        "server_port": 53
      }
    ],
    "rules": [
      { "rule_set": ["geosite-cn"], "server": "local" },
      { "domain_suffix": [".cn", ".中国"], "server": "local" },
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
        "fc00::/7",
        "fe80::/10"
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
      "default": "auto",
      "filter": []
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": { "server": "local" },
    "rule_set": [
      { "tag": "geosite-cn", "type": "local", "format": "binary", "path": "/var/lib/sing-box/ruleset/geosite-cn.srs" },
      { "tag": "geosite-geolocation-!cn", "type": "local", "format": "binary", "path": "/var/lib/sing-box/ruleset/geosite-geolocation-!cn.srs" },
      { "tag": "geoip-cn", "type": "local", "format": "binary", "path": "/var/lib/sing-box/ruleset/geoip-cn.srs" }
    ],
    "rules": [
      { "action": "hijack-dns", "protocol": ["dns"] },
      { "action": "hijack-dns", "port": [53] },
      { "rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct" },
      { "outbound": "🚀 节点选择" }
    ]
  }
}
