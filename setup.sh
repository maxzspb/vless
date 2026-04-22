#!/bin/bash
# VPN Setup: VLESS (3x-ui/Xray) + Hysteria2 + Cloudflare WARP
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()    { echo -e "\n${CYAN}━━ $1 ━━${NC}"; }

echo ""
echo "══════════════════════════════════════════"
echo "   VPN Setup: VLESS + Hysteria2 + WARP"
echo "══════════════════════════════════════════"
echo ""

# ── Проверка Docker ──────────────────────────────────────────
step "Проверка зависимостей"
apt update -qq && apt install -y curl wget wireguard-tools iptables resolvconf jq lsb-release coreutils openssl -qq

if ! command -v docker &> /dev/null; then
    info "Устанавливаем Docker..."
    curl -fsSL https://get.docker.com | sh
    systemctl enable --now docker
fi

if docker compose version &> /dev/null; then
    DOCKER_COMPOSE="docker compose"
elif command -v docker-compose &> /dev/null; then
    DOCKER_COMPOSE="docker-compose"
else
    info "Скачиваем Docker Compose..."
    curl -SL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    DOCKER_COMPOSE="docker-compose"
fi

# ── Выбор компонентов ────────────────────────────────────────
echo ""
echo "Что установить?"
echo "  1) VLESS + Hysteria2  (рекомендуется)"
echo "  2) Только VLESS"
echo "  3) Только Hysteria2"
read -p "Выбор [1/2/3]: " INSTALL_MODE
INSTALL_MODE=${INSTALL_MODE:-1}
case "$INSTALL_MODE" in
    1) INSTALL_VLESS=true;  INSTALL_HY=true  ;;
    2) INSTALL_VLESS=true;  INSTALL_HY=false ;;
    3) INSTALL_VLESS=false; INSTALL_HY=true  ;;
    *) error "Неверный выбор." ;;
esac

if $INSTALL_HY; then
    read -sp "Пароль для Hysteria2: " HY_PASS; echo ""
fi
read -p "Домен для TLS-сертификата [Enter = самоподписанный]: " DOMAIN

WORKDIR=~/vless
XUI_PORT=2053
mkdir -p $WORKDIR/{cert,db}

# ── GeoIP базы ───────────────────────────────────────────────
step "GeoIP базы"
download_geo() {
    local url=$1
    local out=$2
    local tmp="${out}.tmp"
    if [ -s "$out" ]; then
        info "$(basename $out) уже есть и не пустой — пропускаем"
        return
    fi
    info "Скачиваем $(basename $out)..."
    if wget -q --show-progress --connect-timeout=5 --tries=2 -O "$tmp" "$url" || \
       wget -q --show-progress --connect-timeout=10 --tries=2 -O "$tmp" "https://mirror.ghproxy.com/$url"; then
        mv "$tmp" "$out"
        info "$(basename $out) загружен"
    else
        warning "Не удалось скачать $(basename $out)"
        rm -f "$tmp"
    fi
}

if $INSTALL_VLESS; then
    download_geo "https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat" "$WORKDIR/geosite.dat"
    download_geo "https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat" "$WORKDIR/geoip.dat"
fi
if $INSTALL_HY; then
    download_geo "https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb" "$WORKDIR/geoip.mmdb"
fi

# ── Cloudflare WARP ──────────────────────────────────────────
step "Cloudflare WARP"
if ip link show warp &>/dev/null && [ -f /etc/wireguard/warp.conf ]; then
    info "WARP настроен. Проверяем соединение..."
    if ! curl -s --interface warp --max-time 5 https://ifconfig.me >/dev/null; then
        warning "WARP завис. Перезапускаем интерфейс..."
        wg-quick down warp 2>/dev/null || true
        wg-quick up warp 2>/dev/null || true
        sleep 3
    fi
    WARP_IP=$(curl -s --interface warp --max-time 10 https://ifconfig.me 2>/dev/null || true)
else
    info "Устанавливаем warp-cli..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null
    apt update -qq && apt install -y cloudflare-warp -qq

    systemctl start warp-svc 2>/dev/null || true
    sleep 2
    warp-cli --accept-tos registration new 2>/dev/null || true
    sleep 3

    WARP_PRIVATE=$(warp-cli --accept-tos registration show 2>/dev/null | grep -i "private" | awk '{print $NF}')
    if [ -n "$WARP_PRIVATE" ]; then
        WARP_KEY_USE="$WARP_PRIVATE"
        info "Личные ключи WARP получены"
    else
        warning "Используем резервные публичные ключи WARP"
        WARP_KEY_USE="qAK9pGqPyHiY6i/MZjJJPhvCFFt13YhyXWe73ZFKXlE="
    fi

    cat > /etc/wireguard/warp.conf << EOF
[Interface]
PrivateKey = $WARP_KEY_USE
Address = 172.16.0.2/32
MTU = 1420
Table = off
PostUp = ip route add default dev warp table 2408; ip rule add from 172.16.0.2 lookup 2408 2>/dev/null || true
PostDown = ip route del default dev warp table 2408 2>/dev/null || true; ip rule del from 172.16.0.2 lookup 2408 2>/dev/null || true

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.cloudflareclient.com:2408
PersistentKeepalive = 25
EOF

    wg-quick up warp 2>/dev/null || true
    systemctl enable wg-quick@warp
    WARP_IP=$(curl -s --interface warp --max-time 10 https://ifconfig.me 2>/dev/null || true)
fi

[ -n "$WARP_IP" ] && info "WARP работает. IP: $WARP_IP" || warning "WARP не ответил"

# ── Hysteria2 конфиг ─────────────────────────────────────────
if $INSTALL_HY; then
    step "Hysteria2"
    # (Генерация самоподписанного сертификата, если нет домена, оставлена как в оригинале)
    if [ ! -f $WORKDIR/cert/cert.crt ]; then
        openssl req -x509 -nodes -newkey rsa:2048 -keyout $WORKDIR/cert/private.key -out $WORKDIR/cert/cert.crt -days 3650 -subj "/CN=bing.com" 2>/dev/null
    fi

    cat > $WORKDIR/hysteria.yaml << EOF
listen: :8443
tls:
  cert: /root/cert/cert.crt
  key:  /root/cert/private.key
auth:
  type: password
  password: $HY_PASS
masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true
outbounds:
  - name: warp
    type: direct
    direct:
      bindDevice: warp
      mode: auto
acl:
  inline:
    - reject(geoip:ru)
    - warp(all)
EOF
    info "hysteria.yaml создан"
fi

# ── docker-compose ───────────────────────────────────────────
step "docker-compose"
cat > $WORKDIR/docker-compose.yaml << 'EOF'
services:
EOF

if $INSTALL_VLESS; then
    cat >> $WORKDIR/docker-compose.yaml << 'EOF'
  3x-ui:
    image: ghcr.io/mhsanaei/3x-ui:latest
    container_name: 3x-ui
    environment:
      - XRAY_VMESS_AEAD_FORCED=false
    volumes:
      - ./db:/etc/x-ui
      - ./cert:/root/cert
      - ./geosite.dat:/usr/local/x-ui/bin/geosite.dat
      - ./geoip.dat:/usr/local/x-ui/bin/geoip.dat
    network_mode: host
    restart: unless-stopped
EOF
fi

if $INSTALL_HY; then
    cat >> $WORKDIR/docker-compose.yaml << 'EOF'
  hysteria2:
    image: tobyxdd/hysteria
    container_name: hysteria2
    network_mode: host
    volumes:
      - ./cert:/root/cert
      - ./hysteria.yaml:/etc/hysteria.yaml
      - ./geoip.mmdb:/etc/hysteria/Country.mmdb
    command: ["server", "-c", "/etc/hysteria.yaml"]
    restart: unless-stopped
EOF
fi

cd $WORKDIR
$DOCKER_COMPOSE up -d --no-recreate
sleep 5

# ── Xray конфиг (Вшитый локально) ────────────────────────────
if $INSTALL_VLESS; then
    step "Xray конфиг"
    
    # Ищем бинарник Xray внутри контейнера (xray или xray-linux-amd64)
    XRAY_BIN=$(docker exec 3x-ui sh -c 'ls /usr/local/x-ui/bin/xray* | head -n 1' 2>/dev/null || echo "/usr/local/x-ui/bin/xray")
    
    KEYPAIR=$(docker exec 3x-ui $XRAY_BIN x25519 2>/dev/null || echo "")
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYPAIR"  | grep -i "public"  | awk '{print $NF}')

    if [ -z "$PRIVATE_KEY" ]; then
        warning "Не удалось сгенерировать ключи через Xray, используем заглушки."
        PRIVATE_KEY="GENERATE_IN_PANEL"
        PUBLIC_KEY="CHECK_PANEL"
    fi

    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 4)
    info "UUID: $UUID"
    info "Reality PrivateKey: $PRIVATE_KEY"

    # Создаем ИДЕАЛЬНЫЙ локальный темплейт конфига
    cat > $WORKDIR/xray_config_template.json << 'EOF'
{
  "log": { "access": "none", "dnsLog": false, "error": "", "loglevel": "warning", "maskAddress": "" },
  "api": { "tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"] },
  "inbounds": [
    { "tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "tunnel", "settings": { "address": "127.0.0.1" } },
    {
      "tag": "inbound-443", "listen": "", "port": 443, "protocol": "vless",
      "settings": {
        "clients": [
          { "id": "PLACEHOLDER_UUID", "email": "user", "flow": "", "enable": true, "limitIp": 0, "totalGB": 0, "expiryTime": 0, "reset": 0, "subId": "", "comment": "" }
        ],
        "decryption": "none", "encryption": "none", "fallbacks": []
      },
      "streamSettings": {
        "network": "xhttp", "security": "reality",
        "realitySettings": {
          "show": false, "xver": 0, "target": "www.microsoft.com:443", "serverNames": ["www.microsoft.com"],
          "privateKey": "PLACEHOLDER_PRIVATE_KEY", "minClientVer": "", "maxClientVer": "", "maxTimediff": 0,
          "shortIds": ["PLACEHOLDER_SHORT_ID"],
          "settings": { "publicKey": "PLACEHOLDER_PUBLIC_KEY", "fingerprint": "chrome", "serverName": "", "spiderX": "/" }
        },
        "xhttpSettings": { "path": "/", "host": "", "headers": {}, "noSSEHeader": false, "xPaddingBytes": "100-1000", "mode": "auto" }
      },
      "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": false, "routeOnly": false }
    }
  ],
  "outbounds": [
    { "tag": "warp", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" }, "sendThrough": "172.16.0.2" },
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "AsIs" } },
    { "tag": "blocked", "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "ip": ["1.1.1.1", "8.8.8.8"], "outboundTag": "direct" },
      { "type": "field", "ip": ["geoip:ru"], "outboundTag": "blocked" },
      { "type": "field", "inboundTag": ["api"], "outboundTag": "api" },
      { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" },
      { "type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"] },
      { "type": "field", "inboundTag": ["dns_inbound"], "outboundTag": "warp" }
    ]
  },
  "dns": {
    "servers": [
      { "address": "1.1.1.1", "port": 53, "queryStrategy": "UseIP", "skipFallback": true },
      { "address": "8.8.8.8", "port": 53, "queryStrategy": "UseIP", "skipFallback": true }
    ],
    "queryStrategy": "UseIP", "tag": "dns_inbound"
  },
  "policy": {
    "levels": { "0": { "statsUserDownlink": true, "statsUserUplink": true } },
    "system": { "statsInboundDownlink": true, "statsInboundUplink": true, "statsOutboundDownlink": false, "statsOutboundUplink": false }
  },
  "stats": {}
}
EOF

    # Подменяем переменные в конфиге
    sed \
        -e "s/PLACEHOLDER_UUID/$UUID/g" \
        -e "s/PLACEHOLDER_PRIVATE_KEY/$PRIVATE_KEY/g" \
        -e "s/PLACEHOLDER_PUBLIC_KEY/$PUBLIC_KEY/g" \
        -e "s/PLACEHOLDER_SHORT_ID/$SHORT_ID/g" \
        $WORKDIR/xray_config_template.json > $WORKDIR/xray_config.json

    docker cp $WORKDIR/xray_config.json 3x-ui:/app/bin/config.json
    docker restart 3x-ui 2>/dev/null || true
    sleep 4
    info "Xray конфиг применён (из локального шаблона)"

    VPS_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)
    VLESS_URI="vless://${UUID}@${VPS_IP}:443?type=xhttp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=www.microsoft.com&sid=${SHORT_ID}&spx=%2F&path=%2F&mode=auto#VLESS-$(hostname)"
    echo "$VLESS_URI" > $WORKDIR/vless-uri.txt
    info "VLESS URI: $VLESS_URI"
fi

# ── iptables: UDP port hopping для Hysteria2 ─────────────────
if $INSTALL_HY; then
    step "iptables / port hopping"
    iptables -t nat -D PREROUTING -p udp --dport 443         -j REDIRECT --to-port 8443 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport 20000:31462 -j REDIRECT --to-port 8443 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport 31464:50000 -j REDIRECT --to-port 8443 2>/dev/null || true
    iptables -t nat -A PREROUTING -p udp --dport 443         -j REDIRECT --to-port 8443
    iptables -t nat -A PREROUTING -p udp --dport 20000:31462 -j REDIRECT --to-port 8443
    iptables -t nat -A PREROUTING -p udp --dport 31464:50000 -j REDIRECT --to-port 8443
    netfilter-persistent save 2>/dev/null || true
    info "UDP 443 + 20000-50000 → 8443"
fi

echo -e "\n${GREEN}Установка завершена! Конфиг прошит, ключи готовы.${NC}"