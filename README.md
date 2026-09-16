# Hotkey Hints (`io.github.mikus2604.hotkey-hints`)

Hold **Super**, **Alt**, **Ctrl**, or **Shift** anywhere on the desktop to see,
live from `omarchy menu keybindings --print`, which hotkeys branch off that
modifier. Add more modifiers while holding to drill one level in. The card
never takes keyboard focus: keep typing in the app underneath, and **release
the last modifier** to close it. Escape is not a close path, because the
overlay cannot steal the keyboard.

This plugin is a Super/Alt/Ctrl/Shift drill-down, not a Super-only cheatsheet.
The card floats, can be dragged and resized, and stays capped at a handful of
direct combos plus modifier branches (`+ Ctrl · 12`).

## Install

```bash
omarchy plugin add https://github.com/mikus2604/Omarchy-HotKeys-Teacher.git --enable
```

Then, in a visible terminal, install the **root-owned** modifier watcher (this
is a separate, consented step — `omarchy plugin add` does not elevate anything):

```bash
sudo bash ~/.config/omarchy/plugins/io.github.mikus2604.hotkey-hints/scripts/install.sh
omarchy restart shell
```

Add the bar widget from **Setup → Plugins** if you want the settings popup
(font, delay, opacity, usage tracking). The overlay itself has no bar icon.

Requirements: Omarchy 4 (Quickshell), `python-evdev`, and a one-time `sudo` to
copy `hotkey-watcher.py` into `/usr/local/libexec/omarchy-hotkey-hints/` and
enable a systemd unit. Re-run `install.sh` after plugin updates if you want
the helper refreshed — the copy in libexec is what actually runs.

The unit’s `ExecStart` points at that **root-owned** path, never at the
plugin checkout.

## How it is wired

- **`Overlay.qml`** (`kind: panel`, `keepLoaded: true`) — the overlay. IPC
  only: `press`, `release`, `dismiss`, `state`, `ping`. No keyboard grab.
- **`hotkey-watcher.py`** — installed to `/usr/local/libexec/...`, started as
  root so it can open `/dev/input`, then `seteuid` to the session user for IPC
  and state. Default: the eight modifier keys only. Hyprland’s `bindr` release
  binds for bare modifiers never fire; the kernel is used instead.
- **`Widget.qml`** (`kind: bar-widget`) — settings popup. The shell only
  persists third-party settings through the bar-widget schema.
- **`Model.js`** — parses `omarchy menu keybindings --print` and computes
  progressive disclosure. Runnable under `scripts/selfcheck.sh`.
- **`scripts/state-file.py`** — descriptor-bound (`O_NOFOLLOW|O_NONBLOCK`)
  reads and atomic writes of plugin state. `FileView` in QML is watcher-only.
- **`scripts/print-keybindings.sh`** — bounded, deadline-capped producer for
  the keybindings dump.

## Usage tracking (opt-in, off by default)

Turn on **Remember most-used hotkeys** in the settings popup to sort chips by
how often you actually press that *bound* combo.

When that setting is off, the watcher never inspects non-modifier keys.

When it is on, a non-modifier keydown while a modifier is held is looked up
against `~/.local/state/omarchy/hotkey-hints/bindings.json` **before**
anything is written. No match → nothing leaves the process: no IPC, no log,
no file. A match increments a count in
`~/.local/state/omarchy/hotkey-hints/usage.json` (mods+key identity only —
never window/app context, never timing, never unbound keys).

## Files written

| Path | What |
|---|---|
| `~/.config/omarchy/shell.json` | Bar-widget settings (via the shell’s own `updateEntryInline`) |
| `~/.local/state/omarchy/hotkey-hints/bindings.json` | Flattened known-binding allowlist |
| `~/.local/state/omarchy/hotkey-hints/usage.json` | Opt-in usage counts |
| `~/.local/state/omarchy/hotkey-hints/watch.json` | `{ "rememberUsage": bool }` for the watcher |
| `/usr/local/libexec/omarchy-hotkey-hints/hotkey-watcher.py` | Root-owned helper (install.sh) |
| `/etc/systemd/system/omarchy-hotkey-hints-watcher.service` | systemd unit (install.sh) |

The overlay does **not** rewrite Hyprland bindings or other plugins’ files.

## Removing

Stop the watcher **before** deleting the plugin directory, so the uninstall
script is still there:

```bash
sudo bash ~/.config/omarchy/plugins/io.github.mikus2604.hotkey-hints/scripts/uninstall.sh --purge
omarchy plugin remove io.github.mikus2604.hotkey-hints
```

If the plugin directory is already gone:

```bash
sudo systemctl disable --now omarchy-hotkey-hints-watcher.service
sudo rm -f /etc/systemd/system/omarchy-hotkey-hints-watcher.service
sudo rm -f /usr/local/libexec/omarchy-hotkey-hints/hotkey-watcher.py
sudo rmdir /usr/local/libexec/omarchy-hotkey-hints
sudo systemctl daemon-reload
```

`--purge` deletes `~/.local/state/omarchy/hotkey-hints/` for `SUDO_USER` only
when that path is a real directory owned by that user (never a symlink).
Bar-widget settings remain in `~/.config/omarchy/shell.json` until you remove
the widget from the bar. `omarchy plugin remove` does **not** stop the
systemd unit — that is why the uninstall script exists.


## Verifying changes

```bash
bash scripts/selfcheck.sh
```

Live: hold Super for longer than the reveal delay (280 ms default). Release
should close the card within ~80 ms if the watcher is running
(`systemctl status omarchy-hotkey-hints-watcher`). After editing
`Overlay.qml`, `omarchy restart shell`.
