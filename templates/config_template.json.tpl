{
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "/usr/local/etc/sing-box/ui/",
      "secret": "sing-box",
      "default_mode": "rule"
    },
    "cache_file": {
      "enabled": true,
      "path": "/var/lib/sing-box/cache.db",
      "store_rdrc": true
    }
  },
  "log": {
    "disabled": false,
    "level": "info",
    "output": "stdout",
    "timestamp": true
  },
  "dns": {
    "strategy": "prefer_ipv4",
    "servers": [
      {
        "tag": "bootstrap",
        "type": "udp",
        "server": "223.5.5.5",
        "server_port": 53
      },
      {
        "tag": "local",
        "type": "https",
        "server": "dns.alidns.com",
        "path": "/dns-query",
        "domain_resolver": "bootstrap"
      },
      {
        "tag": "remote_cf",
        "type": "https",
        "server": "cloudflare-dns.com",
        "path": "/dns-query",
        "detour": "🚀 节点选择",
        "domain_resolver": "bootstrap"
      }
    ],
    "rules": [
      {
        "action": "route",
        "server": "bootstrap",
        "domain": [
          "dns.alidns.com",
          "dns.google",
          "cloudflare-dns.com",
          "dns.nextdns.io"
        ]
      },
      {
        "rule_set": ["geosite-cn", "geoip-cn"],
        "action": "route",
        "server": "local"
      },
      {
        "action": "route",
        "rule_set": ["geosite-geolocation-!cn"],
        "server": "remote_cf"
      }
    ],
    "final": "remote_cf"
  },
  "inbounds": [
    {
      "type": "tun",
      "tag": "tun-in",
      "interface_name": "singbox_tun",
      "address": ["172.18.0.1/30"],
      "mtu": 1400,
      "auto_route": true,
      "strict_route": true,
      "auto_redirect": true,
      "stack": "mixed",
      "route_exclude_address": [
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
      "server": "127.0.0.1",
      "server_port": 0,
      "username": "",
      "password": "",
      "detour": "🚀 节点选择"
    },
    { "type": "direct", "tag": "direct" }
  ],
  "route": {
    "auto_detect_interface": true,
    "default_domain_resolver": { "server": "local" },
    "rule_set": [
      {
        "tag": "geosite-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-cn.srs",
        "download_detour": "🚀 节点选择",
        "update_interval": "1d"
      },
      {
        "tag": "geosite-geolocation-!cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geosite/geosite-geolocation-!cn.srs",
        "download_detour": "🚀 节点选择",
        "update_interval": "1d"
      },
      {
        "tag": "geosite-openai",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/SagerNet/sing-geosite/rule-set/geosite-openai.srs",
        "download_detour": "🚀 节点选择",
        "update_interval": "1d"
      },
      {
        "tag": "geoip-cn",
        "type": "remote",
        "format": "binary",
        "url": "https://raw.githubusercontent.com/lyc8503/sing-box-rules/rule-set-geoip/geoip-cn.srs",
        "download_detour": "🚀 节点选择",
        "update_interval": "1d"
      }
    ],
    "rules": [
      { "action": "sniff" },
      { "action": "hijack-dns", "protocol": ["dns"] },
      { "action": "hijack-dns", "port": [53] },
      {
        "type": "logical",
        "mode": "and",
        "rules": [
          { "rule_set": "geosite-cn" },
          { "rule_set": "geoip-cn" }
        ],
        "action": "route",
        "outbound": "direct"
      },
      { "outbound": "🚀 节点选择" }
    ]
  }
}
