
# Проверка порта SSH (диапазон 1024-65535)
# Получение текущего порта SSH из конфигурации
get_ssh_port() {
    local port
    # Фактическое значение (учитывает Include sshd_config.d), fallback на основной конфиг
    port=$(sshd -T 2>/dev/null | awk '/^port[[:space:]]/ {print $2; exit}')
    [[ -z "$port" ]] && port=$(grep -i '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | xargs)
    [[ -z "$port" ]] && port=22
    echo "$port"
}

# НАСТРОЙКА SSH-КЛЮЧЕЙ
# ============================================================

# Проверка sshd_config и безопасный рестарт sshd.
# Откат изменяемого drop-in выполняет вызывающая функция по своей свежей копии.
validate_and_restart_sshd() {
    if ! ${USE_SUDO:+$USE_SUDO }sshd -t 2>/dev/null; then
        red "Ошибка: конфигурация sshd невалидна (sshd -t завершился с ошибкой)."
        return 1
    fi

    # Перезапуск sshd: сначала ssh (Ubuntu/Debian), затем sshd (fallback)
    if ${USE_SUDO:+$USE_SUDO }systemctl restart ssh 2>/dev/null; then
        return 0
    fi
    if ${USE_SUDO:+$USE_SUDO }systemctl restart sshd 2>/dev/null; then
        return 0
    fi

    red "Ошибка: не удалось перезапустить службу sshd (ssh/sshd)."
    red "Внимание: текущая SSH-сессия может быть затронута. Проверьте статус службы вручную."
    return 1
}

# Убедиться, что /etc/ssh/sshd_config содержит Include для sshd_config.d/*.conf
_ensure_sshd_include() {
    local sshd_config="/etc/ssh/sshd_config"
    local include_line="Include /etc/ssh/sshd_config.d/*.conf"
    if ! grep -qE '^\s*Include\s+/etc/ssh/sshd_config\.d/\*\.conf' "$sshd_config" 2>/dev/null; then
        cp "$sshd_config" "${sshd_config}.bak" || { red "Не удалось создать резервную копию $sshd_config."; return 1; }
        printf '%s\n' "$include_line" | cat - "$sshd_config" > "${sshd_config}.tmp" && mv "${sshd_config}.tmp" "$sshd_config" || {
            red "Не удалось добавить Include в $sshd_config."
            return 1
        }
        yellow "Добавлен Include /etc/ssh/sshd_config.d/*.conf в $sshd_config"
    fi
}

# Восстановить именно предыдущее состояние drop-in SSH, не используя старый .bak.
restore_sshd_dropin() {
    local dropin=$1 backup=$2 existed=$3
    if [[ "$existed" == "yes" ]]; then
        cp -p -- "$backup" "$dropin" || { red "Не удалось восстановить $dropin из $backup."; return 1; }
    else
        rm -f -- "$dropin" || { red "Не удалось удалить новый файл $dropin при откате."; return 1; }
    fi
    validate_and_restart_sshd
}

# Проверка наличия другого рабочего способа входа по SSH с правами администратора.
# Пароль учитывается только при явно разрешенной PasswordAuthentication.
has_alternative_ssh_access() {
    local user uid shell home password_auth status
    password_auth=$(sshd -T 2>/dev/null | awk '/^passwordauthentication/ {print $2; exit}')

    while IFS=: read -r user _ uid _ _ home shell; do
        [[ "$uid" =~ ^[0-9]+$ && "$uid" -ge 1000 && "$uid" -lt 65534 ]] || continue
        [[ "$shell" != */nologin && "$shell" != */false && -x "$shell" ]] || continue
        id -nG "$user" 2>/dev/null | grep -Eq '(^| )(sudo|admin)( |$)' || continue

        if [[ -s "$home/.ssh/authorized_keys" ]]; then
            return 0
        fi
        if [[ "$password_auth" == "yes" ]]; then
            status=$(passwd -S "$user" 2>/dev/null | awk '{print $2}')
            [[ "$status" == "P" ]] && return 0
        fi
    done < <(getent passwd)

    return 1
}

_prepare_ssh_dir() {
    local username="$1" user_home="$2"
    if [[ ! -d "$user_home/.ssh" ]]; then
        if ! ${USE_SUDO:+$USE_SUDO }mkdir -p "$user_home/.ssh" ||
            ! ${USE_SUDO:+$USE_SUDO }chown "$username:$username" "$user_home/.ssh" ||
            ! ${USE_SUDO:+$USE_SUDO }chmod 700 "$user_home/.ssh"; then
            red "Не удалось подготовить каталог .ssh для пользователя $username."
            return 1
        fi
    elif ! ${USE_SUDO:+$USE_SUDO }chown "$username:$username" "$user_home/.ssh" ||
        ! ${USE_SUDO:+$USE_SUDO }chmod 700 "$user_home/.ssh"; then
        red "Не удалось проверить права каталога .ssh для пользователя $username."
        return 1
    fi
}

_add_ssh_key_flow() {
    local username="$1" user_home="$2" mode="$3"

    if ! _prepare_ssh_dir "$username" "$user_home"; then
        return 1
    fi

    if ! command -v nano &>/dev/null; then
        red "nano не установлен. Установите его: apt install nano"
        return 1
    fi

    red "Прежде чем продолжить, выполните следующие действия на своём компьютере:"
    if [[ "$mode" == "new" ]]; then
        yellow "1. Откройте PowerShell."
        yellow "2. Перейдите в папку .ssh: cd ~\\.ssh  (если папки нет — создайте: mkdir ~\\.ssh)"
        yellow "3. Сгенерируйте ключ:"
        yellow "   ssh-keygen -t ed25519 -C \"Комментарий\" -f Имя_файла -N Пароль"
        yellow "4. Скопируйте содержимое публичного ключа:"
        yellow "   cat ~\\.ssh\\Имя_файла.pub"
        yellow "5. Вставьте скопированное в редактор nano, который сейчас откроется."
        yellow "   Сохраните и закройте редактор: Ctrl+X, Y, Enter."
        echo
        read -r -p "Если выполнили шаги 1–4, нажмите ENTER для открытия редактора: "
    else
        yellow "1. Откройте PowerShell."
        yellow "2. Найдите нужный .pub файл в папке .ssh:"
        yellow "   ls ~\\.ssh\\*.pub"
        yellow "3. Скопируйте содержимое нужного ключа:"
        yellow "   cat ~\\.ssh\\Имя_файла.pub"
        yellow "4. Вставьте скопированное в редактор nano, который сейчас откроется."
        yellow "   Сохраните и закройте редактор: Ctrl+X, Y, Enter."
        echo
        read -r -p "Если скопировали содержимое ключа, нажмите ENTER для открытия редактора: "
    fi

    if ! ${USE_SUDO:+$USE_SUDO }nano "$user_home/.ssh/authorized_keys"; then
        red "Редактор nano завершился с ошибкой."
        return 1
    fi

    if [[ ! -s "$user_home/.ssh/authorized_keys" ]] ||
        ! ${USE_SUDO:+$USE_SUDO }chown -R "$username:$username" "$user_home/.ssh" ||
        ! ${USE_SUDO:+$USE_SUDO }chmod 600 "$user_home/.ssh/authorized_keys"; then
        red "Не удалось проверить или установить права SSH-ключей для пользователя $username."
        return 1
    fi

    if ! validate_and_restart_sshd; then
        return 1
    fi

    green "Настройка SSH-ключей для пользователя $username завершена."
}

toggle_pubkey_auth() {
    local sshd_dropin="/etc/ssh/sshd_config.d/00-protection.conf"
    local backup="" existed="no"
    local current_val
    current_val=$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication/ {print $2; exit}')
    [[ -z "$current_val" ]] && current_val="yes"

    if [[ "$current_val" == "yes" ]]; then
        yellow "ВНИМАНИЕ: После отключения аутентификации по ключу вход будет возможен только по паролю."
        yellow "Убедитесь, что вход по паролю разрешён и пароль задан, ПРЕЖДЕ чем отключать ключи."
        yellow "Проверьте вход по паролю в отдельном терминале, не закрывая этот сеанс."
        if [[ "$(prompt_yes_no "Аутентификация по ключу включена. Отключить?" "no")" != "yes" ]]; then
            return
        fi
        local new_val="no"
    else
        if [[ "$(prompt_yes_no "Аутентификация по ключу отключена. Включить?" "yes")" != "yes" ]]; then
            return
        fi
        local new_val="yes"
    fi

    mkdir -p "$(dirname "$sshd_dropin")" || { red "Не удалось создать каталог drop-in SSH."; return 1; }
    _ensure_sshd_include || return 1
    if [[ -f "$sshd_dropin" ]]; then
        existed="yes"
        backup=$(mktemp "$(dirname "$sshd_dropin")/.00-protection.XXXXXX") || { red "Не удалось создать резервную копию SSH drop-in."; return 1; }
        cp -p -- "$sshd_dropin" "$backup" || { rm -f -- "$backup"; red "Не удалось создать резервную копию SSH drop-in."; return 1; }
        if ! sed -i -E "/^[[:space:]]*PubkeyAuthentication[[:space:]]/d; 1iPubkeyAuthentication $new_val" "$sshd_dropin"; then
            restore_sshd_dropin "$sshd_dropin" "$backup" "$existed" || red "Требуется ручная проверка конфигурации SSH после неудачного отката."
            rm -f -- "$backup"
            red "Не удалось изменить PubkeyAuthentication."
            return 1
        fi
    elif ! printf 'PubkeyAuthentication %s\n' "$new_val" > "$sshd_dropin"; then
        rm -f -- "$sshd_dropin"
        red "Не удалось изменить PubkeyAuthentication."
        return 1
    fi

    if ! validate_and_restart_sshd; then
        restore_sshd_dropin "$sshd_dropin" "$backup" "$existed" || red "Требуется ручная проверка конфигурации SSH после неудачного отката."
        [[ -n "$backup" ]] && rm -f -- "$backup"
        return 1
    fi

    [[ -n "$backup" ]] && rm -f -- "$backup"

    if [[ "$new_val" == "yes" ]]; then
        purple "Аутентификация по ключу включена."
    else
        purple "Аутентификация по ключу отключена."
    fi
}

setup_ssh_keys() {
    local ssh_labels=() ssh_values=()
    local pubkey_status
    pubkey_status=$(sshd -T 2>/dev/null | awk '/^pubkeyauthentication/ {print $2; exit}')
    [[ -z "$pubkey_status" ]] && pubkey_status="yes"

    if [[ "$pubkey_status" == "yes" ]]; then
        local pubkey_label="5. Отключить аутентификацию по ключу"
    else
        local pubkey_label="5. Включить аутентификацию по ключу"
    fi

    ssh_labels=(
        "1. Добавить новый ключ пользователю"
        "2. Использовать существующий ключ для пользователя"
        "3. Добавить новый ключ для root"
        "4. Использовать существующий ключ для root"
        "$pubkey_label"
        "0. Назад"
    )
    ssh_values=(1 2 3 4 5 0)

    select_menu "Настройка SSH-ключей" ssh_labels ssh_values
    local choice="$MENU_CHOICE"

    if [[ "$choice" == "0" ]]; then
        return
    fi

    if [[ "$choice" == "5" ]]; then
        toggle_pubkey_auth
        return
    fi

    local username user_home mode

    if [[ "$choice" == "3" || "$choice" == "4" ]]; then
        username="root"
    else
        if ! select_non_system_user manual; then
            return
        fi
        username="$SELECTED_USER"
    fi

    user_home="$(getent passwd "$username" | cut -d: -f6)"
    if [[ -z "$user_home" ]]; then
        red "Не удалось определить домашний каталог пользователя $username."
        return 1
    fi

    if [[ "$choice" == "1" || "$choice" == "3" ]]; then
        mode="new"
    else
        mode="existing"
    fi

    _add_ssh_key_flow "$username" "$user_home" "$mode"
}

# ============================================================
# НАСТРОЙКА SSH
# ============================================================

# Установка значения PermitRootLogin (с бекапом и рестартом sshd)
set_permit_root_login() {
    local value=$1
    local sshd_dropin="/etc/ssh/sshd_config.d/00-protection.conf"
    local backup="" existed="no"
    mkdir -p "$(dirname "$sshd_dropin")" || { red "Не удалось создать каталог drop-in SSH."; return 1; }
    _ensure_sshd_include || return 1
    if [[ -f "$sshd_dropin" ]]; then
        existed="yes"
        backup=$(mktemp "$(dirname "$sshd_dropin")/.00-protection.XXXXXX") || { red "Не удалось создать резервную копию SSH drop-in."; return 1; }
        cp -p -- "$sshd_dropin" "$backup" || { rm -f -- "$backup"; red "Не удалось создать резервную копию SSH drop-in."; return 1; }
    fi
    if [[ -f "$sshd_dropin" ]]; then
        if ! sed -i -E "/^[[:space:]]*PermitRootLogin[[:space:]]/d; 1iPermitRootLogin $value" "$sshd_dropin"; then
            restore_sshd_dropin "$sshd_dropin" "$backup" "$existed" || red "Требуется ручная проверка конфигурации SSH после неудачного отката."
            [[ -n "$backup" ]] && rm -f -- "$backup"
            red "Не удалось изменить PermitRootLogin."
            return 1
        fi
    elif ! printf 'PermitRootLogin %s\n' "$value" > "$sshd_dropin"; then
        rm -f -- "$sshd_dropin"
        red "Не удалось изменить PermitRootLogin."
        return 1
    fi
    if ! validate_and_restart_sshd; then
        red "Не удалось применить PermitRootLogin $value."
        restore_sshd_dropin "$sshd_dropin" "$backup" "$existed" || red "Требуется ручная проверка конфигурации SSH после неудачного отката."
        [[ -n "$backup" ]] && rm -f -- "$backup"
        return 1
    fi
    if [[ "$(sshd -T 2>/dev/null | awk '/^permitrootlogin/ {print $2; exit}')" != "$value" ]]; then
        red "Эффективное значение PermitRootLogin не совпало с ожидаемым: $value."
        restore_sshd_dropin "$sshd_dropin" "$backup" "$existed" || red "Требуется ручная проверка конфигурации SSH после неудачного отката."
        [[ -n "$backup" ]] && rm -f -- "$backup"
        return 1
    fi
    [[ -n "$backup" ]] && rm -f -- "$backup"
}

# Отключение/включение входа root по SSH
disable_root_ssh() {
    local ROOT_SSH_STATUS
    # Определяем текущее значение PermitRootLogin (учитывает Include sshd_config.d)
    ROOT_SSH_STATUS=$(sshd -T 2>/dev/null | awk '/^permitrootlogin/ {print $2; exit}')
    if [[ -z "$ROOT_SSH_STATUS" ]]; then
        ROOT_SSH_STATUS=$(grep -i '^\s*PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | tail -n 1 | awk '{print $2}')
    fi
    
    # Если параметра нет — считаем, что включен по умолчанию (prohibit-password/yes)
    if [[ -z "$ROOT_SSH_STATUS" ]]; then
        ROOT_SSH_STATUS="yes"
    fi
    
    if [[ "$ROOT_SSH_STATUS" == "no" ]]; then
        if [[ "$(prompt_yes_no "Вход root по SSH отключен. Хотите включить вход root по SSH?" "no")" == "yes" ]]; then
            if set_permit_root_login yes; then
                purple "Вход root по SSH включен."
            fi
        fi
    elif [[ "$ROOT_SSH_STATUS" == "prohibit-password" ]]; then
        yellow "Вход root по SSH разрешен только по ключам (вход по паролю отключен)."
        if [[ "$(prompt_yes_no "Полностью отключить вход root по SSH?" "no")" == "yes" ]]; then
            if ! has_alternative_ssh_access; then
                red "Отключение root по SSH отменено: не найден другой рабочий SSH-доступ с правами sudo/admin."
                return 1
            fi
            if set_permit_root_login no; then
                purple "Вход root по SSH отключен."
            fi
        elif [[ "$(prompt_yes_no "Полностью включить вход root по SSH (разрешить вход по паролю)?" "no")" == "yes" ]]; then
            if set_permit_root_login yes; then
                purple "Вход root по SSH включен."
            fi
        fi
    else
        if [[ "$(prompt_yes_no "Хотите отключить вход root по SSH?" "no")" == "yes" ]]; then
            if ! has_alternative_ssh_access; then
                red "Отключение root по SSH отменено: не найден другой рабочий SSH-доступ с правами sudo/admin."
                return 1
            fi
            if set_permit_root_login no; then
                purple "Вход root по SSH отключен."
            fi
        fi
    fi
}


# Изменение порта SSH
change_port_ssh() {
    local NEW_SSH_PORT sshd_dropin backup existed ufw_rule_added CURRENT_SSH_PORT
    CURRENT_SSH_PORT=$(get_ssh_port)
    
    if [[ "$(prompt_yes_no "Порт SSH = $CURRENT_SSH_PORT, хотите изменить его?" "no")" == "no" ]]; then
        return
    fi

    while true; do
        read -r -p 'Введите новый порт SSH (от 1024 до 65535): ' NEW_SSH_PORT
        
        if validate_port "$NEW_SSH_PORT" 1024 65535; then
            if port_in_use "$NEW_SSH_PORT"; then
                red "Порт $NEW_SSH_PORT уже занят. Выберите другой."
                continue
            fi
            if systemctl is-active --quiet ssh.socket 2>/dev/null; then
                red "Обнаружена socket-активация ssh.socket. Изменение порта отменено: настройте ListenStream в systemd socket override или отключите socket-активацию и повторите попытку."
                return 1
            fi
            sshd_dropin="/etc/ssh/sshd_config.d/00-protection.conf"
            mkdir -p "$(dirname "$sshd_dropin")" || { red "Не удалось создать каталог drop-in SSH."; return 1; }
            _ensure_sshd_include || return 1
            backup=""
            existed="no"
            ufw_rule_added="no"
            if [[ -f "$sshd_dropin" ]]; then
                existed="yes"
                backup=$(mktemp "$(dirname "$sshd_dropin")/.00-protection.XXXXXX") || { red "Не удалось создать резервную копию SSH drop-in."; return 1; }
                cp -p -- "$sshd_dropin" "$backup" || { rm -f -- "$backup"; red "Не удалось создать резервную копию SSH drop-in."; return 1; }
            fi

            # Открываем новый порт в UFW до рестарта sshd (если UFW активен)
            if ${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null | grep -q 'Status: active'; then
                if ! ufw_rule_exists "$NEW_SSH_PORT/tcp"; then
                    ufw_rule_added="yes"
                fi
                if ! ufw_allow_port "$NEW_SSH_PORT" tcp; then
                    [[ -n "$backup" ]] && rm -f -- "$backup"
                    red "Не удалось открыть порт $NEW_SSH_PORT/tcp в UFW. SSH-конфигурация не изменена."
                    return 1
                fi
            fi

            if [[ -f "$sshd_dropin" ]]; then
                if ! sed -i -E "/^[[:space:]]*Port[[:space:]]/d; 1iPort $NEW_SSH_PORT" "$sshd_dropin"; then
                    restore_sshd_dropin "$sshd_dropin" "$backup" "$existed" || red "Требуется ручная проверка конфигурации SSH после неудачного отката."
                    [[ "$ufw_rule_added" == "yes" ]] && echo "y" | ${USE_SUDO:+$USE_SUDO }ufw delete allow "$NEW_SSH_PORT/tcp" >/dev/null 2>&1
                    [[ -n "$backup" ]] && rm -f -- "$backup"
                    red "Не удалось изменить порт SSH."
                    return 1
                fi
            elif ! printf 'Port %s\n' "$NEW_SSH_PORT" > "$sshd_dropin"; then
                rm -f -- "$sshd_dropin"
                [[ "$ufw_rule_added" == "yes" ]] && echo "y" | ${USE_SUDO:+$USE_SUDO }ufw delete allow "$NEW_SSH_PORT/tcp" >/dev/null 2>&1
                [[ -n "$backup" ]] && rm -f -- "$backup"
                red "Не удалось изменить порт SSH."
                return 1
            fi

            # Перезапускаем SSH с проверкой конфигурации и авто-откатом.
            if ! validate_and_restart_sshd; then
                red "Не удалось применить новый порт SSH. Проверьте конфигурацию вручную."
                restore_sshd_dropin "$sshd_dropin" "$backup" "$existed" || red "Требуется ручная проверка конфигурации SSH после неудачного отката."
                [[ "$ufw_rule_added" == "yes" ]] && echo "y" | ${USE_SUDO:+$USE_SUDO }ufw delete allow "$NEW_SSH_PORT/tcp" >/dev/null 2>&1
                [[ -n "$backup" ]] && rm -f -- "$backup"
                return 1
            fi
            local effective_ssh_ports
            effective_ssh_ports=$(sshd -T 2>/dev/null | awk '$1 == "port" {print $2}')
            if ! printf '%s\n' "$effective_ssh_ports" | grep -Fxq "$NEW_SSH_PORT" || ! port_in_use "$NEW_SSH_PORT"; then
                red "Эффективный порт SSH не совпал с ожидаемым: $NEW_SSH_PORT."
                restore_sshd_dropin "$sshd_dropin" "$backup" "$existed" || red "Требуется ручная проверка конфигурации SSH после неудачного отката."
                [[ "$ufw_rule_added" == "yes" ]] && echo "y" | ${USE_SUDO:+$USE_SUDO }ufw delete allow "$NEW_SSH_PORT/tcp" >/dev/null 2>&1
                [[ -n "$backup" ]] && rm -f -- "$backup"
                return 1
            fi
            [[ -n "$backup" ]] && rm -f -- "$backup"

            purple "Порт SSH изменен на $NEW_SSH_PORT."
            if [[ -f /etc/fail2ban/jail.local ]] && ! grep -qE "^port = $NEW_SSH_PORT$" /etc/fail2ban/jail.local; then
                yellow "Внимание: jail Fail2ban (jail.local) настроен не на порт $NEW_SSH_PORT — обновите конфигурацию Fail2ban (пункт 8 меню)."
            fi
            CURRENT_SSH_PORT=$NEW_SSH_PORT
            break
        else
            red "Недопустимый порт. Порт должен быть в диапазоне от 1024 до 65535."
        fi
    done
}

