#!/bin/bash
# Сторож заряда: шлёт пуш на телефон при пересечении порогов разряда.
# Запускается launchd-агентом com.backpack.battery-watch раз в несколько минут.
# Молчит, пока ничего не меняется.

set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

CONF="$HOME/.config/battery-watch.conf"
STATE="$HOME/.local/state/battery-watch.state"

[ -r "$CONF" ] || { echo "нет конфига $CONF" >&2; exit 1; }
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
        title="🪫 Батарея ${pct}% — вот-вот выключится"; prio=urgent;  tags="rotating_light"
    elif [ "$crossed" -le 10 ]; then
        title="🪫 Батарея ${pct}%";                      prio=high;    tags="warning"
    elif [ "$crossed" -le 20 ]; then
        title="🔋 Батарея ${pct}%";                      prio=default; tags="battery"
    elif [ "$crossed" -le 50 ]; then
        title="🔋 Батарея ${pct}%";                      prio=low;     tags="battery"
    else
        title="🔋 Батарея ${pct}%";                      prio=min;     tags="battery"
    fi

    if [ "$left" = "?" ]; then
        body="Оценка времени пока недоступна."
    else
        body="Осталось примерно $left."
    fi

    # Приписку про резкое выключение добавляем, только если сон действительно
    # запрещён - иначе она врёт.
    if ioreg -r -c IOPMrootDomain -d 1 | grep -q '"SleepDisabled" = Yes'; then
        body="$body Сон запрещён - мак не заснёт сам, выключится резко."
    else
        body="$body Сон разрешён - уснёт штатно."
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
        if push "🔋 Проверка связи" "Сторож заряда настроен. Если видишь это на телефоне - всё работает." low battery; then
            log "тестовый пуш отправлен ($BACKEND)"
            exit 0
        fi
        log "ОШИБКА: тестовый пуш не ушёл"
        exit 1
        ;;
    demo)
        # Боевое по виду уведомление для заданного порога, через тот же код.
        # Состояние не трогает, на реальную работу сторожа не влияет.
        d_thr="${2:-20}"
        d_pct="${3:-$d_thr}"
        if notify_threshold "$d_thr" "$d_pct" "1:47"; then
            log "demo: отправлено уведомление уровня ${d_thr}% (показан заряд ${d_pct}%)"
            exit 0
        fi
        log "demo: ОШИБКА отправки"
        exit 1
        ;;
    status)
        echo "заряд:    $(battery_percent)%"
        echo "питание:  $([ "$(on_ac)" = yes ] && echo 'сеть' || echo 'батарея')"
        echo "остаток:  $(time_left)"
        echo "бэкенд:   $BACKEND"
        echo "состояние: $(read_state)"
        exit 0
        ;;
esac

# --- основная логика ----------------------------------------------------

pct=$(battery_percent)
ac=$(on_ac)

if [ -z "$pct" ]; then
    log "не удалось прочитать заряд"
    exit 0
fi

read -r last_notified last_ac <<< "$(read_state)"

if [ "$ac" = yes ]; then
    # На зарядке молчим и сбрасываем пороги, чтобы при следующем разряде
    # оповещения сработали заново.
    if [ "$last_ac" != yes ]; then
        log "подключено питание, пороги сброшены (${pct}%)"
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
    log "отправлено: порог $crossed (${pct}%, осталось $left)"
else
    # Не записываем порог как отправленный - повторим на следующем запуске.
    echo "$last_notified no" > "$STATE"
    log "ОШИБКА отправки на ${pct}%, повторю позже"
fi
