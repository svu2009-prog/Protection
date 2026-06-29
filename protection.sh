#!/bin/bash

# ============================================================
# СКРИПТ АВТОМАТИЗАЦИИ НАСТРОЙКИ СЕРВЕРА
# Совместимость: Ubuntu, Debian (с sudo и без sudo)
# ============================================================

# Переменные
DOCKER_INSTALLED=false
ROOT_PASSWORD=""
DISABLE_PING=""
ROOT_SSH_STATUS=""
PING_STATUS=""
CURRENT_SSH_PORT=""
username=""
password=""
SSH_PORT_AMNEZIAWG=""
output=""
check_xui=""
USE_SUDO=""
PROTECTION_VERSION="1.1.4"
PROTECTION_COMMAND_PATH="/usr/local/bin/protection"
DOCKER_MENU_VERSION=1
DOCKER_HELP_VERSION=1

# ============================================================
# КОНФИГУРАЦИЯ ПО УМОЛЧАНИЮ
# ============================================================

INFO_FILE="$(pwd)/info.txt"

F2B_BANTIME_DEFAULT=3600
F2B_FINDTIME_DEFAULT=2400
F2B_MAXRETRY_DEFAULT=3
F2B_SSHD_BANTIME=3600
F2B_RECIDIVE_BANTIME=604800
F2B_RECIDIVE_FINDTIME=172800
F2B_RECIDIVE_MAXRETRY=2


# Зарезервированные имена пользователей (системные)
RESERVED_USERNAMES=(root bin daemon adm lp sync shutdown halt mail news uucp operator games ftp nobody systemd-timesync systemd-network systemd-resolve systemd-bus-proxy sys log uuidd admin)

# ============================================================
# ОПРЕДЕЛЕНИЕ НАЛИЧИЯ SUDO
# ============================================================

# Проверка наличия sudo и определение префикса команд
check_sudo() {
    if command -v sudo &>/dev/null; then
        USE_SUDO="sudo"
    else
        USE_SUDO=""
        yellow "ВНИМАНИЕ: sudo не установлен, команды будут выполняться напрямую"
    fi
}

show_version() {
    echo "protection v${PROTECTION_VERSION}"
}

resolve_current_script_path() {
    local script_source="${BASH_SOURCE[0]}"

    if [[ -z "$script_source" || ! -f "$script_source" ]]; then
        return 1
    fi

    if command -v readlink &>/dev/null; then
        readlink -f "$script_source" 2>/dev/null && return 0
    fi

    local script_dir
    script_dir="$(cd "$(dirname "$script_source")" && pwd -P)" || return 1
    printf "%s/%s\n" "$script_dir" "$(basename "$script_source")"
}

compare_versions() {
    local current=$1 installed=$2
    local current_major current_minor current_patch installed_major installed_minor installed_patch

    if [[ ! "$installed" =~ ^[0-9]+(\.[0-9]+){2}$ ]]; then
        echo "older"
        return 0
    fi

    IFS=. read -r current_major current_minor current_patch <<< "$current"
    IFS=. read -r installed_major installed_minor installed_patch <<< "$installed"

    if (( installed_major == current_major && installed_minor == current_minor && installed_patch == current_patch )); then
        echo "same"
    elif (( installed_major > current_major || (installed_major == current_major && installed_minor > current_minor) || (installed_major == current_major && installed_minor == current_minor && installed_patch > current_patch) )); then
        echo "newer"
    else
        echo "older"
    fi
}

get_script_version() {
    local script_file=$1
    grep -m1 '^PROTECTION_VERSION=' "$script_file" 2>/dev/null | cut -d= -f2- | tr -d '"'
}

ensure_global_command() {
    local script_path installed_version version_status command_dir

    if ! script_path="$(resolve_current_script_path)"; then
        yellow "Не удалось определить путь к текущему скрипту, команда protection не создана."
        return 0
    fi

    if [[ -f "$PROTECTION_COMMAND_PATH" ]]; then
        installed_version="$(get_script_version "$PROTECTION_COMMAND_PATH")"
        version_status="$(compare_versions "$PROTECTION_VERSION" "$installed_version")"

        if [[ "$version_status" == "same" && ! -L "$PROTECTION_COMMAND_PATH" ]]; then
            return 0
        fi

        if [[ "$script_path" == "$PROTECTION_COMMAND_PATH" ]]; then
            yellow "Глобальная команда protection запущена из установленной копии. Для обновления запустите свежий protection.sh."
            return 0
        fi

        if [[ "$version_status" == "newer" ]]; then
            yellow "Установленная команда protection новее текущего скрипта: $installed_version > $PROTECTION_VERSION."
            return 0
        fi
    elif [[ "$script_path" == "$PROTECTION_COMMAND_PATH" ]]; then
        return 0
    fi

    command_dir="$(dirname "$PROTECTION_COMMAND_PATH")"

    if ! ${USE_SUDO} mkdir -p "$command_dir"; then
        red "Не удалось создать каталог $command_dir для команды protection."
        return 1
    fi

    if ! ${USE_SUDO} cp --remove-destination "$script_path" "$PROTECTION_COMMAND_PATH"; then
        red "Не удалось создать глобальную команду $PROTECTION_COMMAND_PATH."
        return 1
    fi

    if ! ${USE_SUDO} chmod +x "$PROTECTION_COMMAND_PATH"; then
        red "Не удалось сделать $PROTECTION_COMMAND_PATH исполняемым."
        return 1
    fi

    purple "Глобальная команда protection обновлена: $PROTECTION_COMMAND_PATH"
}

# ============================================================
# ФУНКЦИИ ДЛЯ ЦВЕТНОГО ВЫВОДА
# ============================================================

# Основная функция для цветного вывода
color_echo() {
    local color_code=$1 message=$2
    echo -e "\x1B[${color_code}m ${message} \x1B[0m"
}

# Цветные обертки для различных типов сообщений
black() { color_echo 90 "$1"; }
red() { color_echo 91 "$1"; }
green() { color_echo 92 "$1"; }
yellow() { color_echo 93 "$1"; }
blue() { color_echo 94 "$1"; }
purple() { color_echo 95 "$1"; }
cyan() { color_echo 96 "$1"; }
white() { color_echo 97 "$1"; }

case "${1:-}" in
    -v|--version)
        show_version
        exit 0
        ;;
esac

# ============================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ

# Удаление ANSI-кодов
strip_ansi() {
    sed -r "s/\x1B\[[0-9;]*[A-Za-z]//g"
}

# Отрисовка интерактивного меню для select_menu.
render_menu() {
    local title=$1 selected=$2 labels_name=$3 redraw=${4:-0}
    local -n labels_ref=$labels_name
    local menu_lines=$((${#labels_ref[@]} + 4))
    
    [[ -n "$title" ]] && menu_lines=$((menu_lines + 1))
    
    if [[ "$redraw" -eq 1 ]]; then
        printf "\033[%sA" "$menu_lines"
    fi
    
    printf "\033[2K"
    echo " "
    if [[ -n "$title" ]]; then
        printf "\033[2K"
        green "$title"
    fi
    printf "\033[2K"
    echo " "
    
    for i in "${!labels_ref[@]}"; do
        if [[ "$i" -eq "$selected" ]]; then
            printf "\033[2K\033[93m> %s\033[0m\n" "${labels_ref[$i]}"
        else
            printf "\033[2K\033[92m  %s\033[0m\n" "${labels_ref[$i]}"
        fi
    done
    
    printf "\033[2K"
    echo " "
    printf "\033[2K"
    yellow "Стрелки ↑/↓ - выбор, Enter - подтвердить, цифра - быстрый выбор"
}

# Универсальный выбор пункта меню стрелками, Enter или числом.
select_menu() {
    local title=$1 labels_name=$2 values_name=$3 selected=${4:-0}
    local -n labels_ref=$labels_name
    local -n values_ref=$values_name
    local key extra typed zero_value_index=-1
    
    MENU_CHOICE=""
    
    if [[ ${#labels_ref[@]} -eq 0 || ${#labels_ref[@]} -ne ${#values_ref[@]} ]]; then
        red "Ошибка меню: некорректный список пунктов."
        return 1
    fi
    
    for i in "${!values_ref[@]}"; do
        if [[ "${values_ref[$i]}" == "0" ]]; then
            zero_value_index=$i
            break
        fi
    done
    
    if [[ ! -t 0 ]]; then
        echo " "
        [[ -n "$title" ]] && green "$title"
        echo " "
        for i in "${!labels_ref[@]}"; do
            echo "${labels_ref[$i]}"
        done
        echo " "
        while true; do
            if ! read -r -p " Выберите пункт и нажмите ENTER: " MENU_CHOICE; then
                if [[ "$zero_value_index" -ge 0 ]]; then
                    MENU_CHOICE="0"
                    return 0
                fi
                MENU_CHOICE=""
                return 1
            fi
            for i in "${!values_ref[@]}"; do
                if [[ "${values_ref[$i]}" == "$MENU_CHOICE" ]]; then
                    return 0
                fi
            done
            red "Некорректный выбор."
        done
    fi
    
    [[ "$selected" =~ ^[0-9]+$ ]] || selected=0
    if [[ "$selected" -lt 0 || "$selected" -ge ${#labels_ref[@]} ]]; then
        selected=0
    fi
    
    tput civis 2>/dev/null || true
    local menu_rendered=0
    
    while true; do
        render_menu "$title" "$selected" "$labels_name" "$menu_rendered"
        menu_rendered=1
        IFS= read -rsn1 key
        
        case "$key" in
            "")
                MENU_CHOICE="${values_ref[$selected]}"
                tput cnorm 2>/dev/null || true
                echo " "
                return 0
                ;;
            $'\e')
                extra=""
                IFS= read -rsn2 -t 0.05 extra || true
                case "$extra" in
                    "[A"|OD)
                        ((selected--))
                        [[ "$selected" -lt 0 ]] && selected=$((${#labels_ref[@]} - 1))
                        ;;
                    "[B"|OC)
                        ((selected++))
                        [[ "$selected" -ge ${#labels_ref[@]} ]] && selected=0
                        ;;
                    "[C")
                        ((selected++))
                        [[ "$selected" -ge ${#labels_ref[@]} ]] && selected=0
                        ;;
                    "[D")
                        ((selected--))
                        [[ "$selected" -lt 0 ]] && selected=$((${#labels_ref[@]} - 1))
                        ;;
                    *)
                        if [[ "$zero_value_index" -ge 0 ]]; then
                            MENU_CHOICE="0"
                            tput cnorm 2>/dev/null || true
                            echo " "
                            return 0
                        fi
                        ;;
                esac
                ;;
            q|Q)
                if [[ "$zero_value_index" -ge 0 ]]; then
                    MENU_CHOICE="0"
                    tput cnorm 2>/dev/null || true
                    echo " "
                    return 0
                fi
                ;;
            [0-9])
                typed="$key"
                while IFS= read -rsn1 -t 0.35 extra; do
                    [[ "$extra" =~ ^[0-9]$ ]] || break
                    typed+="$extra"
                done
                for i in "${!values_ref[@]}"; do
                    if [[ "${values_ref[$i]}" == "$typed" ]]; then
                        MENU_CHOICE="$typed"
                        tput cnorm 2>/dev/null || true
                        echo " "
                        return 0
                    fi
                done
                ;;
        esac
    done
}

trap 'tput cnorm 2>/dev/null || true' EXIT

# ============================================================

# Проверка наличия интернета
check_internet() {
    # Проверка через ICMP
    if command -v ping &>/dev/null; then
        ping -c1 -W2 1.1.1.1 >/dev/null 2>&1 && return 0
        ping -c1 -W2 8.8.8.8 >/dev/null 2>&1 && return 0
    fi
    
    # Проверка через HTTP(S)
    if command -v curl &>/dev/null; then
        curl -fsS --max-time 5 https://deb.debian.org >/dev/null 2>&1 && return 0
        curl -fsS --max-time 5 https://archive.ubuntu.com >/dev/null 2>&1 && return 0
    fi
    
    if command -v wget &>/dev/null; then
        wget -q --timeout=5 --spider https://deb.debian.org >/dev/null 2>&1 && return 0
        wget -q --timeout=5 --spider https://archive.ubuntu.com >/dev/null 2>&1 && return 0
    fi
    
    return 1
}


# Проверка, занят ли порт
port_in_use() {
    local port=$1
    if command -v ss &>/dev/null; then
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$port$"
        return $?
    fi
    if command -v netstat &>/dev/null; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -q ":$port$"
        return $?
    fi
    return 1
}

# Короткий статус службы
service_short_status() {
    local svc=$1
    if systemctl is-active --quiet "$svc" 2>/dev/null; then
        green "$svc активен"
    else
        yellow "$svc не активен"
    fi
}

# Обработчик прерывания
on_interrupt() {
    red "Работа скрипта прервана пользователем."
    exit 1
}


# ============================================================
# ПРОВЕРКА ПРАВ И ИНИЦИАЛИЗАЦИЯ
# ============================================================

trap on_interrupt INT

# Проверка запуска от root
precheck() {
    if [[ $EUID -ne 0 ]]; then
        red "Этот скрипт должен быть запущен от пользователя root"
        exit 1
    fi
    
    # Определяем наличие sudo
    check_sudo
    
    # Если sudo не установлен, предлагаем установить
    if [[ -z "$USE_SUDO" ]]; then
        if [[ "$(prompt_yes_no "sudo не установлен. Установить sudo?" "no")" == "yes" ]]; then
            install_sudo_package
            check_sudo
        fi
    fi

    ensure_global_command
    
    main
}

# Установка пакета sudo
install_sudo_package() {
    # Проверка наличия интернета
    if ! check_internet; then
        red "Нет подключения к интернету."
        if [[ "$(prompt_yes_no "Продолжить без подключения?" "no")" == "no" ]]; then
            return
        fi
    fi

    green "Устанавливаем sudo..."
    apt update -y
    apt install sudo -y
    
    if command -v sudo &>/dev/null; then
        purple "sudo успешно установлен."
    else
        red "Ошибка при установке sudo."
    fi
}

# ============================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ ВАЛИДАЦИИ
# ============================================================

# Проверка порта (по умолчанию 1024-65535)
validate_port() {
    local port=$1
    local min=${2:-1024}
    local max=${3:-65535}
    [[ "$port" =~ ^[0-9]+$ && "$port" -ge "$min" && "$port" -le "$max" ]]
}

# Проверка порта SSH (диапазон 1024-65535)
validate_ssh_port() {
    validate_port "$1" 1024 65535
}

# Получение текущего порта SSH из конфигурации
get_ssh_port() {
    local port
    port=$(grep -i '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | xargs)
    [[ -z "$port" ]] && port=22
    echo "$port"
}

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

# Проверка имени пользователя
validate_username() {
    local username=$1
    
    # Проверка длины (от 4 до 32 символов)
    if [[ ${#username} -lt 4 || ${#username} -gt 32 ]]; then
        red "Имя пользователя должно быть от 4 до 32 символов."
        return 1
    fi
    
    # Проверка формата (буквы, цифры, дефисы, подчеркивания)
    if ! [[ "$username" =~ ^[A-Za-z_][A-Za-z0-9_-]*$ ]]; then
        red "Имя пользователя должно начинаться с буквы или подчеркивания и содержать только буквы, цифры, дефисы и подчеркивания."
        return 1
    fi
    
    # Проверка на зарезервированные имена
    for reserved in "${RESERVED_USERNAMES[@]}"; do
        if [[ "$username" == "$reserved" ]]; then
            red "Имя пользователя '$username' является зарезервированным."
            return 1
        fi
    done
    
    return 0
}

# Проверка пароля (минимум 12 символов, буквы верхнего/нижнего регистра, цифры)
validate_password() {
    local password=$1
    
    # Минимальная длина
    if [[ ${#password} -lt 12 ]]; then
        red "Пароль должен быть не менее 12 символов."
        return 1
    fi
    
    # Наличие строчных букв
    if ! echo "$password" | grep -qP "[a-zа-я]"; then
        red "Пароль должен содержать хотя бы одну букву нижнего регистра."
        return 1
    fi
    
    # Наличие заглавных букв
    if ! echo "$password" | grep -qP "[A-ZА-Я]"; then
        red "Пароль должен содержать хотя бы одну букву верхнего регистра."
        return 1
    fi
    
    # Наличие цифр
    if ! echo "$password" | grep -qP "[0-9]"; then
        red "Пароль должен содержать хотя бы одну цифру."
        return 1
    fi
    
    return 0
}

# ============================================================
# ФУНКЦИИ РАБОТЫ С UFW
# ============================================================

# Отключение UFW, если он активен
disable_ufw_if_active() {
    if ${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null | grep -q 'Status: active'; then
        ${USE_SUDO:+$USE_SUDO }ufw disable >/dev/null 2>&1
    fi
}

# ============================================================
# ФУНКЦИИ УПРАВЛЕНИЯ ПОЛЬЗОВАТЕЛЯМИ
# ============================================================

# Добавление пользователя в sudoers для выполнения команд без пароля
add_user_nopasswd() {
    local username=$1
    
    if [[ -z "$USE_SUDO" ]]; then
        yellow "sudo не установлен, пропускаем настройку NOPASSWD"
        return
    fi
    
    echo "$username ALL=(ALL) NOPASSWD:ALL" | tee "/etc/sudoers.d/$username" >/dev/null
    purple "Пользователь $username добавлен в группу для выполнения команд без пароля."
}

# Удаление пользователя из sudoers (возврат требования пароля)
remove_user_nopasswd() {
    local username=$1
    rm -f /etc/sudoers.d/$username
    purple "Пользователь $username исключен из группы для выполнения команд без пароля."
}

# Изменение пароля существующего пользователя
change_user_password() {
    local username=$1
    
    while true; do
        read -s -p "Введите новый пароль для пользователя $username: " password
        echo
        
        if validate_password "$password"; then
            read -s -p "Повторите новый пароль для пользователя $username: " password_confirm
            echo
            
            if [[ "$password" == "$password_confirm" ]]; then
                if echo "$username:$password" | chpasswd; then
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
    if [[ "$(prompt_yes_no "Хотите изменить пароль root?" "no")" == "no" ]]; then
        return
    fi
    
    while true; do
        read -s -p "Введите новый пароль для root: " ROOT_PASSWORD
        echo
        
        if validate_password "$ROOT_PASSWORD"; then
            read -s -p "Повторите новый пароль для root: " ROOT_PASSWORD_CONFIRM
            echo
            
            if [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]]; then
                if echo "root:$ROOT_PASSWORD" | chpasswd; then
                    green "Пароль root успешно изменен."
                    break
                else
                    red "Не удалось изменить пароль root."
                    break
                fi
            else
                red "Пароли не совпадают. Попробуйте снова."
            fi
        fi
    done
}

# ============================================================
# ФУНКЦИЯ ИНТЕРАКТИВНЫХ ЗАПРОСОВ
# ============================================================

# Запрос ответа yes/no с выбором по умолчанию
prompt_yes_no() {
    local prompt=$1
    local default=${2:-""}
    local default_hint=""
    
    case "$default" in
        [Yy]*) default_hint=" [YES]";;
        [Nn]*) default_hint=" [NO]";;
        *) default="";;
    esac
    
    while true; do
        read -p "$prompt (yes/no)$default_hint: " response
        [[ -z "$response" && -n "$default" ]] && response="$default"
        
        case "$response" in
            [Yy]*) echo "yes"; return 0;;
            [Nn]*) echo "no"; return 1;;
            *) red "Пожалуйста, введите 'yes' или 'no'.";;
        esac
    done
}

# ============================================================
# НАСТРОЙКА IPv6
# ============================================================

# Функция для отключения/включения IPv6
disable_ipv6() {
    # Проверяем текущий статус IPv6
    IPV6_STATUS_ALL=$(sysctl net.ipv6.conf.all.disable_ipv6 2>/dev/null | awk '{print $3}')
    IPV6_STATUS_DEFAULT=$(sysctl net.ipv6.conf.default.disable_ipv6 2>/dev/null | awk '{print $3}')
    IPV6_STATUS_LO=$(sysctl net.ipv6.conf.lo.disable_ipv6 2>/dev/null | awk '{print $3}')
    
    # Если IPv6 уже отключен
    if [[ "$IPV6_STATUS_ALL" == "1" && "$IPV6_STATUS_DEFAULT" == "1" && "$IPV6_STATUS_LO" == "1" ]]; then
        green "IPv6 уже отключен во всех интерфейсах."
        
        if [[ "$(prompt_yes_no "Хотите включить IPv6?" "no")" == "yes" ]]; then
            cp /etc/sysctl.conf /etc/sysctl.conf.bak
            sed -i '/net.ipv6.conf.all.disable_ipv6/d' /etc/sysctl.conf
            sed -i '/net.ipv6.conf.default.disable_ipv6/d' /etc/sysctl.conf
            sed -i '/net.ipv6.conf.lo.disable_ipv6/d' /etc/sysctl.conf
            sysctl -p >/dev/null 2>&1
            purple "IPv6 успешно включен."
        fi
        return
    fi
    
    # Предлагаем отключить IPv6
    if [[ "$(prompt_yes_no "Хотите отключить IPv6?" "no")" == "no" ]]; then
        return
    fi
    
    # Добавляем параметры отключения IPv6 в sysctl.conf
    tee -a /etc/sysctl.conf > /dev/null <<EOF
net.ipv6.conf.all.disable_ipv6 = 1
net.ipv6.conf.default.disable_ipv6 = 1
net.ipv6.conf.lo.disable_ipv6 = 1
EOF
    
    # Применяем изменения
    sysctl -p >/dev/null 2>&1
    
    # Проверяем, что IPv6 отключен
    if sysctl net.ipv6.conf.all.disable_ipv6 | grep -q "1" && \
       sysctl net.ipv6.conf.default.disable_ipv6 | grep -q "1" && \
       sysctl net.ipv6.conf.lo.disable_ipv6 | grep -q "1"; then
        purple "IPv6 успешно отключен во всех интерфейсах."
        green "Рекомендуется перезагрузить систему для полного применения изменений."
    else
        red "Ошибка при отключении IPv6. Проверьте настройки вручную."
    fi
}



# ============================================================
# ДОПОЛНИТЕЛЬНОЕ МЕНЮ ПОЛЬЗОВАТЕЛЕЙ
# ============================================================

# Получение списка несистемных пользователей
get_non_system_users() {
    getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "ubuntu" {print $1}' | grep -vE '(nologin|false|sync|halt|shutdown)'
}

# Выбор пользователя из списка
select_non_system_user() {
    local users_list=($(get_non_system_users))
    local user_labels=()
    local user_values=()
    
    if [[ ${#users_list[@]} -eq 0 ]]; then
        red "Нет подходящих пользователей."
        SELECTED_USER=""
        return 1
    fi
    
    for i in "${!users_list[@]}"; do
        user_labels+=("$((i+1)). ${users_list[$i]}")
        user_values+=("$((i+1))")
    done
    
    while true; do
        select_menu "Список доступных пользователей:" user_labels user_values
        user_num="$MENU_CHOICE"
        if [[ "$user_num" =~ ^[0-9]+$ && "$user_num" -ge 1 && "$user_num" -le ${#users_list[@]} ]]; then
            SELECTED_USER="${users_list[$((user_num-1))]}"
            return 0
        fi
        red "Некорректный выбор. Введите число от 1 до ${#users_list[@]}"
    done
}



# Выбор пользователя для SSH-ключей
select_user_for_ssh_keys() {
    local users_list=($(get_non_system_users))
    local user_labels=()
    local user_values=()
    
    if [[ ${#users_list[@]} -eq 0 ]]; then
        red "Нет подходящих пользователей."
        SELECTED_USER=""
        return 1
    fi
    
    for i in "${!users_list[@]}"; do
        user_labels+=("$((i+1)). ${users_list[$i]}")
        user_values+=("$((i+1))")
    done
    user_labels+=("$(( ${#users_list[@]} + 1 )). Ввести имя пользователя вручную")
    user_values+=("$(( ${#users_list[@]} + 1 ))")
    
    while true; do
        select_menu "Список доступных пользователей:" user_labels user_values
        user_num="$MENU_CHOICE"
        if [[ "$user_num" =~ ^[0-9]+$ ]]; then
            if [[ "$user_num" -ge 1 && "$user_num" -le ${#users_list[@]} ]]; then
                SELECTED_USER="${users_list[$((user_num-1))]}"
                return 0
            elif [[ "$user_num" -eq $(( ${#users_list[@]} + 1 )) ]]; then
                read -p "Введите имя пользователя: " manual_user
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
            fi
        fi
        red "Некорректный выбор. Введите число от 1 до $(( ${#users_list[@]} + 1 ))"
    done
}

# Подменю управления пользователями
users_menu() {
    local users_list=($(get_non_system_users))
    
    # Если пользователей нет — выполняем стандартное создание
    if [[ ${#users_list[@]} -eq 0 ]]; then
        new_user
        return
    fi
    
    while true; do
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
        local user_menu_values=(1 2 3 4 5 6 7 8 0)
        
        select_menu "Подменю управления пользователями" user_menu_labels user_menu_values
        USER_MENU="$MENU_CHOICE"
        
        case $USER_MENU in
            1)
                users_list=($(get_non_system_users))
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
                    read -p "Введите имя группы: " TARGET_GROUP
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
# НАСТРОЙКА SSH-КЛЮЧЕЙ
# ============================================================

setup_ssh_keys() {
    if ! select_user_for_ssh_keys; then
        return
    fi
    username="$SELECTED_USER"
    
    # Проверка и создание директории .ssh
    if [[ ! -d "/home/$username/.ssh" ]]; then
        ${USE_SUDO:+$USE_SUDO }mkdir -p "/home/$username/.ssh"
        ${USE_SUDO:+$USE_SUDO }chown "$username:$username" "/home/$username/.ssh"
        ${USE_SUDO:+$USE_SUDO }chmod 700 "/home/$username/.ssh"
    fi
    
    # Инструкции для пользователя
    red "Прежде чем продолжить, выполните следующие действия:"
    yellow "1. Запустите на компьютере с Windows программу: powershell.exe"
    yellow "2. Проверьте, что в папке пользователя есть папка .ssh. Если её нет, создайте её и скопируйте путь до неё."
    yellow "3. В PowerShell введите команду: cd путь_к_папке_ssh"
    yellow "4. Далее скопируйте и вставьте в PowerShell команду:"
    yellow "   - ssh-keygen -t ed25519 -C \"Комментарий\" -f Имя_файла -N Пароль"
    yellow "5. Введите команду: cat имя_файла.pub и скопируйте содержимое ключа."
    yellow "6. Вставьте это в открытом редакторе nano на сервере, сохраните и закройте редактор (Ctrl+X, Y, Enter)."
    echo
    
    # Ожидание подтверждения пользователя
    read -p "Если выполнили все действия до номера 5 включительно, нажмите ENTER: "
    
    # Открытие файла authorized_keys для редактирования
    ${USE_SUDO:+$USE_SUDO }nano "/home/$username/.ssh/authorized_keys"
    
    # Установка прав доступа
    ${USE_SUDO:+$USE_SUDO }chown -R "$username:$username" "/home/$username/.ssh"
    ${USE_SUDO:+$USE_SUDO }chmod 600 "/home/$username/.ssh/authorized_keys"
    ${USE_SUDO:+$USE_SUDO }systemctl restart ssh 2>/dev/null || ${USE_SUDO:+$USE_SUDO }systemctl restart sshd 2>/dev/null
    
    green "Настройка SSH-ключей для пользователя $username завершена."
}

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
    if [[ -n "$groups" ]]; then
        if ! useradd -m "$username" -G "$groups" -s /bin/bash; then
            red "Ошибка при создании пользователя $username."
            return 1
        fi
    else
        if ! useradd -m "$username" -s /bin/bash; then
            red "Ошибка при создании пользователя $username."
            return 1
        fi
    fi
    
    # Устанавливаем пароль
    if ! echo "$username:$password" | chpasswd; then
        red "Ошибка при установке пароля для пользователя $username."
        userdel -r "$username"
        return 1
    fi
    
    # Добавляем в sudoers без пароля, если требуется и sudo установлен
    if [[ "$nopass" == "yes" && -n "$USE_SUDO" ]]; then
        add_user_nopasswd "$username"
    fi
    
    yellow "Проверяем какие права имеет пользователь $username"
    if [[ -n "$USE_SUDO" ]]; then
        $USE_SUDO -l -U "$username" 2>/dev/null
        green "Если вы видите такую надпись (ALL : ALL) ALL то все нормально"
    fi
    
    purple "Пользователь $username создан."
}

# ============================================================
# БЛОКИРОВКА PING
# ============================================================

# Функция для отключения/включения ICMP ping
disable_ping() {
    if grep -q "^net.ipv4.icmp_echo_ignore_all" /etc/sysctl.conf; then
        PING_STATUS=$(grep '^net.ipv4.icmp_echo_ignore_all' /etc/sysctl.conf)
        
        if [[ "$PING_STATUS" == "net.ipv4.icmp_echo_ignore_all = 0" ]]; then
            if [[ "$(prompt_yes_no "Доступ к команде ping включен. Хотите отключить доступ к команде ping?" "no")" == "yes" ]]; then
                cp /etc/sysctl.conf /etc/sysctl.conf.bak
                sed -i 's/net.ipv4.icmp_echo_ignore_all .*/net.ipv4.icmp_echo_ignore_all = 1/' /etc/sysctl.conf
                sysctl -p >/dev/null 2>&1
                purple "Доступ к команде ping отключен."
            fi
        else
            if [[ "$(prompt_yes_no "Хотите включить доступ к команде ping?" "no")" == "yes" ]]; then
                cp /etc/sysctl.conf /etc/sysctl.conf.bak
                sed -i 's/net.ipv4.icmp_echo_ignore_all .*/net.ipv4.icmp_echo_ignore_all = 0/' /etc/sysctl.conf
                sysctl -p >/dev/null 2>&1
                purple "Доступ к команде ping включен."
            fi
        fi
    else
        if [[ "$(prompt_yes_no "Хотите отключить доступ к команде ping?" "no")" == "yes" ]]; then
            echo 'net.ipv4.icmp_echo_ignore_all = 1' | tee -a /etc/sysctl.conf >/dev/null
            sysctl -p >/dev/null 2>&1
            yellow "Доступ к команде ping отключен."
        fi
    fi
}

# ============================================================
# НАСТРОЙКА SSH
# ============================================================

# Отключение/включение входа root по SSH
disable_root_ssh() {
    # Определяем текущее значение PermitRootLogin (берем последнее в файле)
    ROOT_SSH_STATUS=$(grep -i '^\s*PermitRootLogin' /etc/ssh/sshd_config 2>/dev/null | tail -n 1 | awk '{print $2}')
    
    # Если параметра нет — считаем, что включен по умолчанию (prohibit-password/yes)
    if [[ -z "$ROOT_SSH_STATUS" ]]; then
        ROOT_SSH_STATUS="yes"
    fi
    
    if [[ "$ROOT_SSH_STATUS" == "no" ]]; then
        if [[ "$(prompt_yes_no "Вход root по SSH отключен. Хотите включить вход root по SSH?" "no")" == "yes" ]]; then
            cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
            if grep -qi '^\s*PermitRootLogin' /etc/ssh/sshd_config; then
                sed -i 's/^\s*PermitRootLogin.*/PermitRootLogin yes/I' /etc/ssh/sshd_config
            else
                echo "PermitRootLogin yes" | tee -a /etc/ssh/sshd_config >/dev/null
            fi
            ${USE_SUDO:+$USE_SUDO }systemctl restart ssh 2>/dev/null || ${USE_SUDO:+$USE_SUDO }systemctl restart sshd 2>/dev/null
            purple "Вход root по SSH включен."
        fi
    else
        if [[ "$(prompt_yes_no "Хотите отключить вход root по SSH?" "no")" == "yes" ]]; then
            cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
            if grep -qi '^\s*PermitRootLogin' /etc/ssh/sshd_config; then
                sed -i 's/^\s*PermitRootLogin.*/PermitRootLogin no/I' /etc/ssh/sshd_config
            else
                echo "PermitRootLogin no" | tee -a /etc/ssh/sshd_config >/dev/null
            fi
            ${USE_SUDO:+$USE_SUDO }systemctl restart ssh 2>/dev/null || ${USE_SUDO:+$USE_SUDO }systemctl restart sshd 2>/dev/null
            purple "Вход root по SSH отключен."
        fi
    fi
}


# Изменение порта SSH
change_port_ssh() {
    CURRENT_SSH_PORT=$(get_ssh_port)
    
    if [[ "$(prompt_yes_no "Порт SSH = $CURRENT_SSH_PORT, хотите изменить его?" "no")" == "no" ]]; then
        return
    fi
    
    disable_ufw_if_active
    
    while true; do
        read -p 'Введите новый порт SSH (от 1024 до 65535): ' NEW_SSH_PORT
        
        if validate_ssh_port "$NEW_SSH_PORT"; then
            if port_in_use "$NEW_SSH_PORT"; then
                red "Порт $NEW_SSH_PORT уже занят. Выберите другой."
                continue
            fi
            # Изменяем порт в конфигурации SSH
            cp /etc/ssh/sshd_config /etc/ssh/sshd_config.bak
            if grep -q "^Port " /etc/ssh/sshd_config; then
                sed -i "s/^Port .*/Port ${NEW_SSH_PORT}/" /etc/ssh/sshd_config
            else
                echo "Port $NEW_SSH_PORT" | tee -a /etc/ssh/sshd_config >/dev/null
            fi
            
            # Перезапускаем SSH (для Ubuntu и Debian)
            ${USE_SUDO:+$USE_SUDO }systemctl daemon-reload 2>/dev/null
            ${USE_SUDO:+$USE_SUDO }systemctl restart ssh.socket 2>/dev/null
            ${USE_SUDO:+$USE_SUDO }systemctl restart ssh 2>/dev/null || ${USE_SUDO:+$USE_SUDO }systemctl restart sshd 2>/dev/null
            
            purple "Порт SSH изменен на $NEW_SSH_PORT."
            CURRENT_SSH_PORT=$NEW_SSH_PORT
            break
        else
            red "Недопустимый порт. Порт должен быть в диапазоне от 1024 до 65535."
        fi
    done
}

# ============================================================
# НАСТРОЙКА UFW FIREWALL
# ============================================================

# Настройка UFW файрвола
setup_ufw() {
    # Проверка наличия интернета
    if ! check_internet; then
        red "Нет подключения к интернету."
        if [[ "$(prompt_yes_no "Продолжить без подключения?" "no")" == "no" ]]; then
            return
        fi
    fi

    # Устанавливаем ufw, если не установлен
    if ! dpkg -l | grep -q "^ii  ufw"; then
        apt install -yq ufw
    fi
    
    CHECK_UFW=$(${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null)
    
    if [[ "$CHECK_UFW" == "Status: inactive" ]]; then
        if [[ "$(prompt_yes_no "Хотите включить и настроить ufw?" "no")" == "no" ]]; then
            red "ufw не включен."
            return
        fi
        
        disable_ufw_if_active
        echo "y" | ${USE_SUDO:+$USE_SUDO }ufw reset >/dev/null 2>&1
        
        # Получаем текущий порт SSH
        CURRENT_SSH_PORT=$(get_ssh_port)
        
        # Разрешаем стандартные порты
        ufw_allow_port 443 tcp
        if validate_port "$CURRENT_SSH_PORT" 1 65535; then
            ufw_allow_port "$CURRENT_SSH_PORT" tcp
        else
            red "SSH порт из конфигурации некорректен: $CURRENT_SSH_PORT"
        fi
        
        # Проверяем наличие 3X-UI и добавляем его порт
        if command -v x-ui &>/dev/null; then
            output=$(x-ui settings 2>/dev/null | strip_ansi)
            PORT_X_UI=$(echo "$output" | grep -i "port:" | awk -F' ' '{print $2}' | xargs)
            if [[ -n "$PORT_X_UI" ]] && validate_port "$PORT_X_UI" 1 65535; then
                ufw_allow_port "$PORT_X_UI" tcp
            elif [[ -n "$PORT_X_UI" ]]; then
                red "Порт 3X-UI некорректен: $PORT_X_UI"
            fi
        fi
        
        # Включаем UFW
        echo "y" | ${USE_SUDO:+$USE_SUDO }ufw enable >/dev/null 2>&1
        purple "ufw настроен и включен."
    else
        if [[ "$(prompt_yes_no "UFW включен, но не настроен, хотите выключить?" "no")" == "yes" ]]; then
            echo "y" | ${USE_SUDO:+$USE_SUDO }ufw disable >/dev/null 2>&1
            echo "y" | ${USE_SUDO:+$USE_SUDO }ufw reset >/dev/null 2>&1
            purple "ufw отключен."
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
    ${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null | grep -qw "$rule" && return 0
    return 1
}

# Проверка и добавление портов, которые настраивает скрипт
ensure_ufw_ports() {
    # Получаем текущий порт SSH
    CURRENT_SSH_PORT=$(get_ssh_port)
    
    # 443/tcp
    if ! ufw_rule_exists "443/tcp"; then
        ufw_allow_port 443 tcp
        purple "Добавлен порт 443/tcp в UFW."
    fi
    
    # SSH порт
    if validate_port "$CURRENT_SSH_PORT" 1 65535 && ! ufw_rule_exists "$CURRENT_SSH_PORT/tcp"; then
        ufw_allow_port "$CURRENT_SSH_PORT" tcp
        purple "Добавлен порт $CURRENT_SSH_PORT/tcp в UFW."
    elif ! validate_port "$CURRENT_SSH_PORT" 1 65535; then
        red "SSH порт из конфигурации некорректен: $CURRENT_SSH_PORT"
    fi
    
    # Порт 3X-UI
    if command -v x-ui &>/dev/null; then
        output=$(x-ui settings 2>/dev/null)
        PORT_X_UI=$(echo "$output" | grep -i "port:" | awk -F' ' '{print $2}' | xargs)
        if [[ -n "$PORT_X_UI" ]] && validate_port "$PORT_X_UI" 1 65535; then
            if ! ufw_rule_exists "$PORT_X_UI/tcp"; then
                ufw_allow_port "$PORT_X_UI" tcp
                purple "Добавлен порт $PORT_X_UI/tcp в UFW."
            fi
        elif [[ -n "$PORT_X_UI" ]]; then
            red "Порт 3X-UI некорректен: $PORT_X_UI"
        fi
    fi
    

}

# Подменю управления UFW
ufw_menu() {
    # Если ufw не установлен или не активен — выполняем стандартную установку/настройку
    if ! dpkg -l | grep -q "^ii  ufw"; then
            setup_ufw
        return
    fi
    
    UFW_STATUS=$(${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null)
    if echo "$UFW_STATUS" | grep -q "Status: inactive"; then
            setup_ufw
        return
    fi
    
    # Проверяем и добавляем нужные порты
    ensure_ufw_ports
    
    while true; do
        local ufw_menu_labels=(
            "1. Показать статус"
            "2. Добавить порты TCP"
            "3. Добавить порты UDP"
            "4. Удалить порт"
            "5. Отключить ufw"
            "6. Включить ufw"
            "0. Назад"
        )
        local ufw_menu_values=(1 2 3 4 5 6 0)
        
        select_menu "Подменю управления Firewall UFW" ufw_menu_labels ufw_menu_values
        UFW_MENU="$MENU_CHOICE"
        
        case $UFW_MENU in
            1)
                service_short_status ufw
                ${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null
                ;;
            2)
                while true; do
                    read -p "Введите порты для добавления (TCP, через пробел): " UFW_TCP_PORTS
                    for UFW_TCP_PORT in $UFW_TCP_PORTS; do
                        if validate_port "$UFW_TCP_PORT" 1 65535; then
                            ufw_allow_port "$UFW_TCP_PORT" tcp
                            purple "Порт $UFW_TCP_PORT/tcp добавлен."
                        else
                            red "Недопустимый порт: $UFW_TCP_PORT. Пропускаем."
                        fi
                    done
                    break
                done
                ;;
            3)
                while true; do
                    read -p "Введите порты для добавления (UDP, через пробел): " UFW_UDP_PORTS
                    for UFW_UDP_PORT in $UFW_UDP_PORTS; do
                        if validate_port "$UFW_UDP_PORT" 1 65535; then
                            ufw_allow_port "$UFW_UDP_PORT" udp
                            purple "Порт $UFW_UDP_PORT/udp добавлен."
                        else
                            red "Недопустимый порт: $UFW_UDP_PORT. Пропускаем."
                        fi
                    done
                    break
                done
                ;;
            4)
                read -p "Введите порт для удаления: " UFW_DEL_PORT
                if ! validate_port "$UFW_DEL_PORT" 1 65535; then
                    red "Недопустимый порт. Порт должен быть в диапазоне от 1 до 65535."
                    continue
                fi
                read -p "Введите протокол (tcp/udp): " UFW_DEL_PROTO
                if [[ "$UFW_DEL_PROTO" != "tcp" && "$UFW_DEL_PROTO" != "udp" ]]; then
                    red "Некорректный протокол. Используйте tcp или udp."
                    continue
                fi
                if echo "y" | ${USE_SUDO:+$USE_SUDO }ufw delete allow "$UFW_DEL_PORT/$UFW_DEL_PROTO" >/dev/null 2>&1; then
                    purple "Правило $UFW_DEL_PORT/$UFW_DEL_PROTO удалено."
                else
                    red "Не удалось удалить правило $UFW_DEL_PORT/$UFW_DEL_PROTO."
                fi
                ;;
            5)
                if [[ "$(prompt_yes_no "Отключить ufw?" "no")" == "yes" ]]; then
                    echo "y" | ${USE_SUDO:+$USE_SUDO }ufw disable >/dev/null 2>&1
                    purple "ufw отключен."
                fi
                ;;
            6)
                # Перед включением проверяем, что SSH порт разрешен
                CURRENT_SSH_PORT=$(get_ssh_port)
                if ! validate_port "$CURRENT_SSH_PORT" 1 65535; then
                    red "SSH порт из конфигурации некорректен: $CURRENT_SSH_PORT"
                    break
                fi
                if ! ufw_rule_exists "$CURRENT_SSH_PORT/tcp"; then
                    if [[ "$(prompt_yes_no "SSH порт $CURRENT_SSH_PORT/tcp не разрешен. Добавить?" "no")" == "yes" ]]; then
                        ufw_allow_port "$CURRENT_SSH_PORT" tcp
                        purple "Добавлен порт $CURRENT_SSH_PORT/tcp."
                    else
                        red "Включение ufw отменено, чтобы не потерять доступ."
                        break
                    fi
                fi
                if [[ "$(prompt_yes_no "Включить ufw?" "no")" == "yes" ]]; then
                    echo "y" | ${USE_SUDO:+$USE_SUDO }ufw enable >/dev/null 2>&1
                    purple "ufw включен."
                fi
                ;;
            0)
                break
                ;;
            *)
                yellow "Введите число от 0 до 6 и нажмите ENTER"
                ;;
        esac
    done
}

# ============================================================
# FAIL2BAN
# ============================================================

# Установка и настройка fail2ban
install_fail2ban() {
    # Проверка наличия интернета
    if ! check_internet; then
        red "Нет подключения к интернету."
        if [[ "$(prompt_yes_no "Продолжить без подключения?" "no")" == "no" ]]; then
            return
        fi
    fi

    # Устанавливаем nftables, если не установлен
    if ! command -v nft &>/dev/null; then
        green "Устанавливаем nftables..."
        apt install -yq nftables
        systemctl enable nftables
        systemctl start nftables
        purple "nftables успешно установлен и запущен."
    else
        green "nftables уже установлен."
    fi
    
    # Устанавливаем fail2ban
    apt install -yq fail2ban
    
    if [[ "$(prompt_yes_no "Хотите настроить fail2ban?" "no")" == "no" ]]; then
        systemctl stop fail2ban
        systemctl disable fail2ban
        red "fail2ban отключен."
        return
    fi
    
    # Получаем текущий SSH порт для конфигурации
    CURRENT_SSH_PORT=$(get_ssh_port)
    
    # Создаем конфигурацию fail2ban
    cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
# Время бана по умолчанию (1 час)
bantime = $F2B_BANTIME_DEFAULT
findtime = $F2B_FINDTIME_DEFAULT
maxretry = $F2B_MAXRETRY_DEFAULT

# Разрешённые IP (добавьте свои после 127.0.0.1 через пробел)
ignoreip = 127.0.0.1/8 ::1

# Действие по умолчанию — iptables
banaction = iptables-multiport
banaction_allports = iptables-allports
backend = systemd

[sshd]
enabled = true
port = $CURRENT_SSH_PORT
filter = sshd
logpath = /var/log/auth.log
backend = polling
maxretry = 3
findtime = $F2B_FINDTIME_DEFAULT
bantime = $F2B_SSHD_BANTIME
banaction = iptables-multiport

[recidive]
enabled = true
filter = recidive
logpath = /var/log/fail2ban.log
backend  = polling
# Жёсткий бан за рецидив: 2 бана за 2 дня -> блокировка на неделю
bantime = $F2B_RECIDIVE_BANTIME
findtime = $F2B_RECIDIVE_FINDTIME
maxretry = $F2B_RECIDIVE_MAXRETRY
action = iptables-allports[name=recidive]
EOF
    
    systemctl enable fail2ban
    systemctl start fail2ban
    systemctl restart fail2ban
    purple "fail2ban установлен и настроен."
}



# ============================================================
# ДОПОЛНИТЕЛЬНОЕ МЕНЮ FAIL2BAN
# ============================================================



# Выбор jail для Fail2ban
select_fail2ban_jail() {
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



# Подменю управления Fail2ban
fail2ban_menu() {
    # Если fail2ban не установлен — выполняем стандартную установку/настройку
    if ! dpkg -l | grep -q "^ii  fail2ban"; then
        install_fail2ban
        return
    fi
    
    while true; do
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
            "0. Назад"
        )
        local fb_menu_values=(1 2 3 4 5 6 7 8 9 0)
        
        select_menu "Подменю управления Fail2ban" fb_menu_labels fb_menu_values
        FB_MENU="$MENU_CHOICE"
        
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
                    for j in $FB_JAILS; do
                        echo "- $j"
                    done
                    for j in $FB_JAILS; do
                        echo "------- Jail: $j -------"
                        fb_status=$(${USE_SUDO:+$USE_SUDO }fail2ban-client status "$j" 2>/dev/null)
                        echo "$fb_status"
                    done
                fi
                ;;
            4)
                if select_fail2ban_jail; then
                    echo "Список jail:"
                    for j in $FB_JAILS; do
                        echo "- $j"
                    done
                    for j in $FB_JAILS; do
                        echo "------- Jail: $j -------"
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
                    echo "Список jail:"
                    for j in $FB_JAILS; do
                        echo "- $j"
                    done
                    for j in $FB_JAILS; do
                        echo "------- Jail: $j -------"
                        fb_status=$(${USE_SUDO:+$USE_SUDO }fail2ban-client status "$j" 2>/dev/null)
                        echo "$fb_status"
                    done
                    local UNBAN_IP
                    read -p "Введите IP для разбана: " UNBAN_IP
                    if [[ -z "$UNBAN_IP" ]]; then
                        red "IP не указан."
                    else
                        for j in $FB_JAILS; do
                            ${USE_SUDO:+$USE_SUDO }fail2ban-client set "$j" unbanip "$UNBAN_IP" 2>/dev/null
                        done
                        purple "IP $UNBAN_IP разбанен во всех jail (если был в бане)."
                    fi
                fi
                ;;

            6)
                ${USE_SUDO:+$USE_SUDO }systemctl start fail2ban 2>/dev/null
                purple "fail2ban запущен."
                ;;
            7)
                ${USE_SUDO:+$USE_SUDO }systemctl stop fail2ban 2>/dev/null
                purple "fail2ban остановлен."
                ;;
            8)
                ${USE_SUDO:+$USE_SUDO }systemctl restart fail2ban 2>/dev/null
                purple "fail2ban перезапущен."
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
# ДОПОЛНИТЕЛЬНОЕ МЕНЮ DOCKER
# ============================================================

docker_menu() {
    while true; do
        local docker_menu_labels=(
            "1. Установить Docker"
            "2. Обновить Docker"
            "3. Обновить контейнеры (docker compose pull)"
            "4. Остановить все контейнеры"
            "5. Запустить все контейнеры"
            "6. Перезапустить все контейнеры"
            "7. Перезапустить контейнер по имени"
            "8. Показать все контейнеры"
            "9. Показать запущенные контейнеры"
            "10. Показать образы"
            "11. Очистить неиспользуемые образы/тома"
            "12. Очистка старых контейнеров"
            "13. Удалить все контейнеры"
            "14. Полное удаление Docker"
            "0. Назад"
        )
        local docker_menu_values=(1 2 3 4 5 6 7 8 9 10 11 12 13 14 0)
        local docker_version="не установлен"
        local compose_version="не установлен"
        local docker_menu_title
        
        if command -v docker &>/dev/null; then
            docker_version="$(docker --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
            if docker compose version --short >/dev/null 2>&1; then
                compose_version="$(docker compose version --short 2>/dev/null)"
            fi
        fi
        
        if [[ "$compose_version" == "не установлен" ]] && command -v docker-compose &>/dev/null; then
            compose_version="$(docker-compose --version 2>/dev/null | awk '{print $3}' | tr -d ',')"
        fi
        
        docker_menu_title="Подменю Docker | Docker: ${docker_version:-не установлен} | Compose: ${compose_version:-не установлен}"
        
        select_menu "$docker_menu_title" docker_menu_labels docker_menu_values
        DOCKER_MENU="$MENU_CHOICE"
        
        case $DOCKER_MENU in
            1)
                install_docker
                ;;
            2)
                if command -v docker &>/dev/null; then
                    if [[ "$(prompt_yes_no "Хотите обновить Docker?" "no")" == "yes" ]]; then
                        apt-get update
                        apt-get upgrade -y docker-ce docker-ce-cli containerd.io
                        purple "Docker успешно обновлен."
                    fi
                else
                    red "Docker не установлен."
                fi
                ;;
            3)
                if command -v docker &>/dev/null; then
                    if command -v docker-compose &>/dev/null || docker compose version >/dev/null 2>&1; then
                        if [[ "$(prompt_yes_no "Выполнить docker compose pull?" "no")" == "yes" ]]; then
                            if [[ -f docker-compose.yml || -f docker-compose.yaml || -f compose.yml || -f compose.yaml ]]; then
                                if command -v docker-compose &>/dev/null; then
                                    docker-compose pull
                                else
                                    docker compose pull
                                fi
                            else
                                local COMPOSE_PATH
                                read -p "Введите путь к файлу compose (или папке), или оставьте пустым для поиска: " COMPOSE_PATH
                                if [[ -z "$COMPOSE_PATH" ]]; then
                                    echo "Ищем compose-файлы в /opt, /srv, /root, /home (это может занять время)..."
                                    mapfile -t compose_files < <(find /opt /srv /root /home -maxdepth 6 -type f \( -name 'docker-compose.yml' -o -name 'docker-compose.yaml' -o -name 'compose.yml' -o -name 'compose.yaml' \) 2>/dev/null)
                                    if [[ ${#compose_files[@]} -eq 0 ]]; then
                                        red "Файлы compose не найдены."
                                    else
                                        local compose_labels=()
                                        local compose_values=()
                                        for i in "${!compose_files[@]}"; do
                                            compose_labels+=("$((i+1)). ${compose_files[$i]}")
                                            compose_values+=("$((i+1))")
                                        done
                                        select_menu "Найденные compose-файлы:" compose_labels compose_values
                                        local COMPOSE_NUM
                                        COMPOSE_NUM="$MENU_CHOICE"
                                        if [[ "$COMPOSE_NUM" =~ ^[0-9]+$ && "$COMPOSE_NUM" -ge 1 && "$COMPOSE_NUM" -le ${#compose_files[@]} ]]; then
                                            COMPOSE_PATH="${compose_files[$((COMPOSE_NUM-1))]}"
                                        else
                                            red "Некорректный выбор."
                                        fi
                                    fi
                                fi
                                if [[ -n "$COMPOSE_PATH" ]]; then
                                    if [[ -d "$COMPOSE_PATH" ]]; then
                                        if command -v docker-compose &>/dev/null; then
                                            (cd "$COMPOSE_PATH" && docker-compose pull)
                                        else
                                            (cd "$COMPOSE_PATH" && docker compose pull)
                                        fi
                                    elif [[ -f "$COMPOSE_PATH" ]]; then
                                        if command -v docker-compose &>/dev/null; then
                                            docker-compose -f "$COMPOSE_PATH" pull
                                        else
                                            docker compose -f "$COMPOSE_PATH" pull
                                        fi
                                    else
                                        red "Файл или папка не найдены."
                                    fi
                                fi
                            fi
                        fi
                    else
                        red "docker compose не найден."
                    fi
                else
                    red "Docker не установлен."
                fi
                ;;
            4)
                if command -v docker &>/dev/null; then
                    if [[ "$(prompt_yes_no "Остановить все контейнеры?" "no")" == "yes" ]]; then
                        mapfile -t running_containers < <(docker ps -q)
                        if [[ ${#running_containers[@]} -eq 0 ]]; then
                            yellow "Запущенные контейнеры не найдены."
                        elif docker stop "${running_containers[@]}" 2>/dev/null; then
                            purple "Все контейнеры остановлены."
                        else
                            red "Не удалось остановить все контейнеры."
                        fi
                    fi
                else
                    red "Docker не установлен."
                fi
                ;;
            5)
                if command -v docker &>/dev/null; then
                    if [[ "$(prompt_yes_no "Запустить все контейнеры?" "no")" == "yes" ]]; then
                        mapfile -t all_containers < <(docker ps -aq)
                        if [[ ${#all_containers[@]} -eq 0 ]]; then
                            yellow "Контейнеры не найдены."
                        elif docker start "${all_containers[@]}" 2>/dev/null; then
                            purple "Все контейнеры запущены."
                        else
                            red "Не удалось запустить все контейнеры."
                        fi
                    fi
                else
                    red "Docker не установлен."
                fi
                ;;
            6)
                if command -v docker &>/dev/null; then
                    if [[ "$(prompt_yes_no "Перезапустить все контейнеры?" "no")" == "yes" ]]; then
                        mapfile -t all_containers < <(docker ps -aq)
                        if [[ ${#all_containers[@]} -eq 0 ]]; then
                            yellow "Контейнеры не найдены."
                        elif docker restart "${all_containers[@]}" 2>/dev/null; then
                            purple "Все контейнеры перезапущены."
                        else
                            red "Не удалось перезапустить все контейнеры."
                        fi
                    fi
                else
                    red "Docker не установлен."
                fi
                ;;
            7)
                if command -v docker &>/dev/null; then
                    containers_list=($(docker ps -a --format "{{.Names}}"))
                    if [[ ${#containers_list[@]} -eq 0 ]]; then
                        red "Контейнеры не найдены."
                    else
                        local container_labels=()
                        local container_values=()
                        for i in "${!containers_list[@]}"; do
                            container_labels+=("$((i+1)). ${containers_list[$i]}")
                            container_values+=("$((i+1))")
                        done
                        container_labels+=("$(( ${#containers_list[@]} + 1 )). Ввести имя контейнера вручную")
                        container_values+=("$(( ${#containers_list[@]} + 1 ))")
                        
                        select_menu "Список контейнеров:" container_labels container_values
                        cnum="$MENU_CHOICE"
                        DOCKER_NAME=""
                        if [[ "$cnum" =~ ^[0-9]+$ ]]; then
                            if [[ "$cnum" -ge 1 && "$cnum" -le ${#containers_list[@]} ]]; then
                                DOCKER_NAME="${containers_list[$((cnum-1))]}"
                            elif [[ "$cnum" -eq $(( ${#containers_list[@]} + 1 )) ]]; then
                                read -p "Введите имя контейнера: " DOCKER_NAME
                            fi
                        fi
                        if [[ -z "$DOCKER_NAME" ]]; then
                            red "Имя контейнера не указано."
                        else
                            docker restart "$DOCKER_NAME" 2>/dev/null
                            if [[ $? -eq 0 ]]; then
                                purple "Контейнер $DOCKER_NAME перезапущен."
                            else
                                red "Не удалось перезапустить контейнер $DOCKER_NAME."
                            fi
                        fi
                    fi
                else
                    red "Docker не установлен."
                fi
                ;;
            8)
                if command -v docker &>/dev/null; then
                    docker ps -a
                else
                    red "Docker не установлен."
                fi
                ;;
            9)
                if command -v docker &>/dev/null; then
                    docker ps
                else
                    red "Docker не установлен."
                fi
                ;;
            10)
                if command -v docker &>/dev/null; then
                    docker images
                else
                    red "Docker не установлен."
                fi
                ;;
            11)
                if command -v docker &>/dev/null; then
                    if [[ "$(prompt_yes_no "Удалить неиспользуемые образы/тома?" "no")" == "yes" ]]; then
                        docker system prune -af --volumes
                        purple "Неиспользуемые образы и тома удалены."
                    fi
                else
                    red "Docker не установлен."
                fi
                ;;
            12)
                if command -v docker &>/dev/null; then
                    if [[ "$(prompt_yes_no "Удалить остановленные контейнеры?" "no")" == "yes" ]]; then
                        docker container prune -f
                        purple "Остановленные контейнеры удалены."
                    fi
                else
                    red "Docker не установлен."
                fi
                ;;
            13)
                if command -v docker &>/dev/null; then
                    if [[ "$(prompt_yes_no "Удалить все контейнеры?" "no")" == "yes" ]]; then
                        mapfile -t all_containers < <(docker ps -aq)
                        if [[ ${#all_containers[@]} -eq 0 ]]; then
                            yellow "Контейнеры не найдены."
                        elif docker rm -f "${all_containers[@]}" 2>/dev/null; then
                            purple "Все контейнеры удалены."
                        else
                            red "Не удалось удалить все контейнеры."
                        fi
                    fi
                else
                    red "Docker не установлен."
                fi
                ;;
            14)
                if [[ "$(prompt_yes_no "Полностью удалить Docker?" "no")" == "yes" ]]; then
                    ${USE_SUDO:+$USE_SUDO }systemctl stop docker 2>/dev/null
                    ${USE_SUDO:+$USE_SUDO }systemctl stop docker.socket 2>/dev/null
                    ${USE_SUDO:+$USE_SUDO }apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-compose >/dev/null 2>&1
                    ${USE_SUDO:+$USE_SUDO }apt-get autoremove -y >/dev/null 2>&1
                    ${USE_SUDO:+$USE_SUDO }rm -rf /var/lib/docker /var/lib/containerd
                    if command -v docker &>/dev/null; then
                        yellow "Docker удален не полностью: найден бинарник $(command -v docker). Проверьте альтернативный способ установки."
                    else
                        purple "Docker полностью удален."
                    fi
                fi
                ;;
            0)
                break
                ;;
            *)
                yellow "Введите число от 0 до 14 и нажмите ENTER"
                ;;
        esac
    done
}


# ============================================================
# DOCKER
# ============================================================

# Проверка наличия пользователей в группе docker
check_docker_users() {
    local raw
    raw=$(getent group docker 2>/dev/null | cut -d: -f4)
    [[ -n "$raw" ]]
}

# Добавление пользователя в группу docker
add_user_to_docker() {
    local username=$1
    
    if ! id "$username" &>/dev/null; then
        red "Пользователь $username не существует."
        return 1
    fi
    
    if groups "$username" | grep -q '\bdocker\b'; then
        green "Пользователь $username уже в группе docker."
        return 0
    fi
    
    if usermod -aG docker "$username"; then
        purple "Пользователь $username добавлен в группу docker."
        green "Не забудьте выйти и войти заново, чтобы изменения вступили в силу."
        return 0
    else
        red "Ошибка при добавлении пользователя $username в группу docker."
        return 1
    fi
}

# Выбор существующего пользователя для добавления в группу docker
select_existing_user() {
    # Получаем список несистемных пользователей (UID >= 1000), исключая ubuntu
    local users_list=($(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 && $1 != "ubuntu" {print $1}' | grep -vE '(nologin|false|sync|halt|shutdown)'))
    local user_labels=()
    local user_values=()
    
    if [[ ${#users_list[@]} -eq 0 ]]; then
        red "Нет подходящих пользователей для добавления в группу docker."
        if [[ "$(prompt_yes_no "Создать нового пользователя и добавить в группы sudo и docker?" "no")" == "yes" ]]; then
            new_user docker
        fi
        return 1
    fi
    
    for i in "${!users_list[@]}"; do
        user_labels+=("$((i+1)). ${users_list[$i]}")
        user_values+=("$((i+1))")
    done
    user_labels+=("$(( ${#users_list[@]} + 1 )). Создать нового пользователя")
    user_values+=("$(( ${#users_list[@]} + 1 ))")
    
    while true; do
        select_menu "Список доступных пользователей:" user_labels user_values
        user_num="$MENU_CHOICE"
        
        if [[ "$user_num" =~ ^[0-9]+$ ]]; then
            if [[ "$user_num" -ge 1 ]] && [[ "$user_num" -le ${#users_list[@]} ]]; then
                local selected_user="${users_list[$((user_num-1))]}"
                add_user_to_docker "$selected_user"
                return $?
            elif [[ "$user_num" -eq $(( ${#users_list[@]} + 1 )) ]]; then
                new_user docker
                return $?
            fi
        fi
        
        red "Некорректный выбор. Введите число от 1 до $(( ${#users_list[@]} + 1 ))"
    done
}

# Установка Docker
install_docker() {

    # Проверка наличия интернета
    if ! check_internet; then
        red "Нет подключения к интернету."
        if [[ "$(prompt_yes_no "Продолжить без подключения?" "no")" == "no" ]]; then
            return
        fi
    fi

    if command -v docker &>/dev/null; then
        DOCKER_INSTALLED=true
        green "Docker уже установлен."
        
        # Проверяем наличие пользователей в группе docker
        if ! check_docker_users; then
            yellow "Внимание: нет пользователей в группе docker."
            
            if [[ "$(prompt_yes_no "Добавить существующего пользователя в группу docker?" "no")" == "yes" ]]; then
                select_existing_user
            elif [[ "$(prompt_yes_no "Создать нового пользователя и добавить в группы sudo и docker?" "no")" == "yes" ]]; then
                new_user docker
            fi
        fi
        
        if [[ "$(prompt_yes_no "Хотите обновить Docker?" "no")" == "yes" ]]; then
            apt-get update
            apt-get upgrade -y docker-ce docker-ce-cli containerd.io
            purple "Docker успешно обновлен."
        fi
        
        return
    fi
    
    if [[ "$(prompt_yes_no "Хотите установить Docker?" "no")" == "no" ]]; then
        return
    fi
    if ! command -v curl &>/dev/null; then
        green "Устанавливаем curl..."
        apt-get update
        apt-get install -y curl
    fi
    
    if ! command -v curl &>/dev/null; then
        if ! command -v wget &>/dev/null; then
            green "Устанавливаем wget..."
            apt-get update
            apt-get install -y wget
        fi
        if command -v wget &>/dev/null; then
            green "curl недоступен, используем wget для установки Docker..."
            yellow "ВНИМАНИЕ: Следующая команда скачает и запустит скрипт с get.docker.com."
            yellow "Убедитесь, что вы доверяете источнику, перед продолжением."
            wget -qO- https://get.docker.com | sh
            return
        fi
    fi

    
    green "Устанавливаем Docker..."
    yellow "ВНИМАНИЕ: Следующая команда скачает и запустит скрипт с get.docker.com."
    yellow "Убедитесь, что вы доверяете источнику, перед продолжением."
    apt-get update
    curl -fsSL https://get.docker.com | sh
    
    DOCKER_INSTALLED=true
    
    # Проверяем установку
    if docker --version &>/dev/null; then
        purple "Docker успешно установлен. Версия: $(docker --version | awk '{print $3}' | tr -d ',')"
        
        # После установки предлагаем добавить пользователя
        if ! check_docker_users; then
            yellow "Внимание: Docker установлен, но нет пользователей в группе docker."
            if [[ "$(prompt_yes_no "Добавить существующего пользователя в группу docker?" "no")" == "yes" ]]; then
                select_existing_user
            elif [[ "$(prompt_yes_no "Создать нового пользователя и добавить в группы sudo и docker?" "no")" == "yes" ]]; then
                new_user docker
            fi
        fi
    else
        red "Ошибка при установке Docker."
    fi
}

# ============================================================
# СОЗДАНИЕ НОВОГО ПОЛЬЗОВАТЕЛЯ
# ============================================================

# Функция создания нового пользователя с интерактивным выбором параметров
new_user() {
    local target_groups=""
    
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
            recommended_username=$(head /dev/urandom | tr -dc a-z | head -c 1; head /dev/urandom | tr -dc a-z0-9 | head -c 7)
            
            if [[ "$(prompt_yes_no "Рекомендуемое имя пользователя $recommended_username, оставить?" "yes")" == "yes" ]]; then
                username=$recommended_username
            else
                read -p "Введите имя пользователя: " username
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
                if grep -q "$username ALL=(ALL) NOPASSWD:ALL" /etc/sudoers.d/* 2>/dev/null; then
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
                recommended_password=$(head /dev/urandom | tr -dc A-Za-z0-9 | head -c 15)
                
                if [[ "$(prompt_yes_no "Рекомендуемый пароль пользователя $recommended_password, оставить?" "yes")" == "yes" ]]; then
                    password=$recommended_password
                else
                    read -s -p "Введите пароль для пользователя $username: " password
                    echo
                    
                    if ! validate_password "$password"; then
                        continue
                    fi
                    
                    read -s -p "Повторите пароль для пользователя $username: " password_confirm
                    echo
                    
                    if [[ "$password" != "$password_confirm" ]]; then
                        red "Пароли не совпадают. Попробуйте снова."
                        continue
                    fi
                fi
                break
            done
            
            local nopass="no"
            if [[ -n "$USE_SUDO" ]]; then
                nopass=$(prompt_yes_no "Разрешить выполнение команд без пароля для $username?" "no")
            fi
            
            create_user "$username" "$password" "$nopass" "$target_groups"
        fi
    done
}

# ============================================================
# ВЫВОД ИНФОРМАЦИИ В ФАЙЛ
# ============================================================

# Функция для сохранения всех настроек в файл
out_file() {
    echo "" | tee $INFO_FILE
    
    CURRENT_SSH_PORT=$(get_ssh_port)
    
    [[ -n "$ROOT_PASSWORD" ]] && echo "Пароль root = $ROOT_PASSWORD" | tee -a $INFO_FILE
    [[ -n "$CURRENT_SSH_PORT" ]] && echo "Порт SSH = $CURRENT_SSH_PORT" | tee -a $INFO_FILE
    [[ -n "$username" ]] && echo "Новый пользователь = $username" | tee -a $INFO_FILE
    [[ -n "$password" ]] && echo "Пароль нового пользователя = $password" | tee -a $INFO_FILE

    if [[ -n "$ROOT_PASSWORD" || -n "$password" ]]; then
        echo "" | tee -a $INFO_FILE
        echo "ВНИМАНИЕ: Данный файл содержит пароли в открытом виде!" | tee -a $INFO_FILE
        echo "Рекомендуется удалить файл $INFO_FILE после сохранения паролей в безопасном месте." | tee -a $INFO_FILE
    fi
    echo "" | tee -a $INFO_FILE
    
    # Проверяем наличие 3X-UI
    if command -v x-ui &>/dev/null || [[ -f /usr/local/x-ui/x-ui.service ]] || systemctl list-unit-files 2>/dev/null | grep -q '^x-ui'; then
        echo "------- Настройки для панели 3X-UI --------" | tee -a $INFO_FILE
        if command -v x-ui &>/dev/null; then
            output=$(x-ui settings 2>/dev/null | strip_ansi)
            PORT_X_UI=$(echo "$output" | grep -i "port:" | awk -F' ' '{print $2}' | xargs)
            USER_X_UI=$(echo "$output" | grep -i "username:" | awk -F' ' '{print $2}' | xargs)
            PASS_X_UI=$(echo "$output" | grep -i "password:" | awk -F' ' '{print $2}' | xargs)
            WEB_X_UI=$(echo "$output" | grep -i "webBasePath:" | awk -F' ' '{print $2}' | xargs)
            ACC_X_UI=$(echo "$output" | grep -i "Access URL:" | awk -F' ' '{print $3}' | xargs)
            
            echo "username: $USER_X_UI" | tee -a $INFO_FILE
            echo "password: $PASS_X_UI" | tee -a $INFO_FILE
            echo "port: $PORT_X_UI" | tee -a $INFO_FILE
            echo "webBasePath: $WEB_X_UI" | tee -a $INFO_FILE
            echo "Access URL: $ACC_X_UI" | tee -a $INFO_FILE
        else
            echo "x-ui команда не найдена, пропускаем чтение настроек." | tee -a $INFO_FILE
        fi
        
        if [[ "$check_xui" == "yes" ]]; then
            echo "------- Сертификаты --------" | tee -a $INFO_FILE
            echo "Путь к файлу ПУБЛИЧНОГО ключа сертификата - /etc/ssl/self_signed_cert/self_signed.crt" | tee -a $INFO_FILE
            echo "Путь к файлу ПРИВАТНОГО ключа сертификата - /etc/ssl/self_signed_cert/self_signed.key" | tee -a $INFO_FILE
        fi
    fi
}



# ============================================================
# СПРАВКА
# ============================================================

show_help() {
    echo " "
    green "Справка (подробно):"
    echo "1. Обновить пакеты — обновляет систему (apt update/upgrade). Возможные проблемы: перезапуск сервисов, сбои при обновлении."
    echo "2. Поменять пароль ROOT — изменяет пароль root. Возможные проблемы: потеря доступа при забытом пароле."
    yellow "Рекомендуется: сохранить пароль в надежном месте."
    echo "3. Поменять порт SSH — меняет порт SSH и перезапускает службу. Возможные проблемы: потеря доступа, если порт закрыт в firewall."
    yellow "Рекомендуется: заранее открыть порт в UFW и проверить доступ."
    echo "4. Пользователи — управление пользователями и группами. Возможные проблемы: удаление пользователя с home удалит данные."
    echo "5. Отключить/включить PING — меняет sysctl. Возможные проблемы: диагностика сети затруднится."
    echo "6. Отключить/включить IPv6 — меняет sysctl. Возможные проблемы: сервисы/туннели могут перестать работать."
    echo "7. Настроить SSH ключи — добавляет ключ в authorized_keys пользователя. Возможные проблемы: ошибка доступа при неверных правах."
    echo "8. Fail2ban — защита от брутфорса, управление jail. Возможные проблемы: можно заблокировать себя при ошибках."
    yellow "Рекомендуется: добавить свой IP в ignoreip."
    echo "9. UFW — настройка firewall и управление правилами. Возможные проблемы: блокировка SSH при неверных правилах."
    yellow "Рекомендуется: убедиться, что SSH порт разрешен до включения."
    echo "10. Вход ROOT по SSH — включает/отключает root. Возможные проблемы: потеря доступа при отсутствии другого пользователя."
    yellow "Рекомендуется: иметь отдельного пользователя с sudo."
    echo "11. Docker — подменю управления: установка, обновление, чистка и контейнеры. Возможные проблемы: остановка сервисов, удаление данных контейнеров."
    echo "12. Справка — показывает это описание."
    echo " "
    if [[ "$DOCKER_MENU_VERSION" != "$DOCKER_HELP_VERSION" ]]; then
        yellow "ВНИМАНИЕ: справка Docker может не соответствовать меню."
    fi
    green "Справка по Docker‑подменю:"
    echo "1. Установить Docker — устанавливает Docker. Возможные проблемы: конфликт пакетов/репозиториев."
    echo "2. Обновить Docker — обновляет docker-ce/cli/containerd. Возможные проблемы: перезапуск сервисов."
    echo "3. Обновить контейнеры (docker compose pull) — тянет новые образы. Возможные проблемы: несовместимость новых версий."
    echo "4. Остановить все контейнеры — останавливает все контейнеры. Возможные проблемы: остановка сервисов."
    echo "5. Запустить все контейнеры — запускает все контейнеры. Возможные проблемы: ошибки старта."
    echo "6. Перезапустить все контейнеры — перезапуск всех контейнеров. Возможные проблемы: кратковременный даунтайм."
    echo "7. Перезапустить контейнер по имени — перезапуск выбранного контейнера. Возможные проблемы: даунтайм контейнера."
    echo "8. Показать все контейнеры — выводит все контейнеры."
    echo "9. Показать запущенные контейнеры — выводит активные контейнеры."
    echo "10. Показать образы — выводит Docker образы."
    echo "11. Очистить неиспользуемые образы/тома — удаляет неиспользуемые ресурсы. Возможные проблемы: удаление нужных томов."
    echo "12. Очистка старых контейнеров — удаляет остановленные контейнеры. Возможные проблемы: потеря истории контейнеров."
    echo "13. Удалить все контейнеры — удаляет все контейнеры. Возможные проблемы: остановка сервисов, потеря данных."
    echo "14. Полное удаление Docker — удаляет Docker и данные /var/lib/docker. Возможные проблемы: потеря всех данных Docker."
    echo " "

}






# ============================================================
# ОСНОВНОЕ МЕНЮ
# ============================================================

# Главное меню скрипта
main() {
    while true; do
        local main_menu_labels=(
            "1. Обновить пакеты"
            "2. Поменять пароль ROOT"
            "3. Поменять порт SSH"
            "4. Создать нового пользователя"
            "5. Отключить\\включить доступ к команде PING"
            "6. Отключить\\включить IPv6"
            "7. Настроить SSH ключи"
            "8. Настроить, отключить\\включить Fail2ban"
            "9. Настроить, отключить\\включить Firewall UFW"
            "10. Отключить\\включить вход ROOT по SSH"
            "11. Docker"
            "12. Справка"
            "0. Выйти"
        )
        local main_menu_values=(1 2 3 4 5 6 7 8 9 10 11 12 0)
        
        select_menu "Основное меню | protection v${PROTECTION_VERSION}" main_menu_labels main_menu_values
        NUMBER="$MENU_CHOICE"
        
        case $NUMBER in
            0)
                out_file
                break
                ;;
            1)
                apt update && apt upgrade -y && apt autoremove -y && apt clean
                ;;
            2)
                change_root_pass
                ;;
            3)
                change_port_ssh
                ;;
            4)
                users_menu
                ;;
            5)
                disable_ping
                ;;
            6)
                disable_ipv6
                ;;
            7)
                setup_ssh_keys
                ;;
            8)
                fail2ban_menu
                ;;
            9)
                ufw_menu
                ;;
            10)
                disable_root_ssh
                ;;
            11)
                docker_menu
                ;;
            12)
                show_help
                ;;
            *)
                yellow "Введите число от 0 до 12 и нажмите ENTER"
                ;;
        esac
    done
    
    exit
}

# ============================================================
# ЗАПУСК СКРИПТА
# ============================================================

precheck
