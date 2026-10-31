
ufw_allow_port() {
    local port=$1
    local proto=$2

    if ! validate_port "$port" 1 65535; then
        red "Некорректный порт для UFW: $port"
        return 1
    fi

    case "$proto" in
        tcp|udp) ;;
        *)
            red "Некорректный протокол для UFW: $proto"
            return 1
            ;;
    esac

    echo "y" | ${USE_SUDO:+$USE_SUDO }ufw allow "$port/$proto" >/dev/null 2>&1
}

# ============================================================
# НАСТРОЙКА UFW FIREWALL
# ============================================================

# Настройка UFW файрвола
setup_ufw() {
    local CURRENT_SSH_PORT
    # Проверка наличия интернета
    if ! check_internet; then
        red "Нет подключения к интернету."
        if [[ "$(prompt_yes_no "Продолжить без подключения?" "no")" == "no" ]]; then
            return
        fi
    fi

    # Устанавливаем ufw, если не установлен
    if ! dpkg-query -W -f='${Status}' ufw 2>/dev/null | grep -q "install ok installed"; then
        if ! ${USE_SUDO:+$USE_SUDO }apt update -y || ! ${USE_SUDO:+$USE_SUDO }apt install -yq ufw; then
            red "Не удалось установить UFW."
            return 1
        fi
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        red "UFW установлен, но команда ufw недоступна."
        return 1
    fi
    
    local CHECK_UFW
    CHECK_UFW=$(${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null)
    
    if [[ "$CHECK_UFW" == "Status: inactive" ]]; then
        if [[ "$(prompt_yes_no "Хотите включить и настроить ufw?" "no")" == "no" ]]; then
            red "ufw не включен."
            return
        fi
        
        yellow "Текущие правила UFW будут сохранены; необходимые правила добавятся к ним."

        # Получаем текущий порт SSH
        CURRENT_SSH_PORT=$(get_ssh_port)

        # Разрешаем стандартные порты
            if ! ufw_allow_port 443 tcp; then
                red "Не удалось открыть порт 443/tcp в UFW."
                return 1
            fi
            if validate_port "$CURRENT_SSH_PORT" 1 65535; then
                if ! ufw_allow_port "$CURRENT_SSH_PORT" tcp; then
                    red "Не удалось открыть SSH-порт $CURRENT_SSH_PORT/tcp в UFW."
                    return 1
                fi
            else
                red "SSH порт из конфигурации некорректен: $CURRENT_SSH_PORT"
                return 1
            fi



        # Включаем UFW
        if echo "y" | ${USE_SUDO:+$USE_SUDO }ufw enable >/dev/null 2>&1; then
            purple "ufw настроен и включен."
        else
            red "Ошибка при включении ufw. Проверьте статус вручную: ufw status"
            return 1
        fi
    else
        if [[ "$(prompt_yes_no "UFW включен, но не настроен, хотите выключить?" "no")" == "yes" ]]; then
            if echo "y" | ${USE_SUDO:+$USE_SUDO }ufw disable >/dev/null 2>&1; then
                purple "ufw отключен; существующие правила сохранены."
            else
                red "Не удалось отключить ufw."
                return 1
            fi
        else
            red "ВНИМАНИЕ, ufw не настроен, рекомендуется отключить его."
        fi
    fi
}



# ============================================================
# ДОПОЛНИТЕЛЬНОЕ МЕНЮ UFW
# ============================================================

# Проверка наличия правила UFW
ufw_rule_exists() {
    local rule=$1
    ${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null | grep -qwF "$rule" && return 0
    return 1
}

# Проверка и добавление портов, которые настраивает скрипт
ensure_ufw_ports() {
    local CURRENT_SSH_PORT
    # Получаем текущий порт SSH
    CURRENT_SSH_PORT=$(get_ssh_port)
    
    # 443/tcp
    if ! ufw_rule_exists "443/tcp"; then
        if ufw_allow_port 443 tcp; then
            purple "Добавлен порт 443/tcp в UFW."
        else
            red "Не удалось добавить порт 443/tcp в UFW."
        fi
    fi
    
    # SSH порт
    if validate_port "$CURRENT_SSH_PORT" 1 65535 && ! ufw_rule_exists "$CURRENT_SSH_PORT/tcp"; then
        if ufw_allow_port "$CURRENT_SSH_PORT" tcp; then
            purple "Добавлен порт $CURRENT_SSH_PORT/tcp в UFW."
        else
            red "Не удалось добавить SSH-порт $CURRENT_SSH_PORT/tcp в UFW."
        fi
    elif ! validate_port "$CURRENT_SSH_PORT" 1 65535; then
        red "SSH порт из конфигурации некорректен: $CURRENT_SSH_PORT"
    fi
    

    

}

# Подменю управления UFW
ufw_menu() {
    local CURRENT_SSH_PORT
    # Если ufw не установлен или не активен — выполняем стандартную установку/настройку
    if ! dpkg-query -W -f='${Status}' ufw 2>/dev/null | grep -q "install ok installed"; then
            setup_ufw
        return
    fi
    
    local UFW_STATUS
    UFW_STATUS=$(${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null)
    if echo "$UFW_STATUS" | grep -q "Status: inactive"; then
            setup_ufw
        return
    fi
    
    # Проверяем и добавляем нужные порты
    ensure_ufw_ports
    
    while true; do
        # shellcheck disable=SC2034 # Массивы читаются select_menu по имени через nameref.
        local ufw_menu_labels=(
            "1. Показать статус"
            "2. Добавить порты TCP"
            "3. Добавить порты UDP"
            "4. Удалить порт из списка"
            "5. Отключить ufw"
            "6. Включить ufw"
            "0. Назад"
        )
        # shellcheck disable=SC2034 # Массивы читаются select_menu по имени через nameref.
        local ufw_menu_values=(1 2 3 4 5 6 0)
        
        select_menu "Подменю управления Firewall UFW" ufw_menu_labels ufw_menu_values
        local UFW_MENU="$MENU_CHOICE"
        local UFW_TCP_PORTS UFW_UDP_PORTS
        
        case $UFW_MENU in
            1)
                service_short_status ufw
                ${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null
                ;;
            2)
                while true; do
                    read -r -p "Введите порты для добавления (TCP, через пробел): " UFW_TCP_PORTS
                    if [[ -z "${UFW_TCP_PORTS// /}" ]]; then
                        red "Ни один порт не введён."
                        continue
                    fi
                    local UFW_ADDED_COUNT=0
                    local UFW_ADDED_LIST=""
                    local UFW_TCP_PORT
                    for UFW_TCP_PORT in $UFW_TCP_PORTS; do
                        if validate_port "$UFW_TCP_PORT" 1 65535; then
                            if ufw_allow_port "$UFW_TCP_PORT" tcp; then
                                purple "Порт $UFW_TCP_PORT/tcp добавлен."
                                UFW_ADDED_COUNT=$((UFW_ADDED_COUNT + 1))
                                UFW_ADDED_LIST="$UFW_ADDED_LIST $UFW_TCP_PORT"
                            else
                                red "Не удалось добавить порт $UFW_TCP_PORT/tcp."
                            fi
                        else
                            red "Недопустимый порт: $UFW_TCP_PORT. Пропускаем."
                        fi
                    done
                    purple "Итого добавлено TCP-портов: $UFW_ADDED_COUNT:$UFW_ADDED_LIST"
                    break
                done
                ;;
            3)
                while true; do
                    read -r -p "Введите порты для добавления (UDP, через пробел): " UFW_UDP_PORTS
                    if [[ -z "${UFW_UDP_PORTS// /}" ]]; then
                        red "Ни один порт не введён."
                        continue
                    fi
                    local UFW_ADDED_COUNT=0
                    local UFW_ADDED_LIST=""
                    local UFW_UDP_PORT
                    for UFW_UDP_PORT in $UFW_UDP_PORTS; do
                        if validate_port "$UFW_UDP_PORT" 1 65535; then
                            if ufw_allow_port "$UFW_UDP_PORT" udp; then
                                purple "Порт $UFW_UDP_PORT/udp добавлен."
                                UFW_ADDED_COUNT=$((UFW_ADDED_COUNT + 1))
                                UFW_ADDED_LIST="$UFW_ADDED_LIST $UFW_UDP_PORT"
                            else
                                red "Не удалось добавить порт $UFW_UDP_PORT/udp."
                            fi
                        else
                            red "Недопустимый порт: $UFW_UDP_PORT. Пропускаем."
                        fi
                    done
                    purple "Итого добавлено UDP-портов: $UFW_ADDED_COUNT:$UFW_ADDED_LIST"
                    break
                done
                ;;
            4)
                local UFW_RULES_RAW
                UFW_RULES_RAW=$(${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null | grep -i " ALLOW " | awk '{print $1}')
                if [[ -z "$UFW_RULES_RAW" ]]; then
                    red "Нет правил для удаления."
                    continue
                fi
                local UFW_DEL_LABELS=()
                local UFW_DEL_VALUES=()
                local UFW_RULE
                for UFW_RULE in $UFW_RULES_RAW; do
                    UFW_DEL_LABELS+=("$UFW_RULE")
                    UFW_DEL_VALUES+=("$UFW_RULE")
                done
                select_menu "Выберите порт для удаления:" UFW_DEL_LABELS UFW_DEL_VALUES
                [[ -z "$MENU_CHOICE" ]] && continue
                local UFW_DEL_PORT="${MENU_CHOICE%%/*}"
                local UFW_DEL_PROTO="${MENU_CHOICE##*/}"
                if echo "y" | ${USE_SUDO:+$USE_SUDO }ufw delete allow "$UFW_DEL_PORT/$UFW_DEL_PROTO" >/dev/null 2>&1; then
                    purple "Правило $UFW_DEL_PORT/$UFW_DEL_PROTO удалено."
                else
                    red "Не удалось удалить правило $UFW_DEL_PORT/$UFW_DEL_PROTO."
                fi
                ;;
            5)
                if [[ "$(prompt_yes_no "Отключить ufw?" "no")" == "yes" ]]; then
                    if echo "y" | ${USE_SUDO:+$USE_SUDO }ufw disable >/dev/null 2>&1; then
                        purple "ufw отключен."
                    else
                        red "Не удалось отключить ufw."
                    fi
                fi
                ;;
            6)
                # Перед включением проверяем, что SSH порт разрешен
                CURRENT_SSH_PORT=$(get_ssh_port)
                if ! validate_port "$CURRENT_SSH_PORT" 1 65535; then
                    red "SSH порт из конфигурации некорректен: $CURRENT_SSH_PORT"
                    continue
                fi
                if ! ufw_rule_exists "$CURRENT_SSH_PORT/tcp"; then
                    if [[ "$(prompt_yes_no "SSH порт $CURRENT_SSH_PORT/tcp не разрешен. Добавить?" "no")" == "yes" ]]; then
                        if ufw_allow_port "$CURRENT_SSH_PORT" tcp; then
                            purple "Добавлен порт $CURRENT_SSH_PORT/tcp."
                        else
                            red "Не удалось добавить SSH-порт $CURRENT_SSH_PORT/tcp."
                            continue
                        fi
                    else
                        red "Включение ufw отменено, чтобы не потерять доступ."
                        break
                    fi
                fi
                if [[ "$(prompt_yes_no "Включить ufw?" "no")" == "yes" ]]; then
                    if echo "y" | ${USE_SUDO:+$USE_SUDO }ufw enable >/dev/null 2>&1; then
                        purple "ufw включен."
                    else
                        red "Ошибка при включении ufw. Проверьте: ufw status"
                    fi
                fi
                ;;
            0)
                break
                ;;
            *)
                yellow "Введите число от 0 до 10 и нажмите ENTER"
                ;;
        esac
    done
}

