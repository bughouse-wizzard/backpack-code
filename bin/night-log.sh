#!/bin/bash
# Пишет строку телеметрии в CSV. Нужен, чтобы утром была кривая разряда и
# видно было, не разваливалось ли что-то ночью.
#
# Нагрузку не создаёт намеренно: реальный сценарий - это работающий claude rc
# и заморозка, а синтетический busy-loop измерил бы сам себя.

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

OUT="$HOME/Library/Logs/night-log.csv"

pct=$(pmset -g batt | grep -Eo '[0-9]+%' | head -1 | tr -d '%')
ac=$(pmset -g batt | head -1 | grep -q "'AC Power'" && echo ac || echo batt)
left=$(pmset -g batt | grep -Eo '[0-9]+:[0-9]+ remaining' | head -1 | sed 's/ remaining//')
sleepdis=$(ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes' && echo yes || echo no)
lid=$(ioreg -r -k AppleClamshellState -d 4 2>/dev/null | grep -q '"AppleClamshellState" = Yes' && echo closed || echo open)
# grep -c печатает 0 и возвращает 1, поэтому || echo 0 дал бы две строки
frozen=$(grep -c . "$HOME/.local/state/backpack-frozen.pids" 2>/dev/null | head -1)
frozen=${frozen:-0}
backlight=$(ioreg -c AppleCLCD2 -r -d 1 2>/dev/null | awk -F'= ' '/"IOMFBBrightnessLevel"/ {print $2; exit}')
cpu=$(ps -A -o %cpu | awk '{s+=$1} END {printf "%.0f", s}')
# Имя вытаскиваем sed-ом, а не awk: BSD awk в этой локали ломает многобайтные
# символы: кириллица в именах превращается в мусор вида M-PM-=M-PM-4. sed работает
# с байтами и UTF-8 не портит. Числом занимается awk - там только ASCII.
top_line=$(ps -A -o %cpu,comm | sort -rn | sed -n 2p)
top_cpu=$(printf '%s' "$top_line" | awk '{printf "%.0f", $1}')
top_name=$(printf '%s' "$top_line" \
           | sed -E 's/^[[:space:]]*[0-9.]+[[:space:]]+//' \
           | sed -E 's|.*/steamapps/common/([^/]+)/.*|\1|; s|.*/Steam\.AppBundle/.*|Steam|; s|.*/||' \
           | tr ',' ';')
top="${top_name}:${top_cpu}"
# Сон за последние 6 минут: если появится - значит запрет не удержал
slept=$(pmset -g log 2>/dev/null | grep 'Entering Sleep state' \
        | awk -v c="$(date -v-6M '+%Y-%m-%d %H:%M:%S')" '$1" "$2 >= c' | wc -l | tr -d ' ')

[ -f "$OUT" ] || echo "time,pct,power,left,sleep_disabled,lid,frozen,backlight,cpu_total,top_proc,slept_6min" > "$OUT"
echo "$(date '+%Y-%m-%d %H:%M:%S'),$pct,$ac,${left:-?},$sleepdis,$lid,$frozen,${backlight:-?},$cpu,${top:-?},$slept" >> "$OUT"
