# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

`justarieldotcom.hotkey-hints` is an Omarchy shell (Quickshell/QML) plugin: hold
**Super**, **Alt**, **Ctrl**, or **Shift** anywhere on the desktop to see, live
from `omarchy menu keybindings --print`, which hotkeys branch off that modifier.
Adding more held modifiers drills one level deeper. `README.md` is the
user-facing spec; `docs/DEVNOTES.md` holds the history of the release-detection
bug, the de-rooting rework, and the bugs found along the way — read both before
making non-trivial changes. They are the authoritative design docs, not this
file.

## Architecture

Four pieces, each with a single job:

- **`Overlay.qml`** (`kind: panel`, `keepLoaded: true`) — the always-loaded
  overlay surface. It **launches and supervises `hotkey-watcher.py`** as an
  ordinary unprivileged child process and acts only on validated lines from its
  stdout (`press <MOD>`, `release <MOD>`, `used <identity>`, `error <code>`).
  It also answers IPC (`press`, `release`, `dismiss`, `state`, `ping`, `used`,
  `resetUsage`, `status`, `retry`), kept as the manual test surface and for
  Widget.qml's Preview button. It re-reads `~/.config/omarchy/shell.json`
  directly via a watched `FileView` (a bare `panel`-kind plugin gets no injected
  `settings` prop), so settings changes apply live without a shell restart. It
  writes the current keybindings list to `hotkey-hints-bindings.json` (the
  watcher's allowlist — see below) on every refresh, and persists usage counts
  to `hotkey-hints-usage.json`.
- **`hotkey-watcher.py`** — reads physical keys from `/dev/input` via
  `python-evdev` and prints one line per modifier transition. This exists
  because Hyprland's `bindr` release bindings for bare modifier keys never fire
  (libinput-based compositors lose the held-key state) — see `docs/DEVNOTES.md`.
  It reads only, never grabs. It runs as the **ordinary user**; reading
  `/dev/input` needs group `input` and nothing more — no root, no systemd unit,
  no setuid. It also (for the opt-in usage-tracking feature) watches for a
  non-modifier key going down while a modifier is held — but only ever reports
  one if it matches an entry in `hotkey-hints-bindings.json`; anything else
  (ordinary typing, app shortcuts, unbound combos) is dropped in-process, so it
  never becomes a general keylogger despite reading regular keys.
- **`Widget.qml`** (`kind: bar-widget`) — small bar icon whose only job is to
  host the **Settings** popup (font, padding, position, opacity, `maxDirect`,
  `rememberUsage`) and to surface watcher health with a **Retry watcher**
  button. It exists because the Omarchy shell only gives third-party plugins
  live-editable, persisted settings through the bar-widget schema mechanism.
- **`Model.js`** (`.pragma library`) — pure parsing/logic, deliberately free of
  QML/Quickshell imports so it's testable in isolation:
  - `groupKeybindings()` buckets `omarchy menu keybindings --print` output by
    each binding's *leading* modifier.
  - `stepsForHeld()` computes progressive disclosure for the held modifier set:
    direct combos, deeper modifier branches, an overflow count. Optionally takes
    a usage-counts map to sort direct combos most-used-first.
  - `usageIdentity()` / `flattenBindingIdentities()` / `parseUsageCounts()` —
    the mods+key identity format shared with the watcher, and defensive parsing
    of the persisted usage file.
  - `pickBarEntrySettings()` reads this plugin's persisted settings out of a
    parsed `shell.json`.

Settings flow: edited in `Widget.qml`'s popup → persisted into this plugin's
inline entry in `~/.config/omarchy/shell.json` → `Overlay.qml` picks them up
live via its own `FileView` watch on that same file.

Adding or changing a setting means touching three files in lockstep:
`manifest.json` (the `barWidget.defaults` value **and** its `schema` entry),
`Widget.qml` (a backing property, a control in the popup, its line in `save()`,
and its reset in the popup's load path), and `Overlay.qml` (a `readonly
property` derived from `rawSettings`). Note that `Widget.qml` `save()`s every
non-string value through `String(...)`, so `Overlay.qml` parses back
defensively — `parseInt`/`parseFloat` with a range check falling back to the
default, and `=== true || === "true"` for booleans. Keep that coercion on both
sides or a setting will read as its default forever.

Files this plugin owns at runtime: its inline entry in
`~/.config/omarchy/shell.json` (written by `Widget.qml`, watched by
`Overlay.qml`), and under `$XDG_STATE_HOME/omarchy` (default
`~/.local/state/omarchy`): `hotkey-hints-bindings.json` (written by
`Overlay.qml`, read by the watcher) and `hotkey-hints-usage.json`.

## Verifying changes

No build step and no test runner config — these are plugin source files loaded
directly by the Omarchy shell.

1. **`Model.js` logic** — covered by `Model.selfCheck()` (assert-based; returns
   `true`, throws on failure). `.pragma library` is a QML-only directive, so
   strip it and eval under plain `node`:

   ```sh
   node -e "eval(require('fs').readFileSync('Model.js','utf8').replace('.pragma library','')); console.log(selfCheck())"
   ```

   (`require('./Model.js')` yields `{}` — no `module.exports`, by design.) Add
   assertions to `selfCheck()` itself; there is no separate test file.
2. **Watcher** — `python3 -m py_compile hotkey-watcher.py`, then drive it with a
   synthetic `uinput` keyboard while it runs unprivileged. See the testing
   scaffold section in `docs/DEVNOTES.md`; the negative assertions (no `used`
   line for unbound combos or ordinary typing) are the ones that matter.
3. **QML** — `qmllint -I "$OMARCHY_PATH/shell" Overlay.qml Widget.qml`.
   Expect noise: `qs.Commons`/`qs.Ui` singletons don't resolve outside the
   shell's own import graph, and `onExited` warns about an unresolvable
   `QProcess::ExitStatus` (the built-in clipboard plugin produces three of the
   same). Compare warning *categories* against the baseline rather than
   chasing zero.
4. **Manifest** — `omarchy plugin validate <plugin dir>` (silence = pass).
5. **Live, end-to-end** — `omarchy-shell justarieldotcom.hotkey-hints status`
   (expect `running`), then `omarchy-shell -q justarieldotcom.hotkey-hints press
   SUPER`, wait >280 ms, `omarchy-shell justarieldotcom.hotkey-hints state`
   (expect `open`), then `dismiss`. **The `-q` flag must come before the
   target** — `omarchy-shell` only strips it as `$1`, so
   `omarchy-shell <target> -q press SUPER` silently calls a method named `-q`.
6. **After editing `Overlay.qml`**, restart the shell (`omarchy restart shell`)
   — the in-runtime "Local plugin changed, reloading" hot-reload does **not**
   reliably reinitialize a panel component.

## Things to keep in mind when changing this code

- `Overlay.qml` must stay keyboard-focus-free (`WlrKeyboardFocus.None`) and must
  never interpret the keyboard itself — it acts only on the watcher's validated
  stdout lines and on IPC. That split is what makes the free-floating,
  non-focus-stealing card and reliable release detection work at once.
- The watcher's non-modifier keydown handling (usage tracking) must **never**
  report a key that doesn't match `hotkey-hints-bindings.json` — that
  match-before-report split is the entire reason a helper reading regular keys
  isn't a keylogger. Don't add a "report everything, filter later" path, even
  temporarily for debugging.
- Every line from the watcher is matched against an anchored regex in
  `handleWatcherLine()` before anything acts on it. Keep it that way; that
  function is the trust boundary.
- `setpriv --pdeathsig TERM` on the watcher command is what stops it outliving
  the shell. Remove it and every shell restart orphans a watcher.
- Drop a dead evdev device by **path**, never by fd: `close()` sets `.fd` to
  `-1`, so an fd-based filter keeps the device it meant to remove and the next
  `select()` raises `ValueError` (not an `OSError`, so it escapes the loop's
  handler). This was a real crash; see `forget_device()`.
- `on_key()` distinguishes evdev's raw value (`0`=up, `1`=down, `2`=autorepeat)
  rather than collapsing to a bool — holding a hotkey must not emit `used` at
  the keyboard repeat rate.
- The watcher canonicalizes both sides of each modifier (`Super_L`/`Super_R` →
  `SUPER`) and only emits `release` when *both* physical keys are up — preserve
  that in `MODS`/`on_key()` or double-taps and mixed chords misfire.
- `Model.usageIdentity()` upper-cases both mods and key, because `omarchy menu
  keybindings --print` is inconsistent about key-name casing (`Delete` vs
  `DELETE`). `KEY_NAMES` in the watcher is upper-cased once at import for the
  same reason — mixed-case XF86 media names silently never matched before.
  Any new code producing or consuming an identity must go through
  `usageIdentity()` rather than hand-rolling the join.
- `revealDelayMs` (280 ms) is the debounce that keeps ordinary fast modifier
  taps (capital letters, quick shortcuts) from flashing the card open — don't
  remove it without reproducing that problem.
- `stuckCloseMs` (8 s) is pure insurance for a watcher that died or missed a
  release; the primary close path is always the `release` line.
- `panel.screen` is assigned only while the surface is unmapped (inside
  `revealTimer.onTriggered`, before `opened` flips). Nothing in this shell
  reassigns `.screen` on a visible window.

## Publishing

This plugin is listed on the Omarchy plugin marketplace, whose automated
security baseline raises a reviewable "capability" for things it finds in
*scanned* source files (`.py .sh .qml .js .mjs .service .toml .yaml .yml`, plus
anything with the exec bit or an installer-ish name). `.md` files and `docs/`
are not scanned. The plugin currently clears the baseline with **zero findings
and zero capabilities**, which is what qualifies it for the automatic
*Snapshot verified* badge — so keep `sudo`, `pkexec`, `systemctl`,
`systemd-run`, `pacman`, `pip install`, `curl`, `wget` and `git clone` out of
those files (setup instructions belong in `README.md`), add no `*.service` file,
and add no file named `install*`/`setup*`/`uninstall*`. `SUBMISSION.md` has the
submission details and the full checklist.
