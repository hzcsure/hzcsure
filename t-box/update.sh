#!/usr/bin/env bash
# update.sh — fetch subscriptions + generate sing-box config
# Supports: Clash YAML, URI format (vmess/vless/trojan/hysteria2/ss/tuic/socks), base64, file://
# Usage: ./update.sh [--local]  # --local = rebuild from cached nodes only
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

SUB_URLS="${SUB_URLS:-sub_urls}"
OUT_CONFIG="config.json"
CACHE_FILE="nodes_cache.json"
PROXY_PORT="${PROXY_PORT:-1080}"
LOG_LEVEL="error"
DEFAULT_UA="${DEFAULT_UA:-ClashforWindows/0.20.39}"
DELAY_URL="${DELAY_URL:-http://www.gstatic.com/generate_204}"
BLOCKLIST="${BLOCKLIST:-(流量|套餐|重置|建议|官网|http|剩余|到期)}"
LOCAL_BUILD=false
[ "${1:-}" = "--local" ] && LOCAL_BUILD=true

# ─── helpers ───
RED='\033[0;31m' GREEN='\033[0;32m' YELLOW='\033[0;33m'
CYAN='\033[0;36m' BOLD='\033[1m' RESET='\033[0m'
_url_decode() { printf '%b' "${1//%/\\x}"; }
_first_line() { sed -n '/^[[:space:]]*$/d; 1p' 2>/dev/null || true; }
_fetch_url() { curl -sfL --connect-timeout 15 --max-time 30 -A "${2:-$DEFAULT_UA}" "$1" 2>/dev/null || true; }

# ─── URI parsers (ported from tvproxy-url) ───

_transport_jq() {
    local type="$1" host="$2" path="$3"
    case "$type" in
        ws) jq -n -c --arg host "$host" --arg path "${path:-/}" \
              '{type:"ws",path:$path,headers:{Host:$host}}' ;;
        grpc) jq -n -c --arg svc "${path:-gRPC}" \
              '{type:"grpc",service_name:$svc}' ;;
        http|h2) jq -n -c --arg host "$host" --arg path "${path:-/}" \
              '{type:"http",host:[$host],path:$path}' ;;
        httpupgrade) jq -n -c --arg host "$host" --arg path "${path:-/}" \
              '{type:"httpupgrade",host:$host,path:$path}' ;;
        *) echo '{}' ;;
    esac
}

_tls_singbox() {
    local sec="$1" sni="$2" fp="$3" pbk="$4" sid="$5" insecure="$6"
    [ "$sec" != "tls" ] && [ "$sec" != "reality" ] && { echo '{}'; return; }
    local utls="" reality=""
    if [ "$sec" = "reality" ]; then
        utls=",utls:{enabled:true,fingerprint:\"${fp:-chrome}\"}"
        [ -n "$pbk" ] && reality=",reality:{enabled:true,public_key:\"$pbk\",short_id:\"${sid:-}\"}"
    elif [ -n "$fp" ]; then
        utls=",utls:{enabled:true,fingerprint:\"$fp\"}"
    fi
    jq -n -c --arg sni "$sni" --argjson insec "${insecure:-0}" \
      "{tls:{enabled:true,server_name:\$sni,insecure:(\$insec==1)${utls}${reality}}}"
}

_parse_vmess() {
    local b64="${1#vmess://}"
    local json; json=$(echo -n "$b64" | base64 -d 2>/dev/null) || return 1
    echo "$json" | jq -c '
      def transport:
        if .net == "ws" then { type:"ws", path:(.path//"/"), headers:{Host:(.host//.add//"")} }
        elif .net == "grpc" then { type:"grpc", service_name:(.path//"gRPC") }
        elif .net == "h2" or .net == "http" then { type:"http", host:[.host//.add//""], path:(.path//"/") }
        else {} end;
      def tls_conf:
        if .tls == "tls" then {
          enabled:true, server_name:(.sni//.host//.add//""),
          insecure:(.["allowInsecure"]//false),
          utls:(if (.fp//"")!="" then {enabled:true,fingerprint:.fp} else {} end)
        } else {} end;
      {
        type:"vmess", tag:(.ps//"unknown"),
        server:(.add//""), server_port:((.port//"443")|tonumber),
        uuid:(.id//""), security:(.scy//"auto"), alter_id:((.aid//"0")|tonumber)
      }
      + (if (transport|has("type")) then {transport:transport} else {} end)
      + (if (tls_conf|has("enabled")) then {tls:tls_conf} else {} end)
    ' 2>/dev/null
}

_parse_vless() {
    local uri="${1#vless://}"; local uuid="${uri%%@*}"; local rest="${uri#*@}"
    local hostport="" query="" fragment=""
    case "$rest" in *\?*) hostport="${rest%%\?*}"; query="${rest#*\?}"; query="${query%%#*}"; [[ "$rest" == *\#* ]] && fragment="${rest##*\#}" ;; *) hostport="${rest%%#*}"; [[ "$rest" == *\#* ]] && fragment="${rest##*\#}" ;; esac
    fragment=$(_url_decode "$fragment")
    local host="${hostport%%:*}"; host="${host%/}"; local port="${hostport##*:}"; [ "$port" = "$host" ] && port="443"

    local type="tcp" security="" sni="" fp="" host_val="" path_val="/" pbk="" sid="" flow="" enc=""
    local oldIFS="$IFS"; IFS='&'
    for param in $query; do
        case "${param%%=*}" in
            type) type="${param#*=}";; security) security="${param#*=}";;
            sni|servername) sni=$(_url_decode "${param#*=}");; fp) fp="${param#*=}";;
            host) host_val=$(_url_decode "${param#*=}");; path) path_val=$(_url_decode "${param#*=}");;
            pbk) pbk="${param#*=}";; sid) sid="${param#*=}";; flow) enc="${param#*=}";;
            encryption) enc="${param#*=}";;
        esac
    done; IFS="$oldIFS"

    local tls_json; tls_json=$(_tls_singbox "$security" "${sni:-$host}" "$fp" "$pbk" "$sid" "0")
    local transport_json; transport_json=$(_transport_jq "$type" "${host_val:-$host}" "${path_val:-/}")
    jq -n -c --arg host "$host" --arg port "$port" --arg uuid "$uuid" \
      --arg tag "${fragment:-unknown}" --arg flow "${enc:-}" \
      '{type:"vless",server:$host,server_port:($port|tonumber),tag:$tag,uuid:$uuid}
       + (if $flow!="" and $flow!="none" then {flow:$flow} else {} end)
       + '"$tls_json"' + '"$transport_json"'' 2>/dev/null
}

_parse_trojan() {
    local uri="${1#trojan://}"; local pass="${uri%%@*}"; pass=$(_url_decode "$pass")
    local rest="${uri#*@}"; local hostport="" query="" fragment=""
    case "$rest" in *\?*) hostport="${rest%%\?*}"; query="${rest#*\?}"; query="${query%%#*}"; [[ "$rest" == *\#* ]] && fragment="${rest##*\#}" ;; *) hostport="${rest%%#*}"; [[ "$rest" == *\#* ]] && fragment="${rest##*\#}" ;; esac
    fragment=$(_url_decode "$fragment")
    local host="${hostport%%:*}"; host="${host%/}"; local port="${hostport##*:}"; [ "$port" = "$host" ] && port="443"

    local sni="$host" insecure="0" type="tcp" host_val="$host" path_val="/" flow="" fp=""
    local oldIFS="$IFS"; IFS='&'
    for param in $query; do
        case "${param%%=*}" in
            sni|servername|peer) sni=$(_url_decode "${param#*=}");;
            allowInsecure|insecure) insecure="${param#*=}";;
            type) type="${param#*=}";; host) host_val=$(_url_decode "${param#*=}");;
            path) path_val=$(_url_decode "${param#*=}");; flow) flow="${param#*=}";; fp) fp="${param#*=}";;
        esac
    done; IFS="$oldIFS"

    local tls_json; tls_json=$(_tls_singbox "tls" "$sni" "$fp" "" "" "$insecure")
    jq -n -c --arg host "$host" --arg port "$port" --arg pass "$pass" \
      --arg tag "${fragment:-unknown}" --arg flow "${flow:-}" \
      '{type:"trojan",server:$host,server_port:($port|tonumber),tag:$tag,password:$pass}
       + (if $flow!="" and $flow!="none" then {flow:$flow} else {} end)
       + '"$tls_json"' + '"$(_transport_jq "$type" "$host_val" "$path_val")"'' 2>/dev/null
}

_parse_hysteria2() {
    local uri="${1#hysteria2://}"; local pass="${uri%%@*}"; local rest="${uri#*@}"
    local hostport="" query="" fragment=""
    case "$rest" in *\?*) hostport="${rest%%\?*}"; query="${rest#*\?}"; query="${query%%#*}"; [[ "$rest" == *\#* ]] && fragment="${rest##*\#}" ;; *) hostport="${rest%%#*}"; [[ "$rest" == *\#* ]] && fragment="${rest##*\#}" ;; esac
    fragment=$(_url_decode "$fragment")
    local host="${hostport%%:*}"; host="${host%/}"; local port="${hostport##*:}"; [ "$port" = "$host" ] && port="443"
    local insecure="0" sni="$host" obfs="" obfs_pw="" auth="" up="50" down="100"
    local oldIFS="$IFS"; IFS='&'
    for param in $query; do
        case "${param%%=*}" in
            insecure|allowInsecure) insecure="${param#*=}";; sni|servername) sni=$(_url_decode "${param#*=}");;
            obfs) obfs="${param#*=}";; obfs-password) obfs_pw=$(_url_decode "${param#*=}");;
            auth) auth="${param#*=}";; upmbps|up) up="${param#*=}";; downmbps|down) down="${param#*=}";;
        esac
    done; IFS="$oldIFS"
    local tls_json; tls_json=$(jq -n -c --arg sni "$sni" --argjson insec "$insecure" \
      '{tls:{enabled:true,server_name:$sni,insecure:($insec==1),alpn:["h3"]}}')
    jq -n -c --arg host "$host" --arg port "$port" --arg pass "$pass" \
      --arg tag "${fragment:-unknown}" --argjson up "${up:-50}" --argjson down "${down:-100}" \
      '{type:"hysteria2",server:$host,server_port:($port|tonumber),tag:$tag,password:$pass,up_mbps:$up,down_mbps:$down}
       + '"$tls_json"'
       + (if "'"$obfs"'"!="" then {obfs:{type:"'"$obfs"'",password:"'"$obfs_pw"'"}}
         elif "'"$auth"'"!="" then {auth_str:"'"$auth"'"} else {} end)' 2>/dev/null
}

_parse_ss() {
    local uri="${1#ss://}"; local fragment=""; [[ "$uri" == *\#* ]] && fragment=$(_url_decode "${uri##*\#}") && uri="${uri%%\#*}"
    local decoded="" pre_at="${uri%%@*}"
    if [[ "$pre_at" =~ ^[A-Za-z0-9+/=]+$ ]]; then decoded=$(echo -n "$pre_at" | base64 -d 2>/dev/null || true); fi
    local method="" password="" host="" port=""
    if [ -n "$decoded" ]; then
        method="${decoded%%:*}"; password="${decoded#*:}"; local hp="${uri#*@}"; host="${hp%%:*}"; port="${hp##*:}"
    else
        local ui="${uri%%@*}"; method="${ui%%:*}"; password="${ui#*:}"; local hp="${uri#*@}"; host="${hp%%:*}"; port="${hp##*:}"
    fi
    [ "$port" = "$host" ] && port="8388"
    jq -n -c --arg host "$host" --arg port "$port" --arg tag "${fragment:-unknown}" \
      --arg m "$method" --arg p "$password" \
      '{type:"shadowsocks",server:$host,server_port:($port|tonumber),tag:$tag,method:$m,password:$p}' 2>/dev/null
}

_parse_tuic() {
    local uri="${1#tuic://}"; local ui="${uri%%@*}"; ui=$(_url_decode "$ui"); local uuid="${ui%%:*}" pass="${ui#*:}"
    local rest="${uri#*@}"; local hostport="" query="" fragment=""
    case "$rest" in *\?*) hostport="${rest%%\?*}"; query="${rest#*\?}"; query="${query%%#*}"; [[ "$rest" == *\#* ]] && fragment="${rest##*\#}" ;; *) hostport="${rest%%#*}"; [[ "$rest" == *\#* ]] && fragment="${rest##*\#}" ;; esac
    fragment=$(_url_decode "$fragment")
    local host="${hostport%%:*}"; host="${host%/}"; local port="${hostport##*:}"; [ "$port" = "$host" ] && port="443"
    local sni="$host" insecure="0" alpn="h3" cong="bbr" udp="native"
    local oldIFS="$IFS"; IFS='&'
    for param in $query; do
        case "${param%%=*}" in
            sni|servername) sni=$(_url_decode "${param#*=}");; allow_insecure|insecure) insecure="${param#*=}";;
            alpn) alpn="${param#*=}";; congestion_control) cong="${param#*=}";; udp_relay_mode) udp="${param#*=}";;
        esac
    done; IFS="$oldIFS"
    jq -n -c --arg host "$host" --arg port "$port" --arg uuid "$uuid" --arg pass "$pass" \
      --arg cong "${cong:-bbr}" --arg udp "${udp:-native}" --arg tag "${fragment:-unknown}" --arg sni "$sni" --arg alpn "$alpn" \
      '{type:"tuic",server:$host,server_port:($port|tonumber),tag:$tag,uuid:$uuid,password:$pass,congestion_control:$cong,udp_relay_mode:$udp,tls:{enabled:true,server_name:$sni,alpn:[$alpn]}}' 2>/dev/null
}

_parse_anytls() {
    local uri="${1#anytls://}"; local pass="${uri%%@*}"; local rest="${uri#*@}"; local hostport="" query="" fragment=""
    case "$rest" in *\?*) hostport="${rest%%\?*}"; query="${rest#*\?}"; query="${query%%#*}"; [[ "$rest" == *\#* ]] && fragment="${rest##*\#}" ;; *) hostport="${rest%%#*}"; [[ "$rest" == *\#* ]] && fragment="${rest##*\#}" ;; esac
    fragment=$(_url_decode "$fragment")
    local host="${hostport%%:*}"; host="${host%/}"; local port="${hostport##*:}"; [ "$port" = "$host" ] && port="443"
    local sni="$host" insecure="0" type="tcp" host_val="" path_val="/"
    local oldIFS="$IFS"; IFS='&'
    for param in $query; do
        case "${param%%=*}" in
            sni|servername) sni=$(_url_decode "${param#*=}");; allowInsecure|insecure) insecure="${param#*=}";;
            type) type="${param#*=}";; host) host_val=$(_url_decode "${param#*=}");; path) path_val=$(_url_decode "${param#*=}");;
        esac
    done; IFS="$oldIFS"
    jq -n -c --arg host "$host" --arg port "$port" --arg pass "$pass" --arg tag "${fragment:-unknown}" \
      '{type:"anytls",server:$host,server_port:($port|tonumber),tag:$tag,password:$pass}
       + '"$(_tls_singbox "tls" "$sni" "" "" "" "$insecure")"'
       + '"$(_transport_jq "$type" "${host_val:-$host}" "${path_val:-/}")"'' 2>/dev/null
}

_parse_uri() {
    local line="$1"; line="${line%$'\r'}"
    case "$line" in
        vmess://*)     _parse_vmess "$line" ;;
        vless://*)     _parse_vless "$line" ;;
        trojan://*)    _parse_trojan "$line" ;;
        hysteria2://*) _parse_hysteria2 "$line" ;;
        anytls://*)    _parse_anytls "$line" ;;
        ss://*)        _parse_ss "$line" ;;
        tuic://*)      _parse_tuic "$line" ;;
        *)             return 1 ;;
    esac
}

# ─── Clash YAML → sing-box (ported from tvproxy-sub jq pipeline) ───

_clash_to_singbox() {
    # stdin: Clash YAML proxies array as JSON
    jq -c '
    [.[] | select(.type != null and .server != null and .port != null and
      (.name | test("'${BLOCKLIST}'")) | not)
    | {
        server,
        server_port: (.port // 443),
        tag: (.name // "unknown")
      }
    # --- transport ---
    + (if .network == "ws" then
        { transport: { type: "ws", path: (.["ws-opts"].path // "/"),
          headers: (if .["ws-opts"].headers then .["ws-opts"].headers else {} end) } }
      elif .network == "grpc" then
        { transport: { type: "grpc", service_name: (.["grpc-opts"]["grpc-service-name"] // "") } }
      elif .network == "h2" or .network == "http" then
        { transport: { type: .network, host: (.["h2-opts"].host // .["http-opts"].host // []) } }
      elif .network == "httpupgrade" then
        { transport: { type: "httpupgrade", host: (.["httpupgrade-opts"].host // ""),
          path: (.["httpupgrade-opts"].path // "/") } }
      else {} end)
    # --- TLS ---
    + (if (.type != "shadowsocks" and .type != "ss" and .type != "vmess") and
         (.tls or .["skip-cert-verify"] or .servername or .sni or .["reality-opts"]) then
        { tls: { enabled: true, server_name: (.servername // .sni // .server // ""),
          insecure: (.["skip-cert-verify"] // false)
        }
        + (if .["client-fingerprint"] then
            { utls: { enabled: true, fingerprint: .["client-fingerprint"] } }
          else {} end)
        + (if .["reality-opts"] then
            { reality: { enabled: true, public_key: (.["reality-opts"]["public-key"] // ""),
              short_id: (.["reality-opts"]["short-id"] // "") } }
          else {} end)
        } else {} end)
    # --- protocol-specific ---
    + if .type == "vless" then
        { type: "vless", uuid } + (if .["reality-opts"] then { flow: (.flow // "xtls-rprx-vision") } else {} end)
      elif .type == "trojan" then
        { type: "trojan", password }
      elif .type == "hysteria" or .type == "hysteria2" then
        { type: "hysteria2", password: (.auth_str // .password // ""),
          up_mbps: (.up // 50), down_mbps: (.down // 100) }
        + (if .obfs and .obfs != "" and .["obfs-password"] and .["obfs-password"] != "" then
            { obfs: { type: .obfs, password: .["obfs-password"] } }
          else {} end)
        + (if .["skip-cert-verify"] then { tls: { enabled: true, server_name: (.sni // .servername // .server // ""), insecure: true, alpn: ["h3"] } } else {} end)
      elif .type == "shadowsocks" or .type == "ss" then
        { type: "shadowsocks", method: (.cipher // "aes-256-gcm"), password: (.password // ""),
          plugin: (if .plugin then .plugin else empty end),
          plugin_opts: (if .["plugin-opts"] then .["plugin-opts"] else empty end)
        }
      elif .type == "vmess" then
        { type: "vmess", uuid, security: (.cipher // "auto"),
          alter_id: ((.alterId // 0) | tonumber) }
        + (if (.tls) then { tls: { enabled: true, server_name: (.servername // .sni // .server // ""),
          insecure: (.["skip-cert-verify"] // false) } } else {} end)
      elif .type == "snell" then
        { type: "snell", password: (.psk // ""),
          version: (.["snell-opts"].version // 4 | tonumber) }
      elif .type == "http" then
        { type: "http", username: (.username // ""), password: (.password // ""),
          tls: (if (.tls) then { enabled: true, server_name: (.servername // .sni // .server // ""),
            insecure: (.["skip-cert-verify"] // false) } else {} end)
        }
      elif .type == "socks5" then
        { type: "socks", version: "5", username: (.username // ""), password: (.password // "") }
      else empty end
    | select(.type != null)
    ]' 2>/dev/null
}

# ─── Format detection + parse ───

_detect_and_parse() {
    local raw="$1"
    local first_line; first_line=$(_first_line <<< "$raw")

    # HTML detection
    if [[ "$first_line" =~ ^[[:space:]]*(<\!DOCTYPE|<html|<head|<meta|<script|HTTP/) ]]; then
        echo "_status:HTML"; return
    fi

    # Try base64 decode first
    if [[ ! "$first_line" =~ ^(vmess|vless|trojan|hysteria2|anytls|ss|tuic|socks):// ]] && grep -qE '://' <<< "$raw"; then
        local decoded; decoded=$(echo "$raw" | base64 -d 2>/dev/null || true)
        if [ -n "$decoded" ]; then
            local dfirst; dfirst=$(_first_line <<< "$decoded")
            if [[ "$dfirst" =~ ^(vmess|vless|trojan|hysteria2|ss|tuic|socks):// ]] || grep -qE '^[[:space:]]*(proxies|mixed-port|port):' <<< "$decoded"; then
                raw="$decoded"
                first_line=$(_first_line <<< "$raw")
            fi
        fi
    fi

    # Clash YAML
    if grep -qE '^[[:space:]]*(proxies|mixed-port|port):' <<< "$raw"; then
        if command -v yq >/dev/null 2>&1; then
            local proxies; proxies=$(echo "$raw" | yq -o=json '.proxies' 2>/dev/null || echo "[]")
            if [ -n "$proxies" ] && [ "$proxies" != "null" ] && [ "$(echo "$proxies" | jq 'length' 2>/dev/null)" != "0" ]; then
                echo "$proxies" | _clash_to_singbox
                echo "_status:Clash|$(echo "$proxies" | jq 'length' 2>/dev/null)"
            else
                # Try URI format with default UA (no custom UA)
                echo "_status:URI|0"
            fi
        else
            echo "_status:NoYQ"; return
        fi
        return
    fi

    # URI format
    if [[ "$first_line" =~ ^(vmess|vless|trojan|hysteria2|anytls|ss|tuic|socks):// ]]; then
        local cnt=0
        while IFS= read -r uri_line; do
            [ -z "$uri_line" ] && continue
            local parsed; parsed=$(_parse_uri "$uri_line" 2>/dev/null || true)
            [ -n "$parsed" ] && { echo "$parsed"; cnt=$((cnt+1)); }
        done <<< "$raw"
        echo "_status:URI|$cnt"
        return
    fi

    echo "_status:UNKNOWN"
}

# ═══ Main ═══

echo "=== Subscription Update ==="
echo ""

if $LOCAL_BUILD; then
    [ ! -f "$CACHE_FILE" ] && { echo "ERROR: $CACHE_FILE not found, run without --local first"; exit 1; }
    ALL_NODES=$(cat "$CACHE_FILE")
    echo "using cached nodes (offline rebuild)"
else
    [ ! -f "$SUB_URLS" ] && { echo "ERROR: $SUB_URLS not found"; exit 1; }

    ENTRIES=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="${line%%#*}"; line="${line%"${line##*[![:space:]]}"}"
        [ -z "$line" ] && continue
        ENTRIES+=("$line")
    done < "$SUB_URLS"

    echo "fetching ${#ENTRIES[@]} subscription(s)..."
    echo ""

    FETCH_DIR=$(mktemp -d)
    trap "rm -rf '$FETCH_DIR'" EXIT

    OK_COUNT=0; FAIL_COUNT=0; ALL_NODES="[]"
    for i in "${!ENTRIES[@]}"; do
        entry="${ENTRIES[$i]}"
        url="${entry%% *}"
        ua="${entry#* }"; [ "$ua" = "$url" ] && ua="$DEFAULT_UA"
        short="${url##*/}"; short="${short:0:40}"

        echo -n "  [$i] $short ... "

        # local file
        if [[ "$url" == file://* ]]; then
            local_path="${url#file://}"
            [ ! -f "$local_path" ] && { echo "FAIL (file not found: $local_path)"; FAIL_COUNT=$((FAIL_COUNT+1)); continue; }
            raw=$(cat "$local_path" 2>/dev/null)
        else
            raw=$(_fetch_url "$url" "$ua")
        fi

        if [ -z "$raw" ]; then
            echo "FAIL (no response)"
            FAIL_COUNT=$((FAIL_COUNT + 1))
            continue
        fi

        mkdir -p raw
        echo "$raw" > "raw/${short}_$(date +%Y%m%d_%H%M%S).yaml"

        # Parse with all stages collected
        parse_output=$(_detect_and_parse "$raw" 2>/dev/null || true)
        status_line=$(echo "$parse_output" | grep '^_status:' | tail -1)
        nodes_str=$(echo "$parse_output" | grep -v '^_status:')

        case "$status_line" in
            _status:HTML)    echo "SKIP (HTML)"; FAIL_COUNT=$((FAIL_COUNT+1)); continue ;;
            _status:UNKNOWN) echo "UNKNOWN format"; FAIL_COUNT=$((FAIL_COUNT+1)); continue ;;
            _status:NoYQ)    echo "WARN (no yq)"; FAIL_COUNT=$((FAIL_COUNT+1)); continue ;;
            _status:Clash*)
                cnt=$(echo "$nodes_str" | jq -s 'length' 2>/dev/null)
                nodes_json=$(echo "$nodes_str" | jq -s '.' 2>/dev/null || echo "[]")
                echo "OK (Clash, $cnt nodes)" ;;
            _status:URI*)
                cnt=$(echo "$nodes_str" | jq -s 'length' 2>/dev/null || echo 0)
                nodes_json=$(echo "$nodes_str" | jq -s '.' 2>/dev/null || echo "[]")
                echo "OK (URI, $cnt nodes)" ;;
        esac

        ALL_NODES=$(echo "$ALL_NODES" | jq -c --argjson n "$nodes_json" '. + $n')
        OK_COUNT=$((OK_COUNT + 1))
    done

    echo ""
    echo "subscriptions: OK=$OK_COUNT FAIL=$FAIL_COUNT"
    [ "$OK_COUNT" -eq 0 ] && { echo "ERROR: all subscriptions failed"; exit 1; }
fi

# ─── Merge & generate config ───

NODES=$(echo "$ALL_NODES" | jq -c 'unique_by(.tag)')
TOTAL=$(echo "$NODES" | jq 'length')

# Filter: keep nodes with valid server+port or non-vless/vmess types
NODES=$(echo "$NODES" | jq '[.[] | select(.server != null and .server_port != null)]')
TOTAL=$(echo "$NODES" | jq 'length')
echo "nodes: $TOTAL (after dedup + validation)"

# Save cache for --local rebuilds
echo "$NODES" > "$CACHE_FILE"

TAGS=$(echo "$NODES" | jq '[.[].tag]')

jq -n --slurpfile nodes <(echo "$NODES") --argjson tags "$TAGS" \
  --argjson port "$PROXY_PORT" --arg loglevel "$LOG_LEVEL" --arg delay_url "$DELAY_URL" \
  '{
    log: { level: $loglevel },
    inbounds: [{ type: "mixed", tag: "mixed-in", listen: "0.0.0.0", listen_port: $port }],
    dns: { servers: [
      { tag: "local", address: "udp://8.8.8.8", detour: "direct" },
      { tag: "local6", address: "udp://1.1.1.1", detour: "direct" }
    ]},
    outbounds: ($nodes[0] + [
      { type: "selector", tag: "proxy", outbounds: $tags },
      { type: "direct", tag: "direct" }
    ]),
    route: { final: "proxy" },
    experimental: { clash_api: { external_controller: "0.0.0.0:9090", secret: "" } }
  }' > "$OUT_CONFIG"

echo ""
if [ -x ./sing-box ] && ./sing-box check -c "$OUT_CONFIG" >/dev/null 2>&1; then
    echo "config: $OUT_CONFIG (valid, $TOTAL nodes)"
else
    echo "config: $OUT_CONFIG (written, $TOTAL nodes)"
fi

echo "done."
exit 0