#!/usr/bin/env bash
# Скрипт проверки установки Reverse Proxy Fork
# Запуск: bash <(curl -Ls https://raw.githubusercontent.com/Yuissy/xui-reverse-proxy/main/check_installation.sh)

GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

PASS="✅"
FAIL="❌"
WARN="⚠️"

echo ""
echo "============================================"
echo "  ПРОВЕРКА УСТАНОВКИ REVERSE PROXY FORK"
echo "============================================"
echo ""

declare -A RESULTS

# 1. Xray
if systemctl is-active --quiet xray 2>/dev/null; then
    RESULTS["Xray"]="$PASS запущен"
else
    RESULTS["Xray"]="$FAIL не запущен"
fi

# 2. UFW (проверяем через ufw status, а не systemctl)
if ufw status 2>/dev/null | grep -q "Status: active"; then
    RESULTS["UFW"]="$PASS активен"
else
    RESULTS["UFW"]="$FAIL не активен"
fi

# 3. Fail2ban
if fail2ban-client status 2>/dev/null | grep -q "Number of jail"; then
    JAILS=$(fail2ban-client status 2>/dev/null | grep "Jail list" | cut -d':' -f2 | xargs)
    RESULTS["Fail2ban"]="$PASS активен (джайлы: ${JAILS:-sshd})"
else
    RESULTS["Fail2ban"]="$FAIL не запущен"
fi

# 4. Cron
if systemctl is-active --quiet cron 2>/dev/null; then
    if crontab -l 2>/dev/null | grep -qv "^#" | grep -q "."; then
        RESULTS["Cron"]="$PASS запущен, задачи есть"
    else
        RESULTS["Cron"]="$WARN запущен, но crontab пуст"
    fi
else
    RESULTS["Cron"]="$FAIL не запущен"
fi

# 5. Nginx (только для full)
if command -v nginx &>/dev/null; then
    if systemctl is-active --quiet nginx 2>/dev/null; then
        RESULTS["Nginx"]="$PASS запущен"
    else
        RESULTS["Nginx"]="$FAIL не запущен"
    fi
fi

# 6. Панель 3x-ui (только для full)
if systemctl is-active --quiet x-ui 2>/dev/null; then
    RESULTS["3x-ui"]="$PASS запущена"
elif command -v x-ui &>/dev/null; then
    RESULTS["3x-ui"]="$FAIL не запущена"
fi

# 7. BBR
if sysctl net.ipv4.tcp_congestion_control 2>/dev/null | grep -q "bbr"; then
    RESULTS["BBR"]="$PASS активен"
else
    RESULTS["BBR"]="$FAIL не активен"
fi

# 8. MSS Clamp
if iptables -t mangle -L POSTROUTING 2>/dev/null | grep -q "TCPMSS.*1460"; then
    RESULTS["MSS Clamp"]="$PASS активен"
else
    RESULTS["MSS Clamp"]="$FAIL не найден"
fi

# 9. WARP ключи
if [ -f "/usr/local/etc/xray/config.json" ]; then
    if grep -q "WARP_SECRET_KEY_PLACEHOLDER\|WARP_PUBLIC_KEY_PLACEHOLDER" /usr/local/etc/xray/config.json 2>/dev/null; then
        RESULTS["WARP"]="$WARN заглушки"
    elif grep -q "secretKey" /usr/local/etc/xray/config.json 2>/dev/null; then
        RESULTS["WARP"]="$PASS ключи на месте"
    else
        RESULTS["WARP"]="$WARN не настроен"
    fi
fi

# 10. Geo-файлы
if [ -f "/usr/local/share/xray/geoip.dat" ] && [ -f "/usr/local/share/xray/geosite.dat" ]; then
    RESULTS["Geo-файлы"]="$PASS на месте"
else
    RESULTS["Geo-файлы"]="$FAIL отсутствуют"
fi

# 11. SSL-сертификаты (только для full)
if [ -d "/etc/letsencrypt/live" ] && ls /etc/letsencrypt/live/*/fullchain.pem &>/dev/null 2>&1; then
    RESULTS["SSL"]="$PASS сертификаты найдены"
elif command -v certbot &>/dev/null; then
    RESULTS["SSL"]="$WARN certbot установлен, сертификаты не найдены"
fi

# Вывод таблицы
echo "| Компонент       | Статус                     |"
echo "|-----------------|----------------------------|"
for key in "Xray" "UFW" "Fail2ban" "Cron" "Nginx" "3x-ui" "BBR" "MSS Clamp" "WARP" "Geo-файлы" "SSL"; do
    if [[ -n "${RESULTS[$key]}" ]]; then
        printf "| %-15s | %-26s |\n" "$key" "${RESULTS[$key]}"
    fi
done
echo ""
echo "============================================"
echo "  Проверка завершена"
echo "============================================"
