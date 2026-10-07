#!/bin/sh
export LANG=en_US.UTF-8
# --- Настройки путей ---
BASE_DIR="$HOME/agsbx"
BIN_SINGBOX="$BASE_DIR/sing-box"
CONFIG_FILE="$BASE_DIR/sb.json"
CERT_FILE="$BASE_DIR/cert.pem"
KEY_FILE="$BASE_DIR/private.key"
SERVICE_NAME="sb"

# --- Функции ---

detect_arch() {
    case $(uname -m) in
        arm64|aarch64) cpu="arm64" ;;
        amd64|x86_64)  cpu="amd64" ;;
        *) echo "Архитектура $(uname -m) не поддерживается" && exit 1 ;;
    esac
}

install_deps() {
    echo "Установка зависимостей..."
    if command -v apt >/dev/null 2>&1; then
        apt update -y && apt install -y curl wget openssl jq qrencode ufw wireguard-tools dnsutils
    elif command -v yum >/dev/null 2>&1; then
        yum install -y curl wget openssl jq qrencode ufw wireguard-tools bind-utils
    fi
}

download_singbox() {
    mkdir -p "$BASE_DIR"
    if [ ! -e "$BIN_SINGBOX" ]; then
        echo "Скачивание Sing-box..."
        url="https://github.com/yonggekkk/argosbx/releases/download/argosbx/sing-box-$cpu"
        if ! (command -v curl >/dev/null 2>&1 && curl -Lo "$BIN_SINGBOX" -# --retry 2 "$url"); then
             (command -v wget >/dev/null 2>&1 && wget -O "$BIN_SINGBOX" --tries=2 "$url")
        fi
        
        if [ ! -s "$BIN_SINGBOX" ]; then
             echo "Скачивание с официального репозитория..."
             LATEST_URL=$(curl -s https://api.github.com/repos/SagerNet/sing-box/releases/latest | jq -r ".assets[] | select(.name|test(\"linux-${cpu}.tar.gz$\")) | .browser_download_url" | head -n 1)
             wget -O /tmp/sb.tar.gz "$LATEST_URL"
             tar -xzf /tmp/sb.tar.gz -C /tmp
             mv /tmp/sing-box-*/sing-box "$BIN_SINGBOX"
             rm -rf /tmp/sb.tar.gz /tmp/sing-box-*
        fi
        
        chmod +x "$BIN_SINGBOX"
    fi
}

generate_data() {
    echo "Генерация параметров для портов..."
    uuid=$("$BIN_SINGBOX" generate uuid)
    echo "$uuid" > "$BASE_DIR/uuid"

    port_hy2_warp=$(shuf -i 20000-30000 -n 1)
    port_hy2_direct=$(shuf -i 30001-40000 -n 1)
    port_tuic=$(shuf -i 40001-60000 -n 1)
    
    echo "$port_hy2_warp" > "$BASE_DIR/port_hy2_warp"
    echo "$port_hy2_direct" > "$BASE_DIR/port_hy2_direct"
    echo "$port_tuic" > "$BASE_DIR/port_tuic"
}

generate_cert() {
    echo "Генерация сертификата (CN=www.bing.com)..."
    openssl req -x509 -newkey rsa:2048 \
        -keyout "$KEY_FILE" \
        -out "$CERT_FILE" \
        -days 3650 -nodes \
        -subj "/CN=www.bing.com" >/dev/null 2>&1
}

get_warp_keys() {
    echo "Получение ключей WARP..."
    warp_data=$(curl -sSL https://warp.xijp.eu.org/)
    
    if [ -z "$warp_data" ]; then
        echo "Ошибка получения через API, генерируем локальные ключи..."
        w_priv=$(wg genkey)
        w_ip="172.16.0.2"
        w_reserved="[]"
    else
        w_priv=$(echo "$warp_data" | awk -F'：' '/Private_key/{print $2}' | xargs)
        w_ip=$(echo "$warp_data" | awk -F'：' '/IPV4/{print $2}' | xargs)
        w_reserved=$(echo "$warp_data" | awk -F'：' '/reserved/{print $2}' | xargs)
    fi

    if [ -z "$w_priv" ]; then
        w_priv=$(wg genkey)
        w_ip="172.16.0.2"
        w_reserved="[]"
    fi

    w_pub="bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo="
    
    cf_ip=$(dig +short engage.cloudflareclient.com @1.1.1.1 | head -n1)
    [ -z "$cf_ip" ] && cf_ip="162.159.192.1"

    echo "WARP IP: $w_ip"
    echo "WARP Reserved: $w_reserved"
}

create_config() {
    echo "Создание конфигурации (3 независимых ветки трафика)..."
    
    if [ -n "$w_ip" ]; then
        addr_list="[\"$w_ip/32\"]"
    else
        addr_list="[\"172.16.0.2/32\"]"
    fi

    if [ -z "$w_reserved" ]; then
        w_reserved="[]"
    fi

    cat > "$CONFIG_FILE" <<EOF
{
    "log": {"level": "warn"},
    "dns": {
        "servers": [
            {
                "tag": "remote-dns",
                "type": "https",
                "server": "1.1.1.1"
            }
        ],
        "strategy": "ipv4_only"
    },
    "inbounds": [
        {
            "type": "hysteria2",
            "tag": "hy2-warp-in",
            "listen": "::",
            "listen_port": ${port_hy2_warp},
            "users": [ { "password": "${uuid}" } ],
            "tls": {
                "enabled": true,
                "alpn": ["h3"],
                "certificate_path": "${CERT_FILE}",
                "key_path": "${KEY_FILE}"
            },
            "masquerade": "https://www.bing.com"
        },
        {
            "type": "hysteria2",
            "tag": "hy2-direct-in",
            "listen": "::",
            "listen_port": ${port_hy2_direct},
            "users": [ { "password": "${uuid}" } ],
            "tls": {
                "enabled": true,
                "alpn": ["h3"],
                "certificate_path": "${CERT_FILE}",
                "key_path": "${KEY_FILE}"
            },
            "masquerade": "https://www.bing.com"
        },
        {
            "type": "tuic",
            "tag": "tuic-in",
            "listen": "::",
            "listen_port": ${port_tuic},
            "users": [ { "uuid": "${uuid}", "password": "${uuid}" } ],
            "congestion_control": "bbr",
            "tls": {
                "enabled": true,
                "alpn": ["h3"],
                "certificate_path": "${CERT_FILE}",
                "key_path": "${KEY_FILE}"
            }
        }
    ],
    "outbounds": [
        { "type": "direct", "tag": "direct" }
    ],
    "endpoints": [
        {
            "type": "wireguard",
            "tag": "warp-out",
            "address": ${addr_list},
            "private_key": "${w_priv}",
            "peers": [
                {
                    "address": "${cf_ip}",
                    "port": 2408,
                    "public_key": "${w_pub}",
                    "allowed_ips": ["0.0.0.0/0", "::/0"],
                    "reserved": ${w_reserved}
                }
            ]
        }
    ],
    "route": {
        "rules": [
             {
                 "ip_cidr": ["${cf_ip}/32"],
                 "outbound": "direct"
             },
             {
                 "inbound": ["hy2-warp-in"],
                 "outbound": "warp-out"
             },
             {
                 "inbound": ["hy2-direct-in", "tuic-in"],
                 "outbound": "direct"
             },
             {
                 "protocol": "dns",
                 "outbound": "direct"
             }
        ],
        "final": "direct"
    }
}
EOF
}

setup_firewall() {
    echo "Настройка фаервола (UFW)..."
    ufw allow 22/tcp
    ufw allow ${port_hy2_warp}/udp
    ufw allow ${port_hy2_direct}/udp
    ufw allow ${port_tuic}/udp
    ufw --force enable
    ufw reload
}

create_service() {
    echo "Установка системного сервиса..."
    if pidof systemd >/dev/null 2>&1 && [ "$EUID" -eq 0 ]; then
        cat > /etc/systemd/system/${SERVICE_NAME}.service <<EOF
[Unit]
Description=3-Way Hysteria2 and TUIC5 Service
After=network.target

[Service]
Type=simple
ExecStart=${BIN_SINGBOX} run -c ${CONFIG_FILE}
Restart=on-failure
RestartSec=5s
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
        systemctl daemon-reload
        systemctl enable ${SERVICE_NAME}
        systemctl restart ${SERVICE_NAME}
    else
        pkill -f "sing-box run"
        nohup "$BIN_SINGBOX" run -c "$CONFIG_FILE" >/dev/null 2>&1 &
        echo "Sing-box запущен в фоне."
    fi
}

client_info() {
    ip=$(curl -s4m5 ifconfig.me || curl -s6m5 ifconfig.me)
    [ -z "$ip" ] && ip="YOUR_SERVER_IP"
    
    uuid=$(cat "$BASE_DIR/uuid")
    port_hy2_warp=$(cat "$BASE_DIR/port_hy2_warp")
    port_hy2_direct=$(cat "$BASE_DIR/port_hy2_direct")
    port_tuic=$(cat "$BASE_DIR/port_tuic")

    link_hy2_warp="hysteria2://${uuid}@${ip}:${port_hy2_warp}?sni=www.bing.com&insecure=1#HY2-USA-WARP"
    link_hy2_direct="hysteria2://${uuid}@${ip}:${port_hy2_direct}?sni=www.bing.com&insecure=1#HY2-DIRECT"
    link_tuic="tuic://${uuid}:${uuid}@${ip}:${port_tuic}?congestion_control=bbr&alpn=h3&sni=www.bing.com&allow_insecure=1#TUIC5-DIRECT"

    clear
    echo "======================================================"
    echo "      УСТАНОВКА ЗАВЕРШЕНА (Доступно 3 конфигурации)"
    echo "======================================================"
    echo " Server IP:   $ip"
    echo " UUID/Pass:   $uuid"
    echo "------------------------------------------------------"
    echo " 1. HY2 Port (WARP USA): $port_hy2_warp (UDP)"
    echo " 2. HY2 Port (DIRECT):   $port_hy2_direct (UDP)"
    echo " 3. TUIC Port (DIRECT):  $port_tuic (UDP)"
    echo "======================================================"
    echo ""
    echo ">>> ССЫЛКА 1. HYSTERIA 2 через WARP (Для ChatGPT/США сайтов):"
    echo "$link_hy2_warp"
    echo "QR-код HY2 WARP:"
    qrencode -t ANSIUTF8 "$link_hy2_warp"
    echo ""
    echo "------------------------------------------------------"
    echo ""
    echo ">>> ССЫЛКА 2. HYSTERIA 2 НАПРЯМУЮ (Макс. скорость HY2):"
    echo "$link_hy2_direct"
    echo "QR-код HY2 DIRECT:"
    qrencode -t ANSIUTF8 "$link_hy2_direct"
    echo ""
    echo "------------------------------------------------------"
    echo ""
    echo ">>> ССЫЛКА 3. TUIC v5 НАПРЯМУЮ (Макс. скорость / Низкий пинг):"
    echo "$link_tuic"
    echo "QR-код TUIC v5 DIRECT:"
    qrencode -t ANSIUTF8 "$link_tuic"
    echo ""
    echo "======================================================"
}

uninstall() {
    echo "Удаление..."
    systemctl stop ${SERVICE_NAME} 2>/dev/null
    systemctl disable ${SERVICE_NAME} 2>/dev/null
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    rm -rf "$BASE_DIR"
    systemctl daemon-reload
    echo "Удаление завершено."
    exit
}

menu() {
    echo
    echo "HY2 (WARP/Direct) + TUIC5 (Direct) 3-in-1 Manager"
    echo "1. Установить / Переустановить"
    echo "2. Показать информацию и QR"
    echo "3. Удалить"
    echo "4. Выход"
    read -p "Выбор: " opt

    case $opt in
        1)
            detect_arch
            install_deps
            download_singbox
            generate_data
            generate_cert
            get_warp_keys
            create_config
            setup_firewall
            create_service
            client_info
            ;;
        2)
            client_info
            ;;
        3)
            uninstall
            ;;
        4)
            exit
            ;;
        *)
            menu
            ;;
    esac
}

# --- Точка входа ---
case "$1" in
    uninstall)
        uninstall
        ;;
    *)
        menu
        ;;
esac