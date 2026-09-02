#!/bin/bash
# Тумблер запрета сна при закрытой крышке.
# Состояние читается из ioreg, переключается через pmset по узкому правилу
# в /etc/sudoers.d/pmset-disablesleep - пароль не спрашивается.

set -u

# Shortcuts запускает скрипт с урезанным окружением: PATH без /usr/sbin, HOME пуст.
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

PMSET=/usr/bin/pmset

current_state() {
    if ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'; then
        echo on
    else
        echo off
    fi
}

notify() {
    osascript -e "display notification \"$2\" with title \"$1\"" >/dev/null 2>&1 || true
}

# Пуш на телефон при каждой смене режима: главное - не забыть переключить
# перед выходом из дома, а уведомление на маке этого не обеспечивает.
push_phone() {
    local conf="$HOME/.config/battery-watch.conf"
    [ -r "$conf" ] || return 0
    # shellcheck disable=SC1090
    . "$conf"
    curl -fsS --max-time 15 \
        -H "Title: $1" -H "Priority: high" -H "Tags: $3" \
        -d "$2" "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>&1 || true
}

value_for() {
    if [ "$1" = on ]; then
        echo 1
    else
        echo 0
    fi
}

apply() {
    local want="$1"
    if sudo -n "$PMSET" -a disablesleep "$(value_for "$want")" 2>/dev/null; then
        return 0
    fi
    notify "Sleep: error" "No /etc/sudoers.d/pmset-disablesleep rule"
    echo "error: no sudoers rule - install it with ./install.sh, see docs/en/sleep-toggle.md" >&2
    return 1
}

# Перед рюкзаком проверяем оснастку и предупреждаем о прожорах: узнать об этом
# надо до того, как крышка закрыта, а не из пуша про 20% через час.
preflight() {
    local health hogs

    if [ -x "$HOME/bin/backpack-health.sh" ]; then
        if ! health=$("$HOME/bin/backpack-health.sh" 2>&1); then
            echo "⚠️  rig: $(echo "$health" | tail -1)"
        fi
    fi

    hogs=$(ps -A -o %cpu,comm \
        | awk '$1 > 50 {c=$1; sub(/^[^ ]+ +/,""); n=$0
               sub(/.*\/Applications\//,"",n); sub(/\.app\/.*/,"",n)
               printf "%s %.0f%%\n", n, c}' \
        | sort -t' ' -k2 -rn | head -2 | paste -sd', ' -)

    if [ -n "$hogs" ]; then
        echo "⚠️  burning CPU: $hogs"
    fi
}

report() {
    local extra
    if [ "$1" = on ]; then
        notify "Sleep prevented" "You can close the lid"
        echo "🔒 SLEEP PREVENTED - you can close the lid"
        extra=$(preflight)
        [ -n "$extra" ] && echo "$extra"
        push_phone "🔒 Backpack mode ON" \
            "The Mac will not sleep with the lid closed.${extra:+ }${extra//$'\n'/ }" lock
    else
        notify "Sleep allowed" "Back to normal"
        echo "😴 SLEEP ALLOWED - back to normal"
        # Третий независимый путь разморозки, помимо агента и ручной команды.
        [ -x "$HOME/bin/backpack-mode.sh" ] && "$HOME/bin/backpack-mode.sh" thaw >/dev/null 2>&1
        push_phone "😴 Backpack mode OFF" \
            "The Mac will sleep as usual. Processes thawed." unlock
    fi
}

switch_to() {
    apply "$1" && report "$1"
}

case "${1:-toggle}" in
    status)
        current_state
        ;;
    on|off)
        switch_to "$1"
        ;;
    toggle)
        if [ "$(current_state)" = on ]; then
            switch_to off
        else
            switch_to on
        fi
        ;;
    *)
        echo "usage: $(basename "$0") [toggle|on|off|status]" >&2
        exit 2
        ;;
esac
