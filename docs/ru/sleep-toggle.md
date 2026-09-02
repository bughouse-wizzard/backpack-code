# sleep-toggle - тумблер запрета сна

*[English version](../en/sleep-toggle.md)*

Переключает `pmset disablesleep`, то есть запрет засыпания при закрытой крышке.
Без стороннего приложения: узкое правило sudoers плюс шорткат в меню-баре.

## Файлы

- `~/bin/sleep-toggle.sh` - сам тумблер
- `/etc/sudoers.d/pmset-disablesleep` - правило, ставится из `./install.sh`

## Установка правила sudoers

`./install.sh` рендерит и ставит его сам. Руками:

```bash
sed "s|__USER__|$(id -un)|g" config/pmset-disablesleep.sudoers.in > /tmp/rule
sudo visudo -cf /tmp/rule \
  && sudo install -m 0440 -o root -g wheel /tmp/rule /etc/sudoers.d/pmset-disablesleep
```

`visudo -cf` разбирает файл до установки - синтаксическая ошибка в sudoers может
лишить sudo целиком, поэтому проверка обязательна.

Правило разрешает ровно две команды с фиксированными аргументами:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

Ничего другого через него запустить нельзя: sudoers сверяет команду вместе с
аргументами целиком.

## Использование

```bash
~/bin/sleep-toggle.sh          # переключить
~/bin/sleep-toggle.sh on       # запретить сон
~/bin/sleep-toggle.sh off      # вернуть обычное поведение
~/bin/sleep-toggle.sh status   # on | off
```

Состояние читается из `ioreg` (`SleepDisabled`), а не из своего файла, поэтому
не рассинхронизируется, даже если переключить сон руками через `pmset`.

## Хоткей

1. Открыть **Shortcuts** (Быстрые команды).
2. Новый шорткат, действие **Run Shell Script** (Запустить скрипт).
3. Shell: `/bin/bash`, текст: `$HOME/bin/sleep-toggle.sh`
4. Назвать, например, «Контроль сна», и в настройках шортката назначить
   сочетание клавиш - оснастка строилась вокруг `^⌥S`.

**В macOS 26 «Pin in Menu Bar» из Shortcuts убрали**, раздела Menu Bar в
боковой панели больше нет. Остались хоткей, Spotlight и Quick Actions. Если
гайд обещает иконку в меню-баре - он написан до macOS 26.

Ещё две вещи про запуск скриптов из Shortcuts, обе выглядят как поломка
скрипта, хотя он цел:

- **Run Shell Script стартует с пустым `$HOME` и урезанным `PATH`**, в котором
  нет `/usr/sbin`, где лежит `ioreg`. Нужны абсолютные пути и явный `PATH`.
- **Уведомления через `osascript` не проходят** - песочница. Показывать
  результат надо действием Show Notification, подключённым к Shell Script
  Result.

## Снести

```bash
./uninstall.sh          # сперва размораживает процессы и возвращает сон
```

## Про перегрев

Запрет сна нужен, только пока ноут реально работает в закрытом виде. Лежащий на
столе мак держать в этом режиме незачем - в рюкзаке он не вентилируется, а
запрет сна переживает перезагрузку.
