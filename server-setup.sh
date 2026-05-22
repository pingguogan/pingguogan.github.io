#!/usr/bin/env bash
# X-Tunnel 服务端快速配置工具（多实例版）
set -o pipefail

INSTALL_DIR="/opt/x-tunnel"
BIN="$INSTALL_DIR/x-tunnel-server"
GITHUB_REPO="pangaoogao/x-tunnel"
GITHUB_RELEASE="https://github.com/$GITHUB_REPO/releases/latest/download"
INSECURE=false

# ======================== 下载 ========================

ensure_binary() {
    if [ -f "$BIN" ] && [ -x "$BIN" ]; then
        return 0
    fi
    echo "正在下载 x-tunnel-server ..."
    mkdir -p "$INSTALL_DIR"
    local url="$GITHUB_RELEASE/x-tunnel-server"
    if curl -fsSL -o "$BIN" "$url"; then
        chmod +x "$BIN"
        echo "下载完成: $BIN"
    else
        echo "下载失败: $url"
        echo "请手动编译后复制到 $BIN"
        exit 1
    fi
}

self_update() {
    local tmp
    tmp=$(mktemp)
    local url="$GITHUB_RELEASE/server-setup.sh"
    if curl -fsSL -o "$tmp" "$url"; then
        if ! diff -q "$tmp" "$0" &>/dev/null; then
            cp "$tmp" "$0"
            chmod +x "$0"
            echo "脚本已更新，请重新运行"
            rm -f "$tmp"
            exit 0
        fi
    fi
    rm -f "$tmp"
}

# ======================== 实例管理 ========================

cfg_path()  { local s=$1; echo "$INSTALL_DIR/server-config${s}.json"; }
svc_name()  { local s; s=$(echo "$1" | tr -d '[:space:]'); [ -z "$s" ] && echo "x-tunnel-server" || echo "x-tunnel-server${s}"; }
log_path()  { local s=$1; local nm=$(svc_name "$s"); echo "/var/log/${nm}.log"; }

detect_instances() {
    INSTANCES=(); INSTANCE_DISPLAY=()
    for f in "$INSTALL_DIR"/server-config*.json; do
        [ -f "$f" ] || continue
        base=$(basename "$f" .json)
        if [ "$base" = "server-config" ]; then
            INSTANCES+=(""); INSTANCE_DISPLAY+=("默认")
        else
            suf="${base#server-config}"
            INSTANCES+=("$suf"); INSTANCE_DISPLAY+=("${suf#-}")
        fi
    done
}

list_instances() {
    detect_instances
    if [ ${#INSTANCES[@]} -eq 0 ]; then
        echo "  (无实例)"
        return
    fi
    for i in "${!INSTANCES[@]}"; do
        s=${INSTANCES[$i]}; d=${INSTANCE_DISPLAY[$i]}
        cf=$(cfg_path "$s")
        port=$(grep -oP '"listen"\s*:\s*"\K[^"]+' "$cf" 2>/dev/null | grep -oP '\d+$' || echo "?")
        if systemctl is-active "$(svc_name "$s")" &>/dev/null || pgrep -f "x-tunnel-server.*$(basename "$cf")" &>/dev/null; then
            echo "  $((i+1))) $d (端口 $port) [运行中]"
        else
            echo "  $((i+1))) $d (端口 $port) [已停止]"
        fi
    done
}

show_all_links() {
    detect_instances
    echo ""
    echo "=== 复制以下链接到客户端（Ctrl+V 导入）==="
    echo ""
    for i in "${!INSTANCES[@]}"; do
        s=${INSTANCES[$i]}; d=${INSTANCE_DISPLAY[$i]}
        cf=$(cfg_path "$s")
        [ -f "$cf" ] || continue
        listen=$(grep -oP '"listen"\s*:\s*"\K[^"]+' "$cf" 2>/dev/null | head -1 || echo "")
        token=$(grep -oP '"token"\s*:\s*"\K[^"]+' "$cf" 2>/dev/null | head -1 || echo "")
        cert=$(grep -oP '"cert"\s*:\s*"\K[^"]+' "$cf" 2>/dev/null | head -1 || echo "")
        if [ -n "$cert" ]; then
            server_addr=$(echo "$cert" | sed 's|/fullchain\.cer$||; s|/fullchain\.pem$||; s|.*/||')
        else
            server_addr=$(echo "$listen" | sed 's|wss://||; s|ws://||; s|:.*||')
        fi
        forward_addr="${listen/0.0.0.0/$server_addr}"
        client_json="{\"mode\":\"client\",\"listen\":\"socks5://0.0.0.0:1080\",\"forward\":\"$forward_addr\""
        [ -n "$token" ] && client_json="$client_json,\"token\":\"$token\""
        client_json="$client_json,\"fallback\":true,\"connNum\":3}"
        echo "xtunnel://$(echo -n "$client_json" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=')"
    done
    echo ""
    echo "=== 共 ${#INSTANCES[@]} 个链接 ==="
}

# ======================== 实例选择菜单 ========================

instance_menu() {
    detect_instances
    if [ ${#INSTANCES[@]} -eq 0 ]; then
        echo "暂无实例，进入配置向导创建新实例..."
        run_wizard ""
        return
    fi
    while true; do
        echo ""
        echo "--- 选择实例 ---"
        list_instances
        local n=$(( ${#INSTANCES[@]} + 1 ))
        echo "  $n) 新建实例"
        echo "  a) 显示所有分享链接"
        echo "  0) 退出"
        echo ""
        read -p "请选择 [0-$n/a]: " SEL
        [ -z "$SEL" ] && continue
        SEL=$(echo "$SEL" | tr '[:upper:]' '[:lower:]')
        if [ "$SEL" = "0" ]; then exit 0; fi
        if [ "$SEL" = "a" ]; then
            show_all_links
            continue
        fi
        if [ "$SEL" = "$n" ]; then
            local next=1
            for s in "${INSTANCES[@]}"; do
                local num=${s#-}
                [ -n "$num" ] && [ "$num" -ge "$next" ] && next=$((num+1))
            done
            ensure_binary
            run_wizard "-$next"
            return
        fi
        if [ "$SEL" -ge 1 ] && [ "$SEL" -le "${#INSTANCES[@]}" ]; then
            idx=$((SEL-1))
            manage_instance "${INSTANCES[$idx]}" "${INSTANCE_DISPLAY[$idx]}"
        else
            echo "无效选项"
        fi
    done
}

# ======================== 实例管理菜单 ========================

manage_instance() {
    local suf=$1; local display=$2
    local conf=$(cfg_path "$suf")
    local svc=$(svc_name "$suf")
    local logf=$(log_path "$suf")

    LISTEN=$(grep -oP '"listen"\s*:\s*"\K[^"]+' "$conf" 2>/dev/null | head -1 || echo "")
    TOKEN=$(grep -oP '"token"\s*:\s*"\K[^"]+' "$conf" 2>/dev/null | head -1 || echo "")
    CERT_FILE=$(grep -oP '"cert"\s*:\s*"\K[^"]+' "$conf" 2>/dev/null | head -1 || echo "")
    KEY_FILE=$(grep -oP '"key"\s*:\s*"\K[^"]+' "$conf" 2>/dev/null | head -1 || echo "")
    FORWARD=$(grep -oP '"forward"\s*:\s*"\K[^"]+' "$conf" 2>/dev/null | head -1 || echo "")
    INSECURE=false

    if [ -n "$LISTEN" ]; then
        DOMAIN=""; SERVER_ADDR=""
        if [ -n "$CERT_FILE" ]; then
            DOMAIN=$(echo "$CERT_FILE" | sed 's|/fullchain\.cer$||; s|.*/||')
            SERVER_ADDR="$DOMAIN"
        else
            SERVER_ADDR=$(echo "$LISTEN" | sed 's|wss://||; s|ws://||; s|:.*||')
        fi
        FORWARD_ADDR="${LISTEN/0.0.0.0/$SERVER_ADDR}"
        CLIENT_JSON="{\"mode\":\"client\",\"listen\":\"socks5://0.0.0.0:1080\",\"forward\":\"$FORWARD_ADDR\""
        [ -n "$TOKEN" ] && CLIENT_JSON="$CLIENT_JSON,\"token\":\"$TOKEN\""
        [ "$INSECURE" = true ] && CLIENT_JSON="$CLIENT_JSON,\"insecure\":true"
        CLIENT_JSON="$CLIENT_JSON,\"fallback\":true,\"connNum\":3}"
        SHARE_LINK="xtunnel://$(echo -n "$CLIENT_JSON" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=')"
    fi

    echo ""
    echo "==================================="
    echo "  实例: ${display:-默认}"
    echo "  配置: $conf"
    echo "==================================="

    while true; do
        echo ""
        echo "  1) 启动服务"
        echo "  2) 停止服务"
        echo "  3) 重启服务"
        echo "  4) 查看状态"
        echo "  5) 查看配置"
        echo "  6) 查看最近日志"
        echo "  7) 实时日志 (Ctrl+C退出)"
        echo "  8) 显示分享链接"
        echo "  9) 重新配置"
        echo " 10) 删除此实例"
        echo "  0) 返回上级菜单"
        echo ""
        read -p "请输入 [0-10]: " ACT

        case $ACT in
            1)
                echo "启动 ${svc}..."
                pgrep -f "x-tunnel-server.*$(basename "$conf")" 2>/dev/null | xargs kill 2>/dev/null || true
                sleep 1
                systemctl start "$svc" 2>/dev/null || nohup "$BIN" -config "$conf" > "$logf" 2>&1 &
                sleep 1
                if systemctl is-active "$svc" &>/dev/null || pgrep -f "x-tunnel-server.*$(basename "$conf")" &>/dev/null; then
                    echo "服务已启动"
                else
                    echo "启动失败！检查日志:"
                    journalctl -u "$svc" -n 10 --no-pager 2>/dev/null || tail -10 "$logf" 2>/dev/null || true
                fi ;;
            2)
                echo "停止 ${svc}..."
                systemctl stop "$svc" 2>/dev/null || true
                pgrep -f "x-tunnel-server.*$(basename "$conf")" 2>/dev/null | xargs kill 2>/dev/null || true
                echo "服务已停止" ;;
            3)
                echo "重启 ${svc}..."
                systemctl restart "$svc" 2>/dev/null || { systemctl stop "$svc" 2>/dev/null; sleep 1; nohup "$BIN" -config "$conf" > "$logf" 2>&1 & }
                echo "服务已重启" ;;
            4)
                echo "服务状态:"
                if systemctl is-active "$svc" &>/dev/null; then
                    systemctl status "$svc" --no-pager 2>/dev/null || echo "$svc 运行中"
                else
                    pgrep -af "x-tunnel-server.*$(basename "$conf")" 2>/dev/null || echo "$svc 未运行"
                fi ;;
            5)
                echo "配置 ($conf):"
                echo ""
                [ -f "$conf" ] && cat "$conf" || echo "无配置文件" ;;
            6)
                echo "最近日志 (${svc}):"
                journalctl -u "$svc" -n 30 --no-pager 2>/dev/null || tail -30 "$logf" 2>/dev/null || echo "无日志" ;;
            7)
                echo "实时日志 (${svc}):"
                if systemctl is-active "$svc" &>/dev/null; then
                    journalctl -u "$svc" -f --no-pager 2>/dev/null || true
                else
                    tail -f "$logf" 2>/dev/null || echo "无日志文件"
                fi ;;
            8)
                echo "分享链接:"
                echo ""
                echo "  $SHARE_LINK"
                echo ""
                echo "JSON 配置:"
                echo ""
                echo "$CLIENT_JSON" ;;
            9)
                run_wizard "$suf" "$display"
                return ;;
            10)
                read -p "确认删除实例 ${display:-默认}? (y/N): " OK
                if [[ "$OK" =~ ^[Yy] ]]; then
                    systemctl stop "$svc" 2>/dev/null || true
                    pgrep -f "x-tunnel-server.*$(basename "$conf")" 2>/dev/null | xargs kill 2>/dev/null || true
                    systemctl disable "$svc" 2>/dev/null || true
                    rm -f "$conf" "/etc/systemd/system/${svc}.service"
                    systemctl daemon-reload 2>/dev/null
                    echo "实例已删除"
                    return
                fi ;;
            0) return ;;
            *) echo "无效选项" ;;
        esac
    done
}

# ======================== 配置向导 ========================

run_wizard() {
    local suf=$1
    local display=${2:-}
    local conf=$(cfg_path "$suf")
    local svc=$(svc_name "$suf")

    echo ""
    [ -z "$display" ] && display="${suf#-}"
    [ -z "$display" ] && display="默认"
    echo "--- 配置实例: $display ---"
    echo ""

    # ---------- 基本设置 ----------
    read -p "监听端口 [443]: " PORT
    PORT=${PORT:-443}
    LISTEN="wss://0.0.0.0:$PORT"

    read -p "认证令牌 (回车自动生成随机12位): " TOKEN
    if [ -z "$TOKEN" ]; then
        TOKEN=$(tr -dc A-Za-z0-9 </dev/urandom 2>/dev/null | head -c12 || openssl rand -base64 9 2>/dev/null | tr -dc A-Za-z0-9 | head -c12 || echo "x$(date +%s)")
        echo "  自动生成令牌: $TOKEN"
    fi

    # ---------- TLS 证书 ----------
    CERT_FILE=""; KEY_FILE=""; INSECURE=false; DOMAIN=""

    if [[ "$LISTEN" == wss://* ]]; then
        echo ""
        echo "--- TLS 证书 ---"

        declare -A CERT_MAP
        CERT_LIST=()
        for f in "$INSTALL_DIR"/server-config*.json; do
            [ -f "$f" ] || continue
            c=$(grep -oP '"cert"\s*:\s*"\K[^"]+' "$f" 2>/dev/null || true)
            k=$(grep -oP '"key"\s*:\s*"\K[^"]+' "$f" 2>/dev/null || true)
            [ -n "$c" ] && [ -f "$c" ] || continue
            if [ -z "${CERT_MAP[$c]}" ]; then
                CERT_MAP[$c]="$k"
                CERT_LIST+=("$c")
            fi
        done
        for d in /etc/letsencrypt/*/; do
            d="${d%/}"
            domain=$(basename "$d")
            case "$domain" in accounts|archive|csr|keys|live|renewal|renewal-hooks) continue ;; esac
            for cert_file in "$d/fullchain.cer" "$d/fullchain.pem"; do
                [ -f "$cert_file" ] || continue
                key_file="$d/$domain.key"
                [ ! -f "$key_file" ] && key_file="/etc/letsencrypt/live/$domain/privkey.pem"
                [ ! -f "$key_file" ] && continue
                [ -z "${CERT_MAP[$cert_file]}" ] && { CERT_MAP[$cert_file]="$key_file"; CERT_LIST+=("$cert_file"); }
            done
        done
        for d in /etc/letsencrypt/live/*/; do
            d="${d%/}"
            for cert_file in "$d/fullchain.pem" "$d/fullchain.cer"; do
                [ -f "$cert_file" ] || continue
                key_file="$d/privkey.pem"
                [ ! -f "$key_file" ] && continue
                [ -z "${CERT_MAP[$cert_file]}" ] && { CERT_MAP[$cert_file]="$key_file"; CERT_LIST+=("$cert_file"); }
            done
        done

        if [ ${#CERT_LIST[@]} -gt 0 ]; then
            echo "检测到已有证书:"
            for i in "${!CERT_LIST[@]}"; do
                d=$(echo "${CERT_LIST[$i]}" | sed 's|/fullchain\.cer$||; s|/fullchain\.pem$||; s|.*/||')
                echo "  $((i+1))) $d (${CERT_LIST[$i]})"
            done
            echo "  $(( ${#CERT_LIST[@]} + 1 ))) 不使用已有证书"
            read -p "选择证书 [1]: " CERT_SEL
            CERT_SEL=${CERT_SEL:-1}
            if [ "$CERT_SEL" -ge 1 ] && [ "$CERT_SEL" -le "${#CERT_LIST[@]}" ]; then
                idx=$((CERT_SEL-1))
                CERT_FILE="${CERT_LIST[$idx]}"
                KEY_FILE="${CERT_MAP[$CERT_FILE]}"
                DOMAIN=$(echo "$CERT_FILE" | sed 's|/fullchain\.cer$||; s|.*/||')
                echo "将使用证书，域名: $DOMAIN"
            fi
        fi

        if [ -z "$CERT_FILE" ]; then
            echo "1) 使用自定义证书文件"
            echo "2) 使用自签名证书（客户端需勾选 insecure）"
            read -p "选择证书方式 [1]: " CERT_CHOICE
            CERT_CHOICE=${CERT_CHOICE:-1}

            case $CERT_CHOICE in
                1)
                    read -p "证书文件路径: " CERT_FILE
                    read -p "密钥文件路径: " KEY_FILE
                    [ -n "$CERT_FILE" ] && [ ! -f "$CERT_FILE" ] && { echo "文件不存在: $CERT_FILE"; exit 1; }
                    [ -n "$KEY_FILE" ] && [ ! -f "$KEY_FILE" ] && { echo "文件不存在: $KEY_FILE"; exit 1; }
                    ;;
                2)
                    echo "将使用自签名证书，客户端需勾选 insecure"
                    INSECURE=true
                    ;;
            esac
        fi
    fi

    # ---------- 客户端连接地址 ----------
    if [ -n "$DOMAIN" ]; then
        SERVER_ADDR="$DOMAIN"
        echo "客户端连接地址: $SERVER_ADDR (使用证书域名)"
    else
        PUBLIC_IP=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || echo "")
        read -p "服务器公网 IP 或域名 [${PUBLIC_IP:-未检测到}]: " SERVER_ADDR
        SERVER_ADDR=${SERVER_ADDR:-$PUBLIC_IP}
    fi

    # ---------- SOCKS5 前置代理 ----------
    FORWARD=""
    read -p "使用 SOCKS5 前置代理? (y/N): " USE_SOCKS5
    [[ "$USE_SOCKS5" =~ ^[Yy] ]] && read -p "SOCKS5 地址 (如 socks5://127.0.0.1:1080): " FORWARD

    # ---------- 安全限制 ----------
    read -p "允许的 CIDR 范围 [0.0.0.0/0,::/0]: " CIDR
    CIDR=${CIDR:-0.0.0.0/0,::/0}

    # ---------- 生成配置 JSON ----------
    echo ""; echo "正在生成配置..."
    cat > "$conf" <<EOF
{
  "listen": "$LISTEN",
  "cidr": "$CIDR"
EOF
    [ -n "$TOKEN" ]    && echo '  ,"token": "'"$TOKEN"'"' >> "$conf"
    [ -n "$CERT_FILE" ] && echo '  ,"cert": "'"$CERT_FILE"'"' >> "$conf"
    [ -n "$KEY_FILE" ]  && echo '  ,"key": "'"$KEY_FILE"'"' >> "$conf"
    [ -n "$FORWARD" ]   && echo '  ,"forward": "'"$FORWARD"'"' >> "$conf"
    echo "" >> "$conf"
    echo "}" >> "$conf"

    if command -v python3 &>/dev/null; then
        python3 -c "
import json
with open('$conf') as f:
    cfg = json.load(f)
cfg = {k:v for k,v in cfg.items() if v is not None and v != ''}
with open('$conf', 'w') as f:
    json.dump(cfg, f, indent=2)
" 2>/dev/null || true
    fi

    echo "配置已写入: $conf"

    # ---------- 生成客户端配置 ----------
    FORWARD_ADDR="${LISTEN/0.0.0.0/$SERVER_ADDR}"
    CLIENT_JSON="{\"mode\":\"client\",\"listen\":\"socks5://0.0.0.0:1080\",\"forward\":\"$FORWARD_ADDR\""
    [ -n "$TOKEN" ] && CLIENT_JSON="$CLIENT_JSON,\"token\":\"$TOKEN\""
    [ "$INSECURE" = true ] && CLIENT_JSON="$CLIENT_JSON,\"insecure\":true"
    CLIENT_JSON="$CLIENT_JSON,\"fallback\":true,\"connNum\":3}"
    SHARE_LINK="xtunnel://$(echo -n "$CLIENT_JSON" | base64 -w0 2>/dev/null | tr '+/' '-_' | tr -d '=')"
    CLI_CMD="./x-tunnel-client -l socks5://0.0.0.0:1080 -f \"$FORWARD_ADDR\""
    [ -n "$TOKEN" ] && CLI_CMD="$CLI_CMD -token \"$TOKEN\""
    [ "$INSECURE" = true ] && CLI_CMD="$CLI_CMD -insecure"
    CLI_CMD="$CLI_CMD -fallback"

    echo ""
    echo "==================================="
    echo "  客户端连接配置"
    echo "==================================="
    echo ""
    echo "【分享链接】:"
    echo "  $SHARE_LINK"
    echo ""
    echo "【JSON】:"
    echo "$CLIENT_JSON"
    echo ""
    echo "【命令行】:"
    echo "  $CLI_CMD"
    echo ""

    # ---------- 安装系统服务 ----------
    if [ ! -f "$BIN" ]; then
        ensure_binary
    fi

    echo ""
    if [ -f "$INSTALL_DIR/x-tunnel-server" ]; then
        echo "检测到已安装，正在更新服务..."
        systemctl stop "$svc" 2>/dev/null || true
    else
        echo "安装系统服务..."
        mkdir -p "$INSTALL_DIR"
    fi

    # 生成 service 文件
    local svc_file="/etc/systemd/system/${svc}.service"
    cat > "$svc_file" <<SERVICE
[Unit]
Description=X-Tunnel Server${suf:+ ($display)}
After=network.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
ExecStart=$BIN -config $conf
Restart=always
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
SERVICE
    systemctl daemon-reload
    systemctl enable "$svc" 2>/dev/null
    if systemctl start "$svc"; then
        echo "服务已安装并启动！"
    else
        echo "systemctl 启动失败，尝试直接运行..."
        nohup "$BIN" -config "$conf" > "$logf" 2>&1 &
        sleep 1
        if pgrep -f "x-tunnel-server.*$(basename "$conf")" &>/dev/null; then
            echo "服务已启动（直接运行模式）"
        else
            echo "启动失败！检查日志:"
            tail -10 "$logf" 2>/dev/null
        fi
    fi
    echo "  服务名: $svc"
    echo "  配置: $conf"

    # ---------- 快捷命令 ----------
    mkdir -p /usr/local/bin
    cat > /usr/local/bin/x-tunnel <<'XTOOL'
#!/usr/bin/env bash
exec /opt/x-tunnel/server-setup.sh "$@"
XTOOL
    chmod +x /usr/local/bin/x-tunnel
    echo ""
    echo "快捷命令已安装: x-tunnel"
    echo "  输入 x-tunnel              → 实例选择菜单"
    echo "  输入 x-tunnel <名称>       → 管理指定实例"
    echo "  输入 x-tunnel <名称> start → 启动指定实例"
    echo "  输入 x-tunnel list         → 列出所有实例"

    manage_instance "$suf" "$display"
}

# ======================== 主入口 ========================

# 首次运行：确保脚本在 INSTALL_DIR
if [ "$(readlink -f "$0")" != "$INSTALL_DIR/server-setup.sh" ] && [ ! -f "$INSTALL_DIR/server-setup.sh" ]; then
    mkdir -p "$INSTALL_DIR"
    cp "$0" "$INSTALL_DIR/server-setup.sh"
    chmod +x "$INSTALL_DIR/server-setup.sh"
    echo "脚本已复制到 $INSTALL_DIR/server-setup.sh，请用 x-tunnel 命令运行"
    # 安装快捷命令
    cat > /usr/local/bin/x-tunnel <<'XTOOL'
#!/usr/bin/env bash
exec /opt/x-tunnel/server-setup.sh "$@"
XTOOL
    chmod +x /usr/local/bin/x-tunnel
    echo "快捷命令已安装: x-tunnel"
    exit 0
fi

if [ $# -ge 2 ]; then
    ACTION="$1"; INSTANCE_SUFFIX="$2"
    detect_instances
    for i in "${!INSTANCES[@]}"; do
        if [ "${INSTANCES[$i]}" = "$INSTANCE_SUFFIX" ] || [ "${INSTANCE_DISPLAY[$i]}" = "$INSTANCE_SUFFIX" ]; then
            INSTANCE_SUFFIX="${INSTANCES[$i]}"
            break
        fi
    done
    cf=$(cfg_path "$INSTANCE_SUFFIX")
    sv=$(svc_name "$INSTANCE_SUFFIX")
    lf=$(log_path "$INSTANCE_SUFFIX")
    case "$ACTION" in
        start)
            systemctl start "$sv" 2>/dev/null || nohup "$BIN" -config "$cf" > "$lf" 2>&1 &
            echo "${sv} 已启动"; exit 0 ;;
        stop)
            systemctl stop "$sv" 2>/dev/null || true
            pgrep -f "x-tunnel-server.*$(basename "$cf")" 2>/dev/null | xargs kill 2>/dev/null || true
            echo "${sv} 已停止"; exit 0 ;;
        restart)
            systemctl restart "$sv" 2>/dev/null || { systemctl stop "$sv" 2>/dev/null; sleep 1; nohup "$BIN" -config "$cf" > "$lf" 2>&1 & }
            echo "${sv} 已重启"; exit 0 ;;
        status)
            if systemctl is-active "$sv" &>/dev/null; then
                systemctl status "$sv" --no-pager 2>/dev/null
            else
                pgrep -af "x-tunnel-server.*$(basename "$cf")" 2>/dev/null || echo "${sv} 未运行"
            fi
            exit 0 ;;
        config|conf)
            [ -f "$cf" ] && cat "$cf" || echo "无配置文件"
            exit 0 ;;
        logs|log)
            journalctl -u "$sv" -n 30 --no-pager 2>/dev/null || tail -30 "$lf" 2>/dev/null || echo "无日志"
            exit 0 ;;
        logsf|logf|logfollow)
            if systemctl is-active "$sv" &>/dev/null; then
                journalctl -u "$sv" -f --no-pager 2>/dev/null || true
            else
                tail -f "$lf" 2>/dev/null || echo "无日志文件"
            fi
            exit 0 ;;
    esac
fi

if [ $# -ge 1 ]; then
    case "$1" in
        start|stop|restart|status|config|conf|logs|log|logsf|logf|logfollow)
            ACTION="$1"; INSTANCE_SUFFIX=""
            cf=$(cfg_path "$INSTANCE_SUFFIX")
            sv=$(svc_name "$INSTANCE_SUFFIX")
            lf=$(log_path "$INSTANCE_SUFFIX")
            case "$ACTION" in
                start)
                    systemctl start "$sv" 2>/dev/null || nohup "$BIN" -config "$cf" > "$lf" 2>&1 &
                    echo "${sv} 已启动"; exit 0 ;;
                stop)
                    systemctl stop "$sv" 2>/dev/null || true
                    pgrep -f "x-tunnel-server.*$(basename "$cf")" 2>/dev/null | xargs kill 2>/dev/null || true
                    echo "${sv} 已停止"; exit 0 ;;
                restart)
                    systemctl restart "$sv" 2>/dev/null || { systemctl stop "$sv" 2>/dev/null; sleep 1; nohup "$BIN" -config "$cf" > "$lf" 2>&1 & }
                    echo "${sv} 已重启"; exit 0 ;;
                status)
                    if systemctl is-active "$sv" &>/dev/null; then
                        systemctl status "$sv" --no-pager 2>/dev/null
                    else
                        pgrep -af "x-tunnel-server.*$(basename "$cf")" 2>/dev/null || echo "${sv} 未运行"
                    fi
                    exit 0 ;;
                config|conf)
                    [ -f "$cf" ] && cat "$cf" || echo "无配置文件"
                    exit 0 ;;
                logs|log)
                    journalctl -u "$sv" -n 30 --no-pager 2>/dev/null || tail -30 "$lf" 2>/dev/null || echo "无日志"
                    exit 0 ;;
                logsf|logf|logfollow)
                    if systemctl is-active "$sv" &>/dev/null; then
                        journalctl -u "$sv" -f --no-pager 2>/dev/null || true
                    else
                        tail -f "$lf" 2>/dev/null || echo "无日志文件"
                    fi
                    exit 0 ;;
            esac
            ;;
        download)
            ensure_binary
            exit 0 ;;
        update)
            self_update
            echo "已是最新"
            exit 0 ;;
        list|ls)
            detect_instances
            echo "X-Tunnel 实例列表:"
            list_instances
            exit 0 ;;
        menu)
            if [ $# -ge 2 ]; then
                detect_instances
                for i in "${!INSTANCES[@]}"; do
                    if [ "${INSTANCE_DISPLAY[$i]}" = "$2" ] || [ "${INSTANCES[$i]}" = "-$2" ] || [ "${INSTANCES[$i]}" = "$2" ]; then
                        manage_instance "${INSTANCES[$i]}" "${INSTANCE_DISPLAY[$i]}"
                        exit 0
                    fi
                done
                echo "实例 '$2' 不存在"
            fi
            instance_menu
            exit 0 ;;
        setup|install)
            ensure_binary
            detect_instances
            if [ ${#INSTANCES[@]} -eq 0 ]; then
                run_wizard "" "默认"
            else
                next=1
                for s in "${INSTANCES[@]}"; do
                    num=${s#-}
                    [ -n "$num" ] && [ "$num" -ge "$next" ] && next=$((num+1))
                done
                run_wizard "-$next" "实例$next"
            fi
            exit 0 ;;
        *)
            detect_instances
            for i in "${!INSTANCES[@]}"; do
                if [ "${INSTANCE_DISPLAY[$i]}" = "$1" ] || [ "${INSTANCES[$i]}" = "-$1" ] || [ "${INSTANCES[$i]}" = "$1" ]; then
                    manage_instance "${INSTANCES[$i]}" "${INSTANCE_DISPLAY[$i]}"
                    exit 0
                fi
            done
            echo "未知命令或实例 '$1' 不存在"
            echo "用法: $0 [start|stop|restart|status|config|logs|list|menu|setup|download|update]"
            exit 1 ;;
    esac
fi

instance_menu
