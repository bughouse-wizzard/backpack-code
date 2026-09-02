#!/bin/bash
# Проверяет, что вся оснастка для работы с закрытой крышкой на месте,
# и чинит то, что чинится само (поднимает упавшие launchd-агенты).
#
# Вызывается автоматически из sleep-toggle.sh при включении запрета сна -
# то есть ровно перед тем, как ноут отправится в рюкзак.

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

UID_NUM=$(id -u)
PROBLEMS=0
REPAIRED=0
QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

# Агенты, которые должны быть загружены: метка -> путь к плисту.
# Список включает и самого себя: любой из агентов поднимет упавшего соседа,
# поэтому умереть должны оба сразу, чтобы оснастка осталась лежать.
AGENTS="com.backpack.battery-watch:$HOME/Library/LaunchAgents/com.backpack.battery-watch.plist
com.backpack.backpack-health:$HOME/Library/LaunchAgents/com.backpack.backpack-health.plist
com.backpack.backpack-mode:$HOME/Library/LaunchAgents/com.backpack.backpack-mode.plist
com.backpack.claude-rc:$HOME/Library/LaunchAgents/com.backpack.claude-rc.plist
com.backpack.night-log:$HOME/Library/LaunchAgents/com.backpack.night-log.plist"

# Ставятся по желанию: нет плиста - значит не хотели, а не сломалось.
OPTIONAL_AGENTS="com.backpack.claude-rc com.backpack.night-log"

say()  { [ "$QUIET" -eq 1 ] || printf "%s\n" "$1"; }
ok()   { say "  ✅ $1"; }
warn() { say "  ⚠️  $1"; PROBLEMS=$((PROBLEMS + 1)); ISSUES="${ISSUES:-}$1; "; }
fix()  { say "  🔧 $1"; REPAIRED=$((REPAIRED + 1)); FIXED="${FIXED:-}$1; "; }

agent_loaded() {
    launchctl print "gui/$UID_NUM/$1" >/dev/null 2>&1
}

check_agent() {
    local label="$1" plist="$2"

    if [ ! -f "$plist" ]; then
        case " $OPTIONAL_AGENTS " in
            *" $label "*) say "  •  $label не ставился - необязательный"; return ;;
        esac
        warn "$label: плист отсутствует ($plist)"
        return
    fi

    if agent_loaded "$label"; then
        ok "$label загружен"
        return
    fi

    if launchctl bootstrap "gui/$UID_NUM" "$plist" 2>/dev/null && agent_loaded "$label"; then
        fix "$label не был загружен - поднял"
    else
        warn "$label не загружен и не поднимается"
    fi
}

say "=== АГЕНТЫ ==="
for entry in $AGENTS; do
    check_agent "${entry%%:*}" "${entry#*:}"
done

say ""
say "=== ПРАВА И ФАЙЛЫ ==="
if [ -f /etc/sudoers.d/pmset-disablesleep ]; then
    ok "правило sudoers на месте"
else
    warn "нет /etc/sudoers.d/pmset-disablesleep - тумблер сна работать не будет"
fi

# Спрашиваем список разрешённого, а не выполняем команду: единственная
# разрешённая команда меняет состояние сна, дёргать её ради проверки нельзя.
if sudo -n -l 2>/dev/null | grep -q 'disablesleep'; then
    ok "правило подхвачено sudo (без пароля)"
else
    warn "sudo не видит правило - проверь @includedir в /etc/sudoers"
fi

for s in sleep-toggle.sh battery-watch.sh sleep-audit.sh backpack-mode.sh; do
    if [ -x "$HOME/bin/$s" ]; then
        ok "$s исполняем"
    else
        warn "$HOME/bin/$s отсутствует или не исполняем"
    fi
done

if [ -r "$HOME/.config/battery-watch.conf" ]; then
    ok "конфиг сторожа читается"
else
    warn "нет ~/.config/battery-watch.conf - пуши о заряде не уйдут"
fi

say ""
say "=== REMOTE CONTROL ==="
# KeepAlive поднимает процесс сам за секунды. Здесь не чиним, а ЗАМЕЧАЕМ:
# смена pid означает, что он падал, и об этом стоит узнать.
# Смотрим не "процесс существует", а счётчик запусков launchd. Существование
# ловит только полную смерть, а крах-цикл под KeepAlive выглядит как здоровье:
# в ночь на 2026-09-02 claude rc падал 11 раз из-за лимита дескрипторов, и
# проверка по pid называла это "перезапустился, всё хорошо".
RC_RUNS_FILE="$HOME/.local/state/claude-rc.runs"
rc_pid=$(pgrep -f 'claude rc' 2>/dev/null | head -1)
rc_runs=$(launchctl print "gui/$UID_NUM/com.backpack.claude-rc" 2>/dev/null \
          | awk -F'= ' '/^\truns =/ {print $2; exit}')
rc_runs=${rc_runs:-0}
rc_prev=$(cat "$RC_RUNS_FILE" 2>/dev/null || echo "$rc_runs")
rc_delta=$((rc_runs - rc_prev))
rc_uptime=$(ps -p "${rc_pid:-0}" -o etime= 2>/dev/null | tr -d ' ')

if [ -z "$rc_pid" ]; then
    warn "Remote Control не запущен (запусков всего: $rc_runs)"
    RC_EVENT="down"
elif [ "$rc_delta" -ge 2 ]; then
    warn "Remote Control падает по кругу: $rc_delta перезапусков с прошлой проверки"
    RC_EVENT="looping"
elif [ "$rc_delta" -eq 1 ]; then
    ok "Remote Control перезапускался один раз (pid $rc_pid, живёт $rc_uptime)"
    RC_EVENT="restarted"
else
    ok "Remote Control стабилен (pid $rc_pid, живёт $rc_uptime)"
    RC_EVENT="stable"
fi
echo "$rc_runs" > "$RC_RUNS_FILE"

if [ "$QUIET" -eq 1 ] && [ "$RC_EVENT" != stable ]; then
    RC_CONF="$HOME/.config/battery-watch.conf"
    if [ -r "$RC_CONF" ]; then
        # shellcheck disable=SC1090
        . "$RC_CONF"
        case "$RC_EVENT" in
            down)
                rc_t="📡 Remote Control лежит"
                rc_b="Не запущен, KeepAlive не поднял. Смотри ~/Library/Logs/claude-rc.log"
                rc_p=high ;;
            looping)
                rc_t="📡 Remote Control падает по кругу"
                rc_b="$rc_delta перезапусков за полчаса. KeepAlive маскирует поломку - нужна причина, лог: ~/Library/Logs/claude-rc.log"
                rc_p=high ;;
            *)
                rc_t="📡 Remote Control перезапустился"
                rc_b="Падал один раз, поднялся сам. Живёт $rc_uptime, pid $rc_pid."
                rc_p=default ;;
        esac
        curl -fsS --max-time 15 -H "Title: $rc_t" -H "Priority: $rc_p" \
            -H "Tags: satellite" -d "$rc_b" \
            "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>&1 || true
    fi
fi

say ""
say "=== СОСТОЯНИЕ ==="
if ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'; then
    say "  🔒 сон запрещён"
else
    say "  😴 сон разрешён"
fi
say "  🔋 заряд $(pmset -g batt | grep -Eo '[0-9]+%' | head -1)"

say ""
if [ "$PROBLEMS" -eq 0 ] && [ "$REPAIRED" -eq 0 ]; then
    say "Всё на месте."
elif [ "$PROBLEMS" -eq 0 ]; then
    say "Починено: $REPAIRED. Проблем нет."
else
    say "Проблем: $PROBLEMS, починено: $REPAIRED. Разберись до того, как закрывать крышку."
fi

# В тихом режиме молчание = всё хорошо. О поломке и о самопочинке сообщаем
# пушем: иначе о них никто не узнает, пока не полезешь смотреть руками.
if [ "$QUIET" -eq 1 ] && { [ "$PROBLEMS" -gt 0 ] || [ "$REPAIRED" -gt 0 ]; }; then
    CONF="$HOME/.config/battery-watch.conf"
    if [ -r "$CONF" ]; then
        # shellcheck disable=SC1090
        . "$CONF"
        if [ "$PROBLEMS" -gt 0 ]; then
            h_title="🛠 Оснастка сломана"; h_prio=high
            h_body="${ISSUES:-}"
        else
            h_title="🔧 Оснастка починена сама"; h_prio=low
            h_body="${FIXED:-}"
        fi
        curl -fsS --max-time 15 -H "Title: $h_title" -H "Priority: $h_prio" \
            -H "Tags: wrench" -d "$h_body" \
            "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null 2>&1 || true
    fi
fi

exit "$PROBLEMS"
