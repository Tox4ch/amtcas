# 🧰 amtcas

> Сборник полезных скриптов для настройки и обслуживания серверов.
> Одна команда — готовый результат.

[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Ubuntu%2022.04%2B%20%7C%20Debian%2012%2B-blue?style=flat-square)](#)

---

## ⚡ Скрипты

| Скрипт | Описание |
| ------ | -------- |
| [🔐 `firststep.sh`](#-firststepsh) | Добавляет SSH-ключ и отключает вход по паролю |
| [🌉 `mtproxy-setup.sh`](#-mtproxy-setupsh) | Приватный Telegram MTProxy с туннелем VLESS+Reality |

**Быстрый запуск:**

```bash
# 🔐 Первичная защита сервера
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/firststep.sh)

# 🌉 Каскадный MTProxy
bash <(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/mtproxy-setup.sh)
```

> ⚠️ Запускай через `bash <(curl ...)`, а не `curl ... | bash`: так работает интерактивный ввод.

---

## 🔐 firststep.sh

**Что делает.** Первый шаг после выдачи VPS: ставит ваш SSH-ключ и закрывает вход по паролю.

**Быстрый запуск.**

```bash
sudo bash <(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/firststep.sh)
```

**Как работает.**

1. Спрашивает пользователя и публичный ключ, проверяет ключ через `ssh-keygen`.
2. Добавляет ключ в `~/.ssh/authorized_keys` (без дублей, с правильными правами).
3. После подтверждения отключает `PasswordAuthentication` и `KbdInteractiveAuthentication`.
4. Проверяет конфиг (`sshd -t`), при ошибке откатывает изменения, делает бэкап в `/root/`.
5. Перезагружает sshd без обрыва текущей сессии.

> 💡 Не закрывай текущую сессию, пока не проверишь вход по ключу из нового терминала.

---

## 🌉 mtproxy-setup.sh

**Что делает.** Поднимает приватный Telegram MTProxy, который выходит в Telegram через зашифрованный туннель на зарубежном сервере. Подходит, когда прямой MTProxy блокируется или тормозит.

```
Клиент → 🇷🇺 RU-сервер (telemt) → 🌉 Мост (Xray, VLESS+Reality) → Telegram
```

**Быстрый запуск.**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/mtproxy-setup.sh)
```

После первого запуска скрипт ставится как команда `amtcas`: дальше достаточно набрать `amtcas`.

**Как работает.**

1. Нужны два VPS: **RU-сервер** и **мост** за рубежом (Ubuntu 22.04 / Debian 12, открытый `443/tcp`).
2. Запусти скрипт на **мосту**: он сам поставит Docker, сгенерирует ключи и выдаст данные для RU-сервера.
3. Запусти скрипт на **RU-сервере**, вставь эти данные (транспорт должен совпадать с мостом).
4. Получи готовую ссылку `tg://proxy?...` и открой её в Telegram.

Роль сервера скрипт определяет сам. Транспорт на выбор: TCP, gRPC или xHTTP. Есть автообновление и полное удаление через меню.

---

## 📄 Лицензия

MIT: используй свободно, модифицируй, распространяй.

Построено на базе [telemt](https://github.com/telemt/telemt) и [Xray-core](https://github.com/XTLS/Xray-core).
