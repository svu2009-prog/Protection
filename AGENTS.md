# AGENTS.md

## Project

Bash-скрипт для администрирования Ubuntu/Debian серверов. **Монолитная сборка**: весь код в одном файле `protection.sh` (~2880 строк, 62 функции). 

**История структуры:**
- v2.0.0: был модульный подход (src/ → build.sh), откачен в v1.5.3 (текущая версия)
- Текущее состояние: монолит, более простая разработка и отладка

## Current Structure

`protection.sh` — главный файл, содержит:
- **Инициализация**: shebang, `set -o pipefail`, глобальные переменные, `PROTECTION_VERSION`
- **Core функции**: `check_sudo()`, версионирование, цвета, меню, хелперы, валидации
- **SSH**: `disable_root_ssh()`, `setup_ssh_keys()`, `set_permit_root_login()`, `change_port_ssh()`, `validate_and_restart_sshd()`
- **Users**: `create_user()`, `select_non_system_user()`, пароли, sudoers
- **Network**: IPv6, Ping, sysctl
- **UFW**: `setup_ufw()`, `ufw_allow_port()`, правила
- **Fail2ban**: `generate_fail2ban_config()`, `install_fail2ban()`, jail-конфиги
- **Docker**: `install_docker()`, `add_user_to_docker()`
- **Menu**: интерактивное меню, `select_menu()`, цикл обработки
- **Output**: `out_file()` — генерация info.txt, `show_help()`

**Без сборки**: файл редактируется напрямую (не требует build.sh).

## Entrypoint & flow

`precheck()` → `check_sudo()` → `ensure_global_command()` → `main()` (интерактивное меню, цикл `while true`).

Запуск: `sudo ./protection.sh` или `/usr/local/bin/protection` (после первого запуска).

Флаг `--version` / `-v` — выход без входа в меню.

## Self-install

Скрипт копирует себя в `/usr/local/bin/protection` при каждом запуске, если установленная версия старее текущей. Версия берется из `PROTECTION_VERSION` (строка 12 в `protection.sh`). Сравнение — `compare_versions()` (semver-like). Если пути совпадают (запущен из `/usr/local/bin/protection`) — пропускает. Bump `PROTECTION_VERSION` при любых функциональных изменениях.

## USE_SUDO pattern (critical)

Две формы, обе существуют в коде:

- **Безопасная**: `${USE_SUDO:+$USE_SUDO }cmd` — expands to `sudo cmd` or `cmd` (без префикса).
- **Устаревшая**: `$USE_SUDO cmd` — при `USE_SUDO=""` даёт ` cmd` (с пробелом), что работает, но ломает `|| cmd` fallback.

При добавлении новых команд ИСПОЛЬЗУЙ только `${USE_SUDO:+$USE_SUDO }`.

## Menu system

`select_menu(title, labels_array_name, values_array_name)` — стрелочная навигация, Enter для выбора. Результат: глобальная `$MENU_CHOICE`.

Неинтерактивный режим (если stdout не tty): `select_menu` переключается на ввод строки с `read`.

## Function return values

Некоторые функции «возвращают» данные через глобальные переменные (bash не умеет возвращать строки):

- `$SELECTED_USER` — из `select_non_system_user()`, `select_existing_user()`, `select_user_for_ssh_keys()`
- `$FB_JAILS` — из `select_fail2ban_jail()`
- `$MENU_CHOICE` — из `select_menu()`

**НЕ добавляй `local`** к этим переменным — это сломает передачу значений.

Вспомогательные переменные внутри функций (`users_list`, `user_labels`, и т.д.) — с `local`.

## Backup pattern

Перед `sed -i` на конфигах — всегда `cp file file.bak`:
- `/etc/ssh/sshd_config.d/00-protection.conf` → временный бэкап (в `set_permit_root_login()`, `change_port_ssh()`, `toggle_pubkey_auth()`)
- `/etc/sysctl.conf` → `/etc/sysctl.conf.bak` (в `disable_ipv6()`, `disable_ping()`)

Для SSH используется drop-in паттерн: все изменения идут в `/etc/ssh/sshd_config.d/00-protection.conf`, основной файл не трогается.

## Color helpers

`red()`, `green()`, `yellow()`, `blue()`, `purple()`, `cyan()`, `black()`, `white()` — обёртки над `color_echo(code, message)`. Принимают 1 аргумент (строку). Третьего параметра нет.

## No tests / CI / formatter

Тестов нет, CI нет, линтера нет. Ручная проверка — `shellcheck protection.sh` (если установлен). `set -e` отсутствует намеренно — НЕ добавляй без явной просьбы.

## Git

- Прямой пуш в `main` (без PR/веток).
- Автор коммита: `svu2009-prog` / `svu2009-prog@users.noreply.github.com`. Проверяй `git config user.name` и `user.email`.
- `.gitattributes`: `*.sh text eol=lf`.
- Credentials: PAT в Windows Credential Manager, не через токен в репозитории.
- **При каждом изменении кода**: 
  1. Отредактировать `protection.sh` напрямую (без build.sh)
  2. Bump `PROTECTION_VERSION` в строке 12 файла
  3. `git add -A && git commit -m "vX.Y.Z: ..." && git push origin main`
  4. Не оставляй незапушенные коммиты.

## Script language & constraints

- Язык интерфейса: русский (комментарии, подсказки, вывод).
- Требует `root` (`$EUID -ne 0` → exit 1), Ubuntu/Debian, `bash`.
- `prompt_yes_no(prompt, default)` возвращает `"yes"` или `"no"` в stdout.
- `info.txt` генерируется при выходе (`out_file()`, `src/90-main.sh`). Содержит пароли в открытом виде — с предупреждением в самом файле.

## Release and Versioning (Plan)
- Bump PROTECTION_VERSION в `src/00-header.sh` (затем `./build.sh`) при каждом значимом изменении скрипта. Использовать семантическую версию MAJOR.MINOR.PATCH.
- Примеры:
  - 1.1.3 — патч-изменения (мелкие исправления); 1.2.0 — новые возможности; 2.0.0 — крупные изменения.
- Сообщение коммита: начинайте с vX.Y.Z: краткое описание изменений.
- Пуш в main без PR — если требуется аудит изменений, используйте PR и уведомляйте команду об обновлениях версии.
- При публикации новой версии обязательно добавляйте SHA-256 предыдущей проверенной версии в `PROTECTION_UPDATE_SHA256` в `protection.sh`. Хэш рассчитывается для канонического содержимого скрипта без блока `PROTECTION_UPDATE_SHA256`, чтобы allowlist не менял собственный хэш. Без записи SHA-256 автоматическое обновление следующей версии будет отклонено.
- После bump-а версии обновляйте lock-файл (skills-lock.json) в соответствии с текущей структурой скиллов и текущим списком в `./.agents/skills`, затем фиксируйте в коммите.
- При добавлении/удалении скиллов обязательно синхронизировать текущие файлы с .agents/skills и актуализировать skills-lock.json.
- Поддерживайте AGENTS.md как источник инструкций и согласованной политики выпуска.
