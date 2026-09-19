# Contributing to Hotkey Hints

Thanks for wanting to make this better! This guide gets you from fork to
working PR, and explains the handful of design rules that aren't negotiable.

## Dev setup

Omarchy loads a plugin from `~/.config/omarchy/plugins/<id>/`, and a plugin's
folder *is* its git checkout. So developing means swapping the installed copy
for your fork:

```sh
# 1. prerequisites (see README → Install): python-evdev, and the input group

# 2. replace any installed copy with your fork
omarchy plugin remove justarieldotcom.hotkey-hints --yes
git clone https://github.com/<you>/omarchy-hotkey-hints \
  ~/.config/omarchy/plugins/justarieldotcom.hotkey-hints
omarchy plugin enable justarieldotcom.hotkey-hints

# 3. after editing Overlay.qml, restart the shell. Hot reload doesn't reliably
#    reinitialize a panel component
omarchy restart shell
```

If you're forking to publish your *own* variant, give it an id under your own
name: rename the folder, then change `id` in `manifest.json` and every
`justarieldotcom.hotkey-hints` in the QML (`grep -rn justarieldotcom.hotkey-hints`).
Marketplace ids are permanent and can't collide.

## How the pieces fit

| File | Job |
|---|---|
| `Model.js` | Pure logic: parsing keybindings, progressive disclosure, usage identities. No QML imports. |
| `Overlay.qml` | The card. Supervises the watcher, validates its output, draws the hints, answers IPC. |
| `hotkey-watcher.py` | Reads physical key transitions from `/dev/input`. Prints `ready`, `press/release <MOD>`, `used <identity>`, `error <code>`. |
| `Widget.qml` | Bar icon that hosts the Settings popup and watcher health. |

[`docs/DEVNOTES.md`](docs/DEVNOTES.md) has the full design history. Read it
before non-trivial changes, especially if you're touching release detection.

## Testing your change

There's no build step. Run whichever of these your change touches:

```sh
# Model.js: assert-based self check (add your assertions to selfCheck())
node -e "eval(require('fs').readFileSync('Model.js','utf8').replace('.pragma library','')); console.log(selfCheck())"

# watcher: syntax, then run it and expect "ready" first
python3 -m py_compile hotkey-watcher.py
timeout 2 python3 -u hotkey-watcher.py ~/.local/state/omarchy/hotkey-hints-bindings.json

# QML: expect some noise about qs.Commons / qs.Ui; compare against main, not zero
qmllint -I "$OMARCHY_PATH/shell" Overlay.qml Widget.qml   # or /usr/lib/qt6/bin/qmllint

# manifest
omarchy plugin validate .

# live: drive the overlay over IPC (-q must come BEFORE the target)
omarchy-shell justarieldotcom.hotkey-hints status        # -> running
omarchy-shell -q justarieldotcom.hotkey-hints press SUPER
omarchy-shell justarieldotcom.hotkey-hints state         # -> open (after ~280 ms)
omarchy-shell justarieldotcom.hotkey-hints dismiss
```

**Adding a setting** touches three files in lockstep: `manifest.json` (default
*and* schema entry), `Widget.qml` (property, control, `save()`, reset) and
`Overlay.qml` (a `readonly property` parsed defensively from `rawSettings`).
Settings round-trip as strings, so parse them back with a range check.

## Rules that keep this plugin trustworthy

This plugin reads the keyboard, so these aren't style preferences. PRs that
break them won't be merged:

1. **Match before report.** The watcher only ever prints a non-modifier key if
   it matches one of the user's own bindings. No "log everything and filter
   later" path, not even temporarily for debugging.
2. **Validate every watcher line** with an anchored regex in
   `handleWatcherLine()` before acting on it. That function is the trust
   boundary.
3. **No privilege in code.** No `sudo`, `pkexec`, systemd units, package
   installs or install scripts in shipped source. The watcher runs as the
   user, as a child of the shell, under `setpriv --pdeathsig TERM`.
4. **No network, ever.**
5. **The card never takes keyboard focus** (`WlrKeyboardFocus.None`).

## Pull requests

- Keep PRs focused, one idea per PR.
- Say how you tested it (which of the commands above, and on what setup).
- Screenshots or a GIF for anything visual are hugely appreciated.
- Update `README.md` if you change user-facing behavior or settings.

## Ideas

The README has a list of [ideas](README.md#contributing). Pick one, open an
issue to say you're on it, and go. Something else in mind? Open an issue and
let's talk.
