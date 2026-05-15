#!/usr/bin/env bash
set -euo pipefail

########################################
# REVERSE PROXY FORK — СКРИПТ ОБСЛУЖИВАНИЯ
# Запуск: bash update.sh [full|relay]
########################################

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warning() { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}=== $* ===${NC}"; }

[[ $EUID -ne 0 ]] && error "Запустите от root"

# Восстанавливаем SOCKS5-прокси, если он настроен для apt
if [[ -f /etc/apt/apt.conf.d/99-proxy.conf ]]; then
    local proxy_url=$(grep -oP 'socks5h://\K[^"]+' /etc/apt/apt.conf.d/99-proxy.conf 2>/dev/null | head -1)
    if [[ -n "$proxy_url" ]]; then
        export http_proxy="socks5h://$proxy_url"
        export https_proxy="socks5h://$proxy_url"
    fi
fi

# ==============================================
# 1. Бэкап конфигов
# ==============================================
backup_configs() {
    section "Создание бэкапа"
    local BACKUP_DIR="/usr/local/reverse_proxy/backup"
    local DATE=$(date +"%Y-%m-%d_%H-%M")
    mkdir -p "$BACKUP_DIR"

    tar -czf "$BACKUP_DIR/backup_$DATE.tar.gz" \
        /etc/nginx/ \
        /etc/x-ui/ \
        /usr/local/etc/xray/ \
        /etc/letsencrypt/ 2>/dev/null || true

    find "$BACKUP_DIR" -name "backup_*.tar.gz" -mtime +30 -delete 2>/dev/null || true

    info "Бэкап создан: $BACKUP_DIR/backup_$DATE.tar.gz"
}

# ==============================================
# 2. Обновление Xray (сервер 2)
# ==============================================
update_xray_relay() {
    section "Обновление Xray"
    if ! systemctl is-active --quiet xray 2>/dev/null; then
        warning "Служба xray не найдена. Пропускаем."
        return
    fi

    local before after
    before=$(/usr/local/bin/xray version 2>/dev/null | head -1 || echo "неизвестно")
    
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    
    after=$(/usr/local/bin/xray version 2>/dev/null | head -1 || echo "неизвестно")
    
    systemctl restart xray
    info "Xray: $before → $after"
}

# ==============================================
# 3. Обновление панели 3x-ui (сервер 1)
# ==============================================
update_xui_panel() {
    section "Обновление панели 3x-ui и Xray"
    if ! systemctl is-active --quiet x-ui 2>/dev/null; then
        warning "Служба x-ui не найдена. Пропускаем."
        return
    fi

    echo "2" | x-ui || warning "Не удалось обновить панель через x-ui"
    info "Панель 3x-ui и Xray обновлены"
}

# ==============================================
# 4. Обновление Geo-файлов (сервер 1)
# ==============================================
update_geo_files() {
    section "Обновление Geo-файлов"
    if [[ -f /usr/local/bin/update-geodata.sh ]]; then
        bash /usr/local/bin/update-geodata.sh
        info "Geo-файлы обновлены"
    else
        warning "Скрипт update-geodata.sh не найден. Пропускаем."
    fi
}

# ==============================================
# 5. Обновление системных пакетов
# ==============================================
update_system() {
    section "Обновление системных пакетов"
    apt update -y
    apt upgrade -y
    apt autoremove -y
    apt autoclean -y
    info "Системные пакеты обновлены"
}

# ==============================================
# 6. Очистка логов
# ==============================================
cleanup_logs() {
    section "Очистка старых логов"
    journalctl --vacuum-time=7d 2>/dev/null || true
    find /var/log -name "*.log.*" -mtime +14 -delete 2>/dev/null || true
    info "Логи старше 7 дней очищены"
}

# ==============================================
# 7. Статус сервера
# ==============================================
show_status() {
    section "Статус сервера"
    
    echo "Хост: $(hostname)"
    echo "Ядро: $(uname -r)"
    echo "Аптайм: $(uptime -p)"
    echo "Диск: $(df -h / | awk 'NR==2 {print $3 "/" $2 " (" $5 ")"}')"
    echo "Память: $(free -h | awk '/^Mem:/ {print $3 "/" $2}')"

    echo ""
    echo "=== Службы ==="
    
    if systemctl is-active --quiet xray 2>/dev/null; then
        info "xray: активен ($(/usr/local/bin/xray version 2>/dev/null | head -1 || echo 'v?'))"
    fi
    
    if systemctl is-active --quiet x-ui 2>/dev/null; then
        info "x-ui: активен"
        echo "   Порт панели: $(grep -oP '"port":\s*\K\d+' /etc/x-ui/x-ui.db 2>/dev/null | head -1 || echo '2053')"
        if ss -tlnp 2>/dev/null | grep -q ":10000 "; then
            info "Xray (порт 10000): слушается"
        else
            warning "Xray (порт 10000): НЕ слушается"
        fi
    fi

    if systemctl is-active --quiet nginx 2>/dev/null; then
        info "nginx: активен"
    fi

    if ufw status 2>/dev/null | grep -q "Status: active"; then
        info "ufw: активен"
    fi

    if fail2ban-client status 2>/dev/null | grep -q "Number of jail"; then
        info "fail2ban: активен ($(fail2ban-client status 2>/dev/null | grep "Number of jail" | awk '{print $NF}'))"
    fi

    local BACKUP_DIR="/usr/local/reverse_proxy/backup"
    if [[ -d "$BACKUP_DIR" ]]; then
        echo ""
        echo "=== Бэкапы ==="
        ls -lh "$BACKUP_DIR" | tail -5
    fi
}

# ==============================================
# Главное меню
# ==============================================
case "${1:-}" in
    full)
        echo ""
        echo "============================================"
        echo "  ОБСЛУЖИВАНИЕ СЕРВЕРА 1 (РФ)"
        echo "============================================"
        backup_configs
        update_xui_panel
        update_geo_files
        update_system
        cleanup_logs
        show_status
        echo ""
        info "Обслуживание завершено."
        ;;
    relay)
        echo ""
        echo "============================================"
        echo "  ОБСЛУЖИВАНИЕ СЕРВЕРА 2 (ЗАРУБЕЖНЫЙ)"
        echo "============================================"
        backup_configs
        update_xray_relay
        update_system
        cleanup_logs
        show_status
        echo ""
        info "Обслуживание завершено."
        ;;
    *)
        echo "============================================"
        echo "  REVERSE PROXY FORK — СКРИПТ ОБСЛУЖИВАНИЯ"
        echo "============================================"
        echo ""
        echo "Использование:"
        echo "  bash $0 full   — обслуживание Сервера 1 (РФ)"
        echo "  bash $0 relay  — обслуживание Сервера 2 (зарубежный)"
        echo ""
        exit 1
        ;;
esac
