# sleep-toggle - the sleep prevention switch

*[Русская версия](../ru/sleep-toggle.md)*

Flips `pmset disablesleep`, which is what stops the Mac from sleeping when the
lid closes. No third-party app: a narrow `sudoers` rule plus a Shortcuts
hotkey.

## Files

- `~/bin/sleep-toggle.sh` - the switch itself
- `/etc/sudoers.d/pmset-disablesleep` - the rule, installed by `./install.sh`

## The sudoers rule

`./install.sh` renders and installs it for you. By hand:

```bash
sed "s|__USER__|$(id -un)|g" config/pmset-disablesleep.sudoers.in > /tmp/rule
sudo visudo -cf /tmp/rule \
  && sudo install -m 0440 -o root -g wheel /tmp/rule /etc/sudoers.d/pmset-disablesleep
```

`visudo -cf` parses the file *before* it is installed. A syntax error in
`sudoers` can lock you out of `sudo` entirely, so this check is not optional.

The rule permits exactly two commands with fixed arguments:

```
/usr/bin/pmset -a disablesleep 0
/usr/bin/pmset -a disablesleep 1
```

Nothing else can be run through it - `sudoers` matches the command together
with its full argument list.

Without the rule the toggle would ask for a password, and when it is invoked
from a hotkey there is nobody to ask.

## Usage

```bash
~/bin/sleep-toggle.sh          # toggle
~/bin/sleep-toggle.sh on       # prevent sleep
~/bin/sleep-toggle.sh off      # back to normal
~/bin/sleep-toggle.sh status   # on | off
```

State is read from `ioreg` (`SleepDisabled`), not from a state file of our own,
so it cannot drift out of sync - even if you flip sleep by hand with `pmset`.

## Binding it to a hotkey

1. Open **Shortcuts**.
2. New shortcut, action **Run Shell Script**.
3. Shell `/bin/bash`, script: `$HOME/bin/sleep-toggle.sh`
4. Name it, e.g. "Sleep", and assign a keyboard shortcut in the shortcut's
   settings - `^⌥S` is the one this rig was built around.

**macOS 26 removed "Pin in Menu Bar" from Shortcuts**; the Menu Bar section is
gone from the sidebar entirely. What remains is the keyboard shortcut,
Spotlight, and Quick Actions. If you are following an older guide that promises
a menu bar icon, that is why you cannot find the setting.

Two more things about running scripts from Shortcuts, both of which look like
the script is broken when it isn't:

- **Shortcuts runs Run Shell Script with an empty `$HOME` and a truncated
  `PATH`** that does not include `/usr/sbin`, where `ioreg` lives. Use absolute
  paths and set `PATH` explicitly inside anything you call this way.
- **`osascript` notifications do not get through** - the sandbox blocks them.
  Show results with a Show Notification action wired to the Shell Script
  Result instead.

## Removal

```bash
./uninstall.sh          # thaws processes and restores sleep first
```

## About heat

Sleep prevention is only for when the machine is genuinely working while shut.
There is no reason to leave it armed on a Mac sitting on a desk: inside a
backpack it does not ventilate, and the setting survives a reboot.
