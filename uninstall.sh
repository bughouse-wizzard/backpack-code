#!/bin/bash
# Снимает оснастку. Сначала размораживает процессы и возвращает сон,
# иначе останется машина, которая не спит, и половина приложений в SIGSTOP.

set -u

UID_NUM=$(id -u)
PURGE=0
[ "${1:-}" = "--purge" ] && PURGE=1

say() { printf "%s\n" "$1"; }

[ -x "$HOME/bin/backpack-mode.sh" ] && "$HOME/bin/backpack-mode.sh" thaw >/dev/null 2>&1 \
    && say "✅ процессы разморожены"
[ -x "$HOME/bin/sleep-toggle.sh" ] && "$HOME/bin/sleep-toggle.sh" off >/dev/null 2>&1 \
    && say "✅ сон разрешён обратно"

for a in battery-watch backpack-mode backpack-health claude-rc night-log; do
    label="com.backpack.$a"
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null && say "✅ выгружен $label"
    rm -f "$HOME/Library/LaunchAgents/$label.plist"
done

rm -f "$HOME"/bin/{sleep-toggle,backpack-mode,backpack-health,battery-watch,sleep-audit,night-log}.sh
say "✅ скрипты из ~/bin удалены"

if [ "$PURGE" -eq 1 ]; then
    rm -f "$HOME/.config/backpack-mode.conf" "$HOME/.config/battery-watch.conf"
    rm -f "$HOME/.local/state/backpack-frozen.pids" "$HOME/.local/state/backpack-mode.state" \
          "$HOME/.local/state/battery-watch.state" "$HOME/.local/state/claude-rc.runs"
    sudo rm -f /etc/sudoers.d/pmset-disablesleep
    say "✅ конфиги, состояние и правило sudoers удалены"
else
    say "•  конфиги и правило sudoers оставлены, снести всё: ./uninstall.sh --purge"
fi
