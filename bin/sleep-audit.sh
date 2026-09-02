#!/bin/bash
# Показывает, засыпал ли мак за последние N минут и почему.
# Нужен, чтобы отличать "экран заблокировался" от "система реально спала":
# рвёт соединение только второе.

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

MINUTES="${1:-60}"

echo "=== ЗАПРЕТ СНА СЕЙЧАС ==="
if ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'; then
    echo "  🔒 включён - система засыпать не должна"
else
    echo "  😴 ВЫКЛЮЧЕН - система заснёт по таймауту"
fi

echo
echo "=== ТАЙМАУТЫ ==="
pmset -g | grep -E '^ (sleep|displaysleep|disksleep) '

echo
echo "=== СОБЫТИЯ СНА ЗА ПОСЛЕДНИЕ $MINUTES МИН ==="
cutoff=$(date -v-"${MINUTES}"M '+%Y-%m-%d %H:%M:%S')
found=$(pmset -g log 2>/dev/null \
    | grep -E '(Entering Sleep state|Wake from|DarkWake from)' \
    | awk -v c="$cutoff" '$1" "$2 >= c')

if [ -z "$found" ]; then
    echo "  событий нет - система не спала"
else
    echo "$found" | sed 's/^/  /'
fi

echo
echo "=== ЧТО СЕЙЧАС ДЕРЖИТ СИСТЕМУ БОДРОЙ ==="
pmset -g assertions | grep -E 'PreventUserIdleSystemSleep +1|PreventSystemSleep +1' >/dev/null \
    && pmset -g assertions | grep -A20 'Listed by owning process' | grep -E 'PreventUserIdleSystemSleep|PreventSystemSleep' | head -4 | sed 's/^/  /' \
    || echo "  ничего - держится только на запрете сна"
