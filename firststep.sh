#!/usr/bin/env bash
#
# firststep.sh — первый шаг после выдачи VPS:
#   • добавляет публичный SSH-ключ
#   • позволяет удалить выбранный ключ
#   • отключает вход по паролю
# Можно запускать повторно: скрипт покажет уже добавленные ключи.
#
# Запуск: sudo bash firststep.sh
#
set -euo pipefail

# ---------- цвета ----------
if [[ -t 1 ]]; then
    RST=$'\e[0m'; BLD=$'\e[1m'; DIM=$'\e[2m'
    RED=$'\e[31m'; GRN=$'\e[32m'; YEL=$'\e[33m'; BLU=$'\e[34m'
    MAG=$'\e[35m'; CYN=$'\e[36m'; GRY=$'\e[90m'
else
    RST=""; BLD=""; DIM=""; RED=""; GRN=""; YEL=""; BLU=""; MAG=""; CYN=""; GRY=""
fi

hr()      { printf '%s%s%s\n' "$GRY" "$(printf '─%.0s' $(seq 1 60))" "$RST"; }
section() { echo; echo "${CYN}${BLD}▌ $*${RST}"; hr; }
ok()      { echo " ${GRN}✔${RST} $*"; }
info()    { echo " ${BLU}ℹ${RST} $*"; }
warn()    { echo " ${YEL}⚠${RST} $*"; }
err()     { echo " ${RED}✖${RST} $*" >&2; }
die()     { err "$*"; exit 1; }

# ---------- ввод ----------
# Сбрасываем всё, что осталось в буфере терминала (хвосты от вставки ключа)
flush_tty() {
    local junk
    while read -r -t 0.05 -n 1000 junk </dev/tty 2>/dev/null; do :; done
}

# Чистим строку: убираем \r, escape-последовательности вставки и пробелы по краям
clean_line() {
    printf '%s' "$1" | tr -d '\r' | sed -E \
        -e $'s/\x1b\\[[0-9;?]*[~A-Za-z]//g' \
        -e 's/^[[:space:]]+//' -e 's/[[:space:]]+$//'
}

# ask_yn "Вопрос" [y|n]  — без второго аргумента требует явный ответ
ask_yn() {
    local prompt="$1" def="${2:-}" hint ans
    case "$def" in y) hint="Y/n";; n) hint="y/N";; *) hint="y/n";; esac
    while true; do
        flush_tty
        printf ' %s?%s %s %s[%s]%s: ' "$YEL" "$RST" "$prompt" "$GRY" "$hint" "$RST"
        IFS= read -r ans </dev/tty || return 1
        ans="$(clean_line "$ans")"
        [[ -z "$ans" ]] && ans="$def"
        case "$ans" in
            [yYдД]|[yY][eE][sS]|[дД][аА]) return 0 ;;
            [nNнН]|[nN][oO]|[нН][еЕ][тТ]) return 1 ;;
        esac
        warn "Введите y или n."
    done
}

# ---------- ключи ----------
# load_keys файл — разбирает authorized_keys построчно и заполняет массивы:
#   KEY_LNUM — номер строки в файле (по нему удаляем)
#   KEY_FP / KEY_TYPE / KEY_COMMENT — отпечаток, тип, комментарий
# Комментарии, пустые и битые строки пропускаются и в нумерацию не попадают.
KEY_COUNT=0
KEY_LNUM=(); KEY_FP=(); KEY_TYPE=(); KEY_COMMENT=()

load_keys() {
    local f="$1" line out fp rest type comment tmp n=0
    KEY_COUNT=0; KEY_LNUM=(); KEY_FP=(); KEY_TYPE=(); KEY_COMMENT=()
    [[ -s "$f" ]] || return 0
    tmp="$(mktemp)"
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n+1))
        line="${line%$'\r'}"
        [[ -z "${line//[[:space:]]/}" ]] && continue
        [[ "$line" =~ ^[[:space:]]*# ]] && continue
        printf '%s\n' "$line" > "$tmp"
        out="$(ssh-keygen -l -f "$tmp" 2>/dev/null | head -n1 || true)"
        [[ -n "$out" ]] || continue
        read -r _ fp rest <<<"$out"
        type="${rest##* }"; type="${type//[()]/}"
        if [[ "$rest" == *" "* ]]; then comment="${rest% *}"; else comment=""; fi
        KEY_LNUM+=("$n"); KEY_FP+=("$fp"); KEY_TYPE+=("$type"); KEY_COMMENT+=("$comment")
    done < "$f"
    rm -f "$tmp"
    KEY_COUNT=${#KEY_FP[@]}
}

print_keys() {
    local i
    [[ $KEY_COUNT -gt 0 ]] || return 0
    for ((i=0; i<KEY_COUNT; i++)); do
        printf ' %s%d)%s %s%-8s%s %s%s%s  %s\n' \
            "$GRN" "$((i+1))" "$RST" "$BLD" "${KEY_TYPE[$i]}" "$RST" \
            "$GRY" "${KEY_FP[$i]}" "$RST" "${KEY_COMMENT[$i]}"
    done
}

key_exists() {
    local i
    for ((i=0; i<KEY_COUNT; i++)); do
        [[ "${KEY_FP[$i]}" == "$1" ]] && return 0
    done
    return 1
}

pw_state() { { sshd -T 2>/dev/null || true; } | awk '/^passwordauthentication /{print $2}'; }

# add_key — запрашивает и добавляет публичный ключ (использует $target_user, $auth_file и т.д.)
add_key() {
    local pubkey tmp new_fp
    section "Новый ключ"
    echo " Вставьте публичный ключ одной строкой ${GRY}(ssh-ed25519 AAAA... / ssh-rsa AAAA...)${RST}"
    printf ' %s>%s ' "$CYN" "$RST"
    IFS= read -r pubkey </dev/tty
    pubkey="$(clean_line "${pubkey:-}")"

    if [[ -z "$pubkey" ]]; then
        warn "Пустой ввод. Ничего не изменено."; return 1
    fi
    if [[ "$pubkey" == -----BEGIN* ]]; then
        err "Это приватный ключ! Нужен публичный (файл .pub). Ничего не изменено."; return 1
    fi

    tmp="$(mktemp)"
    echo "$pubkey" > "$tmp"
    if ! ssh-keygen -l -f "$tmp" &>/dev/null; then
        rm -f "$tmp"
        err "Это не похоже на корректный публичный SSH-ключ. Ничего не изменено."; return 1
    fi
    new_fp="$(ssh-keygen -l -f "$tmp" | awk '{print $2}')"
    ok "Ключ распознан: ${GRY}$(ssh-keygen -l -f "$tmp")${RST}"
    rm -f "$tmp"

    load_keys "$auth_file"
    if key_exists "$new_fp"; then
        info "Такой ключ уже добавлен, пропускаю."
        return 0
    fi

    install -d -m 700 -o "$target_user" -g "$group" "$ssh_dir"
    chmod 700 "$ssh_dir"
    touch "$auth_file"
    # гарантируем перевод строки в конце файла перед добавлением
    if [[ -s "$auth_file" && -n "$(tail -c1 "$auth_file")" ]]; then echo >> "$auth_file"; fi
    echo "$pubkey" >> "$auth_file"
    chown "$target_user:$group" "$auth_file"
    chmod 600 "$auth_file"
    command -v restorecon &>/dev/null && restorecon -R "$ssh_dir" || true
    ok "Ключ добавлен в $auth_file"
    return 0
}

# delete_key — показывает ключи, удаляет выбранный (по номеру строки в файле)
delete_key() {
    local sel idx fp n tmp backup i
    load_keys "$auth_file"
    if [[ $KEY_COUNT -eq 0 ]]; then
        warn "Удалять нечего: ключей нет."
        return 0
    fi

    section "Удаление ключа"
    print_keys
    echo
    flush_tty
    printf ' Номер ключа для удаления %s[Enter — отмена]%s: ' "$GRY" "$RST"
    IFS= read -r sel </dev/tty || return 0
    sel="$(clean_line "${sel:-}")"
    if [[ -z "$sel" ]]; then info "Отменено."; return 0; fi
    if ! [[ "$sel" =~ ^[0-9]+$ ]] || (( 10#$sel < 1 || 10#$sel > KEY_COUNT )); then
        warn "Нет ключа с номером «$sel»."
        return 0
    fi
    idx=$((10#$sel - 1))
    fp="${KEY_FP[$idx]}"
    n="${KEY_LNUM[$idx]}"

    # защита от потери доступа
    if [[ $KEY_COUNT -eq 1 ]]; then
        if [[ "$(pw_state)" == "no" ]]; then
            err "Это последний ключ, а вход по паролю отключён: после удаления доступ к серверу будет потерян."
            err "Сначала добавьте другой ключ. Ничего не изменено."
            return 0
        fi
        warn "Это ${BLD}последний${RST} ключ пользователя $target_user."
    fi

    echo
    echo " Будет удалён: ${BLD}${KEY_TYPE[$idx]}${RST} ${GRY}$fp${RST} ${KEY_COMMENT[$idx]}"
    warn "Новые входы по этому ключу станут невозможны (уже открытые сессии не закроются)."
    if ! ask_yn "Удалить этот ключ?" n; then
        info "Отменено."
        return 0
    fi

    # убеждаемся, что на этой строке всё ещё тот же ключ (файл могли изменить)
    tmp="$(mktemp)"
    sed -n "${n}p" "$auth_file" > "$tmp"
    if [[ "$(ssh-keygen -l -f "$tmp" 2>/dev/null | awk '{print $2}')" != "$fp" ]]; then
        rm -f "$tmp"
        err "Файл $auth_file изменился, пока вы выбирали. Ничего не удалено, повторите."
        return 0
    fi

    backup="/root/authorized_keys.${target_user}.backup.$(date +%Y%m%d-%H%M%S)"
    cp -a "$auth_file" "$backup"
    chmod 600 "$backup"

    awk -v n="$n" 'NR != n' "$auth_file" > "$tmp"
    cat "$tmp" > "$auth_file"   # перезаписываем содержимое: владелец, права и SELinux-контекст сохраняются
    rm -f "$tmp"
    ok "Ключ удалён. Резервная копия: $backup"

    load_keys "$auth_file"
    for ((i=0; i<KEY_COUNT; i++)); do
        if [[ "${KEY_FP[$i]}" == "$fp" ]]; then
            warn "Этот же ключ есть в файле в другой строке (№$((i+1))) и продолжает работать. Удалите и её."
        fi
    done
    return 0
}

# =====================================================================
[[ $EUID -eq 0 ]] || die "Запустите от root или через sudo."

echo "${MAG}${BLD}"
echo "  ╔════════════════════════════════════════════╗"
echo "  ║   FIRSTSTEP — SSH-ключ и защита сервера    ║"
echo "  ╚════════════════════════════════════════════╝"
echo "${RST}"

# --- 1. Пользователь ---
section "Пользователь"
default_user="${SUDO_USER:-root}"
printf ' Для какого пользователя управлять ключами? %s[%s]%s: ' "$GRY" "$default_user" "$RST"
IFS= read -r target_user </dev/tty
target_user="$(clean_line "${target_user:-}")"
target_user="${target_user:-$default_user}"
id "$target_user" &>/dev/null || die "Пользователь '$target_user' не найден."
group="$(id -gn "$target_user")"
home_dir="$(getent passwd "$target_user" | cut -d: -f6)"
ssh_dir="$home_dir/.ssh"
auth_file="$ssh_dir/authorized_keys"
ok "Пользователь: ${BLD}$target_user${RST} (${home_dir})"

# --- 2. Текущее состояние ---
section "Текущее состояние"
pw_before="$(pw_state)"
case "$pw_before" in
    no)  ok   "Вход по паролю: ${BLD}отключён${RST}" ;;
    yes) warn "Вход по паролю: ${BLD}включён${RST}" ;;
    *)   info "Вход по паролю: не удалось определить" ;;
esac

# --- 3. Управление ключами ---
echo
echo " ${BLD}Ключи в $auth_file:${RST}"
load_keys "$auth_file"
if [[ $KEY_COUNT -eq 0 ]]; then
    info "Ключей пока нет."
    add_key || true
else
    print_keys
    while true; do
        echo
        echo " ${BLD}Действие:${RST}"
        echo "   ${GRN}1)${RST} Продолжить без изменений"
        echo "   ${GRN}2)${RST} Добавить ключ"
        echo "   ${GRN}3)${RST} Удалить ключ"
        flush_tty
        printf ' Выбор %s[1]%s: ' "$GRY" "$RST"
        IFS= read -r choice </dev/tty || break
        choice="$(clean_line "${choice:-}")"
        case "${choice:-1}" in
            1) break ;;
            2) add_key || true ;;
            3) delete_key || true ;;
            *) warn "Введите 1, 2 или 3."; continue ;;
        esac
        load_keys "$auth_file"
        echo
        echo " ${BLD}Ключи в $auth_file:${RST}"
        if [[ $KEY_COUNT -eq 0 ]]; then info "Ключей не осталось."; else print_keys; fi
    done
fi

# --- 4. Вход по паролю ---
section "Вход по паролю"
load_keys "$auth_file"
[[ $KEY_COUNT -gt 0 ]] || die "У '$target_user' нет ни одного ключа: отключать пароль нельзя, потеряете доступ."

if [[ "$pw_before" == "no" ]]; then
    ok "Вход по паролю уже отключён, менять нечего."
    echo; ok "${BLD}Всё в порядке.${RST} Ключей у $target_user: $KEY_COUNT"
    exit 0
fi

echo " ${YEL}${BLD}ВНИМАНИЕ:${RST} после этого вход по паролю будет отключён."
echo " Убедитесь, что у вас есть приватная часть ключа."
echo
if ! ask_yn "Отключить вход по паролю?"; then
    warn "Пароли оставлены включёнными (вы выбрали «нет»)."
    exit 0
fi

conf_main="/etc/ssh/sshd_config"
conf_dir="/etc/ssh/sshd_config.d"
drop_in="$conf_dir/00-disable-password-auth.conf"
backup="/root/sshd_config.backup.$(date +%Y%m%d-%H%M%S)"

cp -a "$conf_main" "$backup"
[[ -d "$conf_dir" ]] && cp -a "$conf_dir" "$backup.d"
ok "Резервная копия: $backup"

mkdir -p "$conf_dir"
cat > "$drop_in" <<'CONF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
CONF

# Если основной конфиг не подключает sshd_config.d — добавляем Include в начало
if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' "$conf_main"; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$conf_main"
fi

if ! sshd -t; then
    err "Ошибка в конфигурации sshd, откатываю изменения."
    rm -f "$drop_in"
    cp -a "$backup" "$conf_main"
    exit 1
fi

# Проверяем, что "no" реально действует (cloud-init и др. могут перебивать)
effective="$(pw_state)"
if [[ "$effective" != "no" ]]; then
    warn "Другой конфиг переопределяет настройку, правлю его..."
    { grep -rlE '^\s*PasswordAuthentication\s+yes' "$conf_main" "$conf_dir" 2>/dev/null || true; } \
        | xargs -r sed -i -E 's/^(\s*)PasswordAuthentication\s+yes/\1PasswordAuthentication no/I'
    sshd -t
    effective="$(pw_state)"
fi
[[ "$effective" == "no" ]] || die "Не удалось отключить PasswordAuthentication, проверьте конфиги вручную."

systemctl reload ssh 2>/dev/null || systemctl reload sshd
ok "Вход по паролю ${BLD}отключён${RST}, sshd перезагружен."

# --- Итог ---
section "Готово"
echo " ${YEL}${BLD}НЕ закрывайте текущую сессию!${RST}"
echo " Откройте новый терминал и проверьте вход по ключу:"
echo
echo "   ${CYN}ssh -i /путь/к/приватному_ключу $target_user@<адрес_сервера>${RST}"
echo
echo " ${GRY}Откат: cp -a $backup $conf_main && rm $drop_in && systemctl reload ssh${RST}"
echo
