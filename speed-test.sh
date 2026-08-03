#!/usr/bin/env bash
# speed-test.sh — test all sing-box outbound nodes via Clash API
# Usage: ./speed-test.sh [config.json] [--json]
set -euo pipefail

CONFIG="${1:-config.json}"
JSON_OUT="${2:-}"
DELAY_URL="${DELAY_URL:-http://www.gstatic.com/generate_204}"
DELAY_TIMEOUT="${DELAY_TIMEOUT:-2000}"
MAX_JOBS="${MAX_JOBS:-10}"
API="http://127.0.0.1:9090"
SING_BOX="${SING_BOX:-sing-box}"

# ─── helpers ───
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m'
CYAN='\033[0;36m' BOLD='\033[1m' RESET='\033[0m'

_api_get() { curl -sf --retry 2 --connect-timeout 3 "$API$1" 2>/dev/null; }
_url_encode() { printf '%s' "$1" | jq -sRr '@uri'; }

echo "=== sing-box Speed Test ==="
echo "config : $CONFIG"
echo "url    : $DELAY_URL"
echo "timeout: ${DELAY_TIMEOUT}ms"
echo ""

# 1. Start sing-box
echo -n "starting sing-box... "
ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true \
ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true \
"$SING_BOX" run -c "$CONFIG" &
SB_PID=$!
trap "kill $SB_PID 2>/dev/null; wait $SB_PID 2>/dev/null" EXIT

# Wait for API
for i in $(seq 1 15); do
    if _api_get "/version" >/dev/null 2>&1; then
        echo -e "${GREEN}OK${RESET} (pid=$SB_PID)"
        break
    fi
    [ "$i" -eq 15 ] && { echo -e "${RED}FAILED${RESET}"; exit 1; }
    sleep 1
done

# 2. Get all proxy tags
echo ""
mapfile -t NODES < <(_api_get "/proxies/proxy" | jq -r '
  [.all | to_entries[] | select(.key != "proxy" and .key != "direct")]
  | sort_by(.key) | .[].value')

TOTAL=${#NODES[@]}
echo "testing $TOTAL nodes (max $MAX_JOBS concurrent)..."
echo "---"

# 3. Build type map
declare -A TYPE_MAP
while IFS=$'\t' read -r tag tp; do
    TYPE_MAP["$tag"]="$tp"
done < <(jq -r '.outbounds[] | "\(.tag)\t\(.type)"' "$CONFIG" 2>/dev/null)

# 4. Concurrent delay tests
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'; kill $SB_PID 2>/dev/null; wait $SB_PID 2>/dev/null" EXIT

running=0
for idx in $(seq 0 $((TOTAL - 1))); do
    node="${NODES[$idx]}"
    (
        enc=$(_url_encode "$node")
        tp="${TYPE_MAP[$node]:-?}"
        delay=$(_api_get "/proxies/$enc/delay?url=$DELAY_URL&timeout=$DELAY_TIMEOUT" 2>/dev/null \
            | jq -r '.delay // "timeout"')
        if [ -z "$delay" ] || [ "$delay" = "timeout" ] || [ "$delay" = "0" ]; then
            printf '99999\t%s\t%s\n' "$node" "$tp" > "$TMPDIR/result_${idx}"
            printf "  [%3d] %-40s ${RED}timeout${RESET}\n" "$idx" "$node"
        else
            printf '%s\t%s\t%s\n' "$delay" "$node" "$tp" > "$TMPDIR/result_${idx}"
            color="$GREEN"
            [ "$delay" -gt 500 ] && color="$YELLOW"
            printf "  [%3d] %-40s ${color}%sms${RESET}\n" "$idx" "$node" "$delay"
        fi
    ) &
    running=$((running + 1))
    if [ "$running" -ge "$MAX_JOBS" ]; then
        wait -n 2>/dev/null || true
        running=$((running - 1))
    fi
done
wait

# 5. Summary
echo "---"
alive=$(grep -vc '^99999' "$TMPDIR"/result_* 2>/dev/null || echo 0)
dead=$(grep -c '^99999' "$TMPDIR"/result_* 2>/dev/null || echo 0)
echo -e "alive: ${GREEN}${alive}${RESET} / ${TOTAL}  dead: ${RED}${dead}${RESET}"

if [ "$alive" -gt 0 ]; then
    echo ""
    echo "=== Top 10 ==="
    sort -t$'\t' -k1 -n "$TMPDIR"/result_* 2>/dev/null | grep -v '^99999' | head -10 | \
    while IFS=$'\t' read -r ms tag tp; do
        printf "  %-40s %-10s %s ms\n" "$tag" "[$tp]" "$ms"
    done
fi

# 6. JSON output if requested
if [ "$JSON_OUT" = "--json" ]; then
    echo ""
    echo "--- JSON ---"
    {
        echo '['
        first=true
        sort -t$'\t' -k1 -n "$TMPDIR"/result_* 2>/dev/null | while IFS=$'\t' read -r ms tag tp; do
            $first && first=false || echo ','
            if [ "$ms" = "99999" ]; then
                echo -n "  {\"tag\":\"$tag\",\"type\":\"$tp\",\"delay\":null,\"alive\":false}"
            else
                echo -n "  {\"tag\":\"$tag\",\"type\":\"$tp\",\"delay\":$ms,\"alive\":true}"
            fi
        done
        echo ''
        echo ']'
    } | jq .
fi

# Summary line for CI
echo ""
echo "::notice::speed-test: $alive/$TOTAL alive, $dead dead"

[ "$alive" -eq 0 ] && exit 1
exit 0
