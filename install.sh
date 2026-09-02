#!/bin/bash
# Ставит оснастку режима рюкзака: скрипты в ~/bin, launchd-агенты, конфиги.
# Идемпотентно - повторный запуск обновляет то, что уже стоит.

set -eu

REPO="$(cd "$(dirname "$0")" && pwd)"
UID_NUM=$(id -u)
WITH_NIGHT_LOG=0

for arg in "$@"; do
    case "$arg" in
        --with-night-log) WITH_NIGHT_LOG=1 ;;
        -h|--help)
            echo "Использование: ./install.sh [--with-night-log]"
            exit 0 ;;
        *) echo "неизвестный флаг: $arg" >&2; exit 1 ;;
    esac
done

say() { printf "%s\n" "$1"; }

# --- скрипты ---------------------------------------------------------------
mkdir -p "$HOME/bin" "$HOME/.config" "$HOME/.local/state"
install -m 0755 "$REPO"/bin/*.sh "$HOME/bin/"
say "✅ скрипты в ~/bin"

# --- конфиги ---------------------------------------------------------------
if [ ! -e "$HOME/.config/backpack-mode.conf" ]; then
    install -m 0644 "$REPO/config/backpack-mode.conf.example" "$HOME/.config/backpack-mode.conf"
    say "✅ ~/.config/backpack-mode.conf - ВПИШИ ТУДА СВОЙ VPN-КЛИЕНТ в NEVER_FREEZE"
else
    say "•  ~/.config/backpack-mode.conf уже есть, не трогаю"
fi

if [ ! -e "$HOME/.config/battery-watch.conf" ]; then
    topic="backpack-$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 24)"
    sed "s|^NTFY_TOPIC=.*|NTFY_TOPIC=$topic|" \
        "$REPO/config/battery-watch.conf.example" > "$HOME/.config/battery-watch.conf"
    chmod 600 "$HOME/.config/battery-watch.conf"
    say "✅ ~/.config/battery-watch.conf, топик ntfy сгенерирован: $topic"
    say "   Подпишись на него в приложении ntfy (App Store / Google Play),"
    say "   потом проверь: ~/bin/battery-watch.sh test"
    say "   Кто знает топик - тот читает твои пуши и может слать свои."
else
    say "•  ~/.config/battery-watch.conf уже есть, не трогаю"
fi

# --- плисты ----------------------------------------------------------------
CLAUDE_BIN=$(command -v claude || true)
WORKDIR="${BACKPACK_CLAUDE_WORKDIR:-$HOME}"

render() {
    sed -e "s|__HOME__|$HOME|g" \
        -e "s|__USER__|$(id -un)|g" \
        -e "s|__CLAUDE_BIN__|${CLAUDE_BIN:-/usr/bin/false}|g" \
        -e "s|__WORKDIR__|$WORKDIR|g" "$1"
}

AGENTS="battery-watch backpack-mode backpack-health"
[ -n "$CLAUDE_BIN" ] && AGENTS="$AGENTS claude-rc"
[ "$WITH_NIGHT_LOG" -eq 1 ] && AGENTS="$AGENTS night-log"

for a in $AGENTS; do
    label="com.backpack.$a"
    plist="$HOME/Library/LaunchAgents/$label.plist"
    mkdir -p "$HOME/Library/LaunchAgents"
    render "$REPO/LaunchAgents/$label.plist.in" > "$plist"
    launchctl bootout "gui/$UID_NUM/$label" 2>/dev/null || true
    launchctl bootstrap "gui/$UID_NUM" "$plist"
    say "✅ агент $label"
done

if [ -z "$CLAUDE_BIN" ]; then
    say "•  claude в PATH не найден - агент claude-rc пропущен"
fi

# --- sudoers ---------------------------------------------------------------
# Без него sleep-toggle будет спрашивать пароль, а из хоткея спросить некому.
SUDOERS_TMP=$(mktemp)
render "$REPO/config/pmset-disablesleep.sudoers.in" > "$SUDOERS_TMP"
if sudo -n true 2>/dev/null || [ -t 0 ]; then
    if sudo visudo -cf "$SUDOERS_TMP" >/dev/null; then
        sudo install -m 0440 -o root -g wheel "$SUDOERS_TMP" /etc/sudoers.d/pmset-disablesleep
        say "✅ правило sudoers для pmset disablesleep"
    else
        say "⚠️  правило sudoers не прошло проверку visudo, пропущено"
    fi
else
    say "•  нет tty для sudo - поставь правило вручную, см. README"
fi
rm -f "$SUDOERS_TMP"

say ""
"$HOME/bin/backpack-health.sh" || true
say ""
say "Осталось повесить хоткей вручную - Shortcuts, действие Run Shell Script,"
say "shell /bin/bash, и абсолютный путь (именно абсолютный, \$HOME там пустой):"
say ""
say "    $HOME/bin/sleep-toggle.sh"
say ""
say "Пошагово: docs/ru/sleep-toggle.md или раздел Install в README.md"
