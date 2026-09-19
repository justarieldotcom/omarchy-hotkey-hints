# Omarchy Hotkeys Teacher — notes

Status: the reported bug ("overlay takes ~6 s to disappear after releasing a
modifier") is **fixed** and verified on Hyprland 0.56.2 / Omarchy shell
(Quickshell). Overlay now closes **50–80 ms** after the last modifier key is
released.

## The bug: Hyprland silently drops modifier-release events

Symptom: hold Super (or Alt/Ctrl/Shift) — the hotkey card appears — release
the key — the card stays for ~6 s, then vanishes.

Investigation (all on Hyprland 0.56.2):

- The original design bound all 8 bare modifier keys (`Super_L/R`, `Alt_L/R`,
  `Control_L/R`, `Shift_L/R`) in `~/.config/hypr/bindings.lua`:
  - press: `omarchy-shell -q justarieldotcom.hotkey-hints press <MOD>` with
    `{ repeating = true }` (acts as a keepalive while held),
  - release: `... release <MOD>` with `{ release = true }`.
- Empirically, **the release bind never fires.** Instrumenting the plugin over
  days of usage produced zero `RELEASE` log lines. `hyprctl binds -j` confirms
  all 8 binds are registered with the `r` (release) flag — they simply never
  dispatch. This matches the documented voxtype warning: *"libinput-based
  compositors (Hyprland, Sway, River) lose track of the held-key state and the
  release event never fires."*
- Key-repeat keepalive is unreliable too: repeats flow only ~2–3 s into a
  hold (at ~19/s), then Hyprland stops forwarding them entirely, even while
  the key is still physically held (verified by controlled 5 s real-keyboard
  holds and a synthetic uinput rig).
- Ruled out ways to get a reliable release signal from the compositor:
  - `hyprctl activewindow -j` has **no `modmask` field** in this build.
  - Hyprland has **no per-key IPC event**: the `.socket2.sock` stream only
    emits `activelayout`; `hyprctl subscribe/events` → "unknown request";
    `strings /usr/bin/Hyprland` shows no keyboard-key event.
- Consequence: with only Hyprland signals, the overlay cannot distinguish
  "released" from "held but Hyprland stopped sending events", so the only
  safe close was the 8 s stuck-guard → the reported delay.

## The fix: an evdev key-state watcher (best effort, minimal)

`hotkey-watcher.py` bypasses the compositor's broken modifier handling
entirely. It reads the **physical** keyboard state from `/dev/input` via
`python-evdev` and reports every modifier transition on stdout, one line per
event, to the `Overlay.qml` process that launched it:

- Tracks the 8 evdev modifier keycodes (KEY_LEFTMETA/RIGHTMETA/LEFTCTRL/
  RIGHTCTRL/LEFTALT/RIGHTALT/LEFTSHIFT/RIGHTSHIFT).
- Canonicalizes modifiers: `Super_L` or `Super_R` → `SUPER`, etc.
- Emits exactly one `press` line on the first key-down of a canonical
  modifier and one `release` line when the **last** of its two keys goes up — so
  tap-Super_R while holding Super_L resolves correctly.
- Watches the raw `EV_KEY` transitions, which are never subject to the
  compositor's key-repeat dropping; press/release reach the shell in tens of
  milliseconds.
- Device hotplug: rescans `/dev/input/event*` every 2 s; opens new keyboards,
  drops closed ones, and seeds the initial state from `InputDevice.active_keys()`.
- Read-only: it never grabs devices, so it steals no input.

Why this covers both requirements simultaneously (unlike any timer-only
approach): holds of any length keep the overlay open (only transitions are
sent, no futile keepalives), and release still closes instantly because the
kernel is ground truth — independent of how long the key was held.

Verification (synthetic uinput keyboard, live shell state sampling):

| scenario | open→closed latency | notes |
|---|---|---|
| 5 s Super hold | ~70 ms after release | stayed open full 5 s |
| Super+Ctrl chord (Ctrl released first) | ~78 ms after Super | correct order |
| Super_L then Super_R | ~52 ms after both up | no premature release |
| Ctrl tap < 280 ms | never opened | debounce works |

## Usage tracking: expanding the watcher's read scope without it becoming a keylogger

Feature: an opt-in `rememberUsage` setting that reorders each level's chips
by how often the user actually presses that combo. The hard part wasn't the
ordering (that's a one-line comparator change in `Model.js`) — it was that
literally nothing in this plugin had ever observed a *completed* hotkey
before. `Overlay.qml` is deliberately keyboard-focus-free (see the top-level
architecture note); the only thing that ever reads raw keys is the root
watcher, and until now it only read the 8 modifier keycodes.

Options considered:
- **Compositor signal for "a bind fired"** — ruled out again, same as the
  release-detection investigation above: no such event exists on Hyprland's
  IPC socket.
- **Branch drill-path proxy** (count which modifier branch the user adds
  while the overlay is open, entirely inside `Overlay.qml`, no watcher
  changes) — simple and required zero new privilege, but only reorders
  modifier-branch chips, not the leaf hotkey chips, and misses every combo
  the user already knows by muscle memory (overlay never opens for those).
  Rejected as too weak a signal for what was actually asked.
- **Real completed-hotkey tracking** (chosen): extend the watcher to also
  watch non-modifier keydowns while a modifier is held.

The risk with the chosen option is obvious: a helper reading *all* keys, not
just modifiers, is a meaningfully bigger surface — in the worst case, a
keylogger. (It no longer runs as root — see the de-rooting section below — but
group `input` still means "can read the keyboard", so the argument stands.) The
mitigation is a strict match-before-report split:
- `Overlay.qml` writes every known binding (from the same
  `omarchy menu keybindings --print` parse used for the hints themselves) to
  `~/.local/state/omarchy/hotkey-hints-bindings.json` as a flat list of
  `Model.usageIdentity()` strings.
- The watcher loads that file (poll-on-keydown, mtime-checked, same
  no-inotify style as the rest of the file) into an in-memory set.
- A non-modifier keydown while a modifier is held is looked up in that set
  **before** anything happens. No match → nothing happens: nothing printed,
  nothing written, no log line. Only a match prints one
  `used <identity>` line on the same stdout the press/release lines already use,
  so it adds no new channel at all — just an occasional extra line, and only
  for real hotkey presses, which are inherently infrequent.
- What's reported is only the mods+key identity string (e.g. `SUPER:K`) —
  never which window/app had focus, never timing, never anything for a key
  that didn't match a real bind.

Autorepeat handling: evdev's `EV_KEY` value is `0`=up, `1`=down, `2`=repeat.
The original code collapsed 1 and 2 into a single `pressed=True` (harmless
for modifiers, since the `down` set already dedupes). Usage tracking can't
tolerate that collapse — holding `SUPER+K` would otherwise spam a `used` IPC
call at the keyboard's repeat rate — so `on_key()` now takes the raw evdev
value and returns immediately on `2`.

Key-name mapping: evdev's own keycode names (`KEY_K`, `KEY_9`, `KEY_F9`, …)
already match the key-name strings `omarchy menu keybindings --print` uses
for plain letters/digits/F-keys, generated once at import time from
`evdev.ecodes.keys`. A short explicit table (`KEY_NAMES` in
`hotkey-watcher.py`) covers the handful of keys where the two naming schemes
diverge (`KEY_ENTER`→`RETURN`, `KEY_ESC`→`ESCAPE`, `KEY_DOT`→`PERIOD`,
`KEY_LEFTBRACE`→`BRACKETLEFT`, `KEY_SYSRQ`→`PRINT`, the `XF86Audio*`/
`XF86Kbd*`/`XF86Mon*` media keys) — verified against a real
`omarchy menu keybindings --print` dump on this machine, not guessed. A key
that isn't in the table is simply never reported — safe degradation (the
combo just never gets to float to the top), matching this file's existing
best-effort philosophy. `omarchy menu keybindings --print`'s own key-name
casing is inconsistent (`Delete` vs `DELETE`, `Home` vs `HOME`); both sides
of the match upper-case via `Model.usageIdentity()` / the equivalent join in
the watcher, so this doesn't cause false negatives.

Known limitation, accepted rather than solved: mouse-button binds (e.g.
`SUPER + LEFT MOUSE BUTTON`) are structurally untrackable here, since
`is_keyboard()` only opens devices with a `KEY_A` capability — mice are never
opened at all, so their button events never reach `on_key()`. Usage tracking
only ever applies to keyboard-originated combos.

## Architecture / files

- `Overlay.qml` — the overlay (panel plugin). Launches and supervises
  `hotkey-watcher.py`, and acts only on validated lines from its stdout (plus
  the IPC surface kept for testing). Never interprets the keyboard itself.
  `revealDelayMs: 280` debounces fast modifier taps; `stuckCloseMs: 8000` is
  now pure insurance.
- `hotkey-watcher.py` — the evdev watcher described above.
- `Model.js` — keybinding parsing + progressive disclosure (`selfCheck()`).
- `Widget.qml` — bar-widget used only to expose the settings popup.
- `manifest.json` — plugin metadata / settings schema.

## Installing

See the README — it is `omarchy plugin add`, the `python-evdev` package, and
`input` group membership. There is no unit to install and no path to edit.

Removing any old per-modifier `bindr` entries for this plugin from your
Hyprland keybindings is still worth doing if you ever had them: the watcher
owns modifier press/release now.

## Operational notes / gotchas

- The watcher is an ordinary child of the shell. To restart it after editing
  `hotkey-watcher.py`, restart the shell (`omarchy restart shell`) — or use
  **Retry watcher** in the settings popup, which re-spawns it in place.
- `setpriv --pdeathsig TERM` is what guarantees the watcher cannot outlive the
  shell. Without it, every shell restart would orphan a watcher; keep it.
- The shell hot-reload ("Local plugin changed, reloading") does **not**
  reliably reinitialize the panel component — restart the shell after editing
  `Overlay.qml`.
- `hotkey-watcher.py` deliberately does not use libinput's grab: reading
  without grabbing is enough and models the keyboard-compositor split per
  Omarchy's layering.

## Fixed: settings popup opened once, then never again (2026-09-15)

Symptom: click the bar icon, the settings popup opens fine; click anywhere
outside it to dismiss (the normal way to close it); click the bar icon
again — nothing happens, ever again, with no error anywhere (IPC
`open`/`toggle`/`show` to `justarieldotcom.hotkey-hints.settings` all report success,
but no `omarchy-keyboard-panel` layer ever maps — checked with `hyprctl
layers`).

Root cause: `Widget.qml`'s `KeyboardPanel { id: popup }` bound its own
`open` to the outer widget's state one-way (`open: root.opened`) but never
set `owner: root`. Base `KeyboardPanel.qml`'s outside-click dismissal calls
its own `close()`, which — with no `owner` — falls back to directly
assigning `root.open = false` on itself (base component, not this plugin).
In QML, assigning a value to a property that already has a live binding
**permanently destroys that binding** (this is standard, documented Qt
behavior — see https://doc.qt.io/qt-6/qtqml-syntax-propertybinding.html).
After that one dismiss, `popup.open` is a disconnected dead value; nothing
Widget.qml or the outer bar icon does can ever flip it again. This is a
named, known Omarchy plugin footgun — see the upstream plugin-dev docs'
"A Panel Opens Once but Not Again" troubleshooting entry
(https://plugins.omarchy.org/develop.html).

Fix: add `owner: root` to the `KeyboardPanel` block, matching every other
`KeyboardPanel` usage in this shell (first-party `omarchy.audio` /
`omarchy.bluetooth` / `omarchy.network`, and sibling plugins `t480.agents`,
`t480.control-station`, `green-room`) — all of them set this and none of
them have ever hit this bug. Also deleted the unused `hostWidget` property
and its dead guard in `persistSettings()`: it was inert scaffolding toward
the upstream docs' `Loader`-based `BarWidget.qml` + `Panel.qml` split
pattern (where `hostWidget` gets wired via `injectPanel()`), which this
plugin doesn't use — it's a single-file `Panel` like every sibling above,
where `owner: root` alone is complete and correct.

If a similar "works once, dead after" symptom ever shows up on
`Overlay.qml` or a future panel, check for a raw property assignment
happening on a bound property first — enable Qt's own diagnostic for it:
`quickshell --log-rules "qt.qml.binding.removal=true"`.

## Testing scaffold (for future work)

- `/tmp/opencode/modtest.py` — synthetic keyboard sequence (5 s hold, tap,
  chord, double-modifier) via `UInput`; run as root.
- Sampling loop: poll `omarchy-shell justarieldotcom.hotkey-hints state` every ~50 ms to
  timestamp open/close transitions.
## De-rooting: from a root systemd service to a shell-owned co-process (2026-09-19)

The watcher originally ran as a **root** systemd service
(`omarchy-hotkey-hints-watcher.service`) that pushed events into the plugin by
spawning `omarchy-shell -q <id> press SUPER` once per key transition. That
worked on the machine it was built on and nowhere else:

- the unit's `ExecStart` was an absolute `/home/<user>/...` path, hand-edited
  per install;
- it needed `sudo` to install, `sudo` to remove, and left a root service behind
  if you deleted the plugin folder;
- running as root, it had to *reconstruct* the user's session to reach the IPC
  (`HOME`, `XDG_RUNTIME_DIR`, a hardcoded `uid = 1000` fallback);
- it spawned a whole process per keypress.

All four problems have the same root cause: the watcher was a peer of the
shell rather than a child of it. Making it a child fixes them at once.

`Overlay.qml` now launches the helper itself and reads its stdout:

```qml
Process {
  command: ["setpriv", "--pdeathsig", "TERM", "python3", "-u",
            root.watcherScript, bindingsFile.path]
  stdout: SplitParser { onRead: function(line) { root.handleWatcherLine(line) } }
  onExited: { /* exponential backoff restart, unless watcherBlocked */ }
}
```

This is not a novel shape — it is exactly how the built-in clipboard plugin
supervises `wl-paste --watch`
(`$OMARCHY_PATH/shell/plugins/clipboard/Clipboard.qml`), including the
`setpriv --pdeathsig TERM` guard. Consequences:

- **No root.** Reading `/dev/input/event*` (`root:input`, mode 0660) needs
  group `input` and nothing else. Verified empirically: as uid 1000 with only
  supplementary group `input`, all 17 event devices open and the keyboard is
  detected.
- **No path to configure.** The helper's path is derived as
  `$HOME/.config/omarchy/plugins/<plugin id>/hotkey-watcher.py`, the same
  construction `PluginRegistry.qml` uses to discover the plugin in the first
  place. Deliberately *not* `Qt.resolvedUrl()` → filesystem path: `Util.fileUrl()`
  percent-encodes each segment and the shell ships no inverse helper, so that
  round trip would be unprecedented string surgery that breaks on non-ASCII
  usernames.
- **No install or removal steps.** `omarchy plugin add` / `omarchy plugin
  remove`, and `--pdeathsig TERM` means removal cannot leave a process behind.
- **No per-keypress process spawn.** One long-lived pipe instead.
- **The helper knows nothing about the session.** No `HOME`, no
  `XDG_RUNTIME_DIR`, no uid guess, no `subprocess` import. It takes the
  allowlist path in `argv[1]` and writes lines to stdout. `python3 -u` gives
  line buffering without touching the child's environment (nothing in the shell
  sets `Process.environment`, so its merge-vs-replace semantics are unverified).

### Wire protocol

```
ready                once at startup, after at least one keyboard is open
press <MOD>          SUPER | ALT | CTRL | SHIFT
release <MOD>
used <MODS>:<KEY>    only for an identity matched against the allowlist
error <code>         no-input-access | no-keyboard | missing-evdev, then exit 1
```

Every line is matched against an anchored regex in `handleWatcherLine()` before
anything acts on it. The helper is the one component that sees raw key data, so
its output is parsed strictly rather than trusted; an unrecognised line is
dropped without reaching `press()`/`bumpUsage()`.

### Why the error lines exist

Group membership only takes effect in a **new login session**, so the common
first-run failure is "installed everything, still nothing happens". The helper
now reports *why* it gave up and the overlay stops retrying (`watcherBlocked`)
rather than respawning a doomed process on a timer; `Widget.qml` surfaces the
reason in the settings popup with a **Retry watcher** button. `status()` over
IPC exposes the same state for scripting.

Once at least one keyboard is open the helper prints `ready`, which flips the
status to `running`. Before that line existed, the status stayed `starting`
until the first modifier press, so a healthy watcher looked stuck after every
shell restart. `ready` deliberately doesn't reset the restart back-off; only
real `press`/`used` traffic does, so a helper that crashes right after `ready`
still backs off instead of respawning in a tight loop.

### Bugs found and fixed while doing this

- **Closing an `InputDevice` sets its `.fd` to `-1`.** The old loop dropped a
  dead device by filtering `d.fd != fd` *after* calling `close()`, so the
  comparison was against `-1` and the device stayed in the dict. The next
  `select()` got a `-1` and raised `ValueError` — which is not an `OSError`, so
  the loop's `except OSError` didn't catch it and the watcher died. Under
  `Restart=always` this was invisible; as a co-process it would have been a
  restart loop. Devices are now dropped by **path** (`forget_device`), and the
  fd map skips any already-closed device. Reproduced and fixed with a synthetic
  uinput keyboard — see the test scaffold below.
- **Media-key binds were never counted.** `KEY_NAMES` held mixed-case XF86
  names (`"XF86AudioMute"`) while the allowlist is written by
  `Model.usageIdentity()`, which upper-cases. So `SUPER:XF86AudioMute` was
  compared against `SUPER:XF86AUDIOMUTE` and never matched. `KEY_NAMES` is now
  upper-cased once at import.
- **A keyboard vanishing mid-hold left modifiers stuck down** in the watcher's
  `down` set, and the overlay stuck open until the 8 s guard. `forget_device()`
  now emits `release` for anything still held when the last device goes away.
- **The overlay could open on the wrong output.** `PanelWindow` set no
  `screen`, so `seedPosition()`/`clampPos()` could also measure the wrong
  output's geometry. It now resolves `Hyprland.focusedMonitor`'s name against
  `Quickshell.screens` (the shell's own indirection, `focusedScreenName()` in
  `plugins/bar/Bar.qml`) and assigns `panel.screen` inside
  `revealTimer.onTriggered` **before** flipping `opened` — so the screen is only
  ever set while the surface is unmapped. Nothing in this shell reassigns
  `.screen` on a visible window and whether wlr-layer-shell honours that is
  unverified, so this sidesteps the question rather than betting on it.
- **`~/.local/state/omarchy/` may not exist on a fresh machine** and `FileView`
  does not create parent directories. An `ensureStateDirProc` (`mkdir -p`) now
  runs first, following `plugins/notifications/Service.qml`'s best-effort
  pattern; `XDG_STATE_HOME` is honoured with a `$HOME/.local/state` fallback.

### Testing scaffold

`synth_keyboard.py` + `test_watcher.sh` (kept out of the repo; regenerate as
needed) drive the watcher through a synthetic `uinput` keyboard while it runs
**unprivileged** — `setpriv --reuid=1000 --regid=1000 --groups=1000,<input gid>`
— and assert the exact expected event stream. The assertions that matter most
are the negative ones:

- an unbound combo (`SUPER+A`) produces **no** `used` line;
- typing `Hi` with Shift held produces **no** `used` line;
- a held `SUPER+K` autorepeating produces **exactly one** `used` line;
- the watcher survives its keyboard being removed.
