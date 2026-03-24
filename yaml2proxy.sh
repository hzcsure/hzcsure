#!/bin/sh
# 纯 Shell 解析 Clash YAML → 代理链接
# 无 yq 无 jq 无依赖
# 用法：sh yaml2proxy.sh config.yaml

set -e

if [ $# -ne 1 ]; then
    echo "用法: $0 config.yaml"
    exit 1
fi

yaml="$1"
#echo "===== 开始解析（纯 Shell 版）====="

awk '
BEGIN{inProxy=0; n=0;}
/^proxies:/{inProxy=1; next}
inProxy && /^- name:/{
    if(n>0) output();
    n++; type=""; name=""; server=""; port=""; uuid=""; password="";
    tls="false"; sni=""; net="tcp"; path=""; host=""; aid=0;
    sub(/^- name: /,""); name=$0; gsub(/"/,""); next
}
inProxy && /^  type:/{sub(/^  type: /,""); type=$0; next}
inProxy && /^  server:/{sub(/^  server: /,""); server=$0; next}
inProxy && /^  port:/{sub(/^  port: /,""); port=$0; next}
inProxy && /^  uuid:/{sub(/^  uuid: /,""); uuid=$0; next}
inProxy && /^  password:/{sub(/^  password: /,""); password=$0; next}
inProxy && /^  tls:/{sub(/^  tls: /,""); tls=$0; next}
inProxy && /^  servername:/{sub(/^  servername: /,""); sni=$0; next}
inProxy && /^  network:/{sub(/^  network: /,""); net=$0; next}
inProxy && /^  alterId:/{sub(/^  alterId: /,""); aid=$0; next}
inProxy && /^  path:/{sub(/^  path: /,""); path=$0; next}
inProxy && /^    path:/{sub(/^    path: /,""); path=$0; next}
inProxy && /^    host:/{sub(/^    host: /,""); host=$0; next}
inProxy && /^  sni:/{sub(/^  sni: /,""); sni=$0; next}
END{output();}

function output() {
    if(type=="vmess"){
        json = "{\"v\":\"2\",\"ps\":\"" name "\",\"add\":\"" server "\",\"port\":\"" port "\",\"id\":\"" uuid "\",\"aid\":\"" aid "\",\"scy\":\"auto\",\"net\":\"" net "\",\"type\":\"none\",\"host\":\"" host "\",\"path\":\"" path "\",\"tls\":\"\"}"
        cmd = "echo \047" json "\047 | base64 | tr -d \047\n\r\047"
        cmd | getline b64
        close(cmd)
        #print "【VMess】" name
        print "vmess://" b64
        print ""
    }
    if(type=="vless"){
        enc = name
        gsub(/ /,"%20",enc); gsub(/\//,"%2F",enc); gsub(/:/,"%3A",enc)
        q = "security=" (tls=="true"?"tls":"none") "&type=" net "&sni=" sni "&path=" path "&host=" host
        #print "【VLESS】" name
        print "vless://" uuid "@" server ":" port "?" q "#" enc
        print ""
    }
    if(type=="trojan"){
        enc = name
        gsub(/ /,"%20",enc); gsub(/\//,"%2F",enc); gsub(/:/,"%3A",enc)
        q = "security=tls&type=" net "&sni=" sni
        #print "【Trojan】" name
        print "trojan://" password "@" server ":" port "?" q "#" enc
        print ""
    }
}
' "$yaml"

#echo "===== 解析完成 ====="
