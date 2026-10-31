
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
    local script_file=$1 line ver
    line=$(grep -m1 '^PROTECTION_VERSION=' "$script_file" 2>/dev/null) || return 1
    ver="${line#*=}"
    ver="${ver//\"/}"
    ver="${ver//$'\r'/}"
    echo "$ver"
}

ensure_global_command() {
    local script_path installed_version version_status command_dir temp_path

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

    if ! temp_path=$(${USE_SUDO:+$USE_SUDO }mktemp "$command_dir/.protection.XXXXXX"); then
        red "Не удалось создать временный файл для команды protection."
        return 1
    fi

    if ! ${USE_SUDO:+$USE_SUDO }cp "$script_path" "$temp_path" ||
        ! ${USE_SUDO:+$USE_SUDO }chmod 755 "$temp_path" ||
        ! ${USE_SUDO:+$USE_SUDO }mv -f "$temp_path" "$PROTECTION_COMMAND_PATH"; then
        ${USE_SUDO:+$USE_SUDO }rm -f "$temp_path"
        red "Не удалось атомарно установить глобальную команду $PROTECTION_COMMAND_PATH."
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
# shellcheck disable=SC2329 # Обёртки предназначены для вызова из меню и расширений.
black() { color_echo 90 "$1"; }
red() { color_echo 91 "$1"; }
green() { color_echo 92 "$1"; }
yellow() { color_echo 93 "$1"; }
# shellcheck disable=SC2329 # Обёртки предназначены для вызова из меню и расширений.
blue() { color_echo 94 "$1"; }
purple() { color_echo 95 "$1"; }
# shellcheck disable=SC2329 # Обёртки предназначены для вызова из меню и расширений.
cyan() { color_echo 96 "$1"; }
# shellcheck disable=SC2329 # Обёртки предназначены для вызова из меню и расширений.
white() { color_echo 97 "$1"; }

case "${1:-}" in
    -v|--version)
        show_version
        exit 0
        ;;
esac

# ============================================================
# ВСПОМОГАТЕЛЬНЫЕ ФУНКЦИИ

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
                IFS= read -rsn2 -t 0.1 extra || true
                case "$extra" in
                    "[A"|OD)
                        ((selected--))
                        [[ "$selected" -lt 0 ]] && selected=$((${#labels_ref[@]} - 1))
                        ;;
                    "[B"|OC)
                        ((selected++))
                        [[ "$selected" -ge ${#labels_ref[@]} ]] && selected=0
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
        ss -ltn "sport = :$port" 2>/dev/null | grep -q ":$port"
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
# shellcheck disable=SC2329 # Вызывается trap on_interrupt INT.
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
    if ${USE_SUDO:+$USE_SUDO }apt update -y && ${USE_SUDO:+$USE_SUDO }apt install sudo -y; then
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
        if ! read -r -p "$prompt (yes/no)$default_hint: " response; then
            # EOF (stdin закрыт) — возвращаем дефолт, не зацикливаемся
            local eof_answer="$default"
            [[ -z "$eof_answer" ]] && eof_answer="no"
            red "Не удалось прочитать ответ, возвращаем '$eof_answer'." >&2
            echo "$eof_answer"
            [[ "$eof_answer" == "yes" ]] && return 0
            return 1
        fi
        [[ -z "$response" && -n "$default" ]] && response="$default"
        
        case "$response" in
            [Yy]*) echo "yes"; return 0;;
            [Nn]*) echo "no"; return 1;;
            *) red "Пожалуйста, введите 'yes' или 'no'." >&2;;
        esac
    done
}
