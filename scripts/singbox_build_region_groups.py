#!/usr/bin/env python3
"""
Scan proxy node tags for region emoji flags and generate per-region urltest outbounds
"""
import json, os, sys, fcntl, time, re
from collections import defaultdict

# Map region names to country codes (global constant, initialized once)
NAME_CC_MAP = {
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

def acquire_lock(lockfile, timeout=300):
    """Acquire an exclusive file lock with stale-lock detection"""
    pid_file = f"{lockfile}.pid"
    
    # Open lock file atomically
    try:
        lock = open(lockfile, 'w')
    except IOError as e:
        print(f"ERROR: cannot open lock file {lockfile}: {e}", file=sys.stderr)
        return None
    
    start_time = time.time()
    
    # Try non-blocking lock acquisition
    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            
            # Write PID on successful lock
            try:
                with open(pid_file, 'w') as pf:
                    pf.write(str(os.getpid()))
            except IOError as e:
                print(f"WARN: cannot write PID file {pid_file}: {e}", file=sys.stderr)
            
            # Register cleanup handler
            import atexit
            atexit.register(lambda: cleanup_lock(pid_file))
            
            return lock
            
        except IOError:
            # Lock held, check for stale lock
            elapsed = time.time() - start_time
            
            if os.path.exists(pid_file):
                try:
                    with open(pid_file, 'r') as pf:
                        lock_pid = int(pf.read().strip())
                    
                    # Check if holding process is still alive
                    try:
                        os.kill(lock_pid, 0)
                        # Process alive, wait or timeout
                        if elapsed >= timeout:
                            print(f"ERROR: lock held by PID {lock_pid}, timed out after {timeout}s", 
                                  file=sys.stderr)
                            return None
                    except OSError:
                        # Stale lock detected
                        print(f"INFO: stale lock detected (PID {lock_pid}), waiting for cleanup", 
                              file=sys.stderr)
                        
                except (IOError, ValueError):
                    pass
            
            if elapsed >= timeout:
                print(f"ERROR: lock acquisition timed out ({timeout}s)", file=sys.stderr)
                print(f"INFO: lock file: {lockfile}", file=sys.stderr)
                return None
            
            time.sleep(2)

def cleanup_lock(pid_file):
    """Remove PID file if owned by current process"""
    try:
        if os.path.exists(pid_file):
            with open(pid_file, 'r') as pf:
                stored_pid = int(pf.read().strip())
            
            # Only remove PID file created by this process
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
    # Prefer env var, fall back to deployment config file
    DEFAULT_REGION = os.environ.get("DEFAULT_REGION", "").lower()
    if not DEFAULT_REGION:
        deploy_cfg = "/usr/local/etc/sing-box/.deployment_config"
        if os.path.exists(deploy_cfg):
            try:
                with open(deploy_cfg) as dc:
                    for line in dc:
                        if line.startswith("DEFAULT_REGION="):  # Parse region from config
                            # Strip whitespace and surrounding quotes
                            val = line.strip().split("=", 1)[1].strip()
                            DEFAULT_REGION = val.strip('\'"').lower()
                            break
            except (IOError, OSError, ValueError):
                pass
    if not DEFAULT_REGION:
        DEFAULT_REGION = "jp"
    
    if not os.path.exists(CONFIG):
        print(f"ERROR: config file not found: {CONFIG}", file=sys.stderr)
        sys.exit(1)
    
    try:
        with open(CONFIG, "r", encoding="utf-8") as f:
            cfg = json.load(f)
    except Exception as e:
        print(f"ERROR: failed to read config file: {e}", file=sys.stderr)
        sys.exit(1)

    # Region display names
    REGION_NAMES = {
        "hk": "🇭🇰 香港", "tw": "🇹🇼 台湾", "jp": "🇯🇵 日本",
        "sg": "🇸🇬 新加坡", "us": "🇺🇸 美国", "kr": "🇰🇷 韩国",
        "gb": "🇬🇧 英国", "de": "🇩🇪 德国", "ca": "🇨🇦 加拿大",
        "au": "🇦🇺 澳大利亚", "in": "🇮🇳 印度", "tr": "🇹🇷 土耳其",
    }

    # Exclude info/traffic nodes by keyword
    EXCLUDE_KEYWORDS = ["流量", "过期", "剩余", "Expire", "Traffic", "官网", "网址", "地址"]

    def is_regional_indicator(c):
        return 0x1F1E6 <= ord(c) <= 0x1F1FF

    # Pre-compile regex for two-letter country code boundary match
    CC_PATTERN = re.compile(r'\b([A-Z]{2})\b')

    def flag_to_cc(s):
        # Match by region name first
        lower_s = s.lower()
        for key, cc in NAME_CC_MAP.items():
            if key in lower_s:
                return cc
                
        # Match by regional indicator emoji
        s = s.lstrip()
        if len(s) >= 2:
            a, b = s[0], s[1]
            if is_regional_indicator(a) and is_regional_indicator(b):
                cc = chr(ord('A') + (ord(a) - 0x1F1E6)) + chr(ord('A') + (ord(b) - 0x1F1E6))
                return cc.lower()
                
        # Match two-letter uppercase boundary word via pre-compiled regex
        match = CC_PATTERN.search(s)
        if match:
            return match.group(1).lower()
            
        return None

    outbounds = cfg.get("outbounds", [])
    node_tags = []
    
    for ob in outbounds:
        t = ob.get("type")
        tag = ob.get("tag", "")
        # P2 修复：同时排除 "block" 类型，防止其出现在 urltest 分组中
        if not tag or t in ("direct", "block", "selector", "urltest"):
            continue
        if any(kw in tag for kw in EXCLUDE_KEYWORDS):
            continue
        node_tags.append(tag)

    # Early return if no proxy nodes found (prevents IndexError downstream)
    if not node_tags:
        print("WARN: no proxy nodes found in config, skipping region group generation", file=sys.stderr)
        return

    groups = defaultdict(list)
    for tag in node_tags:
        cc = flag_to_cc(tag) or "other"
        groups[cc].append(tag)

    region_urltests = []
    
    # Global auto-select group
    if node_tags:
        region_urltests.append({
            "type": "urltest", "tag": "🌏 全局自动", "outbounds": node_tags,
            "url": "https://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 50
        })

    # Per-region urltest groups
    for cc in sorted(groups.keys()):
        if cc == "other": continue
        tag = REGION_NAMES.get(cc, f"🌐 {cc.upper()}")
        region_urltests.append({
            "type": "urltest", "tag": tag, "outbounds": groups[cc],
            "url": "https://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 50
        })

    # Catch-all region group
    if "other" in groups:
        region_urltests.append({
            "type": "urltest", "tag": "🌍 其他地区", "outbounds": groups["other"],
            "url": "https://www.gstatic.com/generate_204", "interval": "3m", "tolerance": 50
        })

    # Build or update the proxy selector outbound
    proxy = next((ob for ob in outbounds if ob.get("type") == "selector" and ob.get("tag") == "🚀 节点选择"), None)
    if proxy is None:
        proxy = {"type": "selector", "tag": "🚀 节点选择", "outbounds": []}
        outbounds.insert(0, proxy)

    region_tags = [u["tag"] for u in region_urltests]
    
    # Keep manual node tags, remove stale region tags to avoid duplicates
    original_outbounds = proxy.get("outbounds", [])
    filtered_outbounds = []
    
    # Strip old auto-generated region prefixes (we regenerated them above)
    old_region_prefixes = ("🌏", "🇭🇰", "🇹🇼", "🇯🇵", "🇸🇬", "🇺🇸", "🇰🇷", "🇬🇧", "🇩🇪", "🇨🇦", "🇦🇺", "🇮🇳", "🇹🇷", "🌍", "🌐")
    
    for tag in original_outbounds:
        if tag == "direct" or tag == "auto" or str(tag).startswith(old_region_prefixes):
            continue
        filtered_outbounds.append(tag)
        
    # Merge: region groups first, then individual nodes, then direct
    final_proxy_outbounds = region_tags + filtered_outbounds
    if "direct" not in final_proxy_outbounds:
        final_proxy_outbounds.append("direct")
        
    proxy["outbounds"] = final_proxy_outbounds

    # Set default region
    if DEFAULT_REGION == "auto" and "🌏 全局自动" in region_tags:
        proxy["default"] = "🌏 全局自动"
    else:
        default_tag = REGION_NAMES.get(DEFAULT_REGION, f"🌐 {DEFAULT_REGION.upper()}")
        if default_tag in region_tags:
            proxy["default"] = default_tag
        else:
            if region_tags:
                proxy["default"] = "🌏 全局自动" if "🌏 全局自动" in region_tags else region_tags[0]

    # Ensure a direct outbound exists
    if not any(ob.get("type") == "direct" and ob.get("tag") == "direct" for ob in outbounds):
        outbounds.append({"type": "direct", "tag": "direct"})

    # Remove old region urltest outbounds before reinserting
    outbounds = [ob for ob in outbounds 
                 if not (ob.get("type") == "urltest" and ob.get("tag", "").startswith(("🌏", "🇭🇰", "🇹🇼", "🇯🇵", "🇸🇬", "🇺🇸", "🇰🇷", "🇬🇧", "🇩🇪", "🇨🇦", "🇦🇺", "🇮🇳", "🇹🇷", "🌍", "🌐")))]

    cfg["outbounds"] = region_urltests + outbounds

    tmp = CONFIG + ".tmp"
    with open(tmp, "w", encoding="utf-8") as f:
      json.dump(cfg, f, ensure_ascii=False, indent=2)
    os.replace(tmp, CONFIG)

    print(f"OK: generated {len(region_urltests)} region groups")
    if "default" in proxy:
        print(f"OK: default region: {proxy['default']}")

if __name__ == "__main__":
    main()
