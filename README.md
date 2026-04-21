# 🌉 amtcas — Каскадный MTProxy

> **Автоматическая настройка приватного Telegram MTProxy с VLESS+Reality туннелем**
>
> Клиент → 🇷🇺 RU-сервер (telemt) → 🌉 Мост (Xray) → 📨 Telegram

[![Version](https://img.shields.io/badge/version-1.0.0-blue?style=flat-square)](https://github.com/Tox4ch/amtcas)
[![License](https://img.shields.io/badge/license-MIT-green?style=flat-square)](LICENSE)
[![Platform](https://img.shields.io/badge/platform-Ubuntu%2022.04%20%7C%20Debian%2012-orange?style=flat-square)](#требования)

---

## 🤔 Зачем это нужно?

Обычный MTProxy поднимается на одном сервере и напрямую соединяется с Telegram. В условиях сложной фильтрации это работает ненадёжно: трафик от прокси до Telegram проходит через российских провайдеров и может быть заблокирован или замедлен.

**amtcas** строит цепочку в два звена:

1. Клиент Telegram подключается к **RU-серверу** — он работает как MTProxy и принимает подключения
2. RU-сервер пробрасывает трафик через зашифрованный **VLESS+Reality туннель** на сервер-мост за рубежом
3. **Сервер-мост** уже имеет прямой незаблокированный доступ к Telegram

---

## 🏗️ Архитектура соединения

```
📱 Клиент Telegram
      │
      │  MTProto / Fake-TLS
      │  Порт 443
      ▼
┌─────────────────────────────────────────┐
│  🇷🇺 RU-сервер                           │
│                                         │
│  ┌──────────┐      ┌────────────────┐   │
│  │  telemt  │ ───▶ │  Xray-client   │   │
│  │  :443    │      │  SOCKS5 :1080  │   │
│  └──────────┘      └────────────────┘   │
└──────────────────────────┬──────────────┘
                           │
                           │  VLESS + XTLS-Reality
                           │  (для DPI выглядит как HTTPS → google.com)
                           │  Порт 443
                           ▼
┌─────────────────────────────────────────┐
│  🌉 Сервер-мост (любая страна)           │
│                                         │
│  ┌────────────────┐                     │
│  │  Xray-server   │                     │
│  │  VLESS+Reality │                     │
│  └────────────────┘                     │
└──────────────────────────┬──────────────┘
                           │
                           │  TCP / прямой доступ
                           ▼
                   📨 Telegram DC
```
---

## ✨ Возможности скрипта

- 🔍 **Проверка зависимостей** — автоматически определяет что не установлено и предлагает поставить
- 📦 **Автоустановка Docker** — работает на Ubuntu и Debian, определяет дистрибутив сам
- 🌉 **Настройка сервера-моста** — генерирует ключи X25519 и UUID, создаёт конфиги Xray, запускает контейнер
- 🇷🇺 **Настройка RU-сервера** — настраивает Xray-клиент и telemt, прописывает системные параметры
- 🔒 **Автонастройка фаервола** — открывает нужные порты, закрывает внутренние
- 🔍 **Проверка маршрута соединения** — после установки проверяет туннель и показывает схему с реальными IP
- 🔗 **Готовая ссылка** — `tg://proxy?...` выводится сразу после запуска

---

## 📋 Требования

### Серверы

Тебе понадобятся **два** VPS:

| | RU-сервер | Сервер-мост |
|---|---|---|
| Расположение | Россия или любой с RU-IP | Любая страна за пределами РФ |
| ОС | Ubuntu 22.04 / Debian 12 | Ubuntu 22.04 / Debian 12 |
| RAM | от 512 МБ | от 512 МБ |
| Открытый порт | `443/tcp` входящий | `443/tcp` входящий |
| Архитектура | amd64 / arm64 | amd64 / arm64 |
| Доступ | root или sudo | root или sudo |

> 💡 Сервер-мост необязательно должен быть в Германии — подойдёт любой VPS в Европе, США, Финляндии и т.д. с прямым доступом к Telegram.

### Локально

- Терминал с SSH-доступом к обоим серверам
- Больше ничего — всё остальное скрипт установит сам

---

## 🚀 Быстрый старт

### Первый запуск (с GitHub)

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/mtproxy-setup.sh)
```

> ⚠️ Используй именно `bash <(curl ...)`, а не `curl ... | bash` — интерактивный ввод работает только с первым вариантом.

### Последующие запуски

После первого запуска скрипт устанавливается в `/usr/local/bin/amtcas`:

```bash
amtcas
```

---

## 📖 Порядок настройки

### Шаг 1 — Настроить сервер-мост

Зайди по SSH на **сервер-мост** и запусти скрипт. В меню выбери пункт **1**.

Скрипт автоматически:
- Сгенерирует X25519 ключевую пару и UUID
- Создаст конфиг Xray VLESS+Reality
- Запустит контейнер

В конце выведет **блок с данными для RU-сервера** — скопируй их:

```
Мост IP:      1.2.3.4
Мост Port:    443
UUID:         xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Public key:   xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
Short ID:     abcd1234
SNI:          www.google.com
```

### Шаг 2 — Настроить RU-сервер

Зайди по SSH на **RU-сервер** и запусти скрипт. В меню выбери пункт **2**.

Скрипт запросит данные из Шага 1 и автоматически:
- Пропишет `sysctl` для бинда на порт 443
- Создаст конфиг Xray-клиента (SOCKS5 → VLESS)
- Создаст конфиг telemt (MTProxy → SOCKS5)
- Настроит фаервол
- Запустит оба контейнера
- Проверит туннель и покажет готовую ссылку

### Шаг 3 — Подключить клиент

Скопируй ссылку вида:
```
tg://proxy?server=RU_IP&port=443&secret=ee...
```

Открой её в Telegram или добавь вручную: **Настройки → Конфиденциальность → Прокси**.

---

## 🛠️ Полезные команды

### Управление сервисами

```bash
# Статус всех контейнеров
docker ps

# Логи telemt (в реальном времени)
cd ~/mtproxy && docker compose logs -f

# Логи Xray-клиента
cd ~/xray-client && docker compose logs -f

# Логи Xray-моста (на сервере-мосте)
cd ~/xray-server && docker compose logs -f

# Перезапустить telemt
cd ~/mtproxy && docker compose restart

# Перезапустить Xray-клиент
cd ~/xray-client && docker compose restart

# Обновить образы до последней версии
docker compose pull && docker compose up -d
```

### Проверка туннеля

```bash
# Должен вернуть IP сервера-моста, а не RU
curl --socks5 127.0.0.1:1080 https://ifconfig.me

# Проверить связь с Telegram через туннель
curl --socks5 127.0.0.1:1080 https://149.154.167.50 -v --max-time 5
```

### Управление пользователями telemt

```bash
# Получить все ссылки через API
curl -s http://127.0.0.1:9091/v1/users | jq

# Добавить нового пользователя — сгенерировать секрет
openssl rand -hex 16
```

Добавить пользователя в `~/mtproxy/telemt.toml`:
```toml
[access.users]
user1 = "a1b2c3d4e5f60718293a4b5c6d7e8f90"
user2 = "00112233445566778899aabbccddeeff"
```
Конфиг подхватывается **без перезапуска**.

---

## ⚙️ Дополнительная настройка telemt

### Домен в ссылке вместо IP

Добавь A-запись в DNS (`proxy.example.com → RU_IP`), затем в `telemt.toml`:

```toml
[general.links]
public_host = "proxy.example.com"
```

### Ограничение числа подключений на пользователя

```toml
[access.user_max_unique_ips]
myuser = 3   # Максимум 3 уникальных IP одновременно
```

### Метрики (Prometheus)

```toml
[server]
metrics_port = 9090
metrics_whitelist = ["127.0.0.1/32"]
```

Доступны по `http://127.0.0.1:9090/metrics`.

### Лимит соединений

```toml
[server]
max_connections = 10000   # 0 = без лимита
```

---

## 🗂️ Структура файлов после установки

```
RU-сервер:
├── /usr/local/bin/amtcas       ← глобальная команда
│
├── ~/xray-client/
│   ├── config.json             ← VLESS outbound → мост, SOCKS5 :1080
│   └── docker-compose.yml
│
└── ~/mtproxy/
    ├── telemt.toml             ← MTProxy, upstream: socks5://127.0.0.1:1080
    └── docker-compose.yml

Сервер-мост:
└── ~/xray-server/
    ├── config.json             ← VLESS+Reality inbound :443
    └── docker-compose.yml
```

---

## 🔌 Таблица портов

| Сервер | Сервис | Адрес | Открыт наружу |
|---|---|---|---|
| RU | telemt MTProxy | `0.0.0.0:443/tcp` | ✅ для клиентов Telegram |
| RU | Xray SOCKS5 | `127.0.0.1:1080/tcp` | ❌ только localhost |
| Мост | Xray VLESS+Reality | `0.0.0.0:443/tcp` | ✅ для RU-сервера |

---

## 🔄 Обновление скрипта

При каждом запуске `amtcas` автоматически проверяет GitHub на наличие новой версии.
Если обновление доступно — покажет уведомление и предложит обновиться одним нажатием.

Обновить вручную:
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/Tox4ch/amtcas/main/mtproxy-setup.sh)
```

---

## 🐛 Диагностика

| Симптом | Вероятная причина | Решение |
|---|---|---|
| `curl ifconfig.me` через SOCKS5 возвращает RU IP | Xray-клиент не подключился к мосту | `cd ~/xray-client && docker compose logs` |
| `received real certificate (MITM)` | В `address` указан домен вместо IP | Поставить реальный IP моста |
| `received real certificate (MITM)` при правильном IP | Перепутаны private/public ключи | Перегенерировать, `privateKey` — на мосту, `publicKey` — на RU |
| `Permission denied` при бинде на 443 | Non-root контейнер | `sysctl -w net.ipv4.ip_unprivileged_port_start=443` |
| telemt не видит `127.0.0.1:1080` | Нет `network_mode: host` | Проверить оба `docker-compose.yml` на RU |
| `bind: address already in use` | Порт 443 занят | `ss -tlnp \| grep 443` |
| `unknown command` при запуске Xray | Дублирование команды | `command: ["run", ...]` без `xray` в начале |

---

## 📄 Лицензия

MIT — используй свободно, модифицируй, распространяй.

---

<div align="center">
  <sub>Построено на базе <a href="https://github.com/telemt/telemt">telemt</a> и <a href="https://github.com/XTLS/Xray-core">Xray-core</a></sub>
</div>
