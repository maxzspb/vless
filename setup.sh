#!/bin/bash
# VPN Setup: VLESS (3x-ui/Xray) + Hysteria2 + Cloudflare WARP
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()    { echo -e "\n${CYAN}━━ $1 ━━${NC}"; }

# ── Проверка пакетов и Docker ────────────────────────────────
apt-get update -qq && apt-get install -y curl wget wireguard-tools iptables resolvconf jq lsb-release coreutils openssl -qq >/dev/null 2>&1

if docker compose version &>/dev/null; then
    DC="docker compose"
elif command -v docker-compose &>/dev/null; then
    DC="docker-compose"
else
    curl -sSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" -o /usr/local/bin/docker-compose
    chmod +x /usr/local/bin/docker-compose
    DC="docker-compose"
fi

echo ""
echo "══════════════════════════════════════════"
echo "   VPN Setup: VLESS + Hysteria2 + WARP"
echo "══════════════════════════════════════════"
echo ""

# ── Выбор компонентов ────────────────────────────────────────
echo "Что установить?"
echo "  1) VLESS + Hysteria2  (рекомендуется)"
echo "  2) Только VLESS"
echo "  3) Только Hysteria2"
echo ""
read -p "Выбор [1/2/3]: " INSTALL_MODE
INSTALL_MODE=${INSTALL_MODE:-1}
case "$INSTALL_MODE" in
    1) INSTALL_VLESS=true;  INSTALL_HY=true  ;;
    2) INSTALL_VLESS=true;  INSTALL_HY=false ;;
    3) INSTALL_VLESS=false; INSTALL_HY=true  ;;
    *) error "Неверный выбор." ;;
esac
echo ""

if $INSTALL_HY; then
    read -sp "Пароль для Hysteria2: " HY_PASS; echo ""
fi
read -p "Домен для TLS-сертификата [Enter = самоподписанный]: " DOMAIN

WORKDIR=~/vless
XUI_PORT=2053
mkdir -p $WORKDIR/{cert,db}

# ── .env ─────────────────────────────────────────────────────
step "Конфиг"
cat > $WORKDIR/.env << EOF
HYSTERIA_PASSWORD=${HY_PASS:-}
DOMAIN=${DOMAIN:-}
INSTALL_VLESS=$INSTALL_VLESS
INSTALL_HY=$INSTALL_HY
XUI_PORT=$XUI_PORT
SSH_USER=${SUDO_USER:-$USER}
EOF
chmod 600 $WORKDIR/.env
info ".env создан"

# ── TLS-сертификат ───────────────────────────────────────────
step "TLS-сертификат"
if [ -f $WORKDIR/cert/cert.crt ] && [ -f $WORKDIR/cert/private.key ]; then
    info "Сертификат уже существует — пропускаем"
elif [ -n "$DOMAIN" ]; then
    info "Выпускаем сертификат для $DOMAIN..."
    ss -tlnp | grep -q ':80 ' && error "Порт 80 занят — освободи и перезапусти скрипт"
    curl -s https://get.acme.sh | sh -s email=admin@$DOMAIN
    source ~/.bashrc
    ~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
    ~/.acme.sh/acme.sh --issue -d $DOMAIN --standalone
    ~/.acme.sh/acme.sh --install-cert -d $DOMAIN \
        --key-file  $WORKDIR/cert/private.key \
        --fullchain-file $WORKDIR/cert/cert.crt
    info "Сертификат выпущен для $DOMAIN"
else
    warning "Домен не указан — генерируем самоподписанный сертификат"
    openssl req -x509 -nodes -newkey rsa:2048 -keyout $WORKDIR/cert/private.key -out $WORKDIR/cert/cert.crt -days 3650 -subj "/CN=bing.com" 2>/dev/null
    info "Самоподписанный сертификат создан"
fi

# ── GeoIP базы ───────────────────────────────────────────────
step "GeoIP базы"
download_geo() {
    local url=$1
    local out=$2
    if [ -s "$out" ]; then info "$(basename $out) уже есть"; return; fi
    if wget -q --connect-timeout=5 --tries=2 -O "$out.tmp" "$url" || \
       wget -q --connect-timeout=5 --tries=2 -O "$out.tmp" "https://mirror.ghproxy.com/$url"; then
        mv "$out.tmp" "$out"
        info "$(basename $out) загружен"
    else
        warning "Не удалось скачать $(basename $out)"
        rm -f "$out.tmp"
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
if ip link show warp &>/dev/null || [ -f /etc/wireguard/warp.conf ]; then
    info "Найден старый конфиг WARP. Проверяем..."
    if ! curl -s --interface warp --connect-timeout 5 https://ifconfig.me >/dev/null; then
        warning "WARP мертв (нет handshake). Сносим и делаем заново..."
        wg-quick down warp 2>/dev/null || true
        rm -f /etc/wireguard/warp.conf
    else
        WARP_IP=$(curl -s --interface warp --connect-timeout 5 https://ifconfig.me)
        info "WARP жив. IP: $WARP_IP"
    fi
fi

if [ ! -f /etc/wireguard/warp.conf ]; then
    info "Настраиваем WARP с нуля..."
    if ! command -v warp-cli &>/dev/null; then
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null
        apt update -qq && apt install -y cloudflare-warp -qq
    fi

    systemctl restart warp-svc 2>/dev/null || true
    sleep 3
    warp-cli --accept-tos registration new 2>/dev/null || true
    sleep 5

    WARP_PRIVATE=$(warp-cli --accept-tos registration show 2>/dev/null | grep -i "private" | awk '{print $NF}')
    WARP_ADDRESS=$(warp-cli --accept-tos registration show 2>/dev/null | grep -i "IPv4\|address" | head -1 | awk '{print $NF}')

    if [ -n "$WARP_PRIVATE" ]; then
        WARP_KEY_USE="$WARP_PRIVATE"
        WARP_ADDR_USE="${WARP_ADDRESS:-172.16.0.2}/32"
        info "Личные ключи WARP получены"
    else
        warning "warp-cli не вернул ключи — используем публичные"
        WARP_KEY_USE="qAK9pGqPyHiY6i/MZjJJPhvCFFt13YhyXWe73ZFKXlE="
        WARP_ADDR_USE="172.16.0.2/32"
    fi

    cat > /etc/wireguard/warp.conf << EOF
[Interface]
PrivateKey = $WARP_KEY_USE
Address = $WARP_ADDR_USE
MTU = 1280
Table = off
PostUp = ip route add default dev warp table 2408; ip rule add from 172.16.0.2 lookup 2408 2>/dev/null || true
PostDown = ip route del default dev warp table 2408 2>/dev/null || true; ip rule del from 172.16.0.2 lookup 2408 2>/dev/null || true

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = 162.159.192.1:2408
PersistentKeepalive = 25
EOF

    wg-quick up warp 2>/dev/null || true
    systemctl enable wg-quick@warp
    WARP_IP=$(curl -s --interface warp --connect-timeout 5 https://ifconfig.me 2>/dev/null || echo "НЕ ОТВЕТИЛ")
    info "WARP статус: $WARP_IP"
fi

# ── Hysteria2 конфиг ─────────────────────────────────────────
if $INSTALL_HY; then
    step "Hysteria2"
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
cat > $WORKDIR/docker-compose.yaml << 'DCEOF'
services:
DCEOF

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
info "docker-compose.yaml создан"

# ── Запуск контейнеров ───────────────────────────────────────
step "Docker"
cd $WORKDIR
$DC up -d --no-recreate
sleep 5

FAILED=false
$INSTALL_VLESS && ! docker ps | grep -q "3x-ui"    && { warning "3x-ui не запустился"; FAILED=true; }
$INSTALL_HY    && ! docker ps | grep -q "hysteria2" && { warning "hysteria2 не запустился"; FAILED=true; }
$FAILED && error "Проверь логи: $DC logs"
info "Контейнеры запущены"

# ── Xray конфиг — генерируем и применяем автоматически ───────
if $INSTALL_VLESS; then
    step "Xray конфиг"

    info "Ждем загрузки ядра Xray внутри контейнера..."
    PRIVATE_KEY=""
    PUBLIC_KEY=""
    for i in $(seq 1 15); do
        KEYPAIR=$(docker exec 3x-ui /usr/local/x-ui/bin/xray x25519 2>/dev/null || docker exec 3x-ui xray x25519 2>/dev/null || echo "")
        PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "private" | awk '{print $NF}')
        PUBLIC_KEY=$(echo "$KEYPAIR"  | grep -i "public"  | awk '{print $NF}')
        if [ -n "$PRIVATE_KEY" ]; then
            break
        fi
        sleep 2
    done

    if [ -z "$PRIVATE_KEY" ]; then
        warning "Xray так и не загрузился, используем заглушки."
        PRIVATE_KEY="GENERATE_IN_PANEL"
        PUBLIC_KEY="CHECK_PANEL"
    else
        info "Reality PrivateKey сгенерирован!"
    fi

    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 4)
    info "UUID: $UUID"

    XRAY_TPL=$WORKDIR/xray_config_template.json
    if [ ! -f "$XRAY_TPL" ]; then
        cat > "$XRAY_TPL" << 'EOF'
{
  "log": { "access": "none", "dnsLog": false, "error": "", "loglevel": "warning", "maskAddress": "" },
  "api": { "tag": "api", "services": ["HandlerService", "LoggerService", "StatsService"] },
  "inbounds": [
    { "tag": "api", "listen": "127.0.0.1", "port": 62789, "protocol": "tunnel", "settings": { "address": "127.0.0.1" } },
    { "tag": "inbound-443", "listen": "", "port": 443, "protocol": "vless", "settings": { "clients": [ { "id": "PLACEHOLDER_UUID", "email": "user", "flow": "", "enable": true, "limitIp": 0, "totalGB": 0, "expiryTime": 0, "reset": 0, "subId": "", "comment": "" } ], "decryption": "none", "encryption": "none", "fallbacks": [] }, "streamSettings": { "network": "xhttp", "security": "reality", "realitySettings": { "show": false, "xver": 0, "target": "www.microsoft.com:443", "serverNames": ["www.microsoft.com"], "privateKey": "PLACEHOLDER_PRIVATE_KEY", "minClientVer": "", "maxClientVer": "", "maxTimediff": 0, "shortIds": ["PLACEHOLDER_SHORT_ID"], "settings": { "publicKey": "PLACEHOLDER_PUBLIC_KEY", "fingerprint": "chrome", "serverName": "", "spiderX": "/" } }, "xhttpSettings": { "path": "/", "host": "", "headers": {}, "noSSEHeader": false, "xPaddingBytes": "100-1000", "mode": "auto" } }, "sniffing": { "enabled": true, "destOverride": ["http", "tls", "quic", "fakedns"], "metadataOnly": false, "routeOnly": false } }
  ],
  "outbounds": [
    { "tag": "warp", "protocol": "freedom", "settings": { "domainStrategy": "UseIPv4" }, "sendThrough": "172.16.0.2" },
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "AsIs" } },
    { "tag": "blocked", "protocol": "blackhole", "settings": {} }
  ],
  "routing": { "domainStrategy": "AsIs", "rules": [ { "type": "field", "ip": ["1.1.1.1", "8.8.8.8"], "outboundTag": "direct" }, { "type": "field", "ip": ["geoip:ru"], "outboundTag": "blocked" }, { "type": "field", "inboundTag": ["api"], "outboundTag": "api" }, { "type": "field", "ip": ["geoip:private"], "outboundTag": "blocked" }, { "type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"] }, { "type": "field", "inboundTag": ["dns_inbound"], "outboundTag": "warp" } ] },
  "dns": { "servers": [ { "address": "1.1.1.1", "port": 53, "queryStrategy": "UseIP", "skipFallback": true }, { "address": "8.8.8.8", "port": 53, "queryStrategy": "UseIP", "skipFallback": true } ], "queryStrategy": "UseIP", "tag": "dns_inbound" },
  "policy": { "levels": { "0": { "statsUserDownlink": true, "statsUserUplink": true } }, "system": { "statsInboundDownlink": true, "statsInboundUplink": true, "statsOutboundDownlink": false, "statsOutboundUplink": false } },
  "stats": {}
}
EOF
    fi

    if [ -f "$XRAY_TPL" ]; then
        sed \
            -e "s/PLACEHOLDER_UUID/$UUID/g" \
            -e "s/PLACEHOLDER_PRIVATE_KEY/$PRIVATE_KEY/g" \
            -e "s/PLACEHOLDER_PUBLIC_KEY/$PUBLIC_KEY/g" \
            -e "s/PLACEHOLDER_SHORT_ID/$SHORT_ID/g" \
            "$XRAY_TPL" > $WORKDIR/xray_config.json

        docker cp $WORKDIR/xray_config.json 3x-ui:/app/bin/config.json
        docker restart 3x-ui 2>/dev/null || true
        sleep 4
        info "Xray конфиг применён"

        VPS_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
        VLESS_URI="vless://${UUID}@${VPS_IP}:443?type=xhttp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=www.microsoft.com&sid=${SHORT_ID}&spx=%2F&path=%2F&mode=auto#VLESS-$(hostname)"
        echo "$VLESS_URI" > $WORKDIR/vless-uri.txt
        info "VLESS URI сохранён: $WORKDIR/vless-uri.txt"
    fi
fi

# ── Безопасность: закрыть порт панели снаружи ────────────────
if $INSTALL_VLESS; then
    step "Безопасность панели"
    iptables -D INPUT -p tcp --dport $XUI_PORT ! -s 127.0.0.1 -j DROP 2>/dev/null || true
    iptables -I INPUT -p tcp --dport $XUI_PORT ! -s 127.0.0.1 -j DROP
    info "Порт $XUI_PORT закрыт снаружи"
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

# ── DNS ──────────────────────────────────────────────────────
step "DNS"
resolvectl dns ens3 1.1.1.1 8.8.8.8 2>/dev/null || \
resolvectl dns eth0 1.1.1.1 8.8.8.8 2>/dev/null || \
echo "nameserver 1.1.1.1" > /etc/resolv.conf
info "DNS: 1.1.1.1, 8.8.8.8"

# ── Итог ─────────────────────────────────────────────────────
MY_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null)
SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | cut -d: -f2 | head -1 || echo "22")

echo ""
echo "══════════════════════════════════════════════════════════"
echo -e "${GREEN}   Установка завершена!${NC}"
echo "══════════════════════════════════════════════════════════"
echo ""

if $INSTALL_VLESS; then
    echo -e "  ${CYAN}┌─ ПАНЕЛЬ 3x-ui ──────────────────────────────────────${NC}"
    echo    "  │  ssh -L $XUI_PORT:127.0.0.1:$XUI_PORT ${SSH_USER}@$MY_IP -p ${SSH_PORT:-22}"
    echo    "  │  Затем: http://127.0.0.1:$XUI_PORT"
    echo -e "  ${CYAN}└─────────────────────────────────────────────────────${NC}"
    echo ""

    if [ -f $WORKDIR/vless-uri.txt ]; then
        VLESS_URI=$(cat $WORKDIR/vless-uri.txt)
        echo -e "  ${CYAN}┌─ VLESS — готовая ссылка ────────────────────────────${NC}"
        echo    "  │  $VLESS_URI"
        echo -e "  ${CYAN}└─────────────────────────────────────────────────────${NC}"
        echo ""
    fi
fi

if $INSTALL_HY; then
    HY_URI="hysteria2://${HY_PASS}@${MY_IP}:443?sni=bing.com&insecure=1&mport=20000-50000#Hysteria2-$(hostname)"
    echo -e "  ${CYAN}┌─ HYSTERIA2 — готовая ссылка ────────────────────────${NC}"
    echo    "  │  $HY_URI"
    echo -e "  ${CYAN}└─────────────────────────────────────────────────────${NC}"
    echo ""
fi

echo "  WARP IP: ${WARP_IP:-не определён}"
echo ""