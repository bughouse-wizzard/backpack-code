#!/bin/bash
# Режим рюкзака: пока крышка закрыта и сон запрещён, тяжёлые приложения
# заморожены через SIGSTOP. Экран вернулся или запрет снят - размораживаем.
#
# Замораживание обратимо и ничего не теряет: память остаётся на месте,
# SIGCONT возвращает процесс в то же состояние. Ничего не убивается.
#
# Разморозка не должна зависеть от одного механизма, поэтому путей три:
#   1. этот агент при следующем прогоне (экран включился / запрет снят)
#   2. sleep-toggle.sh при выключении режима
#   3. руками: backpack-mode.sh thaw

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

CONF="$HOME/.config/backpack-mode.conf"
STATE="$HOME/.local/state/backpack-frozen.pids"
MODE_STATE="$HOME/.local/state/backpack-mode.state"
LOG_TAG="backpack-mode"

[ -r "$CONF" ] || { echo "нет конфига $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

mkdir -p "$(dirname "$STATE")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $*"; }

# --- состояние системы --------------------------------------------------

sleep_disabled() {
    ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'
}

# Состояние крышки. Именно оно нам и нужно: условие - "ноут сложен", а не
# "экран погас".
#
# Ассерта powerd "Prevent sleep while display is on" для этого НЕ годится:
# в clamshell она не снимается и висит часами, показывая экран включённым.
# Проверено 2026-09-01 на закрытой крышке - висела 54 минуты.
#
# Если ioreg не прочитался, grep вернёт неуспех, крышка будет считаться
# открытой и заморозки не случится - отказ в безопасную сторону.
lid_closed() {
    ioreg -r -k AppleClamshellState -d 4 2>/dev/null \
        | grep -q '"AppleClamshellState" = Yes'
}

# disablesleep глушит сон целиком, включая сон дисплея - панель остаётся под
# напряжением за закрытой крышкой и светит в пустоту. Гасим её явно.
# Не яркостью в ноль: та лишь приглушает, а displaysleepnow обесточивает
# подсветку (IOMFBBrightnessLevel уходит в 0), систему при этом не усыпляет.
# Команда идемпотентна, поэтому зовём без проверок - повтор ничего не стоит.
display_off() {
    pmset displaysleepnow >/dev/null 2>&1 || true
}

backlight_level() {
    ioreg -c AppleCLCD2 -r -d 1 2>/dev/null \
        | awk -F'= ' '/"IOMFBBrightnessLevel"/ {print $2; exit}'
}

# --- выбор процессов ----------------------------------------------------

is_protected() {
    local cmd="$1" pat
    while IFS= read -r pat; do
        [ -z "$pat" ] && continue
        case "$cmd" in *"$pat"*) return 0 ;; esac
    done <<< "$NEVER_FREEZE"
    return 1
}

# Печатает PID-ы процессов текущего пользователя, подходящих под списки
# заморозки и не попавших под защиту.
#
# Списка два, потому что одного шаблона не хватает: FREEZE_APPS ищет по
# /Applications/<имя>.app/, а Steam и его игры живут в
# ~/Library/Application Support/Steam/ - в /Applications лежит только оболочка.
# Для таких случаев FREEZE_PATHS матчит произвольную подстроку пути.
emit_matching() {
    local pattern="$1" me cmd pid
    me=$(id -u)
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        cmd=$(ps -p "$pid" -o command= 2>/dev/null) || continue
        is_protected "$cmd" && continue
        echo "$pid"
    done < <(pgrep -u "$me" -f "$pattern" 2>/dev/null)
}

target_pids() {
    local app path
    while IFS= read -r app; do
        [ -z "$app" ] && continue
        emit_matching "/Applications/$app.app/"
    done <<< "$FREEZE_APPS"

    while IFS= read -r path; do
        [ -z "$path" ] && continue
        emit_matching "$path"
    done <<< "${FREEZE_PATHS:-}"
}

# Человекочитаемое имя из полного пути процесса: /Applications/X.app/... -> X,
# игра из steamapps/common/<Игра>/... -> <Игра>, потроха Steam -> Steam.
pretty_name() {
    sed -E '
        s|.*/steamapps/common/([^/]+)/.*|\1|
        s|.*/Steam\.AppBundle/.*|Steam|
        s|.*/Applications/([^/]+)\.app/.*|\1|
        s|.*/([^/]+)$|\1|
    '
}

# --- заморозка и разморозка ---------------------------------------------

freeze() {
    local pids count=0 pid
    pids=$(target_pids | sort -un)
    [ -z "$pids" ] && return 0

    # Пишем во временный файл и подменяем через mv: rename атомарен, поэтому
    # читатель (status, ночной логгер) видит либо старый список целиком, либо
    # новый целиком. Обнуление с дописыванием давало окно, в котором читатель
    # заставал файл наполовину заполненным - ловили 33 вместо 77.
    local tmp="$STATE.tmp.$$"
    : > "$tmp"
    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        if kill -STOP "$pid" 2>/dev/null; then
            echo "$pid" >> "$tmp"
            count=$((count + 1))
        fi
    done <<< "$pids"
    mv -f "$tmp" "$STATE"

    return 0
}

thaw() {
    local count=0 pid
    [ -s "$STATE" ] || { : > "$STATE" 2>/dev/null; return 0; }

    while IFS= read -r pid; do
        [ -z "$pid" ] && continue
        # Процесс мог умереть, пока был заморожен - это не ошибка.
        if kill -CONT "$pid" 2>/dev/null; then
            count=$((count + 1))
        fi
    done < "$STATE"

    : > "$STATE"
    return 0
}

frozen_count() {
    [ -s "$STATE" ] && grep -c . "$STATE" || echo 0
}

# --- уведомления о переходе ---------------------------------------------
# Агент прогоняется каждые 30 секунд, поэтому сообщать надо только о смене
# режима. Иначе телефон получал бы пуш каждые полминуты.

prev_mode() {
    [ -r "$MODE_STATE" ] && cat "$MODE_STATE" || echo idle
}

push_phone() {
    local conf="$HOME/.config/battery-watch.conf"
    [ -r "$conf" ] || return 0
    # shellcheck disable=SC1090
    . "$conf"
    curl -fsS --max-time 15 \
        -H "Title: $1" -H "Priority: default" -H "Tags: $3" \
        -d "$2" "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

announce() {
    local now="$1" was
    was=$(prev_mode)
    [ "$now" = "$was" ] && return 0

    echo "$now" > "$MODE_STATE"
    if [ "$now" = active ]; then
        log "режим рюкзака ВКЛЮЧИЛСЯ: заморожено $(frozen_count), панель погашена"
        push_phone "🎒 Режим рюкзака активирован" \
            "Заморожено процессов: $(frozen_count). Панель погашена, система работает." \
            "package"
    else
        log "режим рюкзака ВЫКЛЮЧИЛСЯ: процессы разморожены"
        push_phone "🎒 Режим рюкзака снят" \
            "Процессы разморожены, экран вернулся." "package"
    fi
}

# --- режимы -------------------------------------------------------------

case "${1:-apply}" in
    apply)
        # Замораживаем только при обоих условиях сразу: запрет сна включён
        # и крышка закрыта. Если состояние крышки прочитать не удалось,
        # считаем её открытой - лучше не заморозить, чем не вовремя.
        if sleep_disabled && lid_closed; then
            # Морозим на каждом прогоне, а не только на переходе: за это время
            # приложение могло породить новые процессы, они бы остались живыми.
            freeze
            display_off
            announce active
        else
            thaw
            announce idle
        fi
        ;;
    freeze)
        freeze
        echo "заморожено: $(frozen_count)"
        ;;
    thaw|resume)
        n=$(frozen_count)
        thaw
        echo "разморожено: $n"
        ;;
    status)
        echo "запрет сна:  $(sleep_disabled && echo 'включён' || echo 'выключен')"
        echo "крышка:      $(lid_closed && echo 'закрыта' || echo 'открыта')"
        echo "заморожено:  $(frozen_count) процессов"
        echo "подсветка:   $(backlight_level) (0 = обесточена)"
        if [ -s "$STATE" ]; then
            echo "кто именно:"
            while IFS= read -r pid; do
                [ -z "$pid" ] && continue
                ps -p "$pid" -o comm= 2>/dev/null \
                    | pretty_name | sed 's/^/  - /'
            done < "$STATE" | sort | uniq -c | sort -rn
        fi
        ;;
    targets)
        echo "кандидаты на заморозку прямо сейчас:"
        target_pids | sort -un | while IFS= read -r pid; do
            ps -p "$pid" -o comm= 2>/dev/null \
                | pretty_name
        done | sort | uniq -c | sort -rn | sed 's/^/  /'
        ;;
    *)
        echo "использование: $(basename "$0") [apply|freeze|thaw|status|targets]" >&2
        exit 2
        ;;
esac
