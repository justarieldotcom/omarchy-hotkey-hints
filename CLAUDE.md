# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`t480.hotkey-hints` is an Omarchy shell (Quickshell/QML) plugin: hold **Super**,
**Alt**, **Ctrl**, or **Shift** anywhere on the desktop to see, live from
`omarchy menu keybindings --print`, which hotkeys branch off that modifier.
Adding more held modifiers drills one level deeper. Full behavioral spec and
rationale live in `README.md`; the history of the release-detection bug and
its fix live in `DEVNOTES.md` — read both before making non-trivial changes,
they are the authoritative design docs, not this file.

## Architecture

Four pieces, each with a single job:

- **`Overlay.qml`** (`kind: panel`, `keepLoaded: true`) — the always-loaded
  overlay surface itself. It has no bar icon and **never reads the keyboard
  directly** — it only reacts to IPC calls (`press <MOD>`, `release <MOD>`,
  `dismiss`, `state`, `ping`, `used <identity>`, `resetUsage`) sent by the
  watcher/widget below. It re-reads `~/.config/omarchy/shell.json` directly
  via a watched `FileView` (a bare `panel`-kind plugin gets no injected
  `settings` prop), so settings changes from the widget apply live without a
  shell restart. It also writes the current keybindings list out to
  `~/.local/state/omarchy/hotkey-hints-bindings.json` on every refresh (the
  watcher's usage-tracking allowlist — see below) and persists usage counts to
  `~/.local/state/omarchy/hotkey-hints-usage.json`.
- **`hotkey-watcher.py`** — a root systemd service
  (`omarchy-hotkey-hints-watcher.service`) that reads physical keys from
  `/dev/input` via `python-evdev` and mirrors modifier press/release
  transitions into the plugin's IPC. This exists because Hyprland's `bindr`
  release bindings for bare modifier keys never fire (libinput-based
  compositors lose the held-key state) — see `DEVNOTES.md` for the full
  investigation. It reads only, never grabs devices. It also (for the opt-in
  usage-tracking feature) watches for a non-modifier key going down while a
  modifier is held — but only ever reports one if it matches an entry in
  `hotkey-hints-bindings.json`; anything else (ordinary typing, app
  shortcuts, unbound combos) is dropped in-process, so it never becomes a
  general keylogger despite now reading regular keys, not just modifiers.
- **`Widget.qml`** (`kind: bar-widget`) — small bar icon whose only job is to
  host the **Settings** popup (font, padding, position, opacity, `maxDirect`,
  `rememberUsage`). This exists purely because the Omarchy shell only gives
  third-party plugins live-editable, persisted settings through the
  bar-widget schema mechanism — the overlay itself has no popup of its own.
- **`Model.js`** (`.pragma library`) — pure parsing/logic, deliberately kept
  free of QML/Quickshell imports so it's testable in isolation:
  - `groupKeybindings()` turns `omarchy menu keybindings --print` output into
    hint groups bucketed by each binding's *leading* modifier.
  - `stepsForHeld()` computes progressive disclosure for the currently held
    modifier set: direct combos (one more key completes them), deeper
    modifier branches, and an overflow count. Optionally takes a usage-counts
    map to sort direct combos most-used-first.
  - `usageIdentity()` / `flattenBindingIdentities()` / `parseUsageCounts()` —
    the mods+key identity format shared with the watcher, and defensive
    parsing of the persisted usage file.
  - `pickBarEntrySettings()` reads this plugin's own persisted settings back
    out of a parsed `shell.json`.

Settings flow: edited in `Widget.qml`'s popup → persisted into this plugin's
inline entry in `~/.config/omarchy/shell.json` (same pattern as the sibling
`t480.control-station` plugin) → `Overlay.qml` picks them up live via its own
`FileView` watch on that same file.

## Verifying changes

There is no build step and no test runner config — this is a set of plugin
source files loaded directly by the Omarchy shell / Quickshell.

1. **`Model.js` logic** — covered by `Model.selfCheck()` (assert-based). Run
   it manually while developing, e.g. via `qs -c "import 'Model.js' as Model;
   Model.selfCheck()"`, or strip the `.pragma library` line (QML-only) and run
   the file under plain `node`.
2. **Watcher** — after editing `hotkey-watcher.py`:
   `sudo systemctl restart omarchy-hotkey-hints-watcher`, then check with
   `systemctl status omarchy-hotkey-hints-watcher`.
3. **Live, end-to-end** — `omarchy-shell -q t480.hotkey-hints press SUPER`,
   wait >280 ms (the reveal debounce), `omarchy-shell t480.hotkey-hints state`
   (expect `open`), then `dismiss` — or just hold Super for real; releasing
   the key should close it within ~50–80 ms.
4. **After editing `Overlay.qml`**, restart the shell for the component to
   reinitialize: `omarchy restart shell`. The in-runtime "Local plugin
   changed, reloading" hot-reload does **not** reliably reinitialize a panel
   component.

## Things to keep in mind when changing this code

- `Overlay.qml` must stay keyboard-focus-free (`WlrKeyboardFocus.None`) and
  reactive-only (IPC in, never reading `/dev/input` or compositor key events
  itself) — that split is what makes the free-floating, non-focus-stealing
  card and the reliable release detection both work at once.
- `revealDelayMs` (280 ms, in `Overlay.qml`) is the debounce that keeps
  ordinary fast modifier taps (capital letters, quick shortcuts) from
  flashing the card open — don't remove it without reproducing that problem.
- `stuckCloseMs` (8 s) is pure insurance for when the watcher service is down
  or misses a release; the primary close path is always the watcher's
  `release` IPC call, not this timer.
- The watcher canonicalizes both sides of each modifier (e.g. `Super_L`/
  `Super_R` → `SUPER`) and only emits `release` when *both* physical keys of
  that canonical modifier are up — preserve that when touching `MODS` or
  `on_key()` in `hotkey-watcher.py`, or double-taps/mixed chords will misfire.
- `omarchy-hotkey-hints-watcher.service`'s `ExecStart` is a hardcoded
  absolute path — update it if the plugin is relocated.
- The watcher's non-modifier keydown handling (usage tracking) must **never**
  report a key that doesn't match `hotkey-hints-bindings.json` — that
  match-before-report split is the entire reason a root service reading
  regular keys isn't a keylogger. Don't add a "report everything, filter
  later" path, even temporarily for debugging.
- `on_key()` distinguishes evdev's raw key value (`0`=up, `1`=down,
  `2`=autorepeat) rather than collapsing to a bool — holding a hotkey down
  must not spam `used` IPC calls at the keyboard repeat rate.
- `Model.usageIdentity()` upper-cases both mods and key before joining,
  because `omarchy menu keybindings --print` is inconsistent about key-name
  casing (`Delete` vs `DELETE`). Any new code producing or consuming an
  identity string must go through that function rather than hand-rolling the
  join, or matches will silently fail on mixed-case binds.
