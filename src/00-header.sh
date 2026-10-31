#!/bin/bash

set -o pipefail

# ============================================================
# СКРИПТ АВТОМАТИЗАЦИИ НАСТРОЙКИ СЕРВЕРА
# Совместимость: Ubuntu, Debian (с sudo и без sudo)
#
# СГЕНЕРИРОВАНО ИЗ src/ через build.sh — НЕ РЕДАКТИРОВАТЬ НАПРЯМУЮ.
# Редактируйте модули в src/, затем запускайте: ./build.sh
# Порядок модулей: 00-header, 10-core, 20-network, 30-users, 40-ssh,
#                  50-ufw, 60-fail2ban, 70-docker, 90-main
# ============================================================

# Переменные
username=""
USE_SUDO=""
PROTECTION_VERSION="2.0.0"
PROTECTION_COMMAND_PATH="/usr/local/bin/protection"

# ============================================================
# КОНФИГУРАЦИЯ ПО УМОЛЧАНИЮ
# ============================================================

INFO_FILE="/root/info.txt"

F2B_BANTIME_DEFAULT=3600
F2B_FINDTIME_DEFAULT=2400
F2B_MAXRETRY_DEFAULT=3
F2B_RECIDIVE_BANTIME=604800
F2B_RECIDIVE_FINDTIME=172800
F2B_RECIDIVE_MAXRETRY=2


# Зарезервированные имена пользователей (системные)
RESERVED_USERNAMES=(root bin daemon adm lp sync shutdown halt mail news uucp operator games ftp nobody systemd-timesync systemd-network systemd-resolve systemd-bus-proxy sys log uuidd admin)
