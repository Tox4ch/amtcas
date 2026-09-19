#!/usr/bin/env bash
#
# vps-check.sh — приёмка нового VPS за первый час (12 проверок)
# По мотивам: https://gig.ovh/t/priyomka-novogo-vps-za-pervyj-chas-12-proverok-poka-dejstvuet-moneyback/504
#
# Запуск: sudo bash vps-check.sh [--home-ip 1.2.3.4] [--skip-fio] [--skip-speed] [--out /path]
#
set -uo pipefail

# ---------- параметры ----------
HOME_IP=""
SKIP_FIO=0
SKIP_SPEED=0
OUT_DIR="./vps-check-report-$(date +%Y%m%d-%H%M%S)"
FIO_RUNTIME=15   # секунд на каждый fio-тест (статья предлагает 30 — можно увеличить через --fio-runtime)

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home-ip) HOME_IP="$2"; shift 2 ;;
    --skip-fio) SKIP_FIO=1; shift ;;
    --skip-speed) SKIP_SPEED=1; shift ;;
    --out) OUT_DIR="$2"; shift 2 ;;
    --fio-runtime) FIO_RUNTIME="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--home-ip IP] [--skip-fio] [--skip-speed] [--out DIR] [--fio-runtime SEC]"
      exit 0 ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

mkdir -p "$OUT_DIR"
RAW_LOG="$OUT_DIR/raw.log"
REPORT_MD="$OUT_DIR/report.md"
REPORT_HTML="$OUT_DIR/report.html"
: > "$RAW_LOG"

# ---------- утилиты ----------
declare -A STATUS   # OK / WARN / FAIL / SKIP
declare -A DETAIL
declare -A VALUE

log()  { echo "[$(date '+%H:%M:%S')] $*" | tee -a "$RAW_LOG" >&2; }
run()  { echo "+ $*" >> "$RAW_LOG"; "$@" >> "$RAW_LOG" 2>&1; }
have() { command -v "$1" >/dev/null 2>&1; }

set_result() {
  local key="$1" status="$2" value="$3" detail="$4"
  STATUS["$key"]="$status"
  VALUE["$key"]="$value"
  DETAIL["$key"]="$detail"
  log "[$status] $key — $value"
}

need_root() {
  if [[ $EUID -ne 0 ]]; then
    log "Внимание: скрипт не запущен от root — часть проверок (dmesg, установка пакетов) может не сработать."
  fi
}

install_if_missing() {
  local pkg="$1" bin="${2:-$1}"
  if ! have "$bin"; then
    if have apt-get; then
      log "Устанавливаю $pkg..."
      apt-get update -qq >> "$RAW_LOG" 2>&1
      apt-get install -y -qq "$pkg" >> "$RAW_LOG" 2>&1
    elif have yum; then
      yum install -y -q "$pkg" >> "$RAW_LOG" 2>&1
    elif have apk; then
      apk add --quiet "$pkg" >> "$RAW_LOG" 2>&1
    fi
  fi
}

need_root

echo "=================================================================="
echo " Приёмка VPS — 12 проверок первого часа"
echo " Отчёт будет сохранён в: $OUT_DIR"
echo "=================================================================="

# =========================================================
# ЭТАП 1: ЖЕЛЕЗО
# =========================================================

# --- Проверка 1: виртуализация ---
log "Проверка 1/12: тип виртуализации..."
VIRT="unknown"
if have systemd-detect-virt; then
  VIRT=$(systemd-detect-virt 2>/dev/null || echo "unknown")
fi
case "$VIRT" in
  kvm)
    set_result "virt" "OK" "KVM" "Полноценная виртуализация: своё ядро, WireGuard в ядре, Docker без оговорок." ;;
  openvz|lxc|lxc-libvirt)
    set_result "virt" "WARN" "$VIRT" "Контейнерная виртуализация на чужом ядре: часть модулей может быть недоступна, ресурсы могут быть перепроданы." ;;
  none)
    set_result "virt" "OK" "bare-metal / none" "Виртуализация не обнаружена (возможно, выделенный сервер)." ;;
  *)
    set_result "virt" "WARN" "$VIRT" "Тип виртуализации не kvm — проверьте вручную ограничения хостера." ;;
esac

# --- Проверка 2: CPU и steal time ---
log "Проверка 2/12: CPU и steal time (5 сек)..."
CPU_MODEL=$(lscpu 2>/dev/null | grep -m1 "Model name" | sed 's/Model name:\s*//')
VMSTAT_OUT=$(vmstat 1 5 2>/dev/null)
echo "$VMSTAT_OUT" >> "$RAW_LOG"
STEAL_AVG=$(echo "$VMSTAT_OUT" | tail -n +3 | awk '{sum+=$NF; n++} END {if (n>0) printf "%.1f", sum/n; else print "NA"}')
if [[ "$STEAL_AVG" == "NA" ]]; then
  set_result "cpu_steal" "WARN" "не удалось измерить" "vmstat не вернул данных."
elif (( $(echo "$STEAL_AVG <= 2" | bc -l 2>/dev/null || echo 1) )); then
  set_result "cpu_steal" "OK" "${STEAL_AVG}% steal" "Нода не перегружена ($CPU_MODEL)."
elif (( $(echo "$STEAL_AVG <= 5" | bc -l 2>/dev/null || echo 0) )); then
  set_result "cpu_steal" "WARN" "${STEAL_AVG}% steal" "Заметное отъедание CPU соседями по ноде."
else
  set_result "cpu_steal" "FAIL" "${STEAL_AVG}% steal" "Нода перегружена — в пиковые часы производительность будет проседать. Тариф это не лечит."
fi

# --- Проверка 3: память ---
log "Проверка 3/12: память и OOM..."
MEM_TOTAL=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
SWAP_TOTAL=$(free -h 2>/dev/null | awk '/^Swap:/{print $2}')
run free -h
OOM_HITS=$(dmesg 2>/dev/null | grep -c -i -E "oom|killed process" || true)
if [[ "$OOM_HITS" -gt 0 ]]; then
  set_result "memory" "WARN" "${MEM_TOTAL} RAM, swap=${SWAP_TOTAL}, OOM-событий: $OOM_HITS" "Обнаружены OOM-килы на свежем сервере — плохой знак (шаблон или нехватка памяти)."
else
  set_result "memory" "OK" "${MEM_TOTAL} RAM, swap=${SWAP_TOTAL}" "OOM-килов не обнаружено. Сверьте объём RAM с тарифом вручную."
fi

# --- Проверка 4: диск (fio) ---
if [[ "$SKIP_FIO" -eq 1 ]]; then
  set_result "disk_fio" "SKIP" "пропущено" "Проверка диска отключена флагом --skip-fio."
else
  log "Проверка 4/12: диск через fio (randread/randwrite 4k, ~$((FIO_RUNTIME*2))с)..."
  install_if_missing fio
  if ! have fio; then
    set_result "disk_fio" "SKIP" "fio недоступен" "Не удалось установить fio (нет сети/прав)."
  else
    FIO_DIR=$(mktemp -d)
    FIO_READ=$(fio --name=t --directory="$FIO_DIR" --filename=test.fio --size=512M \
      --direct=1 --rw=randread --bs=4k --iodepth=64 --runtime="$FIO_RUNTIME" --time_based \
      --group_reporting 2>>"$RAW_LOG")
    echo "$FIO_READ" >> "$RAW_LOG"
    READ_IOPS=$(echo "$FIO_READ" | grep -Eo 'IOPS=[0-9.]+[kK]?' | head -1 | grep -Eo '[0-9.]+[kK]?')

    FIO_WRITE=$(fio --name=t --directory="$FIO_DIR" --filename=test.fio --size=512M \
      --direct=1 --rw=randwrite --bs=4k --iodepth=64 --runtime="$FIO_RUNTIME" --time_based \
      --group_reporting 2>>"$RAW_LOG")
    echo "$FIO_WRITE" >> "$RAW_LOG"
    WRITE_IOPS=$(echo "$FIO_WRITE" | grep -Eo 'IOPS=[0-9.]+[kK]?' | head -1 | grep -Eo '[0-9.]+[kK]?')
    rm -rf "$FIO_DIR"

    to_num() {
      local v="$1"
      if [[ "$v" == *k || "$v" == *K ]]; then
        echo "${v%[kK]}" | awk '{print $1*1000}'
      else
        echo "$v"
      fi
    }
    READ_NUM=$(to_num "${READ_IOPS:-0}")
    WRITE_NUM=$(to_num "${WRITE_IOPS:-0}")
    MIN_IOPS=$(awk -v a="$READ_NUM" -v b="$WRITE_NUM" 'BEGIN{print (a<b)?a:b}')

    if (( $(echo "$MIN_IOPS >= 15000" | bc -l 2>/dev/null || echo 0) )); then
      set_result "disk_fio" "OK" "read=${READ_IOPS:-?} IOPS, write=${WRITE_IOPS:-?} IOPS" "Похоже на настоящий NVMe."
    elif (( $(echo "$MIN_IOPS >= 5000" | bc -l 2>/dev/null || echo 0) )); then
      set_result "disk_fio" "WARN" "read=${READ_IOPS:-?} IOPS, write=${WRITE_IOPS:-?} IOPS" "Уровень SATA SSD, а не NVMe — сверьте с тарифом."
    else
      set_result "disk_fio" "FAIL" "read=${READ_IOPS:-?} IOPS, write=${WRITE_IOPS:-?} IOPS" "Сотни IOPS — вероятно HDD или жёстко зарезанный диск. Плохо для БД/Nextcloud/Immich."
    fi
  fi
fi

# =========================================================
# ЭТАП 2: СЕТЬ
# =========================================================

# --- Проверка 5: полоса ---
if [[ "$SKIP_SPEED" -eq 1 ]]; then
  set_result "bandwidth" "SKIP" "пропущено" "Проверка полосы отключена флагом --skip-speed."
else
  log "Проверка 5/12: скорость сети (speedtest, может занять минуту)..."
  install_if_missing speedtest-cli
  if have speedtest-cli; then
    SPEED_OUT=$(timeout 90 speedtest-cli --simple 2>>"$RAW_LOG")
    echo "$SPEED_OUT" >> "$RAW_LOG"
    DL=$(echo "$SPEED_OUT" | awk '/Download/{print $2, $3}')
    UL=$(echo "$SPEED_OUT" | awk '/Upload/{print $2, $3}')
    PING=$(echo "$SPEED_OUT" | awk '/Ping/{print $2, $3}')
    if [[ -n "$DL" ]]; then
      set_result "bandwidth" "OK" "↓ ${DL:-?}, ↑ ${UL:-?}, ping ${PING:-?}" "Разовый замер. Повторите тест в пиковые часы вечером — статья настаивает на двух замерах."
    else
      set_result "bandwidth" "WARN" "не удалось измерить" "speedtest-cli не вернул результат (таймаут/блокировка)."
    fi
  else
    set_result "bandwidth" "SKIP" "speedtest-cli недоступен" "Не удалось установить speedtest-cli."
  fi
fi

# --- Проверка 6: маршруты и задержки (mtr) ---
log "Проверка 6/12: mtr до целевого хоста..."
MTR_TARGET="${HOME_IP:-1.1.1.1}"
install_if_missing mtr-tiny mtr
if have mtr; then
  MTR_OUT=$(mtr -rwbzc 20 "$MTR_TARGET" 2>>"$RAW_LOG")
  echo "$MTR_OUT" >> "$RAW_LOG"
  LAST_LOSS=$(echo "$MTR_OUT" | tail -n1 | awk '{print $3}')
  LAST_AVG=$(echo "$MTR_OUT" | tail -n1 | awk '{print $6}')
  if [[ -z "$HOME_IP" ]]; then
    set_result "mtr" "WARN" "цель: 1.1.1.1 (потери ${LAST_LOSS:-?}, avg ${LAST_AVG:-?}мс)" "Домашний IP не указан (--home-ip), тест сделан до 1.1.1.1. Для точной картины прогоните mtr отдельно в обе стороны до вашего дома."
  else
    set_result "mtr" "OK" "цель: $MTR_TARGET (потери ${LAST_LOSS:-?}, avg ${LAST_AVG:-?}мс)" "Проверьте отдельно и обратное направление (с домашней машины до сервера) — маршруты бывают несимметричными."
  fi
else
  set_result "mtr" "SKIP" "mtr недоступен" "Не удалось установить mtr-tiny."
fi

# --- Проверка 7: MTU ---
log "Проверка 7/12: MTU / фрагментация..."
if ping -M do -s 1472 -c 2 8.8.8.8 >>"$RAW_LOG" 2>&1; then
  set_result "mtu" "OK" "1500 байт проходит" "Полноразмерные пакеты не фрагментируются."
else
  set_result "mtu" "WARN" "1500 байт НЕ проходит" "Где-то по пути туннель с уменьшенным MTU — источник багов вида «сайты открываются наполовину», особенно поверх WireGuard."
fi

# --- Проверка 8: IPv6 ---
log "Проверка 8/12: IPv6..."
IPV6_ADDR=$(timeout 5 curl -6 -s ifconfig.co 2>>"$RAW_LOG")
if [[ -n "$IPV6_ADDR" ]] && timeout 5 ping -6 -c3 2001:4860:4860::8888 >>"$RAW_LOG" 2>&1; then
  set_result "ipv6" "OK" "$IPV6_ADDR" "IPv6 работает и ходит наружу."
else
  set_result "ipv6" "WARN" "недоступен" "IPv6 не настроен или не маршрутизируется. Некритично, если он вам не нужен."
fi

# =========================================================
# ЭТАП 3: РЕПУТАЦИЯ IP
# =========================================================

log "Определяю внешний IP..."
MY_IP=$(timeout 5 curl -s ifconfig.me 2>>"$RAW_LOG")

# --- Проверка 9: чёрные списки ---
log "Проверка 9/12: чёрные списки (DNSBL)..."
if [[ -z "$MY_IP" ]]; then
  set_result "blacklist" "SKIP" "не удалось определить IP" "curl ifconfig.me не ответил."
else
  REV_IP=$(echo "$MY_IP" | awk -F. '{print $4"."$3"."$2"."$1}')
  BL_HITS=0
  BL_LIST=""
  for zone in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org; do
    if have dig; then
      RES=$(dig +short "${REV_IP}.${zone}" 2>>"$RAW_LOG")
    elif have host; then
      RES=$(host "${REV_IP}.${zone}" 2>>"$RAW_LOG" | grep "has address" || true)
    else
      RES=""
    fi
    if [[ -n "$RES" ]]; then
      BL_HITS=$((BL_HITS+1))
      BL_LIST="$BL_LIST $zone"
    fi
  done
  if [[ "$BL_HITS" -eq 0 ]]; then
    set_result "blacklist" "OK" "$MY_IP — чист по basic DNSBL" "Автопроверка Spamhaus ZEN/SpamCop/Barracuda не нашла листингов. Дополнительно вручную проверьте check.spamhaus.org и mxtoolbox.com/blacklists.aspx для полной картины."
  else
    set_result "blacklist" "FAIL" "$MY_IP в списках:$BL_LIST" "IP уже засвечен в чёрных списках — просите замену у хостера или возврат денег."
  fi
fi

# --- Проверка 10: rDNS и порт 25 ---
log "Проверка 10/12: rDNS и порт 25..."
if [[ -z "$MY_IP" ]]; then
  set_result "rdns" "SKIP" "не удалось определить IP" ""
else
  PTR=$(dig -x "$MY_IP" +short 2>>"$RAW_LOG")
  PORT25="закрыт"
  if timeout 5 bash -c "cat < /dev/null > /dev/tcp/smtp.gmail.com/25" 2>>"$RAW_LOG"; then
    PORT25="открыт"
  fi
  PTR_NOTE="PTR: ${PTR:-нет записи}"
  if echo "$PTR" | grep -qiE "spam|relay|abuse|blacklist"; then
    set_result "rdns" "WARN" "$PTR_NOTE, порт 25: $PORT25" "PTR-запись намекает на подозрительную историю адреса."
  else
    set_result "rdns" "OK" "$PTR_NOTE, порт 25: $PORT25" "Порт 25 закрыт — нормально для большинства задач; если планируете свой почтовый сервер, уточните политику разблокировки у хостера."
  fi
fi

# --- Проверка 11: как IP видят сервисы ---
log "Проверка 11/12: репутация IP у сервисов (ipinfo.io)..."
if [[ -z "$MY_IP" ]]; then
  set_result "ip_reputation" "SKIP" "не удалось определить IP" ""
else
  IPINFO=$(timeout 5 curl -s "https://ipinfo.io/${MY_IP}/json" 2>>"$RAW_LOG")
  echo "$IPINFO" >> "$RAW_LOG"
  ORG=$(echo "$IPINFO" | grep -o '"org": *"[^"]*"' | cut -d'"' -f4)
  COUNTRY=$(echo "$IPINFO" | grep -o '"country": *"[^"]*"' | cut -d'"' -f4)
  set_result "ip_reputation" "WARN" "org: ${ORG:-?}, country: ${COUNTRY:-?}" "Данные ipinfo.io для справки. Вручную проверьте, не помечен ли диапазон как hosting/proxy/VPN, и откройте с сервера те сервисы, ради которых он покупался — дешёвые диапазоны банят целыми подсетями."
fi

# =========================================================
# ЭТАП 4: ПРИГОДНОСТЬ ПОД ЗАДАЧИ
# =========================================================

# --- Проверка 12: TUN, Docker, nested-виртуализация ---
log "Проверка 12/12: TUN / Docker / nested-виртуализация..."
TUN_OK="нет"
[[ -e /dev/net/tun ]] && TUN_OK="да"

NESTED_FLAGS=$(grep -cE "vmx|svm" /proc/cpuinfo 2>/dev/null || echo 0)

DOCKER_OK="не проверено"
if have docker; then
  if timeout 30 docker run --rm hello-world >>"$RAW_LOG" 2>&1; then
    DOCKER_OK="работает"
  else
    DOCKER_OK="установлен, но hello-world не прошёл"
  fi
else
  DOCKER_OK="не установлен"
fi

DETAIL_12="TUN: $TUN_OK; nested-виртуализация флагов: $NESTED_FLAGS; Docker: $DOCKER_OK"
if [[ "$TUN_OK" == "да" ]]; then
  set_result "tun_docker" "OK" "$DETAIL_12" "TUN доступен — WireGuard/OpenVPN/sing-box заработают."
else
  set_result "tun_docker" "WARN" "$DETAIL_12" "/dev/net/tun отсутствует — без него не поднимутся WireGuard/OpenVPN/sing-box в TUN-режиме. На контейнерных VPS его обычно нужно включать в панели хостера."
fi

# =========================================================
# ИТОГОВЫЙ ОТЧЁТ
# =========================================================

ORDER=(virt cpu_steal memory disk_fio bandwidth mtr mtu ipv6 blacklist rdns ip_reputation tun_docker)
declare -A TITLES=(
  [virt]="1. Виртуализация"
  [cpu_steal]="2. CPU и steal time"
  [memory]="3. Память и OOM"
  [disk_fio]="4. Диск (fio, случайный доступ 4k)"
  [bandwidth]="5. Пропускная способность сети"
  [mtr]="6. Маршруты и задержки (mtr)"
  [mtu]="7. MTU / фрагментация"
  [ipv6]="8. IPv6"
  [blacklist]="9. Чёрные списки IP (DNSBL)"
  [rdns]="10. rDNS и порт 25"
  [ip_reputation]="11. Репутация IP у сервисов"
  [tun_docker]="12. TUN, Docker, nested-виртуализация"
)

OK_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
for k in "${ORDER[@]}"; do
  case "${STATUS[$k]:-SKIP}" in
    OK) OK_COUNT=$((OK_COUNT+1));;
    WARN) WARN_COUNT=$((WARN_COUNT+1));;
    FAIL) FAIL_COUNT=$((FAIL_COUNT+1));;
    *) SKIP_COUNT=$((SKIP_COUNT+1));;
  esac
done

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  VERDICT="ВОЗВРАТ / замена — есть критичные проблемы (FAIL)."
elif [[ "$WARN_COUNT" -ge 3 ]]; then
  VERDICT="ПОД ВОПРОСОМ — много замечаний (WARN), стоит взвесить или уточнить у хостера."
else
  VERDICT="МОЖНО ОБЖИВАТЬ — критичных проблем не найдено."
fi

{
  echo "# Отчёт приёмки VPS"
  echo
  echo "**Дата:** $(date '+%Y-%m-%d %H:%M:%S %Z')"
  echo "**Хост:** $(hostname 2>/dev/null || echo unknown)"
  echo "**IP:** ${MY_IP:-неизвестен}"
  echo "**CPU:** ${CPU_MODEL:-неизвестен}"
  echo
  echo "## Итог: $VERDICT"
  echo
  echo "OK: $OK_COUNT · WARN: $WARN_COUNT · FAIL: $FAIL_COUNT · SKIP: $SKIP_COUNT"
  echo
  echo "| # | Проверка | Статус | Значение |"
  echo "|---|----------|--------|----------|"
  for k in "${ORDER[@]}"; do
    st="${STATUS[$k]:-SKIP}"
    val="${VALUE[$k]:-—}"
    echo "| ${TITLES[$k]} | | **$st** | $val |"
  done
  echo
  echo "## Детали"
  for k in "${ORDER[@]}"; do
    echo
    echo "### ${TITLES[$k]} — ${STATUS[$k]:-SKIP}"
    echo "- Значение: ${VALUE[$k]:-—}"
    echo "- Комментарий: ${DETAIL[$k]:-—}"
  done
  echo
  echo "## Что сделать вручную (скрипт не покрывает полностью)"
  echo "- Разовые сетевые замеры не заменяют повторный тест днём/вечером — прогоните проверки 5 и 6 ещё раз в пиковые часы."
  echo "- Проверьте check.spamhaus.org и mxtoolbox.com/blacklists.aspx вручную для полной картины по чёрным спискам."
  echo "- Прогоните mtr в обе стороны (с сервера до дома и с дома до сервера)."
  echo "- Перечитайте ToS хостера: запрет VPN/прокси, реальный потолок «безлимитного» трафика, политика по абузам."
  echo "- До обживания сервера — базовый hardening: вход по ключам, отключённый root-логин, файрвол."
  echo
  echo "Полный лог команд: raw.log в этой же папке."
} > "$REPORT_MD"

# --- HTML версия ---
STATUS_COLOR() {
  case "$1" in
    OK) echo "#1a7f37";;
    WARN) echo "#9a6700";;
    FAIL) echo "#cf222e";;
    *) echo "#6e7781";;
  esac
}

{
  echo "<!DOCTYPE html><html lang='ru'><head><meta charset='utf-8'>"
  echo "<meta name='viewport' content='width=device-width, initial-scale=1'>"
  echo "<title>Отчёт приёмки VPS</title><style>"
  echo "body{font-family:-apple-system,Segoe UI,Roboto,Arial,sans-serif;max-width:900px;margin:2rem auto;padding:0 1rem;line-height:1.5;color:#1f2328;background:#fff}"
  echo "h1{font-size:1.6rem} h2{font-size:1.2rem;margin-top:2rem;border-bottom:1px solid #d0d7de;padding-bottom:.3rem}"
  echo "table{border-collapse:collapse;width:100%;margin:1rem 0} th,td{border:1px solid #d0d7de;padding:.5rem .7rem;text-align:left;font-size:.92rem}"
  echo "th{background:#f6f8fa} .badge{display:inline-block;padding:.15rem .55rem;border-radius:999px;color:#fff;font-size:.8rem;font-weight:600}"
  echo ".verdict{padding:1rem;border-radius:8px;background:#f6f8fa;border:1px solid #d0d7de;font-size:1.05rem}"
  echo ".detail{margin-bottom:1.2rem} .meta{color:#57606a;font-size:.9rem}"
  echo "</style></head><body>"
  echo "<h1>Отчёт приёмки VPS</h1>"
  echo "<p class='meta'>Дата: $(date '+%Y-%m-%d %H:%M:%S %Z') &middot; Хост: $(hostname 2>/dev/null || echo unknown) &middot; IP: ${MY_IP:-неизвестен} &middot; CPU: ${CPU_MODEL:-неизвестен}</p>"
  echo "<div class='verdict'><b>Итог:</b> $VERDICT<br>OK: $OK_COUNT · WARN: $WARN_COUNT · FAIL: $FAIL_COUNT · SKIP: $SKIP_COUNT</div>"
  echo "<h2>Сводная таблица</h2><table><tr><th>Проверка</th><th>Статус</th><th>Значение</th></tr>"
  for k in "${ORDER[@]}"; do
    st="${STATUS[$k]:-SKIP}"
    color=$(STATUS_COLOR "$st")
    val="${VALUE[$k]:-—}"
    echo "<tr><td>${TITLES[$k]}</td><td><span class='badge' style='background:$color'>$st</span></td><td>$(echo "$val" | sed 's/&/\&amp;/g; s/</\&lt;/g')</td></tr>"
  done
  echo "</table>"
  echo "<h2>Детали по каждой проверке</h2>"
  for k in "${ORDER[@]}"; do
    st="${STATUS[$k]:-SKIP}"
    color=$(STATUS_COLOR "$st")
    echo "<div class='detail'><b>${TITLES[$k]}</b> <span class='badge' style='background:$color'>$st</span>"
    echo "<p><b>Значение:</b> $(echo "${VALUE[$k]:-—}" | sed 's/&/\&amp;/g; s/</\&lt;/g')<br>"
    echo "<b>Комментарий:</b> $(echo "${DETAIL[$k]:-—}" | sed 's/&/\&amp;/g; s/</\&lt;/g')</p></div>"
  done
  echo "<h2>Что сделать вручную</h2><ul>"
  echo "<li>Повторить проверки полосы и mtr днём и вечером в пиковые часы.</li>"
  echo "<li>Проверить check.spamhaus.org и mxtoolbox.com/blacklists.aspx вручную.</li>"
  echo "<li>Прогнать mtr в обе стороны (сервер→дом и дом→сервер).</li>"
  echo "<li>Перечитать ToS хостера (VPN/прокси, fair use, политика по абузам).</li>"
  echo "<li>Базовый hardening до обживания сервера: ключи вместо пароля, отключённый root-логин, файрвол.</li>"
  echo "</ul>"
  echo "</body></html>"
} > "$REPORT_HTML"

echo
echo "=================================================================="
echo " ИТОГ: $VERDICT"
echo " OK: $OK_COUNT · WARN: $WARN_COUNT · FAIL: $FAIL_COUNT · SKIP: $SKIP_COUNT"
echo
echo " Markdown-отчёт: $REPORT_MD"
echo " HTML-отчёт:     $REPORT_HTML"
echo " Полный лог:     $RAW_LOG"
echo "=================================================================="
