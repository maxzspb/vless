#!/bin/bash
# VPN Setup: VLESS (3x-ui/Xray) + Hysteria2 + Cloudflare WARP
set -e

REPO_RAW="https://raw.githubusercontent.com/maxzspb/vless/main"
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()    { echo -e "\n${CYAN}━━ $1 ━━${NC}"; }

# ── Зависимости и Docker ─────────────────────────────────────
apt-get update -qq && apt-get install -y -qq \
    curl wget wireguard-tools iptables netfilter-persistent \
    iptables-persistent lsb-release openssl sqlite3 >/dev/null 2>&1

if ! command -v docker &>/dev/null; then
    curl -fsSL https://get.docker.com | sh
    systemctl enable docker && systemctl start docker
fi

if docker compose version &>/dev/null; then
    DC="docker compose"
elif command -v docker-compose &>/dev/null; then
    DC="docker-compose"
else
    curl -sSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(uname -m)" \
        -o /usr/local/bin/docker-compose && chmod +x /usr/local/bin/docker-compose
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
EOF
chmod 600 $WORKDIR/.env
info ".env создан"

# ── TLS-сертификат ───────────────────────────────────────────
step "TLS-сертификат"
if [ -f $WORKDIR/cert/cert.crt ] && [ -f $WORKDIR/cert/private.key ]; then
    info "Сертификат уже существует — пропускаем"
elif [ -n "$DOMAIN" ]; then
    info "Выпускаем сертификат для $DOMAIN..."
    ss -tlnp | grep -q ':80 ' && error "Порт 80 занят"
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
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout $WORKDIR/cert/private.key \
        -out    $WORKDIR/cert/cert.crt \
        -days 3650 -subj "/CN=bing.com" 2>/dev/null
    info "Самоподписанный сертификат создан"
fi

# ── GeoIP базы ───────────────────────────────────────────────
step "GeoIP базы"
download_geo() {
    local url=$1 out=$2
    if [ -s "$out" ]; then info "$(basename $out) уже есть"; return; fi
    wget -q --connect-timeout=10 --tries=2 -O "$out.tmp" "$url" && \
        mv "$out.tmp" "$out" && info "$(basename $out) загружен" || \
        { warning "Не удалось скачать $(basename $out)"; rm -f "$out.tmp"; }
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
WARP_ALIVE=false
if ip link show warp &>/dev/null && [ -f /etc/wireguard/warp.conf ]; then
    if curl -s --interface warp --connect-timeout 8 https://ifconfig.me >/dev/null 2>&1; then
        WARP_IP=$(curl -s --interface warp --connect-timeout 8 https://ifconfig.me 2>/dev/null || true)
        info "WARP жив. IP: $WARP_IP"
        WARP_ALIVE=true
    else
        warning "WARP мёртв — пересоздаём..."
        wg-quick down warp 2>/dev/null || true
        rm -f /etc/wireguard/warp.conf
    fi
fi

if [ "$WARP_ALIVE" = false ]; then
    if ! command -v warp-cli &>/dev/null; then
        info "Устанавливаем warp-cli..."
        curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
            gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
        echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | \
            tee /etc/apt/sources.list.d/cloudflare-client.list >/dev/null
        apt-get update -qq && apt-get install -y -qq cloudflare-warp
    fi

    info "Регистрируем WARP аккаунт..."
    systemctl restart warp-svc 2>/dev/null || true
    sleep 4
    warp-cli --accept-tos registration new 2>/dev/null || true
    sleep 6

    WARP_PRIVATE=$(warp-cli --accept-tos registration show 2>/dev/null | grep -i "private" | awk '{print $NF}' || true)
    WARP_ADDRESS=$(warp-cli --accept-tos registration show 2>/dev/null | grep -i "IPv4\|address" | head -1 | awk '{print $NF}' || true)

    if [ -n "$WARP_PRIVATE" ]; then
        WARP_KEY_USE="$WARP_PRIVATE"
        WARP_ADDR_USE="${WARP_ADDRESS:-172.16.0.2}/32"
        info "Личные ключи WARP получены"
    else
        warning "warp-cli не вернул ключи — используем резервные публичные"
        WARP_KEY_USE="qAK9pGqPyHiY6i/MZjJJPhvCFFt13YhyXWe73ZFKXlE="
        WARP_ADDR_USE="172.16.0.2/32"
    fi

    # Table=off + policy routing — Xray использует sendThrough:172.16.0.2
    # ядро Linux видит src 172.16.0.2 → таблица 2408 → dev warp
    cat > /etc/wireguard/warp.conf << EOF
[Interface]
PrivateKey = $WARP_KEY_USE
Address = $WARP_ADDR_USE
MTU = 1280
Table = off
PostUp   = ip route add default dev warp table 2408; ip rule add from 172.16.0.2 lookup 2408 priority 100 2>/dev/null || true
PostDown = ip route del default dev warp table 2408 2>/dev/null || true; ip rule del from 172.16.0.2 lookup 2408 priority 100 2>/dev/null || true

[Peer]
PublicKey = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = engage.cloudflareclient.com:2408
PersistentKeepalive = 25
EOF

    wg-quick up warp 2>/dev/null || true
    systemctl enable wg-quick@warp 2>/dev/null || true
    sleep 3
    WARP_IP=$(curl -s --interface warp --connect-timeout 8 https://ifconfig.me 2>/dev/null || true)
    [ -n "$WARP_IP" ] && info "WARP работает. IP: $WARP_IP" || warning "WARP не ответил — проверь вручную"
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
sleep 8

FAILED=false
$INSTALL_VLESS && ! docker ps | grep -q "3x-ui"    && { warning "3x-ui не запустился"; FAILED=true; }
$INSTALL_HY    && ! docker ps | grep -q "hysteria2" && { warning "hysteria2 не запустился"; FAILED=true; }
$FAILED && error "Проверь логи: $DC logs"
info "Контейнеры запущены"

# ── Настройка 3x-ui через API + SQLite ───────────────────────
if $INSTALL_VLESS; then
    step "Настройка VLESS"

    # Генерируем ключи через xray внутри контейнера
    KEYPAIR=""
    for i in $(seq 1 15); do
        KEYPAIR=$(docker exec 3x-ui /usr/local/x-ui/bin/xray x25519 2>/dev/null || \
                  docker exec 3x-ui xray x25519 2>/dev/null || echo "")
        [ -n "$(echo $KEYPAIR | grep -i private)" ] && break
        sleep 2
    done
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo  "$KEYPAIR" | grep -i "public"  | awk '{print $NF}')
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 4)

    if [ -z "$PRIVATE_KEY" ]; then
        warning "xray не сгенерировал ключи — нажми Get New Cert в панели"
        PRIVATE_KEY="CHANGE_IN_PANEL"
        PUBLIC_KEY="CHANGE_IN_PANEL"
    else
        info "Reality keypair готов"
    fi
    info "UUID: $UUID  ShortID: $SHORT_ID"

    # Ждём инициализации БД 3x-ui
    for i in $(seq 1 20); do
        [ -f $WORKDIR/db/x-ui.db ] && \
            sqlite3 $WORKDIR/db/x-ui.db "SELECT 1 FROM users LIMIT 1;" &>/dev/null && break
        sleep 2
    done

    # Настраиваем через API (3x-ui должен уже быть готов)
    XUI_URL="http://127.0.0.1:$XUI_PORT"
    COOKIE_JAR=$(mktemp)

    # Логин
    LOGIN_OK=$(curl -s -c "$COOKIE_JAR" -X POST "$XUI_URL/login" \
        -F "username=admin" -F "password=admin" | \
        python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success','false'))" 2>/dev/null || echo "false")

    if [ "$LOGIN_OK" = "True" ] || [ "$LOGIN_OK" = "true" ]; then
        info "Авторизация в 3x-ui OK"

        # Строим JSON для inbound (settings/streamSettings — строки, а не объекты!)
        SETTINGS_JSON="{\"clients\":[{\"id\":\"$UUID\",\"email\":\"user\",\"flow\":\"\",\"enable\":true,\"limitIp\":0,\"totalGB\":0,\"expiryTime\":0,\"reset\":0,\"subId\":\"\",\"comment\":\"\"}],\"decryption\":\"none\",\"encryption\":\"none\",\"fallbacks\":[]}"
        STREAM_JSON="{\"network\":\"xhttp\",\"security\":\"reality\",\"realitySettings\":{\"show\":false,\"xver\":0,\"target\":\"www.microsoft.com:443\",\"serverNames\":[\"www.microsoft.com\"],\"privateKey\":\"$PRIVATE_KEY\",\"minClientVer\":\"\",\"maxClientVer\":\"\",\"maxTimediff\":0,\"shortIds\":[\"$SHORT_ID\"],\"settings\":{\"publicKey\":\"$PUBLIC_KEY\",\"fingerprint\":\"chrome\",\"serverName\":\"\",\"spiderX\":\"/\"}},\"xhttpSettings\":{\"path\":\"/\",\"host\":\"\",\"headers\":{},\"noSSEHeader\":false,\"xPaddingBytes\":\"100-1000\",\"mode\":\"auto\"}}"
        SNIFF_JSON="{\"enabled\":true,\"destOverride\":[\"http\",\"tls\",\"quic\",\"fakedns\"],\"metadataOnly\":false,\"routeOnly\":false}"

        # Добавляем inbound через API
        ADD_RESULT=$(curl -s -b "$COOKIE_JAR" -X POST "$XUI_URL/xui/API/inbounds/add" \
            -H "Content-Type: application/json" \
            -d "{\"remark\":\"VLESS-2026\",\"enable\":true,\"listen\":\"\",\"port\":443,\"protocol\":\"vless\",\"settings\":$(echo $SETTINGS_JSON | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'),\"streamSettings\":$(echo $STREAM_JSON | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'),\"sniffing\":$(echo $SNIFF_JSON | python3 -c 'import json,sys; print(json.dumps(sys.stdin.read().strip()))'),\"expiryTime\":0}" \
            2>/dev/null || echo "{}")

        ADD_OK=$(echo "$ADD_RESULT" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('success','false'))" 2>/dev/null || echo "false")

        if [ "$ADD_OK" = "True" ] || [ "$ADD_OK" = "true" ]; then
            info "Inbound VLESS добавлен через API"
        else
            warning "API inbound не добавился ($(echo $ADD_RESULT | head -c 100)) — добавь вручную в панели"
        fi

        # Настраиваем outbounds через SQLite (API для Xray Configs менее стабилен)
        # Останавливаем 3x-ui чтобы безопасно писать в БД
        docker stop 3x-ui > /dev/null 2>&1 || true
        sleep 2

        # Пишем outbounds/routing/dns в settings таблицу 3x-ui
        OUTBOUNDS_JSON='[{"tag":"warp","protocol":"freedom","settings":{"domainStrategy":"UseIPv4"},"sendThrough":"172.16.0.2"},{"tag":"direct","protocol":"freedom","settings":{"domainStrategy":"AsIs"}},{"tag":"blocked","protocol":"blackhole","settings":{}}]'
        ROUTING_JSON='{"domainStrategy":"AsIs","rules":[{"type":"field","ip":["1.1.1.1","8.8.8.8"],"outboundTag":"direct"},{"type":"field","ip":["geoip:ru"],"outboundTag":"blocked"},{"type":"field","inboundTag":["api"],"outboundTag":"api"},{"type":"field","ip":["geoip:private"],"outboundTag":"blocked"},{"type":"field","outboundTag":"blocked","protocol":["bittorrent"]},{"type":"field","inboundTag":["dns_inbound"],"outboundTag":"warp"}]}'
        DNS_JSON='{"servers":[{"address":"1.1.1.1","port":53,"queryStrategy":"UseIP","skipFallback":true},{"address":"8.8.8.8","port":53,"queryStrategy":"UseIP","skipFallback":true}],"queryStrategy":"UseIP","tag":"dns_inbound"}'

        sqlite3 $WORKDIR/db/x-ui.db "INSERT OR REPLACE INTO settings (key, value) VALUES ('xrayOutboundConfig', '$(echo $OUTBOUNDS_JSON | sed "s/'/''/g")');" 2>/dev/null || true
        sqlite3 $WORKDIR/db/x-ui.db "INSERT OR REPLACE INTO settings (key, value) VALUES ('xrayRoutingConfig', '$(echo $ROUTING_JSON | sed "s/'/''/g")');" 2>/dev/null || true
        sqlite3 $WORKDIR/db/x-ui.db "INSERT OR REPLACE INTO settings (key, value) VALUES ('xrayDNSConfig', '$(echo $DNS_JSON | sed "s/'/''/g")');" 2>/dev/null || true

        docker start 3x-ui > /dev/null 2>&1 || true
        sleep 5
        info "Outbounds/routing/DNS записаны в БД"

    else
        warning "Авторизация в 3x-ui не удалась — настрой outbounds/inbound вручную в панели"
        warning "Ключи для inbound сохранены в $WORKDIR/vless-keys.txt"
    fi

    rm -f "$COOKIE_JAR"

    # Сохраняем ключи для ручной настройки/проверки
    VPS_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)
    cat > $WORKDIR/vless-keys.txt << EOF
UUID:        $UUID
PrivateKey:  $PRIVATE_KEY
PublicKey:   $PUBLIC_KEY
ShortID:     $SHORT_ID
SNI/Target:  www.microsoft.com
Port:        443
VPS IP:      $VPS_IP
EOF
    info "Ключи сохранены: $WORKDIR/vless-keys.txt"

    # Собираем ссылку
    VLESS_URI="vless://${UUID}@${VPS_IP}:443?type=xhttp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=www.microsoft.com&sid=${SHORT_ID}&spx=%2F&path=%2F&mode=auto#VLESS-$(hostname)"
    echo "$VLESS_URI" > $WORKDIR/vless-uri.txt
fi

# ── Порт панели закрыть снаружи ──────────────────────────────
if $INSTALL_VLESS; then
    step "Безопасность панели"
    iptables -D INPUT -p tcp --dport $XUI_PORT ! -s 127.0.0.1 -j DROP 2>/dev/null || true
    iptables -I INPUT -p tcp --dport $XUI_PORT ! -s 127.0.0.1 -j DROP
    info "Порт $XUI_PORT закрыт снаружи (только SSH-туннель)"
fi

# ── iptables: UDP port hopping → Hysteria2 ───────────────────
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

# ── Cron: автообновление GeoIP ───────────────────────────────
step "Автообновление"
crontab -l 2>/dev/null | grep -v "geosite\|geoip\|acme-renew" | crontab - 2>/dev/null || true
if $INSTALL_VLESS; then
    (crontab -l 2>/dev/null; echo "0 3 * * 0 wget -q -O $WORKDIR/geosite.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat && docker restart 3x-ui") | crontab -
    (crontab -l 2>/dev/null; echo "5 3 * * 0 wget -q -O $WORKDIR/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat") | crontab -
fi
if $INSTALL_HY; then
    (crontab -l 2>/dev/null; echo "10 3 * * 0 wget -q -O $WORKDIR/geoip.mmdb https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb && docker restart hysteria2") | crontab -
fi
[ -n "$DOMAIN" ] && \
    (crontab -l 2>/dev/null; echo "0 4 * * 1 ~/.acme.sh/acme.sh --cron --home ~/.acme.sh >> /var/log/acme-renew.log 2>&1") | crontab - || true
info "Cron настроен"

# ── Итог ─────────────────────────────────────────────────────
MY_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)
SSH_PORT=$(ss -tlnp 2>/dev/null | grep sshd | awk '{print $4}' | cut -d: -f2 | head -1 || echo "22")

echo ""
echo "══════════════════════════════════════════════════════════"
echo -e "${GREEN}   Установка завершена!${NC}"
echo "══════════════════════════════════════════════════════════"
echo ""

if $INSTALL_VLESS; then
    echo -e "  ${CYAN}┌─ ПАНЕЛЬ 3x-ui ──────────────────────────────────────${NC}"
    echo    "  │  ssh -L $XUI_PORT:127.0.0.1:$XUI_PORT root@$MY_IP -p ${SSH_PORT:-22}"
    echo    "  │  http://127.0.0.1:$XUI_PORT   (admin / admin — смени!)"
    echo    "  │"
    echo    "  │  В панели проверь Outbounds — должен быть warp (freedom"
    echo    "  │  + sendThrough 172.16.0.2), Routing Rules и DNS."
    echo    "  │  Если нет — настрой по README.md раздел «Настройка VLESS»"
    echo -e "  ${CYAN}└─────────────────────────────────────────────────────${NC}"
    echo ""
    if [ -f $WORKDIR/vless-uri.txt ]; then
        VLESS_LINK=$(cat $WORKDIR/vless-uri.txt)
        echo -e "  ${CYAN}┌─ VLESS — ссылка подключения ────────────────────────${NC}"
        echo    "  │  $VLESS_LINK"
        echo    "  │  Файл: $WORKDIR/vless-uri.txt"
        echo -e "  ${CYAN}└─────────────────────────────────────────────────────${NC}"
        echo ""
    fi
fi

if $INSTALL_HY; then
    HY_URI="hysteria2://${HY_PASS}@${MY_IP}:443?sni=bing.com&insecure=1&mport=20000-50000#Hysteria2-$(hostname)"
    echo "$HY_URI" > $WORKDIR/hysteria2-uri.txt
    echo -e "  ${CYAN}┌─ HYSTERIA2 ─────────────────────────────────────────${NC}"
    echo    "  │  $HY_URI"
    echo    "  │  Файл: $WORKDIR/hysteria2-uri.txt"
    echo -e "  ${CYAN}└─────────────────────────────────────────────────────${NC}"
    echo ""
fi

echo "  WARP IP: ${WARP_IP:-не определён}"
echo ""
