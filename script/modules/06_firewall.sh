#!/bin/bash
# lib/06_firewall.sh — Настройка брандмауэра через UFW или iptables

# === Глобальные переменные ===
: "${PROJECT_ROOT:=/opt}"
: "${TEMPLATE_DIR:=${PROJECT_ROOT}/template}"

# === Главная функция ===
firewall_config() {
    log "INFO" "Starting firewall configuration..."

    if command -v ufw &>/dev/null; then
        firewall_setup_ufw
    else
        firewall_setup_iptables
    fi

    log "INFO" "Firewall configuration complete."
}

# === Настройка через UFW ===
firewall_setup_ufw() {
    log "INFO" "UFW detected. Configuring rules..."
    local before_rules_file="/etc/ufw/before.rules"

    # Включаем UFW, если он выключен
    if ufw status 2>/dev/null | grep -q "Status: inactive"; then
        log "DEBUG" "UFW inactive. Enabling..."
        ufw --force enable
    fi

    # Сброс существующих правил, если активен
    if ufw status 2>/dev/null | grep -q "active"; then
        if ufw status numbered | grep -q '[0-9]'; then
            ufw --force reset
            log "DEBUG" "UFW rules reset."
        else
            log "DEBUG" "UFW already clean."
        fi
    fi

    # Установка политик по умолчанию
    ufw default deny incoming || exit_error "Failed to set default policy for incoming."
    ufw default allow outgoing || exit_error "Failed to set default policy for outgoing."
    log "DEBUG" "Default policies applied."

    # Открываем порты из переменных окружения
    declare -A ports
    firewall_extract_ports ports

    for port in "${!ports[@]}"; do
        ufw allow "$port"/tcp comment "${ports[$port]}" || exit_error "Failed to allow port $port."
        log "DEBUG" "UFW allowed port $port (${ports[$port]})."
    done

    # Добавление 443 отдельно (если не задан)
    if [[ -z "${ports[443]:-}" ]]; then
        ufw allow 443/tcp comment "HTTPS"
        ufw allow 443/udp comment "QUIC"
        log "DEBUG" "HTTPS/QUIC ports allowed."
    fi

    # Добавление 80 отдельно (если не задан)
    if [[ -z "${ports[80]:-}" ]]; then
        ufw allow 80/tcp comment "HTTP"
        log "DEBUG" "HTTP ports allowed."
    fi

    # Бэкапим before.rules перед редактированием
    backup_file "$before_rules_file"

    # Убеждаемся, что секция *filter существует
    if ! grep -q "^*filter" "$before_rules_file"; then
        echo -e "*filter\n:ufw-before-input - [0:0]\n:ufw-before-output - [0:0]\n:ufw-before-forward - [0:0]\nCOMMIT" >> "$before_rules_file"
        log "DEBUG" "Created *filter section in $before_rules_file."
    fi

    # Добавляем защиту от нестандартных TCP-флагов
    firewall_add_tcp_flags_protection "$before_rules_file"

    # Комментируем правила ICMP
    firewall_comment_icmp_accepts "$before_rules_file"

    # Перезапускаем UFW
    ufw --force enable
    ufw --force reload
    log "INFO" "UFW rules applied."

    # Показываем активные правила
    ufw status verbose
}

# === Настройка через iptables ===
firewall_setup_iptables() {
    log "WARN" "UFW not found. Falling back to iptables."

    # Проверяем наличие iptables
    command -v iptables &>/dev/null || exit_error "iptables not found."

    # Сброс всех правил
    iptables -F && iptables -X && iptables -Z
    iptables -t nat -F && iptables -t mangle -F
    if command -v ip6tables &>/dev/null; then
        ip6tables -F && ip6tables -X && ip6tables -Z
        ip6tables -t nat -F && ip6tables -t mangle -F
    fi
    log "DEBUG" "All iptables chains flushed."

    # Устанавливаем политики безопасности
    iptables -P INPUT DROP
    iptables -P FORWARD DROP
    iptables -P OUTPUT ACCEPT
    if command -v ip6tables &>/dev/null; then
        ip6tables -P INPUT DROP
        ip6tables -P FORWARD DROP
        ip6tables -P OUTPUT ACCEPT
    fi
    log "DEBUG" "Default iptables policies set."

    # Разрешаем локальный трафик
    iptables -A INPUT -i lo -j ACCEPT
    command -v ip6tables &>/dev/null && ip6tables -A INPUT -i lo -j ACCEPT

    # Разрешаем ESTABLISHED,RELATED
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    command -v ip6tables &>/dev/null && ip6tables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    log "DEBUG" "Allowed loopback and established connections."

    # Открываем порты из окружения
    declare -A ports
    firewall_extract_ports ports

    for port in "${!ports[@]}"; do
        iptables -A INPUT -p tcp --dport "$port" -j ACCEPT
        command -v ip6tables &>/dev/null && ip6tables -A INPUT -p tcp --dport "$port" -j ACCEPT
        log "DEBUG" "iptables allowed port $port (${ports[$port]})."
    done

    # Разрешаем 443, если не задан явно
    if [[ -z "${ports[443]:-}" ]]; then
        iptables -A INPUT -p tcp --dport 443 -j ACCEPT
        iptables -A INPUT -p udp --dport 443 -j ACCEPT
        command -v ip6tables &>/dev/null && {
            ip6tables -A INPUT -p tcp --dport 443 -j ACCEPT
            ip6tables -A INPUT -p udp --dport 443 -j ACCEPT
        }
        log "DEBUG" "iptables allowed HTTPS/QUIC."
    fi

    # Разрешаем 80, если не задан явно — HTTP
    if [[ -z "${ports[80]:-}" ]]; then
        iptables -A INPUT -p tcp --dport 80 -j ACCEPT
        command -v ip6tables &>/dev/null && ip6tables -A INPUT -p tcp --dport 80 -j ACCEPT
        log "DEBUG" "iptables allowed HTTP."
    fi

    # Добавляем защиту TCP-флагов
    firewall_add_tcp_flags_protection_iptables

    # Запрещаем ICMP
    # --- ICMP (IPv4) ---

    # Разрешаем системные типы (PMTU, TTL)
    iptables -A INPUT -p icmp --icmp-type fragmentation-needed -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type time-exceeded -j ACCEPT
    iptables -A INPUT -p icmp --icmp-type destination-unreachable -j ACCEPT

    # Рубим ping, чтобы сервер не пинговался
    iptables -A INPUT -p icmp --icmp-type echo-request -j DROP

    # Остальные ICMP попадают под политику (INPUT = DROP), можно не трогать
    log "DEBUG" "ICMP hardened: system types allowed, echo-request dropped."

    # --- ICMPv6 (если нужен) ---
    if command -v ip6tables &>/dev/null; then
        ip6tables -A INPUT -p ipv6-icmp --icmpv6-type packet-too-big -j ACCEPT
        ip6tables -A INPUT -p ipv6-icmp --icmpv6-type time-exceeded -j ACCEPT
        ip6tables -A INPUT -p ipv6-icmp --icmpv6-type destination-unreachable -j ACCEPT

        ip6tables -A INPUT -p ipv6-icmp --icmpv6-type echo-request -j DROP

        log "DEBUG" "IPv6 ICMP hardened."
    fi
    
    command -v ip6tables &>/dev/null && ip6tables -A INPUT -p ipv6-icmp -j DROP
    log "DEBUG" "Blocked all ICMP requests."

    # Логируем блокировки
    iptables -A INPUT -j LOG --log-prefix "[BLOCKED] " --log-level 4
    command -v ip6tables &>/dev/null && ip6tables -A INPUT -j LOG --log-prefix "[BLOCKED] " --log-level 4
    log "DEBUG" "Logging enabled for blocked packets."

    # Сохраняем правила
    iptables-save > /etc/iptables/rules.v4
    command -v ip6tables &>/dev/null && ip6tables-save > /etc/iptables/rules.v6
    log "OK" "iptables rules saved."

    # Создаём systemd unit для восстановления
    firewall_create_restore_unit
}

# === Парсинг переменных окружения вида port_remote_X и PORT_REMOTE ===
firewall_extract_ports() {
    local -n result=$1
    for var in $(compgen -v); do
        # приводим имя переменной к нижнему регистру для нечувствительного поиска
        local var_lc="${var,,}"
        if [[ $var_lc == *port_remote* ]]; then
            local value="${!var}"
            [[ -n $value ]] && result["$value"]="$var"
        fi
    done
}

# === Добавление TCP protection правил в before.rules (UFW) ===
firewall_add_tcp_flags_protection() {
    local rules_file="$1"
    local rules=(
        "-A ufw-before-input -p tcp --tcp-flags FIN,PSH,URG FIN,PSH,URG -j DROP"
        "-A ufw-before-input -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP"
        "-A ufw-before-input -p tcp --tcp-flags SYN,RST SYN,RST -j DROP"
        "-A ufw-before-input -p tcp --tcp-flags FIN,RST FIN,RST -j DROP"
        "-A ufw-before-input -p tcp --tcp-flags ACK,FIN FIN -j DROP"
        "-A ufw-before-input -p tcp --tcp-flags ACK,PSH PSH -j DROP"
        "-A ufw-before-input -p tcp --tcp-flags ACK,URG URG -j DROP"
    )
    for rule in "${rules[@]}"; do
        sed -i "/$(echo $rule | sed 's/[]\/()$*.^|[]/\\&/g')/d" "$rules_file"
        sed -i "/^COMMIT/i $rule" "$rules_file"
        log "DEBUG" "Added UFW TCP protection rule: $rule"
    done
}

# === Защита TCP-флагов в iptables ===
firewall_add_tcp_flags_protection_iptables() {
    for table in iptables ip6tables; do
        command -v "$table" &>/dev/null || continue
        "$table" -A INPUT -p tcp --tcp-flags FIN,PSH,URG FIN,PSH,URG -j DROP
        "$table" -A INPUT -p tcp --tcp-flags SYN,FIN SYN,FIN -j DROP
        "$table" -A INPUT -p tcp --tcp-flags SYN,RST SYN,RST -j DROP
        "$table" -A INPUT -p tcp --tcp-flags FIN,RST FIN,RST -j DROP
        "$table" -A INPUT -p tcp --tcp-flags ACK,FIN FIN -j DROP
        "$table" -A INPUT -p tcp --tcp-flags ACK,PSH PSH -j DROP
        "$table" -A INPUT -p tcp --tcp-flags ACK,URG URG -j DROP
        log "DEBUG" "Added iptables TCP protection (via $table)"
    done
}

# === Комментирование определённых ICMP правил в before.rules ===
firewall_comment_icmp_accepts() {
    local file="$1"
    local patterns=(
        # "-A ufw-before-input -p icmp --icmp-type destination-unreachable -j ACCEPT"
        # "-A ufw-before-input -p icmp --icmp-type time-exceeded -j ACCEPT"
        # "-A ufw-before-input -p icmp --icmp-type parameter-problem -j ACCEPT"
        "-A ufw-before-input -p icmp --icmp-type echo-request -j ACCEPT"
        # "-A ufw-before-forward -p icmp --icmp-type destination-unreachable -j ACCEPT"
        # "-A ufw-before-forward -p icmp --icmp-type time-exceeded -j ACCEPT"
        # "-A ufw-before-forward -p icmp --icmp-type parameter-problem -j ACCEPT"
        "-A ufw-before-forward -p icmp --icmp-type echo-request -j ACCEPT"
    )
    for pattern in "${patterns[@]}"; do
        sed -i "/$(echo $pattern | sed 's/[]\/()$*.^|[]/\\&/g')/s/^/#/" "$file"
        log "DEBUG" "Commented ICMP rule: $pattern"
    done
}

# === Создание systemd-юнита для восстановления iptables ===
firewall_create_restore_unit() {
    local unit_file="/etc/systemd/system/iptables-restore.service"
    cat > "$unit_file" <<EOF
[Unit]
Description=Restore iptables rules
Before=network.target

[Service]
Type=oneshot
ExecStart=/sbin/iptables-restore < /etc/iptables/rules.v4
ExecStart=/sbin/ip6tables-restore < /etc/iptables/rules.v6
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl enable iptables-restore.service
    log "OK" "Systemd unit iptables-restore.service enabled."
}
