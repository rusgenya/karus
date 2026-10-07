#!/usr/bin/env bash
# Hysteria 2 + four Xray/Happ test profiles. Ubuntu 22.04/24.04, Debian 12/13.
# Official docs: https://v2.hysteria.network/docs/advanced/Full-Server-Config/
# https://v2.hysteria.network/docs/advanced/Full-Client-Config/
# https://v2.hysteria.network/docs/developers/URI-Scheme/
# https://xtls.github.io/en/config/transport.html
# https://xtls.github.io/en/config/transports/reality.html
# https://github.com/XTLS/Xray-core/discussions/716
# https://www.happ.su/main/dev-docs/examples-of-links-and-parameters
set +x
set -Eeuo pipefail
umask 077
export LC_ALL=C
TMP='' TEST_PID='' PASSWORD='' SERVICE_CREATED=0 XR_CREATED=0
OUT_DIR=$(pwd -P)
fail() { printf '\nОШИБКА: %s\n' "$*" >&2; exit 1; }
cleanup() {
  if [[ -n "$TEST_PID" ]]; then kill "$TEST_PID" 2>/dev/null || true; wait "$TEST_PID" 2>/dev/null || true; fi
  [[ -z "$TMP" ]] || rm -rf -- "$TMP"
  unset PASSWORD
}
trap cleanup EXIT
# Never include command expansions (which could contain secrets) in errors.
redact() {
  python3 -c '
import json,re,sys
s=sys.stdin.read(); secrets=[]
try:
 for line in open("/etc/hysteria/config.yaml"):
  m=re.match(r"\s*password:\s*\"?([a-f0-9]{64})",line)
  if m: secrets.append(m.group(1))
except OSError: pass
try:
 c=json.load(open("/etc/xray/config.json"))
 for i in c.get("inbounds",[]):
  secrets.extend(u["id"] for u in i.get("settings",{}).get("clients",[]))
  r=i.get("streamSettings",{}).get("realitySettings",{})
  secrets.extend([r.get("privateKey","")]+r.get("shortIds",[]))
except (OSError,ValueError): pass
for value in secrets:
 if value: s=s.replace(value,"[REDACTED]")
s=re.sub(r"(?:hysteria2|hy2|vless)://[^\s]+","[REDACTED URI]",s)
sys.stdout.write(s)
'
}
diagnostics() {
  if (( SERVICE_CREATED )); then
    printf '\nДиагностика: systemctl status hysteria --no-pager\n' >&2
    systemctl status hysteria --no-pager 2>&1 | redact >&2 || true
    printf '\njournalctl -u hysteria --no-pager -n 50\n' >&2
    journalctl -u hysteria --no-pager -n 50 2>&1 | redact >&2 || true
    printf '%s\n' 'Проверьте сообщения выше: ACME — DNS/443 TCP/лимиты CA/часы; bind — занятый порт; permission — права; YAML — конфигурация.' >&2
  fi
  if (( XR_CREATED )); then
    printf '\nsystemctl status xray --no-pager\n' >&2
    systemctl status xray --no-pager 2>&1 | redact >&2 || true
    printf '\njournalctl -u xray --no-pager -n 50\n' >&2
    journalctl -u xray --no-pager -n 50 2>&1 | redact >&2 || true
  fi
}
on_error() { local rc=$?; trap - ERR; printf '\nСбой установщика (код %s).\n' "$rc" >&2; diagnostics; exit "$rc"; }
trap on_error ERR
ask() { [[ -r /dev/tty ]] || fail 'Нужен интерактивный терминал.'; read -r -p "$1" "$2" </dev/tty; }

[[ $EUID -eq 0 ]] || fail 'Запустите: sudo ./install-hysteria.sh'
[[ -f /etc/os-release ]] || fail 'Не удалось определить ОС.'
. /etc/os-release
case "$ID:${VERSION_ID:-}" in
  ubuntu:22.04|ubuntu:24.04|debian:12|debian:13) ;;
  *) fail 'Поддерживаются только Ubuntu 22.04/24.04 и Debian 12/13.' ;;
esac
case "$(uname -m)" in
  x86_64) ARCH=amd64 ;; aarch64|arm64) ARCH=arm64 ;;
  i386|i686) ARCH=386 ;; armv7l) ARCH=armv7 ;;
  *) fail "Архитектура $(uname -m) не поддерживается этим установщиком." ;;
esac
[[ -d /run/systemd/system && $(ps -p 1 -o comm=) == systemd ]] || fail 'systemd должен работать как PID 1.'
command -v systemctl >/dev/null || fail 'systemctl не найден.'
for path in /usr/local/bin /etc /var/lib "$OUT_DIR"; do
  [[ -d "$path" && -w "$path" ]] || fail "Нет доступа к каталогу $path"
  FREE=$(df -Pk "$path" | awk 'END {print $4}')
  [[ "$FREE" =~ ^[0-9]+$ && "$FREE" -ge 524288 ]] || fail "В $path нужно не менее 512 MiB свободного места."
done
# Refuse to overwrite an existing installation or exported credentials.
for path in /usr/local/bin/hysteria /etc/hysteria /var/lib/hysteria /etc/systemd/system/hysteria.service "$OUT_DIR/client.yaml" "$OUT_DIR/connection.txt" /usr/local/bin/xray /etc/xray /etc/systemd/system/xray.service "$OUT_DIR/happ-links.txt" "$OUT_DIR/xray-clients"; do
  [[ ! -e "$path" && ! -L "$path" ]] || fail "Уже существует $path. Это установщик только для первого запуска."
done
[[ -z $(systemctl list-unit-files 'hysteria*.service' --no-legend) ]] || fail 'Обнаружен существующий сервис Hysteria.'
[[ -z $(systemctl list-unit-files 'xray*.service' --no-legend) ]] || fail 'Обнаружен существующий Xray.'
getent passwd hysteria >/dev/null && fail 'Системный пользователь hysteria уже существует.'
getent group hysteria >/dev/null && fail 'Системная группа hysteria уже существует.'

ask 'Введите домен (Enter — домена нет): ' DOMAIN
if [[ -z "$DOMAIN" ]]; then
  printf '%s\n' 'Для стандартной TLS-конфигурации нужен домен,' 'указывающий на этот VPS.' 'Создайте DNS-запись A с IPv4 VPS, без CDN/proxy, дождитесь обновления DNS и запустите скрипт снова.'
  exit 1
fi
DOMAIN=${DOMAIN,,}; DOMAIN=${DOMAIN%.}
[[ ${#DOMAIN} -le 253 && "$DOMAIN" == *.* ]] || fail 'Введите обычное доменное имя, без https:// и порта.'
IFS='.' read -r -a LABELS <<< "$DOMAIN"
for label in "${LABELS[@]}"; do
  [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail 'Некорректный домен. Для IDN используйте punycode.'
done
ask 'Email для Let’s Encrypt: ' EMAIL
[[ "$EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || fail 'Некорректный email.'
printf '%s\n' 'Нужен входящий 443/TCP для ACME TLS-ALPN (включая продление).' 'UFW: установщик разрешает UDP Hysteria и четыре TCP-порта Xray, SSH не меняет.' 'В панели VPS разрешите UDP Hysteria, TCP-порты Xray и 443/TCP для ACME. Не включайте CDN/proxy для домена.'
ask 'Согласны с условиями Let’s Encrypt (https://letsencrypt.org/repository/)? [y/N]: ' CONSENT
[[ "$CONSENT" == y || "$CONSENT" == Y ]] || fail 'Выпуск сертификата отменён.'

# APT itself verifies repository metadata/package signatures. No remote installer.
getent ahostsv4 deb.debian.org >/dev/null || fail 'Нет IPv4 DNS/интернета (проверьте resolver и сеть).'
printf '%s\n' 'Устанавливаю стандартные зависимости через APT…'
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get install -y -qq ca-certificates curl openssl python3 dnsutils iproute2 passwd
TMP=$(mktemp -d)
fetch() { curl -4 --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --retry 2 --connect-timeout 10 --max-time 120 "$@"; }
# Immutable release URLs; resume only inside this run, then verify full checksum.
fetch_binary() {
  local url=$1 dest=$2 attempt rc=1 size
  printf 'Скачиваю %s (до 30 минут на попытку, максимум 3 попытки)…\n' "${dest##*/}"
  for attempt in 1 2 3; do
    if curl -4 --proto '=https' --proto-redir '=https' --tlsv1.2 \
      -fsSL --connect-timeout 20 --max-time 1800 \
      --speed-limit 1024 --speed-time 120 -C - "$url" -o "$dest"; then
      return 0
    else
      rc=$?
    fi
    size=0
    [[ ! -f "$dest" ]] || size=$(stat -c %s "$dest")
    printf 'Загрузка не завершена: код %s, сохранено %s байт.\n' "$rc" "$size" >&2
    if (( attempt == 3 )); then break; fi
    if (( rc == 33 )); then
      printf '%s\n' 'Источник не поддержал докачку; следующая попытка начнётся заново.' >&2
      rm -f -- "$dest"
    else
      printf '%s\n' 'Повторяю с докачкой через 5 секунд…' >&2
    fi
    sleep 5
  done
  printf '%s\n' 'Официальный файл не удалось скачать. Проверьте доступ VPS к GitHub/release-assets; checksum не отключается.' >&2
  return "$rc"
}
IP=$(fetch https://api.ipify.org) || fail 'Не удалось определить внешний IPv4 по HTTPS.'
python3 - "$IP" <<'PY' || fail 'Не найден публичный IPv4.'
import ipaddress,sys
ip=ipaddress.ip_address(sys.argv[1]); assert ip.version==4 and ip.is_global
PY
NAT_DETECTED=0
if ! ip -4 -o addr show scope global | awk '{split($4,a,"/"); print a[1]}' | grep -Fxq "$IP"; then
  NAT_DETECTED=1
  printf '\nВнешний IPv4 %s отсутствует на интерфейсах: возможен NAT.\n' "$IP"
  printf '%s\n' 'Исходящий IPv4 не доказывает наличие выделенного входящего адреса.' 'Продолжение возможно только при подтверждённом входящем NAT с сохранением портов.'
fi
# Use two public resolvers to catch stale or inconsistent A/AAAA records.
for resolver in 1.1.1.1 8.8.8.8; do
  A_RECORDS=$(dig -4 +time=5 +tries=1 +short @"$resolver" "$DOMAIN" A) || fail "DNS-запрос к $resolver не прошёл."
  A_IPS=$(printf '%s\n' "$A_RECORDS" | grep -E '^([0-9]{1,3}\.){3}[0-9]{1,3}$' || true)
  [[ -n "$A_IPS" ]] || fail "У $DOMAIN нет A-записи (resolver $resolver)."
  while IFS= read -r addr; do [[ "$addr" == "$IP" ]] || fail "A-запись $addr не совпадает с IPv4 VPS $IP."; done <<< "$A_IPS"
  AAAA=$(dig -4 +time=5 +tries=1 +short @"$resolver" "$DOMAIN" AAAA) || fail 'Ошибка проверки AAAA.'
  [[ -z "$AAAA" ]] || fail 'Удалите AAAA-запись: этот установщик настраивает только IPv4, а ACME может выбрать IPv6.'
done
udp_free() { [[ -z $(ss -H -aun "sport = :$1") ]]; }
PORT=443
while ! udp_free "$PORT"; do
  ask "UDP-порт $PORT занят. Введите другой (1–65535): " PORT
  [[ "$PORT" =~ ^[0-9]{1,5}$ ]] || fail 'Порт должен быть числом от 1 до 65535.'
  PORT=$((10#$PORT)); (( PORT >= 1 && PORT <= 65535 )) || fail 'Порт вне допустимого диапазона.'
done
[[ -z $(ss -H -altn 'sport = :443') ]] || fail '443/TCP занят. Для встроенного TLS-ALPN ACME нужен свободный 443/TCP.'
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  printf '%s\n' 'UFW активен: убедитесь, что 443/TCP уже разрешён. Новое TCP-правило скрипт не добавит.'
  ask '443/TCP доступен извне, включая UFW и firewall провайдера? [y/N]: ' TCP_OK
  [[ "$TCP_OK" == y || "$TCP_OK" == Y ]] || fail 'Разрешите 443/TCP для ACME и повторите запуск.'
fi

# Keep 443/TCP free for Hysteria ACME. Four Xray ports must be >=1024.
XR_PORTS=()
XR_LABELS=(XHTTP-REALITY XHTTP-TLS gRPC-REALITY gRPC-TLS)
XR_DEFAULTS=(8443 9443 11443 10443)
for index in 0 1 2 3; do
  chosen=${XR_DEFAULTS[$index]}
  while :; do
    ask "${XR_LABELS[$index]} TCP-порт [$chosen]: " answer
    [[ -z "$answer" ]] || chosen=$answer
    [[ "$chosen" =~ ^[0-9]{1,5}$ ]] || fail 'TCP-порт должен быть числом.'
    chosen=$((10#$chosen))
    (( chosen >= 1024 && chosen <= 65535 )) || fail 'Для Xray разрешены порты 1024–65535 (без дополнительных capabilities).'
    duplicate=0
    for existing in "${XR_PORTS[@]}"; do [[ "$existing" != "$chosen" ]] || duplicate=1; done
    if [[ -z $(ss -H -altn "sport = :$chosen") ]] && (( duplicate == 0 )); then break; fi
    printf '%s\n' 'Этот TCP-порт занят или уже выбран. Укажите другой.'
  done
  XR_PORTS+=("$chosen")
done
if (( NAT_DETECTED )); then
  printf '\nУ провайдера должны быть направлены на этот VPS:\n'
  printf '  %s:%s/UDP -> VPS:%s/UDP (Hysteria)\n' "$IP" "$PORT" "$PORT"
  printf '  %s:443/TCP -> VPS:443/TCP (ACME, включая продление)\n' "$IP"
  for chosen in "${XR_PORTS[@]}"; do
    printf '  %s:%s/TCP -> VPS:%s/TCP (Xray)\n' "$IP" "$chosen" "$chosen"
  done
  printf '%s\n' 'Подходит выделенный IPv4 с 1:1 NAT или явный проброс этих портов.' 'Общий исходящий IPv4 без входящего проброса не подходит.'
  ask 'Провайдер подтвердил входящий NAT для этого IPv4 и перечисленных портов? [y/N]: ' NAT_OK
  [[ "$NAT_OK" == y || "$NAT_OK" == Y ]] || fail 'Сначала уточните у провайдера входящий IPv4/проброс. Установщик не может настроить NAT провайдера.'
fi
ask 'REALITY target/SNI [www.microsoft.com]: ' REALITY_HOST
REALITY_HOST=${REALITY_HOST:-www.microsoft.com}; REALITY_HOST=${REALITY_HOST,,}
[[ ${#REALITY_HOST} -le 253 && "$REALITY_HOST" == *.* ]] || fail 'Некорректный REALITY target.'
IFS='.' read -r -a LABELS <<< "$REALITY_HOST"
for label in "${LABELS[@]}"; do
  [[ ${#label} -le 63 && "$label" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?$ ]] || fail 'Некорректный REALITY target.'
done
# Verify the decoy is reachable, has valid TLS1.3 and negotiates HTTP/2.
if ! timeout 25 openssl s_client -4 -connect "$REALITY_HOST:443" -servername "$REALITY_HOST" -verify_hostname "$REALITY_HOST" -verify_return_error -tls1_3 -alpn h2 </dev/null > "$TMP/reality-target.log" 2>&1; then
  fail 'REALITY target недоступен или не прошёл TLS-проверку. Выберите другой HTTPS-сайт с TLS 1.3 и HTTP/2.'
fi
grep -Fq 'ALPN protocol: h2' "$TMP/reality-target.log" || fail 'REALITY target не поддерживает HTTP/2 (h2).'

printf '%s\n' 'Получаю latest stable из официального GitHub API…'
fetch https://api.github.com/repos/apernet/hysteria/releases/latest -o "$TMP/release.json" || fail 'GitHub API недоступен или rate limit. Повторите позже; сторонний источник не используется.'
python3 - "$TMP/release.json" "$ARCH" > "$TMP/assets" <<'PY'
import json,re,sys
r=json.load(open(sys.argv[1])); tag=r.get('tag_name','')
assert not r.get('prerelease') and not r.get('draft') and re.fullmatch(r'(?:app/)?v2\.\d+\.\d+',tag), 'Not a stable Hysteria 2 release'
a={a['name']:a for a in r['assets']}
name='hysteria-linux-'+sys.argv[2]
assert name in a and 'hashes.txt' in a, 'Official binary/checksum asset missing'
for key in (name,'hashes.txt'):
 u=a[key]['browser_download_url']
 assert u.startswith(('https://github.com/apernet/hysteria/releases/download/','https://github.com/HyNetworks/hysteria/releases/download/')), 'Unexpected source'
print(tag); print(name); print(a[name]['browser_download_url']); print(a['hashes.txt']['browser_download_url'])
PY
mapfile -t ASSETS < "$TMP/assets"
TAG=${ASSETS[0]}; ASSET=${ASSETS[1]}
fetch_binary "${ASSETS[2]}" "$TMP/$ASSET"
fetch "${ASSETS[3]}" -o "$TMP/hashes.txt"
python3 - "$TMP/hashes.txt" "$TMP/$ASSET" "$ASSET" <<'PY'
import hashlib,re,sys
matches=[]
for line in open(sys.argv[1]):
 # Standard sha256sum format, plus BSD-style SHA256 (filename) = hash.
 m=re.fullmatch(r'([a-fA-F0-9]{64})\s+\*?(?:\./)?(?:build/)?'+re.escape(sys.argv[3])+r'\s*',line.strip())
 if m: matches.append(m.group(1).lower()); continue
 m=re.fullmatch(r'SHA256 \((?:\./)?(?:build/)?'+re.escape(sys.argv[3])+r'\) = ([a-fA-F0-9]{64})',line.strip())
 if m: matches.append(m.group(1).lower())
assert len(matches)==1, 'Missing/ambiguous checksum; refusing installation'
actual=hashlib.sha256(open(sys.argv[2],'rb').read()).hexdigest()
assert actual==matches[0], 'SHA256 mismatch; refusing installation'
print('Official SHA256: OK')
PY
chmod 700 "$TMP/$ASSET"
"$TMP/$ASSET" version > "$TMP/version" 2>&1
grep -Fq "${TAG#app/}" "$TMP/version" || fail 'Бинарный файл не соответствует версии релиза.'

PASSWORD=$(openssl rand -hex 32)
useradd --system --user-group --home-dir /var/lib/hysteria --no-create-home --shell /usr/sbin/nologin hysteria
install -m 755 -o root -g root "$TMP/$ASSET" /usr/local/bin/hysteria
install -d -m 750 -o root -g hysteria /etc/hysteria
install -d -m 700 -o hysteria -g hysteria /var/lib/hysteria
cat > "$TMP/config.yaml" <<YAML
listen: 0.0.0.0:$PORT
acme:
  domains:
    - $DOMAIN
  email: $EMAIL
  ca: letsencrypt
  type: tls
  listenHost: 0.0.0.0
  dir: /var/lib/hysteria/acme
auth:
  type: password
  password: "$PASSWORD"
YAML
install -m 640 -o root -g hysteria "$TMP/config.yaml" /etc/hysteria/config.yaml
cat > /etc/systemd/system/hysteria.service <<'UNIT'
[Unit]
Description=Hysteria 2 test server
Wants=network-online.target
After=network-online.target

[Service]
Type=simple
User=hysteria
Group=hysteria
WorkingDirectory=/var/lib/hysteria
ExecStart=/usr/local/bin/hysteria server --config /etc/hysteria/config.yaml
Restart=on-failure
RestartSec=5
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
ReadWritePaths=/var/lib/hysteria
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 /etc/systemd/system/hysteria.service
SERVICE_CREATED=1
if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then
  ufw allow "$PORT/udp"
fi
udp_free "$PORT" || fail 'UDP-порт заняли во время установки.'
systemctl daemon-reload
systemctl enable hysteria
systemctl start hysteria

printf '%s\n' 'Жду запуска, сертификата и локального теста (до 180 секунд)…'
# Real Hysteria client: verifies CA chain/SNI/auth; curl verifies HTTPS via SOCKS5.
# Use IPv4 loopback only: this is NOT a test of external UDP reachability.
SOCKS_PORT=$(python3 - <<'PY'
import socket
with socket.socket() as s:
 s.bind(('127.0.0.1',0)); print(s.getsockname()[1])
PY
)
cat > "$TMP/test-client.yaml" <<YAML
server: 127.0.0.1:$PORT
auth: "$PASSWORD"
tls:
  sni: $DOMAIN
  insecure: false
socks5:
  listen: 127.0.0.1:$SOCKS_PORT
YAML
TEST_OK=0
DEADLINE=$((SECONDS + 180))
while (( SECONDS < DEADLINE )); do
  if systemctl is-active --quiet hysteria && [[ -n $(ss -H -lun "sport = :$PORT") ]]; then
    /usr/local/bin/hysteria client --config "$TMP/test-client.yaml" >/dev/null 2>&1 &
    TEST_PID=$!
    for attempt in 1 2 3; do
      if curl -4 --silent --fail --max-time 10 --proxy "socks5h://127.0.0.1:$SOCKS_PORT" https://api.ipify.org -o "$TMP/proxy-ip"; then
        if [[ $(cat "$TMP/proxy-ip") == "$IP" ]]; then TEST_OK=1; break; fi
      fi
      sleep 1
    done
    kill "$TEST_PID" 2>/dev/null || true; wait "$TEST_PID" 2>/dev/null || true; TEST_PID=''
    (( TEST_OK == 0 )) || break
  fi
  sleep 3
done
if (( TEST_OK == 0 )); then
  diagnostics
  fail 'TLS/auth/локальный прокси-тест не прошёл. Проверьте ACME, DNS, 443/TCP, часы VPS, исходящий HTTPS и firewall. Данные клиента не экспортированы.'
fi
CERT_OK=0
while IFS= read -r -d '' cert; do
  if openssl x509 -in "$cert" -noout -checkhost "$DOMAIN" >/dev/null 2>&1 && openssl x509 -in "$cert" -noout -checkend 86400 >/dev/null 2>&1; then CERT_OK=1; break; fi
done < <(find /var/lib/hysteria/acme -type f -name '*.crt' -print0)
(( CERT_OK == 1 )) || fail 'Не найден действующий ACME-сертификат домена.'
systemctl is-active --quiet hysteria
MAIN_PID=$(systemctl show hysteria -p MainPID --value)
[[ "$MAIN_PID" =~ ^[0-9]+$ && "$MAIN_PID" -gt 0 ]] && kill -0 "$MAIN_PID"
[[ $(readlink -f "/proc/$MAIN_PID/exe") == /usr/local/bin/hysteria ]] || fail 'Не совпадает исполняемый файл сервиса.'
ss -H -lunp "sport = :$PORT" | grep -Fq "pid=$MAIN_PID," || fail 'UDP-порт не принадлежит процессу сервиса.'

# ---- Four independent Xray profiles for manual testing in Happ ----
printf '%s\n' 'Устанавливаю Xray из официального релиза…'
fetch https://api.github.com/repos/XTLS/Xray-core/releases/latest -o "$TMP/xray-release.json" || fail 'Официальный GitHub API Xray недоступен.'
python3 - "$TMP/xray-release.json" "$ARCH" > "$TMP/xray-assets" <<'PY'
import json,re,sys
r=json.load(open(sys.argv[1])); tag=r.get('tag_name','')
assert not r.get('draft') and not r.get('prerelease') and re.fullmatch(r'v\d+\.\d+\.\d+',tag), 'Not a stable release'
arch={'amd64':'64','arm64':'arm64-v8a','386':'32','armv7':'arm32-v7a'}[sys.argv[2]]
name=f'Xray-linux-{arch}.zip'; a={a['name']:a for a in r['assets']}
assert name in a and name+'.dgst' in a, 'Official binary/checksum missing'
for key in (name,name+'.dgst'):
 assert a[key]['browser_download_url'].startswith('https://github.com/XTLS/Xray-core/releases/download/'), 'Unexpected download source'
print(tag); print(name); print(a[name]['browser_download_url']); print(a[name+'.dgst']['browser_download_url'])
PY
mapfile -t XR_ASSETS < "$TMP/xray-assets"
XR_TAG=${XR_ASSETS[0]}; XR_ASSET=${XR_ASSETS[1]}
fetch_binary "${XR_ASSETS[2]}" "$TMP/$XR_ASSET"
fetch "${XR_ASSETS[3]}" -o "$TMP/xray.dgst"
python3 - "$TMP/xray.dgst" "$TMP/$XR_ASSET" "$TMP/xray" <<'PY'
import hashlib,re,sys,zipfile
s=open(sys.argv[1]).read(); hashes=[]
for line in s.splitlines():
 if re.search(r'SHA(?:2-)?256|SHA-256',line,re.I) or re.match(r'^[a-fA-F0-9]{64}\s',line):
  hashes+=re.findall(r'(?<![a-fA-F0-9])[a-fA-F0-9]{64}(?![a-fA-F0-9])',line)
assert len(hashes)==1, 'Missing/ambiguous SHA256 checksum'
assert hashlib.sha256(open(sys.argv[2],'rb').read()).hexdigest()==hashes[0].lower(), 'SHA256 mismatch'
with zipfile.ZipFile(sys.argv[2]) as z:
 assert 'xray' in z.namelist(), 'Missing xray binary'
 open(sys.argv[3],'wb').write(z.read('xray'))
print('Xray official SHA256: OK')
PY
chmod 700 "$TMP/xray"
"$TMP/xray" version > "$TMP/xray-version" 2>&1
grep -Fq "${XR_TAG#v}" "$TMP/xray-version" || fail 'Версия бинарного файла Xray не совпала с релизом.'
# No private keys are passed as CLI arguments or printed to stdout.
"$TMP/xray" x25519 > "$TMP/x25519.keys" 2>/dev/null
python3 - "$TMP/x25519.keys" "$TMP/xray-secrets.json" <<'PY'
import json,re,secrets,sys,uuid
s=open(sys.argv[1]).read()
def key(pattern):
 m=re.search(pattern+r'\s*:\s*([A-Za-z0-9_-]{43})',s,re.I)
 assert m, 'Unsupported official x25519 output format'
 return m.group(1)
private=key(r'Private\s*Key')
public=key(r'(?:Public\s*Key|Password(?:\s*\(PublicKey\))?)')
json.dump({'private':private,'public':public,'uuid':str(uuid.uuid4()),'sid':secrets.token_hex(8),'path':'/'+secrets.token_hex(8),'service':'grpc'+secrets.token_hex(4)},open(sys.argv[2],'w'))
PY
KEYFILE=${cert%.crt}.key
[[ -s "$KEYFILE" ]] || fail 'Не найден приватный ключ ACME-сертификата.'
# One protected service account allows both daemons to read the same ACME files.
install -m 755 -o root -g root "$TMP/xray" /usr/local/bin/xray
install -d -m 750 -o root -g hysteria /etc/xray
python3 - "$TMP/xray-secrets.json" "$TMP" "$IP" "$DOMAIN" "$REALITY_HOST" "$cert" "$KEYFILE" "${XR_PORTS[@]}" <<'PY'
import copy,json,pathlib,sys,urllib.parse
secrets=json.load(open(sys.argv[1])); root=pathlib.Path(sys.argv[2])
ip,domain,target,cert,key=sys.argv[3:8]; ports=list(map(int,sys.argv[8:]))
profiles=[('XHTTP-REALITY','xhttp','reality',ports[0]),('XHTTP-TLS','xhttp','tls',ports[1]),('gRPC-REALITY','grpc','reality',ports[2]),('gRPC-TLS','grpc','tls',ports[3])]
inbounds=[]; links=[]
for label,transport,security,port in profiles:
 # The current stable Xray core recognizes network, not method.
 stream={'network':transport,'security':security}
 if transport=='xhttp': stream['xhttpSettings']={'path':secrets['path'],'mode':'auto'}
 else: stream['grpcSettings']={'serviceName':secrets['service']}
 server=copy.deepcopy(stream)
 if security=='reality':
  server['realitySettings']={'show':False,'target':target+':443','serverNames':[target],'privateKey':secrets['private'],'shortIds':[secrets['sid']]}
  stream['realitySettings']={'serverName':target,'fingerprint':'chrome','password':secrets['public'],'shortId':secrets['sid']}
 else:
  server['tlsSettings']={'alpn':['h2'],'minVersion':'1.3','certificates':[{'certificateFile':cert,'keyFile':key,'oneTimeLoading':False}]}
  stream['tlsSettings']={'serverName':domain,'allowInsecure':False,'alpn':['h2']}
 inbounds.append({'tag':label,'listen':'0.0.0.0','port':port,'protocol':'vless','settings':{'clients':[{'id':secrets['uuid']}],'decryption':'none'},'streamSettings':server})
 outbound={'tag':'proxy','protocol':'vless','settings':{'vnext':[{'address':ip,'port':port,'users':[{'id':secrets['uuid'],'encryption':'none'}]}]},'streamSettings':stream}
 client={'log':{'loglevel':'warning'},'inbounds':[{'listen':'127.0.0.1','port':1080,'protocol':'socks','settings':{'auth':'noauth','udp':True}}],'outbounds':[outbound]}
 (root/(label+'.json')).write_text(json.dumps(client,indent=2)+'\n')
 q={'encryption':'none','security':security,'type':transport,'sni':target if security=='reality' else domain}
 if security=='reality': q.update({'fp':'chrome','pbk':secrets['public'],'sid':secrets['sid']})
 else: q['alpn']='h2'
 if transport=='xhttp': q.update({'path':secrets['path'],'mode':'auto'})
 else: q.update({'serviceName':secrets['service'],'mode':'gun'})
 links.append(f"vless://{secrets['uuid']}@{ip}:{port}?{urllib.parse.urlencode(q)}#{label}")
config={'log':{'loglevel':'warning','access':'none'},'inbounds':inbounds,'outbounds':[{'protocol':'freedom','tag':'direct','settings':{'domainStrategy':'UseIPv4'}}]}
(root/'xray-config.json').write_text(json.dumps(config,indent=2)+'\n')
(root/'xray-links.txt').write_text('\n'.join(links)+'\n')
PY
install -m 640 -o root -g hysteria "$TMP/xray-config.json" /etc/xray/config.json
# The downloaded core must accept the documented configuration before service start.
if ! /usr/local/bin/xray run -test -config /etc/xray/config.json > "$TMP/xray-validation.log" 2>&1; then
  printf '%s\n' 'Xray отклонил конфигурацию. Санитизированная диагностика:' >&2
  redact < "$TMP/xray-validation.log" >&2
  fail 'Конфигурация не соответствует скачанной стабильной версии Xray; небезопасный fallback не применяется.'
fi
cat > /etc/systemd/system/xray.service <<'UNIT'
[Unit]
Description=Xray four transport test profiles for Happ
Wants=network-online.target
After=network-online.target hysteria.service

[Service]
Type=simple
User=hysteria
Group=hysteria
WorkingDirectory=/var/lib/hysteria
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=on-failure
RestartSec=5
NoNewPrivileges=true
CapabilityBoundingSet=
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true
UMask=0077

[Install]
WantedBy=multi-user.target
UNIT
chmod 644 /etc/systemd/system/xray.service
XR_CREATED=1
for xr_port in "${XR_PORTS[@]}"; do
  [[ -z $(ss -H -altn "sport = :$xr_port") ]] || fail "TCP-порт $xr_port заняли во время установки."
  if command -v ufw >/dev/null && ufw status | grep -q '^Status: active'; then ufw allow "$xr_port/tcp"; fi
done
systemctl daemon-reload
systemctl enable xray
systemctl start xray
sleep 2
systemctl is-active --quiet xray
XR_PID=$(systemctl show xray -p MainPID --value)
[[ "$XR_PID" =~ ^[0-9]+$ && "$XR_PID" -gt 0 ]] && kill -0 "$XR_PID"
[[ $(readlink -f "/proc/$XR_PID/exe") == /usr/local/bin/xray ]] || fail 'Не совпадает исполняемый файл Xray.'
XR_LABELS=(XHTTP-REALITY XHTTP-TLS gRPC-REALITY gRPC-TLS)
for index in 0 1 2 3; do
  label=${XR_LABELS[$index]}; xr_port=${XR_PORTS[$index]}
  ss -H -ltnp "sport = :$xr_port" | grep -Fq "pid=$XR_PID," || fail "TCP $xr_port не принадлежит Xray."
  LOCAL_PORT=$(python3 - <<'PY'
import socket
with socket.socket() as s:
 s.bind(('127.0.0.1',0)); print(s.getsockname()[1])
PY
)
  python3 - "$TMP/$label.json" "$TMP/xray-test.json" "$LOCAL_PORT" <<'PY'
import json,sys
c=json.load(open(sys.argv[1])); c['inbounds'][0]['port']=int(sys.argv[3]); c['outbounds'][0]['settings']['vnext'][0]['address']='127.0.0.1'
json.dump(c,open(sys.argv[2],'w'))
PY
  /usr/local/bin/xray run -config "$TMP/xray-test.json" >/dev/null 2>&1 &
  TEST_PID=$!; XR_OK=0
  for attempt in 1 2 3 4 5; do
    sleep 1
    if curl -4 --silent --fail --max-time 12 --proxy "socks5h://127.0.0.1:$LOCAL_PORT" https://api.ipify.org -o "$TMP/xray-proxy-ip"; then
      if [[ $(cat "$TMP/xray-proxy-ip") == "$IP" ]]; then XR_OK=1; break; fi
    fi
  done
  kill "$TEST_PID" 2>/dev/null || true; wait "$TEST_PID" 2>/dev/null || true; TEST_PID=''
  if (( XR_OK == 0 )); then diagnostics; fail "$label: локальный тест TLS/REALITY/auth/выхода в интернет не прошёл. Экспорт пяти профилей отменён."; fi
  printf '%s: LOCAL TEST OK (%s/TCP)\n' "$label" "$xr_port"
done
# Export only after all five local proxy tests have passed.
set -o noclobber
{ printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=0#Hysteria2\n' "$PASSWORD" "$IP" "$PORT" "$DOMAIN"; cat "$TMP/xray-links.txt"; } > "$OUT_DIR/happ-links.txt"
mkdir -m 700 "$OUT_DIR/xray-clients"
for label in "${XR_LABELS[@]}"; do install -m 600 "$TMP/$label.json" "$OUT_DIR/xray-clients/$label.json"; done
set +o noclobber
chmod 600 "$OUT_DIR/happ-links.txt"
if [[ ${SUDO_UID:-0} =~ ^[0-9]+$ && ${SUDO_GID:-0} =~ ^[0-9]+$ ]]; then
  chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$OUT_DIR/happ-links.txt"
  chown -R "${SUDO_UID:-0}:${SUDO_GID:-0}" "$OUT_DIR/xray-clients"
fi

# Reserve exports without clobbering existing files/symlinks.
set -o noclobber
cat > "$OUT_DIR/client.yaml" <<YAML
server: $IP:$PORT
auth: "$PASSWORD"
tls:
  sni: $DOMAIN
  insecure: false
socks5:
  listen: 127.0.0.1:1080
YAML
# Hex password/domain/IPv4 need no URI percent-encoding.
printf 'hysteria2://%s@%s:%s/?sni=%s&insecure=0\n' "$PASSWORD" "$IP" "$PORT" "$DOMAIN" > "$OUT_DIR/connection.txt"
set +o noclobber
chmod 600 "$OUT_DIR/client.yaml" "$OUT_DIR/connection.txt"
if [[ ${SUDO_UID:-0} =~ ^[0-9]+$ && ${SUDO_GID:-0} =~ ^[0-9]+$ ]]; then
  chown "${SUDO_UID:-0}:${SUDO_GID:-0}" "$OUT_DIR/client.yaml" "$OUT_DIR/connection.txt"
fi
unset PASSWORD
cat <<SUMMARY
========================================
 HYSTERIA 2 + XRAY / HAPP INSTALLED
========================================
Version: $TAG
Server: $DOMAIN:$PORT (IPv4: $IP)
Protocol: Hysteria 2 / UDP
Hysteria 2: RUNNING
TLS: OK (CA/SNI проверены клиентом)
Port: $PORT/UDP
Service: RUNNING
Local proxy -> Internet: OK
Xray: RUNNING ($XR_TAG)
XHTTP-REALITY: ${XR_PORTS[0]}/TCP — LOCAL TEST OK
XHTTP-TLS: ${XR_PORTS[1]}/TCP — LOCAL TEST OK
gRPC-REALITY: ${XR_PORTS[2]}/TCP — LOCAL TEST OK
gRPC-TLS: ${XR_PORTS[3]}/TCP — LOCAL TEST OK
Happ import: $OUT_DIR/happ-links.txt (5 secret links, mode 600)
External Happ -> VPS: NOT TESTED
Client config: $OUT_DIR/client.yaml
Connection: $OUT_DIR/connection.txt (содержит секрет; права 600)

systemctl status hysteria
systemctl restart hysteria
journalctl -u hysteria -f
systemctl status xray
systemctl restart xray
journalctl -u xray -f

Отключить оба сервиса (не удаляет файлы):
sudo systemctl disable --now hysteria xray
========================================
SUMMARY
printf '%s\n' 'Скопируйте client.yaml на клиентское устройство защищённым каналом.' 'На клиенте: hysteria client --config client.yaml' 'В другом терминале клиента: curl --proxy socks5h://127.0.0.1:1080 https://api.ipify.org' "Ожидаемый результат: $IP" 'URI хранится в connection.txt; импорт поддерживается не всеми клиентами.'
printf '%s\n' 'Happ: обновите приложение, скопируйте одну строку из happ-links.txt, нажмите + → импорт из буфера.' 'Повторите для пяти профилей. Если версия Happ поддерживает импорт нескольких строк, можно скопировать все.' 'По очереди включайте каждый профиль и проверяйте сайты/внешний IPv4 с клиентского устройства.' 'Это ручной выбор резерва, не автоматическое переключение. Общий UUID для четырёх VLESS-профилей — один пользователь.' 'Xray читает тот же ACME-сертификат, что Hysteria; не закрывайте 443/TCP после установки.'
