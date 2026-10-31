# ДОПОЛНИТЕЛЬНОЕ МЕНЮ DOCKER
# ============================================================

_require_docker() {
    command -v docker &>/dev/null && return 0
    red "Docker не установлен."
    return 1
}

docker_menu() {
    while true; do
        # shellcheck disable=SC2034 # Массивы читаются select_menu по имени через nameref.
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
        # shellcheck disable=SC2034 # Массивы читаются select_menu по имени через nameref.
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
                if _require_docker; then
                    if [[ "$(prompt_yes_no "Хотите обновить Docker?" "no")" == "yes" ]]; then
                        if ${USE_SUDO:+$USE_SUDO }apt-get update && ${USE_SUDO:+$USE_SUDO }apt-get upgrade -y docker-ce docker-ce-cli containerd.io; then
                            purple "Docker успешно обновлен."
                        else
                            red "Ошибка при обновлении Docker."
                        fi
                    fi
                fi
                ;;
            3)
                if _require_docker; then
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
                if _require_docker; then
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
                fi
                ;;
            5)
                if _require_docker; then
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
                fi
                ;;
            6)
                if _require_docker; then
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
                fi
                ;;
            7)
                if _require_docker; then
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
                            if docker restart "$DOCKER_NAME" 2>/dev/null; then
                                purple "Контейнер $DOCKER_NAME перезапущен."
                            else
                                red "Не удалось перезапустить контейнер $DOCKER_NAME."
                            fi
                        fi
                    fi
                fi
                ;;
            8)
                if _require_docker; then
                    docker ps -a
                fi
                ;;
            9)
                if _require_docker; then
                    docker ps
                fi
                ;;
            10)
                if _require_docker; then
                    docker images
                fi
                ;;
            11)
                if _require_docker; then
                    if [[ "$(prompt_yes_no "Удалить неиспользуемые образы/тома?" "no")" == "yes" ]]; then
                        if docker system prune -af --volumes; then
                            purple "Неиспользуемые образы и тома удалены."
                        else
                            red "Ошибка при очистке образов/томов."
                        fi
                    fi
                fi
                ;;
            12)
                if _require_docker; then
                    if [[ "$(prompt_yes_no "Удалить остановленные контейнеры?" "no")" == "yes" ]]; then
                        if docker container prune -f; then
                            purple "Остановленные контейнеры удалены."
                        else
                            red "Ошибка при очистке контейнеров."
                        fi
                    fi
                fi
                ;;
            13)
                if _require_docker; then
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
    local installer_file

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
        if [[ -z "$(getent group docker 2>/dev/null | cut -d: -f4)" ]]; then
            yellow "Внимание: нет пользователей в группе docker."
            if [[ "$(prompt_yes_no "Добавить существующего пользователя в группу docker?" "no")" == "yes" ]]; then
                select_non_system_user "" create && [[ -n "$SELECTED_USER" ]] && add_user_to_docker "$SELECTED_USER"
            elif [[ "$(prompt_yes_no "Создать нового пользователя и добавить в группы sudo и docker?" "no")" == "yes" ]]; then
                new_user docker
            fi
        fi
        
        if [[ "$(prompt_yes_no "Хотите обновить Docker?" "no")" == "yes" ]]; then
            if ${USE_SUDO:+$USE_SUDO }apt-get update && ${USE_SUDO:+$USE_SUDO }apt-get upgrade -y docker-ce docker-ce-cli containerd.io; then
                purple "Docker успешно обновлен."
            else
                yellow "apt-get upgrade не удался (возможно, Docker установлен из distro-репозитория)."
            fi
        fi
        
        return
    fi
    
    if [[ "$(prompt_yes_no "Хотите установить Docker?" "no")" == "no" ]]; then
        return
    fi
    if ! command -v curl &>/dev/null; then
        green "Устанавливаем curl..."
        ${USE_SUDO:+$USE_SUDO }apt-get update
        ${USE_SUDO:+$USE_SUDO }apt-get install -y curl
    fi
    
    if ! command -v curl &>/dev/null; then
        if ! command -v wget &>/dev/null; then
            green "Устанавливаем wget..."
            ${USE_SUDO:+$USE_SUDO }apt-get update
            ${USE_SUDO:+$USE_SUDO }apt-get install -y wget
        fi
    fi

    local dl_cmd=""
    if command -v curl &>/dev/null; then
        dl_cmd="curl"
    elif command -v wget &>/dev/null; then
        dl_cmd="wget"
    else
        red "Не удалось найти curl или wget для загрузки установщика Docker."
        return 1
    fi

    if [[ "$dl_cmd" == "wget" ]]; then
        green "curl недоступен, используем wget для установки Docker..."
    else
        green "Устанавливаем Docker..."
        ${USE_SUDO:+$USE_SUDO }apt-get update
    fi
    yellow "ВНИМАНИЕ: Следующая команда скачает и запустит скрипт с get.docker.com."
    yellow "Убедитесь, что вы доверяете источнику, перед продолжением."
    if [[ "$(prompt_yes_no "Загрузить и выполнить установщик Docker от get.docker.com?" "no")" == "no" ]]; then
        return
    fi
    if ! installer_file=$(mktemp); then
        red "Не удалось создать временный файл для установщика Docker."
        return 1
    fi
    if [[ "$dl_cmd" == "curl" ]]; then
        curl -fsSL -o "$installer_file" https://get.docker.com
    else
        wget -q -O "$installer_file" https://get.docker.com
    fi
    if [[ ! -s "$installer_file" ]]; then
        rm -f -- "$installer_file"
        red "Не удалось загрузить установщик Docker."
        return 1
    fi
    if ! sh "$installer_file"; then
        rm -f -- "$installer_file"
        red "Ошибка при установке Docker через $dl_cmd."
        return 1
    fi
    rm -f -- "$installer_file"

    # Проверяем установку
    if docker --version &>/dev/null; then
        purple "Docker успешно установлен. Версия: $(docker --version | awk '{print $3}' | tr -d ',')"
        
        # После установки предлагаем добавить пользователя
        if [[ -z "$(getent group docker 2>/dev/null | cut -d: -f4)" ]]; then
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

