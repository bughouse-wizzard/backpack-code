#!/bin/bash
# Показывает, засыпал ли мак за последние N минут и почему.
# Нужен, чтобы отличать "экран заблокировался" от "система реально спала":
# рвёт соединение только второе.

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

MINUTES="${1:-60}"

echo "=== SLEEP PREVENTION RIGHT NOW ==="
if ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'; then
    echo "  🔒 armed - the system should not sleep"
else
    echo "  😴 OFF - the system will sleep on timeout"
fi

echo
echo "=== TIMEOUTS ==="
pmset -g | grep -E '^ (sleep|displaysleep|disksleep) '

echo
echo "=== SLEEP EVENTS IN THE LAST $MINUTES MIN ==="
cutoff=$(date -v-"${MINUTES}"M '+%Y-%m-%d %H:%M:%S')
found=$(pmset -g log 2>/dev/null \
    | grep -E '(Entering Sleep state|Wake from|DarkWake from)' \
    | awk -v c="$cutoff" '$1" "$2 >= c')

if [ -z "$found" ]; then
    echo "  no events - the system did not sleep"
else
    echo "$found" | sed 's/^/  /'
fi

echo
echo "=== WHAT IS KEEPING IT AWAKE RIGHT NOW ==="
pmset -g assertions | grep -E 'PreventUserIdleSystemSleep +1|PreventSystemSleep +1' >/dev/null \
    && pmset -g assertions | grep -A20 'Listed by owning process' | grep -E 'PreventUserIdleSystemSleep|PreventSystemSleep' | head -4 | sed 's/^/  /' \
    || echo "  nothing - it is held up by sleep prevention alone"
