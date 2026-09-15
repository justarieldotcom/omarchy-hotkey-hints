# Hotkey Hints (`t480.hotkey-hints`)

Hold **Super**, **Alt**, **Ctrl**, or **Shift** anywhere on the desktop to see,
live from `omarchy menu keybindings --print`, which hotkeys branch off that
modifier. The overlay is deliberately minimal: one compact card, capped at
~10% of the screen height, showing only the single keys that complete a combo
and the deeper modifier branches (e.g. hold Super → `+ Space → Omarchy menu`,
`+ Ctrl · 12`). Add more modifiers while holding to drill one level in. The
card floats free of any focus: drag it around, resize it from the corner,
and keep typing in whatever app you're in — it never takes the keyboard.

## How it's wired together

- **`Overlay.qml`** (`kind: panel`, `keepLoaded: true`) — the overlay itself.
  Always loaded at shell startup, no bar icon of its own (same shape as the
  built-in `omarchy.osd` plugin). It only reacts to IPC calls — `press <MOD>`,
  `release <MOD>`, `dismiss`, `state` — it never reads the keyboard directly.
- **`hotkey-watcher.py`** — a small evdev key-state watcher, run as a root
  systemd service (`omarchy-hotkey-hints-watcher.service`). It reads the
  physical modifier keys from the kernel via `/dev/input`, mirroring every
  press and release transition into the plugin's IPC. This bypasses a bug in
  Hyprland where `bindr` release bindings for bare modifier keys silently
  never fire, causing a multi-second phantom delay on every close. The watcher
  emits exactly one press on first key-down and one release on last key-up of
  each canonical modifier (Super_L/R → `SUPER`, etc.), so double-taps and
  mixed chords resolve correctly. It also (opt-in — see below) watches for a
  completed hotkey combo, matching it in-process against the known bindings
  list before ever reporting it, so it never becomes a general keylogger.
- **`Widget.qml`** (`kind: bar-widget`) — a small bar icon whose only job is
  to host **Settings** (font family/size, padding, position, opacity, and the
  `maxDirect` cap). This Omarchy shell only gives third-party plugins
  live-editable, persisted settings through the bar-widget schema mechanism,
  so this exists purely to reuse it.
- **`Model.js`** — pure parsing: turns `omarchy menu keybindings --print`
  output into hint groups bucketed by each binding's *leading* modifier, then
  `stepsForHeld()` computes progressive disclosure for the currently held set
  (direct combos, deeper modifier branches, and an overflow count). It also
  reads this plugin's own persisted settings back out of `shell.json`.

Settings are edited via the bar-widget popup and persisted into this plugin's
inline entry in `~/.config/omarchy/shell.json`, exactly like
`t480.control-station`. `Overlay.qml` re-reads that same file directly (via a
watched `FileView`) since a bare `panel`-kind plugin gets no injected
`settings` prop — so settings changes apply live, no shell restart needed.

## Free-floating, resize-stable surface

The card is a `WlrLayershell` Overlay-layer surface sized *exactly* to the
card itself (its input region is the card — clicks outside pass through).
It takes **no keyboard focus** (`WlrKeyboardFocus.None`), so keystrokes keep
flowing to whatever window is focused underneath: you can keep typing while
the hints are up, and the overlay never hijacks the active window.

- **Move**: drag the card anywhere with the mouse; it stays in screen bounds.
  Before you move it, it re-centers on every open per the `position` setting;
  once you drag it, it stays where you left it.
- **Resize**: drag the corner grip. Width is free (min 360), the type scales
  with the card width (9–26 px), and the height follows the reflowed content,
  so shrinking/growing never clips or overflows. Height can extend past the
  content with the vertical part of the corner drag.
- **Close**: the overlay closes immediately when the last held modifier is
  released — the watcher sends `release` within ~50 ms of the physical key
  going up. There's no Escape-key path: the card has no keyboard focus so it
  can't steal typing.

## Guaranteed dismissal

- **Release**: the watcher's `release` IPC fires the moment the last physical
  modifier key of a canonical modifier goes up (measured ~50–80 ms in tests),
  closing the overlay immediately.
- **Long holds**: the watcher only sends transitions, not repeats, so holding
  a key for any duration is harmless — the overlay stays open until the
  release arrives, however long that is.
- **Stuck guard**: if the watcher service is down or a modifier ever goes
  missed, the overlay closes 8 s after the last modifier event. Pure
  insurance — in normal use the release IPC closes it within ~80 ms.

## The debounce (why fast Ctrl/Shift taps don't flash it)

Every modifier also does double duty in ordinary typing or shortcuts. The
overlay defers the reveal until a modifier has been held `revealDelayMs`
(280 ms by default), so ordinary taps, capital letters, and fast shortcuts
never flash the card. `revealDelayMs` in `Overlay.qml` is the knob.

## Compact-by-default

The card says inside ~10% of the screen height by keeping only the top
`maxDirect` (default 6) direct combos on screen, truncating descriptions to
~20 characters, and collapsing the rest into a `+N more` chip. Raise
`maxDirect` from the settings popup if you want more combos listed at once.

## Remember most-used hotkeys (opt-in)

Off by default. Turn it on from the settings popup (**Remember most-used
hotkeys**) to sort each level's chips by how often you actually press that
combo, most-used first — combined with `maxDirect`, your most-used hotkeys
are what stay on screen and rarely-used ones are what fall into `+N more`.

How it's measured: `hotkey-watcher.py` (the same root evdev service that
detects modifier release) also watches for a non-modifier key going down
while a modifier is held — i.e. a completed combo, whether or not the
overlay was even open at the time (so a combo you already know by muscle
memory still counts). It's matched against the *current* keybindings list
(which `Overlay.qml` writes out to
`~/.local/state/omarchy/hotkey-hints-bindings.json` every time it refreshes)
**before** anything is reported. Only a match is ever reported — ordinary
typing, an app's own Ctrl+C, or any unbound combo never leaves the watcher
process: no IPC call, no log line, nothing written anywhere. What is reported
is just the mods+key identity (e.g. `SUPER:K`), counted in
`~/.local/state/omarchy/hotkey-hints-usage.json` — never timing, never
window/app context, never anything about the key that wasn't a known bind.

Turning the setting off stops using the counts (chips revert to the
alphabetical/shortest-first order) but keeps them on disk, so turning it back
on later doesn't need to "relearn" anything. **Reset usage stats** in the
settings popup clears the file.

## Verifying changes here

1. `node` — the Model logic is covered by `Model.selfCheck()` plus a harness
   in `/tmp`; run `node` over `Model.js` after stripping the `.pragma library`
   line (it's a QML-only pragma). See `selfCheck()` in `Model.js`.
2. Watcher: `sudo systemctl restart omarchy-hotkey-hints-watcher` after
   editing `hotkey-watcher.py`; check it with
   `systemctl status omarchy-hotkey-hints-watcher`.
3. Live: `omarchy-shell -q t480.hotkey-hints press SUPER`, wait >280 ms,
   `omarchy-shell t480.hotkey-hints state` (expect `open`), then `dismiss` —
   or just hold Super for real. Releasing the key closes it.

### Editing `Overlay.qml`

After any change to `Overlay.qml`, restart the shell for the component to
reinitialize (`omarchy restart shell`). The in-runtime "Local plugin changed,
reloading" log does not reliably reinitialize that component.