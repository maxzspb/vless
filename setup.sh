#!/bin/bash
# VPN Setup: VLESS (3x-ui/Xray) + Hysteria2 + Cloudflare WARP
# https://github.com/maxzspb/vless
set -e

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[✓]${NC} $1"; }
warning() { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()    { echo -e "\n${CYAN}━━ $1 ━━${NC}"; }

REPO_RAW="https://raw.githubusercontent.com/maxzspb/vless/main"

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
    *) error "Неверный выбор. Введи 1, 2 или 3." ;;
esac
echo ""

# ── Параметры ────────────────────────────────────────────────
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
    openssl req -x509 -nodes -newkey rsa:2048 \
        -keyout $WORKDIR/cert/private.key \
        -out    $WORKDIR/cert/cert.crt \
        -days 3650 -subj "/CN=bing.com" 2>/dev/null
    info "Самоподписанный сертификат создан"
fi

# ── GeoIP базы ───────────────────────────────────────────────
step "GeoIP базы"
if $INSTALL_VLESS; then
    [ ! -f $WORKDIR/geosite.dat ] && \
        wget -q -O $WORKDIR/geosite.dat \
        https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat && \
        info "geosite.dat загружен" || info "geosite.dat уже есть"
    [ ! -f $WORKDIR/geoip.dat ] && \
        wget -q -O $WORKDIR/geoip.dat \
        https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat && \
        info "geoip.dat загружен" || info "geoip.dat уже есть"
fi
if $INSTALL_HY; then
    [ ! -f $WORKDIR/geoip.mmdb ] && \
        wget -q -O $WORKDIR/geoip.mmdb \
        https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb && \
        info "geoip.mmdb загружен" || info "geoip.mmdb уже есть"
fi

# ── Cloudflare WARP ──────────────────────────────────────────
step "Cloudflare WARP"
if ip link show warp &>/dev/null && [ -f /etc/wireguard/warp.conf ]; then
    info "WARP уже настроен — пропускаем"
    WARP_IP=$(curl -s --interface warp --max-time 10 https://ifconfig.me 2>/dev/null || true)
else
    info "Устанавливаем warp-cli..."
    curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
        gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg 2>/dev/null
    echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | \
        tee /etc/apt/sources.list.d/cloudflare-client.list > /dev/null
    apt update -qq && apt install -y cloudflare-warp -qq

    info "Ждём запуска warp-svc..."
    systemctl start warp-svc 2>/dev/null || true
    for i in $(seq 1 15); do
        warp-cli --accept-tos status 2>/dev/null | grep -q "Disconnected\|Connected\|Registration" && break
        sleep 2
    done

    info "Регистрируем личный WARP аккаунт..."
    warp-cli --accept-tos registration new 2>/dev/null || true
    sleep 5

    WARP_PRIVATE=$(warp-cli --accept-tos registration show 2>/dev/null \
        | grep -i "private" | awk '{print $NF}')
    WARP_ADDRESS=$(warp-cli --accept-tos registration show 2>/dev/null \
        | grep -i "IPv4\|address" | head -1 | awk '{print $NF}')

    if [ -n "$WARP_PRIVATE" ]; then
        WARP_KEY_USE="$WARP_PRIVATE"
        WARP_ADDR_USE="${WARP_ADDRESS:-172.16.0.2}/32"
        info "Личные ключи WARP получены"
    else
        warning "warp-cli не вернул ключи — используем резервные публичные"
        WARP_KEY_USE="qAK9pGqPyHiY6i/MZjJJPhvCFFt13YhyXWe73ZFKXlE="
        WARP_ADDR_USE="172.16.0.2/32"
    fi

    # Table=off + policy routing через PostUp/PostDown
    # sendThrough: 172.16.0.2 в Xray будет работать благодаря таблице 2408
    cat > /etc/wireguard/warp.conf << EOF
[Interface]
PrivateKey = $WARP_KEY_USE
Address = $WARP_ADDR_USE
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
[ -n "$WARP_IP" ] \
    && info "WARP работает. Выходной IP: $WARP_IP (Cloudflare)" \
    || warning "WARP не ответил — проверь: curl --interface warp https://ifconfig.me"

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
docker compose up -d --no-recreate
sleep 8

FAILED=false
$INSTALL_VLESS && ! docker ps | grep -q "3x-ui"    && { warning "3x-ui не запустился"; FAILED=true; }
$INSTALL_HY    && ! docker ps | grep -q "hysteria2" && { warning "hysteria2 не запустился"; FAILED=true; }
$FAILED && error "Проверь логи: docker compose logs"
info "Контейнеры запущены"

# ── Xray конфиг — генерируем и применяем автоматически ───────
if $INSTALL_VLESS; then
    step "Xray конфиг"

    # Ждём пока 3x-ui инициализирует БД
    for i in $(seq 1 20); do
        [ -f $WORKDIR/db/x-ui.db ] && break
        sleep 2
    done

    # Генерируем UUID и Reality keypair
    UUID=$(cat /proc/sys/kernel/random/uuid)
    SHORT_ID=$(openssl rand -hex 4)

    # Пробуем получить keypair через xray внутри контейнера
    KEYPAIR=$(docker exec 3x-ui xray x25519 2>/dev/null || \
              docker exec 3x-ui /usr/local/x-ui/bin/xray x25519 2>/dev/null || echo "")
    PRIVATE_KEY=$(echo "$KEYPAIR" | grep -i "private" | awk '{print $NF}')
    PUBLIC_KEY=$(echo "$KEYPAIR"  | grep -i "public"  | awk '{print $NF}')

    # Fallback — генерируем через openssl
    if [ -z "$PRIVATE_KEY" ]; then
        PRIVATE_KEY=$(openssl genpkey -algorithm X25519 2>/dev/null | \
            openssl pkey -outform DER 2>/dev/null | tail -c 32 | \
            base64 | tr '+/' '-_' | tr -d '=' || echo "GENERATE_IN_PANEL")
        PUBLIC_KEY="CHECK_PANEL"
        warning "Reality keypair: открой панель и нажми Get New Cert в inbound"
    fi

    info "UUID: $UUID"
    info "Reality PrivateKey готов"

    # Скачиваем шаблон
    XRAY_TPL=$WORKDIR/xray_config_template.json
    [ ! -f "$XRAY_TPL" ] && \
        curl -fsSL "$REPO_RAW/xray_config_template.json" -o "$XRAY_TPL" 2>/dev/null || true

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

        VPS_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || true)
        VLESS_URI="vless://${UUID}@${VPS_IP}:443?type=xhttp&security=reality&pbk=${PUBLIC_KEY}&fp=chrome&sni=www.microsoft.com&sid=${SHORT_ID}&spx=%2F&path=%2F&mode=auto#VLESS-$(hostname)"
        echo "$VLESS_URI" > $WORKDIR/vless-uri.txt
        info "VLESS URI сохранён: $WORKDIR/vless-uri.txt"
    else
        warning "Шаблон не найден — настрой VLESS в панели вручную (Шаг 4 в README)"
    fi
fi

# ── Безопасность: закрыть порт панели снаружи ────────────────
if $INSTALL_VLESS; then
    step "Безопасность панели"
    iptables -D INPUT -p tcp --dport $XUI_PORT ! -s 127.0.0.1 -j DROP 2>/dev/null || true
    iptables -I INPUT -p tcp --dport $XUI_PORT ! -s 127.0.0.1 -j DROP
    info "Порт $XUI_PORT закрыт снаружи — только SSH-туннель"
fi

# ── iptables: UDP port hopping для Hysteria2 ─────────────────
if $INSTALL_HY; then
    step "iptables / port hopping"
    # Идемпотентно: удаляем старые перед добавлением
    iptables -t nat -D PREROUTING -p udp --dport 443         -j REDIRECT --to-port 8443 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport 20000:31462 -j REDIRECT --to-port 8443 2>/dev/null || true
    iptables -t nat -D PREROUTING -p udp --dport 31464:50000 -j REDIRECT --to-port 8443 2>/dev/null || true
    iptables -t nat -A PREROUTING -p udp --dport 443         -j REDIRECT --to-port 8443
    iptables -t nat -A PREROUTING -p udp --dport 20000:31462 -j REDIRECT --to-port 8443
    iptables -t nat -A PREROUTING -p udp --dport 31464:50000 -j REDIRECT --to-port 8443
    netfilter-persistent save
    info "UDP 443 + 20000-50000 → 8443"
fi

# ── DNS ──────────────────────────────────────────────────────
step "DNS"
resolvectl dns ens3 1.1.1.1 8.8.8.8 2>/dev/null || \
resolvectl dns eth0 1.1.1.1 8.8.8.8 2>/dev/null || \
echo "nameserver 1.1.1.1" > /etc/resolv.conf
info "DNS: 1.1.1.1, 8.8.8.8"

# ── Cron: автообновление GeoIP и сертификата ─────────────────
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
    (crontab -l 2>/dev/null; echo "0 4 * * 1 ~/.acme.sh/acme.sh --cron --home ~/.acme.sh >> /var/log/acme-renew.log 2>&1") | crontab -
info "Cron настроен (GeoIP каждое воскресенье в 3:00)"

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
    echo    "  │  Открой через SSH-туннель на своей машине:"
    echo    "  │"
    echo    "  │  ssh -L $XUI_PORT:127.0.0.1:$XUI_PORT root@$MY_IP -p ${SSH_PORT:-22}"
    echo    "  │"
    echo    "  │  Затем: http://127.0.0.1:$XUI_PORT"
    echo    "  │  Логин: admin / Пароль: admin — сразу смени!"
    echo -e "  ${CYAN}└─────────────────────────────────────────────────────${NC}"
    echo ""

    if [ -f $WORKDIR/vless-uri.txt ]; then
        VLESS_URI=$(cat $WORKDIR/vless-uri.txt)
        echo -e "  ${CYAN}┌─ VLESS — готовая ссылка ────────────────────────────${NC}"
        echo    "  │"
        echo    "  │  $VLESS_URI"
        echo    "  │"
        echo    "  │  Hiddify: + → Добавить по ссылке"
        echo    "  │  Файл: $WORKDIR/vless-uri.txt"
        echo -e "  ${CYAN}└─────────────────────────────────────────────────────${NC}"
        echo ""
    fi
fi

if $INSTALL_HY; then
    HY_URI="hysteria2://${HY_PASS}@${MY_IP}:443?sni=bing.com&insecure=1&mport=20000-50000#Hysteria2-$(hostname)"
    echo "$HY_URI" > $WORKDIR/hysteria2-uri.txt
    echo -e "  ${CYAN}┌─ HYSTERIA2 — готовая ссылка ────────────────────────${NC}"
    echo    "  │"
    echo    "  │  $HY_URI"
    echo    "  │"
    echo    "  │  Hiddify: + → Добавить по ссылке"
    echo    "  │  Файл: $WORKDIR/hysteria2-uri.txt"
    echo -e "  ${CYAN}└─────────────────────────────────────────────────────${NC}"
    echo ""
fi

echo "  Выходной IP WARP: ${WARP_IP:-не определён} (Cloudflare)"
echo ""
