#!/usr/bin/env bash
#
# firststep.sh — первый шаг после выдачи VPS:
#   • добавляет публичный SSH-ключ
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
KEY_COUNT=0
list_keys() {
    local f="$1" out line bits fp rest type comment i=0
    KEY_COUNT=0
    [[ -s "$f" ]] || return 0
    out="$(ssh-keygen -l -f "$f" 2>/dev/null || true)"
    [[ -n "$out" ]] || return 0
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        i=$((i+1))
        read -r bits fp rest <<<"$line"
        type="${rest##* }"; type="${type//[()]/}"
        if [[ "$rest" == *" "* ]]; then comment="${rest% *}"; else comment=""; fi
        printf ' %s%d)%s %s%-8s%s %s%s%s  %s\n' \
            "$GRN" "$i" "$RST" "$BLD" "$type" "$RST" "$GRY" "$fp" "$RST" "$comment"
    done <<<"$out"
    KEY_COUNT=$i
}

pw_state() { { sshd -T 2>/dev/null || true; } | awk '/^passwordauthentication /{print $2}'; }

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
printf ' Для какого пользователя добавить ключ? %s[%s]%s: ' "$GRY" "$default_user" "$RST"
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

echo
echo " ${BLD}Ключи в $auth_file:${RST}"
list_keys "$auth_file"
if [[ $KEY_COUNT -eq 0 ]]; then
    info "Ключей пока нет."
    add_key=1
else
    echo
    if ask_yn "Добавить ещё один ключ?" n; then add_key=1; else add_key=0; fi
fi

# --- 3. Добавление ключа ---
if [[ $add_key -eq 1 ]]; then
    section "Новый ключ"
    echo " Вставьте публичный ключ одной строкой ${GRY}(ssh-ed25519 AAAA... / ssh-rsa AAAA...)${RST}"
    printf ' %s>%s ' "$CYN" "$RST"
    IFS= read -r pubkey </dev/tty
    pubkey="$(clean_line "${pubkey:-}")"

    [[ -n "$pubkey" ]] || die "Пустой ввод. Ничего не изменено."
    [[ "$pubkey" == -----BEGIN* ]] && die "Это приватный ключ! Нужен публичный (файл .pub). Ничего не изменено."

    tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
    echo "$pubkey" > "$tmp"
    ssh-keygen -l -f "$tmp" &>/dev/null || die "Это не похоже на корректный публичный SSH-ключ. Ничего не изменено."
    new_fp="$(ssh-keygen -l -f "$tmp" | awk '{print $2}')"
    ok "Ключ распознан: ${GRY}$(ssh-keygen -l -f "$tmp")${RST}"

    existing_fps=""
    [[ -s "$auth_file" ]] && existing_fps="$(ssh-keygen -l -f "$auth_file" 2>/dev/null | awk '{print $2}' || true)"

    if grep -qxF "$new_fp" <<<"$existing_fps"; then
        info "Такой ключ уже добавлен, пропускаю."
    else
        install -d -m 700 -o "$target_user" -g "$group" "$ssh_dir"
        chmod 700 "$ssh_dir"
        touch "$auth_file"
        # гарантируем перевод строки в конце файла перед добавлением
        [[ -s "$auth_file" && -n "$(tail -c1 "$auth_file")" ]] && echo >> "$auth_file"
        echo "$pubkey" >> "$auth_file"
        chown "$target_user:$group" "$auth_file"
        chmod 600 "$auth_file"
        command -v restorecon &>/dev/null && restorecon -R "$ssh_dir" || true
        ok "Ключ добавлен в $auth_file"
    fi
fi

# --- 4. Вход по паролю ---
section "Вход по паролю"
list_keys "$auth_file" >/dev/null
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
