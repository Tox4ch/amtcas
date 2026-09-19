#!/usr/bin/env bash
#
# vps-check.sh — приёмка нового VPS за первый час (12 проверок)
# Весь вывод — только в терминал, никаких файлов на диске.
#
# Запуск: sudo bash vps-check.sh [--home-ip 1.2.3.4] [--skip-fio] [--skip-speed] [--fio-runtime 15]
#
set -uo pipefail

# ---------- цвета ----------
if [[ -t 1 ]]; then
  C_RESET=$'\e[0m'; C_BOLD=$'\e[1m'; C_DIM=$'\e[2m'
  C_RED=$'\e[31m'; C_GREEN=$'\e[32m'; C_YELLOW=$'\e[33m'
  C_BLUE=$'\e[34m'; C_MAGENTA=$'\e[35m'; C_CYAN=$'\e[36m'; C_GRAY=$'\e[90m'
  BG_RED=$'\e[41m'; BG_GREEN=$'\e[42m'; BG_YELLOW=$'\e[43m'; BG_GRAY=$'\e[100m'
else
  C_RESET=""; C_BOLD=""; C_DIM=""; C_RED=""; C_GREEN=""; C_YELLOW=""
  C_BLUE=""; C_MAGENTA=""; C_CYAN=""; C_GRAY=""; BG_RED=""; BG_GREEN=""; BG_YELLOW=""; BG_GRAY=""
fi

badge() {
  local st="$1"
  case "$st" in
    OK)   echo "${BG_GREEN}${C_BOLD} OK ${C_RESET}";;
    WARN) echo "${BG_YELLOW}${C_BOLD} WARN ${C_RESET}";;
    FAIL) echo "${BG_RED}${C_BOLD} FAIL ${C_RESET}";;
    *)    echo "${BG_GRAY}${C_BOLD} SKIP ${C_RESET}";;
  esac
}

hr()      { echo "${C_GRAY}$(printf '─%.0s' $(seq 1 70))${C_RESET}"; }
section() { echo; echo "${C_CYAN}${C_BOLD}▌ $*${C_RESET}"; hr; }
step()    { echo "${C_BLUE}➤${C_RESET} $*"; }
note()    { echo "  ${C_DIM}$*${C_RESET}"; }

# ---------- параметры ----------
HOME_IP=""
SKIP_FIO=0
SKIP_SPEED=0
FIO_RUNTIME=15

while [[ $# -gt 0 ]]; do
  case "$1" in
    --home-ip) HOME_IP="$2"; shift 2 ;;
    --skip-fio) SKIP_FIO=1; shift ;;
    --skip-speed) SKIP_SPEED=1; shift ;;
    --fio-runtime) FIO_RUNTIME="$2"; shift 2 ;;
    -h|--help)
      echo "Usage: $0 [--home-ip IP] [--skip-fio] [--skip-speed] [--fio-runtime SEC]"
      exit 0 ;;
    *) echo "Неизвестный аргумент: $1"; exit 1 ;;
  esac
done

have() { command -v "$1" >/dev/null 2>&1; }

declare -A STATUS
declare -A DETAIL
declare -A VALUE

set_result() {
  local key="$1" status="$2" value="$3" detail="$4"
  STATUS["$key"]="$status"; VALUE["$key"]="$value"; DETAIL["$key"]="$detail"
  echo "  $(badge "$status")  ${C_BOLD}${value}${C_RESET}"
  [[ -n "$detail" ]] && note "$detail"
}

install_if_missing() {
  local pkg="$1" bin="${2:-$1}"
  if ! have "$bin"; then
    if have apt-get; then
      apt-get update -qq >/dev/null 2>&1
      apt-get install -y -qq "$pkg" >/dev/null 2>&1
    elif have yum; then
      yum install -y -q "$pkg" >/dev/null 2>&1
    elif have apk; then
      apk add --quiet "$pkg" >/dev/null 2>&1
    fi
  fi
}

clear 2>/dev/null || true
echo "${C_MAGENTA}${C_BOLD}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║        ПРИЁМКА VPS — 12 ПРОВЕРОК ПЕРВОГО ЧАСА             ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo "${C_RESET}"
[[ $EUID -ne 0 ]] && echo "${C_YELLOW}⚠ Не запущено от root — часть проверок может быть неполной.${C_RESET}"

# =========================================================
# ЭТАП 1: ЖЕЛЕЗО
# =========================================================
section "ЖЕЛЕЗО"

step "1/12 Тип виртуализации"
VIRT="unknown"
have systemd-detect-virt && VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
case "$VIRT" in
  kvm)   set_result "virt" "OK" "KVM" "Полноценная виртуализация: своё ядро, WireGuard, Docker без оговорок." ;;
  openvz|lxc|lxc-libvirt)
         set_result "virt" "WARN" "$VIRT" "Контейнерная виртуализация на чужом ядре: часть модулей может быть недоступна." ;;
  none)  set_result "virt" "OK" "bare-metal / none" "Виртуализация не обнаружена." ;;
  *)     set_result "virt" "WARN" "$VIRT" "Не KVM — проверьте ограничения хостера вручную." ;;
esac

step "2/12 CPU и steal time (5 сек)"
CPU_MODEL=$(lscpu 2>/dev/null | grep -m1 "Model name" | sed 's/Model name:\s*//')
VMSTAT_OUT=$(vmstat 1 5 2>/dev/null)
STEAL_AVG=$(echo "$VMSTAT_OUT" | tail -n +3 | awk '{sum+=$NF; n++} END {if (n>0) printf "%.1f", sum/n; else print "NA"}')
if [[ "$STEAL_AVG" == "NA" ]]; then
  set_result "cpu_steal" "WARN" "не удалось измерить" "vmstat не вернул данных."
elif (( $(echo "$STEAL_AVG <= 2" | bc -l 2>/dev/null || echo 1) )); then
  set_result "cpu_steal" "OK" "${STEAL_AVG}% steal" "${CPU_MODEL:-CPU неизвестен}. Нода не перегружена."
elif (( $(echo "$STEAL_AVG <= 5" | bc -l 2>/dev/null || echo 0) )); then
  set_result "cpu_steal" "WARN" "${STEAL_AVG}% steal" "Заметное отъедание CPU соседями по ноде."
else
  set_result "cpu_steal" "FAIL" "${STEAL_AVG}% steal" "Нода перегружена — просадки в пиковые часы. Тариф это не лечит."
fi

step "3/12 Память и OOM"
MEM_TOTAL=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}')
SWAP_TOTAL=$(free -h 2>/dev/null | awk '/^Swap:/{print $2}')
OOM_HITS=$(dmesg 2>/dev/null | grep -c -i -E "oom|killed process" || true)
if [[ "$OOM_HITS" -gt 0 ]]; then
  set_result "memory" "WARN" "${MEM_TOTAL} RAM, swap=${SWAP_TOTAL}, OOM: $OOM_HITS" "Обнаружены OOM-килы на свежем сервере — плохой знак."
else
  set_result "memory" "OK" "${MEM_TOTAL} RAM, swap=${SWAP_TOTAL}" "OOM-килов не обнаружено. Сверьте объём RAM с тарифом вручную."
fi

step "4/12 Диск (fio randread/randwrite 4k)"
if [[ "$SKIP_FIO" -eq 1 ]]; then
  set_result "disk_fio" "SKIP" "пропущено" "Отключено флагом --skip-fio."
else
  install_if_missing fio
  if ! have fio; then
    set_result "disk_fio" "SKIP" "fio недоступен" "Не удалось установить fio."
  else
    FIO_DIR=$(mktemp -d)
    FIO_READ=$(fio --name=t --directory="$FIO_DIR" --filename=test.fio --size=512M \
      --direct=1 --rw=randread --bs=4k --iodepth=64 --runtime="$FIO_RUNTIME" --time_based --group_reporting 2>/dev/null)
    READ_IOPS=$(echo "$FIO_READ" | grep -Eo 'IOPS=[0-9.]+[kK]?' | head -1 | grep -Eo '[0-9.]+[kK]?')
    FIO_WRITE=$(fio --name=t --directory="$FIO_DIR" --filename=test.fio --size=512M \
      --direct=1 --rw=randwrite --bs=4k --iodepth=64 --runtime="$FIO_RUNTIME" --time_based --group_reporting 2>/dev/null)
    WRITE_IOPS=$(echo "$FIO_WRITE" | grep -Eo 'IOPS=[0-9.]+[kK]?' | head -1 | grep -Eo '[0-9.]+[kK]?')
    rm -rf "$FIO_DIR"
    to_num() { local v="$1"; if [[ "$v" == *k || "$v" == *K ]]; then echo "${v%[kK]}" | awk '{print $1*1000}'; else echo "$v"; fi; }
    READ_NUM=$(to_num "${READ_IOPS:-0}"); WRITE_NUM=$(to_num "${WRITE_IOPS:-0}")
    MIN_IOPS=$(awk -v a="$READ_NUM" -v b="$WRITE_NUM" 'BEGIN{print (a<b)?a:b}')
    if (( $(echo "$MIN_IOPS >= 15000" | bc -l 2>/dev/null || echo 0) )); then
      set_result "disk_fio" "OK" "read=${READ_IOPS:-?} write=${WRITE_IOPS:-?} IOPS" "Похоже на настоящий NVMe."
    elif (( $(echo "$MIN_IOPS >= 5000" | bc -l 2>/dev/null || echo 0) )); then
      set_result "disk_fio" "WARN" "read=${READ_IOPS:-?} write=${WRITE_IOPS:-?} IOPS" "Уровень SATA SSD — сверьте с тарифом."
    else
      set_result "disk_fio" "FAIL" "read=${READ_IOPS:-?} write=${WRITE_IOPS:-?} IOPS" "Похоже на HDD или сильно зарезанный диск."
    fi
  fi
fi

# =========================================================
# ЭТАП 2: СЕТЬ
# =========================================================
section "СЕТЬ"

step "5/12 Пропускная способность"
if [[ "$SKIP_SPEED" -eq 1 ]]; then
  set_result "bandwidth" "SKIP" "пропущено" "Отключено флагом --skip-speed."
else
  install_if_missing speedtest-cli
  if have speedtest-cli; then
    SPEED_OUT=$(timeout 90 speedtest-cli --simple 2>/dev/null)
    DL=$(echo "$SPEED_OUT" | awk '/Download/{print $2, $3}')
    UL=$(echo "$SPEED_OUT" | awk '/Upload/{print $2, $3}')
    PING=$(echo "$SPEED_OUT" | awk '/Ping/{print $2, $3}')
    if [[ -n "$DL" ]]; then
      set_result "bandwidth" "OK" "↓ ${DL:-?}  ↑ ${UL:-?}  ping ${PING:-?}" "Разовый замер — повторите вечером в пиковые часы для полной картины."
    else
      set_result "bandwidth" "WARN" "не удалось измерить" "speedtest-cli не вернул результат."
    fi
  else
    set_result "bandwidth" "SKIP" "speedtest-cli недоступен" "Не удалось установить."
  fi
fi

step "6/12 Маршруты и задержки (mtr)"
MTR_TARGET="${HOME_IP:-1.1.1.1}"
install_if_missing mtr-tiny mtr
if have mtr; then
  MTR_OUT=$(mtr -rwbzc 20 "$MTR_TARGET" 2>/dev/null)
  LAST_LOSS=$(echo "$MTR_OUT" | tail -n1 | awk '{print $3}')
  LAST_AVG=$(echo "$MTR_OUT" | tail -n1 | awk '{print $6}')
  if [[ -z "$HOME_IP" ]]; then
    set_result "mtr" "WARN" "до 1.1.1.1: потери ${LAST_LOSS:-?}, avg ${LAST_AVG:-?}мс" "Домашний IP не указан (--home-ip). Прогоните mtr и в обратную сторону."
  else
    set_result "mtr" "OK" "до $MTR_TARGET: потери ${LAST_LOSS:-?}, avg ${LAST_AVG:-?}мс" "Проверьте и обратное направление — маршруты бывают несимметричными."
  fi
else
  set_result "mtr" "SKIP" "mtr недоступен" "Не удалось установить mtr-tiny."
fi

step "7/12 MTU / фрагментация"
if ping -M do -s 1472 -c 2 8.8.8.8 >/dev/null 2>&1; then
  set_result "mtu" "OK" "1500 байт проходит" "Полноразмерные пакеты не фрагментируются."
else
  set_result "mtu" "WARN" "1500 байт НЕ проходит" "Где-то по пути туннель с уменьшенным MTU — источник багов, особенно поверх WireGuard."
fi

step "8/12 IPv6"
IPV6_ADDR=$(timeout 5 curl -6 -s ifconfig.co 2>/dev/null)
if [[ -n "$IPV6_ADDR" ]] && timeout 5 ping -6 -c3 2001:4860:4860::8888 >/dev/null 2>&1; then
  set_result "ipv6" "OK" "$IPV6_ADDR" "IPv6 работает и ходит наружу."
else
  set_result "ipv6" "WARN" "недоступен" "Не настроен или не маршрутизируется. Некритично, если не нужен."
fi

# =========================================================
# ЭТАП 3: РЕПУТАЦИЯ IP
# =========================================================
section "РЕПУТАЦИЯ IP"

MY_IP=$(timeout 5 curl -s ifconfig.me 2>/dev/null)

step "9/12 Чёрные списки (DNSBL)"
if [[ -z "$MY_IP" ]]; then
  set_result "blacklist" "SKIP" "не удалось определить IP" ""
else
  REV_IP=$(echo "$MY_IP" | awk -F. '{print $4"."$3"."$2"."$1}')
  BL_HITS=0; BL_LIST=""
  for zone in zen.spamhaus.org bl.spamcop.net b.barracudacentral.org; do
    RES=""
    if have dig; then RES=$(dig +short "${REV_IP}.${zone}" 2>/dev/null)
    elif have host; then RES=$(host "${REV_IP}.${zone}" 2>/dev/null | grep "has address" || true); fi
    [[ -n "$RES" ]] && { BL_HITS=$((BL_HITS+1)); BL_LIST="$BL_LIST $zone"; }
  done
  if [[ "$BL_HITS" -eq 0 ]]; then
    set_result "blacklist" "OK" "$MY_IP — чист по basic DNSBL" "Дополнительно проверьте check.spamhaus.org и mxtoolbox.com/blacklists.aspx вручную."
  else
    set_result "blacklist" "FAIL" "$MY_IP в списках:$BL_LIST" "IP уже засвечен — просите замену у хостера или возврат денег."
  fi
fi

step "10/12 rDNS и порт 25"
if [[ -z "$MY_IP" ]]; then
  set_result "rdns" "SKIP" "не удалось определить IP" ""
else
  PTR=$(dig -x "$MY_IP" +short 2>/dev/null)
  PORT25="закрыт"
  timeout 5 bash -c "cat < /dev/null > /dev/tcp/smtp.gmail.com/25" 2>/dev/null && PORT25="открыт"
  if echo "$PTR" | grep -qiE "spam|relay|abuse|blacklist"; then
    set_result "rdns" "WARN" "PTR: ${PTR:-нет записи}, порт 25: $PORT25" "PTR-запись намекает на подозрительную историю адреса."
  else
    set_result "rdns" "OK" "PTR: ${PTR:-нет записи}, порт 25: $PORT25" "Порт 25 закрыт — нормально; для своего почтового сервера уточните политику у хостера."
  fi
fi

step "11/12 Репутация IP у сервисов"
if [[ -z "$MY_IP" ]]; then
  set_result "ip_reputation" "SKIP" "не удалось определить IP" ""
else
  IPINFO=$(timeout 5 curl -s "https://ipinfo.io/${MY_IP}/json" 2>/dev/null)
  ORG=$(echo "$IPINFO" | grep -o '"org": *"[^"]*"' | cut -d'"' -f4)
  COUNTRY=$(echo "$IPINFO" | grep -o '"country": *"[^"]*"' | cut -d'"' -f4)
  set_result "ip_reputation" "WARN" "org: ${ORG:-?}, country: ${COUNTRY:-?}" "Проверьте вручную, не помечен ли диапазон как hosting/proxy/VPN."
fi

# =========================================================
# ЭТАП 4: ПРИГОДНОСТЬ ПОД ЗАДАЧИ
# =========================================================
section "ПРИГОДНОСТЬ ПОД ЗАДАЧИ"

step "12/12 TUN / Docker / nested-виртуализация"
TUN_OK="нет"; [[ -e /dev/net/tun ]] && TUN_OK="да"
NESTED_FLAGS=$(grep -cE "vmx|svm" /proc/cpuinfo 2>/dev/null || echo 0)
DOCKER_OK="не установлен"
if have docker; then
  if timeout 30 docker run --rm hello-world >/dev/null 2>&1; then DOCKER_OK="работает"
  else DOCKER_OK="установлен, hello-world не прошёл"; fi
fi
DETAIL_12="nested-виртуализация флагов: $NESTED_FLAGS; Docker: $DOCKER_OK"
if [[ "$TUN_OK" == "да" ]]; then
  set_result "tun_docker" "OK" "TUN: да" "$DETAIL_12 — WireGuard/OpenVPN/sing-box заработают."
else
  set_result "tun_docker" "WARN" "TUN: нет" "$DETAIL_12 — без /dev/net/tun не поднимутся WireGuard/OpenVPN в TUN-режиме."
fi

# =========================================================
# ИТОГ
# =========================================================
ORDER=(virt cpu_steal memory disk_fio bandwidth mtr mtu ipv6 blacklist rdns ip_reputation tun_docker)
declare -A TITLES=(
  [virt]="Виртуализация" [cpu_steal]="CPU / steal time" [memory]="Память / OOM"
  [disk_fio]="Диск (fio)" [bandwidth]="Полоса сети" [mtr]="Маршруты (mtr)"
  [mtu]="MTU" [ipv6]="IPv6" [blacklist]="Чёрные списки" [rdns]="rDNS / порт 25"
  [ip_reputation]="Репутация IP" [tun_docker]="TUN / Docker"
)

OK_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; SKIP_COUNT=0
for k in "${ORDER[@]}"; do
  case "${STATUS[$k]:-SKIP}" in
    OK) OK_COUNT=$((OK_COUNT+1));; WARN) WARN_COUNT=$((WARN_COUNT+1));;
    FAIL) FAIL_COUNT=$((FAIL_COUNT+1));; *) SKIP_COUNT=$((SKIP_COUNT+1));;
  esac
done

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  VERDICT_COLOR="$C_RED"; VERDICT="ВОЗВРАТ / ЗАМЕНА — есть критичные проблемы"
elif [[ "$WARN_COUNT" -ge 3 ]]; then
  VERDICT_COLOR="$C_YELLOW"; VERDICT="ПОД ВОПРОСОМ — много замечаний, уточните у хостера"
else
  VERDICT_COLOR="$C_GREEN"; VERDICT="МОЖНО ОБЖИВАТЬ — критичных проблем не найдено"
fi

echo
echo "${C_MAGENTA}${C_BOLD}"
echo "  ╔══════════════════════════════════════════════════════════╗"
echo "  ║                    СВОДНЫЙ ОТЧЁТ                          ║"
echo "  ╚══════════════════════════════════════════════════════════╝"
echo "${C_RESET}"
printf "  %-24s%s\n" "IP:" "${MY_IP:-неизвестен}"
printf "  %-24s%s\n" "CPU:" "${CPU_MODEL:-неизвестен}"
printf "  %-24s%s\n" "Хост:" "$(hostname 2>/dev/null || echo unknown)"
printf "  %-24s%s\n" "Дата:" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
echo
hr
for k in "${ORDER[@]}"; do
  printf "  %-24s%s  %s\n" "${TITLES[$k]}" "$(badge "${STATUS[$k]:-SKIP}")" "${VALUE[$k]:-—}"
done
hr
echo "  ${C_GREEN}OK: $OK_COUNT${C_RESET}   ${C_YELLOW}WARN: $WARN_COUNT${C_RESET}   ${C_RED}FAIL: $FAIL_COUNT${C_RESET}   ${C_GRAY}SKIP: $SKIP_COUNT${C_RESET}"
echo
echo "  ${C_BOLD}${VERDICT_COLOR}➤ ИТОГ: $VERDICT${C_RESET}"
echo
echo "${C_DIM}  Вручную стоит дополнительно проверить: повторный замер скорости/mtr"
echo "  в другое время суток, check.spamhaus.org, mxtoolbox.com/blacklists.aspx,"
echo "  обратный mtr (с домашней машины до сервера), ToS хостера.${C_RESET}"
echo
