#!/usr/bin/env bash
set -euo pipefail

########################################
# REVERSE PROXY FORK v1.3
# XHTTP + Cascade (full/relay)
# Основан на скрипте cortez24rus (MIT)
########################################

VERSION="1.3.0"
DIR_REVERSE_PROXY="/usr/local/reverse_proxy/"

# Цвета
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${GREEN}[✓]${NC} $*"; }
warning() { echo -e "${YELLOW}[!]${NC} $*"; }
error()   { echo -e "${RED}[✗]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}=== $* ===${NC}"; }

# Обёртка curl с поддержкой SOCKS5
_curl() {
    if [[ -n "${http_proxy:-}" ]] && [[ "${http_proxy}" == socks5h://* ]]; then
        local socks_host="${http_proxy#socks5h://}"
        curl --socks5-hostname "$socks_host" "$@"
    else
        curl "$@"
    fi
}

# Проверка root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        error "Скрипт должен быть запущен от root. Используйте: sudo bash $0"
    fi
}

# Определение ОС
detect_os() {
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        OS=$ID
    else
        error "Не удалось определить ОС"
    fi

    case $OS in
        ubuntu|debian)
            PKG_UPDATE="apt update -y"
            PKG_INSTALL="apt install -y"
            ;;
        *)
            error "Поддерживаются только Ubuntu/Debian. Ваша ОС: $OS"
            ;;
    esac
    info "ОС: $OS"
}

# Внешний IP
get_public_ip() {
    local cache_file="$DIR_REVERSE_PROXY/.public_ip"
    if [[ -f "$cache_file" ]]; then
        cat "$cache_file"
        return
    fi

    local ip
    ip=$(curl -s --max-time 5 ipinfo.io/ip 2>/dev/null) || \
    ip=$(curl -s --max-time 5 ifconfig.me 2>/dev/null) || \
    ip=$(curl -s --max-time 5 icanhazip.com 2>/dev/null)
    if [[ -z "$ip" ]]; then
        warning "Не удалось автоматически определить IP"
    read -p "Введите внешний IP-адрес сервера вручную: " ip
    [[ -z "$ip" ]] && error "IP не введён. Установка прервана."
    fi
    echo "$ip" | tee "$cache_file"
}

# Случайная строка
random_string() {
    local length=${1:-30}
    set +o pipefail
    tr -dc 'A-Za-z0-9' < /dev/urandom | head -c "$length"
    set -o pipefail
}

# Случайный порт
random_port() {
    echo $(( RANDOM % 40000 + 10000 ))
}

# Генерация UUID
generate_uuid() {
    if command -v xray &>/dev/null; then
        xray uuid 2>/dev/null || cat /proc/sys/kernel/random/uuid
    else
        cat /proc/sys/kernel/random/uuid
    fi
}

# Установка зависимостей
install_dependencies() {
    section "Установка зависимостей"
    local deps=("curl" "wget" "jq" "openssl" "ufw" "fail2ban" "ca-certificates" "gnupg" "sqlite3" "iptables-persistent")
    local missing=()
    for dep in "${deps[@]}"; do
        if ! command -v "$dep" &>/dev/null && ! dpkg -l 2>/dev/null | grep -q "^ii.*$dep"; then
            missing+=("$dep")
        fi
    done
    if [[ ${#missing[@]} -gt 0 ]]; then
        info "Устанавливаем: ${missing[*]}"
        $PKG_UPDATE
        echo "iptables-persistent iptables-persistent/autosave_v4 boolean true" | debconf-set-selections 2>/dev/null || true
        echo "iptables-persistent iptables-persistent/autosave_v6 boolean true" | debconf-set-selections 2>/dev/null || true
        $PKG_INSTALL "${missing[@]}"
    else
        info "Все зависимости уже установлены"
    fi
}

# UFW
setup_ufw() {
    local mode=$1
    local inbound_port=${2:-0}
    section "Настройка UFW"

    ufw --force reset
    ufw default deny incoming
    ufw default allow outgoing

    local ssh_port
    ssh_port=$(ss -tlnp | grep sshd | awk '{print $4}' | awk -F':' '{print $NF}' | head -n1)
    ssh_port=${ssh_port:-22}
    if [[ "$ssh_port" == "22" ]] && ! ss -tlnp | grep -q ":22 "; then
    warning "SSH-порт не обнаружен, используется 22 (убедитесь, что это верно)"
    fi
    ufw allow "$ssh_port/tcp"

    # Сохраняем SOCKS5-прокси, если порт 1080 уже открыт
    if ufw status | grep -q "1080/tcp"; then
        local socks_rule=$(ufw status | grep "1080/tcp" | awk '{print $3}')
        ufw allow from "$socks_rule" to any port 1080 proto tcp
    fi

    if [[ "$mode" == "full" ]]; then
        ufw allow 80/tcp
        ufw allow 443/tcp
        info "Открыты порты: $ssh_port (SSH), 80, 443"
    elif [[ "$mode" == "relay" ]]; then
        ufw allow "$inbound_port/tcp"
        info "Открыты порты: $ssh_port (SSH), $inbound_port (Xray)"
    fi

    ufw --force enable

    # Блокировка IPv6 входящих
    cat > /etc/ufw/before6.rules <<'EOF'
*filter
:ufw6-before-input - [0:0]
-A ufw6-before-input -j DROP
COMMIT
EOF
    ufw reload
    info "UFW активирован"
}

# fail2ban (усиленный)
setup_fail2ban() {
    local mode=$1
    section "Настройка fail2ban"
    
    cat > /etc/fail2ban/jail.local <<'EOF'
[sshd]
enabled = true
port = ssh
filter = sshd
logpath = /var/log/auth.log
maxretry = 3
bantime = 7200
findtime = 600
EOF

    if [[ "$mode" == "full" ]]; then
        mkdir -p /var/log/nginx
        touch /var/log/nginx/error.log /var/log/nginx/access.log
        cat >> /etc/fail2ban/jail.local <<'EOF'

[nginx-http-auth]
enabled = true
port = http,https
filter = nginx-http-auth
logpath = /var/log/nginx/error.log
maxretry = 3
bantime = 3600
findtime = 300

[nginx-botsearch]
enabled = true
port = http,https
filter = nginx-botsearch
logpath = /var/log/nginx/access.log
maxretry = 2
bantime = 86400
findtime = 300
EOF
    fi

    touch /var/log/auth.log
    systemctl enable fail2ban
    systemctl restart fail2ban
    info "fail2ban запущен"
}

# BBR
setup_bbr() {
    section "Включение BBR"
    cat > /etc/sysctl.d/99-bbr.conf <<'EOF'
net.core.default_qdisc=fq
net.ipv4.tcp_congestion_control=bbr
net.core.rmem_max=67108864
net.core.wmem_max=67108864
net.ipv4.tcp_rmem=4096 87380 67108864
net.ipv4.tcp_wmem=4096 65536 67108864
EOF
    sysctl --system > /dev/null 2>&1
    info "BBR включён"
}

# MSS Clamp
setup_mss_clamp() {
    section "Настройка TCP MSS Clamp"
    if ! iptables -t mangle -C POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1460 2>/dev/null; then
        iptables -t mangle -A POSTROUTING -p tcp --tcp-flags SYN,RST SYN -j TCPMSS --set-mss 1460
    fi
    if command -v netfilter-persistent &>/dev/null; then
        netfilter-persistent save
    fi
    info "TCP MSS Clamp настроен"
}

# Автообновления
setup_auto_updates() {
    section "Настройка автообновлений"
    $PKG_INSTALL unattended-upgrades
    cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
    systemctl restart unattended-upgrades
    info "Автообновления включены"
}

# Скачивание geo-файлов
download_geo_files() {
    section "Загрузка geo-файлов"
    if ! command -v curl &>/dev/null; then
        $PKG_INSTALL curl
    fi
    local geo_dir="/usr/local/share/xray"
    mkdir -p "$geo_dir"

    GEOIP_OK=false
    GEOSITE_OK=false

    curl -L --max-time 300 -o "$geo_dir/geoip.dat" \
        "https://github.com/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat" && \
        { info "geoip.dat загружен"; GEOIP_OK=true; } || warning "Ошибка загрузки geoip.dat"

    curl -L --max-time 300 -o "$geo_dir/geosite.dat" \
        "https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat" && \
        { info "geosite.dat загружен"; GEOSITE_OK=true; } || warning "Ошибка загрузки geosite.dat"
}

# Автообновление geo-файлов
setup_geo_autoupdate() {
    section "Настройка автообновления geo"
    cat > /usr/local/bin/update-geodata.sh <<'UEOF'
#!/bin/bash
GEO_DIR="/usr/local/share/xray"
mkdir -p "$GEO_DIR"

# Проверяем SOCKS5-прокси
SOCKS_HOST=""
if [[ -n "${http_proxy:-}" ]] && [[ "${http_proxy}" == socks5h://* ]]; then
    SOCKS_HOST="${http_proxy#socks5h://}"
fi

if [[ -n "$SOCKS_HOST" ]]; then
    curl -L --max-time 300 --socks5-hostname "$SOCKS_HOST" -o "$GEO_DIR/geoip.dat" \
        "https://github.com/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat"
    curl -L --max-time 300 --socks5-hostname "$SOCKS_HOST" -o "$GEO_DIR/geosite.dat" \
        "https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat"
else
    curl -L --max-time 300 -o "$GEO_DIR/geoip.dat" \
        "https://github.com/hydraponique/roscomvpn-geoip/releases/latest/download/geoip.dat"
    curl -L --max-time 300 -o "$GEO_DIR/geosite.dat" \
        "https://github.com/hydraponique/roscomvpn-geosite/releases/latest/download/geosite.dat"
fi

systemctl restart x-ui 2>/dev/null || true
UEOF
    chmod +x /usr/local/bin/update-geodata.sh
    
    # Добавляем cron-задачу напрямую
    local cron_entry="0 3 * * 6 /usr/local/bin/update-geodata.sh"
    if ! crontab -l 2>/dev/null | grep -qF "update-geodata.sh"; then
        (crontab -l 2>/dev/null || true; echo "$cron_entry") | crontab - 2>/dev/null || {
            # Если crontab - не сработал — пишем в файл напрямую
            local cron_file="/var/spool/cron/crontabs/root"
            mkdir -p /var/spool/cron/crontabs
            grep -qF "update-geodata.sh" "$cron_file" 2>/dev/null || echo "$cron_entry" >> "$cron_file"
            chmod 600 "$cron_file"
        }
    fi
    info "Автообновление geo включено (еженедельно)"
}

# WARP
setup_warp_relay() {
    section "Настройка WARP"
    local wgcf_url="https://github.com/ViRb3/wgcf/releases/download/v2.2.26/wgcf_2.2.26_linux_amd64"
    local wgcf_bin="/usr/local/bin/wgcf"

    if ! command -v "$wgcf_bin" &>/dev/null; then
        info "Скачиваем wgcf..."
        if ! curl -L --max-time 30 -o "$wgcf_bin" "$wgcf_url"; then
            warning "Не удалось скачать wgcf. WARP пропущен."
            return 1
        fi
        chmod +x "$wgcf_bin"
    fi

    cd /tmp
    local ok=false

    # Пробуем сгенерировать из существующего аккаунта
    if [[ -f wgcf-account.toml ]]; then
        info "Найден существующий аккаунт WARP, генерируем ключи..."
        for i in {1..3}; do
            if "$wgcf_bin" generate 2>/dev/null; then ok=true; break
            else sleep 10; fi
        done
    fi

    # Если нет аккаунта или генерация не удалась — регистрируем заново
    if ! $ok; then
        info "Регистрируем новый аккаунт WARP..."
        rm -f wgcf-account.toml wgcf-profile.conf
        for i in {1..3}; do
            if yes | "$wgcf_bin" register 2>/dev/null; then ok=true; break
            else sleep 15; fi
        done
        
        # Если register упал, но файл аккаунта создался — пробуем generate
        if ! $ok && [[ -f wgcf-account.toml ]]; then
            info "Аккаунт создан, генерируем ключи..."
            ok=false
            for i in {1..3}; do
                if "$wgcf_bin" generate 2>/dev/null; then ok=true; break
                else sleep 10; fi
            done
        elif ! $ok; then
            warning "Не удалось зарегистрировать WARP."; return 1
        fi
        
        # Если после регистрации нужно сгенерировать
        if $ok && [[ ! -f wgcf-profile.conf ]]; then
            ok=false
            for i in {1..3}; do
                if "$wgcf_bin" generate 2>/dev/null; then ok=true; break
                else sleep 10; fi
            done
            if ! $ok; then warning "Не удалось сгенерировать конфиг WARP."; return 1; fi
        fi
    fi

    [[ ! -f "/tmp/wgcf-profile.conf" ]] && { warning "Конфиг не найден."; return 1; }

    local private_key public_key
    private_key=$(grep "PrivateKey" /tmp/wgcf-profile.conf | awk '{print $3}')
    public_key=$(grep "PublicKey" /tmp/wgcf-profile.conf | awk '{print $3}')

    if [[ -z "$private_key" || -z "$public_key" ]]; then
        warning "Ключи не извлечены."; return 1
    fi

    local xray_config="/usr/local/etc/xray/config.json"
    if [[ -f "$xray_config" ]]; then
        sed -i "s|\"secretKey\": \"[^\"]*\"|\"secretKey\": \"$private_key\"|" "$xray_config"
        sed -i "s|\"publicKey\": \"[^\"]*\"|\"publicKey\": \"$public_key\"|" "$xray_config"
        info "Ключи WARP вставлены в конфиг Xray"
    fi
}
# Установка Xray
install_xray_relay() {
    section "Установка Xray"
    bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install
    info "Xray установлен"
}

# Конфиг Xray для Сервера 2
configure_xray_relay() {
    local inbound_port=$1
    local secret_path=$2
    section "Конфигурация Xray (relay)"
    mkdir -p "$DIR_REVERSE_PROXY"

    local uuid
    uuid=$(generate_uuid)
    mkdir -p /usr/local/etc/xray/

    cat > /usr/local/etc/xray/config.json <<EOF
{
  "log": { "loglevel": "warning", "access": "/var/log/xray/access.log", "error": "/var/log/xray/error.log" },
  "inbounds": [{
    "tag": "cascade-in",
    "port": $inbound_port,
    "protocol": "vless",
    "settings": { "clients": [{ "id": "$uuid", "flow": "" }], "decryption": "none" },
    "streamSettings": {
      "network": "xhttp",
      "xhttpSettings": {
        "path": "$secret_path",
        "host": "",
        "mode": "packet-up",
        "scMaxBufferedPosts": 30,
        "scMaxEachPostBytes": "1000000-2000000",
        "noSSEHeader": false,
        "xPaddingBytes": "100-1000"
      },
      "sockopt": {
        "tcpFastOpen": false,
        "tcpNoDelay": true,
        "tcpMaxSeg": 1440,
        "tcpCongestion": "bbr",
        "tcpMptcp": false,
        "tcpKeepAliveIdle": 60,
        "tcpKeepAliveInterval": 30,
        "tcpUserTimeout": 10000,
        "tcpWindowClamp": 600
      }
    },
    "sniffing": { "enabled": true, "destOverride": ["http", "tls"], "routeOnly": true }
  }],
  "outbounds": [
    { "tag": "direct", "protocol": "freedom", "settings": { "domainStrategy": "UseIP" } },
    { "tag": "warp", "protocol": "wireguard", "settings": { "secretKey": "WARP_SECRET_KEY_PLACEHOLDER", "address": ["172.16.0.2/32"], "peers": [{ "publicKey": "WARP_PUBLIC_KEY_PLACEHOLDER", "endpoint": "engage.cloudflareclient.com:2408" }], "mtu": 1280 } },
    { "tag": "blocked", "protocol": "blackhole", "settings": {} }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      { "type": "field", "domain": ["domain:ifconfig.me","domain:ipinfo.io","domain:2ip.ru","domain:ipify.org","domain:icanhazip.com"], "outboundTag": "blocked" },
      { "type": "field", "domain": ["geosite:openai","domain:gemini.google.com","domain:claude.ai","domain:copilot.microsoft.com"], "outboundTag": "warp" },
      { "type": "field", "network": "tcp,udp", "outboundTag": "direct" }
    ]
  }
}
EOF

    mkdir -p "$DIR_REVERSE_PROXY"
    local public_ip
    public_ip=$(get_public_ip)
    cat > "$DIR_REVERSE_PROXY/server2_params.conf" <<EOF
SERVER2_IP=$public_ip
SERVER2_PORT=$inbound_port
SERVER2_PATH=$secret_path
SERVER2_UUID=$uuid
EOF
chmod 600 "$DIR_REVERSE_PROXY/server2_params.conf"
    info "Параметры сохранены в $DIR_REVERSE_PROXY/server2_params.conf"
}

# Проверка Сервера 2
verify_relay() {
    section "Проверка установки"
    local ok=true

    if systemctl is-active --quiet xray; then
        info "✅ Xray запущен"
    else
        warning "❌ Xray не запущен"
        ok=false
    fi

    if ufw status | grep -q "Status: active"; then
        info "✅ UFW активен"
    else
        warning "❌ UFW не активен"
        ok=false
    fi

    if fail2ban-client status 2>/dev/null | grep -q "Number of jail"; then
        info "✅ fail2ban запущен"
    else
        warning "❌ fail2ban не запущен"
        ok=false
    fi

    if $ok; then
        info "Сервер 2 готов. Перезагрузка не требуется."
    else
        warning "Некоторые проверки не пройдены."
    fi
}

# Проверка наличия crontab
_check_crontab() {
    command -v crontab &>/dev/null || { info "Устанавливаем cron..."; $PKG_INSTALL cron; }
}

# Главная функция Сервера 2
run_relay_mode() {
    section "РЕЖИМ RELAY (Сервер 2 — Зарубежный)"

    check_root
    detect_os
    install_dependencies
    _check_crontab

    echo ""
    echo "Настройка зарубежного сервера как ретранслятора."
    echo "Будет установлен только Xray (без панели)."
    echo ""

    local inbound_port
    local suggested_port=$(random_port)
    printf "Порт для туннеля (диапазон: 1024-65535) [Enter = %s]: " "$suggested_port"
    read inbound_port || true
    [[ -z "$inbound_port" ]] && inbound_port=$suggested_port
    if [[ ! "$inbound_port" =~ ^[0-9]+$ ]] || [[ "$inbound_port" -lt 1024 ]] || [[ "$inbound_port" -gt 65535 ]]; then
        error "Некорректный порт (1024-65535)"
    fi
        if ss -tlnp 2>/dev/null | grep -q ":$inbound_port "; then
        warning "Порт $inbound_port уже занят. Это может вызвать конфликт."
    fi

    local secret_path
    printf "Секретный путь (напр. /v3/assets/updates) [Enter = сгенерировать]: "
    read secret_path || true
    [[ -z "$secret_path" ]] && secret_path="/$(random_string 12)"
    [[ "$secret_path" != /* ]] && secret_path="/$secret_path"

    echo ""
    info "Параметры:"
    echo "  Порт: $inbound_port"
    echo "  Путь: $secret_path"
    echo ""

    local confirm
    read -p "Продолжить? [Y/n]: " confirm
    confirm=${confirm:-y}
    [[ "${confirm,,}" != "y" ]] && error "Отменено"

    setup_bbr
    setup_ufw "relay" "$inbound_port"
    setup_fail2ban "relay"
    setup_auto_updates
    install_xray_relay
    configure_xray_relay "$inbound_port" "$secret_path"
    setup_warp_relay
    setup_mss_clamp

    chown -R root:root /usr/local/etc/xray/
    chmod 644 /usr/local/etc/xray/config.json

    systemctl enable xray
    systemctl restart xray

    # Финальный вывод
    local public_ip
    public_ip=$(get_public_ip)
    local client_uuid
    client_uuid=$(grep -o '"id": "[^"]*"' /usr/local/etc/xray/config.json | head -1 | cut -d'"' -f4)

    echo ""
    echo "============================================"
    echo "  СЕРВЕР 2 УСПЕШНО НАСТРОЕН"
    echo "============================================"
    echo "  IP Сервера 2:        $public_ip"
    echo "  Порт inbound:        $inbound_port"
    echo "  Секретный путь:      $secret_path"
    echo "  UUID:                $client_uuid"
    echo "============================================"
    echo "  Скопируйте эти данные. Они понадобятся"
    echo "  при запуске скрипта на Сервере 1 (РФ)."
    echo ""
    echo "  НАСТРОЙКА SSH-КЛЮЧЕЙ (рекомендуется):"
    echo "  1. На своём ПК сгенерируйте ключ (если ещё нет):"
    echo "     ssh-keygen -t ed25519"
    echo "  2. Скопируйте ключ на сервер:"
    echo "     ssh-copy-id root@$public_ip"
    echo "  3. Проверьте вход без пароля:"
    echo "     ssh root@$public_ip"
    echo "  4. После успешной проверки отключите вход по паролю:"
    echo "     sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config"
    echo "     sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config"
    echo "     sudo systemctl restart sshd"
    echo "  5. ОТКЛЮЧАТЬ ВХОД ПО ПАРОЛЮ ТОЛЬКО ПОСЛЕ ПРОВЕРКИ КЛЮЧА!"
    echo "============================================"
    echo ""

    verify_relay
}

# Установка Nginx (Сервер 1)
install_nginx_full() {
    section "Установка Nginx"
    curl -fsSL https://nginx.org/keys/nginx_signing.key | gpg --dearmor > /usr/share/keyrings/nginx-archive-keyring.gpg
    . /etc/os-release
    echo "deb [signed-by=/usr/share/keyrings/nginx-archive-keyring.gpg] http://nginx.org/packages/$ID $(lsb_release -cs) nginx" > /etc/apt/sources.list.d/nginx.list
    $PKG_UPDATE
    $PKG_INSTALL nginx
    systemctl enable nginx
    systemctl start nginx
    info "Nginx установлен"
}

# SSL-сертификаты
issue_certificates() {
    local domain=$1
    local email=$2
    local cf_token=$3
    section "Выпуск SSL-сертификатов"

    $PKG_INSTALL certbot python3-certbot-dns-cloudflare
    local creds="/etc/letsencrypt/.cloudflare.credentials"
    mkdir -p /etc/letsencrypt
    cat > "$creds" <<EOF
dns_cloudflare_api_token = $cf_token
EOF
    chmod 600 "$creds"

    # Временно отключаем SOCKS-прокси (certbot не поддерживает)
    local _http_proxy_backup="${http_proxy:-}"
    local _https_proxy_backup="${https_proxy:-}"
    unset http_proxy https_proxy

    certbot certonly --dns-cloudflare \
        --dns-cloudflare-credentials "$creds" \
        --dns-cloudflare-propagation-seconds 30 \
        --rsa-key-size 4096 \
        -d "$domain" -d "*.$domain" \
        --agree-tos -m "$email" \
        --cert-name "$domain" \
        --no-eff-email --non-interactive

    # Восстанавливаем прокси, если он был настроен
    if [[ -n "$_http_proxy_backup" ]]; then
        export http_proxy="$_http_proxy_backup"
        export https_proxy="$_https_proxy_backup"
    fi

    echo "renew_hook = systemctl reload nginx" >> "/etc/letsencrypt/renewal/$domain.conf"
    set +o pipefail
    (crontab -l 2>/dev/null; echo "0 5 1 */2 * certbot -q renew") | crontab -
    set -o pipefail
    info "Сертификаты выпущены"
}

# Конфиг Nginx (Сервер 1)
configure_nginx_full() {
    local domain=$1
    local secret_path=$2
    local server2_ip=$3
    local server2_port=$4
    local web_base_path=$5
    section "Конфигурация Nginx"

    mkdir -p /etc/nginx/stream-enabled/ /etc/nginx/locations/ /var/www/html/

    # Заглушка
    if [ ! -f /var/www/html/index.html ]; then
        cat > /var/www/html/index.html <<'EOF'
<!DOCTYPE html><html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width,initial-scale=1.0"><title>Site under maintenance</title><style>body{font-family:Arial,sans-serif;display:flex;justify-content:center;align-items:center;height:100vh;margin:0;background:#f5f5f5}h1{color:#333}</style></head><body><h1>We'll be back soon!</h1></body></html>
EOF
    fi

    local nginx_user
    nginx_user=$(id www-data &>/dev/null && echo "www-data" || echo "nginx")

    openssl dhparam -out /etc/nginx/dhparam.pem 2048

    cat > /etc/nginx/nginx.conf <<EOF
user $nginx_user;
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /var/run/nginx.pid;

events { worker_connections 1024; multi_accept on; }

http {
    server_names_hash_bucket_size 64;
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;
    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    keepalive_timeout 75s;

    log_format json_analytics escape=json '{'
        '"time_local":"\$time_local",'
        '"remote_addr":"\$remote_addr",'
        '"request":"\$request",'
        '"status":\$status,'
        '"user_agent":"\$http_user_agent"'
        '}';
    access_log /var/log/nginx/access.log json_analytics;

    add_header X-Content-Type-Options "nosniff" always;
    add_header X-Frame-Options "SAMEORIGIN" always;
    add_header Referrer-Policy "strict-origin-when-cross-origin" always;

    include /etc/nginx/conf.d/*.conf;
}
stream { include /etc/nginx/stream-enabled/*.conf; }
EOF

    cat > /etc/nginx/conf.d/default.conf <<EOF
server {
    listen 80 default_server;
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
}

server {
    listen 443 ssl http2;
    server_name $domain *.$domain;
    ssl_certificate /etc/letsencrypt/live/$domain/fullchain.pem;
    ssl_certificate_key /etc/letsencrypt/live/$domain/privkey.pem;
    ssl_trusted_certificate /etc/letsencrypt/live/$domain/chain.pem;
    ssl_dhparam /etc/nginx/dhparam.pem;
    ssl_protocols TLSv1.2 TLSv1.3;
    ssl_ciphers ECDHE-ECDSA-AES128-GCM-SHA256:ECDHE-RSA-AES128-GCM-SHA256:ECDHE-ECDSA-AES256-GCM-SHA384:ECDHE-RSA-AES256-GCM-SHA384:ECDHE-ECDSA-CHACHA20-POLY1305:ECDHE-RSA-CHACHA20-POLY1305;
    ssl_prefer_server_ciphers off;
    root /var/www/html;
    index index.html;
    location / { try_files \$uri \$uri/ =404; }
    proxy_intercept_errors on;
    error_page 400 401 403 404 502 = @fallback;
    location @fallback { return 301 https://\$host/; }
    include /etc/nginx/locations/*.conf;
}
EOF

    cat > /etc/nginx/locations/panel.conf <<EOF
location /$web_base_path {
    proxy_redirect off;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_pass http://127.0.0.1:2053/$web_base_path;
    break;
}
EOF

    cat > /etc/nginx/locations/xhttp.conf <<EOF
location $secret_path {
    proxy_redirect off;
    proxy_pass http://127.0.0.1:10000;
    proxy_http_version 1.1;
    proxy_request_buffering off;
    proxy_buffering off;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection "upgrade";
    proxy_read_timeout 1d;
    proxy_send_timeout 1d;
}
EOF

    if nginx -t; then
        systemctl restart nginx
        info "Nginx настроен"
    else
        error "Ошибка в конфигурации Nginx"
    fi
}

# Установка панели 3x-ui
install_xui_panel() {
    section "Установка панели 3x-ui"

    bash <(_curl -Ls https://raw.githubusercontent.com/mhsanaei/3x-ui/master/install.sh) v2.9.4

    # Привязка панели к localhost (чтобы не светилась в мир)
    local db_path="/etc/x-ui/x-ui.db"
    if [ -f "$db_path" ]; then
        sqlite3 "$db_path" "UPDATE settings SET value = '127.0.0.1' WHERE key = 'webListen';"
        systemctl restart x-ui
        info "Панель 3x-ui привязана к localhost (127.0.0.1)"
    else
        warning "База данных панели не найдена. Возможно, привязка к localhost не выполнена."
    fi
}

# Конфигурация Xray для Сервера 1 (каскад)
configure_xray_full() {
    local domain=$1
    local secret_path=$2
    local server2_ip=$3
    local server2_port=$4
    local server2_uuid=$5
    local web_base_path=$6

    section "Конфигурация Xray (full)"

    local uuid
    uuid=$(generate_uuid)
    # Сохраняем клиентский UUID для финального вывода
    mkdir -p "$DIR_REVERSE_PROXY"
    echo "$uuid" > "$DIR_REVERSE_PROXY/client_uuid.conf"
    chmod 600 "$DIR_REVERSE_PROXY/client_uuid.conf"

    # Обновляем inbound'ы и настройки через БД панели
    update_panel_db "$domain" "$secret_path" "$server2_ip" "$server2_port" "$server2_uuid" "$uuid" "$web_base_path"
}

# Обновление inbound'ов и настроек панели через БД
update_panel_db() {
    local domain=$1
    local secret_path=$2
    local server2_ip=$3
    local server2_port=$4
    local server2_uuid=$5
    local client_uuid=$6
    local web_base_path=$7

    local db_path="/etc/x-ui/x-ui.db"
    
    if [[ ! -f "$db_path" ]]; then
        warning "База данных панели не найдена. Пропускаем обновление inbound'ов."
        return 1
    fi

    local stream_settings
    stream_settings=$(cat <<STEOF
{
  "network": "xhttp",
  "security": "none",
  "xhttpSettings": {
    "path": "$secret_path",
    "host": "$domain",
    "mode": "packet-up",
    "scMaxBufferedPosts": 30,
    "scMaxEachPostBytes": "1000000-2000000",
    "noSSEHeader": false,
    "xPaddingBytes": "100-1000"
  },
  "sockopt": {
    "tcpFastOpen": false,
    "tcpNoDelay": true,
    "tcpMaxSeg": 1440,
    "tcpCongestion": "bbr",
    "tcpMptcp": false,
    "tcpKeepAliveIdle": 60,
    "tcpKeepAliveInterval": 30,
    "tcpUserTimeout": 10000,
    "tcpWindowClamp": 600
  }
}
STEOF
)

    local inbound_settings="{\"clients\":[{\"id\":\"$client_uuid\",\"flow\":\"\"}],\"decryption\":\"none\"}"
    local sniffing='{"enabled":true,"destOverride":["http","tls"],"routeOnly":true}'

    sqlite3 "$db_path" "DELETE FROM inbounds WHERE port = 10000;"
    sqlite3 "$db_path" "INSERT INTO inbounds (remark, port, protocol, settings, stream_settings, sniffing, listen) VALUES ('xhttp-cascade', 10000, 'vless', '$inbound_settings', '$stream_settings', '$sniffing', '127.0.0.1');"
    sqlite3 "$db_path" "UPDATE settings SET value = '/${web_base_path}/' WHERE key = 'webBasePath';"

    local xray_template
    xray_template=$(cat <<XEOF
{
  "outbounds": [
    {
      "tag": "direct",
      "protocol": "freedom",
      "settings": {"domainStrategy": "UseIPv4"}
    },
    {
      "tag": "cascade",
      "protocol": "vless",
      "settings": {
        "vnext": [{
          "address": "$server2_ip",
          "port": $server2_port,
          "users": [{"id": "$server2_uuid", "flow": "", "encryption": "none"}]
        }]
      },
      "streamSettings": {
        "network": "xhttp",
        "fingerprint": "chrome",
        "xhttpSettings": {
          "path": "$secret_path",
          "host": "",
          "mode": "packet-up",
          "scMaxBufferedPosts": 30,
          "scMaxEachPostBytes": "1000000-2000000",
          "noSSEHeader": false,
          "xPaddingBytes": "100-1000"
        },
        "sockopt": {
          "tcpFastOpen": false,
          "tcpNoDelay": true,
          "tcpMaxSeg": 1440,
          "tcpCongestion": "bbr",
          "tcpMptcp": false,
          "tcpKeepAliveIdle": 60,
          "tcpKeepAliveInterval": 30,
          "tcpUserTimeout": 10000,
          "tcpWindowClamp": 600
        }
      }
    },
    {
      "tag": "blocked",
      "protocol": "blackhole",
      "settings": {}
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {"type": "field", "domain": ["geosite:category-ads","geosite:win-spy"], "outboundTag": "blocked"},
      {"type": "field", "domain": ["domain:ifconfig.me","domain:ipinfo.io","domain:2ip.ru","domain:ipify.org","domain:icanhazip.com"], "outboundTag": "blocked"},
      {"type": "field", "ip": ["geoip:private"], "outboundTag": "direct"},
      {"type": "field", "ip": ["geoip:direct"], "outboundTag": "direct"},
      {"type": "field", "domain": ["geosite:category-ru","geosite:whitelist"], "outboundTag": "direct"},
      {"type": "field", "domain": ["geosite:apple","geosite:microsoft","geosite:steam","geosite:epic-games","geosite:riot","geosite:escapefromtarkov","geosite:faceit","geosite:pinterest","geosite:twitch"], "outboundTag": "direct"},
      {"type": "field", "domain": ["geosite:youtube","geosite:telegram","geosite:github","geosite:google-play"], "outboundTag": "cascade"},
      {"type": "field", "network": "tcp,udp", "outboundTag": "cascade"}
    ]
  }
}
XEOF
)
    sqlite3 "$db_path" "UPDATE settings SET value = '$xray_template' WHERE key = 'xrayTemplateConfig';"

    info "Inbound и настройки панели обновлены через БД"
}

# Проверка Сервера 1
verify_full() {
    section "Проверка установки"
    local ok=true

    if systemctl is-active --quiet nginx; then
        info "✅ Nginx запущен"
    else
        warning "❌ Nginx не запущен"
        ok=false
    fi

    if ss -tlnp 2>/dev/null | grep -q ":10000 "; then
        info "✅ Xray слушает порт 10000"
    else
        warning "❌ Xray не слушает порт 10000"
        ok=false
    fi

    if systemctl is-active --quiet x-ui; then
        info "✅ Панель 3x-ui запущена"
    else
        warning "❌ Панель не запущена"
        ok=false
    fi

    if ufw status | grep -q "Status: active"; then
        info "✅ UFW активен"
    else
        warning "❌ UFW не активен"
        ok=false
    fi

    if fail2ban-client status 2>/dev/null | grep -q "Number of jail"; then
        info "✅ fail2ban запущен"
    else
        warning "❌ fail2ban не запущен"
        ok=false
    fi

    if $ok; then
        info "Сервер 1 готов. Перезагрузка не требуется."
    else
        warning "Некоторые проверки не пройдены."
    fi
}

# Главная функция Сервера 1
run_full_mode() {
    section "РЕЖИМ FULL (Сервер 1 — РФ)"

    check_root
    detect_os
    install_dependencies
    _check_crontab

    echo ""
    echo "Настройка российского сервера как точки входа."
    echo ""

    local domain=""
    while [[ -z "$domain" ]]; do
        read -p "Ваш домен (например, example.ru) [обязательно]. Для выхода из процесса установки оставьте поле пустым и нажмите Enter: " domain
        [[ -z "$domain" ]] && error "Домен обязателен. Установка прервана."
    done

    local email=""
    while [[ -z "$email" ]]; do
        read -p "Email Cloudflare [обязательно]. Для выхода оставьте поле пустым и нажмите Enter: " email
        [[ -z "$email" ]] && error "Email обязателен. Установка прервана."
    done

    local cf_token=""
    while [[ -z "$cf_token" ]]; do
        read -p "API-ключ Cloudflare (Global API Key) [обязательно]. Для выхода оставьте поле пустым и нажмите Enter: " cf_token
        [[ -z "$cf_token" ]] && error "API-ключ Cloudflare обязателен. Установка прервана."
    done

    local web_base_path
    printf "Путь к панели управления без слэш / (напр. MyAdmin) [Enter = сгенерировать]: "
    read web_base_path || true
    [[ -z "$web_base_path" ]] && web_base_path=$(random_string 12)
    web_base_path="${web_base_path#/}"

    echo ""
    echo "Введите параметры зарубежного сервера (Сервер 2):"
    echo ""

    local server2_ip=""
    while [[ -z "$server2_ip" ]]; do
        read -p "IP-адрес Сервера 2 [обязательно]. Для выхода оставьте поле пустым и нажмите Enter: " server2_ip
        [[ -z "$server2_ip" ]] && error "IP-адрес обязателен. Установка прервана."
    done

    local server2_port=""
    while [[ -z "$server2_port" ]]; do
        read -p "Порт inbound Сервера 2 [обязательно]. Для выхода оставьте поле пустым и нажмите Enter: " server2_port
        [[ -z "$server2_port" ]] && error "Порт обязателен. Установка прервана."
    done

    local server2_uuid=""
    while [[ -z "$server2_uuid" ]]; do
        read -p "UUID Сервера 2 [обязательно]. Для выхода оставьте поле пустым и нажмите Enter: " server2_uuid
        [[ -z "$server2_uuid" ]] && error "UUID обязателен. Установка прервана."
    done

    local secret_path=""
    while [[ -z "$secret_path" ]]; do
        read -p "Секретный путь (такой же, как на Сервере 2) [обязательно]. Для выхода оставьте поле пустым и нажмите Enter: " secret_path
        [[ -z "$secret_path" ]] && error "Секретный путь обязателен. Установка прервана."
    done
    [[ "$secret_path" != /* ]] && secret_path="/$secret_path"

    echo ""
    info "Параметры:"
    echo "  Домен: $domain"
    echo "  Панель: /$web_base_path"
    echo "  Сервер 2: $server2_ip:$server2_port"
    echo "  Путь: $secret_path"
    echo ""

    local confirm
    read -p "Продолжить? [Y/n]: " confirm
    confirm=${confirm:-y}
    [[ "${confirm,,}" != "y" ]] && error "Отменено"

    setup_bbr
    setup_ufw "full"
    setup_fail2ban "full"
    setup_auto_updates
    install_nginx_full
    install_xui_panel
    issue_certificates "$domain" "$email" "$cf_token"
    download_geo_files
    setup_geo_autoupdate
    configure_xray_full "$domain" "$secret_path" "$server2_ip" "$server2_port" "$server2_uuid" "$web_base_path"
    configure_nginx_full "$domain" "$secret_path" "$server2_ip" "$server2_port" "$web_base_path"
    setup_mss_clamp
    systemctl enable x-ui
    systemctl restart x-ui
    systemctl restart nginx
    verify_full

    # Финальный вывод
        # Предложить перекачать geo-файлы, если что-то не загрузилось
    if ! $GEOIP_OK || ! $GEOSITE_OK; then
        warning "Некоторые geo-файлы не загрузились. Маршрутизация РФ может работать некорректно."
        read -p "Попробовать загрузить geo-файлы заново? [Y/n]: " rego
        rego=${rego:-y}
        if [[ "${rego,,}" == "y" ]]; then
            download_geo_files
            systemctl restart x-ui 2>/dev/null || true
        fi
    fi
    local client_uuid
    client_uuid=$(cat "$DIR_REVERSE_PROXY/client_uuid.conf" 2>/dev/null || echo "не найден")
    local server_ip
    server_ip=$(get_public_ip)

    echo ""
    echo "============================================"
    echo "  УСТАНОВКА ЗАВЕРШЕНА"
    echo "============================================"
    echo "  Домен: https://$domain"
    local panel_port
    panel_port=$(grep -oP '"port":\s*\K\d+' /etc/x-ui/x-ui.db 2>/dev/null | head -1 || echo "2053")
    echo "  Панель: http://127.0.0.1:$panel_port/$web_base_path"
    echo "         (через SSH-туннель)"
    echo ""
    echo "  ДОСТУП К ПАНЕЛИ:"
    echo "  Выполните на своём ПК:"
    echo "  ssh -L $panel_port:127.0.0.1:$panel_port root@$server_ip"
    echo "  Затем откройте: http://127.0.0.1:$panel_port/$web_base_path"
    echo ""
    echo "  ДАННЫЕ ДЛЯ КЛИЕНТА (v2rayN/Nekobox):"
    echo "  Адрес: $domain"
    echo "  Порт: 443"
    echo "  Путь: $secret_path"
    echo "  UUID: $client_uuid"
    echo "  Тип: VLESS + XHTTP"
    echo "============================================"
    echo ""
    echo "  ПОСЛЕ УСТАНОВКИ:"
    echo "  НАСТРОЙКА SSH-КЛЮЧЕЙ (рекомендуется):"
    echo "  1. На своём ПК сгенерируйте ключ (если ещё нет):"
    echo "     ssh-keygen -t ed25519"
    echo "  2. Скопируйте ключ на сервер:"
    echo "     ssh-copy-id root@$server_ip"
    echo "  3. Проверьте вход без пароля:"
    echo "     ssh root@$server_ip"
    echo "  4. После успешной проверки отключите вход по паролю:"
    echo "     sudo sed -i 's/^#PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config"
    echo "     sudo sed -i 's/^PasswordAuthentication yes/PasswordAuthentication no/' /etc/ssh/sshd_config"
    echo "     sudo systemctl restart sshd"
    echo "  5. ОТКЛЮЧАТЬ ВХОД ПО ПАРОЛЮ ТОЛЬКО ПОСЛЕ ПРОВЕРКИ КЛЮЧА!"
    echo ""
    echo "============================================"
    echo ""
    echo "  ПОСЛЕ НАСТРОЙКИ SSH-КЛЮЧЕЙ:"    
    echo "  1. Проверьте сервер через ByeByeVPN:"
    echo "     https://github.com/pwnnex/ByeByeVPN"
    echo "  2. Настройте клиент строго по инструкции"
    echo "  3. Включите Always-On VPN на устройстве"
    echo "============================================"
}

# Главное меню
main_menu() {
    clear
    echo ""
    echo "============================================"
    echo "  REVERSE PROXY FORK v$VERSION"
    echo "  XHTTP + Cascade (full/relay)"
    echo "============================================"
    echo ""
    echo "  1. Сервер 1 (РФ) — полная установка"
    echo "     Nginx, SSL, панель, сайт-заглушка, каскад"
    echo ""
    echo "  2. Сервер 2 (Зарубежный) — ретранслятор"
    echo "     Только Xray (без панели, без Nginx)"
    echo ""
    echo "  0. Выход"
    echo ""

    local choice
    read -p "Ваш выбор (0-2): " choice

    case $choice in
        1) run_full_mode ;;
        2) run_relay_mode ;;
        0) info "Выход."; exit 0 ;;
        *) error "Неверный выбор." ;;
    esac
}

# Обработка аргументов командной строки
if [[ $# -gt 0 ]]; then
    case "$1" in
        --mode)
            case "$2" in
                full) run_full_mode ;;
                relay) run_relay_mode ;;
                *) error "Неверный режим. Используйте: --mode full | --mode relay" ;;
            esac
            ;;
        --help|-h)
            echo "Reverse Proxy Fork v$VERSION"
            echo "Запуск: bash $0 [--mode full|relay]"
            exit 0
            ;;
        *) error "Неверный аргумент. Используйте --help" ;;
    esac
else
    main_menu
fi
