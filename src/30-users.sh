# ============================================================
# ФУНКЦИИ РАБОТЫ С UFW
# ============================================================

# ============================================================
# ФУНКЦИИ УПРАВЛЕНИЯ ПОЛЬЗОВАТЕЛЯМИ
# ============================================================

# Добавление пользователя в sudoers для выполнения команд без пароля
add_user_nopasswd() {
    local username=$1 sudoers_file temp_file
    
    if [[ -z "$USE_SUDO" ]]; then
        yellow "sudo не установлен, пропускаем настройку NOPASSWD"
        return
    fi
    
    if ! command -v visudo &>/dev/null; then
        red "Команда visudo не найдена; настройка sudoers отменена."
        return 1
    fi

    sudoers_file="/etc/sudoers.d/$username"
    if ! temp_file=$(mktemp "/etc/sudoers.d/.${username}.XXXXXX"); then
        red "Не удалось создать временный sudoers-файл."
        return 1
    fi
    if ! printf '%s ALL=(ALL) NOPASSWD:ALL\n' "$username" > "$temp_file" ||
        ! chmod 0440 "$temp_file" ||
        ! visudo -cf "$temp_file" >/dev/null ||
        ! mv -f -- "$temp_file" "$sudoers_file"; then
        rm -f -- "$temp_file"
        red "Не удалось проверить и атомарно установить /etc/sudoers.d/$username."
        return 1
    fi
    purple "Пользователь $username добавлен в группу для выполнения команд без пароля."
}

# Удаление пользователя из sudoers (возврат требования пароля)
remove_user_nopasswd() {
    local username=$1
    if rm -f "/etc/sudoers.d/$username"; then
        purple "Пользователь $username исключен из группы для выполнения команд без пароля."
    else
        red "Не удалось удалить настройку NOPASSWD для пользователя $username."
        return 1
    fi
}

# Изменение пароля существующего пользователя
change_user_password() {
    local username=$1
    local password password_confirm

    while true; do
        read -rs -p "Введите новый пароль для пользователя $username: " password
        echo

        if validate_password "$password"; then
            read -rs -p "Повторите новый пароль для пользователя $username: " password_confirm
            echo
            
            if [[ "$password" == "$password_confirm" ]]; then
                if printf '%s\n' "$username:$password" | chpasswd; then
                    green "Пароль для пользователя $username успешно изменен."
                    break
                else
                    red "Не удалось изменить пароль для пользователя $username."
                    break
                fi
            else
                red "Пароли не совпадают. Попробуйте снова."
            fi
        fi
    done
}

# Изменение пароля root
change_root_pass() {
    local ROOT_PASSWORD_CONFIRM=""
    if [[ "$(prompt_yes_no "Хотите изменить пароль root?" "no")" == "no" ]]; then
        return
    fi
    
    while true; do
        local root_password
        read -rs -p "Введите новый пароль для root: " root_password
        echo
        
        if validate_password "$root_password"; then
            read -rs -p "Повторите новый пароль для root: " ROOT_PASSWORD_CONFIRM
            echo
            
            if [[ "$root_password" == "$ROOT_PASSWORD_CONFIRM" ]]; then
                if printf '%s\n' "root:$root_password" | chpasswd; then
                    green "Пароль root успешно изменен."
                    unset root_password ROOT_PASSWORD_CONFIRM
                    break
                else
                    red "Не удалось изменить пароль root."
                    unset root_password ROOT_PASSWORD_CONFIRM
                    break
                fi
            else
                red "Пароли не совпадают. Попробуйте снова."
                unset root_password ROOT_PASSWORD_CONFIRM
            fi
        else
            unset root_password
        fi
    done
}

# ============================================================
# ДОПОЛНИТЕЛЬНОЕ МЕНЮ ПОЛЬЗОВАТЕЛЕЙ
# ============================================================

# Получение списка несистемных пользователей
get_non_system_users() {
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "ubuntu" && $7 !~ /(nologin|false|sync|halt|shutdown)$/ {print $1}'
}

# Выбор несистемного пользователя. $1="manual" — добавить ручной ввод имени,
# $2="create" — добавить пункт создания нового пользователя (в группы sudo и docker).
select_non_system_user() {
    local allow_manual=${1:-""} allow_create=${2:-""}
    local users_list=()
    mapfile -t users_list < <(get_non_system_users)
    local user_labels=() user_values=()
    local manual_user="" manual_index=0 create_index=0 extra_index user_num

    SELECTED_USER=""

    if [[ ${#users_list[@]} -eq 0 ]]; then
        if [[ "$allow_create" == "create" ]]; then
            if [[ "$(prompt_yes_no "Нет подходящих пользователей. Создать нового пользователя (sudo и docker)?" "no")" == "yes" ]]; then
                new_user docker
            fi
        else
            red "Нет подходящих пользователей."
        fi
        return 1
    fi

    for i in "${!users_list[@]}"; do
        user_labels+=("$((i+1)). ${users_list[$i]}")
        user_values+=("$((i+1))")
    done

    extra_index=$(( ${#users_list[@]} + 1 ))
    if [[ "$allow_manual" == "manual" ]]; then
        manual_index=$extra_index
        user_labels+=("$extra_index. Ввести имя пользователя вручную")
        user_values+=("$extra_index")
        extra_index=$((extra_index + 1))
    fi
    if [[ "$allow_create" == "create" ]]; then
        create_index=$extra_index
        user_labels+=("$extra_index. Создать нового пользователя")
        user_values+=("$extra_index")
    fi

    while true; do
        select_menu "Список доступных пользователей:" user_labels user_values
        user_num="$MENU_CHOICE"
        if [[ "$user_num" =~ ^[0-9]+$ ]]; then
            if [[ "$user_num" -ge 1 && "$user_num" -le ${#users_list[@]} ]]; then
                SELECTED_USER="${users_list[$((user_num-1))]}"
                return 0
            elif [[ "$allow_manual" == "manual" && "$user_num" -eq "$manual_index" ]]; then
                read -r -p "Введите имя пользователя: " manual_user
                if [[ -z "$manual_user" ]]; then
                    red "Имя пользователя не указано."
                    return 1
                fi
                if ! id "$manual_user" &>/dev/null; then
                    red "Пользователь $manual_user не существует."
                    return 1
                fi
                SELECTED_USER="$manual_user"
                return 0
            elif [[ "$allow_create" == "create" && "$user_num" -eq "$create_index" ]]; then
                new_user docker
                if id "$username" &>/dev/null; then
                    SELECTED_USER="$username"
                    return 0
                fi
                return 1
            fi
        fi
        red "Некорректный выбор."
    done
}

# Подменю управления пользователями
users_menu() {
    local users_list=()
    mapfile -t users_list < <(get_non_system_users)
    
    # Если пользователей нет — выполняем стандартное создание
    if [[ ${#users_list[@]} -eq 0 ]]; then
        new_user
        return
    fi
    
    while true; do
        # shellcheck disable=SC2034 # Массивы читаются select_menu по имени через nameref.
        local user_menu_labels=(
            "1. Показать пользователей"
            "2. Поменять пароль пользователя"
            "3. Создать пользователя"
            "4. Показать в каких группах пользователь"
            "5. Добавить пользователя в группу"
            "6. Добавить пользователя в группу для выполнения команд без пароля"
            "7. Исключить пользователя из группы для выполнения команд без пароля"
            "8. Удалить пользователя"
            "0. Назад"
        )
        # shellcheck disable=SC2034 # Массивы читаются select_menu по имени через nameref.
        local user_menu_values=(1 2 3 4 5 6 7 8 0)
        local USER_MENU TARGET_GROUP
        
        select_menu "Подменю управления пользователями" user_menu_labels user_menu_values
        USER_MENU="$MENU_CHOICE"
        
        case $USER_MENU in
            1)
                mapfile -t users_list < <(get_non_system_users)
                if [[ ${#users_list[@]} -eq 0 ]]; then
                    yellow "Пользователей нет."
                else
                    echo "Список пользователей:"
                    for u in "${users_list[@]}"; do
                        echo "- $u"
                    done
                fi
                ;;
            2)
                if select_non_system_user; then
                    change_user_password "$SELECTED_USER"
                fi
                ;;
            3)
                new_user
                ;;
            4)
                if select_non_system_user; then
                    echo "Группы пользователя $SELECTED_USER:"
                    groups "$SELECTED_USER" 2>/dev/null | cut -d: -f2 | xargs
                fi
                ;;
            5)
                if select_non_system_user; then
                    read -r -p "Введите имя группы: " TARGET_GROUP
                    if [[ -z "$TARGET_GROUP" ]]; then
                        red "Имя группы не указано."
                    elif ! getent group "$TARGET_GROUP" &>/dev/null; then
                        red "Группа '$TARGET_GROUP' не существует."
                    else
                        if usermod -aG "$TARGET_GROUP" "$SELECTED_USER"; then
                            purple "Пользователь $SELECTED_USER добавлен в группу $TARGET_GROUP."
                        else
                            red "Ошибка при добавлении пользователя в группу."
                        fi
                    fi
                fi
                ;;
            6)
                if select_non_system_user; then
                    add_user_nopasswd "$SELECTED_USER"
                fi
                ;;
            7)
                if select_non_system_user; then
                    remove_user_nopasswd "$SELECTED_USER"
                fi
                ;;
            8)
                if select_non_system_user; then
                    if [[ "$(prompt_yes_no "Удалить пользователя $SELECTED_USER и его домашний каталог?" "no")" == "yes" ]]; then
                        if userdel -r "$SELECTED_USER" 2>/dev/null; then
                            purple "Пользователь $SELECTED_USER удален."
                        else
                            red "Ошибка при удалении пользователя."
                        fi
                    fi
                fi
                ;;

            0)
                break
                ;;
            *)
                yellow "Введите число от 0 до 9 и нажмите ENTER"
                ;;
        esac
    done
}



# ============================================================
# ============================================================
# СОЗДАНИЕ ПОЛЬЗОВАТЕЛЯ
# ============================================================

# Функция для создания нового пользователя
create_user() {
    local username=$1
    local password=$2
    local nopass=$3
    local groups=$4
    
    green "Пользователь: $username"
    
    # Создаем пользователя с указанными группами
    if ! useradd -m "$username" ${groups:+-G "$groups"} -s /bin/bash; then
        red "Ошибка при создании пользователя $username."
        return 1
    fi
    
    # Устанавливаем пароль
    if ! printf '%s\n' "$username:$password" | chpasswd; then
        red "Ошибка при установке пароля для пользователя $username."
        userdel -r "$username"
        return 1
    fi
    
    # Добавляем в sudoers без пароля, если требуется и sudo установлен
    if [[ "$nopass" == "yes" && -n "$USE_SUDO" ]]; then
        if ! add_user_nopasswd "$username"; then
            yellow "Пользователь создан, но настройку NOPASSWD не удалось применить."
        fi
    fi
    
    yellow "Проверяем какие права имеет пользователь $username"
    if [[ -n "$USE_SUDO" ]]; then
        sudo -l -U "$username" 2>/dev/null
        green "Если вы видите такую надпись (ALL : ALL) ALL то все нормально"
    fi
    
    purple "Пользователь $username создан."
}

# ============================================================
# СОЗДАНИЕ НОВОГО ПОЛЬЗОВАТЕЛЯ
# ============================================================

# Функция создания нового пользователя с интерактивным выбором параметров
new_user() {
    local target_groups=""
    local password password_confirm
    
    # Определяем группы в зависимости от наличия sudo
    if [[ -n "$USE_SUDO" ]]; then
        target_groups="sudo"
        [[ "$1" == "docker" ]] && target_groups="sudo,docker"
    else
        target_groups=""
        [[ "$1" == "docker" ]] && target_groups="docker"
    fi
    
    while true; do
        if [[ "$(prompt_yes_no "Хотите создать нового пользователя?" "no")" == "no" ]]; then
            break
        fi
        
        # Выбор имени пользователя
        while true; do
            local recommended_username
            recommended_username=$(head -c 64 /dev/urandom | tr -dc '[:lower:]' | head -c 1; head -c 64 /dev/urandom | tr -dc '[:lower:][:digit:]' | head -c 7)
            
            if [[ "$(prompt_yes_no "Рекомендуемое имя пользователя $recommended_username, оставить?" "yes")" == "yes" ]]; then
                username=$recommended_username
            else
                read -r -p "Введите имя пользователя: " username
            fi
            
            validate_username "$username" && break
        done
        
        # Проверка существования пользователя
        if id "$username" &>/dev/null; then
            echo "Пользователь $username уже существует."
            
            if [[ "$(prompt_yes_no "Хотите изменить пароль для пользователя $username?" "no")" == "yes" ]]; then
                change_user_password "$username"
            fi
            
            if [[ -n "$USE_SUDO" ]]; then
                local sudoers_found="no"
                if [[ -d /etc/sudoers.d ]] && grep -rqF "$username ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d 2>/dev/null; then
                    sudoers_found="yes"
                fi
                if [[ "$sudoers_found" == "yes" ]]; then
                    if [[ "$(prompt_yes_no "Хотите исключить пользователя $username из группы для выполнения команд без пароля?" "no")" == "yes" ]]; then
                        remove_user_nopasswd "$username"
                    fi
                else
                    if [[ "$(prompt_yes_no "Хотите добавить пользователя $username в группу для выполнения команд без пароля?" "no")" == "yes" ]]; then
                        add_user_nopasswd "$username"
                    fi
                fi
            fi
            
            # Добавляем в группу docker, если требуется
            [[ "$1" == "docker" ]] && add_user_to_docker "$username"
        else
            # Создание нового пользователя
            while true; do
                read -rs -p "Введите пароль для пользователя $username: " password
                echo

                if ! validate_password "$password"; then
                    unset password
                    continue
                fi

                read -rs -p "Повторите пароль для пользователя $username: " password_confirm
                echo

                if [[ "$password" != "$password_confirm" ]]; then
                    red "Пароли не совпадают. Попробуйте снова."
                    unset password password_confirm
                    continue
                fi
                unset password_confirm
                break
            done
            
            local nopass="no"
            if [[ -n "$USE_SUDO" ]]; then
                nopass=$(prompt_yes_no "Разрешить выполнение команд без пароля для $username?" "no")
            fi
            
            create_user "$username" "$password" "$nopass" "$target_groups"
            unset password
        fi
    done
}

