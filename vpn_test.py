#!/usr/bin/env python3
"""Rootless H1Cloud/Pterodactyl test: one VLESS + XHTTP + REALITY profile.
Only writes its own happ_vpn_test directory. No systemd, apt, TUN or root.
Official Xray v26.3.27 is pinned to the version tested for this configuration.
"""
import base64
import hashlib
import http.client
import ipaddress
import json
import os
import pathlib
import platform
import re
import secrets
import shutil
import signal
import socket
import ssl
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
import uuid
import zipfile

VERSION = "v26.3.27"
PUBLIC_HOST = "de-bots3.h1cloud.net"
DEFAULT_PORT = 25276
TARGET = "www.cloudflare.com"
BASE = pathlib.Path(__file__).resolve().parent / "happ_vpn_test"
PROCESSES = []
SECRET_VALUES = []
os.umask(0o077)


def sanitized(text):
    for value in sorted(set(SECRET_VALUES), key=len, reverse=True):
        if value:
            text = text.replace(value, "[REDACTED]")
    return re.sub(r"(?:vless|hysteria2|hy2)://[^\s]+", "[REDACTED URI]", text)


def write_private(path, text):
    if path.is_symlink():
        raise RuntimeError(f"Отказ: файл {path.name} является symlink.")
    fd, temporary = tempfile.mkstemp(dir=BASE, prefix=".tmp-")
    try:
        with os.fdopen(fd, "w") as output:
            output.write(text)
            os.fchmod(output.fileno(), 0o600)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


class HTTPSRedirectOnly(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        if urllib.parse.urlsplit(newurl).scheme != "https":
            raise RuntimeError("Отказ: redirect с HTTPS на другой протокол.")
        return super().redirect_request(req, fp, code, msg, headers, newurl)


OPENER = urllib.request.build_opener(HTTPSRedirectOnly())


def request(url, headers=None):
    if not url.startswith("https://github.com/XTLS/Xray-core/releases/download/"):
        raise RuntimeError("Неожиданный источник загрузки.")
    req = urllib.request.Request(url, headers={"User-Agent": "Happ-container-test/1", **(headers or {})})
    return OPENER.open(req, timeout=40)


def sha256_file(path):
    h = hashlib.sha256()
    with path.open("rb") as f:
        for block in iter(lambda: f.read(1024 * 1024), b""):
            h.update(block)
    return h.hexdigest()


def download_archive(url, path):
    for attempt in range(1, 4):
        offset = path.stat().st_size if path.exists() else 0
        print(f"Загрузка официального Xray: попытка {attempt}/3, уже {offset} байт.", flush=True)
        try:
            headers = {"Range": f"bytes={offset}-"} if offset else {}
            with request(url, headers) as response:
                status = response.status
                if offset and status == 206:
                    cr = response.headers.get("Content-Range", "")
                    if not cr.startswith(f"bytes {offset}-"):
                        raise RuntimeError("Неверный offset докачки.")
                    mode = "ab"
                elif status == 200:
                    mode = "wb"  # No range support: safely restart the full file.
                else:
                    raise RuntimeError(f"Неожиданный HTTP status: {status}.")
                content_length = response.headers.get("Content-Length", "")
                expected = (offset if mode == "ab" else 0) + int(content_length) if content_length.isdigit() else None
                deadline = time.monotonic() + 1800
                with path.open(mode) as output:
                    while True:
                        if time.monotonic() > deadline:
                            raise TimeoutError("Лимит загрузки: 30 минут на попытку.")
                        block = response.read(256 * 1024)
                        if not block:
                            break
                        output.write(block)
                        if output.tell() > 128 * 1024 * 1024:
                            raise RuntimeError("Архив превышает допустимый размер.")
                    if expected is not None and output.tell() != expected:
                        raise http.client.IncompleteRead(b"", expected - output.tell())
            return
        except urllib.error.HTTPError as error:
            if error.code == 416 and path.exists():
                path.unlink()  # Restart; never accept an incomplete file without checksum.
            print(f"HTTP {error.code}; загрузка не завершена.", flush=True)
        except (OSError, TimeoutError, http.client.IncompleteRead) as error:
            print("Сетевой сбой: " + sanitized(str(error)), flush=True)
        if attempt < 3:
            time.sleep(5)
    raise RuntimeError("Не удалось скачать официальный Xray. Частичный файл сохранён для следующего запуска.")


def ensure_binary():
    arch = {"x86_64": "64", "amd64": "64", "aarch64": "arm64-v8a", "arm64": "arm64-v8a", "i686": "32", "i386": "32", "armv7l": "arm32-v7a"}.get(platform.machine().lower())
    if platform.system() != "Linux" or not arch:
        raise RuntimeError("Нужен Linux с поддерживаемой архитектурой Xray.")
    binary = BASE / "xray"
    metadata = BASE / "binary.json"
    for path in (binary, metadata, BASE / "download.zip"):
        if path.is_symlink():
            raise RuntimeError("Отказ: symlink внутри каталога теста.")
    if binary.is_file() and metadata.is_file():
        data = json.loads(metadata.read_text())
        if data.get("version") != VERSION or data.get("arch") != arch or sha256_file(binary) != data.get("binary_sha256"):
            raise RuntimeError("Кэш бинарного файла не прошёл проверку. Не запускаю изменённый Xray.")
        binary.chmod(0o700)
        print(f"Проверенный Xray {VERSION}: используется сохранённый файл.", flush=True)
        return binary
    if shutil.disk_usage(BASE).free < 150 * 1024 * 1024:
        raise RuntimeError("Для первой загрузки нужно не менее 150 MiB свободного места.")
    asset = f"Xray-linux-{arch}.zip"
    url = f"https://github.com/XTLS/Xray-core/releases/download/{VERSION}/{asset}"
    with request(url + ".dgst") as response:
        text = response.read(16385).decode("utf-8")
    if len(text) > 16384:
        raise RuntimeError("Слишком большой checksum-файл.")
    hashes = []
    for line in text.splitlines():
        if re.search(r"SHA(?:2-)?256|SHA-256", line, re.I) or re.match(r"^[a-fA-F0-9]{64}\s", line):
            hashes += re.findall(r"(?<![a-fA-F0-9])[a-fA-F0-9]{64}(?![a-fA-F0-9])", line)
    if len(hashes) != 1:
        raise RuntimeError("Не найден однозначный официальный SHA-256.")
    archive = BASE / "download.zip"
    download_archive(url, archive)
    if sha256_file(archive) != hashes[0].lower():
        archive.unlink()
        raise RuntimeError("SHA-256 не совпал. Файл удалён, запуск запрещён.")
    with zipfile.ZipFile(archive) as z:
        item = z.getinfo("xray")
        if item.file_size > 128 * 1024 * 1024:
            raise RuntimeError("Неожиданный размер бинарного файла.")
        temp = BASE / ".xray-install"
        if temp.is_symlink():
            raise RuntimeError("Неожиданный symlink.")
        with z.open(item) as source, temp.open("wb") as output:
            shutil.copyfileobj(source, output, 1024 * 1024)
        temp.chmod(0o700)
        os.replace(temp, binary)
    write_private(metadata, json.dumps({"version": VERSION, "arch": arch, "archive_sha256": hashes[0].lower(), "binary_sha256": sha256_file(binary)}, indent=2))
    archive.unlink()
    print("Official Xray SHA-256: OK", flush=True)
    return binary


def run_checked(args):
    result = subprocess.run(args, capture_output=True, text=True, timeout=25)
    if result.returncode:
        raise RuntimeError(sanitized(result.stdout + result.stderr))
    return result.stdout + result.stderr


def get_keys(binary):
    path = BASE / "secrets.json"
    if path.is_symlink():
        raise RuntimeError("Неожиданный symlink secrets.json.")
    if path.exists():
        keys = json.loads(path.read_text())
        required = ("private", "public", "uuid", "sid", "path")
        if any(not isinstance(keys.get(k), str) or not keys[k] for k in required):
            raise RuntimeError("Неполный secrets.json; ключи автоматически не заменяются.")
        path.chmod(0o600)
    else:
        output = run_checked([str(binary), "x25519"])
        private = re.search(r"Private\s*Key\s*:\s*([A-Za-z0-9_-]{43})", output, re.I)
        public = re.search(r"(?:Public\s*Key|Password(?:\s*\(PublicKey\))?)\s*:\s*([A-Za-z0-9_-]{43})", output, re.I)
        if not private or not public:
            raise RuntimeError("Неизвестный формат x25519; ключи не выводятся.")
        keys = {"private": private.group(1), "public": public.group(1), "uuid": str(uuid.uuid4()), "sid": secrets.token_hex(8), "path": "/" + secrets.token_hex(8)}
        write_private(path, json.dumps(keys, indent=2))
    SECRET_VALUES.extend(keys.values())
    return keys


def configs(keys, port, socks_port):
    common = {"network": "xhttp", "security": "reality", "xhttpSettings": {"path": keys["path"], "mode": "auto"}}
    server = {"log": {"loglevel": "warning", "access": "none"}, "inbounds": [{"listen": "0.0.0.0", "port": port, "protocol": "vless", "settings": {"clients": [{"id": keys["uuid"]}], "decryption": "none"}, "streamSettings": {**common, "realitySettings": {"show": False, "target": TARGET + ":443", "serverNames": [TARGET], "privateKey": keys["private"], "shortIds": [keys["sid"]]}}}], "outbounds": [{"protocol": "freedom", "settings": {"domainStrategy": "UseIPv4"}}]}
    client = {"log": {"loglevel": "warning", "access": "none"}, "inbounds": [{"listen": "127.0.0.1", "port": socks_port, "protocol": "socks", "settings": {"auth": "noauth"}}], "outbounds": [{"protocol": "vless", "settings": {"vnext": [{"address": "127.0.0.1", "port": port, "users": [{"id": keys["uuid"], "encryption": "none"}]}]}, "streamSettings": {**common, "realitySettings": {"serverName": TARGET, "fingerprint": "chrome", "password": keys["public"], "shortId": keys["sid"]}}}]}
    q = {"encryption": "none", "security": "reality", "type": "xhttp", "sni": TARGET, "fp": "chrome", "pbk": keys["public"], "sid": keys["sid"], "path": keys["path"], "mode": "auto"}
    link = f"vless://{keys['uuid']}@{PUBLIC_HOST}:{port}?{urllib.parse.urlencode(q)}#H1Cloud-XHTTP-REALITY"
    return server, client, link


def recv_exact(sock, amount):
    data = b""
    while len(data) < amount:
        chunk = sock.recv(amount - len(data))
        if not chunk:
            raise RuntimeError("SOCKS-соединение закрыто.")
        data += chunk
    return data


def https_via_socks(port, host, path):
    context = ssl.create_default_context()
    with socket.create_connection(("127.0.0.1", port), timeout=15) as sock:
        sock.sendall(b"\x05\x01\x00")
        if recv_exact(sock, 2) != b"\x05\x00":
            raise RuntimeError("SOCKS5 negotiation failed.")
        encoded = host.encode("ascii")
        sock.sendall(b"\x05\x01\x00\x03" + bytes([len(encoded)]) + encoded + (443).to_bytes(2, "big"))
        reply = recv_exact(sock, 4)
        if reply[:2] != b"\x05\x00":
            raise RuntimeError("SOCKS5 CONNECT failed.")
        address_size = {1: 4, 4: 16}.get(reply[3])
        if reply[3] == 3:
            address_size = recv_exact(sock, 1)[0]
        if address_size is None:
            raise RuntimeError("Unknown SOCKS address type.")
        recv_exact(sock, address_size + 2)
        with context.wrap_socket(sock, server_hostname=host) as tls:
            tls.sendall(f"GET {path} HTTP/1.1\r\nHost: {host}\r\nConnection: close\r\n\r\n".encode("ascii"))
            response = http.client.HTTPResponse(tls)
            response.begin()
            if response.status != 200:
                raise RuntimeError(f"HTTP status {response.status}")
            body = response.read(8193).decode("utf-8", errors="replace")
    found = body.strip() if host == "api.ipify.org" else next((x[3:] for x in body.splitlines() if x.startswith("ip=")), "")
    address = ipaddress.ip_address(found)
    if not address.is_global:
        raise RuntimeError("HTTPS-тест не вернул публичный IP.")
    return str(address)


def stop(proc):
    if proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()


def signal_stop(signum, frame):
    raise KeyboardInterrupt


def main():
    if BASE.is_symlink():
        raise RuntimeError("Каталог теста не должен быть symlink.")
    BASE.mkdir(mode=0o700, exist_ok=True)
    BASE.chmod(0o700)
    port_text = os.environ.get("SERVER_PORT", str(DEFAULT_PORT))
    if not re.fullmatch(r"[0-9]{1,5}", port_text):
        raise RuntimeError("Некорректный SERVER_PORT.")
    port = int(port_text)
    if not 1024 <= port <= 65535:
        raise RuntimeError("Нужен выделенный непривилегированный TCP-порт.")
    # Do not disrupt another application on the allocated port.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        try:
            sock.bind(("0.0.0.0", port))
        except OSError:
            raise RuntimeError(f"Порт {port}/TCP занят. Другое приложение не останавливаю.")
    print(f"Контейнерный тест: {PUBLIC_HOST}:{port}, один XHTTP + REALITY.", flush=True)
    context = ssl.create_default_context()
    context.minimum_version = ssl.TLSVersion.TLSv1_3
    context.maximum_version = ssl.TLSVersion.TLSv1_3
    context.set_alpn_protocols(["h2"])
    with socket.create_connection((TARGET, 443), timeout=20) as sock:
        with context.wrap_socket(sock, server_hostname=TARGET) as tls:
            if tls.selected_alpn_protocol() != "h2":
                raise RuntimeError("REALITY target не согласовал HTTP/2.")
    binary = ensure_binary()
    version = run_checked([str(binary), "version"])
    if VERSION[1:] not in version:
        raise RuntimeError("Версия бинарного файла не совпадает с проверенной.")
    keys = get_keys(binary)
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        socks_port = sock.getsockname()[1]
    server, client, link = configs(keys, port, socks_port)
    config = BASE / "server.json"
    write_private(config, json.dumps(server, indent=2))
    run_checked([str(binary), "run", "-test", "-config", str(config)])
    for logfile in (BASE / "server.log", BASE / "test-client.log"):
        if logfile.is_symlink():
            raise RuntimeError("Неожиданный symlink лога.")
    with (BASE / "server.log").open("w") as log:
        proc = subprocess.Popen([str(binary), "run", "-config", str(config)], stdout=log, stderr=log)
    PROCESSES.append(proc)
    time.sleep(1)
    if proc.poll() is not None:
        raise RuntimeError("Xray не запустился:\n" + sanitized((BASE / "server.log").read_text()[-6000:]))
    # Verify actual listener; no claim of external port reachability here.
    with socket.create_connection(("127.0.0.1", port), timeout=5):
        pass
    client_path = BASE / ".test-client.json"
    write_private(client_path, json.dumps(client))
    with (BASE / "test-client.log").open("w") as log:
        test = subprocess.Popen([str(binary), "run", "-config", str(client_path)], stdout=log, stderr=log)
    PROCESSES.append(test)
    time.sleep(1)
    egress = None
    for host, path in (("api.ipify.org", "/"), ("www.cloudflare.com", "/cdn-cgi/trace")):
        try:
            egress = https_via_socks(socks_port, host, path)
            break
        except Exception as error:
            print("Локальный HTTPS-тест: " + sanitized(str(error)), flush=True)
    stop(test)
    client_path.unlink(missing_ok=True)
    if egress is None:
        details = sanitized((BASE / "test-client.log").read_text(errors="replace")[-6000:])
        raise RuntimeError("REALITY/auth/выход в интернет не прошёл тест. Ссылка не экспортирована.\n" + details)
    if proc.poll() is not None:
        raise RuntimeError("Сервер завершился во время проверки.")
    write_private(BASE / "happ-link.txt", link + "\n")
    print("\n========================================", flush=True)
    print("Xray process: RUNNING\nConfig: ACCEPTED\nLocal listener: " + str(port) + "/TCP", flush=True)
    print("REALITY + auth + HTTPS: LOCAL TEST OK\nEgress IP: " + egress, flush=True)
    print("External Happ -> container: NOT TESTED", flush=True)
    print("Happ link: happ_vpn_test/happ-link.txt (600, contains secret)", flush=True)
    print("Ключи сохраняются между перезапусками. Ссылку в общий лог не вывожу.", flush=True)
    print("Процесс остаётся запущенным; остановка — кнопкой Стоп в панели.", flush=True)
    print("========================================", flush=True)
    result = proc.wait()
    raise RuntimeError(f"Сервер Xray завершился, код {result}.")


if __name__ == "__main__":
    signal.signal(signal.SIGTERM, signal_stop)
    signal.signal(signal.SIGINT, signal_stop)
    try:
        main()
    except KeyboardInterrupt:
        print("Останавливаю тестовый Xray…", flush=True)
    except Exception as error:
        print("ОШИБКА: " + sanitized(str(error)), file=sys.stderr, flush=True)
        sys.exit_code = 1
    finally:
        for process in reversed(PROCESSES):
            stop(process)
    sys.exit(getattr(sys, "exit_code", 0))
