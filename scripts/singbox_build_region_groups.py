#!/usr/bin/env python3
"""
Scan proxy node tags for region emoji flags and generate per-region urltest outbounds
"""
import json, os, sys, fcntl, time, re
from collections import defaultdict

# Single source of truth for region metadata.
# Each entry: cc -> {"names": [keywords...], "display": "display string"}
# "names" are matched case-insensitively as substrings of the node tag.
REGION_DB = {
    "hk": {"names": ["香港", "hk", "hongkong", "hong kong"], "display": "🇭🇰 香港"},
    "tw": {"names": ["台湾", "tw", "taiwan"],                 "display": "🇹🇼 台湾"},
    "jp": {"names": ["日本", "jp", "japan"],                  "display": "🇯🇵 日本"},
    "sg": {"names": ["狮城", "sg", "singapore", "新加坡"],    "display": "🇸🇬 新加坡"},
    "us": {"names": ["美国", "us", "america", "united states"], "display": "🇺🇸 美国"},
    "kr": {"names": ["韩国", "kr", "korea"],                  "display": "🇰🇷 韩国"},
    "gb": {"names": ["英国", "uk", "gb"],                     "display": "🇬🇧 英国"},
    "de": {"names": ["德国", "de", "germany"],                "display": "🇩🇪 德国"},
    "fr": {"names": ["法国", "fr", "france"],                 "display": "🇫🇷 法国"},
    "tr": {"names": ["土耳其", "tr", "turkey"],               "display": "🇹🇷 土耳其"},
    "in": {"names": ["印度", "india"],                        "display": "🇮🇳 印度"},
    "au": {"names": ["澳洲", "澳大利亚", "au", "australia"],  "display": "🇦🇺 澳大利亚"},
    "ar": {"names": ["阿根廷", "ar", "argentina"],            "display": "🇦🇷 阿根廷"},
    "nl": {"names": ["荷兰", "nl", "netherlands"],            "display": "🇳🇱 荷兰"},
    "ru": {"names": ["俄罗斯", "ru", "russia"],               "display": "🇷🇺 俄罗斯"},
    "id": {"names": ["印尼", "indonesia"],                    "display": "🇮🇩 印尼"},
    "br": {"names": ["巴西", "br", "brazil"],                 "display": "🇧🇷 巴西"},
    "ca": {"names": ["加拿大", "加拿", "ca", "canada"],       "display": "🇨🇦 加拿大"},
}

# Pre-compile a single regex per region: alternation of all keywords.
# Matched case-insensitively via re.IGNORECASE.
_REGION_PATTERNS = {
    cc: re.compile(
        "|".join(re.escape(kw) for kw in sorted(meta["names"], key=len, reverse=True)),
        re.IGNORECASE,
    )
    for cc, meta in REGION_DB.items()
}

# Pre-compile two-letter uppercase boundary word pattern (fallback)
_CC_PATTERN = re.compile(r'\b([A-Z]{2})\b')

# Regional indicator emoji range
_RI_START = 0x1F1E6
_RI_END   = 0x1F1FF


def _flag_emoji_to_cc(s):
    """Fast path: decode regional indicator emoji pair at start of string."""
    s = s.lstrip()
    if len(s) >= 2:
        a, b = s[0], s[1]
        oa, ob = ord(a), ord(b)
        if _RI_START <= oa <= _RI_END and _RI_START <= ob <= _RI_END:
            return chr(ord('A') + (oa - _RI_START)) + chr(ord('A') + (ob - _RI_START))
    return None


def flag_to_cc(tag):
    """Map a proxy node tag string to a two-letter country code (lowercase), or None."""
    # 1. Emoji flag fast path (O(1))
    emoji_cc = _flag_emoji_to_cc(tag)
    if emoji_cc:
        lcc = emoji_cc.lower()
        if lcc in REGION_DB:
            return lcc

    # 2. Pre-compiled keyword match (O(len(tag)) per region, but uses compiled DFA)
    for cc, pattern in _REGION_PATTERNS.items():
        if pattern.search(tag):
            return cc

    # 3. Two-letter uppercase boundary word (generic fallback)
    m = _CC_PATTERN.search(tag)
    if m:
        lcc = m.group(1).lower()
        if lcc in REGION_DB:
            return lcc

    return None


def acquire_lock(lockfile, timeout=300):
    """Acquire an exclusive file lock with stale-lock detection"""
    pid_file = f"{lockfile}.pid"

    try:
        lock = open(lockfile, 'w')
    except IOError as e:
        print(f"ERROR: cannot open lock file {lockfile}: {e}", file=sys.stderr)
        return None

    start_time = time.time()

    while True:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)

            try:
                with open(pid_file, 'w') as pf:
                    pf.write(str(os.getpid()))
            except IOError as e:
                print(f"WARN: cannot write PID file {pid_file}: {e}", file=sys.stderr)

            import atexit
            atexit.register(lambda: cleanup_lock(pid_file))

            return lock

        except IOError:
            elapsed = time.time() - start_time

            if os.path.exists(pid_file):
                try:
                    with open(pid_file, 'r') as pf:
                        lock_pid = int(pf.read().strip())
                    try:
                        os.kill(lock_pid, 0)
                        if elapsed >= timeout:
                            print(f"ERROR: lock held by PID {lock_pid}, timed out after {timeout}s",
                                  file=sys.stderr)
                            return None
                    except OSError:
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
                        if line.startswith("DEFAULT_REGION="):
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

    # Exclude info/traffic nodes by keyword
    EXCLUDE_KEYWORDS = ["流量", "过期", "剩余", "Expire", "Traffic", "官网", "网址", "地址"]

    outbounds = cfg.get("outbounds", [])
    node_tags = []

    for ob in outbounds:
        t = ob.get("type")
        tag = ob.get("tag", "")
        if not tag or t in ("direct", "block", "selector", "urltest"):
            continue
        if any(kw in tag for kw in EXCLUDE_KEYWORDS):
            continue
        node_tags.append(tag)

    # Early return if no proxy nodes found
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

    # Per-region urltest groups (sorted for deterministic output)
    for cc in sorted(groups.keys()):
        if cc == "other":
            continue
        display = REGION_DB.get(cc, {}).get("display", f"🌐 {cc.upper()}")
        region_urltests.append({
            "type": "urltest", "tag": display, "outbounds": groups[cc],
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

    # Strip old auto-generated region prefixes to avoid duplicates
    old_region_prefixes = ("🌏", "🇭🇰", "🇹🇼", "🇯🇵", "🇸🇬", "🇺🇸", "🇰🇷", "🇬🇧", "🇩🇪", "🇨🇦",
                           "🇦🇺", "🇮🇳", "🇹🇷", "🌍", "🌐", "🇫🇷", "🇳🇱", "🇷🇺", "🇮🇩", "🇧🇷",
                           "🇦🇷")

    filtered_outbounds = [
        tag for tag in proxy.get("outbounds", [])
        if tag not in ("direct", "auto") and not str(tag).startswith(old_region_prefixes)
    ]

    proxy["outbounds"] = region_tags + filtered_outbounds
    if "direct" not in proxy["outbounds"]:
        proxy["outbounds"].append("direct")

    # Set default region
    if DEFAULT_REGION == "auto" and "🌏 全局自动" in region_tags:
        proxy["default"] = "🌏 全局自动"
    else:
        default_display = REGION_DB.get(DEFAULT_REGION, {}).get("display", f"🌐 {DEFAULT_REGION.upper()}")
        if default_display in region_tags:
            proxy["default"] = default_display
        elif region_tags:
            proxy["default"] = "🌏 全局自动" if "🌏 全局自动" in region_tags else region_tags[0]

    # Ensure a direct outbound exists
    if not any(ob.get("type") == "direct" and ob.get("tag") == "direct" for ob in outbounds):
        outbounds.append({"type": "direct", "tag": "direct"})

    # Remove old region urltest outbounds before reinserting
    outbounds = [ob for ob in outbounds
                 if not (ob.get("type") == "urltest"
                         and ob.get("tag", "").startswith(old_region_prefixes))]

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
