# TUN 配置说明（Cloudflare / NextDNS）

## 网络环境
- 主接口: ${MAIN_IFACE}
- LAN网段: ${LAN_SUBNET}
- 物理MTU: ${PHYSICAL_MTU}
- TUN MTU: ${RECOMMENDED_TUN_MTU}
- IPv6支持: $([ "$HAS_IPV6" -eq 1 ] && echo "是" || echo "否")

## DNS 设计
- bootstrap（仅解析 DoH 域名）: UDP ${BOOTSTRAP_DNS_IPV4}:53
- 国内 DoH（直连）: https://${LOCAL_DOH_HOST}${LOCAL_DOH_PATH}
- 国外 DoH（走代理）: https://${REMOTE_CF_HOST}${REMOTE_CF_PATH}
- NextDNS（走代理，可选）: https://${NEXTDNS_HOST}/${NEXTDNS_ID}

## 当前默认 remote
- ${REMOTE_MAIN_TAG}

## 验证命令
```bash
# 检查生成配置是否能通过 sing-box
sing-box check -c /usr/local/etc/sing-box/config.json

# 代理通
curl -I https://www.google.com

# 直连通
curl -I https://www.baidu.com
```
