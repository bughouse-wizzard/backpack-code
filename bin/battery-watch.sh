#!/bin/bash
# Сторож заряда: шлёт пуш на телефон при пересечении порогов разряда.
# Запускается launchd-агентом com.backpack.battery-watch раз в несколько минут.
# Молчит, пока ничего не меняется.

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

CONF="$HOME/.config/battery-watch.conf"
STATE="$HOME/.local/state/battery-watch.state"

[ -r "$CONF" ] || { echo "no config at $CONF" >&2; exit 1; }
# shellcheck disable=SC1090
. "$CONF"

mkdir -p "$(dirname "$STATE")"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') $*"; }

# --- чтение батареи -----------------------------------------------------

battery_percent() {
    pmset -g batt | grep -Eo '[0-9]+%' | head -1 | tr -d '%'
}

on_ac() {
    if pmset -g batt | head -1 | grep -q "'AC Power'"; then
        echo yes
    else
        echo no
    fi
}

time_left() {
    local t
    t=$(pmset -g batt | grep -Eo '[0-9]+:[0-9]+ remaining' | head -1 | sed 's/ remaining//')
    if [ -n "$t" ]; then
        echo "$t"
    else
        echo "?"
    fi
}

# --- отправка -----------------------------------------------------------

push_ntfy() {
    curl -fsS --max-time 15 \
        -H "Title: $1" \
        -H "Priority: $3" \
        -H "Tags: $4" \
        -d "$2" \
        "$NTFY_SERVER/$NTFY_TOPIC" >/dev/null
}

push_telegram() {
    curl -fsS --max-time 15 \
        -d "chat_id=$TG_CHAT_ID" \
        -d "text=$1
$2" \
        "https://api.telegram.org/bot$TG_TOKEN/sendMessage" >/dev/null
}

push() {
    if [ "$BACKEND" = telegram ]; then
        push_telegram "$@"
    else
        push_ntfy "$@"
    fi
}

# --- сборка уведомления -------------------------------------------------
# Одна точка сборки для боевого режима и для demo: то, что показывает demo,
# гарантированно совпадает с тем, что придёт на самом деле.

notify_threshold() {
    local crossed="$1" pct="$2" left="$3"
    local title prio tags body

    # Громкость растёт по мере разряда: верхние ступени информационные и
    # молчат, нижние будят. Иначе десяток уведомлений за цикл - это шум.
    if [ "$crossed" -le 5 ]; then
        title="🪫 Battery ${pct}% - about to cut out"; prio=urgent;  tags="rotating_light"
    elif [ "$crossed" -le 10 ]; then
        title="🪫 Battery ${pct}%";                      prio=high;    tags="warning"
    elif [ "$crossed" -le 20 ]; then
        title="🔋 Battery ${pct}%";                      prio=default; tags="battery"
    elif [ "$crossed" -le 50 ]; then
        title="🔋 Battery ${pct}%";                      prio=low;     tags="battery"
    else
        title="🔋 Battery ${pct}%";                      prio=min;     tags="battery"
    fi

    if [ "$left" = "?" ]; then
        body="No time estimate available yet."
    else
        body="About $left remaining."
    fi

    # Приписку про резкое выключение добавляем, только если сон действительно
    # запрещён - иначе она врёт.
    if ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'; then
        body="$body Sleep is prevented - it will not doze off, it will cut out."
    else
        body="$body Sleep is allowed - it will doze off normally."
    fi

    push "$title" "$body" "$prio" "$tags"
}

# --- состояние ----------------------------------------------------------
# В файле хранится последний уже отправленный порог и последний источник
# питания. Порог сбрасывается, как только ноут поставили на зарядку.

read_state() {
    if [ -r "$STATE" ]; then
        cat "$STATE"
    else
        echo "100 no"
    fi
}

# --- режимы проверки ----------------------------------------------------

case "${1:-}" in
    test)
        if push "🔋 Test push" "Battery watch is configured. If you see this on your phone, it works." low battery; then
            log "test push sent ($BACKEND)"
            exit 0
        fi
        log "ERROR: test push did not go through"
        exit 1
        ;;
    demo)
        # Боевое по виду уведомление для заданного порога, через тот же код.
        # Состояние не трогает, на реальную работу сторожа не влияет.
        d_thr="${2:-20}"
        d_pct="${3:-$d_thr}"
        if notify_threshold "$d_thr" "$d_pct" "1:47"; then
            log "demo: sent a ${d_thr}% alert (showing ${d_pct}% charge)"
            exit 0
        fi
        log "demo: SEND ERROR"
        exit 1
        ;;
    status)
        echo "charge:  $(battery_percent)%"
        echo "power:   $([ "$(on_ac)" = yes ] && echo 'AC' || echo 'battery')"
        echo "left:    $(time_left)"
        echo "backend: $BACKEND"
        echo "state:   $(read_state)"
        exit 0
        ;;
esac

# --- основная логика ----------------------------------------------------

pct=$(battery_percent)
ac=$(on_ac)

if [ -z "$pct" ]; then
    log "could not read the charge"
    exit 0
fi

read -r last_notified last_ac <<< "$(read_state)"

if [ "$ac" = yes ]; then
    # На зарядке молчим и сбрасываем пороги, чтобы при следующем разряде
    # оповещения сработали заново.
    if [ "$last_ac" != yes ]; then
        log "AC connected, thresholds reset (${pct}%)"
    fi
    echo "100 yes" > "$STATE"
    exit 0
fi

# Разряд. Берём САМЫЙ НИЗКИЙ из пройденных порогов, о котором ещё не сообщали:
# если заряд успел упасть сразу через несколько ступеней, важна нижняя, а не
# верхняя - иначе срочное предупреждение приедет через несколько циклов опроса.
crossed=""
for t in $THRESHOLDS; do
    if [ "$pct" -le "$t" ] && [ "$t" -lt "$last_notified" ]; then
        crossed="$t"
    fi
done

if [ -z "$crossed" ]; then
    echo "$last_notified no" > "$STATE"
    exit 0
fi

left=$(time_left)

if notify_threshold "$crossed" "$pct" "$left"; then
    echo "$crossed no" > "$STATE"
    log "sent: threshold $crossed (${pct}%, $left left)"
else
    # Не записываем порог как отправленный - повторим на следующем запуске.
    echo "$last_notified no" > "$STATE"
    log "SEND ERROR at ${pct}%, will retry"
fi
