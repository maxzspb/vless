#!/bin/bash
# VPN Setup: VLESS (3x-ui/Xray) + Hysteria2 + Cloudflare WARP
# https://github.com/maxzspb/vless
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()    { echo -e "\n${CYAN}━━ $1 ━━${NC}"; }

# ── Зависимости и Docker ─────────────────────────────────────
apt-get update -qq && apt-get install -y -qq \
    curl wget wireguard-tools netfilter-persistent \
    iptables-persistent lsb-release openssl sqlite3 python3 >/dev/null 2>&1

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
    wget -q --connect-timeout=15 --tries=3 -O "$out.tmp" "$url" && \
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
    sleep 5
    warp-cli --accept-tos registration new 2>/dev/null || true
    sleep 7

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

    # Table=off + PostUp создаёт таблицу 2408
    # Xray использует sendThrough: 172.16.0.2 → ядро видит src 172.16.0.2 → таблица 2408 → dev warp
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

# ── Настройка VLESS через SQLite (единственный надёжный способ) ──
if $INSTALL_VLESS; then
    step "Настройка VLESS"

    # Генерируем X25519 ключи через openssl
    # (xray бинарник в этом образе: /app/bin/xray-linux-amd64, x25519 не всегда работает)
    PRIVATE_RAW=$(openssl genpkey -algorithm X25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$PRIVATE_RAW" | openssl pkey -outform DER 2>/dev/null | \
        tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
    PUBLIC_KEY=$(echo "$PRIVATE_RAW" | openssl pkey -pubout -outform DER 2>/dev/null | \
        tail -c 32 | base64 | tr '+/' '-_' | tr -d '=\n')
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 4)

    info "UUID: $UUID"
    info "Reality keypair сгенерирован"

    # Ждём инициализации БД 3x-ui
    for i in $(seq 1 25); do
        [ -f $WORKDIR/db/x-ui.db ] && \
            sqlite3 $WORKDIR/db/x-ui.db "SELECT 1 FROM users LIMIT 1;" &>/dev/null && break
        sleep 2
    done

    # Останавливаем 3x-ui для безопасной записи в БД
    docker stop 3x-ui >/dev/null 2>&1 || true
    sleep 2

    python3 << PYEOF
import sqlite3, json

DB = '$WORKDIR/db/x-ui.db'
UUID = '$UUID'
PRIVATE_KEY = '$PRIVATE_KEY'
PUBLIC_KEY = '$PUBLIC_KEY'
SHORT_ID = '$SHORT_ID'

db = sqlite3.connect(DB)
cur = db.cursor()

# --- inbound ---
settings = json.dumps({
    "clients": [{"id": UUID, "email": "user", "flow": "", "enable": True,
                 "limitIp": 0, "totalGB": 0, "expiryTime": 0,
                 "reset": 0, "subId": "", "comment": ""}],
    "decryption": "none", "encryption": "none", "fallbacks": []
})
stream = json.dumps({
    "network": "xhttp", "security": "reality",
    "realitySettings": {
        "show": False, "xver": 0,
        "target": "www.microsoft.com:443",
        "serverNames": ["www.microsoft.com"],
        "privateKey": PRIVATE_KEY,
        "minClientVer": "", "maxClientVer": "", "maxTimediff": 0,
        "shortIds": [SHORT_ID],
        "settings": {"publicKey": PUBLIC_KEY, "fingerprint": "chrome",
                     "serverName": "", "spiderX": "/"}
    },
    "xhttpSettings": {"path": "/", "host": "", "headers": {},
                      "noSSEHeader": False, "xPaddingBytes": "100-1000", "mode": "auto"}
})
sniffing = json.dumps({
    "enabled": True,
    "destOverride": ["http", "tls", "quic", "fakedns"],
    "metadataOnly": False, "routeOnly": False
})

cur.execute("DELETE FROM inbounds WHERE tag='inbound-443'")
cur.execute("""
    INSERT INTO inbounds
        (user_id, up, down, total, remark, enable, expiry_time,
         listen, port, protocol, settings, stream_settings, tag, sniffing,
         traffic_reset, last_traffic_reset_time)
    VALUES (1,0,0,0,'VLESS-2026',1,0,'',443,'vless',?,?,'inbound-443',?,'never',0)
""", (settings, stream, sniffing))

# --- outbounds / routing / dns ---
# Ключи xrayOutboundConfig, xrayRoutingConfig, xrayDNSConfig — 3x-ui читает их при генерации конфига
# xrayTemplateConfig НЕ ТРОГАЕМ — если он есть, создаёт дубль inbound
outbounds = json.dumps([
    {"tag": "warp", "protocol": "freedom",
     "settings": {"domainStrategy": "UseIPv4"}, "sendThrough": "172.16.0.2"},
    {"tag": "direct", "protocol": "freedom", "settings": {"domainStrategy": "AsIs"}},
    {"tag": "blocked", "protocol": "blackhole", "settings": {}}
])
routing = json.dumps({
    "domainStrategy": "AsIs",
    "rules": [
        {"type": "field", "ip": ["1.1.1.1","8.8.8.8"], "outboundTag": "direct"},
        {"type": "field", "ip": ["geoip:ru"], "outboundTag": "blocked"},
        {"type": "field", "inboundTag": ["api"], "outboundTag": "api"},
        {"type": "field", "ip": ["geoip:private"], "outboundTag": "blocked"},
        {"type": "field", "outboundTag": "blocked", "protocol": ["bittorrent"]},
        {"type": "field", "inboundTag": ["dns_inbound"], "outboundTag": "warp"}
    ]
})
dns = json.dumps({
    "servers": [
        {"address": "1.1.1.1", "port": 53, "queryStrategy": "UseIP", "skipFallback": True},
        {"address": "8.8.8.8", "port": 53, "queryStrategy": "UseIP", "skipFallback": True}
    ],
    "queryStrategy": "UseIP",
    "tag": "dns_inbound"
})

for key, val in [("xrayOutboundConfig", outbounds),
                 ("xrayRoutingConfig", routing),
                 ("xrayDNSConfig", dns)]:
    cur.execute("INSERT OR REPLACE INTO settings (key, value) VALUES (?,?)", (key, val))

# Удаляем xrayTemplateConfig — он вызывает дублирование inbound
cur.execute("DELETE FROM settings WHERE key='xrayTemplateConfig'")

db.commit()

cur.execute("SELECT id, remark, port, tag FROM inbounds")
print("Inbound в БД:", cur.fetchall())
cur.execute("SELECT key FROM settings WHERE key LIKE 'xray%'")
print("Settings:", [r[0] for r in cur.fetchall()])
db.close()
print("SQLite OK")
PYEOF

    docker start 3x-ui >/dev/null 2>&1 || true
    sleep 8
    info "3x-ui запущен с конфигом из БД"

    # Сохраняем ключи и URI
    VPS_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)
    VLESS_URI="vless://${UUID}@${VPS_IP}:443?type=xhttp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=www.microsoft.com&sid=${SHORT_ID}&spx=%2F&path=%2F&mode=auto#VLESS-$(hostname)"
    echo "$VLESS_URI" > $WORKDIR/vless-uri.txt
    cat > $WORKDIR/vless-keys.txt << EOF
UUID:        $UUID
PrivateKey:  $PRIVATE_KEY
PublicKey:   $PUBLIC_KEY
ShortID:     $SHORT_ID
VPS IP:      $VPS_IP
EOF
    info "Ключи сохранены: $WORKDIR/vless-keys.txt"
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
    echo    "  │  ssh -L $XUI_PORT:127.0.0.1:$XUI_PORT ${SUDO_USER:-root}@$MY_IP -p ${SSH_PORT:-22}"
    echo    "  │  http://127.0.0.1:$XUI_PORT   (admin / admin — смени!)"
    echo -e "  ${CYAN}└─────────────────────────────────────────────────────${NC}"
    echo ""
    if [ -f $WORKDIR/vless-uri.txt ]; then
        echo -e "  ${CYAN}┌─ VLESS ─────────────────────────────────────────────${NC}"
        echo    "  │  $(cat $WORKDIR/vless-uri.txt)"
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

if $INSTALL_VLESS; then
    echo -e "  ${YELLOW}┌─ ВАЖНО: добавь warp outbound в панели ─────────────${NC}"
    echo    "  │  Xray Configs → Outbounds → Add Outbound → вставь JSON:"
    echo    "  │"
    echo    "  │  {"
    echo    "  │    \"tag\": \"warp\","
    echo    "  │    \"protocol\": \"freedom\","
    echo    "  │    \"settings\": { \"domainStrategy\": \"UseIPv4\" },"
    echo    "  │    \"sendThrough\": \"172.16.0.2\""
    echo    "  │  }"
    echo    "  │"
    echo    "  │  Затем добавь direct (freedom) и blocked (blackhole)."
    echo    "  │  Save → Restart Xray"
    echo -e "  ${YELLOW}└─────────────────────────────────────────────────────${NC}"
    echo ""
fi
