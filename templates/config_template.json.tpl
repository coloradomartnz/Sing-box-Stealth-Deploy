{
  "experimental": {
    "clash_api": {
      "external_controller": "127.0.0.1:9090",
      "external_ui": "/usr/local/etc/sing-box/ui",
      "secret": "sing-box",
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
    "strategy": "ipv4_only",
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
      { "rule_set": ["geosite-geolocation-!cn"], "server": "remote_cf" }
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
