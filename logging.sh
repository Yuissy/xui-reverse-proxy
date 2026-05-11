#!/bin/bash
# Скрипт настройки логирования и ротации
# Запускать от root после основной установки

echo "=== Настройка логирования ==="

# 1. Nginx: отключаем access_log, оставляем только ошибки
cat > /etc/nginx/conf.d/logging.conf <<'EOF'
access_log off;
error_log /var/log/nginx/error.log warn;
EOF
echo "Nginx: access_log отключён, error_log = warn"

# 2. Xray: понижаем уровень до warning
XRAY_CONFIG="/usr/local/etc/xray/config.json"
if [ -f "$XRAY_CONFIG" ]; then
    if command -v jq &>/dev/null; then
        jq '.log.loglevel = "warning"' "$XRAY_CONFIG" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
        systemctl restart xray
        echo "Xray: loglevel = warning"
    else
        apt update -qq && apt install -y jq
        jq '.log.loglevel = "warning"' "$XRAY_CONFIG" > /tmp/xray_config.tmp && mv /tmp/xray_config.tmp "$XRAY_CONFIG"
        systemctl restart xray
        echo "Xray: loglevel = warning"
    fi
fi

# 3. Logrotate: ежемесячная ротация
cat > /etc/logrotate.d/our-services <<'EOF'
/var/log/nginx/*.log /var/log/xray/*.log /var/log/fail2ban.log {
    monthly
    rotate 1
    missingok
    notifempty
    copytruncate
}
EOF
echo "Logrotate: ежемесячная ротация (хранится 1 месяц)"

# 4. Принудительная очистка
logrotate -f /etc/logrotate.d/our-services 2>/dev/null
echo "Готово."
