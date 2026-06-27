# AGENTS.md

## Project

Single bash script (`protection.sh`, ~2340 строк) для администрирования Ubuntu/Debian серверов. Не monorepo, не многомодульный.

## Entrypoint & flow

`precheck()` (`protection.sh:412`) → `check_sudo()` → `ensure_global_command()` → `main()` (интерактивное меню, цикл `while true`).

Запуск: `sudo ./protection.sh` или `/usr/local/bin/protection` (после первого запуска).

Флаг `--version` / `-v` — выход без входа в меню.

## Self-install

Скрипт копирует себя в `/usr/local/bin/protection` при каждом запуске, если установленная версия старее текущей. Версия берется из `PROTECTION_VERSION` (`protection.sh:21`). Сравнение — `compare_versions()` (semver-like). Если пути совпадают (запущен из `/usr/local/bin/protection`) — пропускает. Bump `PROTECTION_VERSION` при любых функциональных изменениях.

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
- `/etc/ssh/sshd_config` → `/etc/ssh/sshd_config.bak` (в `change_port_ssh()`, `disable_root_ssh()`)
- `/etc/sysctl.conf` → `/etc/sysctl.conf.bak` (в `disable_ipv6()`, `disable_ping()`)

## Color helpers

`red()`, `green()`, `yellow()`, `blue()`, `purple()`, `cyan()`, `black()`, `white()` — обёртки над `color_echo(code, message)`. Принимают 1 аргумент (строку). Третьего параметра нет.

## No tests / CI / formatter

Тестов нет, CI нет, линтера нет. Ручная проверка — `shellcheck protection.sh` (если установлен). `set -e` отсутствует намеренно — НЕ добавляй без явной просьбы.

## Git

- Прямой пуш в `main` (без PR/веток).
- Автор коммита: `svu2009-prog` / `svu2009-prog@users.noreply.github.com`. Проверяй `git config user.name` и `user.email`.
- `.gitattributes`: `*.sh text eol=lf`.
- Credentials: PAT в Windows Credential Manager, не через токен в репозитории.
- **При каждом изменении `protection.sh`**: bump `PROTECTION_VERSION` (строка 21), затем `git add protection.sh && git commit -m "vX.Y.Z: ..." && git push origin main`. Не оставляй незапушенные коммиты.

## Script language & constraints

- Язык интерфейса: русский (комментарии, подсказки, вывод).
- Требует `root` (`$EUID -ne 0` → exit 1), Ubuntu/Debian, `bash`.
- `prompt_yes_no(prompt, default)` возвращает `"yes"` или `"no"` в stdout.
- `info.txt` генерируется при выходе (`out_file()`, `protection.sh:2160`). Содержит пароли в открытом виде — с предупреждением в самом файле.

## Release and Versioning (Plan)
- Bump PROTECTION_VERSION в protection.sh при каждом значимом изменении скрипта. Использовать семантическую версию MAJOR.MINOR.PATCH.
- Примеры:
  - 1.1.3 — патч-изменения (мелкие исправления); 1.2.0 — новые возможности; 2.0.0 — крупные изменения.
- Сообщение коммита: начинайте с vX.Y.Z: краткое описание изменений.
- Пуш в main без PR — если требуется аудит изменений, используйте PR и уведомляйте команду об обновлениях версии.
 - После bump-а версии обновляйте lock-файл (skills-lock.json) в соответствии с текущей структурой скиллов и текущим списком в `./.agents/skills`, затем фиксируйте в коммите.
- При добавлении/удалении скиллов обязательно синхронизировать текущие файлы с .agents/skills и актуализировать skills-lock.json.
- Поддерживайте AGENTS.md как источник инструкций и согласованной политики выпуска.
