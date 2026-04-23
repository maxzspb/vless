# Личный VPN-сервер: VLESS + Hysteria2 + Cloudflare WARP

Два независимых протокола обхода блокировок на одном VPS. Выходной IP скрыт за Cloudflare. Геоблокировка российских адресов. Автоматические обновления.

---

## Содержание

- [Как это работает](#как-это-работает)
- [Требования](#требования)
- [Быстрый старт — скрипт](#быстрый-старт--скрипт)
- [Ручная установка](#ручная-установка)
- [Настройка VLESS в панели](#настройка-vless-в-панели)
- [Клиент](#клиент)
- [Проверка](#проверка)
- [Улучшения](#улучшения)
- [Диагностика](#диагностика)

---

## Как это работает

```
Твоё устройство
      │
      ├── VLESS + Reality + XHTTP  (TCP 443)
      │   Выглядит как HTTPS к Microsoft. Основной протокол.
      │
      └── Hysteria2  (UDP 443 / port hopping 20000-50000)
          Выглядит как HTTP/3. Резерв когда TCP режется.
      │
      ▼
 Твой VPS (Европа)
      │
      └── Cloudflare WARP (WireGuard)
          Реальный IP VPS скрыт. Сайты видят IP Cloudflare.
```

**VLESS + Reality** — каждое TLS-соединение имитирует рукопожатие с реальным сайтом-донором. DPI не отличает от браузера, потому что Reality использует настоящий TLS-сертификат донора.

**Hysteria2** — работает по UDP, TCP-фильтры его почти не трогают. Клиент прыгает по портам из диапазона 20000–50000 (port hopping). UDP 443 тоже редиректится на Hysteria — конфликта с VLESS нет, TCP и UDP независимы на сетевом уровне.

**Cloudflare WARP** — весь исходящий трафик с VPS идёт через WireGuard-туннель Cloudflare. Реализовано через policy routing: `sendThrough: 172.16.0.2` в Xray + отдельная таблица маршрутов 2408 на хосте (PostUp в warp.conf).

**GeoIP блокировка** — сервер отбрасывает трафик к российским IP. Если кто-то найдёт адрес сервера — не сможет использовать его как прокси к РУ-ресурсам.

---

## Требования

- VPS у европейского хостера: Hetzner, OVH, Contabo, Aeza — любой
- ОС: **Ubuntu 22.04 или 24.04**, минимум 1 CPU / 512 MB RAM
- Открытые порты в панели хостера:
  - `443/tcp` — VLESS
  - `443/udp`, `8443/udp`, `20000-50000/udp` — Hysteria2
- Домен — желательно для TLS-сертификата. Без него тоже работает.

---

## Быстрый старт — скрипт

```bash
ssh root@<IP_VPS>

apt update && apt install -y curl wget git wireguard \
    netfilter-persistent iptables-persistent docker.io

mkdir -p ~/vless && cd ~/vless
curl -fsSL https://raw.githubusercontent.com/maxzspb/vless/main/setup.sh \
    -o setup.sh && chmod +x setup.sh

bash setup.sh
```

Скрипт спросит что установить, пароль для Hysteria2 и домен. В конце выведет готовые `vless://` и `hysteria2://` ссылки.

> Скрипт **идемпотентен** — безопасно запускать повторно.

---

## Ручная установка

### 1. Базовые пакеты и Docker

```bash
apt update && apt upgrade -y
apt install -y curl wget git wireguard netfilter-persistent iptables-persistent

curl -fsSL https://get.docker.com | sh
systemctl enable docker && systemctl start docker

mkdir -p ~/vless/{cert,db}
```

---

### 2. TLS-сертификат

**С доменом** (A-запись домена → IP VPS):
```bash
curl -s https://get.acme.sh | sh -s email=you@example.com
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d твой.домен --standalone
~/.acme.sh/acme.sh --install-cert -d твой.домен \
    --key-file  ~/vless/cert/private.key \
    --fullchain-file ~/vless/cert/cert.crt
```

**Без домена** (самоподписанный):
```bash
openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout ~/vless/cert/private.key \
    -out    ~/vless/cert/cert.crt \
    -days 3650 -subj "/CN=bing.com"
```

---

### 3. Cloudflare WARP

**Зачем `Table = off` + PostUp:** WireGuard не трогает системные маршруты. PostUp создаёт отдельную таблицу 2408. Xray использует `sendThrough: 172.16.0.2` — ядро Linux смотрит в таблицу 2408 и отправляет через warp-интерфейс. Это позволяет Xray-контейнеру использовать WARP без конфликтов и без CAP_NET_RAW.

```bash
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
    gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/cloudflare-client.list
apt update && apt install -y cloudflare-warp

systemctl start warp-svc && sleep 10
warp-cli --accept-tos registration new && sleep 5

WARP_PRIVATE=$(warp-cli --accept-tos registration show | grep -i "private" | awk '{print $NF}')
WARP_ADDRESS=$(warp-cli --accept-tos registration show | grep -i "IPv4" | head -1 | awk '{print $NF}')
```

```bash
cat > /etc/wireguard/warp.conf << EOF
[Interface]
PrivateKey = $WARP_PRIVATE
Address    = ${WARP_ADDRESS}/32
MTU        = 1420
Table      = off
PostUp   = ip route add default dev warp table 2408; ip rule add from 172.16.0.2 lookup 2408 2>/dev/null || true
PostDown = ip route del default dev warp table 2408 2>/dev/null || true; ip rule del from 172.16.0.2 lookup 2408 2>/dev/null || true

[Peer]
PublicKey       = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs      = 0.0.0.0/0, ::/0
Endpoint        = engage.cloudflareclient.com:2408
PersistentKeepalive = 25
EOF

wg-quick up warp
systemctl enable wg-quick@warp
curl --interface warp https://ifconfig.me  # должен вернуть IP Cloudflare
```

---

### 4. GeoIP базы

```bash
cd ~/vless

wget -O geosite.dat \
    https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat
wget -O geoip.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
wget -O geoip.mmdb \
    https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb
```

---

### 5. Hysteria2

**`~/vless/hysteria.yaml`:**

```yaml
listen: :8443

tls:
  cert: /root/cert/cert.crt
  key:  /root/cert/private.key

auth:
  type: password
  password: СЮДА_ПАРОЛЬ

masquerade:
  type: proxy
  proxy:
    url: https://bing.com
    rewriteHost: true

outbounds:
  - name: warp
    type: direct
    direct:
      bindDevice: warp   # Hysteria2 нативно поддерживает привязку к интерфейсу
      mode: auto

acl:
  inline:
    - reject(geoip:ru)
    - warp(all)
```

---

### 6. VLESS / 3x-ui

**`~/vless/docker-compose.yaml`:**

```yaml
services:
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
```

```bash
cd ~/vless && docker compose up -d
docker ps
```

---

### 7. iptables и DNS

```bash
# Hysteria2: UDP port hopping
iptables -t nat -A PREROUTING -p udp --dport 443         -j REDIRECT --to-port 8443
iptables -t nat -A PREROUTING -p udp --dport 20000:31462 -j REDIRECT --to-port 8443
# 31463 зарезервирован под AmneziaVPN
iptables -t nat -A PREROUTING -p udp --dport 31464:50000 -j REDIRECT --to-port 8443

# Панель 3x-ui только через SSH-туннель
iptables -I INPUT -p tcp --dport 2053 ! -s 127.0.0.1 -j DROP

netfilter-persistent save
```

```bash
resolvectl dns ens3 1.1.1.1 8.8.8.8 2>/dev/null || \
resolvectl dns eth0 1.1.1.1 8.8.8.8 2>/dev/null || \
echo "nameserver 1.1.1.1" > /etc/resolv.conf
```

---

### 8. Автообновление

```bash
crontab -e
```

```cron
0 3 * * 0 wget -q -O /root/vless/geosite.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat && docker restart 3x-ui
5 3 * * 0 wget -q -O /root/vless/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
10 3 * * 0 wget -q -O /root/vless/geoip.mmdb https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb && docker restart hysteria2
0 4 * * 1 /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> /var/log/acme-renew.log 2>&1
```

---

## Настройка VLESS в панели

### Доступ через SSH-туннель

Порт 2053 закрыт снаружи. Открываем туннель **на своей машине**:

```bash
ssh -L 2053:127.0.0.1:2053 root@<IP_VPS> -p <SSH_PORT>
```

Панель: `http://127.0.0.1:2053` — логин `admin` / пароль `admin`. **Сразу смени в Panel Settings → User.**

---

### Outbounds, Routing Rules, DNS

> ✅ **Скрипт настраивает это автоматически** через SQLite — при установке через `setup.sh` эти разделы уже сконфигурированы.

Если нужно проверить или настроить вручную:

**Outbounds** должны содержать три записи:

| Tag | Protocol | sendThrough |
|-----|----------|-------------|
| warp | freedom | 172.16.0.2 |
| direct | freedom | — |
| blocked | blackhole | — |

> ⚠️ Кнопку **WARP** не нажимай — Cloudflare API недоступен со многих VPS. Добавь outbound вручную через JSON-редактор с `"sendThrough": "172.16.0.2"`.

> ⚠️ **Не используй вкладку Advanced / "Xray Template Config"** — если вставить туда JSON с inbound, он сохранится в `xrayTemplateConfig` и при следующем рестарте создаст дубль inbound → Xray упадёт с `exit status 2`. Настраивай только через вкладки Outbounds / Routing Rules / DNS.

**Routing Rules** (порядок важен):

| # | Destination IP | Protocol | Inbound Tag | Outbound |
|---|----------------|----------|-------------|----------|
| 1 | `1.1.1.1, 8.8.8.8` | — | — | direct |
| 2 | `geoip:ru` | — | — | blocked |
| 3 | — | — | `api` | api |
| 4 | `geoip:private` | — | — | blocked |
| 5 | — | `bittorrent` | — | blocked |
| 6 | — | — | `dns_inbound` | warp |

**DNS → Add Server:** `1.1.1.1`, `8.8.8.8`

**Save → Restart Xray**

---

### VLESS inbound

**Inbounds → Add Inbound:**

| Поле | Значение |
|------|----------|
| Remark | `VLESS-2026` |
| Protocol | `vless` |
| Port | `443` |

**Clients → Get New Keys** → UUID создастся автоматически.

> ⚠️ **Authentication → оставить пустым.** Не выбирай ML-KEM-768 / Post-Quantum — клиенты не поддерживают, соединение молча падает.

**Transmission:**

| Поле | Значение |
|------|----------|
| Transmission | `XHTTP` |
| Path | `/` |
| Mode | `auto` |
| Padding Bytes | `100-1000` |

**Security → Reality:**

| Поле | Значение |
|------|----------|
| uTLS | `chrome` |
| Target | `www.microsoft.com:443` |
| SNI | `www.microsoft.com` |
| Short IDs | обновить иконкой |
| Keys | нажать **Get New Cert** |
| SpiderX | `/` |

**Sniffing:** включить HTTP + TLS + QUIC + FAKEDNS.

**Save.**

---

### Получение ссылки

Inbounds → иконка информации → **URL** → скопировать `vless://...`

---

## Клиент

> ⚠️ **v2rayNG не работает с XHTTP** — использует v2ray-core, XHTTP это Xray-специфичная фича.

| Платформа | Приложение | Ядро |
|-----------|------------|------|
| Android / iOS | **Hiddify** | Xray ✓ |
| Windows | **Hiddify** / NekoRay | Xray ✓ |
| macOS | **Hiddify** / FoXray | Xray ✓ |
| Linux | NekoRay / sing-box | Xray ✓ |
| ❌ Android | v2rayNG | v2ray — не работает |

Импорт: `+` → «Добавить по ссылке» → вставить `vless://...` или `hysteria2://...`

---

## Проверка

```bash
docker ps

# WARP — должен вернуть IP Cloudflare
curl --interface warp https://ifconfig.me

# Policy routing для WARP
ip route show table 2408
ip rule show | grep 2408

ss -tlnp | grep :443     # VLESS
ss -ulnp | grep 8443     # Hysteria2
iptables -t nat -L PREROUTING -n -v
iptables -L INPUT -n | grep 2053

docker compose -f ~/vless/docker-compose.yaml logs 3x-ui    --tail=30
docker compose -f ~/vless/docker-compose.yaml logs hysteria2 --tail=30
```

---

## Улучшения

### 1. SNI-донор

**Проблема:** `www.microsoft.com` в другой подсети. DPI видит несовпадение IP назначения и SNI.

**Решение:** домен из той же ASN что и VPS.

```bash
curl -s https://ipinfo.io/json | grep '"org"'
# "org": "AS24940 Hetzner Online GmbH"
```

Идти на [search.censys.io](https://search.censys.io), искать домены в этой ASN. После нахождения: в inbound поменять **Target** и **SNI**.

**Проверка:** добавить в `/etc/hosts` на своей машине `<IP_VPS> донор.com` — открыть в браузере, должна открыться страница донора.

---

### 2. Российский сервер как relay

**Проблема:** МТС, Мегафон, Yota, Tele2 — белые списки, европейский VPS не пускают.

**Решение:** ру сервер как прозрачный форвард. Reality handshake проходит насквозь — ру сервер просто туннелирует байты.

```
Клиент → ру сервер:443 → европейский VPS:443 → WARP → интернет
```

**На ру сервере:**

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install

cat > /usr/local/etc/xray/config.json << 'EOF'
{
  "inbounds": [{
    "listen": "0.0.0.0", "port": 443,
    "protocol": "dokodemo-door",
    "settings": {
      "address": "<IP_ЕВРОПЕЙСКОГО_VPS>",
      "port": 443, "network": "tcp,udp"
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF
systemctl enable xray && systemctl start xray
```

TLS-сертификат на ру домен через certbot. Клиент меняет только адрес подключения на ру домен.

---

### 3. VLESS + TCP + Reality + Vision

Второй транспорт для стабильных каналов — меньше оверхеда, выше скорость.

**Inbounds → Add Inbound:**

| Поле | Значение |
|------|----------|
| Remark | `VISION-2026` |
| Protocol | `vless` |
| Port | `8444` |
| Transmission | `TCP` (RAW) |
| Security | `Reality` |
| Flow | `xtls-rprx-vision` |
| uTLS | `chrome` |
| Target / SNI | тот же донор |

В Hiddify добавить оба сервера — клиент сам выберет рабочий.

---

## Диагностика

**Соединение молча сбрасывается в Hiddify**
→ Проверь Authentication в inbound — должно быть пусто, не ML-KEM-768. `decryption` и `encryption` в JSON должны быть `"none"`.

**Xray показывает реальный IP VPS, не Cloudflare**
```bash
ip route show table 2408   # должно быть: default dev warp
ip rule show | grep 2408   # должно быть правило
# Если пусто:
wg-quick down warp && wg-quick up warp
```

**Xray exit status 2 — дубль inbound в конфиге**

Причина: в `xrayTemplateConfig` (settings таблица БД) сохранился inbound — 3x-ui добавляет его поверх inbound из таблицы `inbounds` → дубль тега → Xray падает.
```bash
docker stop 3x-ui
sqlite3 ~/vless/db/x-ui.db "DELETE FROM settings WHERE key='xrayTemplateConfig';"
docker start 3x-ui
sleep 5 && docker logs 3x-ui --tail 3
```
Не используй вкладку Advanced/Template в панели — только Outbounds/Routing/DNS вкладки.


→ Cloudflare API заблокирован. Используй `sendThrough: 172.16.0.2` в outbound JSON.

**Hysteria2 не стартует**
```bash
docker compose logs hysteria2 --tail=30
wg-quick down warp && wg-quick up warp
docker compose restart hysteria2
```

**Port hopping не работает после ребута**
```bash
iptables -t nat -L PREROUTING -n -v
# Если пусто — правила не сохранились:
iptables -t nat -A PREROUTING -p udp --dport 443         -j REDIRECT --to-port 8443
iptables -t nat -A PREROUTING -p udp --dport 20000:31462 -j REDIRECT --to-port 8443
iptables -t nat -A PREROUTING -p udp --dport 31464:50000 -j REDIRECT --to-port 8443
netfilter-persistent save
```

**Панель не открывается через туннель**
```bash
# На своей машине:
ssh -L 2053:127.0.0.1:2053 root@<IP_VPS> -p <SSH_PORT> -N &
curl http://127.0.0.1:2053
```

**Забыл пароль от панели**
```bash
docker stop 3x-ui
sqlite3 ~/vless/db/x-ui.db \
    "UPDATE users SET username='admin', password='admin' WHERE id=1;"
docker start 3x-ui
```

---

## Структура репозитория

```
.
├── README.md
├── setup.sh                    ← скрипт установки
└── xray_config_template.json   ← шаблон Xray-конфига
```

```
~/vless/  (на сервере)
├── .env                  ← пароль Hysteria2 (chmod 600)
├── docker-compose.yaml
├── hysteria.yaml
├── xray_config.json      ← сгенерированный конфиг
├── vless-uri.txt         ← готовая ссылка VLESS
├── hysteria2-uri.txt     ← готовая ссылка Hysteria2
├── cert/
├── db/
├── geoip.dat, geosite.dat, geoip.mmdb
```
