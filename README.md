# 🧰 amtcas

> Сборник полезных скриптов для настройки и обслуживания серверов.
> Одна команда — готовый результат.

[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Ubuntu%2022.04%2B%20%7C%20Debian%2012%2B-blue?style=flat-square)](#)

---

## ⚡ Скрипты

| Скрипт | Описание |
| ------ | -------- |
| [🩺 `vps-check.sh`](#-vps-checksh) | Приёмка нового VPS: 12 проверок железа, сети и репутации IP |
| [🔐 `firststep.sh`](#-firststepsh) | Добавляет SSH-ключ и отключает вход по паролю |
| [🌉 `mtproxy-setup.sh`](#-mtproxy-setupsh) | Приватный Telegram MTProxy с туннелем VLESS+Reality |
| [🛡 `remnawave-audit.sh`](#-remnawave-auditsh) | Аудит ноды/панели Remnawave: проверка и безопасные исправления |

**Быстрый запуск:**

```bash
# vps-check — приёмка VPS
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/vps-check.sh)"

# firststep — SSH-ключ и отключение паролей
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/firststep.sh)"

# mtproxy-setup — каскадный MTProxy
bash <(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/mtproxy-setup.sh)

# remnawave-audit — аудит Remnawave
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/remnawave-audit.sh)"
```

> ⚠️ Запускай через `bash -c "$(curl ...)"` или `bash <(curl ...)`, а не `curl ... | bash`: так работает интерактивный ввод.
> `sudo bash <(curl ...)` не сработает: sudo закрывает дескриптор `/dev/fd/*`.

---

## 🩺 vps-check.sh

**Что делает.** Проверяет свежий VPS за первый час: стоит ли обживать сервер или просить замену. Цветной отчёт и вердикт.

**Быстрый запуск.**

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/vps-check.sh)"
```

Опции: `--home-ip IP`, `--skip-fio`, `--skip-speed`, `--fio-runtime СЕК` — после `_`:
`sudo bash -c "$(curl -fsSL ...)" _ --skip-fio`

**Как работает.** 12 проверок в 4 этапа: железо (steal time, OOM, `fio`), сеть (скорость, `mtr`, MTU, IPv6), репутация IP (DNSBL, rDNS, порт 25), пригодность (TUN, Docker, nested). Статусы OK/WARN/FAIL, мусорных файлов не оставляет.

---

## 🔐 firststep.sh

**Что делает.** Первый шаг после выдачи VPS: ставит SSH-ключ и закрывает вход по паролю.

**Быстрый запуск.**

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/firststep.sh)"
```

**Как работает.** Проверяет ключ, добавляет в `authorized_keys`, после подтверждения отключает пароли, проверяет `sshd -t`, при ошибке откатывает, перезагружает sshd без обрыва сессии.

> 💡 Не закрывай текущую сессию, пока не проверишь вход по ключу из нового терминала.

---

## 🌉 mtproxy-setup.sh

**Что делает.** Приватный MTProxy через зашифрованный туннель на зарубежном сервере.

```
Клиент → 🇷🇺 RU-сервер (telemt) → 🌉 Мост (Xray, VLESS+Reality) → Telegram
```

**Быстрый запуск.**

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/mtproxy-setup.sh)
```

**Как работает.** Два VPS: RU-сервер и мост. Скрипт сам определяет роль, ставит Docker, генерирует ключи, выдаёт данные и готовую ссылку `tg://proxy?...`. Транспорт: TCP, gRPC или xHTTP. После первого запуска доступен как команда `amtcas`; есть автообновление и удаление.

---

## 🛡 remnawave-audit.sh

**Что делает.** Интерактивный аудит ноды и панели Remnawave: проверка, отчёт и безопасные исправления (только после подтверждения). Закрывает пять признаков, по которым ТСПУ находит VPN-ноды, и CVE-2026-98432 (MPTCP).

**Быстрый запуск.**

```bash
sudo bash -c "$(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/remnawave-audit.sh)"
```

**Меню.**

```
1) Проверить ноду (read-only)
2) Проверить и исправить ноду
3) Проверить панель (через API)
0) Выход
```

**Что проверяет нода.** ОС, ядро, диск; MPTCP; firewall и порт ноды (не открыт ли всем); selfsteal — 301 с 80, заглушка на `127.0.0.1:9443`, HSTS, TLS 1.2/1.3; SSH (root, пароли); Docker (restart policy).

**Что проверяет панель.** Ноды online/offline и версии Xray (< 26.10.31 — CVE); профили: Trojan, VLESS без Vision, `reality target`/`serverNames`; пользователи. Конфиг Xray на ноде не хранится — панель высылает его при запуске, поэтому проверки читаются через API.

**Что исправляет.** MPTCP off (с сохранением в `sysctl.d`); ufw: 22/80/443 открыты, порт ноды — только с IP панели, default deny. 301/HSTS (Caddyfile), ядро и SSH — только инструкцией или после явного «y».

**Отчёт.** `reports/<host>-<режим>-<дата>.md`, итог OK/WARN/FAIL.

**Требования.** Нода: Ubuntu 22.04+/Debian 12+, root. Панель: `python3` и API-токен (Settings → API).

---

## 📄 Лицензия

MIT: используй свободно, модифицируй, распространяй.

Построено на базе [Xray-core](https://github.com/XTLS/Xray-core) и [telemt](https://github.com/telemt/telemt).
