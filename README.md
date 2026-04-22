# Личный VPN-сервер: VLESS + Hysteria2 + Cloudflare WARP

Два независимых протокола обхода блокировок на одном VPS. Выходной IP скрыт за Cloudflare. Геоблокировка российских адресов на стороне сервера. Автоматические обновления.

---

## Содержание

- [Как это работает](#как-это-работает)
- [Требования](#требования)
- [Быстрый старт — скрипт](#быстрый-старт--скрипт)
- [Ручная установка](#ручная-установка)
  - [1. Базовые пакеты и Docker](#1-базовые-пакеты-и-docker)
  - [2. TLS-сертификат](#2-tls-сертификат)
  - [3. Cloudflare WARP](#3-cloudflare-warp)
  - [4. GeoIP базы](#4-geoip-базы)
  - [5. Конфиги и запуск](#5-конфиги-и-запуск)
  - [6. iptables и DNS](#6-iptables-и-dns)
  - [7. Автообновление](#7-автообновление)
- [Настройка VLESS в панели](#настройка-vless-в-панели)
  - [Открытие панели через SSH-туннель](#открытие-панели-через-ssh-туннель)
  - [Outbounds](#outbounds)
  - [Routing Rules](#routing-rules)
  - [DNS](#dns)
  - [Создание VLESS inbound](#создание-vless-inbound)
  - [Получение ссылки для клиента](#получение-ссылки-для-клиента)
- [Клиент](#клиент)
- [Проверка](#проверка)
- [Улучшения](#улучшения)
  - [SNI-донор](#1-sni-донор--убедительная-маскировка)
  - [Российский сервер как relay](#2-российский-сервер-как-relay)
  - [VLESS + TCP + Vision](#3-vless--tcp--reality--vision-второй-транспорт)
- [Диагностика](#диагностика)

---

## Как это работает

```
Твоё устройство
      │
      ├── VLESS + Reality + XHTTP  (TCP 443)
      │   Выглядит как обычный HTTPS к Microsoft
      │   Основной протокол
      │
      └── Hysteria2  (UDP 443 / port hopping 20000-50000)
          Выглядит как HTTP/3
          Резерв когда TCP режется
      │
      ▼
 Твой VPS (Европа)  ──▶  Cloudflare WARP
                          Реальный IP VPS скрыт
                          Сайты видят IP Cloudflare
```

**VLESS + Reality** — каждое TLS-соединение выглядит как рукопожатие с реальным крупным сайтом. DPI не отличает от браузера, потому что Reality использует настоящий сертификат сайта-донора.

**Hysteria2** — работает по UDP, TCP-фильтры его почти не трогают. Клиент прыгает по портам из диапазона 20000-50000 (port hopping), iptables перенаправляет всё на внутренний порт 8443. UDP 443 тоже редиректится туда — конфликта с VLESS нет, TCP и UDP независимы.

**Cloudflare WARP** — весь исходящий трафик с VPS идёт через WireGuard-туннель Cloudflare. Сайты видят IP Cloudflare, не твой VPS.

**GeoIP блокировка** — сервер отбрасывает запросы к российским адресам. Даже если кто-то найдёт адрес сервера — он не пройдёт.

---

## Требования

- VPS у европейского хостера: Hetzner, OVH, Contabo, Aeza — любой
- ОС: **Ubuntu 22.04 или 24.04**
- Минимум: 1 CPU, 512 MB RAM
- Открытые порты в панели хостера:
  - `443/tcp` — VLESS
  - `443/udp`, `8443/udp`, `20000-50000/udp` — Hysteria2
- Домен — желательно, нужен для нормального TLS-сертификата. Без него тоже работает.

> Порты открываются в панели хостера (Firewall / Security Groups). Если используешь `ufw` — добавь правила там тоже.

---

## Быстрый старт — скрипт

```bash
# 1. Подключиться к VPS
ssh root@<IP_VPS>

# 2. Установить зависимости
apt update && apt install -y curl wget git wireguard \
    netfilter-persistent iptables-persistent docker.io

# 3. Создать рабочую папку и скачать скрипт
mkdir -p ~/vless && cd ~/vless
curl -fsSL https://raw.githubusercontent.com/maxzspb/vless/main/setup.sh \
    -o setup.sh && chmod +x setup.sh

# 4. Запустить
bash setup.sh
```

Скрипт спросит:
- Что установить (VLESS + Hysteria2 / только VLESS / только Hysteria2)
- Пароль для Hysteria2
- Домен для сертификата (Enter = самоподписанный)

Остальное сделает сам. В конце выведет SSH-туннель для доступа к панели и готовую ссылку Hysteria2.

> Скрипт **идемпотентен** — безопасно запускать повторно после сбоя или после `docker compose down`.

---

## Ручная установка

Если хочешь понимать каждый шаг или настраивать под себя.

### 1. Базовые пакеты и Docker

**Зачем:** Docker изолирует сервисы и упрощает обновления — перезапуск одной командой. `wireguard` нужен для WARP. `netfilter-persistent` сохраняет правила iptables между перезагрузками.

```bash
apt update && apt upgrade -y
apt install -y curl wget git wireguard \
    netfilter-persistent iptables-persistent

curl -fsSL https://get.docker.com | sh
systemctl enable docker && systemctl start docker
```

---

### 2. TLS-сертификат

**Зачем:** VLESS и Hysteria2 оба требуют TLS. С реальным доменом маскировка убедительнее — сервер выглядит как обычный HTTPS-сайт.

```bash
mkdir -p ~/vless/{cert,db}
```

**С доменом** (A-запись домена должна смотреть на IP VPS):
```bash
curl -s https://get.acme.sh | sh -s email=you@example.com
source ~/.bashrc
~/.acme.sh/acme.sh --set-default-ca --server letsencrypt
~/.acme.sh/acme.sh --issue -d твой.домен --standalone
~/.acme.sh/acme.sh --install-cert -d твой.домен \
    --key-file  ~/vless/cert/private.key \
    --fullchain-file ~/vless/cert/cert.crt
```

**Без домена** (самоподписанный — клиент отключит проверку сертификата):
```bash
openssl req -x509 -nodes -newkey rsa:2048 \
    -keyout ~/vless/cert/private.key \
    -out    ~/vless/cert/cert.crt \
    -days 3650 -subj "/CN=bing.com"
```

---

### 3. Cloudflare WARP

**Зачем:** весь исходящий трафик с VPS выходит через Cloudflare. Реальный IP сервера не виден внешним сайтам и не попадёт в блеклисты.

Устанавливаем `warp-cli` для получения личных ключей:
```bash
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg | \
    gpg --yes --dearmor -o /usr/share/keyrings/cloudflare-warp-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg] \
https://pkg.cloudflareclient.com/ $(lsb_release -cs) main" | \
    tee /etc/apt/sources.list.d/cloudflare-client.list
apt update && apt install -y cloudflare-warp

# Ждём запуска демона и регистрируемся
systemctl start warp-svc
sleep 10
warp-cli --accept-tos registration new
sleep 5

# Извлекаем ключи
WARP_PRIVATE=$(warp-cli --accept-tos registration show | grep -i "private" | awk '{print $NF}')
WARP_ADDRESS=$(warp-cli --accept-tos registration show | grep -i "IPv4" | head -1 | awk '{print $NF}')
```

Создаём WireGuard конфиг:
```bash
cat > /etc/wireguard/warp.conf << EOF
[Interface]
PrivateKey = $WARP_PRIVATE
Address    = ${WARP_ADDRESS}/32
MTU        = 1420
Table      = off

[Peer]
PublicKey       = bmXOC+F1FxEMF9dyiK2H5/1SUtzH0JuVo51h2wPfgyo=
AllowedIPs      = 0.0.0.0/0, ::/0
Endpoint        = engage.cloudflareclient.com:2408
PersistentKeepalive = 25
EOF

wg-quick up warp
systemctl enable wg-quick@warp

# Проверка — должен вернуть IP Cloudflare, не IP VPS
curl --interface warp https://ifconfig.me
```

---

### 4. GeoIP базы

**Зачем:** нужны для правил роутинга — чтобы сервер знал какие адреса российские и отбрасывал их.

```bash
cd ~/vless

# Для VLESS/Xray
wget -O geosite.dat \
    https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat
wget -O geoip.dat \
    https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat

# Для Hysteria2
wget -O geoip.mmdb \
    https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb
```

---

### 5. Конфиги и запуск

**`hysteria.yaml`** — конфиг резервного протокола:

```bash
cat > ~/vless/hysteria.yaml << 'EOF'
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
    url: https://bing.com   # при активном зондировании сервер отвечает как Bing
    rewriteHost: true

outbounds:
  - name: warp
    type: direct
    direct:
      bindDevice: warp       # весь трафик через WARP
      mode: auto

acl:
  inline:
    - reject(geoip:ru)       # российские IP — в чёрную дыру
    - warp(all)              # всё остальное — через WARP
EOF
```

**`docker-compose.yaml`:**

```bash
cat > ~/vless/docker-compose.yaml << 'EOF'
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
EOF
```

**Запуск:**
```bash
cd ~/vless
docker compose up -d
docker ps   # оба контейнера должны быть Up
```

---

### 6. iptables и DNS

**Зачем iptables:** Hysteria2 слушает на внутреннем порту 8443. Снаружи клиент может использовать любой порт из диапазона или UDP 443 — iptables тихо редиректит всё внутрь.

**Зачем закрывать порт панели:** 3x-ui слушает на порту 2053. Если оставить открытым — его найдут сканеры и начнут брутить. Доступ только через SSH-туннель.

```bash
# ── Hysteria2: UDP port hopping ──────────────────────────────
iptables -t nat -A PREROUTING -p udp --dport 443         -j REDIRECT --to-port 8443
iptables -t nat -A PREROUTING -p udp --dport 20000:31462 -j REDIRECT --to-port 8443
# 31463 оставляем — зарезервирован под AmneziaVPN
iptables -t nat -A PREROUTING -p udp --dport 31464:50000 -j REDIRECT --to-port 8443

# ── Закрываем порт панели снаружи ────────────────────────────
iptables -I INPUT -p tcp --dport 2053 ! -s 127.0.0.1 -j DROP

# ── Сохраняем — правила переживут перезагрузку ───────────────
netfilter-persistent save
```

**DNS:**
```bash
# Используем Cloudflare DNS вместо хостерского
resolvectl dns ens3 1.1.1.1 8.8.8.8 2>/dev/null || \
resolvectl dns eth0 1.1.1.1 8.8.8.8 2>/dev/null || \
echo "nameserver 1.1.1.1" > /etc/resolv.conf
```

---

### 7. Автообновление

**Зачем:** GeoIP базы устаревают — новые российские диапазоны появляются регулярно. Если не обновлять, часть РУ-трафика начнёт проходить через сервер.

```bash
crontab -e
```

Добавить:
```cron
# GeoIP — каждое воскресенье в 3:00
0 3 * * 0 wget -q -O /root/vless/geosite.dat https://github.com/runetfreedom/russia-v2ray-rules-dat/releases/latest/download/geosite.dat && docker restart 3x-ui
5 3 * * 0 wget -q -O /root/vless/geoip.dat https://github.com/Loyalsoldier/v2ray-rules-dat/releases/latest/download/geoip.dat
10 3 * * 0 wget -q -O /root/vless/geoip.mmdb https://github.com/Loyalsoldier/geoip/releases/latest/download/Country.mmdb && docker restart hysteria2

# TLS-сертификат (если используешь домен) — каждый понедельник в 4:00
0 4 * * 1 /root/.acme.sh/acme.sh --cron --home /root/.acme.sh >> /var/log/acme-renew.log 2>&1
```

---

## Настройка VLESS в панели

### Открытие панели через SSH-туннель

Порт 2053 закрыт снаружи. Открываем туннель **на своей машине**:

```bash
ssh -L 2053:127.0.0.1:2053 root@<IP_VPS> -p <SSH_PORT>
```

Пока терминал открыт — панель доступна по адресу:
```
http://127.0.0.1:2053
```

Логин: `admin`, пароль: `admin`.  
**Сразу смени:** Panel Settings → User.

---

### Outbounds

**Xray Configs → Outbounds → кнопка WARP**

Панель сгенерирует WireGuard outbound автоматически. Должно получиться:

| Tag | Protocol | Адрес |
|-----|----------|-------|
| warp | wireguard | engage.cloudflareclient.com:2408 |
| direct | freedom | — |
| blocked | blackhole | — |

**Save → Restart Xray**

---

### Routing Rules

**Xray Configs → Routing Rules → Add Rule** (порядок важен):

| # | Destination IP | Protocol | Inbound Tag | Outbound |
|---|----------------|----------|-------------|----------|
| 1 | `1.1.1.1, 8.8.8.8` | — | — | direct |
| 2 | `geoip:ru` | — | — | blocked |
| 3 | — | — | `api` | api |
| 4 | `geoip:private` | — | — | blocked |
| 5 | — | `bittorrent` | — | blocked |
| 6 | — | — | `dns_inbound` | warp |

Всё что не попало в правила → уходит в warp по умолчанию.

**Save → Restart Xray**

---

### DNS

**Xray Configs → DNS → Add Server:**
- `1.1.1.1`
- `8.8.8.8`

**Save → Restart Xray**

---

### Создание VLESS inbound

**Inbounds → Add Inbound:**

| Поле | Значение |
|------|----------|
| Remark | `real_2026` |
| Protocol | `vless` |
| Listen IP | *(пусто — все интерфейсы)* |
| Port | `443` |

**Clients:** нажать **Get New Keys** — UUID создастся автоматически.

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
| Short IDs | нажать иконку обновления |
| Public / Private Key | нажать **Get New Cert** |
| SpiderX | `/` |

> SNI лучше заменить на донора из той же ASN что и VPS — см. [раздел Улучшения](#1-sni-донор--убедительная-маскировка).

**Sniffing:** включить, отметить HTTP + TLS + QUIC + FAKEDNS.

**Save.**

---

### Получение ссылки для клиента

В списке Inbounds нажать иконку QR / ссылки. Скопировать строку `vless://...`.

---

## Клиент

| Платформа | Приложение |
|-----------|------------|
| Android / iOS | **Hiddify** |
| Windows | **Hiddify** / NekoRay |
| macOS | **Hiddify** / FoXray |
| Linux | NekoRay / sing-box |

Импорт: `+` → «Добавить по ссылке» → вставить `vless://...`

Hysteria2 URI выводится скриптом в конце установки и сохраняется в `~/vless/hysteria2-uri.txt`. Добавить как второй сервер — Hiddify умеет автопереключаться.

---

## Проверка

```bash
# Контейнеры живы?
docker ps

# WARP работает? (должен вернуть IP Cloudflare, не IP VPS)
curl --interface warp https://ifconfig.me

# VLESS слушает?
ss -tlnp | grep :443

# Hysteria2 слушает?
ss -ulnp | grep 8443

# Port hopping правила?
iptables -t nat -L PREROUTING -n -v

# Порт панели закрыт снаружи?
iptables -L INPUT -n -v | grep 2053

# Логи
docker compose logs 3x-ui    --tail=30
docker compose logs hysteria2 --tail=30
```

---

## Улучшения

### 1. SNI-донор — убедительная маскировка

**Проблема:** `www.microsoft.com` — хороший донор, но IP твоего VPS находится в другой подсети. Умный DPI сравнивает IP назначения с тем что резолвится по SNI — видит несовпадение — подозрение.

**Решение:** найти домен из той же ASN что и твой хостер. Такое соединение выглядит технически корректным — IP и SNI совпадают по ASN.

```bash
# Узнать ASN своего VPS
curl -s https://ipinfo.io/json | grep -E '"org"|"ip"'
# Пример: "org": "AS24940 Hetzner Online GmbH"
```

Идти на [search.censys.io](https://search.censys.io), искать домены в диапазонах этой ASN. Брать любой крупный корпоративный — не личный сайт.

После нахождения: в 3x-ui открыть inbound → поменять **Target** и **SNI** → Save → Restart Xray.

**Проверка** на своей машине:
```bash
# Добавить в /etc/hosts:
# <IP_VPS>  найденный.донор.com
# Открыть в браузере — должна открыться страница донора
```

---

### 2. Российский сервер как relay

**Проблема:** МТС, Мегафон, Yota, Tele2 используют белые списки — пропускают только трафик к одобренным IP. Твой европейский VPS там не числится.

**Решение:** добавить промежуточный сервер с российским IP как прозрачный форвард. ТСПУ видит соединение к российскому домену — пропускает. Reality handshake проходит насквозь — ру сервер его не терминирует, просто туннелирует TCP/UDP-байты дальше.

```
Клиент → ру сервер:443 (SNI = твой.ру.домен) → эстонский VPS:443 → WARP → интернет
```

**На ру сервере** — устанавливаем Xray как голый форвард:

```bash
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
```

```bash
cat > /usr/local/etc/xray/config.json << EOF
{
  "inbounds": [{
    "listen": "0.0.0.0",
    "port": 443,
    "protocol": "dokodemo-door",
    "settings": {
      "address": "<IP_ЕВРОПЕЙСКОГО_VPS>",
      "port": 443,
      "network": "tcp,udp",
      "followRedirect": false
    }
  }],
  "outbounds": [{ "protocol": "freedom" }]
}
EOF

systemctl enable xray && systemctl start xray
```

**Или через nginx** (если уже стоит):

```nginx
stream {
    server {
        listen 443;       # TCP → VLESS
        proxy_pass <IP_ЕВРОПЕЙСКОГО_VPS>:443;
    }
    server {
        listen 443 udp;   # UDP → Hysteria2
        proxy_pass <IP_ЕВРОПЕЙСКОГО_VPS>:443;
    }
}
```

**DNS ру домена:** A-запись смотрит на IP ру сервера. Получить TLS-сертификат:

```bash
apt install -y certbot
certbot certonly --standalone -d твой.ру.домен
```

> Сертификат нужен для того чтобы при активном зондировании сервер отдавал валидный HTTPS. Xray-форвард его не использует — он передаёт байты Reality as-is.

**На европейском VPS** ничего не меняется.

**Клиентский конфиг** — меняется только адрес:

```
address: твой.ру.домен   ← вместо IP европейского VPS
port:    443
SNI:     твой.ру.домен
```

ТСПУ видит TLS к российскому домену с валидным сертификатом — пропускает.

---

### 3. VLESS + TCP + Reality + Vision (второй транспорт)

**Зачем:** два транспорта для разных условий.

- **XHTTP** — маскирует поведение соединения после рукопожатия, хуже детектируется статистически
- **TCP + Vision** — меньше оверхеда, быстрее на стабильных каналах без агрессивного DPI

Добавить второй inbound в 3x-ui:

**Inbounds → Add Inbound:**

| Поле | Значение |
|------|----------|
| Remark | `vision_2026` |
| Protocol | `vless` |
| Port | `8444` |
| Transmission | `TCP` (RAW) |
| Security | `Reality` |
| Flow | `xtls-rprx-vision` |
| uTLS | `chrome` |
| Target / SNI | тот же донор что в основном inbound |

В клиенте (Hiddify / NekoBox) добавить оба сервера и включить автопереключение — клиент сам выберет рабочий.

---

## Диагностика

**Hysteria2 не стартует**
```bash
docker compose logs hysteria2 --tail=30
# Часто: WARP не поднялся до запуска контейнера
wg-quick down warp && wg-quick up warp
docker compose restart hysteria2
```

**VLESS не подключается**
- Проверь что порт 443/tcp открыт в firewall хостера
- Попробуй сменить SNI-донора (см. Улучшения)
- На мобильных операторах — нужен relay через российский сервер (см. Улучшения)

**Port hopping не работает после ребута**
```bash
iptables -t nat -L PREROUTING -n -v
# Если пусто — правила не сохранились:
iptables -t nat -A PREROUTING -p udp --dport 443         -j REDIRECT --to-port 8443
iptables -t nat -A PREROUTING -p udp --dport 20000:31462 -j REDIRECT --to-port 8443
iptables -t nat -A PREROUTING -p udp --dport 31464:50000 -j REDIRECT --to-port 8443
netfilter-persistent save
```

**WARP не работает**
```bash
systemctl status wg-quick@warp
wg-quick down warp && wg-quick up warp
curl --interface warp https://ifconfig.me
```

**Забыл пароль от панели**
```bash
docker stop 3x-ui
sqlite3 ~/vless/db/x-ui.db \
    "UPDATE users SET username='admin', password='admin' WHERE id=1;"
docker start 3x-ui
# Войди с admin/admin, сразу смени в Panel Settings → User
```

**Панель не открывается через туннель**
```bash
# Убедись что туннель запущен (на своей машине):
ssh -L 2053:127.0.0.1:2053 root@<IP_VPS> -p <SSH_PORT> -N &
# -N = не открывать shell, только туннель
curl http://127.0.0.1:2053  # должен ответить
```

---

## Структура файлов

```
~/vless/
├── .env                  ← пароль Hysteria2 (chmod 600)
├── docker-compose.yaml
├── hysteria.yaml
├── setup.sh              ← скрипт установки
├── hysteria2-uri.txt     ← готовая ссылка для клиента
├── cert/
│   ├── cert.crt
│   └── private.key
├── db/
│   └── x-ui.db           ← база 3x-ui
├── geoip.dat
├── geosite.dat
└── geoip.mmdb
```
