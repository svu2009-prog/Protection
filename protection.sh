#!/bin/bash

set -o pipefail

# ============================================================
# СКРИПТ АВТОМАТИЗАЦИИ НАСТРОЙКИ СЕРВЕРА
# Совместимость: Ubuntu, Debian (с sudo и без sudo)
# ============================================================

# Переменные
ROOT_PASSWORD=""
ROOT_SSH_STATUS=""
PING_STATUS=""
CURRENT_SSH_PORT=""
username=""
password=""
USE_SUDO=""
PROTECTION_VERSION="1.3.0"
PROTECTION_COMMAND_PATH="/usr/local/bin/protection"

# ============================================================
# КОНФИГУРАЦИЯ ПО УМОЛЧАНИЮ
# ============================================================

INFO_FILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd -P)"
[[ -z "$INFO_FILE_DIR" ]] && INFO_FILE_DIR="/root"
INFO_FILE="$INFO_FILE_DIR/info.txt"

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

    # Валидируем формат обеих версий (MAJOR.MINOR.PATCH, только цифры)
    if [[ ! "$current" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        echo "older"
        return 0
    fi
    if [[ ! "$installed" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]]; then
        echo "older"
        return 0
    fi

    IFS=. read -r current_major current_minor current_patch <<< "$current"
    IFS=. read -r installed_major installed_minor installed_patch <<< "$installed"

    # Пустые компоненты (напр. "1.2" без patch) приводим к 0
    : "${current_patch:=0}"
    : "${installed_patch:=0}"

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
    grep -m1 '^PROTECTION_VERSION=' "$script_file" 2>/dev/null | cut -d= -f2- | tr -d '"' | tr -d '\r'
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

    if ! ${USE_SUDO:+$USE_SUDO }mkdir -p "$command_dir"; then
        red "Не удалось создать каталог $command_dir для команды protection."
        return 1
    fi

    if ! ${USE_SUDO:+$USE_SUDO }cp --remove-destination "$script_path" "$PROTECTION_COMMAND_PATH"; then
        red "Не удалось создать глобальную команду $PROTECTION_COMMAND_PATH."
        return 1
    fi

    if ! ${USE_SUDO:+$USE_SUDO }chmod +x "$PROTECTION_COMMAND_PATH"; then
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
    printf '\033[%sm %s \033[0m\n' "$color_code" "$message"
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
    yellow "Стрелки ↑/↓ - выбор, Enter - подтвердить, цифра + Enter - выбор по номеру"
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
                if [[ -n "$typed" ]]; then
                    for i in "${!values_ref[@]}"; do
                        if [[ "${values_ref[$i]}" == "$typed" ]]; then
                            MENU_CHOICE="$typed"
                            tput cnorm 2>/dev/null || true
                            echo " "
                            return 0
                        fi
                    done
                    red "Некорректный выбор."
                    typed=""
                else
                    MENU_CHOICE="${values_ref[$selected]}"
                    tput cnorm 2>/dev/null || true
                    echo " "
                    return 0
                fi
                ;;
            $'\e')
                typed=""
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
                typed=""
                if [[ "$zero_value_index" -ge 0 ]]; then
                    MENU_CHOICE="0"
                    tput cnorm 2>/dev/null || true
                    echo " "
                    return 0
                fi
                ;;
            [0-9])
                typed+="$key"
                echo -n "$key"
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
        ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":$port\$"
        return $?
    fi
    if command -v netstat &>/dev/null; then
        netstat -ltn 2>/dev/null | awk '{print $4}' | grep -qE ":$port\$"
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
    if apt update -y && apt install sudo -y; then
        if command -v sudo &>/dev/null; then
            purple "sudo успешно установлен."
        else
            red "sudo установлен, но binary недоступен в PATH."
        fi
    else
        red "Ошибка при установке sudo (apt update/install завершился с ошибкой)."
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
    # Фактическое значение (учитывает Include sshd_config.d), fallback на основной конфиг
    port=$(sshd -T 2>/dev/null | awk '/^port[[:space:]]/ {print $2; exit}')
    [[ -z "$port" ]] && port=$(grep -i '^Port' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | xargs)
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
    
    # Наличие строчных букв (POSIX-классы не зависят от локали, в отличие от [a-zа-яё])
    if ! [[ "$password" =~ [[:lower:]] ]]; then
        red "Пароль должен содержать хотя бы одну букву нижнего регистра."
        return 1
    fi

    # Наличие заглавных букв
    if ! [[ "$password" =~ [[:upper:]] ]]; then
        red "Пароль должен содержать хотя бы одну букву верхнего регистра."
        return 1
    fi

    # Наличие цифр
    if ! [[ "$password" =~ [[:digit:]] ]]; then
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
    if chmod 0440 "/etc/sudoers.d/$username" 2>/dev/null; then
        purple "Пользователь $username добавлен в группу для выполнения команд без пароля."
    else
        red "Не удалось выставить права 0440 на /etc/sudoers.d/$username — sudo может игнорировать файл."
    fi
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
        read -rs -p "Введите новый пароль для root: " ROOT_PASSWORD
        echo
        
        if validate_password "$ROOT_PASSWORD"; then
            read -rs -p "Повторите новый пароль для root: " ROOT_PASSWORD_CONFIRM
            echo
            
            if [[ "$ROOT_PASSWORD" == "$ROOT_PASSWORD_CONFIRM" ]]; then
                if printf '%s\n' "root:$ROOT_PASSWORD" | chpasswd; then
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
        read -r -p "$prompt (yes/no)$default_hint: " response
        [[ -z "$response" && -n "$default" ]] && response="$default"
        
        case "$response" in
            [Yy]*) echo "yes"; return 0;;
            [Nn]*) echo "no"; return 1;;
            *) red "Пожалуйста, введите 'yes' или 'no'." >&2;;
        esac
    done
}

# ============================================================
# SYSCTL ДРОП-ИН
# ============================================================

# Запись ключей в /etc/sysctl.d/99-protection.conf (с бекапом), удаление
# легаси-записей этих ключей из /etc/sysctl.conf и точечное применение.
# Аргументы: пары "ключ=значение". Возвращает 0, если все ключи применились.
apply_sysctl_keys() {
    local dropin="/etc/sysctl.d/99-protection.conf"
    local pair key esc failed=0
    local -A managed_keys=()
    local preserved_lines=() line existing_key failed_keys=""

    # Ключи, которые перезаписываются этим вызовом
    for pair in "$@"; do
        managed_keys["${pair%%=*}"]=1
    done

    # Сохраняем ключи из существующего дроп-ина, которые этот вызов не перезаписывает
    # (иначе, например, отключение ping затирало настройку IPv6 и наоборот)
    if [[ -f "$dropin" ]]; then
        cp "$dropin" "$dropin.bak" || { red "Не удалось создать резервную копию $dropin."; return 1; }
        while IFS= read -r line; do
            [[ "$line" =~ ^[[:space:]]*([A-Za-z0-9._-]+)[[:space:]]*= ]] || continue
            existing_key="${BASH_REMATCH[1]}"
            [[ -n "${managed_keys[$existing_key]:-}" ]] && continue
            preserved_lines+=("$line")
        done < "$dropin"
    fi

    {
        echo "# Файл управляется скриптом protection"
        if (( ${#preserved_lines[@]} )); then
            for line in "${preserved_lines[@]}"; do
                echo "$line"
            done
        fi
        for pair in "$@"; do
            echo "$pair"
        done
    } > "$dropin" || { red "Не удалось записать $dropin."; return 1; }
    chmod 644 "$dropin" 2>/dev/null

    # Легаси-записи в /etc/sysctl.conf применяются при загрузке после дроп-ина,
    # поэтому их нужно убрать, иначе они перебьют наш файл
    if [[ -f /etc/sysctl.conf ]]; then
        for pair in "$@"; do
            key="${pair%%=*}"
            esc=$(printf '%s' "$key" | sed 's/\./\\./g')
            if grep -qE "^[[:space:]]*${esc}[[:space:]]*=" /etc/sysctl.conf 2>/dev/null; then
                cp /etc/sysctl.conf /etc/sysctl.conf.bak || { red "Не удалось создать резервную копию sysctl.conf."; return 1; }
                break
            fi
        done
        for pair in "$@"; do
            key="${pair%%=*}"
            esc=$(printf '%s' "$key" | sed 's/\./\\./g')
            sed -i -E "/^[[:space:]]*${esc}[[:space:]]*=/d" /etc/sysctl.conf 2>/dev/null
        done
    fi

    for pair in "$@"; do
        if ! sysctl -w "$pair" >/dev/null 2>&1; then
            failed=1
            failed_keys="$failed_keys ${pair%%=*}"
        fi
    done
    if [[ -n "$failed_keys" ]]; then
        red "sysctl -w не смог применить ключи:$failed_keys"
    fi
    return "$failed"
}

# ============================================================
# НАСТРОЙКА IPv6
# ============================================================

# Фактическая проверка доступности IPv6-стека: ключи sysctl существуют и читаются.
ipv6_stack_available() {
    [[ -r /proc/sys/net/ipv6/conf/all/disable_ipv6 ]]
}

# Добавление модуля ipv6 в автозагрузку (systemd-modules-load), чтобы модуль
# загружался при старте системы до применения sysctl-дроп-инов.
ensure_ipv6_module_autoload() {
    local autoload_conf="/etc/modules-load.d/protection-ipv6.conf"

    if [[ -f "$autoload_conf" ]] && grep -qxE 'ipv6' "$autoload_conf" 2>/dev/null; then
        return 0
    fi
    if mkdir -p /etc/modules-load.d 2>/dev/null && echo "ipv6" > "$autoload_conf" 2>/dev/null; then
        purple "Модуль ipv6 добавлен в автозагрузку: $autoload_conf"
    else
        yellow "Не удалось добавить модуль ipv6 в автозагрузку ($autoload_conf)."
    fi
}

# Проверка и загрузка модуля ядра ipv6.
# Возвращает 0, если IPv6-стек доступен (sysctl-ключи существуют), иначе 1.
ensure_ipv6_module() {
    # IPv6-стек уже активен — sysctl-ключи существуют, включение/отключение будет работать
    if ipv6_stack_available; then
        return 0
    fi

    # Ядро загружено с ipv6.disable=1 — модуль не поможет, нужны правки параметров загрузки
    if grep -q 'ipv6.disable=1' /proc/cmdline 2>/dev/null; then
        red "Ядро загружено с параметром ipv6.disable=1 (/proc/cmdline) — IPv6 отключен на уровне ядра."
        red "Удалите ipv6.disable=1 из параметров загрузки (GRUB) и перезагрузите сервер."
        return 1
    fi

    # modprobe может отсутствовать в PATH при нестандартном окружении — добавляем стандартные пути
    export PATH="$PATH:/usr/sbin:/sbin"

    # modprobe отсутствует — устанавливаем пакет kmod
    if ! command -v modprobe &>/dev/null; then
        if ! check_internet; then
            red "Нет подключения к интернету."
            if [[ "$(prompt_yes_no "Продолжить без подключения?" "no")" == "no" ]]; then
                return 1
            fi
        fi
        green "Устанавливаем kmod (modprobe)..."
        if apt update -y && apt install -yq kmod; then
            if command -v modprobe &>/dev/null; then
                purple "kmod успешно установлен."
            else
                red "kmod установлен, но modprobe недоступен в PATH."
                return 1
            fi
        else
            red "Ошибка при установке kmod (apt update/install завершился с ошибкой)."
            return 1
        fi
    fi

    # Пытаемся загрузить модуль ipv6 (явный modprobe работает даже при blacklist)
    green "Модуль IPv6 не загружен. Загружаем..."
    local modprobe_err
    modprobe_err=$(${USE_SUDO:+$USE_SUDO }modprobe ipv6 2>&1)
    if ipv6_stack_available; then
        purple "Модуль IPv6 успешно загружен."
        ensure_ipv6_module_autoload
        return 0
    fi

    # Не удалось — ищем блокировки в конфигурации modprobe (blacklist / alias off /
    # options disable=1 / install-заглушка), включая /usr/lib/modprobe.d и /lib/modprobe.d
    local blocked_files bf
    blocked_files=$(grep -Eils '^[[:space:]]*(blacklist[[:space:]]+ipv6([[:space:]]|$)|alias[[:space:]]+net-pf-10[[:space:]]+off([[:space:]]|$)|options[[:space:]]+ipv6[[:space:]]+disable=1|install[[:space:]]+ipv6[[:space:]]+/bin/(true|false))' /etc/modprobe.d/*.conf /usr/lib/modprobe.d/*.conf /lib/modprobe.d/*.conf 2>/dev/null | while IFS= read -r f; do readlink -f "$f" 2>/dev/null; done | sort -u)

    if [[ -n "$blocked_files" ]]; then
        yellow "Модуль IPv6 заблокирован в конфигурации modprobe:"
        echo "$blocked_files"
        if [[ "$(prompt_yes_no "Закомментировать блокирующие записи (будут созданы резервные копии) и повторить загрузку?" "no")" == "yes" ]]; then
            while IFS= read -r bf; do
                [[ -n "$bf" ]] || continue
                cp "$bf" "$bf.bak" 2>/dev/null
                sed -i -E 's@^[[:space:]]*(blacklist[[:space:]]+ipv6([[:space:]]|$)|alias[[:space:]]+net-pf-10[[:space:]]+off([[:space:]]|$)|options[[:space:]]+ipv6[[:space:]]+disable=1|install[[:space:]]+ipv6[[:space:]]+/bin/(true|false))@## protection: &@' "$bf" 2>/dev/null
            done <<< "$blocked_files"
            ${USE_SUDO:+$USE_SUDO }modprobe ipv6 2>/dev/null
            if ipv6_stack_available; then
                purple "Модуль IPv6 успешно загружен."
                ensure_ipv6_module_autoload
                return 0
            fi
        fi
    fi

    red "Не удалось загрузить модуль IPv6: ${modprobe_err:-modprobe не дал вывода}."
    red "Проверьте вручную: modprobe ipv6; lsmod | grep ipv6; конфигурацию /etc/modprobe.d; наличие модуля в /lib/modules/$(uname -r)."
    return 1
}

# Прямая запись значения disable_ipv6 в каждый существующий интерфейс через /proc.
# Нужно, потому что на части ядер запись в conf.all/default не затрагивает уже
# поднятые интерфейсы. Прямая запись работает и для имён с точкой (eth0.100).
ipv6_set_all_interfaces() {
    local value=$1 iface_dir iface
    for iface_dir in /proc/sys/net/ipv6/conf/*; do
        [[ -f "$iface_dir/disable_ipv6" ]] || continue
        iface="${iface_dir##*/}"
        if echo "$value" > "$iface_dir/disable_ipv6" 2>/dev/null; then
            green "  $iface: disable_ipv6=$value"
        else
            yellow "  $iface: не удалось записать disable_ipv6=$value"
        fi
    done
}

# Проверка статуса отключения IPv6: возвращает 0, если all/default/lo = 1
ipv6_is_disabled() {
    local v_all v_def v_lo
    v_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    v_def=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)
    v_lo=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null)
    [[ "$v_all" == "1" && "$v_def" == "1" && "$v_lo" == "1" ]]
}

# Проверка статуса включения IPv6: возвращает 0, если all/default/lo = 0
ipv6_is_enabled() {
    local v_all v_def v_lo
    v_all=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    v_def=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)
    v_lo=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null)
    [[ "$v_all" == "0" && "$v_def" == "0" && "$v_lo" == "0" ]]
}

# Диагностика при неудачном применении настроек IPv6
ipv6_diagnostics() {
    yellow "Диагностика:"
    if command -v lsmod &>/dev/null; then
        lsmod 2>/dev/null | grep -E '^ipv6' || yellow "  модуль ipv6 не отображается в lsmod"
    fi
    echo "  Текущие значения sysctl:"
    sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6 2>&1 | sed 's/^/    /'
    if [[ -f /etc/sysctl.d/99-protection.conf ]]; then
        echo "  Содержимое /etc/sysctl.d/99-protection.conf:"
        sed 's/^/    /' /etc/sysctl.d/99-protection.conf
    fi
}

# Функция для отключения/включения IPv6
disable_ipv6() {
    # Без модуля ipv6 sysctl-ключи недоступны — включение/отключение IPv6 не работает
    if ! ensure_ipv6_module; then
        red "Модуль IPv6 не установлен/не загружен. Включение/отключение IPv6 невозможно."
        return 1
    fi

    # Проверяем текущий статус IPv6
    IPV6_STATUS_ALL=$(sysctl -n net.ipv6.conf.all.disable_ipv6 2>/dev/null)
    IPV6_STATUS_DEFAULT=$(sysctl -n net.ipv6.conf.default.disable_ipv6 2>/dev/null)
    IPV6_STATUS_LO=$(sysctl -n net.ipv6.conf.lo.disable_ipv6 2>/dev/null)

    # Если IPv6 уже отключен
    if ipv6_is_disabled; then
        green "IPv6 уже отключен во всех интерфейсах."

        if [[ "$(prompt_yes_no "Хотите включить IPv6?" "no")" == "yes" ]]; then
            # Записываем параметры включения IPv6 в дроп-ин
            if ! apply_sysctl_keys \
                "net.ipv6.conf.all.disable_ipv6=0" \
                "net.ipv6.conf.default.disable_ipv6=0" \
                "net.ipv6.conf.lo.disable_ipv6=0"; then
                red "Ошибка применения sysctl. Проверьте /etc/sysctl.d/99-protection.conf."
            fi

            # Повторное применение через sysctl -p/--system (как при ручной настройке)
            if ! ipv6_is_enabled; then
                green "Повторное применение настроек через sysctl -p и sysctl --system..."
                ${USE_SUDO:+$USE_SUDO }sysctl -p /etc/sysctl.d/99-protection.conf >/dev/null 2>&1
                ${USE_SUDO:+$USE_SUDO }sysctl --system >/dev/null 2>&1
            fi

            # Прямая запись в каждый существующий интерфейс
            if ! ipv6_is_enabled; then
                green "Прямая запись disable_ipv6=0 в интерфейсы..."
                ipv6_set_all_interfaces 0
            fi

            if ipv6_is_enabled; then
                ensure_ipv6_module_autoload
                purple "IPv6 успешно включен."
            else
                red "Не удалось включить IPv6."
                ipv6_diagnostics
            fi
        fi
        return
    fi

    # Предлагаем отключить IPv6
    if [[ "$(prompt_yes_no "Хотите отключить IPv6?" "no")" == "no" ]]; then
        return
    fi

    # Записываем параметры отключения IPv6 в дроп-ин
    if ! apply_sysctl_keys \
        "net.ipv6.conf.all.disable_ipv6=1" \
        "net.ipv6.conf.default.disable_ipv6=1" \
        "net.ipv6.conf.lo.disable_ipv6=1"; then
        red "Ошибка применения sysctl. Проверьте /etc/sysctl.d/99-protection.conf."
    fi

    # Повторное применение через sysctl -p/--system (как при ручной настройке)
    if ! ipv6_is_disabled; then
        green "Повторное применение настроек через sysctl -p и sysctl --system..."
        ${USE_SUDO:+$USE_SUDO }sysctl -p /etc/sysctl.d/99-protection.conf >/dev/null 2>&1
        ${USE_SUDO:+$USE_SUDO }sysctl --system >/dev/null 2>&1
    fi

    # Прямая запись в каждый существующий интерфейс (all/default не всегда
    # затрагивают уже поднятые интерфейсы)
    if ! ipv6_is_disabled; then
        green "Прямая запись disable_ipv6=1 в интерфейсы..."
        ipv6_set_all_interfaces 1
    fi

    # Проверяем, что IPv6 отключен
    if ipv6_is_disabled; then
        ensure_ipv6_module_autoload
        purple "IPv6 успешно отключен во всех интерфейсах."
        green "Рекомендуется перезагрузить систему для полного применения изменений."
    else
        red "Ошибка при отключении IPv6. Проверьте настройки вручную."
        ipv6_diagnostics
    fi
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
# НАСТРОЙКА SSH-КЛЮЧЕЙ
# ============================================================

# Валидация sshd_config и безопасный рестарт sshd с авто-восстановлением из .bak.
# Возвращает 0 при успехе, 1 при провале (конфиг восстановлен, если был бэкап).
validate_and_restart_sshd() {
    local sshd_config="/etc/ssh/sshd_config"
    local sshd_bak="${sshd_config}.bak"

    # Предварительная проверка синтаксиса sshd_config
    if ! ${USE_SUDO:+$USE_SUDO }sshd -t 2>/dev/null; then
        red "Ошибка: sshd_config невалиден (sshd -t завершился с ошибкой)."
        if [[ -f "$sshd_bak" ]]; then
            ${USE_SUDO:+$USE_SUDO }cp "$sshd_bak" "$sshd_config"
            yellow "sshd_config восстановлен из резервной копии $sshd_bak."
            # Повторная проверка восстановленного конфига
            if ! ${USE_SUDO:+$USE_SUDO }sshd -t 2>/dev/null; then
                red "Внимание: восстановленный sshd_config тоже невалиден — проверьте вручную!"
                return 1
            fi
        else
            red "Резервная копия $sshd_bak не найдена — невозможно восстановить."
            return 1
        fi
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

setup_ssh_keys() {
    if ! select_non_system_user manual; then
        return
    fi
    username="$SELECTED_USER"
    
    # Проверка и создание директории .ssh
    if [[ ! -d "/home/$username/.ssh" ]]; then
        if ! ${USE_SUDO:+$USE_SUDO }mkdir -p "/home/$username/.ssh" ||
            ! ${USE_SUDO:+$USE_SUDO }chown "$username:$username" "/home/$username/.ssh" ||
            ! ${USE_SUDO:+$USE_SUDO }chmod 700 "/home/$username/.ssh"; then
            red "Не удалось подготовить каталог .ssh для пользователя $username."
            return 1
        fi
    elif ! ${USE_SUDO:+$USE_SUDO }chown "$username:$username" "/home/$username/.ssh" ||
        ! ${USE_SUDO:+$USE_SUDO }chmod 700 "/home/$username/.ssh"; then
        red "Не удалось проверить права каталога .ssh для пользователя $username."
        return 1
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
    read -r -p "Если выполнили все действия до номера 5 включительно, нажмите ENTER: "
    
    # Открытие файла authorized_keys для редактирования
    if ! command -v nano &>/dev/null; then
        red "nano не установлен. Установите его: apt install nano"
        return
    fi
    if ! ${USE_SUDO:+$USE_SUDO }nano "/home/$username/.ssh/authorized_keys"; then
        red "Редактор nano завершился с ошибкой."
        return 1
    fi

    # Установка прав доступа
    if [[ ! -s "/home/$username/.ssh/authorized_keys" ]] ||
        ! ${USE_SUDO:+$USE_SUDO }chown -R "$username:$username" "/home/$username/.ssh" ||
        ! ${USE_SUDO:+$USE_SUDO }chmod 600 "/home/$username/.ssh/authorized_keys"; then
        red "Не удалось проверить или установить права SSH-ключей для пользователя $username."
        return 1
    fi
    if ! validate_and_restart_sshd; then
        return 1
    fi
    
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
    if ! printf '%s\n' "$username:$password" | chpasswd; then
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
        sudo -l -U "$username" 2>/dev/null
        green "Если вы видите такую надпись (ALL : ALL) ALL то все нормально"
    fi
    
    purple "Пользователь $username создан."
}

# ============================================================
# БЛОКИРОВКА PING
# ============================================================

# Функция для отключения/включения ICMP ping
disable_ping() {
    # Фактическое значение ядра (учитывает и sysctl.conf, и дроп-ины)
    PING_STATUS=$(sysctl -n net.ipv4.icmp_echo_ignore_all 2>/dev/null)

    if [[ "$PING_STATUS" == "1" ]]; then
        if [[ "$(prompt_yes_no "Доступ к команде ping отключен. Хотите включить?" "no")" == "yes" ]]; then
            if apply_sysctl_keys "net.ipv4.icmp_echo_ignore_all=0"; then
                purple "Доступ к команде ping включен."
            else
                red "Ошибка применения sysctl. Проверьте /etc/sysctl.d/99-protection.conf."
            fi
        fi
    else
        if [[ "$(prompt_yes_no "Хотите отключить доступ к команде ping?" "no")" == "yes" ]]; then
            if apply_sysctl_keys "net.ipv4.icmp_echo_ignore_all=1"; then
                purple "Доступ к команде ping отключен."
            else
                red "Ошибка применения sysctl. Проверьте /etc/sysctl.d/99-protection.conf."
            fi
        fi
    fi
}

# ============================================================
# НАСТРОЙКА SSH
# ============================================================

# Установка значения PermitRootLogin (с бекапом и рестартом sshd)
set_permit_root_login() {
    local value=$1
    local sshd_dropin="/etc/ssh/sshd_config.d/00-protection.conf"
    mkdir -p "$(dirname "$sshd_dropin")" || { red "Не удалось создать каталог drop-in SSH."; return 1; }
    if [[ -f "$sshd_dropin" ]]; then
        cp "$sshd_dropin" "$sshd_dropin.bak" || { red "Не удалось создать резервную копию SSH drop-in."; return 1; }
    fi
    if [[ -f "$sshd_dropin" ]]; then
        if ! sed -i -E "/^[[:space:]]*PermitRootLogin[[:space:]]/d; 1iPermitRootLogin $value" "$sshd_dropin"; then
            red "Не удалось изменить PermitRootLogin."
            return 1
        fi
    elif ! printf 'PermitRootLogin %s\n' "$value" > "$sshd_dropin"; then
        red "Не удалось изменить PermitRootLogin."
        return 1
    fi
    if ! validate_and_restart_sshd; then
        red "Не удалось применить PermitRootLogin $value."
        [[ -f "$sshd_dropin.bak" ]] && cp "$sshd_dropin.bak" "$sshd_dropin" || rm -f "$sshd_dropin"
        return 1
    fi
    if [[ "$(sshd -T 2>/dev/null | awk '/^permitrootlogin/ {print $2; exit}')" != "$value" ]]; then
        red "Эффективное значение PermitRootLogin не совпало с ожидаемым: $value."
        [[ -f "$sshd_dropin.bak" ]] && cp "$sshd_dropin.bak" "$sshd_dropin" || rm -f "$sshd_dropin"
        validate_and_restart_sshd >/dev/null 2>&1
        return 1
    fi
}

# Отключение/включение входа root по SSH
disable_root_ssh() {
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
    local NEW_SSH_PORT
    CURRENT_SSH_PORT=$(get_ssh_port)
    
    if [[ "$(prompt_yes_no "Порт SSH = $CURRENT_SSH_PORT, хотите изменить его?" "no")" == "no" ]]; then
        return
    fi

    while true; do
        read -r -p 'Введите новый порт SSH (от 1024 до 65535): ' NEW_SSH_PORT
        
        if validate_ssh_port "$NEW_SSH_PORT"; then
            if port_in_use "$NEW_SSH_PORT"; then
                red "Порт $NEW_SSH_PORT уже занят. Выберите другой."
                continue
            fi
            local sshd_dropin="/etc/ssh/sshd_config.d/00-protection.conf"
            mkdir -p "$(dirname "$sshd_dropin")" || { red "Не удалось создать каталог drop-in SSH."; return 1; }
            if [[ -f "$sshd_dropin" ]]; then
                cp "$sshd_dropin" "$sshd_dropin.bak" || { red "Не удалось создать резервную копию SSH drop-in."; return 1; }
            fi

            # Открываем новый порт в UFW до рестарта sshd (если UFW активен)
            if ${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null | grep -q 'Status: active'; then
                if ! ufw_allow_port "$NEW_SSH_PORT" tcp; then
                    red "Не удалось открыть порт $NEW_SSH_PORT/tcp в UFW. SSH-конфигурация не изменена."
                    return 1
                fi
            fi

            if [[ -f "$sshd_dropin" ]]; then
                if ! sed -i -E "/^[[:space:]]*Port[[:space:]]/d; 1iPort $NEW_SSH_PORT" "$sshd_dropin"; then
                    red "Не удалось изменить порт SSH."
                    return 1
                fi
            elif ! printf 'Port %s\n' "$NEW_SSH_PORT" > "$sshd_dropin"; then
                red "Не удалось изменить порт SSH."
                return 1
            fi

            # Перезапускаем SSH (для Ubuntu и Debian) с валидацией и авто-restore
            ${USE_SUDO:+$USE_SUDO }systemctl daemon-reload 2>/dev/null
            ${USE_SUDO:+$USE_SUDO }systemctl restart ssh.socket 2>/dev/null
            if ! validate_and_restart_sshd; then
                red "Не удалось применить новый порт SSH. Проверьте конфигурацию вручную."
                [[ -f "$sshd_dropin.bak" ]] && cp "$sshd_dropin.bak" "$sshd_dropin" || rm -f "$sshd_dropin"
                validate_and_restart_sshd >/dev/null 2>&1
                return 1
            fi
            if [[ "$(get_ssh_port)" != "$NEW_SSH_PORT" ]]; then
                red "Эффективный порт SSH не совпал с ожидаемым: $NEW_SSH_PORT."
                [[ -f "$sshd_dropin.bak" ]] && cp "$sshd_dropin.bak" "$sshd_dropin" || rm -f "$sshd_dropin"
                validate_and_restart_sshd >/dev/null 2>&1
                return 1
            fi

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
    if ! dpkg-query -W -f='${Status}' ufw 2>/dev/null | grep -q "install ok installed"; then
        if ! apt update -y || ! apt install -yq ufw; then
            red "Не удалось установить UFW."
            return 1
        fi
    fi

    if ! command -v ufw >/dev/null 2>&1; then
        red "UFW установлен, но команда ufw недоступна."
        return 1
    fi
    
    local CHECK_UFW=$(${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null)
    
    if [[ "$CHECK_UFW" == "Status: inactive" ]]; then
        if [[ "$(prompt_yes_no "Хотите включить и настроить ufw?" "no")" == "no" ]]; then
            red "ufw не включен."
            return
        fi
        
        disable_ufw_if_active
        if ! echo "y" | ${USE_SUDO:+$USE_SUDO }ufw reset >/dev/null 2>&1; then
            red "Ошибка при сбросе правил ufw (ufw reset)."
            return 1
        fi

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
    ${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null | grep -qwF "$rule" && return 0
    return 1
}

# Проверка и добавление портов, которые настраивает скрипт
ensure_ufw_ports() {
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
    # Если ufw не установлен или не активен — выполняем стандартную установку/настройку
    if ! dpkg-query -W -f='${Status}' ufw 2>/dev/null | grep -q "install ok installed"; then
            setup_ufw
        return
    fi
    
    local UFW_STATUS=$(${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null)
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
            "4. Удалить порт из списка"
            "5. Отключить ufw"
            "6. Включить ufw"
            "0. Назад"
        )
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
                local UFW_RULES_RAW=$(${USE_SUDO:+$USE_SUDO }ufw status 2>/dev/null | grep -i " ALLOW " | awk '{print $1}')
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
                    echo "y" | ${USE_SUDO:+$USE_SUDO }ufw disable >/dev/null 2>&1
                    purple "ufw отключен."
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

    if ! apt update -y; then
        red "Не удалось обновить индекс пакетов."
        return 1
    fi

    # Устанавливаем nftables, если не установлен
    if ! command -v nft &>/dev/null; then
        green "Устанавливаем nftables..."
        if ! apt install -yq nftables; then
            red "Не удалось установить nftables."
            return 1
        fi
        if systemctl enable nftables 2>/dev/null && systemctl start nftables 2>/dev/null; then
            purple "nftables успешно установлен и запущен."
        else
            yellow "nftables установлен, но не удалось включить/запустить службу. Проверьте вручную."
        fi
    else
        green "nftables уже установлен."
    fi
    
    # Устанавливаем fail2ban
    if ! apt install -yq fail2ban || ! command -v fail2ban-client >/dev/null 2>&1; then
        red "Не удалось установить fail2ban."
        return 1
    fi
    
    if [[ "$(prompt_yes_no "Хотите настроить fail2ban?" "no")" == "no" ]]; then
        systemctl stop fail2ban
        systemctl disable fail2ban
        red "fail2ban отключен."
        return
    fi
    
    # Получаем текущий SSH порт для конфигурации
    CURRENT_SSH_PORT=$(get_ssh_port)
    
    # Резервная копия существующего jail.local (если есть)
    if [[ -f /etc/fail2ban/jail.local ]]; then
        cp /etc/fail2ban/jail.local /etc/fail2ban/jail.local.bak || { red "Не удалось создать резервную копию jail.local."; return 1; }
    fi

    # Создаем конфигурацию fail2ban
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
bantime = $F2B_SSHD_BANTIME

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

    if ! fail2ban-client -t >/dev/null 2>&1; then
        red "Конфигурация fail2ban не прошла проверку. Восстанавливаем резервную копию."
        if [[ -f /etc/fail2ban/jail.local.bak ]]; then
            cp /etc/fail2ban/jail.local.bak /etc/fail2ban/jail.local
        else
            rm -f /etc/fail2ban/jail.local
        fi
        return 1
    fi
    
    if ! ${USE_SUDO:+$USE_SUDO }systemctl enable fail2ban ||
        ! ${USE_SUDO:+$USE_SUDO }systemctl start fail2ban; then
        red "Не удалось включить или запустить fail2ban."
        return 1
    fi
    if ! ${USE_SUDO:+$USE_SUDO }systemctl restart fail2ban; then
        red "Ошибка: fail2ban не запустился. Проверьте /etc/fail2ban/jail.local и журнал: journalctl -u fail2ban"
        return 1
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



# Подменю управления Fail2ban
fail2ban_menu() {
    # Если fail2ban не установлен — выполняем стандартную установку/настройку
    if ! dpkg-query -W -f='${Status}' fail2ban 2>/dev/null | grep -q "install ok installed"; then
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
                        local fb_status=$(${USE_SUDO:+$USE_SUDO }fail2ban-client status "$j" 2>/dev/null)
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
                        local fb_out=$(${USE_SUDO:+$USE_SUDO }fail2ban-client status "$j" 2>/dev/null)
                        local banned_list=$(echo "$fb_out" | grep -i "Banned IP list" | awk -F':' '{print $2}' | xargs)
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
                        local fb_out=$(${USE_SUDO:+$USE_SUDO }fail2ban-client status "$j" 2>/dev/null)
                        local banned_list=$(echo "$fb_out" | grep -i "Banned IP list" | awk -F':' '{print $2}' | xargs)
                        local ip
                        for ip in $banned_list; do
                            [[ " ${banned_ips_map[*]} " =~ " $ip " ]] || banned_ips_map+=("$ip")
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
                        if [[ -n "$MENU_CHOICE" ]]; then
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
        local DOCKER_MENU="$MENU_CHOICE"
        
        case $DOCKER_MENU in
            1)
                install_docker
                ;;
            2)
                if command -v docker &>/dev/null; then
                    if [[ "$(prompt_yes_no "Хотите обновить Docker?" "no")" == "yes" ]]; then
                        if apt-get update && apt-get upgrade -y docker-ce docker-ce-cli containerd.io; then
                            purple "Docker успешно обновлен."
                        else
                            red "Ошибка при обновлении Docker."
                        fi
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
                                read -r -p "Введите путь к файлу compose (или папке), или оставьте пустым для поиска: " COMPOSE_PATH
                                if [[ -z "$COMPOSE_PATH" ]]; then
                                    echo "Ищем compose-файлы в /opt, /srv, /root, /home (это может занять время)..."
                                    local compose_files=()
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
                        local running_containers=()
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
                        local all_containers=()
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
                        local all_containers=()
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
                    local containers_list=()
                    mapfile -t containers_list < <(docker ps -a --format "{{.Names}}")
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
                        local cnum="$MENU_CHOICE"
                        local DOCKER_NAME=""
                        if [[ "$cnum" =~ ^[0-9]+$ ]]; then
                            if [[ "$cnum" -ge 1 && "$cnum" -le ${#containers_list[@]} ]]; then
                                DOCKER_NAME="${containers_list[$((cnum-1))]}"
                            elif [[ "$cnum" -eq $(( ${#containers_list[@]} + 1 )) ]]; then
                                read -r -p "Введите имя контейнера: " DOCKER_NAME
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
                        if docker system prune -af --volumes; then
                            purple "Неиспользуемые образы и тома удалены."
                        else
                            red "Ошибка при очистке образов/томов."
                        fi
                    fi
                else
                    red "Docker не установлен."
                fi
                ;;
            12)
                if command -v docker &>/dev/null; then
                    if [[ "$(prompt_yes_no "Удалить остановленные контейнеры?" "no")" == "yes" ]]; then
                        if docker container prune -f; then
                            purple "Остановленные контейнеры удалены."
                        else
                            red "Ошибка при очистке контейнеров."
                        fi
                    fi
                else
                    red "Docker не установлен."
                fi
                ;;
            13)
                if command -v docker &>/dev/null; then
                    if [[ "$(prompt_yes_no "Удалить все контейнеры?" "no")" == "yes" ]]; then
                        local all_containers=()
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
                    if ${USE_SUDO:+$USE_SUDO }apt-get purge -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin docker.io docker-compose >/dev/null 2>&1; then
                        ${USE_SUDO:+$USE_SUDO }apt-get autoremove -y >/dev/null 2>&1
                        ${USE_SUDO:+$USE_SUDO }rm -rf /var/lib/docker /var/lib/containerd
                        if command -v docker &>/dev/null; then
                            yellow "Docker удален не полностью: найден бинарник $(command -v docker). Проверьте альтернативный способ установки."
                        else
                            purple "Docker полностью удален."
                        fi
                    else
                        red "Ошибка при apt-get purge Docker. Каталоги /var/lib/docker НЕ удалены во избежание потери данных при сбое. Проверьте вручную."
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
        green "Docker уже установлен."
        
        # Проверяем наличие пользователей в группе docker
        if ! check_docker_users; then
            yellow "Внимание: нет пользователей в группе docker."
            
            if [[ "$(prompt_yes_no "Добавить существующего пользователя в группу docker?" "no")" == "yes" ]]; then
                select_non_system_user "" create && [[ -n "$SELECTED_USER" ]] && add_user_to_docker "$SELECTED_USER"
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
            if ! wget -qO- https://get.docker.com | sh; then
                red "Ошибка при установке Docker через wget."
                return 1
            fi
            return
        fi
    fi

    
    green "Устанавливаем Docker..."
    yellow "ВНИМАНИЕ: Следующая команда скачает и запустит скрипт с get.docker.com."
    yellow "Убедитесь, что вы доверяете источнику, перед продолжением."
    apt-get update
    if ! curl -fsSL https://get.docker.com | sh; then
        red "Ошибка при установке Docker через curl."
        return 1
    fi

    # Проверяем установку
    if docker --version &>/dev/null; then
        purple "Docker успешно установлен. Версия: $(docker --version | awk '{print $3}' | tr -d ',')"
        
        # После установки предлагаем добавить пользователя
        if ! check_docker_users; then
            yellow "Внимание: Docker установлен, но нет пользователей в группе docker."
            if [[ "$(prompt_yes_no "Добавить существующего пользователя в группу docker?" "no")" == "yes" ]]; then
                select_non_system_user "" create && [[ -n "$SELECTED_USER" ]] && add_user_to_docker "$SELECTED_USER"
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
    local recommended_password=""
    
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
            local recommended_username=$(head -c 64 /dev/urandom | tr -dc a-z | head -c 1; head -c 64 /dev/urandom | tr -dc a-z0-9 | head -c 7)
            
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
                local recommended_password=$(head -c 64 /dev/urandom | tr -dc A-Za-z0-9 | head -c 15)
                
                if [[ "$(prompt_yes_no "Рекомендуемый пароль пользователя $recommended_password, оставить?" "yes")" == "yes" ]]; then
                    password=$recommended_password
                else
                    read -rs -p "Введите пароль для пользователя $username: " password
                    echo
                    
                    if ! validate_password "$password"; then
                        continue
                    fi
                    
                    read -rs -p "Повторите пароль для пользователя $username: " password_confirm
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
    ( umask 077; : > "$INFO_FILE" ) 2>/dev/null
    chmod 600 "$INFO_FILE" 2>/dev/null
    {
        echo ""
        CURRENT_SSH_PORT=$(get_ssh_port)
        [[ -n "$ROOT_PASSWORD" ]] && echo "Пароль root = $ROOT_PASSWORD"
        [[ -n "$CURRENT_SSH_PORT" ]] && echo "Порт SSH = $CURRENT_SSH_PORT"
        [[ -n "$username" ]] && echo "Новый пользователь = $username"
        [[ -n "$password" ]] && echo "Пароль нового пользователя = $password"
        if [[ -n "$ROOT_PASSWORD" || -n "$password" ]]; then
            echo ""
            echo "ВНИМАНИЕ: Данный файл содержит пароли в открытом виде!"
            echo "Рекомендуется удалить файл $INFO_FILE после сохранения паролей в безопасном месте."
        fi
        echo ""
    } >> "$INFO_FILE"
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
    echo "6. Отключить/включить IPv6 — меняет sysctl, автоматически проверяет и при необходимости устанавливает/загружает модуль ядра ipv6. Возможные проблемы: сервисы/туннели могут перестать работать."
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
            "4. Управление пользователями"
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
        local NUMBER="$MENU_CHOICE"
        
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
