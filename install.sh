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
            echo "Usage: ./install.sh [--with-night-log]"
            exit 0 ;;
        *) echo "unknown flag: $arg" >&2; exit 1 ;;
    esac
done

say() { printf "%s\n" "$1"; }

# --- скрипты ---------------------------------------------------------------
mkdir -p "$HOME/bin" "$HOME/.config" "$HOME/.local/state"
install -m 0755 "$REPO"/bin/*.sh "$HOME/bin/"
say "✅ scripts in ~/bin"

# --- конфиги ---------------------------------------------------------------
if [ ! -e "$HOME/.config/backpack-mode.conf" ]; then
    install -m 0644 "$REPO/config/backpack-mode.conf.example" "$HOME/.config/backpack-mode.conf"
    say "✅ ~/.config/backpack-mode.conf - PUT YOUR VPN CLIENT IN NEVER_FREEZE"
else
    say "•  ~/.config/backpack-mode.conf already exists, leaving it alone"
fi

if [ ! -e "$HOME/.config/battery-watch.conf" ]; then
    topic="backpack-$(LC_ALL=C tr -dc a-z0-9 </dev/urandom | head -c 24)"
    sed "s|^NTFY_TOPIC=.*|NTFY_TOPIC=$topic|" \
        "$REPO/config/battery-watch.conf.example" > "$HOME/.config/battery-watch.conf"
    chmod 600 "$HOME/.config/battery-watch.conf"
    say "✅ ~/.config/battery-watch.conf, generated ntfy topic: $topic"
    say "   Subscribe to it in the ntfy app (App Store / Google Play),"
    say "   then check it: ~/bin/battery-watch.sh test"
    say "   Whoever knows the topic reads your pushes and can send their own."
else
    say "•  ~/.config/battery-watch.conf already exists, leaving it alone"
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
    say "✅ agent $label"
done

if [ -z "$CLAUDE_BIN" ]; then
    say "•  claude not found in PATH - skipping the claude-rc agent"
fi

# --- sudoers ---------------------------------------------------------------
# Без него sleep-toggle будет спрашивать пароль, а из хоткея спросить некому.
SUDOERS_TMP=$(mktemp)
render "$REPO/config/pmset-disablesleep.sudoers.in" > "$SUDOERS_TMP"
if sudo -n true 2>/dev/null || [ -t 0 ]; then
    if sudo visudo -cf "$SUDOERS_TMP" >/dev/null; then
        sudo install -m 0440 -o root -g wheel "$SUDOERS_TMP" /etc/sudoers.d/pmset-disablesleep
        say "✅ sudoers rule for pmset disablesleep"
    else
        say "⚠️  the sudoers rule failed the visudo check, skipped"
    fi
else
    say "•  no tty for sudo - install the rule by hand, see README"
fi
rm -f "$SUDOERS_TMP"

say ""
"$HOME/bin/backpack-health.sh" || true
say ""
say "One manual step left - bind a hotkey: Shortcuts, Run Shell Script action,"
say "shell /bin/bash, and an absolute path (absolute matters, \$HOME is empty there):"
say ""
say "    $HOME/bin/sleep-toggle.sh"
say ""
say "Step by step: docs/en/sleep-toggle.md or the Install section in README.md"
