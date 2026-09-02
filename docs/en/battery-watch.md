# battery-watch - battery alerts on your phone

*[Русская версия](../ru/battery-watch.md)*

A `launchd` agent checks the charge every 5 minutes and pushes to your phone
when it crosses a threshold. It needs no session and no terminal - it runs
whether or not you are logged in anywhere.

## This config is shared by every alert

`~/.config/battery-watch.conf` holds the notification settings for the whole
rig, not just for the battery. The filename is historical. Everything that
reads the topic from it:

| Event | Sent by |
|---|---|
| Battery crossed 90/80/…/10/5% | `battery-watch.sh` |
| Sleep prevention armed or released | `sleep-toggle.sh` |
| Backpack mode engaged or lifted | `backpack-mode.sh` |
| An agent died, and whether it was revived | `backpack-health.sh` |

Delete the file because you don't want battery pushes, and the rest go silent
too - including the self-repair alerts, which are exactly the ones that matter
when the lid is shut and you cannot look at the machine. `backpack-health.sh`
warns when the file is missing.

## Files

- `~/bin/battery-watch.sh` - the watcher itself
- `~/.config/battery-watch.conf` - settings, mode `600`, **the topic name is a secret**
- `~/Library/LaunchAgents/com.backpack.battery-watch.plist` - the agent
- `~/Library/Logs/battery-watch.log` - log, written only when there is something to say
- `~/.local/state/battery-watch.state` - which threshold has already fired

## Subscribing on the phone

1. Install the **ntfy** app (iOS App Store / Google Play / F-Droid, free).
2. Subscribe to the topic from `~/.config/battery-watch.conf` (`NTFY_TOPIC`).
   `./install.sh` generated a random one for you.
3. Verify: `~/bin/battery-watch.sh test` - a push should arrive.

The topic name is the entire secret: whoever knows it can read your
notifications and send you their own. That is why it is long and random, and
why it does not belong in a repo, a screenshot, or a chat. Running your own
ntfy server instead: point `NTFY_SERVER` at it.

## Thresholds and loudness

`THRESHOLDS` in the config, descending. Default: 90 80 70 60 50 40 30 20 10 5.

Loudness rises as the battery drains, so that ten notifications per cycle do
not turn into noise you learn to swipe away:

| Threshold | ntfy priority | How it behaves |
|---|---|---|
| 90-60 | `min` | silent, collapsed in the shade |
| 50-30 | `low` | silent but visible |
| 20 | `default` | sound and vibration |
| 10 | `high` | pops over the screen |
| 5 | `urgent` | insistent, long vibration |

Levels are bound to ranges rather than to specific numbers, so you can change
the thresholds in the config and the loudness follows.

Each threshold fires once per discharge cycle. Plug the machine in and the
thresholds reset, so the next discharge alerts from scratch.

If the charge fell through several steps at once - during a build, say - the
**lowest** crossed threshold wins. Urgency matters more than completeness.

## Commands

```bash
~/bin/battery-watch.sh          # normal run, this is how launchd calls it
~/bin/battery-watch.sh status   # charge, power source, estimate, state
~/bin/battery-watch.sh test     # test push
```

## Managing the agent

```bash
launchctl print gui/$(id -u)/com.backpack.battery-watch        # state
launchctl kickstart -k gui/$(id -u)/com.backpack.battery-watch # run it now
launchctl bootout gui/$(id -u)/com.backpack.battery-watch      # turn it off
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.backpack.battery-watch.plist
```

## Telegram instead of ntfy

Set `BACKEND=telegram` in the config and fill in `TG_TOKEN` (from @BotFather)
and `TG_CHAT_ID`. The sending code is already there; switching is config-only.

## What happens when the network drops

If a push fails to send, the threshold is **not** recorded as fired, and the
attempt repeats in 5 minutes. An alert can arrive late, but it cannot be lost
to a network blip.

## Why this exists at all

With sleep prevention on (`~/bin/sleep-toggle.sh`), the Mac does not perform an
emergency sleep at low charge - it cuts out. The alert at 20% is what gives you
time to shut things down like a human being.
