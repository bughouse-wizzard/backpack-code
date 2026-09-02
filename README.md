# backpack-code

Run your Mac from your phone while the laptop stays closed in a backpack.

macOS is built on the assumption that a closed lid means a sleeping machine.
If you want the opposite - a MacBook that keeps working, stays reachable, and
lasts a full day in a bag - you have to fight a handful of non-obvious details.
This repo is the result of that fight: five `launchd` agents and six shell
scripts, no dependencies beyond what ships with macOS.

Measured on an overnight run: **93% -> 69% battery over 8.3 hours** (2.89%/h,
~35 hours from a full charge), zero sleep events across 100 samples.

*Everything here exists in both languages: [`docs/en/`](docs/en/) and
[`docs/ru/`](docs/ru/), plus [README.ru.md](README.ru.md).*

## What it does

| Component | Job |
|---|---|
| `sleep-toggle.sh` | Turns sleep prevention on and off (`pmset disablesleep`). Bind it to a hotkey - the point is to arm the machine one keystroke before it goes in the bag. |
| `backpack-mode.sh` | Every 30s: if the lid is closed **and** sleep is disabled, SIGSTOPs heavy apps and turns the panel off. Measured 149% CPU -> 6%. |
| `battery-watch.sh` | Pushes battery warnings to your phone at 30/20/10/5% via [ntfy](https://ntfy.sh) or Telegram. |
| `backpack-health.sh` | Every 30 min: checks the other agents and restarts the dead ones. They watch each other, so both have to die at once for the rig to stay down. |
| `sleep-audit.sh` | Answers "did it sleep in the last N minutes, and what is keeping it awake". |
| `night-log.sh` | Optional CSV telemetry: battery, sleep events, frozen process count. |

There is also an optional agent that keeps [Claude Code](https://claude.com/claude-code)'s
remote control alive under `launchd`, which is what this rig was originally
built for - driving a coding agent from the phone with the laptop shut.

## Install

```bash
git clone https://github.com/bughouse-wizzard/backpack-code
cd backpack-code
./install.sh
```

The installer copies scripts to `~/bin`, renders the `launchd` plists for your
user, generates a private ntfy topic, installs a `sudoers` rule so the sleep
toggle does not need a password, and loads the agents. It is idempotent.

**Then open `~/.config/backpack-mode.conf` and add your VPN client to
`NEVER_FREEZE`.** A frozen VPN behind a closed lid cannot be fixed: you have
lost the connection to the machine and there is nobody there to wake it.

Removal, including thawing anything still frozen and restoring normal sleep:

```bash
./uninstall.sh            # or --purge to drop configs and the sudoers rule too
```

### Bind the toggle to a hotkey

This part cannot be scripted - Shortcuts has no importable form that would
survive a different username - so it is five clicks, once:

1. Open **Shortcuts**, create a new shortcut.
2. Add the action **Run Shell Script**.
3. Set Shell to `/bin/bash` and paste the **absolute** path, printed by the
   installer:

   ```
   /Users/<you>/bin/sleep-toggle.sh
   ```

   `$HOME/bin/...` will not work here. Shortcuts runs shell scripts with an
   empty `$HOME` and a `PATH` that omits `/usr/sbin`, where `ioreg` lives.
4. Name it (e.g. "Sleep control") and pick an icon.
5. Open the shortcut's settings (the ⓘ on the right) and assign a keyboard
   shortcut. This rig was built around `^⌥S`.

Then arm the machine with that hotkey right before it goes in the bag, and
press it again when you take it out.

Two things that look like a broken script but are not:

- **macOS 26 removed "Pin in Menu Bar"** from Shortcuts - the Menu Bar section
  is gone from the sidebar. Older guides promise a menu bar icon; the hotkey,
  Spotlight and Quick Actions are what is left.
- **`osascript` notifications don't get through** the Shortcuts sandbox. To see
  a result, wire a Show Notification action to the Shell Script Result.

More detail in [docs/en/sleep-toggle.md](docs/en/sleep-toggle.md).

## Notifications

Four of the scripts push to your phone, not just the battery one:

| Event | Sent by |
|---|---|
| Battery crossed 90/80/…/10/5% | `battery-watch.sh` |
| Sleep prevention armed or released | `sleep-toggle.sh` |
| Backpack mode engaged or lifted | `backpack-mode.sh` |
| An agent died, and whether it was revived | `backpack-health.sh` |

Setup, once:

1. Install the **ntfy** app (iOS App Store / Google Play / F-Droid, free).
2. `./install.sh` generated a random topic for you - find it in
   `~/.config/battery-watch.conf` as `NTFY_TOPIC`.
3. Subscribe to that topic in the app.
4. `~/bin/battery-watch.sh test` - a push should arrive.

**The topic name is the entire secret.** Anyone who knows it can read your
notifications and send you fake ones, so it is long, random, and the config is
`chmod 600`. Don't paste it anywhere. Self-hosting ntfy instead: point
`NTFY_SERVER` at your own instance.

**Careful - `battery-watch.conf` is the notification config for everything
here**, not just for battery alerts; the name is historical. Delete it because
you don't care about battery pushes and you silently lose the backpack-mode and
self-repair alerts too. `backpack-health.sh` warns when it goes missing.

Alert volume scales with urgency so that ten notifications per discharge cycle
don't become noise: ntfy priority `min` at 90-60%, `low` at 50-30%, `default`
at 20%, `high` at 10%, `urgent` at 5%. Each threshold fires once per discharge
cycle and resets when you plug in. If a push fails to send, the threshold is
**not** marked as done and the next run retries - a notification can arrive
late, but it cannot be lost to a network blip.

Telegram instead of ntfy: set `BACKEND=telegram` in the config and fill in
`TG_TOKEN` (from @BotFather) and `TG_CHAT_ID`. The sending code is already
there. Full details in [docs/en/battery-watch.md](docs/en/battery-watch.md).

## The gotchas

The scripts are short. The knowledge in them is not - this is the part that
cost time.

**Clamshell detection is only `AppleClamshellState` from `ioreg`.** The powerd
assertion `Prevent sleep while display is on` is *not* released in clamshell
mode and stays up for hours, reporting a display that is on (observed: 54
minutes). Anything keyed on it never fires.

**`disablesleep` also disables display sleep**, so behind a closed lid the
panel quietly lights an empty room. Kill it with `pmset displaysleepnow`, not
by setting brightness to zero - that only dims.

**Process lists must be blacklists, never whitelists.** A "freeze everything
except what I need" rule will eventually freeze your VPN. Clients do not look
like VPNs by name, some live outside `/Applications`, and some are system
extensions. With the lid closed that mistake is unrecoverable.

**`launchd` gives a process 256 file descriptors; an interactive shell gives a
million.** Moving a long-running process from a terminal to `launchd` can drop
it into a crash loop with `low max file descriptors`. Fix with
`SoftResourceLimits/NumberOfFiles` in the plist. Check this when moving *any*
process under `launchd`.

**`KeepAlive` masks breakage.** A crash loop looks healthy to every "is the
process running" check - there is always a process, just a new one each time.
Watch the `runs` counter from `launchctl print`, or uptime. This rig caught 11
identical crashes in one night that way.

**Write state files atomically** (temp file + `mv`) instead of truncating and
appending. A reader will catch a half-written file: the night logger once
recorded 33 frozen processes where there were 77.

**Screen lock is not sleep.** "Connection lost" on the phone means the machine
genuinely slept. Locking the screen breaks neither processes nor networking, so
there is no reason to disable it.

**BSD `awk` mangles multibyte characters** in some locales - non-ASCII process
names come back as `M-PM-=M-PM-4`. Cut text with `sed`; leave `awk` for numbers.

## Docs

- [docs/en/sleep-toggle.md](docs/en/sleep-toggle.md) - the sleep switch, the sudoers rule, binding a hotkey
- [docs/en/backpack-mode.md](docs/en/backpack-mode.md) - freezing, powering the panel down, how it fails safe
- [docs/en/battery-watch.md](docs/en/battery-watch.md) - notifications, thresholds, ntfy and Telegram

## Requirements

macOS (developed on macOS 26, Apple Silicon), `bash`, and admin rights once for
the `sudoers` rule. Freezing applications uses SIGSTOP, so anything holding a
network session may need to reconnect after a thaw.

## License

MIT - see [LICENSE](LICENSE).
