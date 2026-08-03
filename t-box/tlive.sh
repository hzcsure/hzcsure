#!/usr/bin/env bash
# tlive.sh — test all nodes, export alive nodes as share-link URIs
# Usage: ./tlive.sh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SING_BOX="./sing-box"
CONFIG="config.json"
API="http://127.0.0.1:9090"
DELAY_URL="${DELAY_URL:-http://www.gstatic.com/generate_204}"
DELAY_TIMEOUT="${DELAY_TIMEOUT:-1000}"
MAX_JOBS="${MAX_JOBS:-10}"
ALIVE_TMP="alive_nodes-1.txt"
ALIVE_FILE="alive_nodes.txt"

RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m' CYAN='\033[0;36m' BOLD='\033[1m' RESET='\033[0m'

[ ! -f "$CONFIG" ] && { echo "ERROR: $CONFIG not found, run update.sh first"; exit 1; }
[ ! -x "$SING_BOX" ] && { chmod +x "$SING_BOX" 2>/dev/null || true; }

_api_get() {
    # curl-level safety net: max-time = delay_timeout + 2s buffer
    local max_s=$((DELAY_TIMEOUT / 1000 + 2))
    curl -sf --retry 1 --max-time "$max_s" --connect-timeout 3 "$API$1" 2>/dev/null || echo '{"delay":null}'
}
_url_encode() { printf '%s' "$1" | jq -sRr '@uri'; }

# ═══ Export sing-box JSON → share-link URIs (ported from tvproxy-url --export) ═══
_export_uris() {
    local tmp_config="$1"
    jq -r '.outbounds[] | select(.type!="selector" and .type!="direct" and .type!="block" and .type!="dns") |
      if .type == "vmess" then
        "vmess://" + (
          { v:"2", ps:.tag, add:.server, port:(.server_port|tostring),
            id:.uuid, aid:((.alter_id//0)|tostring),
            scy:(.security//"auto"),
            net:((.transport.type//"tcp")),
            host:((.transport.headers.Host//(.tls.server_name//.server))),
            path:((.transport.path//"/")),
            tls:(if (.tls.enabled//false) then "tls" else "" end),
            sni:((.tls.server_name//"")),
            fp:(if (.tls.utls.enabled//false) then .tls.utls.fingerprint//"" else "" end),
            alpn:(if .tls.alpn then (.tls.alpn|join(",")) else "" end),
            allowInsecure:(.tls.insecure//false)
          } | tojson | @base64
        )
      elif .type == "vless" then
        "vless://" + .uuid + "@" + .server + ":" + (.server_port|tostring) +
        "?type=" + ((.transport.type//"tcp")) +
        "&security=" + (if (.tls.reality.enabled//false) then "reality" elif (.tls.enabled//false) then "tls" else "none" end) +
        "&encryption=none" +
        (if (.flow//"")!="" then "&flow=" + .flow else "" end) +
        (if (.tls.server_name//"")!="" then "&sni=" + (.tls.server_name|@uri) else "" end) +
        (if (.tls.utls.enabled//false) then "&fp=" + (.tls.utls.fingerprint//"chrome") else "" end) +
        (if (.tls.reality.public_key//"")!="" then "&pbk=" + (.tls.reality.public_key|@uri) else "" end) +
        (if (.tls.reality.short_id//"")!="" then "&sid=" + (.tls.reality.short_id|@uri) else "" end) +
        (if (.transport.headers.Host//"")!="" then "&host=" + (.transport.headers.Host|@uri) else "" end) +
        "&path=" + (((.transport.path//"/"))|@uri) +
        "#" + (.tag|@uri)
      elif .type == "trojan" then
        "trojan://" + ((.password//"")|@uri) + "@" + .server + ":" + (.server_port|tostring) +
        "?security=tls" +
        "&type=" + ((.transport.type//"tcp")) +
        "&sni=" + (((.tls.server_name//.server))|@uri) +
        "&allowInsecure=" + (if (.tls.insecure//false) then "1" else "0" end) +
        (if ((.transport.type//""))=="ws" then
          "&host=" + (((.transport.headers.Host//.server))|@uri) +
          "&path=" + (((.transport.path//"/"))|@uri)
        elif ((.transport.type//""))=="grpc" then
          "&serviceName=" + ((.transport.service_name//"gRPC"))
        else "" end) +
        (if (.flow//"")!="" then "&flow=" + .flow else "" end) +
        (if (.tls.utls.enabled//false) then "&fp=" + (.tls.utls.fingerprint//"chrome") else "" end) +
        "#" + (.tag|@uri)
      elif .type == "hysteria2" then
        "hysteria2://" + ((.password//"")|@uri) + "@" + .server + ":" + (.server_port|tostring) +
        "?insecure=" + (if (.tls.insecure//false) then "1" else "0" end) +
        "&sni=" + (((.tls.server_name//.server))|@uri) +
        (if .up_mbps then "&upmbps=" + (.up_mbps|tostring) else "" end) +
        (if .down_mbps then "&downmbps=" + (.down_mbps|tostring) else "" end) +
        (if .obfs.type then "&obfs=" + .obfs.type + "&obfs-password=" + ((.obfs.password//"")|@uri) else "" end) +
        "#" + (.tag|@uri)
      elif .type == "shadowsocks" then
        "ss://" + ([.method,(.password//"")]|join(":")|@base64) +
        "@" + .server + ":" + (.server_port|tostring) +
        "#" + (.tag|@uri)
      elif .type == "tuic" then
        "tuic://" + ((.uuid//"")|@uri) + ":" + ((.password//"")|@uri) +
        "@" + .server + ":" + (.server_port|tostring) +
        "?congestion_control=" + ((.congestion_control//"bbr")) +
        "&udp_relay_mode=" + ((.udp_relay_mode//"native")) +
        "&alpn=" + (((.tls.alpn[0]//"h3"))|@uri) +
        (if (.tls.server_name//"")!="" then "&sni=" + (.tls.server_name|@uri) else "" end) +
        "&allow_insecure=" + (if (.tls.insecure//false) then "1" else "0" end) +
        "#" + (.tag|@uri)
      elif .type == "anytls" then
        "anytls://" + ((.password//.uuid//"")|@uri) + "@" + .server + ":" + (.server_port|tostring) +
        "?sni=" + (((.tls.server_name//.server))|@uri) +
        "&insecure=" + (if (.tls.insecure//false) then "1" else "0" end) +
        "&type=" + ((.transport.type//"tcp")) +
        (if (.transport.headers.Host//"")!="" then "&host=" + (.transport.headers.Host|@uri) else "" end) +
        "&path=" + (((.transport.path//"/"))|@uri) +
        "#" + (.tag|@uri)
      else empty
    end' "$tmp_config" 2>/dev/null
}

# ═══ Main ═══

echo "=== tlive: Test All + Export Alive ==="
echo ""

# ── 1. Start sing-box ──
echo -n "starting sing-box ... "
ENABLE_DEPRECATED_LEGACY_DNS_SERVERS=true \
ENABLE_DEPRECATED_MISSING_DOMAIN_RESOLVER=true \
"$SING_BOX" run -c "$CONFIG" > sing-box.log 2>&1 &
SB_PID=$!
trap "kill $SB_PID 2>/dev/null; wait $SB_PID 2>/dev/null" EXIT

for i in $(seq 1 15); do
    if _api_get "/version" >/dev/null 2>&1; then
        echo -e "${GREEN}OK${RESET} (pid=$SB_PID)"
        break
    fi
    [ "$i" -eq 15 ] && { echo -e "${RED}FAILED${RESET}"; cat sing-box.log; exit 1; }
    sleep 1
done

# ── 2. Get all nodes ──
mapfile -t NODES < <(_api_get "/proxies/proxy" | jq -r '
  [.all | to_entries[] | select(.key!="proxy" and .key!="direct")]
  | sort_by(.key) | .[].value')

TOTAL=${#NODES[@]}
[ "$TOTAL" -eq 0 ] && { echo "ERROR: no nodes in config"; exit 1; }

# Build type map
declare -A TYPE_MAP
while IFS=$'\t' read -r tag tp; do
    TYPE_MAP["$tag"]="$tp"
done < <(jq -r '.outbounds[] | "\(.tag)\t\(.type)"' "$CONFIG" 2>/dev/null)

echo "testing $TOTAL nodes (max $MAX_JOBS concurrent, timeout ${DELAY_TIMEOUT}ms)..."
echo "---"

# ── 3. Concurrent test ──
TMPDIR=$(mktemp -d)
trap "rm -rf '$TMPDIR'; kill $SB_PID 2>/dev/null; wait $SB_PID 2>/dev/null" EXIT

pids=()
for idx in $(seq 0 $((TOTAL - 1))); do
    node="${NODES[$idx]}"
    (
        enc=$(_url_encode "$node")
        tp="${TYPE_MAP[$node]:-?}"
        delay=$(_api_get "/proxies/$enc/delay?url=$DELAY_URL&timeout=$DELAY_TIMEOUT" 2>/dev/null \
            | jq -r '.delay // "timeout"')
        if [ -z "$delay" ] || [ "$delay" = "timeout" ] || [ "$delay" = "0" ]; then
            printf '99999\t%s\t%s\n' "$node" "$tp" > "$TMPDIR/result_${idx}"
            printf "  %-45s ${RED}timeout${RESET}\n" "$node"
        else
            printf '%s\t%s\t%s\n' "$delay" "$node" "$tp" > "$TMPDIR/result_${idx}"
            color="$GREEN"; [ "$delay" -gt 500 ] && color="$YELLOW"
            printf "  %-45s ${color}%sms${RESET}\n" "$node" "$delay"
        fi
    ) &
    pids+=($!)
    # FIFO: when MAX_JOBS active, wait for oldest to finish
    if [ ${#pids[@]} -ge "$MAX_JOBS" ]; then
        wait "${pids[0]}" 2>/dev/null || true
        pids=("${pids[@]:1}")
    fi
done
# Wait for remaining
for pid in "${pids[@]}"; do wait "$pid" 2>/dev/null || true; done

# ── 4. Collect alive nodes ──
echo "---"
alive_sorted=$(sort -t$'\t' -k1 -n "$TMPDIR"/result_* 2>/dev/null | grep -v '^99999')
alive_count=$(echo "$alive_sorted" | grep -c . 2>/dev/null || echo 0)
dead_count=$((TOTAL - alive_count))

echo -e "alive: ${GREEN}${alive_count}${RESET} / ${TOTAL}  dead: ${RED}${dead_count}${RESET}"

if [ "$alive_count" -eq 0 ]; then
    echo "no alive nodes, nothing to export"
    exit 0
fi

# ── 5. Export alive nodes ──
echo ""
echo "=== Exporting alive nodes ==="

# Build filtered config (alive nodes only, sorted by delay)
sorted_tags=$(echo "$alive_sorted" | awk -F'\t' '{print $2}')
tag_json=$(echo "$sorted_tags" | jq -R . | jq -s .)

tmp_filtered="$TMPDIR/filtered_config.json"
jq --argjson tags "$tag_json" \
  '.outbounds |= ([.[] | select(.tag as $t | $tags | index($t))])
   | .outbounds |= ([$tags[] as $tag | .[] | select(.tag==$tag)])' \
  "$CONFIG" > "$tmp_filtered"

_export_uris "$tmp_filtered" > "$ALIVE_TMP"

if [ -s "$ALIVE_TMP" ]; then
    lines=$(wc -l < "$ALIVE_TMP")
    echo "exported $lines alive nodes to $ALIVE_TMP"

    # Replace alive_nodes.txt
    mv "$ALIVE_TMP" "$ALIVE_FILE"
    echo "updated $ALIVE_FILE"

    # Show top 5
    echo ""
    echo "Top 5:"
    head -5 "$ALIVE_FILE" | while IFS= read -r uri; do
        echo "  ${uri:0:80}..."
    done
else
    echo "export produced empty file"
    rm -f "$ALIVE_TMP"
fi

# ── 6. Summary ──
echo ""
echo "=== Done ==="
echo "alive_nodes.txt: $alive_count nodes"
echo "::notice::tlive: $alive_count/$TOTAL alive, exported to $ALIVE_FILE"
