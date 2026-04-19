#!/usr/bin/env bash
# ============================================================
#  🚀 MTProxy Cascade Installer
#  Telemt + VLESS Reality (RU → Мост)
#  v1.0 — интерактивная установка
# ============================================================

set -euo pipefail

# ── Версия и источник обновлений ─────────────────────────────
VERSION="1.0.0"
GITHUB_RAW_URL="https://raw.githubusercontent.com/ВАШ_НИК/mtproxy-setup/main/mtproxy-setup.sh"
INSTALL_PATH="/usr/local/bin/amtcas"

# ── Цвета и символы ─────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
DIM='\033[2m'
RESET='\033[0m'

ok()   { echo -e "${GREEN}✅ $*${RESET}"; }
info() { echo -e "${CYAN}ℹ️  $*${RESET}"; }
warn() { echo -e "${YELLOW}⚠️  $*${RESET}"; }
err()  { echo -e "${RED}❌ $*${RESET}"; }
sep()  { echo -e "${DIM}────────────────────────────────────────────────────${RESET}"; }
hdr()  { echo -e "\n${BOLD}${BLUE}$*${RESET}"; sep; }

# ── Требования ──────────────────────────────────────────────
REQUIRED_CMDS=(curl docker openssl)

# ── Хелперы ─────────────────────────────────────────────────
ask() {
    # ask "Подсказка" VARNAME [default]
    local prompt="$1" varname="$2" default="${3:-}"
    local hint=""
    [[ -n "$default" ]] && hint=" ${DIM}[${default}]${RESET}"
    while true; do
        echo -ne "${BOLD}${CYAN}$prompt${hint}: ${RESET}"
        read -r value
        value="${value:-$default}"
        if [[ -n "$value" ]]; then
            printf -v "$varname" '%s' "$value"
            return
        fi
        warn "Значение не может быть пустым"
    done
}

ask_secret() {
    local prompt="$1" varname="$2"
    while true; do
        echo -ne "${BOLD}${CYAN}$prompt${RESET}: "
        read -rs value
        echo
        if [[ -n "$value" ]]; then
            printf -v "$varname" '%s' "$value"
            return
        fi
        warn "Значение не может быть пустым"
    done
}

confirm() {
    # confirm "Вопрос?" → 0=да 1=нет
    local prompt="$1"
    echo -ne "${BOLD}${YELLOW}$prompt [y/N]: ${RESET}"
    read -r ans
    [[ "${ans,,}" == "y" || "${ans,,}" == "yes" || "${ans,,}" == "д" || "${ans,,}" == "да" ]]
}

spinner() {
    local pid=$1 msg="${2:-Подождите...}"
    local spin='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
    local i=0
    while kill -0 "$pid" 2>/dev/null; do
        printf "\r${CYAN}${spin:i++%${#spin}:1} ${msg}${RESET}"
        sleep 0.1
    done
    printf "\r%-60s\r" " "
}

check_root() {
    if [[ $EUID -ne 0 ]]; then
        err "Скрипт должен быть запущен от root"
        echo -e "    Запусти: ${BOLD}sudo bash $0${RESET}"
        exit 1
    fi
}

# ── Баннер ──────────────────────────────────────────────────
print_banner() {
    clear
    echo -e "${BOLD}${BLUE}"
    cat << 'EOF'
  ███╗   ███╗████████╗██████╗ ██████╗  ██████╗ ██╗  ██╗██╗   ██╗
  ████╗ ████║╚══██╔══╝██╔══██╗██╔══██╗██╔═══██╗╚██╗██╔╝╚██╗ ██╔╝
  ██╔████╔██║   ██║   ██████╔╝██████╔╝██║   ██║ ╚███╔╝  ╚████╔╝
  ██║╚██╔╝██║   ██║   ██╔═══╝ ██╔══██╗██║   ██║ ██╔██╗   ╚██╔╝
  ██║ ╚═╝ ██║   ██║   ██║     ██║  ██║╚██████╔╝██╔╝ ██╗   ██║
  ╚═╝     ╚═╝   ╚═╝   ╚═╝     ╚═╝  ╚═╝ ╚═════╝ ╚═╝  ╚═╝   ╚═╝
EOF
    echo -e "${RESET}"
    echo -e "  ${BOLD}Каскадный MTProxy${RESET} — Telemt + VLESS Reality"
    echo -e "  ${DIM}Клиент → RU (telemt) → Мост (xray) → Telegram${RESET}"
    echo
}

# ── Проверка зависимостей ────────────────────────────────────
check_deps() {
    hdr "🔍 Проверка зависимостей"

    local missing=()
    for cmd in "${REQUIRED_CMDS[@]}"; do
        if command -v "$cmd" &>/dev/null; then
            ok "$cmd — найден ($(command -v "$cmd"))"
        else
            err "$cmd — не найден"
            missing+=("$cmd")
        fi
    done

    # docker compose (plugin v2)
    if docker compose version &>/dev/null 2>&1; then
        ok "docker compose — найден"
    else
        err "docker compose — не найден"
        missing+=("docker-compose-plugin")
    fi

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo
        warn "Отсутствуют: ${missing[*]}"
        if confirm "Установить недостающее автоматически?"; then
            install_deps
        else
            err "Установи зависимости вручную и перезапусти скрипт"
            exit 1
        fi
    else
        ok "Все зависимости в порядке"
    fi
}

install_deps() {
    hdr "📦 Установка зависимостей"

    info "Обновление пакетов..."
    apt-get update -qq
    apt-get install -y -qq curl wget ca-certificates gnupg lsb-release ufw jq

    if ! command -v docker &>/dev/null; then
        info "Установка Docker..."

        install -m 0755 -d /etc/apt/keyrings

        # Определяем дистрибутив
        local distro
        distro=$(. /etc/os-release && echo "$ID")

        curl -fsSL "https://download.docker.com/linux/${distro}/gpg" \
            -o /etc/apt/keyrings/docker.asc 2>/dev/null
        chmod a+r /etc/apt/keyrings/docker.asc

        echo \
            "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] \
            https://download.docker.com/linux/${distro} \
            $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
            | tee /etc/apt/sources.list.d/docker.list > /dev/null

        apt-get update -qq
        apt-get install -y -qq docker-ce docker-ce-cli containerd.io docker-compose-plugin
        systemctl enable --now docker
        ok "Docker установлен"
    fi
}

# ── Главное меню ─────────────────────────────────────────────
main_menu() {
    hdr "📋 Главное меню"
    echo -e "  ${BOLD}1)${RESET} 🌉  Настроить сервер-мост — Xray VLESS+Reality"
    echo -e "  ${BOLD}2)${RESET} 🇷🇺  Настроить российский сервер  (RU) — Xray-клиент + telemt"
    echo -e "  ${BOLD}3)${RESET} 🔍  Проверить статус всех сервисов"
    echo -e "  ${BOLD}4)${RESET} ❌  Выйти"
    echo
    ask "Выбери пункт" MENU_CHOICE "1"
}

# ══════════════════════════════════════════════════════════════
#  СЕРВЕР-МОСТ: Xray VLESS+Reality
# ══════════════════════════════════════════════════════════════

setup_de() {
    hdr "🌉 Настройка сервера-моста"

    echo -e "${DIM}Этот сервер принимает зашифрованный VLESS+Reality трафик от RU"
    echo -e "и пробрасывает его напрямую в Telegram.${RESET}"
    echo

    # ── Генерация ключей ────────────────────────────────────
    hdr "🔑 Генерация ключей"

    info "Генерирую X25519 ключевую пару..."
    local keypair
    keypair=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null)
    PRIVATE_KEY=$(echo "$keypair" | grep "Private key" | awk '{print $3}')
    PUBLIC_KEY=$(echo "$keypair"  | grep "Public key"  | awk '{print $3}')

    info "Генерирую UUID..."
    UUID=$(docker run --rm ghcr.io/xtls/xray-core:latest uuid 2>/dev/null | tr -d '[:space:]')

    ok "Private key: ${BOLD}${PRIVATE_KEY}${RESET}"
    ok "Public key:  ${BOLD}${PUBLIC_KEY}${RESET}"
    ok "UUID:        ${BOLD}${UUID}${RESET}"

    echo
    warn "Сохрани эти значения — они нужны при настройке RU-сервера:"
    echo -e "  ${BOLD}Public key:${RESET} ${PUBLIC_KEY}"
    echo -e "  ${BOLD}UUID:${RESET}       ${UUID}"
    echo

    # ── Параметры ────────────────────────────────────────────
    hdr "⚙️  Параметры сервера"

    ask "Порт для VLESS (рекомендуется 443)" BRDG_PORT "443"
    ask "SNI-домен для камуфляжа" BRDG_SNI "www.google.com"

    local short_id
    short_id=$(openssl rand -hex 4)
    ask "Short ID (hex 4-16 символов)" SHORT_ID "$short_id"

    # ── Создание файлов ──────────────────────────────────────
    hdr "📁 Создание конфигурации"

    mkdir -p ~/xray-server
    cd ~/xray-server

    cat > config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-in",
      "listen": "0.0.0.0",
      "port": ${BRDG_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "dest": "${BRDG_SNI}:443",
          "xver": 0,
          "serverNames": ["${BRDG_SNI}"],
          "privateKey": "${PRIVATE_KEY}",
          "shortIds": ["${SHORT_ID}"]
        }
      },
      "sniffing": { "enabled": false }
    }
  ],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom" }
  ]
}
EOF

    cat > docker-compose.yml << EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-server
    restart: unless-stopped
    ports:
      - "${BRDG_PORT}:${BRDG_PORT}/tcp"
    volumes:
      - ./config.json:/etc/xray/config.json:ro
    command: ["run", "-c", "/etc/xray/config.json"]
    cap_drop: [ALL]
    cap_add: [NET_BIND_SERVICE]
    security_opt: [no-new-privileges:true]
    read_only: true
    tmpfs: ["/tmp"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    ok "config.json создан"
    ok "docker-compose.yml создан"

    # ── Фаервол ──────────────────────────────────────────────
    hdr "🔒 Настройка фаервола"
    ufw allow OpenSSH  2>/dev/null || true
    ufw allow "${BRDG_PORT}/tcp" 2>/dev/null || true
    ufw --force enable 2>/dev/null || true
    ok "UFW настроен — порт ${BRDG_PORT}/tcp открыт"

    # ── Запуск ───────────────────────────────────────────────
    hdr "🚀 Запуск Xray"

    info "Загружаю образ и запускаю контейнер..."
    (docker compose pull -q 2>/dev/null; docker compose up -d 2>/dev/null) &
    spinner $! "Запуск xray-server..."
    wait $! || true

    sleep 2

    if docker ps --format '{{.Names}}' | grep -q "xray-server"; then
        ok "xray-server запущен"
    else
        err "Не удалось запустить контейнер"
        docker compose logs --tail=20
        exit 1
    fi

    # ── Итог ─────────────────────────────────────────────────
    echo
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${RESET}"
    echo -e "${BOLD}${GREEN}  ✅ Сервер-мост настроен успешно!${RESET}"
    echo -e "${BOLD}${GREEN}════════════════════════════════════════════════════${RESET}"
    echo
    echo -e "  ${BOLD}Данные для RU-сервера (скопируй их):${RESET}"
    sep
    echo -e "  ${CYAN}Мост IP:${RESET}       ${BOLD}$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')${RESET}"
    echo -e "  ${CYAN}Мост Port:${RESET}     ${BOLD}${BRDG_PORT}${RESET}"
    echo -e "  ${CYAN}UUID:${RESET}        ${BOLD}${UUID}${RESET}"
    echo -e "  ${CYAN}Public key:${RESET}  ${BOLD}${PUBLIC_KEY}${RESET}"
    echo -e "  ${CYAN}Short ID:${RESET}    ${BOLD}${SHORT_ID}${RESET}"
    echo -e "  ${CYAN}SNI:${RESET}         ${BOLD}${BRDG_SNI}${RESET}"
    sep
    echo
    warn "Скопируй эти данные — они понадобятся при настройке RU-сервера!"
    echo
}

# ══════════════════════════════════════════════════════════════
#  RU-СЕРВЕР: Xray-клиент + telemt
# ══════════════════════════════════════════════════════════════

setup_ru() {
    hdr "🇷🇺 Настройка российского (RU) сервера"

    echo -e "${DIM}Этот сервер принимает клиентов Telegram (порт 443),"
    echo -e "и туннелирует трафик через сервер-мост по VLESS+Reality.${RESET}"
    echo

    # ── Данные сервера-моста ────────────────────────────────
    hdr "📡 Данные сервера-моста"
    info "Введи данные, которые были получены при настройке сервера-моста"
    echo

    ask "IP-адрес сервера-моста" BRDG_IP
    ask "Порт сервера-моста" BRDG_PORT "443"
    ask "UUID пользователя" BRDG_UUID
    ask "Public key сервера-моста" BRDG_PUBLIC_KEY
    ask "Short ID" BRDG_SHORT_ID "abcdef1234567890"
    ask "SNI-домен (должен совпадать с мостом)" BRDG_SNI "www.google.com"

    # ── Параметры MTProxy ────────────────────────────────────
    hdr "⚙️  Параметры MTProxy"

    info "Генерирую секрет для клиентов Telegram..."
    local mt_secret
    mt_secret=$(openssl rand -hex 16)
    ask "Секрет для MTProxy (hex 32 символа)" MT_SECRET "$mt_secret"

    ask "Имя пользователя в конфиге" MT_USER "myuser"
    ask "TLS-домен для камуфляжа MTProxy" MT_TLS_DOMAIN "www.google.com"

    # ── sysctl ───────────────────────────────────────────────
    hdr "⚙️  Системные настройки"
    info "Разрешаю бинд на порты < 1024 для non-root контейнера..."
    sysctl -w net.ipv4.ip_unprivileged_port_start=443 > /dev/null
    grep -q "ip_unprivileged_port_start" /etc/sysctl.conf \
        && sed -i 's/.*ip_unprivileged_port_start.*/net.ipv4.ip_unprivileged_port_start=443/' /etc/sysctl.conf \
        || echo "net.ipv4.ip_unprivileged_port_start=443" >> /etc/sysctl.conf
    ok "net.ipv4.ip_unprivileged_port_start=443 установлен"

    # ── Создание xray-client ─────────────────────────────────
    hdr "📁 Создание конфигурации Xray-клиента"

    mkdir -p ~/xray-client
    cd ~/xray-client

    cat > config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "socks-in",
      "listen": "127.0.0.1",
      "port": 1080,
      "protocol": "socks",
      "settings": {
        "auth": "noauth",
        "udp": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "vless-out",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${BRDG_IP}",
            "port": ${BRDG_PORT},
            "users": [
              {
                "id": "${BRDG_UUID}",
                "flow": "xtls-rprx-vision",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp",
        "security": "reality",
        "realitySettings": {
          "show": false,
          "fingerprint": "chrome",
          "serverName": "${BRDG_SNI}",
          "publicKey": "${BRDG_PUBLIC_KEY}",
          "shortId": "${BRDG_SHORT_ID}",
          "spiderX": "/"
        }
      }
    }
  ]
}
EOF

    cat > docker-compose.yml << EOF
services:
  xray:
    image: ghcr.io/xtls/xray-core:latest
    container_name: xray-client
    restart: unless-stopped
    network_mode: host
    volumes:
      - ./config.json:/etc/xray/config.json:ro
    command: ["run", "-c", "/etc/xray/config.json"]
    security_opt: [no-new-privileges:true]
    read_only: true
    tmpfs: ["/tmp"]
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"
EOF

    ok "~/xray-client/config.json создан"
    ok "~/xray-client/docker-compose.yml создан"

    # ── Создание telemt ──────────────────────────────────────
    hdr "📁 Создание конфигурации telemt"

    mkdir -p ~/mtproxy
    cd ~/mtproxy

    cat > telemt.toml << EOF
show_link = ["${MT_USER}"]

[general]
use_middle_proxy = false
prefer_ipv6 = false
fast_mode = true

[general.modes]
classic = false
secure = false
tls = true

[general.links]
show = "*"

[server]
port = 443

[server.api]
enabled = true
listen = "127.0.0.1:9091"
whitelist = ["127.0.0.0/8"]
minimal_runtime_enabled = false
minimal_runtime_cache_ttl_ms = 1000

[[server.listeners]]
ip = "0.0.0.0"

[censorship]
tls_domain = "${MT_TLS_DOMAIN}"
mask = true
tls_emulation = true

[access]
replay_check_len = 65536
ignore_time_skew = false

[access.users]
${MT_USER} = "${MT_SECRET}"

[[upstreams]]
type = "socks5"
address = "127.0.0.1:1080"
weight = 10
enabled = true
EOF

    cat > docker-compose.yml << EOF
services:
  telemt:
    image: whn0thacked/telemt-docker:latest
    container_name: telemt
    restart: unless-stopped
    network_mode: host
    environment:
      RUST_LOG: "info"
    volumes:
      - ./telemt.toml:/etc/telemt.toml:ro
      - telemt-data:/etc/telemt
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
    read_only: true
    tmpfs:
      - /tmp:rw,nosuid,nodev,noexec,size=16m
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
    logging:
      driver: json-file
      options:
        max-size: "10m"
        max-file: "3"

volumes:
  telemt-data:
EOF

    ok "~/mtproxy/telemt.toml создан"
    ok "~/mtproxy/docker-compose.yml создан"

    # ── Фаервол ──────────────────────────────────────────────
    hdr "🔒 Настройка фаервола"
    ufw allow OpenSSH  2>/dev/null || true
    ufw allow 443/tcp  2>/dev/null || true
    ufw deny  1080/tcp 2>/dev/null || true
    ufw --force enable 2>/dev/null || true
    ok "UFW: 443/tcp открыт, 1080/tcp закрыт снаружи"

    # ── Запуск xray-client ───────────────────────────────────
    hdr "🚀 Запуск Xray-клиента"

    cd ~/xray-client
    info "Загружаю образ и запускаю xray-client..."
    (docker compose pull -q 2>/dev/null; docker compose up -d 2>/dev/null) &
    spinner $! "Запуск xray-client..."
    wait $! || true
    sleep 3

    # ── Проверка туннеля ─────────────────────────────────────
    hdr "🔍 Проверка VLESS-туннеля"

    info "Проверяю что трафик идёт через мост..."
    local tunnel_ip
    tunnel_ip=$(curl -s --socks5 127.0.0.1:1080 --max-time 10 https://ifconfig.me 2>/dev/null || true)

    if [[ "$tunnel_ip" == "$BRDG_IP" ]]; then
        ok "Туннель работает! Внешний IP через туннель: ${BOLD}${tunnel_ip}${RESET}"
    elif [[ -n "$tunnel_ip" ]]; then
        warn "Туннель активен, но IP не совпадает с мостом: ${tunnel_ip}"
        warn "Возможно мост находится за NAT — это нормально"
    else
        err "Туннель не отвечает"
        echo
        warn "Логи xray-client:"
        docker compose logs --tail=20
        echo
        err "Проверь правильность UUID, ключей и IP сервера-моста"
        if ! confirm "Продолжить запуск telemt несмотря на ошибку туннеля?"; then
            exit 1
        fi
    fi

    # ── Запуск telemt ────────────────────────────────────────
    hdr "🚀 Запуск telemt MTProxy"

    cd ~/mtproxy
    info "Загружаю образ и запускаю telemt..."
    (docker compose pull -q 2>/dev/null; docker compose up -d 2>/dev/null) &
    spinner $! "Запуск telemt..."
    wait $! || true
    sleep 4

    if docker ps --format '{{.Names}}' | grep -q "^telemt$"; then
        ok "telemt запущен"
    else
        err "telemt не запустился"
        docker compose logs --tail=30
        exit 1
    fi

    # ── Получить ссылку ──────────────────────────────────────
    sleep 2
    local RU_IP
    RU_IP=$(curl -s --max-time 5 https://ifconfig.me 2>/dev/null || hostname -I | awk '{print $1}')
    local TG_LINK="tg://proxy?server=${RU_IP}&port=443&secret=ee${MT_SECRET}"

    # Попробовать получить ссылку из логов
    local LOG_LINK
    LOG_LINK=$(cd ~/mtproxy && docker compose logs 2>/dev/null | grep "tg://" | tail -1 | grep -oP 'tg://[^\s]+' || true)
    [[ -n "$LOG_LINK" ]] && TG_LINK="$LOG_LINK"

    # ── Финальная проверка пути ──────────────────────────────
    print_summary "$RU_IP" "$tunnel_ip" "$TG_LINK"
}

# ── Финальный отчёт ─────────────────────────────────────────
print_summary() {
    local ru_ip="$1" tunnel_ip="$2" tg_link="$3"

    echo
    echo -e "${BOLD}${GREEN}"
    cat << 'EOF'
  ╔════════════════════════════════════════════════════════╗
  ║         ✅  НАСТРОЙКА ЗАВЕРШЕНА УСПЕШНО!               ║
  ╚════════════════════════════════════════════════════════╝
EOF
    echo -e "${RESET}"

    echo -e "  ${BOLD}🗺️  Путь соединения:${RESET}"
    echo
    echo -e "  📱 Клиент Telegram"
    echo -e "      │  MTProto/Fake-TLS :443"
    echo -e "      ▼"
    echo -e "  🇷🇺 RU-сервер ${BOLD}${ru_ip}${RESET}"
    echo -e "      │  VLESS+Reality"
    echo -e "      ▼"
    if [[ -n "$tunnel_ip" ]]; then
        echo -e "  🌉 Сервер-мост ${BOLD}${tunnel_ip}${RESET}  ${GREEN}✅ доступен${RESET}"
    else
        echo -e "  🌉 Сервер-мост ${YELLOW}⚠️  не проверен${RESET}"
    fi
    echo -e "      │  TCP"
    echo -e "      ▼"
    echo -e "  📨 Telegram DC"
    echo

    sep
    echo -e "  ${BOLD}🔗 Ссылка для подключения:${RESET}"
    echo
    echo -e "  ${BOLD}${CYAN}${tg_link}${RESET}"
    echo
    sep
    echo
    echo -e "  ${BOLD}📋 Полезные команды:${RESET}"
    echo
    echo -e "  ${DIM}# Логи telemt${RESET}"
    echo -e "  cd ~/mtproxy && docker compose logs -f"
    echo
    echo -e "  ${DIM}# Логи xray-клиента${RESET}"
    echo -e "  cd ~/xray-client && docker compose logs -f"
    echo
    echo -e "  ${DIM}# Статус контейнеров${RESET}"
    echo -e "  docker ps"
    echo
    echo -e "  ${DIM}# Все ссылки через API${RESET}"
    echo -e "  curl -s http://127.0.0.1:9091/v1/users | jq"
    echo
}

# ── Проверка статуса ─────────────────────────────────────────
check_status() {
    hdr "🔍 Проверка статуса сервисов"

    # xray-server (DE)
    if docker ps --format '{{.Names}}' | grep -q "xray-server"; then
        ok "xray-мост — запущен"
    else
        warn "xray-мост — не запущен (ожидаемо если это RU-сервер)"
    fi

    # xray-client (RU)
    if docker ps --format '{{.Names}}' | grep -q "xray-client"; then
        ok "xray-client — запущен"
        info "Проверяю туннель..."
        local tip
        tip=$(curl -s --socks5 127.0.0.1:1080 --max-time 10 https://ifconfig.me 2>/dev/null || true)
        if [[ -n "$tip" ]]; then
            ok "Туннель работает → внешний IP: ${BOLD}${tip}${RESET}"
        else
            err "Туннель не отвечает"
        fi
    else
        warn "xray-client — не запущен"
    fi

    # telemt
    if docker ps --format '{{.Names}}' | grep -q "^telemt$"; then
        ok "telemt MTProxy — запущен"
        local link
        link=$(cd ~/mtproxy 2>/dev/null && docker compose logs 2>/dev/null | grep "tg://" | tail -1 | grep -oP 'tg://[^\s]+' || true)
        [[ -n "$link" ]] && info "Ссылка: ${CYAN}${link}${RESET}"
    else
        warn "telemt — не запущен"
    fi
    echo
}

# ── Самоустановка ────────────────────────────────────────────
self_install() {
    local script_path
    script_path="$(realpath "$0")"

    # Уже установлен и это тот же файл — ничего не делаем
    if [[ "$script_path" == "$INSTALL_PATH" ]]; then
        return
    fi

    cp "$script_path" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"
    ok "Скрипт установлен — теперь запускай просто: ${BOLD}amtcas${RESET}"
}

# ── Проверка обновлений ──────────────────────────────────────
check_update() {
    # Пропускаем если нет curl или нет сети
    if ! command -v curl &>/dev/null; then return; fi

    echo -ne "${DIM}🔄 Проверяю обновления...${RESET}"

    local remote_version
    remote_version=$(
        curl -fsSL --max-time 5 "$GITHUB_RAW_URL" 2>/dev/null \
        | grep -m1 '^VERSION=' \
        | cut -d'"' -f2
    ) || true

    # Нет ответа от GitHub — пропускаем тихо
    if [[ -z "$remote_version" ]]; then
        printf "\r%-40s\r" " "
        return
    fi

    printf "\r%-40s\r" " "

    # Сравниваем версии (semver: major.minor.patch)
    if [[ "$remote_version" == "$VERSION" ]]; then
        ok "Версия актуальна: ${BOLD}v${VERSION}${RESET}"
        return
    fi

    # Проверяем что remote действительно новее через sort -V
    local newer
    newer=$(printf '%s\n%s\n' "$VERSION" "$remote_version" | sort -V | tail -1)

    if [[ "$newer" != "$remote_version" ]]; then
        # remote старше или равна — игнорируем
        ok "Версия актуальна: ${BOLD}v${VERSION}${RESET}"
        return
    fi

    echo
    echo -e "${YELLOW}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${YELLOW}║  🆕 Доступна новая версия!                           ║${RESET}"
    echo -e "${YELLOW}║     Текущая:  v${VERSION}                               ║${RESET}"
    echo -e "${YELLOW}║     Новая:    v${remote_version}                               ║${RESET}"
    echo -e "${YELLOW}╚══════════════════════════════════════════════════════╝${RESET}"
    echo

    if confirm "Обновиться до v${remote_version} прямо сейчас?"; then
        do_update "$remote_version"
    else
        warn "Продолжаю с текущей версией v${VERSION}"
        echo
    fi
}

do_update() {
    local new_version="$1"
    info "Скачиваю v${new_version}..."

    local tmp
    tmp=$(mktemp)

    if curl -fsSL --max-time 30 "$GITHUB_RAW_URL" -o "$tmp" 2>/dev/null; then
        # Проверяем что скачалось валидное (содержит маркер VERSION=)
        if ! grep -q '^VERSION=' "$tmp"; then
            rm -f "$tmp"
            err "Скачанный файл повреждён — обновление отменено"
            return 1
        fi

        chmod +x "$tmp"
        mv "$tmp" "$INSTALL_PATH"
        ok "Обновлено до v${new_version} → ${INSTALL_PATH}"
        echo
        info "Перезапускаю скрипт с новой версией..."
        sleep 1
        exec "$INSTALL_PATH" "$@"
    else
        rm -f "$tmp"
        err "Не удалось скачать обновление — проверь интернет"
        return 1
    fi
}

# ── Точка входа ──────────────────────────────────────────────
main() {
    print_banner
    check_root
    check_deps
    self_install
    check_update

    while true; do
        main_menu
        case "$MENU_CHOICE" in
            1) setup_de ;;
            2) setup_ru ;;
            3) check_status ;;
            4) echo -e "\n${DIM}До свидания! 👋${RESET}\n"; exit 0 ;;
            *) warn "Неверный выбор, попробуй снова" ;;
        esac

        echo
        if ! confirm "Вернуться в главное меню?"; then
            echo -e "\n${DIM}До свидания! 👋${RESET}\n"
            exit 0
        fi
    done
}

main "$@"
