# Reverse Proxy Fork — XHTTP + Cascade

Форк оригинального скрипта [cortez24rus/xui-reverse-proxy](https://github.com/cortez24rus/xui-reverse-proxy) с поддержкой каскада из двух серверов и транспортом XHTTP.

## Особенности

- **XHTTP** как единственный транспорт (убраны gRPC, WebSocket, Reality, XTLS)
- **Каскад:** Сервер 1 (РФ, полная установка) → Сервер 2 (зарубежный, ретранслятор)
- **Сервер 2 в режиме relay:** только Xray, без панели, без Nginx, без SSL
- **Маршрутизация:** российские сайты — напрямую, зарубежные — через каскад, IP-чекеры — блокируются
- **WARP (WireGuard)** для AI-сервисов (ChatGPT, Gemini, Claude) на Сервере 2
- **Защита:** UFW, fail2ban, BBR, TCP MSS Clamp, автообновления безопасности
- **Автообновление geo-файлов** (geoip.dat, geosite.dat) из [runetfreedom/russia-v2ray-rules-dat](https://github.com/runetfreedom/russia-v2ray-rules-dat)
- **Панель 3x-ui** на Сервере 1 привязана к localhost (доступ через SSH-туннель)
- **Панель на Сервере 2 отсутствует** — Xray работает как самостоятельная служба

## Требования

- Два VPS (один в РФ, один за рубежом)
- Один домен, привязанный к Cloudflare (для Сервера 1)
- ОС: Ubuntu 20.04/22.04/24.04 или Debian 11/12
- Права root на обоих серверах

## Установка

## Настройка домена (Cloudflare)

Перед запуском скрипта на Сервере 1 настройте DNS-записи домена в Cloudflare:

| Type  | Name            | Content             | Proxy status               |
|-------|-----------------|---------------------|----------------------------|
| A     | `ваш-домен.ru`  | IP-адрес Сервера 1  | DNS only (серое облачко)   |
| CNAME | `www`           | `ваш-домен.ru`      | DNS only (серое облачко)   |

Также в разделе **SSL/TLS → Overview** установите:
- **Configure:** Full
- **Minimum TLS Version:** TLS 1.3
- В разделе **Edge Certificates** включите **TLS 1.3**

### Шаг 1: Сервер 2 (зарубежный, ретранслятор)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/xui-reverse-proxy/main/reverse_proxy.sh) --mode relay
```
Скрипт задаст несколько вопросов и в конце выдаст карточку с параметрами. Сохраните их — они понадобятся для настройки Сервера 1

### Шаг 2: Сервер 1 (РФ, точка входа)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/xui-reverse-proxy/main/reverse_proxy.sh) --mode full
```
Потребуется ввести:

Домен

Email и API-ключ Cloudflare

Параметры Сервера 2 (из Шага 1)

### Шаг 3: Настройка клиента
После установки скрипт выведет данные для подключения:

Адрес: ваш домен

Порт: 443

Путь: секретный путь (сгенерирован автоматически)

UUID: уникальный идентификатор

Тип: VLESS + XHTTP

Введите эти данные в клиент (v2rayN, Nekobox, v2rayNG).

### Шаг 4: Настройка логирования (рекомендуется)

```bash
bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/xui-reverse-proxy/main/logging.sh)
```
Дополнительно
После установки рекомендуется проверить сервер через ByeByeVPN — внешний сканер детектируемости прокси.

Лицензия
MIT. Основан на cortez24rus/xui-reverse-proxy.
