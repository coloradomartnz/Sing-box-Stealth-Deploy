#!/usr/bin/env python3
"""
sing-box 地区自动分组脚本
功能：扫描订阅节点名称中的 emoji 旗帜，自动生成按地区分类的 urltest 出站
"""
import json, os, sys, fcntl, time, re
from collections import defaultdict

def acquire_lock(lockfile, timeout=300):
    """
    原子化获取文件锁（带僵尸锁检测）
    
    Args:
        lockfile: 锁文件路径
        timeout: 超时时间（秒）
    
    Returns:
        lock对象（成功）或 None（失败）
    """
    pid_file = f"{lockfile}.pid"
    
    # 1. 原子性打开锁文件
    try:
        lock = open(lockfile, 'w')
    except IOError as e:
        print(f"ERROR: 无法打开锁文件 {lockfile}: {e}", file=sys.stderr)
        return None
    
    start_time = time.time()
    
    # 2. 尝试获取锁（非阻塞）
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            
            # 3. 成功获取锁，写入 PID
            try:
                with open(pid_file, 'w') as pf:
                    pf.write(str(os.getpid()))
            except IOError as e:
                print(f"WARN: 无法写入 PID 文件 {pid_file}: {e}", file=sys.stderr)
            
            # 4. 注册清理函数
            import atexit
            atexit.register(lambda: cleanup_lock(pid_file))
            
            return lock
            
        except IOError:
            # 锁被占用，检查是否为僵尸锁
            elapsed = time.time() - start_time
            
            if os.path.exists(pid_file):
                try:
                    with open(pid_file, 'r') as pf:
                        lock_pid = int(pf.read().strip())
                    
                    # 检查进程是否存在
                    try:
                        os.kill(lock_pid, 0)  # 信号 0 仅检测存在性
                        # 进程存在
                        if elapsed >= timeout:
                            print(f"ERROR: 锁被占用（PID {lock_pid}），超时 {timeout}s", 
                                  file=sys.stderr)
                            return None
                    except OSError:
                        # 僵尸锁
                        print(f"INFO: 检测到僵尸锁（PID {lock_pid}），等待清理...", 
                              file=sys.stderr)
                        
                except (IOError, ValueError):
                    pass
            
            if elapsed >= timeout:
                print(f"ERROR: 获取锁超时（{timeout}s）", file=sys.stderr)
                print(f"INFO: 锁文件: {lockfile}", file=sys.stderr)
                return None
            
            time.sleep(2)

def cleanup_lock(pid_file):
    """清理锁文件"""
    try:
        if os.path.exists(pid_file):
            with open(pid_file, 'r') as pf:
                stored_pid = int(pf.read().strip())
            
            # 仅清理本进程创建的 PID 文件
            if stored_pid == os.getpid():
                os.remove(pid_file)
    except (IOError, ValueError):
        pass

def main():
    LOCK = "/tmp/singbox_regions.lock"
    
    lock = acquire_lock(LOCK, timeout=30)
    if lock is None:
        sys.exit(1)
        
    try:
        _run_logic()
    finally:
        fcntl.flock(lock, fcntl.LOCK_UN)
        lock.close()

def _run_logic():
    CONFIG = sys.argv[1] if len(sys.argv) > 1 else "/usr/local/etc/sing-box/config.json"
    # 优先从环境变量读取，其次从配置文件读取
    DEFAULT_REGION = os.environ.get("DEFAULT_REGION", "").lower()
    if not DEFAULT_REGION:
        deploy_cfg = "/usr/local/etc/sing-box/.deployment_config"
        if os.path.exists(deploy_cfg):
            try:
                with open(deploy_cfg) as dc:
                    for line in dc:
                        if line.startswith("DEFAULT_REGION="):
                            DEFAULT_REGION = line.strip().split("=", 1)[1].lower()
                            break
            except (IOError, OSError, ValueError):
                pass
    if not DEFAULT_REGION:
        DEFAULT_REGION = "jp"
    
    if not os.path.exists(CONFIG):
        print(f"❌ 配置文件不存在: {CONFIG}", file=sys.stderr)
        sys.exit(1)
    
    try:
        with open(CONFIG, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as e:
        print(f"❌ 配置文件读取失败: {e}", file=sys.stderr)
        sys.exit(1)

    # 地区名称映射
    REGION_NAMES = {
        "hk": "🇭🇰 香港", "tw": "🇹🇼 台湾", "jp": "🇯🇵 日本",
        "sg": "🇸🇬 新加坡", "us": "🇺🇸 美国", "kr": "🇰🇷 韩国",
        "gb": "🇬🇧 英国", "de": "🇩🇪 德国", "ca": "🇨🇦 加拿大",
        "au": "🇦🇺 澳大利亚", "in": "🇮🇳 印度", "tr": "🇹🇷 土耳其",
    }

    # 排除关键词
    EXCLUDE_KEYWORDS = ["流量", "过期", "剩余", "Expire", "Traffic", "官网", "网址", "地址"]

    def is_regional_indicator(c):
        return 0x1F1E6 <= ord(c) <= 0x1F1FF

    # O-21: 预编译正则,避免每次调用都重新编译
    CC_PATTERN = re.compile(r'\b([A-Z]{2})\b')

    def flag_to_cc(s):
        # 尝试通过名字直接匹配
        name_cc_map = {
            "香港": "hk", "hk": "hk", "hongkong": "hk", "hong kong": "hk",
            "台湾": "tw", "tw": "tw", "taiwan": "tw", 
            "日本": "jp", "jp": "jp", "japan": "jp",
            "狮城": "sg", "sg": "sg", "singapore": "sg", "新加坡": "sg",
            "美国": "us", "us": "us", "america": "us", "united states": "us",
            "韩国": "kr", "kr": "kr", "korea": "kr",
            "英国": "gb", "uk": "gb", "gb": "gb",
            "德国": "de", "de": "de", "germany": "de",
            "法国": "fr", "fr": "fr", "france": "fr",
            "土耳其": "tr", "tr": "tr", "turkey": "tr",
            "印度": "in", "in": "in", "india": "in",
            "澳洲": "au", "澳大利亚": "au", "au": "au", "australia": "au",
            "阿根廷": "ar", "ar": "ar", "argentina": "ar",
            "荷兰": "nl", "nl": "nl", "netherlands": "nl",
            "俄罗斯": "ru", "ru": "ru", "russia": "ru",
            "印尼": "id", "id": "id", "indonesia": "id",
            "巴西": "br", "br": "br", "brazil": "br",
            "加拿大": "ca", "加拿": "ca", "ca": "ca", "canada": "ca"
        }
        
        lower_s = s.lower()
        for key, cc in name_cc_map.items():
            if key in lower_s:
                return cc
                
        # 尝试 Emoji 匹配
        s = s.lstrip()
        if len(s) >= 2:
            a, b = s[0], s[1]
            if is_regional_indicator(a) and is_regional_indicator(b):
                cc = chr(ord('A') + (ord(a) - 0x1F1E6)) + chr(ord('A') + (ord(b) - 0x1F1E6))
                return cc.lower()
                
        # O-20: 使用预编译正则匹配两位大写字母边界词
        match = CC_PATTERN.search(s)
        if match:
            return match.group(1).lower()
            
        return None

    outbounds = cfg.get("outbounds", [])
    node_tags = []
    
    for ob in outbounds:
        t = ob.get("type")
        tag = ob.get("tag", "")
        if not tag or t in ("direct", "selector", "urltest"):
            continue
        if any(kw in tag for kw in EXCLUDE_KEYWORDS):
            continue
        node_tags.append(tag)

    groups = defaultdict(list)
    for tag in node_tags:
        cc = flag_to_cc(tag) or "other"
        groups[cc].append(tag)

    region_urltests = []
    
    # 全局自动
    if node_tags:
        region_urltests.append({
            "type": "urltest", "tag": "🌏 全局自动", "outbounds": node_tags,
            "url": "https://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 50
        })

    # 各地区
    for cc in sorted(groups.keys()):
        if cc == "other": continue
        tag = REGION_NAMES.get(cc, f"🌐 {cc.upper()}")
        region_urltests.append({
            "type": "urltest", "tag": tag, "outbounds": groups[cc],
            "url": "https://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 50
        })

    # 其他地区
    if "other" in groups:
        region_urltests.append({
            "type": "urltest", "tag": "🌍 其他地区", "outbounds": groups["other"],
            "url": "https://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 50
        })

    # Proxy selector
    proxy = next((ob for ob in outbounds if ob.get("type") == "selector" and ob.get("tag") == "🚀 节点选择"), None)
    if proxy is None:
        proxy = {"type": "selector", "tag": "🚀 节点选择", "outbounds": []}
        outbounds.insert(0, proxy)

    region_tags = [u["tag"] for u in region_urltests]
    
    # 提取 proxy 原本的非自动项（保留手动节点节点，同时去重避免重复增加 region_tags）
    original_outbounds = proxy.get("outbounds", [])
    filtered_outbounds = []
    
    # 我们不要保留旧的自动分组地区标签，因为上面我们重新生成了 region_tags
    old_region_prefixes = ("🌏", "🇭🇰", "🇹🇼", "🇯🇵", "🇸🇬", "🇺🇸", "🇰🇷", "🇬🇧", "🇩🇪", "🇨🇦", "🇦🇺", "🇮🇳", "🇹🇷", "🌍", "🌐")
    
    for tag in original_outbounds:
        if tag == "direct" or tag == "auto" or str(tag).startswith(old_region_prefixes):
            continue
        filtered_outbounds.append(tag)
        
    # 合并：地区分组在最前面，然后是具体节点组，最后是 direct
    final_proxy_outbounds = region_tags + filtered_outbounds
    if "direct" not in final_proxy_outbounds:
        final_proxy_outbounds.append("direct")
        
    proxy["outbounds"] = final_proxy_outbounds

    # 默认地区
    if DEFAULT_REGION == "auto" and "🌏 全局自动" in region_tags:
        proxy["default"] = "🌏 全局自动"
    else:
        default_tag = REGION_NAMES.get(DEFAULT_REGION, f"🌐 {DEFAULT_REGION.upper()}")
        if default_tag in region_tags:
            proxy["default"] = default_tag
        else:
            proxy["default"] = "🌏 全局自动" if "🌏 全局自动" in region_tags else region_tags[0]

    # 确保 direct
    if not any(ob.get("type") == "direct" and ob.get("tag") == "direct" for ob in outbounds):
        outbounds.append({"type": "direct", "tag": "direct"})

    # 移除旧的分组
    outbounds = [ob for ob in outbounds 
                 if not (ob.get("type") == "urltest" and ob.get("tag", "").startswith(("🌏", "🇭🇰", "🇹🇼", "🇯🇵", "🇸🇬", "🇺🇸", "🇰🇷", "🇬🇧", "🇩🇪", "🇨🇦", "🇦🇺", "🇮🇳", "🇹🇷", "🌍", "🌐")))]

    cfg["outbounds"] = region_urltests + outbounds

    tmp = CONFIG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
      json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CONFIG)

    print(f"✅ 已生成 {len(region_urltests)} 个地区分组")
    print(f"✅ 默认地区: {proxy['default']}")

if __name__ == "__main__":
    main()
