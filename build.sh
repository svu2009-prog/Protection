#!/bin/bash
# Сборка protection.sh из модулей src/ (порядок = алфавитный порядок имён файлов)
set -eu
cd "$(dirname "$0")"

out="protection.sh"
tmp="protection.sh.tmp"

{
    cat src/00-header.sh
    echo
    cat src/10-core.sh
    echo
    cat src/20-network.sh
    echo
    cat src/30-users.sh
    echo
    cat src/40-ssh.sh
    echo
    cat src/50-ufw.sh
    echo
    cat src/60-fail2ban.sh
    echo
    cat src/70-docker.sh
    echo
    cat src/90-main.sh
} > "$tmp"

mv -f "$tmp" "$out"

# Проверки
bash -n "$out"
count=$(grep -c '^PROTECTION_VERSION=' "$out")
if [[ "$count" -ne 1 ]]; then
    echo "ОШИБКА: PROTECTION_VERSION встречается $count раз(а)" >&2
    exit 1
fi
echo "BUILD_OK: $out ($(wc -l < "$out") строк)"
