#!/usr/bin/env bash
# Добавляет публичный SSH-ключ пользователю и отключает вход по паролю.
# Запуск: sudo bash setup-ssh-key.sh
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "Запустите от root или через sudo."; exit 1; }

# --- Целевой пользователь ---
default_user="${SUDO_USER:-root}"
read -r -p "Для какого пользователя добавить ключ? [$default_user]: " target_user </dev/tty
target_user="${target_user:-$default_user}"
id "$target_user" &>/dev/null || { echo "Пользователь '$target_user' не найден."; exit 1; }
home_dir="$(getent passwd "$target_user" | cut -d: -f6)"

# --- Ввод и проверка ключа ---
echo "Вставьте публичный ключ одной строкой (ssh-ed25519 AAAA... / ssh-rsa AAAA...):"
read -r pubkey </dev/tty
pubkey="$(echo "$pubkey" | xargs)"   # обрезаем пробелы

tmp="$(mktemp)"; trap 'rm -f "$tmp"' EXIT
echo "$pubkey" > "$tmp"
if ! ssh-keygen -l -f "$tmp" &>/dev/null; then
    echo "Это не похоже на корректный публичный SSH-ключ. Прерываю, ничего не изменено."
    exit 1
fi
echo "Ключ распознан: $(ssh-keygen -l -f "$tmp")"

# --- Установка ключа ---
ssh_dir="$home_dir/.ssh"
auth_file="$ssh_dir/authorized_keys"
install -d -m 700 -o "$target_user" -g "$(id -gn "$target_user")" "$ssh_dir"
touch "$auth_file"
if grep -qxF "$pubkey" "$auth_file"; then
    echo "Такой ключ уже есть в $auth_file."
else
    echo "$pubkey" >> "$auth_file"
    echo "Ключ добавлен в $auth_file."
fi
chown "$target_user:$(id -gn "$target_user")" "$auth_file"
chmod 600 "$auth_file"
command -v restorecon &>/dev/null && restorecon -R "$ssh_dir" || true

# --- Подтверждение перед отключением паролей ---
echo
echo "ВНИМАНИЕ: после этого вход по паролю будет отключён."
echo "Убедитесь, что ключ верный и у вас есть доступ к приватной части."
read -r -p "Отключить вход по паролю? [y/N]: " ans </dev/tty
[[ "$ans" =~ ^[Yy]$ ]] || { echo "Ключ добавлен, пароли оставлены включёнными."; exit 0; }

# --- Отключение паролей ---
conf_main="/etc/ssh/sshd_config"
conf_dir="/etc/ssh/sshd_config.d"
backup="/root/sshd_config.backup.$(date +%Y%m%d-%H%M%S)"
cp -a "$conf_main" "$backup"
[[ -d "$conf_dir" ]] && cp -a "$conf_dir" "$backup.d"
echo "Резервная копия: $backup"

mkdir -p "$conf_dir"
cat > "$conf_dir/00-disable-password-auth.conf" <<'EOF'
PasswordAuthentication no
KbdInteractiveAuthentication no
ChallengeResponseAuthentication no
PubkeyAuthentication yes
EOF

# Если основной конфиг не подключает sshd_config.d — добавляем Include в начало
if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/' "$conf_main"; then
    sed -i '1i Include /etc/ssh/sshd_config.d/*.conf' "$conf_main"
fi

# Проверка конфигурации; при ошибке откат
if ! sshd -t; then
    echo "Ошибка в конфигурации sshd, откатываю изменения."
    rm -f "$conf_dir/00-disable-password-auth.conf"
    cp -a "$backup" "$conf_main"
    exit 1
fi

# Проверка, что реально применяется "no" (другие файлы, например cloud-init, могут перебивать)
effective="$(sshd -T | awk '/^passwordauthentication/ {print $2}')"
if [[ "$effective" != "no" ]]; then
    echo "Другой конфиг переопределяет настройку, правлю его..."
    grep -rlE '^\s*PasswordAuthentication\s+yes' "$conf_main" "$conf_dir" 2>/dev/null \
        | xargs -r sed -i -E 's/^(\s*)PasswordAuthentication\s+yes/\1PasswordAuthentication no/I'
    sshd -t
    effective="$(sshd -T | awk '/^passwordauthentication/ {print $2}')"
fi

if [[ "$effective" != "no" ]]; then
    echo "Не удалось отключить PasswordAuthentication, проверьте конфиги вручную."
    exit 1
fi

# --- Применение ---
systemctl reload ssh 2>/dev/null || systemctl reload sshd

echo
echo "Готово: вход по паролю отключён."
echo "НЕ закрывайте текущую сессию! Откройте новый терминал и проверьте вход по ключу:"
echo "    ssh -i /путь/к/приватному_ключу $target_user@<адрес_сервера>"
echo "Если что-то пошло не так, откат: cp -a $backup $conf_main && rm $conf_dir/00-disable-password-auth.conf && systemctl reload ssh"
