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
  - press: `omarchy-shell -q t480.hotkey-hints press <MOD>` with
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
`python-evdev` (root service) and mirrors every modifier transition into the
plugin's existing IPC:

- Tracks the 8 evdev modifier keycodes (KEY_LEFTMETA/RIGHTMETA/LEFTCTRL/
  RIGHTCTRL/LEFTALT/RIGHTALT/LEFTSHIFT/RIGHTSHIFT).
- Canonicalizes modifiers: `Super_L` or `Super_R` → `SUPER`, etc.
- Emits exactly one `press` IPC on the first key-down of a canonical modifier
  and one `release` IPC when the **last** of its two keys goes up — so
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

The risk with the chosen option is obvious: a root service reading
*all* keys, not just modifiers, is a meaningfully bigger privilege surface —
in the worst case, a keylogger. The mitigation is a strict match-before-report
split:
- `Overlay.qml` writes every known binding (from the same
  `omarchy menu keybindings --print` parse used for the hints themselves) to
  `~/.local/state/omarchy/hotkey-hints-bindings.json` as a flat list of
  `Model.usageIdentity()` strings.
- The watcher loads that file (poll-on-keydown, mtime-checked, same
  no-inotify style as the rest of the file) into an in-memory set.
- A non-modifier keydown while a modifier is held is looked up in that set
  **before** anything happens. No match → nothing happens: no subprocess, no
  IPC call, no write, no log line. Only a match spawns
  `omarchy-shell -q t480.hotkey-hints used <identity>` — the exact same
  `subprocess.run` shape the existing press/release calls already use, so it
  doesn't change the watcher's process-spawn profile in kind, only rate (and
  only for real hotkey presses, which are inherently infrequent).
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

- `Overlay.qml` — the overlay (panel plugin). Only reacts to IPC calls
  (`press`, `release`, `dismiss`, `state`, `ping`); never reads the keyboard.
  `revealDelayMs: 280` debounces fast modifier taps; `stuckCloseMs: 8000` is
  now pure insurance.
- `hotkey-watcher.py` — the evdev watcher described above.
- `omarchy-hotkey-hints-watcher.service` — install unit for the watcher
  (adjust the `ExecStart` path for your setup).
- `Model.js` — keybinding parsing + progressive disclosure (`selfCheck()`).
- `Widget.qml` — bar-widget used only to expose the settings popup.
- `manifest.json` — plugin metadata / settings schema.

## Installing

```sh
# 1. Put the plugin at ~/.config/omarchy/plugins/t480.hotkey-hints
# 2. Install the watcher as a root service
sudo tee /etc/systemd/system/omarchy-hotkey-hints-watcher.service \
  < omarchy-hotkey-hints-watcher.service
sudo systemctl daemon-reload
sudo systemctl enable --now omarchy-hotkey-hints-watcher
# 3. Add the service's ExecStart path to hotkey-watcher.py's real location
#    (edit the unit so ExecStart points at your copy under ~/.config/...)
# 4. Remove any old per-modifier binds for this plugin from your Hyprland
#    keybindings — the watcher owns modifier press/release now.
# 5. Restart the shell: omarchy restart shell
```

Requirements: `python-evdev` (system package), and root for `/dev/input`.

## Operational notes / gotchas

- The service runs as root; root must reach the user's shell IPC. The watcher
  reconstructs `HOME`, `XDG_RUNTIME_DIR`, `OMARCHY_PATH` (and omarchy-shell
  auto-detects the compositor socket) — tested working.
- `sudo killall python3`-style cleanup patterns can match the watcher's own
  command line — use `systemctl restart omarchy-hotkey-hints-watcher`.
- The shell hot-reload ("Local plugin changed, reloading") does **not**
  reliably reinitialize the panel component — restart the shell after editing
  `Overlay.qml`.
- `hotkey-watcher.py` deliberately does not use libinput's grab: reading
  without grabbing is enough and models the keyboard-compositor split per
  Omarchy's layering.

## Testing scaffold (for future work)

- `/tmp/opencode/modtest.py` — synthetic keyboard sequence (5 s hold, tap,
  chord, double-modifier) via `UInput`; run as root.
- Sampling loop: poll `omarchy-shell t480.hotkey-hints state` every ~50 ms to
  timestamp open/close transitions.