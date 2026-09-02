# backpack-mode - the backpack mode

*[Русская версия](../ru/backpack-mode.md)*

While the lid is closed and sleep prevention is on, heavy applications are
frozen and the panel is powered down. Open the lid and everything comes back.

## Files

- `~/bin/backpack-mode.sh` - the logic
- `~/.config/backpack-mode.conf` - the application lists
- `~/Library/LaunchAgents/com.backpack.backpack-mode.plist` - the agent, every 30s
- `~/.local/state/backpack-frozen.pids` - which PIDs are frozen right now
- `~/Library/Logs/backpack-mode.log` - log

## Commands

```bash
~/bin/backpack-mode.sh status    # mode, lid, what is frozen, backlight
~/bin/backpack-mode.sh targets   # what it would freeze, touching nothing
~/bin/backpack-mode.sh thaw      # release immediately
~/bin/backpack-mode.sh freeze    # force a freeze
```

## How it works

The trigger is **both conditions at once**: sleep prevention on and lid closed.

Freezing is `SIGSTOP`: the process stops dead, its memory stays, and `SIGCONT`
resumes it in the same state. Nothing is killed and nothing is lost. Measured
on a live system: the targets were burning 149% CPU, 6% after the freeze.

## Two non-obvious decisions

**A blacklist, not a whitelist.** We freeze what is listed rather than
"everything except what I need". A whitelist would eventually freeze a VPN:
clients routinely do not look like VPN clients by name, some live outside
`/Applications`, and some are system extensions. Behind a closed lid that is
unrecoverable - the only fix is to take the laptop out. This is why your own
VPN must go into `NEVER_FREEZE`.

**The lid, not the screen.** Detection is `AppleClamshellState` from `ioreg`.
The powerd assertion `Prevent sleep while display is on` is no good for this:
in clamshell it is never released and hangs for hours, reporting a display that
is on. Observed 2026-09-01 - it stood for 54 minutes with the lid shut, so the
freeze never ran at all.

## Powering down the panel

`disablesleep` suppresses sleep entirely, display sleep included, so behind a
closed lid the panel stays energised and lights an empty room.

We kill it with `pmset displaysleepnow` - no password needed, it cuts the
backlight (`IOMFBBrightnessLevel` drops to 0) and does not put the system to
sleep. Setting brightness to zero is not a substitute: it only dims, the power
stays on.

The command is idempotent and is called on every run while the lid is closed,
so if something wakes the screen it goes dark again within 30 seconds.

## Thawing: three independent paths

1. the agent on its next run - the lid opened, or sleep prevention was released
2. `sleep-toggle.sh off` - when the mode is switched off
3. by hand: `backpack-mode.sh thaw`

All three have to fail for processes to stay frozen.

## Failing towards safety

If the lid state cannot be read, it is treated as open and no freeze happens.
Better to miss out on some battery than to freeze at the wrong moment.
