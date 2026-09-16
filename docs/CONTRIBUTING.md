# Contributing

`io.github.mikus2604.hotkey-hints` is an Omarchy shell (Quickshell/QML) plugin.
Read `README.md` and `DEVNOTES.md` before non-trivial changes.

## Architecture

- **`Overlay.qml`** (`kind: panel`, `keepLoaded: true`) — IPC in
  (`press` / `release` / `dismiss` / `state` / `ping`), never reads
  `/dev/input`. `FileView` is watcher-only (`preload: false`,
  `blockAllReads: true`); reads and writes go through
  `scripts/state-file.py`.
- **`hotkey-watcher.py`** — copied by `scripts/install.sh` to
  `/usr/local/libexec/omarchy-hotkey-hints/` (root-owned). Starts as root to
  open `/dev/input`, then `seteuid` to `--uid`. Default: eight modifier
  keycodes only. Non-modifier keys are inspected only when
  `watch.json` has `rememberUsage: true`, and only a known-binding match
  is written to `usage.json`.
- **`Widget.qml`** — settings popup (the only way third-party plugins get
  persisted settings).
- **`Model.js`** — parsing / progressive disclosure. No QML imports.
  `bash scripts/selfcheck.sh`.

Do not add `used` / `resetUsage` IPC methods. Usage is a file the watcher
writes and the overlay watches.

Do not point systemd `ExecStart` at the plugin checkout.

## After editing Overlay.qml

`omarchy restart shell` — local-plugin hot reload does not reliably
reinitialize a panel component.
