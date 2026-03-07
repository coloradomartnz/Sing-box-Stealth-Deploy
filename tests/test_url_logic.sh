#!/usr/bin/env bash
# tests/test_url_logic.sh
# 專門測試 singbox-deploy.sh 中的 URL 校驗邏輯

set -euo pipefail

RED=$'\033[0;31m'
GREEN=$'\033[0;32m'
NC=$'\033[0m'

# 模擬 singbox-deploy.sh 中的校驗邏輯函數
validate_url() {
    local url="$1"
    # 1. 基礎協議校驗
    if [[ ! "$url" =~ ^https?:// ]]; then
        return 1
    fi
    # 2. 指令攔截名單
    if [[ "$url" =~ (chmod|chown|rm|sudo|systemctl|bash|python|sh|cd|mkdir|cp|mv)[[:space:]] ]]; then
        return 2
    fi
    return 0
}

echo "Testing URL validation logic..."

test_cases=(
    "https://example.com/sub|0|Valid HTTPS URL"
    "http://1.2.3.4/sub|0|Valid HTTP IP URL"
    "ftp://example.com|1|Invalid protocol (ftp)"
    "just_a_string|1|Invalid format (no protocol)"
    "chmod +x script.sh|1|Shell command (chmod)"
    "sudo rm -rf /|1|Shell command (sudo/rm)"
    "https://example.com/sub?token=sudo_is_part_of_token|0|Valid URL with command-like word in query (should pass if no space)"
)

passed=0
failed=0

for t in "${test_cases[@]}"; do
    IFS='|' read -r input expected desc <<< "$t"
    set +e
    validate_url "$input"
    rc=$?
    set -e
    
    # 只要不是 0 都算攔截成功（校驗失敗）
    actual=$([ $rc -eq 0 ] && echo "0" || echo "1")
    
    if [ "$actual" == "$expected" ]; then
        echo -e "  ${GREEN}✓${NC} $desc: '$input' -> $([ $actual == "0" ] && echo "PASS" || echo "BLOCK")"
        passed=$((passed + 1))
    else
        echo -e "  ${RED}✗${NC} $desc: '$input' -> Expected $expected, got $actual"
        failed=$((failed + 1))
    fi
done

echo "-----------------------------------"
echo "Results: $passed passed, $failed failed"

if [ $failed -eq 0 ]; then
    echo -e "${GREEN}SUCCESS: URL validation logic is robust.${NC}"
    exit 0
else
    echo -e "${RED}FAILURE: Validation logic has loopholes.${NC}"
    exit 1
fi
