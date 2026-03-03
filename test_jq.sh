cr_arr='[{"domain": ["abc.com"], "outbound": "direct"}, {"domain": ["xyz.com"], "outbound": "proxy"}]'
cd_arr='[{"domain": ["abc.com"], "server": "local"}, {"domain": ["xyz.com"], "server": "remote_cf"}]'
nd_json='{"tag": "remote_nextdns", "server": "dns.nextdns.io"}'

cat << 'JSON' > json_test.json
{
  "dns": {
    "strategy": "ipv4_only",
    "servers": [
      {"tag": "bootstrap"},
      {"tag": "local"},
      {"tag": "remote_cf"},
      {"tag": "fallback"}
    ],
    "rules": [
      { "rule_set": ["geosite-cn"], "server": "local" }
    ]
  },
  "route": {
    "rules": [
      { "action": "hijack-dns", "protocol": ["dns"] },
      { "action": "hijack-dns", "port": [53] },
      { "rule_set": ["geosite-cn", "geoip-cn"], "outbound": "direct" },
      { "outbound": "proxy" }
    ]
  }
}
JSON

jq --argjson cr "$cr_arr" \
   --argjson cd "$cd_arr" \
   --argjson nd "$nd_json" \
   '
   .route.rules = (.route.rules[:2] + $cr + .route.rules[2:]) |
   .dns.rules = ($cd + .dns.rules) |
   (if $nd != null then .dns.servers = (.dns.servers[:3] + [$nd] + .dns.servers[3:]) else . end)
   ' json_test.json
