# Reverse Proxy Fork — XHTTP Cascade

[![Version](https://img.shields.io/badge/version-2.0.1-blue)](https://github.com/Yuissy/xui-reverse-proxy)
[![License](https://img.shields.io/badge/license-MIT-green)](LICENSE)

**Пример скрипта для настройки свободного интернета**.  
Реализован на основе связки из двух серверов (домашний + зарубежный), реверс-прокси Nginx, панели 3x‑ui и транспорта XHTTP.  
Форк проекта [cortez24rus/xui-reverse-proxy](https://github.com/cortez24rus/xui-reverse-proxy).

---

## Требования

- Два VPS
- Один домен, привязанный к Cloudflare (для домашнего сервера)
- ОС: Ubuntu 20.04/22.04/24.04 или Debian 11/12
- Права root на обоих серверах

## Установка

## Настройка домена (Cloudflare)

Перед запуском скрипта на домашнем сервере настройте DNS-записи домена в Cloudflare:

| Type  | Name            | Content             | Proxy status               |
|-------|-----------------|---------------------|----------------------------|
| A     | `ваш-домен.ru`  | IP-адрес домашнего  | DNS only (серое облачко)   |
| CNAME | `www`           | `ваш-домен.ru`      | DNS only (серое облачко)   |

Также в разделе **SSL/TLS → Overview** установите:
- **Configure:** Full
- **Minimum TLS Version:** TLS 1.3
- В разделе **Edge Certificates** включите **TLS 1.3**

## 🚀 Быстрый старт

Установка **зарубежного сервера** (ретранслятор):
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/xui-reverse-proxy/main/reverse_proxy_v2.sh) --mode relay
```
Установка **домашнего сервера** (точка входа с панелью управления):
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/xui-reverse-proxy/main/reverse_proxy_v2.sh) --mode full
```
Без аргументов откроется интерактивное меню:
```bash
bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/xui-reverse-proxy/main/reverse_proxy_v2.sh)
```

---

## 📂 Состав проекта

| Файл | Назначение |
|------|------------|
| **`reverse_proxy_v2.sh`** | Основной установщик (v2.0.1). Настройка обоих серверов, Nginx, SSL, панели, маршрутизации, WARP, сайта-прикрытия. |
| `reverse_proxy_random_site.sh` | Установка случайного сайта-прикрытия (из репозитория Cortez). Вызывается из меню v2. |
| `check_installation.sh` | Детальная проверка компонентов после установки. |
| `update.sh` | Ручное обслуживание: обновление панели, Xray, системы и очистка логов. |
| `logging.sh` | Настройка логирования и ротации логов (Nginx, Xray, Fail2ban). |
| `reverse_proxy.sh` | **Устаревшая версия v1.x. Оставлена для истории. Использовать не рекомендуется.** |

---

## 🔧 Возможности v2.0.1

- **Два режима установки:** Full (домашний сервер) и Relay (зарубежный сервер)
- **Реверс-прокси Nginx** с маскировкой под обычный сайт
- **Автоматический выпуск SSL-сертификатов** через Cloudflare DNS
- **Панель 3x‑ui** (последняя версия) с привязкой к localhost
- **Транспорт VLESS + XHTTP** с каскадной маршрутизацией
- **Маршрутизация на основе geo‑файлов** (geosite, geoip)
- **WARP на зарубежном сервере** для доступа к избирательно ограниченным ресурсам
- **Фильтрация рекламы, телеметрии, торрентов**
- **Автообновление geo‑файлов** через cron
- **Автоматические обновления безопасности** (unattended‑upgrades)
- **Усиленная защита:** UFW, Fail2ban, BBR, MSS Clamp

---

## 📊 Схема маршрутизации (домашний сервер)

| Приоритет | Правило | Действие |
|-----------|---------|----------|
| 1 | Локальные адреса (geoip:private) | ➡️ напрямую |
| 2 | Сервисы определения IP (ifconfig.me и др.) | 🚫 blocked |
| 3 | Торренты (bittorrent) | 🚫 blocked |
| 4 | Реклама и телеметрия (geosite:category-ads-all, geosite:win-spy) | 🚫 blocked |
| 5 | Домены, требующие свободного доступа (ext:geosite_RU.dat:ru-blocked) | 🔄 каскад (зарубежный сервер) |
| 6 | Ресурсы внутри страны (geoip:ru) | ➡️ напрямую |
| 7 | Всё остальное | 🔄 каскад (зарубежный сервер) |

---

## ⚠️ Важные замечания

- **Перед установкой убедитесь, что порты 80 и 443 не заняты** (на домашнем сервере) и выбранный порт для Xray свободен (на зарубежном сервере).
- **Домен должен быть привязан к Cloudflare** — скрипт использует DNS‑валидацию для получения wildcard‑сертификата.
- **Панель 3x‑ui доступна только через SSH‑туннель** (localhost). Подробная инструкция выводится после установки.
- **Логин/пароль панели:** `admin` / `admin` — **сразу после входа смените пароль через интерфейс панели**.
- **На зарубежном сервере обязателен WARP.** Если получение ключей не удалось — установка прервётся с понятной ошибкой.
- **После установки рекомендуется проверить сервер через [ByeByeVPN](https://github.com/pwnnex/ByeByeVPN)** и настроить клиент строго по инструкции.

---

## 🆘 Поддержка

- [Issues на GitHub](https://github.com/Yuissy/xui-reverse-proxy/issues)
- [Оригинальный скрипт (cortez24rus)](https://github.com/cortez24rus/xui-reverse-proxy)
- [Панель 3x‑ui (MHSanaei)](https://github.com/MHSanaei/3x-ui)
- [Xray‑core](https://github.com/XTLS/Xray-core)
- [Geo‑файлы](https://github.com/runetfreedom/russia-v2ray-rules-dat)
- [Сканер детектируемости ByeByeVPN](https://github.com/pwnnex/ByeByeVPN)

## Особенности

- **XHTTP** как единственный транспорт (убраны gRPC, WebSocket, Reality, XTLS)
- **Каскад:** Сервер 1 (полная установка) → Сервер 2 (ретранслятор)
- **Сервер 2 в режиме relay:** только Xray, без панели, без Nginx, без SSL
- **Маршрутизация:** российские сайты — напрямую, зарубежные — через каскад, IP-чекеры — блокируются
- **WARP (WireGuard)** для AI-сервисов (ChatGPT, Gemini, Claude) на Сервере 2
- **Защита:** UFW, fail2ban, BBR, TCP MSS Clamp, автообновления безопасности
- **Автообновление geo-файлов** (geoip.dat, geosite.dat)
- **Панель 3x-ui** на Сервере 1 привязана к localhost (доступ через SSH-туннель)
- **Панель на Сервере 2 отсутствует** — Xray работает как самостоятельная служба
