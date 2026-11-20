#!/usr/bin/env bash
# remnawave-audit.sh — интерактивный аудит ноды/панели Remnawave.
#
# Что делает:
#   1) Проверяет ноду (read-only): CVE-2026-98432 (MPTCP), firewall, порты, selfsteal
#      (301, заглушка, TLS 1.2/1.3, HSTS), SSH, Docker.
#   2) Может исправить то, что безопасно исправить: MPTCP off, правило firewall для порта ноды.
#   3) Проверяет панель через API: offline-ноды, версии Xray, профили (Trojan / Vision),
#      reality target/serverNames, пользователи, домены.
#
# Ничего не меняет без подтверждения. Исправления — только после ответа «y».
#
# Запуск:  bash remnawave-audit.sh
# Отчёт:   reports/<host>-<дата>.md

set -u

C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_FAIL=$'\033[31m'; C_INFO=$'\033[36m'; C_RST=$'\033[0m'
REPORT=""; PASS=0; WARN=0; FAIL=0
DOMAIN=""; PANEL_IP=""; NODE_PORT="2222"
NEED_MPTCP=0; NEED_UFW=0; NEED_SSH=0; NEED_HSTS=0; NEED_301=0

have() { command -v "$1" >/dev/null 2>&1; }
log()  { REPORT+="$*"$'\n'; }
line() { printf '%s\n' "$*"; }
ok()   { PASS=$((PASS+1)); log "- ${C_OK}OK${C_RST}   $*"; line "  ${C_OK}OK${C_RST}   $*"; }
warn() { WARN=$((WARN+1)); log "- ${C_WARN}WARN${C_RST} $*"; line "  ${C_WARN}WARN${C_RST} $*"; }
fail() { FAIL=$((FAIL+1)); log "- ${C_FAIL}FAIL${C_RST} $*"; line "  ${C_FAIL}FAIL${C_RST} $*"; }
info() { log "- ${C_INFO}INFO${C_RST} $*"; line "  ${C_INFO}INFO${C_RST} $*"; }
title(){ line ""; line "${C_INFO}== $* ==${C_RST}"; log ""; log "## $*"; log ""; }

ask() { # ask "вопрос" "дефолт"
  local q="$1" d="${2:-}" a
  if [ -n "$d" ]; then read -rp "$q [$d]: " a; a="${a:-$d}"; else read -rp "$q: " a; fi
  printf '%s' "$a"
}
ask_secret() { local a; read -rsp "$1: " a; echo >&2; printf '%s' "$a"; }

save_report() {
  local name="$1" host; host=$(hostname 2>/dev/null || echo unknown)
  local stamp; stamp=$(date +%Y-%m-%d_%H-%M-%S)
  mkdir -p reports
  local f="reports/${host}-${name}-${stamp}.md"
  {
    echo "# Аудит: ${host} (${name})"
    echo
    printf '%s\n' "$REPORT"
    echo
    echo "**Итог:** OK=$PASS, WARN=$WARN, FAIL=$FAIL"
  } > "$f"
  line ""
  line "Отчёт сохранён: $f  (OK=$PASS WARN=$WARN FAIL=$FAIL)"
}

# ============================ ПРОВЕРКИ НОДЫ ============================

check_system() {
  title "Система"
  local os kern
  os=$( (. /etc/os-release 2>/dev/null; echo "$PRETTY_NAME") )
  kern=$(uname -r)
  ok "ОС: ${os:-unknown}; ядро: $kern"
  ok "Диск /: $(df -h / | awk 'NR==2 {print $5" ("$4" free)"}')"
}

check_mptcp() {
  title "CVE-2026-98432: MPTCP"
  local m; m=$(sysctl -n net.mptcp.enabled 2>/dev/null || echo "n/a")
  if [ "$m" = "0" ]; then ok "MPTCP выключен"; else
    fail "MPTCP включён (net.mptcp.enabled=$m) — дыра CVE-2026-98432"
    NEED_MPTCP=1
  fi
  info "Xray на ноде: версию смотрите в панели (нужна ≥ 26.10.31)"
}

check_firewall() {
  title "Firewall и порт ноды ($NODE_PORT)"
  if have ufw; then
    local st; st=$(ufw status 2>/dev/null | head -1)
    info "ufw: ${st:-n/a}"
    if ufw status 2>/dev/null | grep -qE "^${NODE_PORT}/tcp.*ALLOW.*Anywhere"; then
      fail "Порт $NODE_PORT открыт всем (ufw)"
      NEED_UFW=1
    elif ufw status 2>/dev/null | grep -qE "${NODE_PORT}/tcp"; then
      ok "В ufw есть правило для порта $NODE_PORT"
    else
      warn "Нет правила ufw для порта $NODE_PORT"
      NEED_UFW=1
    fi
    if [ -n "$PANEL_IP" ] && ! ufw status 2>/dev/null | grep -q "$PANEL_IP"; then
      warn "Нет правила с IP панели ($PANEL_IP)"
      NEED_UFW=1
    fi
  else
    warn "ufw не установлен"
    NEED_UFW=1
  fi
  if have docker && docker ps --format '{{.Ports}}' 2>/dev/null | grep -q "0.0.0.0:${NODE_PORT}"; then
    warn "Docker публикует $NODE_PORT на 0.0.0.0 — ufw не фильтрует Docker-порты (нужен DOCKER-USER или файрвол хостера)"
  fi
  if have nft; then
    if nft list ruleset 2>/dev/null | grep -qE "dport ${NODE_PORT}\b"; then
      ok "nftables: правило для $NODE_PORT есть"
    elif have ufw && ufw status 2>/dev/null | grep -q "^Status: active"; then
      info "nftables: отдельного правила нет, ufw активен"
    else
      warn "nftables: правила для $NODE_PORT нет"
    fi
  fi
}

check_selfsteal() {
  title "Selfsteal (443/80/9443)"
  if [ -z "$DOMAIN" ]; then warn "Домен не задан — проверка selfsteal пропущена"; return; fi
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -q caddy; then
    fail "Контейнер selfsteal (caddy) не найден — нода не маскируется"
    return
  fi
  local code; code=$(curl -sI -m 5 -H "Host: $DOMAIN" http://127.0.0.1/ 2>/dev/null | head -1 | awk '{print $2}')
  if [ "$code" = "301" ]; then ok "80 → 301 на https"; else fail "80: код ${code:-нет} вместо 301"; NEED_301=1; fi

  local hdrs hcode
  hdrs=$(curl -skI -m 5 --resolve "$DOMAIN:9443:127.0.0.1" "https://$DOMAIN:9443/" 2>/dev/null)
  hcode=$(printf '%s' "$hdrs" | head -1 | awk '{print $2}')
  if [ "$hcode" = "200" ]; then ok "Заглушка 9443 отвечает 200"; else fail "Заглушка 9443: код ${hcode:-нет}"; fi
  if printf '%s' "$hdrs" | grep -qi '^strict-transport-security:'; then ok "HSTS есть"; else fail "HSTS отсутствует"; NEED_HSTS=1; fi
  if have openssl; then
    echo | openssl s_client -connect 127.0.0.1:9443 -servername "$DOMAIN" -tls1_2 >/dev/null 2>&1 \
      && ok "TLS 1.2" || fail "TLS 1.2 не отвечает"
    echo | openssl s_client -connect 127.0.0.1:9443 -servername "$DOMAIN" -tls1_3 >/dev/null 2>&1 \
      && ok "TLS 1.3" || fail "TLS 1.3 не отвечает"
  fi
}

check_ssh() {
  title "SSH"
  if have sshd; then
    local cfg root pass
    cfg=$(sshd -T 2>/dev/null)
    root=$(printf '%s' "$cfg" | awk '/^permitrootlogin /{print $2}')
    pass=$(printf '%s' "$cfg" | awk '/^passwordauthentication /{print $2}')
    case "$root" in prohibit-password|without-password|no) ok "SSH root: $root" ;; *) warn "SSH PermitRootLogin=$root"; NEED_SSH=1 ;; esac
    [ "$pass" = "no" ] && ok "Пароли SSH выключены" || { warn "SSH PasswordAuthentication=$pass"; NEED_SSH=1; }
  else
    warn "sshd не найден"
  fi
}

node_check() {
  PASS=0; WARN=0; FAIL=0; REPORT=""
  NEED_MPTCP=0; NEED_UFW=0; NEED_SSH=0; NEED_HSTS=0; NEED_301=0
  title "Аудит ноды: $(hostname)"
  check_system; check_mptcp; check_firewall; check_selfsteal; check_ssh
  save_report "node"
}

# ============================ ИСПРАВЛЕНИЯ ============================

fix_mptcp() {
  line ""
  line "${C_WARN}Исправление: MPTCP${C_RST}"
  local a; a=$(ask "Выключить MPTCP сейчас? (y/N)" "N")
  [ "$a" = "y" ] || return 0
  sysctl -w net.mptcp.enabled=0 >/dev/null 2>&1
  echo 'net.mptcp.enabled=0' > /etc/sysctl.d/99-mptcp-off.conf
  ok "MPTCP выключен и сохранён в /etc/sysctl.d/99-mptcp-off.conf"
  NEED_MPTCP=0
}

fix_ufw() {
  line ""
  line "${C_WARN}Исправление: firewall${C_RST}"
  [ -n "$PANEL_IP" ] || { warn "IP панели не задан — пропуск"; return 0; }
  if ! have ufw; then
    local u; u=$(ask "ufw не установлен. Установить ufw? (y/N)" "N")
    [ "$u" = "y" ] || return 0
    if have apt-get; then
      apt-get update -qq >/dev/null 2>&1
      DEBIAN_FRONTEND=noninteractive apt-get install -y ufw >/dev/null 2>&1
    fi
    have ufw || { fail "Не удалось установить ufw"; return 0; }
    ok "ufw установлен"
  fi
  local ssh_port; ssh_port=$(sshd -T 2>/dev/null | awk '/^port /{print $2; exit}')
  ssh_port="${ssh_port:-22}"
  line "Правила: ${ssh_port}/80/443 открыты, порт $NODE_PORT — только с $PANEL_IP, default deny incoming."
  line "${C_FAIL}Внимание:${C_RST} проверьте, что SSH-порт определён верно (${ssh_port}), иначе потеряете доступ."
  local a; a=$(ask "Применить правила ufw? (y/N)" "N")
  [ "$a" = "y" ] || return 0
  ufw allow "${ssh_port}/tcp" >/dev/null 2>&1
  ufw allow 80/tcp >/dev/null 2>&1
  ufw allow 443/tcp >/dev/null 2>&1
  ufw allow from "$PANEL_IP" to any port "$NODE_PORT" proto tcp comment 'remnanode: только панель' >/dev/null 2>&1
  ufw default deny incoming >/dev/null 2>&1
  ufw --force enable >/dev/null 2>&1
  ok "ufw настроен (порт $NODE_PORT — только $PANEL_IP)"
  warn "Проверьте снаружи: Docker-порты ufw не фильтрует. Если порт доступен — нужен DOCKER-USER или файрвол хостера."
  NEED_UFW=0
}

fix_hsts() {
  line ""
  line "${C_WARN}Исправление: HSTS в Caddyfile${C_RST}"
  local cf=/opt/caddy/Caddyfile
  [ -f "$cf" ] || { warn "Caddyfile не найден в /opt/caddy — добавьте HSTS вручную"; return 0; }
  if grep -q 'Strict-Transport-Security' "$cf"; then ok "HSTS уже есть в Caddyfile"; NEED_HSTS=0; return 0; fi
  line "Будет добавлено в блок https: header Strict-Transport-Security \"max-age=31536000; includeSubDomains\""
  local a; a=$(ask "Добавить HSTS и перезапустить Caddy? (y/N)" "N")
  [ "$a" = "y" ] || return 0
  cp "$cf" "${cf}.bak.$(date +%s)"
  awk '{print} !done && /^https:\/\// {print "\theader Strict-Transport-Security \"max-age=31536000; includeSubDomains\""; done=1}' "$cf" > "${cf}.new" \
    && mv "${cf}.new" "$cf"
  local ct; ct=$(docker ps --format '{{.Names}}' 2>/dev/null | grep -m1 caddy || true)
  if [ -n "$ct" ] && docker exec "$ct" caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
    docker restart "$ct" >/dev/null 2>&1
    ok "HSTS добавлен, $ct перезапущен"
    NEED_HSTS=0
  else
    warn "caddy validate не прошёл — проверьте Caddyfile (бэкап рядом)"
  fi
}

fix_ssh() {
  line ""
  line "${C_WARN}Исправление: SSH${C_RST}"
  line "Предлагается: PermitRootLogin prohibit-password, PasswordAuthentication no."
  line "${C_FAIL}Внимание:${C_RST} убедитесь, что вход по ключу работает, иначе потеряете доступ."
  local a; a=$(ask "Применить? (y/N)" "N")
  [ "$a" = "y" ] || return 0
  local f=/etc/ssh/sshd_config.d/99-audit-hardening.conf
  {
    echo "PermitRootLogin prohibit-password"
    echo "PasswordAuthentication no"
  } > "$f"
  sshd -t 2>/dev/null && systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null || true
  ok "SSH: настройки записаны в $f"
  NEED_SSH=0
}

node_fix() {
  node_check
  if [ "$PASS" -eq 0 ] && [ "$FAIL" -eq 0 ] && [ "$WARN" -eq 0 ]; then return; fi
  line ""
  line "${C_INFO}Что можно исправить:${C_RST}"
  [ "$NEED_MPTCP" = 1 ] && line "  - MPTCP выключить"
  [ "$NEED_UFW" = 1 ] && line "  - firewall: порт $NODE_PORT только для IP панели"
  [ "$NEED_SSH" = 1 ] && line "  - SSH: запрет паролей"
  [ "$NEED_301" = 1 ] && line "  - 301 на 80: правится в Caddyfile (вручную)"
  [ "$NEED_HSTS" = 1 ] && line "  - HSTS: правится в Caddyfile (вручную)"
  line ""
  [ "$NEED_MPTCP" = 1 ] && fix_mptcp
  [ "$NEED_UFW" = 1 ] && fix_ufw
  [ "$NEED_SSH" = 1 ] && fix_ssh
  [ "$NEED_HSTS" = 1 ] && fix_hsts
  if [ "$NEED_301" = 1 ]; then
    line ""
    line "${C_INFO}Подсказка по 301:${C_RST} в /opt/caddy/Caddyfile блок http:// должен содержать:"
    line "    redir https://{host}{uri} permanent"
    line "  затем: docker restart caddy-selfsteal"
  fi
  line ""
  local a; a=$(ask "Прогнать проверку повторно? (y/N)" "Y")
  [ "$a" = "y" ] && node_check
}

# ============================ ПАНЕЛЬ ============================

panel_flow() {
  PASS=0; WARN=0; FAIL=0; REPORT=""
  title "Аудит панели (через API)"
  line "Панельный режим читает конфиги из API панели: версии нод, профили Xray (Trojan/Vision/selfsteal),"
  line "пользователей. Запускается на любой машине с доступом к панели."
  local url token
  local envf="${PANEL_ENV:-.env}"
  if [ -f "$envf" ]; then
    url=$(awk -F= '/^PANEL_URL[[:space:]]*=/{sub(/^[^=]*=/,""); print; exit}' "$envf" | tr -d '"' | tr -d "'" | xargs)
    token=$(awk -F= '/^PANEL_API_TOKEN[[:space:]]*=/{sub(/^[^=]*=/,""); print; exit}' "$envf" | tr -d '"' | tr -d "'" | xargs)
  fi
  [ -n "$url" ] || url=$(ask "URL панели" "https://qua.quartzvalley.org")
  [ -n "$token" ] || token=$(ask_secret "API-токен панели")
  [ -z "$token" ] && { fail "Токен не задан"; save_report "panel"; return; }

  api() { curl -sS -m 20 -H "Authorization: Bearer $token" -H "Accept: application/json" "$url$1"; }
  have python3 || { fail "Нужен python3"; save_report "panel"; return; }

  title "Ноды"
  api /api/nodes | python3 -c '
import sys,json
try: d=json.load(sys.stdin)["response"]
except Exception: sys.exit(0)
for n in d:
    v=n.get("versions",{})
    print("%s\t%s\t%s\t%s" % (n["name"], n.get("isConnected"), v.get("node"), v.get("xray")))
' > /tmp/.audit_nodes.tsv
  while IFS=$'\t' read -r name conn nv xv; do
    [ -z "$name" ] && continue
    if [ "$conn" = "True" ]; then ok "$name: online (node $nv, Xray $xv)"; else fail "$name: OFFLINE (node $nv, Xray $xv)"; fi
    case "$xv" in
      26.7.*|26.8.*|26.9.*|26.10.[0-9]|26.10.1[0-9]|26.10.2[0-9]|26.10.30)
        fail "$name: Xray $xv < 26.10.31 (CVE-2026-98432)" ;;
    esac
  done < /tmp/.audit_nodes.tsv

  title "Профили Xray"
  api /api/config-profiles | python3 -c '
import sys,json
try: d=json.load(sys.stdin)["response"]["configProfiles"]
except Exception: sys.exit(0)
for p in d: print(p["uuid"]+"\t"+p["name"])
' > /tmp/.audit_profiles.tsv
  while IFS=$'\t' read -r puuid pname; do
    [ -z "$puuid" ] && continue
    api "/api/config-profiles/$puuid" | python3 -c '
import sys,json
try: d=json.load(sys.stdin)["response"]["config"]["inbounds"]
except Exception: sys.exit(0)
for i in d:
    ss=i.get("streamSettings",{}) or {}; rs=ss.get("realitySettings",{}) or {}
    print("%s|%s|%s|%s|%s" % (i.get("protocol"), ss.get("network"), ss.get("security"),
        rs.get("target"), ",".join(rs.get("serverNames") or [])))
' | while IFS='|' read -r proto net sec target snis; do
        [ -z "$proto" ] && continue
        [ "$proto" = "trojan" ] && fail "$pname: trojan inbound (вложенный TLS, палится)"
        case "$net" in raw|tcp) ;; *) [ "$sec" = "tls" ] && warn "$pname: $proto/$net/tls — Vision невозможен, только резерв" ;; esac
        if [ "$sec" = "reality" ]; then
          [ "$target" = "127.0.0.1:9443" ] || warn "$pname: reality target=$target (ожидается 127.0.0.1:9443)"
          info "$pname: $proto/$net/reality target=$target sni=$snis"
        fi
    done
  done < /tmp/.audit_profiles.tsv

  title "Пользователи"
  api /api/system/stats | python3 -c '
import sys,json
try: d=json.load(sys.stdin)["response"]
except Exception: sys.exit(0)
u=d.get("users",{})
print("total=%s active=%s expired=%s online=%s" % (u.get("totalUsers"),
  (u.get("statusCounts") or {}).get("ACTIVE"), (u.get("statusCounts") or {}).get("EXPIRED"),
  (d.get("onlineStats") or {}).get("onlineNow")))
' | while read -r s; do ok "Статистика: $s"; done

  save_report "panel"
}

# ============================ МЕНЮ ============================

require_root() {
  if [ "$(id -u)" != "0" ]; then
    line "Нужен root. Перезапуск через sudo..."
    exec sudo bash "$0"
  fi
}

node_flow() {
  require_root
  line ""
  DOMAIN=$(ask "Домен ноды (например, de01.example.com)" "$DOMAIN")
  PANEL_IP=$(ask "IP панели (для правила firewall)" "$PANEL_IP")
  NODE_PORT=$(ask "Порт ноды" "$NODE_PORT")
  node_fix
}

main_menu() {
  while true; do
    line ""
    line "${C_INFO}=== Remnawave Audit ===${C_RST}"
    line "  1) Проверить ноду (read-only)"
    line "  2) Проверить и исправить ноду"
    line "  3) Проверить панель (через API)"
    line "  0) Выход"
    local c; c=$(ask "Выбор" "1")
    case "$c" in
      1) require_root
         DOMAIN=$(ask "Домен ноды" "$DOMAIN"); PANEL_IP=$(ask "IP панели" "$PANEL_IP"); NODE_PORT=$(ask "Порт ноды" "$NODE_PORT")
         node_check ;;
      2) node_flow ;;
      3) panel_flow ;;
      0) exit 0 ;;
      *) line "Нет такого пункта" ;;
    esac
  done
}

main_menu
