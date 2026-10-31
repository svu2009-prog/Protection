# ============================================================
# FAIL2BAN
# ============================================================

# Создание /etc/fail2ban/jail.local с настройками по умолчанию
generate_fail2ban_config() {
    local CURRENT_SSH_PORT
    # Получаем текущий SSH порт для конфигурации
    CURRENT_SSH_PORT=$(get_ssh_port)

    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Время бана по умолчанию (1 час)
bantime = $F2B_BANTIME_DEFAULT
findtime = $F2B_FINDTIME_DEFAULT
maxretry = $F2B_MAXRETRY_DEFAULT

# Разрешённые IP (добавьте свои после 127.0.0.1 через пробел)
ignoreip = 127.0.0.1/8 ::1

# Действие по умолчанию — nftables
banaction = nftables-multiport
banaction_allports = nftables-allports
backend = systemd

[sshd]
enabled = true
port = $CURRENT_SSH_PORT
filter = sshd
logpath = /var/log/auth.log
backend = polling
maxretry = 3
findtime = $F2B_FINDTIME_DEFAULT
bantime = $F2B_BANTIME_DEFAULT

[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
backend  = polling
# Жёсткий бан за рецидив: 2 бана за 2 дня -> блокировка на неделю
bantime = $F2B_RECIDIVE_BANTIME
findtime = $F2B_RECIDIVE_FINDTIME
maxretry = $F2B_RECIDIVE_MAXRETRY
action = nftables-allports[name=recidive]
EOF
}

# Установка и настройка fail2ban
install_fail2ban() {
    local jail_local="/etc/fail2ban/jail.local" jail_backup="" jail_existed="no" CURRENT_SSH_PORT

    # Проверка наличия интернета
    if ! check_internet; then
        red "Нет подключения к интернету."
        if [[ "$(prompt_yes_no "Продолжить без подключения?" "no")" == "no" ]]; then
            return
        fi
    fi

    if ! ${USE_SUDO:+$USE_SUDO }apt update -y; then
        red "Не удалось обновить индекс пакетов."
        return 1
    fi

    # Устанавливаем nftables, если не установлен
    if ! command -v nft &>/dev/null; then
        green "Устанавливаем nftables..."
        if ! ${USE_SUDO:+$USE_SUDO }apt install -yq nftables; then
            red "Не удалось установить nftables."
            return 1
        fi
        if ${USE_SUDO:+$USE_SUDO }systemctl enable nftables 2>/dev/null && ${USE_SUDO:+$USE_SUDO }systemctl start nftables 2>/dev/null; then
            purple "nftables успешно установлен и запущен."
        else
            yellow "nftables установлен, но не удалось включить/запустить службу. Проверьте вручную."
        fi
    else
        green "nftables уже установлен."
    fi
    
    # Устанавливаем fail2ban
    if ! ${USE_SUDO:+$USE_SUDO }apt install -yq fail2ban || ! command -v fail2ban-client >/dev/null 2>&1; then
        red "Не удалось установить fail2ban."
        return 1
    fi
    
    if [[ "$(prompt_yes_no "Хотите настроить fail2ban?" "no")" == "no" ]]; then
        ${USE_SUDO:+$USE_SUDO }systemctl stop fail2ban
        ${USE_SUDO:+$USE_SUDO }systemctl disable fail2ban
        red "fail2ban отключен."
        return
    fi
    
    # Получаем текущий SSH порт для конфигурации
    CURRENT_SSH_PORT=$(get_ssh_port)
    
    # Сохраняем исходное состояние во временную копию для отката этого запуска.
    if [[ -f "$jail_local" ]]; then
        jail_existed="yes"
        jail_backup=$(mktemp "/etc/fail2ban/.jail.local.XXXXXX") || { red "Не удалось создать резервную копию jail.local."; return 1; }
        if ! cp -p -- "$jail_local" "$jail_backup"; then
            rm -f -- "$jail_backup"
            red "Не удалось создать резервную копию jail.local."
            return 1
        fi
    fi

    # Создаем конфигурацию fail2ban
    if ! generate_fail2ban_config; then
        if [[ "$jail_existed" == "yes" ]]; then cp -p -- "$jail_backup" "$jail_local"; else rm -f -- "$jail_local"; fi
        [[ -n "$jail_backup" ]] && rm -f -- "$jail_backup"
        red "Не удалось создать jail.local."
        return 1
    fi

    if ! ${USE_SUDO:+$USE_SUDO }fail2ban-client -t >/dev/null 2>&1; then
        red "Конфигурация fail2ban не прошла проверку. Восстанавливаем резервную копию."
        if [[ "$jail_existed" == "yes" ]]; then
            cp -p -- "$jail_backup" "$jail_local"
        else
            rm -f -- "$jail_local"
        fi
        [[ -n "$jail_backup" ]] && rm -f -- "$jail_backup"
        return 1
    fi
    
    if ! ${USE_SUDO:+$USE_SUDO }systemctl enable fail2ban ||
        ! ${USE_SUDO:+$USE_SUDO }systemctl start fail2ban; then
        red "Не удалось включить или запустить fail2ban."
        if [[ "$jail_existed" == "yes" ]]; then cp -p -- "$jail_backup" "$jail_local"; else rm -f -- "$jail_local"; fi
        [[ -n "$jail_backup" ]] && rm -f -- "$jail_backup"
        return 1
    fi
    if ! ${USE_SUDO:+$USE_SUDO }systemctl restart fail2ban; then
        red "Ошибка: fail2ban не запустился. Проверьте /etc/fail2ban/jail.local и журнал: journalctl -u fail2ban"
        if [[ "$jail_existed" == "yes" ]]; then cp -p -- "$jail_backup" "$jail_local"; else rm -f -- "$jail_local"; fi
        ${USE_SUDO:+$USE_SUDO }systemctl restart fail2ban >/dev/null 2>&1
        [[ -n "$jail_backup" ]] && rm -f -- "$jail_backup"
        return 1
    fi
    [[ -n "$jail_backup" ]] && rm -f -- "$jail_backup"
    if ! ${USE_SUDO:+$USE_SUDO }fail2ban-client status sshd &>/dev/null; then
        yellow "Внимание: jail sshd не активен — проверьте, что существует /var/log/auth.log (на минимальных Ubuntu 22.04+ он может отсутствовать)."
    fi
    purple "fail2ban установлен и настроен."
}



# ============================================================
# ДОПОЛНИТЕЛЬНОЕ МЕНЮ FAIL2BAN
# ============================================================



# Выбор jail для Fail2ban
select_fail2ban_jail() {
    local fb_all jail_list_line
    # Проверка прав
    if [[ $EUID -ne 0 && -z "$USE_SUDO" ]]; then
        red "Нужны права root для работы с Fail2ban."
        return 1
    fi
    
    fb_all=$(${USE_SUDO:+$USE_SUDO }fail2ban-client status 2>/dev/null)
    if [[ -z "$fb_all" ]]; then
        red "Не удалось получить статус Fail2ban."
        return 1
    fi
    if echo "$fb_all" | grep -qi "Permission denied"; then
        red "Недостаточно прав для доступа к fail2ban-client. Запустите скрипт от root." 
        return 1
    fi
    
    jail_list_line=$(echo "$fb_all" | grep -i "Jail list")
    FB_JAILS=$(echo "$jail_list_line" | awk -F':' '{print $2}' | tr -d ' ' | tr ',' ' ')
    
    if [[ -z "$FB_JAILS" ]]; then
        red "Не удалось получить список jail."
        return 1
    fi
    return 0
}



# Редактирование /etc/fail2ban/jail.local в nano
edit_fail2ban_jail_local() {
    local jail_local="/etc/fail2ban/jail.local"
    local jail_local_bak="${jail_local}.edit.bak"

    if [[ ! -f "$jail_local" ]]; then
        yellow "Файл $jail_local не найден."
        if [[ "$(prompt_yes_no "Создать $jail_local с настройками по умолчанию?" "yes")" == "yes" ]]; then
            if ! generate_fail2ban_config; then
                red "Не удалось создать $jail_local."
                return 1
            fi
            purple "Файл $jail_local создан с настройками по умолчанию."
        else
            return 1
        fi
    fi

    # Устанавливаем nano, если он не установлен
    if ! command -v nano &>/dev/null; then
        if ! check_internet; then
            red "Нет подключения к интернету."
            if [[ "$(prompt_yes_no "Продолжить без подключения?" "no")" == "no" ]]; then
                return 1
            fi
        fi
        green "Устанавливаем nano..."
        if ! ${USE_SUDO:+$USE_SUDO }apt update -y; then
            red "Не удалось обновить индекс пакетов."
            return 1
        fi
        if ! apt install -yq nano || ! command -v nano &>/dev/null; then
            red "Не удалось установить nano."
            return 1
        fi
        purple "nano успешно установлен."
    fi

    # Резервная копия перед редактированием
    if ! cp "$jail_local" "$jail_local_bak"; then
        red "Не удалось создать резервную копию jail.local."
        return 1
    fi

    green "Редактирование $jail_local в nano. Сохранить: Ctrl+O, выход: Ctrl+X."
    ${USE_SUDO:+$USE_SUDO }nano "$jail_local" </dev/tty

    # Проверка конфигурации после редактирования
    if ! ${USE_SUDO:+$USE_SUDO }fail2ban-client -t >/dev/null 2>&1; then
        red "Конфигурация fail2ban не прошла проверку после редактирования."
        if [[ "$(prompt_yes_no "Восстановить резервную копию jail.local?" "yes")" == "yes" ]]; then
            if cp "$jail_local_bak" "$jail_local"; then
                purple "jail.local восстановлен из резервной копии $jail_local_bak."
            else
                red "Не удалось восстановить jail.local из резервной копии $jail_local_bak."
                return 1
            fi
        else
            yellow "Оставляем отредактированный jail.local. Исправьте ошибки вручную."
            return 1
        fi
    fi

    # Перезапуск fail2ban для применения настроек, если служба активна
    if systemctl is-active --quiet fail2ban 2>/dev/null; then
        if ${USE_SUDO:+$USE_SUDO }systemctl restart fail2ban 2>/dev/null; then
            purple "fail2ban перезапущен с новой конфигурацией."
        else
            red "Не удалось перезапустить fail2ban. Проверьте журнал: journalctl -u fail2ban"
            return 1
        fi
    else
        yellow "fail2ban не активен — изменения применятся при следующем запуске."
    fi
}

# Подменю управления Fail2ban
fail2ban_menu() {
    # Если fail2ban не установлен — выполняем стандартную установку/настройку
    if ! dpkg-query -W -f='${Status}' fail2ban 2>/dev/null | grep -q "install ok installed"; then
        install_fail2ban
        return
    fi
    
    while true; do
        # shellcheck disable=SC2034 # Массивы читаются select_menu по имени через nameref.
        local fb_menu_labels=(
            "1. Показать статус Fail2ban"
            "2. Показать все активные jail"
            "3. Статус jail"
            "4. Показать забаненные IP"
            "5. Разбанить IP"
            "6. Запустить Fail2ban"
            "7. Остановить Fail2ban"
            "8. Перезапустить Fail2ban"
            "9. Просмотр попыток подключения к серверу"
            "10. Редактировать jail.local (nano)"
            "0. Назад"
        )
        # shellcheck disable=SC2034 # Массивы читаются select_menu по имени через nameref.
        local fb_menu_values=(1 2 3 4 5 6 7 8 9 10 0)

        select_menu "Подменю управления Fail2ban" fb_menu_labels fb_menu_values
        local FB_MENU="$MENU_CHOICE"
        
        case $FB_MENU in
            1)
                service_short_status fail2ban
                ${USE_SUDO:+$USE_SUDO }systemctl status fail2ban --no-pager 2>/dev/null
                ;;
            2)
                ${USE_SUDO:+$USE_SUDO }fail2ban-client status 2>/dev/null
                ;;
            3)
                if select_fail2ban_jail; then
                    echo "Список jail:"
                    local j
                    for j in $FB_JAILS; do
                        echo "- $j"
                    done
                    for j in $FB_JAILS; do
                        echo "------- Jail: $j -------"
                        local fb_status
                        fb_status=$(${USE_SUDO:+$USE_SUDO }fail2ban-client status "$j" 2>/dev/null)
                        echo "$fb_status"
                    done
                fi
                ;;
            4)
                if select_fail2ban_jail; then
                    echo "Список jail:"
                    local j
                    for j in $FB_JAILS; do
                        echo "- $j"
                    done
                    for j in $FB_JAILS; do
                        echo "------- Jail: $j -------"
                        local fb_out banned_list
                        fb_out=$(${USE_SUDO:+$USE_SUDO }fail2ban-client status "$j" 2>/dev/null)
                        banned_list=$(echo "$fb_out" | grep -i "Banned IP list" | awk -F':' '{print $2}' | xargs)
                        if [[ -z "$banned_list" ]]; then
                            yellow "Забаненных IP в jail $j нет."
                        else
                            green "Забаненные IP в jail $j: $banned_list"
                        fi
                    done
                fi
                ;;
            5)
                if select_fail2ban_jail; then
                    local banned_ips_map=() banned_ips_labels=() banned_ips_values=()
                    local j
                    for j in $FB_JAILS; do
                        local fb_out banned_list
                        fb_out=$(${USE_SUDO:+$USE_SUDO }fail2ban-client status "$j" 2>/dev/null)
                        banned_list=$(echo "$fb_out" | grep -i "Banned IP list" | awk -F':' '{print $2}' | xargs)
                        local ip
                        for ip in $banned_list; do
                            [[ " ${banned_ips_map[*]} " =~ $ip ]] || banned_ips_map+=("$ip")
                        done
                    done
                    if [[ ${#banned_ips_map[@]} -eq 0 ]]; then
                        yellow "Нет забаненных IP."
                    else
                        for i in "${!banned_ips_map[@]}"; do
                            banned_ips_labels+=("$((i+1)). ${banned_ips_map[$i]}")
                            banned_ips_values+=("$((i+1))")
                        done
                        select_menu "Выберите IP для разбана:" banned_ips_labels banned_ips_values
                        if [[ "$MENU_CHOICE" =~ ^[0-9]+$ ]] && (( MENU_CHOICE >= 1 && MENU_CHOICE <= ${#banned_ips_map[@]} )); then
                            local selected_ip="${banned_ips_map[$((MENU_CHOICE - 1))]}"
                            for j in $FB_JAILS; do
                                ${USE_SUDO:+$USE_SUDO }fail2ban-client set "$j" unbanip "$selected_ip" 2>/dev/null
                            done
                            purple "IP $selected_ip разбанен во всех jail (если был в бане)."
                        fi
                    fi
                fi
                ;;

            6)
                if ${USE_SUDO:+$USE_SUDO }systemctl start fail2ban 2>/dev/null; then
                    purple "fail2ban запущен."
                else
                    red "Не удалось запустить fail2ban."
                fi
                ;;
            7)
                if ${USE_SUDO:+$USE_SUDO }systemctl stop fail2ban 2>/dev/null; then
                    purple "fail2ban остановлен."
                else
                    red "Не удалось остановить fail2ban."
                fi
                ;;
            8)
                if ${USE_SUDO:+$USE_SUDO }systemctl restart fail2ban 2>/dev/null; then
                    purple "fail2ban перезапущен."
                else
                    red "Не удалось перезапустить fail2ban."
                fi
                ;;
            9)
                if [[ -f /var/log/auth.log ]]; then
                    ${USE_SUDO:+$USE_SUDO }grep -E "ssh|sshd|ssh2" /var/log/auth.log | tail -n 200
                elif [[ -f /var/log/secure ]]; then
                    ${USE_SUDO:+$USE_SUDO }grep -E "ssh|sshd|ssh2" /var/log/secure | tail -n 200
                else
                    red "Не найден файл логов /var/log/auth.log или /var/log/secure."
                fi
                ;;
            10)
                edit_fail2ban_jail_local
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



# ============================================================
