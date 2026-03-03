// ebpf/tproxy_tc.bpf.c
// CO-RE: 只 include vmlinux.h，无需内核头文件
#include "vmlinux.h"
#include <bpf/bpf_endian.h>
#include <bpf/bpf_helpers.h>

// ─── BPF Map：存储 singbox_tun 的 ifindex ────────────────────────────────
// 由用户态 (add_docker_route.sh) 在挂载后写入，程序运行时读取
// 使用 Map 而非硬编码：singbox_tun ifindex 每次系统重启可能变化
struct {
  __uint(type, BPF_MAP_TYPE_ARRAY);
  __uint(max_entries, 1);
  __type(key, __u32);
  __type(value, __u32);
} tun_ifindex_map SEC(".maps");

// ─── 旁路 CIDR Map（跳过直连网段，不送入代理）────────────────────────────
// 用于 Docker 宿主机间通信不走代理（对应原 add_docker_route.sh 的直连逻辑）
struct {
  __uint(type, BPF_MAP_TYPE_LPM_TRIE);
  __uint(max_entries, 64);
  __uint(map_flags, BPF_F_NO_PREALLOC);
  __type(
      key, struct {
        __u32 prefixlen;
        __u32 addr;
      });
  __type(value, __u8);
} bypass_cidr_map SEC(".maps");

#define ETH_P_IP_BE bpf_htons(0x0800)
#define ETH_P_IPV6_BE bpf_htons(0x86DD)
#define IPPROTO_TCP 6
#define IPPROTO_UDP 17
#define ETH_HLEN 14
#define TC_ACT_OK 0

// ─── TC Ingress Hook（挂在 docker0 / br-xxx 等容器接口上）──────────────────
SEC("tc/ingress")
int redirect_docker_to_singbox(struct __sk_buff *skb) {
  void *data = (void *)(long)skb->data;
  void *data_end = (void *)(long)skb->data_end;

  // ① L2 解析（Verifier 强制要求边界检查）
  struct ethhdr *eth = data;
  if ((void *)(eth + 1) > data_end)
    return TC_ACT_OK;

  // ② 仅处理 IPv4 TCP/UDP（IPv6 走单独逻辑，此处 pass-through）
  if (eth->h_proto != ETH_P_IP_BE)
    return TC_ACT_OK;

  struct iphdr *ip = (void *)(eth + 1);
  if ((void *)(ip + 1) > data_end)
    return TC_ACT_OK;

  if (ip->protocol != IPPROTO_TCP && ip->protocol != IPPROTO_UDP)
    return TC_ACT_OK;

  // ③ 查询旁路表：对 LAN/Docker 内部通信直接放行
  struct {
    __u32 prefixlen;
    __u32 addr;
  } key = {
      .prefixlen = 32,
      .addr = ip->daddr, // 目的 IP 查表
  };
  if (bpf_map_lookup_elem(&bypass_cidr_map, &key))
    return TC_ACT_OK; // 命中直连段，不劫持

  // ④ 获取 singbox_tun ifindex（运行时从 Map 读取，避免硬编码）
  __u32 map_key = 0;
  __u32 *tun_ifindex = bpf_map_lookup_elem(&tun_ifindex_map, &map_key);
  if (!tun_ifindex || *tun_ifindex == 0)
    return TC_ACT_OK; // Map 未初始化，安全降级

  // ⑤ 关键：剥掉 Ethernet header，TUN 是 L3 设备不理解 L2
  // bpf_skb_adjust_room 负数 = 从头部裁掉 N 字节
  // BPF_ADJ_ROOM_MAC = 操作的是 MAC 层（以太网头）
  if (bpf_skb_adjust_room(skb, -(int)ETH_HLEN, BPF_ADJ_ROOM_MAC, 0) < 0)
    return TC_ACT_OK; // 裁剪失败，安全放行

  // ⑥ 直接砸给 singbox_tun，完全绕过 IP 路由子系统和 Netfilter
  // 封包从 docker0 TC ingress 直飞 singbox_tun，零经过 iptables
  return bpf_redirect(*tun_ifindex, 0);
}

char LICENSE[] SEC("license") = "GPL";
