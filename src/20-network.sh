
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
        if ${USE_SUDO:+$USE_SUDO }apt update -y && ${USE_SUDO:+$USE_SUDO }apt install -yq kmod; then
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
    local value=$1 iface_dir iface actual failed=0 found=0
    for iface_dir in /proc/sys/net/ipv6/conf/*; do
        [[ -f "$iface_dir/disable_ipv6" ]] || continue
        found=1
        iface="${iface_dir##*/}"
        if printf '%s\n' "$value" > "$iface_dir/disable_ipv6" 2>/dev/null; then
            actual=$(cat "$iface_dir/disable_ipv6" 2>/dev/null)
            if [[ "$actual" == "$value" ]]; then
                green "  $iface: disable_ipv6=$value"
            else
                yellow "  $iface: ожидалось disable_ipv6=$value, фактически $actual"
                failed=1
            fi
        else
            yellow "  $iface: не удалось записать disable_ipv6=$value"
            failed=1
        fi
    done
    if (( ! found )); then
        yellow "  Не найдено ни одного IPv6-интерфейса для изменения."
        return 1
    fi
    return "$failed"
}

# Проверка фактического состояния всех IPv6-интерфейсов.
# Проверка только all/default/lo недостаточна: на некоторых VDS уже поднятые
# интерфейсы не наследуют значение all и могут сохранить IPv6 включённым.
ipv6_interfaces_have_value() {
    local expected=$1 iface_dir actual failed=0 found=0
    for iface_dir in /proc/sys/net/ipv6/conf/*; do
        [[ -f "$iface_dir/disable_ipv6" ]] || continue
        found=1
        actual=$(cat "$iface_dir/disable_ipv6" 2>/dev/null)
        [[ "$actual" == "$expected" ]] || failed=1
    done
    (( found && ! failed ))
}

# Проверка статуса отключения IPv6.
# Диагностика при неудачном применении настроек IPv6
ipv6_diagnostics() {
    yellow "Диагностика:"
    echo "  Ядро: $(uname -a 2>/dev/null)"
    echo "  Параметры загрузки: $(cat /proc/cmdline 2>/dev/null)"
    if command -v systemd-detect-virt &>/dev/null; then
        echo "  Виртуализация: $(systemd-detect-virt 2>/dev/null || echo неизвестно)"
    fi
    if command -v lsmod &>/dev/null; then
        lsmod 2>/dev/null | grep -E '^ipv6' || yellow "  модуль ipv6 не отображается в lsmod"
    fi
    echo "  Текущие значения sysctl:"
    sysctl net.ipv6.conf.all.disable_ipv6 net.ipv6.conf.default.disable_ipv6 net.ipv6.conf.lo.disable_ipv6 2>&1 | sed 's/^/    /'
    if [[ -f /etc/sysctl.d/99-protection.conf ]]; then
        echo "  Содержимое /etc/sysctl.d/99-protection.conf:"
        sed 's/^/    /' /etc/sysctl.d/99-protection.conf
    fi
    echo "  Значения disable_ipv6 по интерфейсам:"
    for iface_dir in /proc/sys/net/ipv6/conf/*; do
        [[ -f "$iface_dir/disable_ipv6" ]] || continue
        printf '    %s: ' "${iface_dir##*/}"
        cat "$iface_dir/disable_ipv6" 2>/dev/null || echo "недоступно"
    done
    if command -v ip &>/dev/null; then
        echo "  IPv6-адреса:"
        ip -6 addr 2>&1 | sed 's/^/    /'
        echo "  IPv6-маршруты:"
        ip -6 route 2>&1 | sed 's/^/    /'
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


    # Если IPv6 уже отключен
    if ipv6_interfaces_have_value 1; then
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
            if ! ipv6_interfaces_have_value 0; then
                green "Повторное применение настроек через sysctl -p и sysctl --system..."
                ${USE_SUDO:+$USE_SUDO }sysctl -p /etc/sysctl.d/99-protection.conf >/dev/null 2>&1
                ${USE_SUDO:+$USE_SUDO }sysctl --system >/dev/null 2>&1
            fi

            # Прямая запись в каждый существующий интерфейс
            if ! ipv6_interfaces_have_value 0; then
                green "Прямая запись disable_ipv6=0 в интерфейсы..."
                ipv6_set_all_interfaces 0
            fi

            if ipv6_interfaces_have_value 0; then
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
    if ! ipv6_interfaces_have_value 1; then
        green "Повторное применение настроек через sysctl -p и sysctl --system..."
        ${USE_SUDO:+$USE_SUDO }sysctl -p /etc/sysctl.d/99-protection.conf >/dev/null 2>&1
        ${USE_SUDO:+$USE_SUDO }sysctl --system >/dev/null 2>&1
    fi

    # Прямая запись в каждый существующий интерфейс (all/default не всегда
    # затрагивают уже поднятые интерфейсы)
    if ! ipv6_interfaces_have_value 1; then
        green "Прямая запись disable_ipv6=1 в интерфейсы..."
        ipv6_set_all_interfaces 1
    fi

    # Проверяем, что IPv6 отключен
    if ipv6_interfaces_have_value 1; then
        ensure_ipv6_module_autoload
        purple "IPv6 успешно отключен во всех интерфейсах."
        green "Рекомендуется перезагрузить систему для полного применения изменений."
    else
        red "Ошибка при отключении IPv6. Проверьте настройки вручную."
        ipv6_diagnostics
    fi
}



# ============================================================
# ============================================================
# БЛОКИРОВКА PING
# ============================================================

# Функция для отключения/включения ICMP ping
disable_ping() {
    local PING_STATUS
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

