#!/usr/bin/env python3
# Reads the physical modifier keys via evdev and reports every press/release
# transition on stdout, one event per line. The plugin's Overlay.qml launches
# this helper as a child process and reads those lines; nothing here knows
# about the shell, the session, or any path but the one handed to it in argv.
#
# Why read the kernel at all: Hyprland's `bindr` release binds for bare
# modifier keys never fire (libinput-based compositors lose the held-key
# state), so the overlay would never learn that a modifier came back up. See
# docs/DEVNOTES.md for the full investigation.
#
# Privileges: runs as the ordinary desktop user. Reading /dev/input needs
# membership in the `input` group and nothing more -- no root, no capabilities,
# no setuid. Devices are only ever opened for reading, never grabbed, so this
# steals no input from anyone.
#
# Wire protocol (stdout, one line each, line-buffered):
#   press <MOD>              a canonical modifier went down   (SUPER|ALT|CTRL|SHIFT)
#   release <MOD>            its last physical key came up
#   used <MODS>:<KEY>        a completed, *known* hotkey combo was pressed
#   error <code>             fatal startup problem; the process then exits 1
#
# Usage tracking (opt-in, the plugin's `rememberUsage` setting): this also
# watches for a non-modifier key going down while a modifier is held, i.e. a
# completed hotkey combo. It is matched in-process against KNOWN_BINDINGS
# (loaded from the allowlist path in argv[1], written by Overlay.qml from the
# live keybindings list) BEFORE anything is reported -- an unmatched key
# (ordinary typing, an app's own Ctrl+C, an unbound combo) never leaves this
# process: nothing printed, nothing logged, nothing written anywhere. Only a
# keypress matching an actual, currently-bound hotkey is ever reported, and
# even then only the mods+key identity -- never timing, never window context,
# never content. That match-before-report split is the whole reason a helper
# that reads regular keys is not a keylogger; do not add a "report everything,
# filter later" path, even temporarily for debugging.
import glob
import json
import os
import re
import select
import signal
import sys
import time

try:
    import evdev
    from evdev import ecodes
except ImportError:
    print("error missing-evdev", flush=True)
    sys.exit(1)

# Canonical modifier per physical evdev keycode. Emit release only when both
# sides of a modifier are up, so Super_L held + Super_R tapped resolves right.
MODS = {
    ecodes.KEY_LEFTMETA: "SUPER",
    ecodes.KEY_RIGHTMETA: "SUPER",
    ecodes.KEY_LEFTCTRL: "CTRL",
    ecodes.KEY_RIGHTCTRL: "CTRL",
    ecodes.KEY_LEFTALT: "ALT",
    ecodes.KEY_RIGHTALT: "ALT",
    ecodes.KEY_LEFTSHIFT: "SHIFT",
    ecodes.KEY_RIGHTSHIFT: "SHIFT",
}

# Non-modifier evdev keycode -> the key-name string `omarchy menu keybindings
# --print` uses for it (verified against a live keybindings dump). Letters and
# digits are handled generically below (evdev's own "KEY_X" name already
# matches); everything here is a case where the two names diverge, plus the
# common XF86 media keys. A key that isn't in this table (or isn't in
# KNOWN_BINDINGS once mapped) is simply never reported -- best-effort by
# design, matching this helper's minimal/read-only philosophy.
KEY_NAMES = {
    ecodes.KEY_ENTER: "RETURN",
    ecodes.KEY_KPENTER: "RETURN",
    ecodes.KEY_ESC: "ESCAPE",
    ecodes.KEY_LEFTBRACE: "BRACKETLEFT",
    ecodes.KEY_RIGHTBRACE: "BRACKETRIGHT",
    ecodes.KEY_DOT: "PERIOD",
    ecodes.KEY_SYSRQ: "PRINT",
    ecodes.KEY_MUTE: "XF86AudioMute",
    ecodes.KEY_VOLUMEDOWN: "XF86AudioLowerVolume",
    ecodes.KEY_VOLUMEUP: "XF86AudioRaiseVolume",
    ecodes.KEY_PLAYPAUSE: "XF86AudioPlay",
    ecodes.KEY_NEXTSONG: "XF86AudioNext",
    ecodes.KEY_PREVIOUSSONG: "XF86AudioPrev",
    ecodes.KEY_MICMUTE: "XF86AudioMicMute",
    ecodes.KEY_EJECTCD: "XF86Eject",
    ecodes.KEY_CALC: "XF86Calculator",
    ecodes.KEY_POWER: "XF86PowerOff",
    ecodes.KEY_BRIGHTNESSDOWN: "XF86MonBrightnessDown",
    ecodes.KEY_BRIGHTNESSUP: "XF86MonBrightnessUp",
    ecodes.KEY_KBDILLUMDOWN: "XF86KbdBrightnessDown",
    ecodes.KEY_KBDILLUMUP: "XF86KbdBrightnessUp",
    ecodes.KEY_KBDILLUMTOGGLE: "XF86KbdLightOnOff",
}
# Plain letters/digits/F-keys: evdev's own name (minus the "KEY_" prefix)
# already matches (KEY_K -> "K", KEY_9 -> "9", KEY_F9 -> "F9").
for _code, _name in ecodes.keys.items():
    if _code in KEY_NAMES or _code in MODS:
        continue
    _names = _name if isinstance(_name, (list, tuple)) else [_name]
    for _n in _names:
        if _n.startswith("KEY_") and _n[4:].isalnum():
            KEY_NAMES[_code] = _n[4:]
            break
# Upper-case every mapped name once, here. The allowlist Overlay.qml writes is
# built by Model.usageIdentity(), which upper-cases both sides because
# `omarchy menu keybindings --print` is inconsistent about key-name casing
# ("Delete" vs "DELETE"). Without this the mixed-case XF86 entries above could
# never match, so media-key binds would silently never be counted.
KEY_NAMES = {_c: _n.upper() for _c, _n in KEY_NAMES.items()}

# Shape of one allowlist entry, e.g. "CTRL+SUPER:V". Entries that don't match
# are dropped on load: the allowlist is the only thing standing between this
# helper and ordinary keystrokes, so it is parsed strictly rather than trusted.
IDENTITY_RE = re.compile(r"^[A-Z]+(?:\+[A-Z]+)*:[A-Z0-9_ ]+$")

SCAN_INTERVAL = 2

down = set()
devices = {}
stopping = False
known_bindings = set()
bindings_mtime = None


def default_bindings_path():
    state_home = os.environ.get("XDG_STATE_HOME") or os.path.join(
        os.path.expanduser("~"), ".local/state")
    return os.path.join(state_home, "omarchy/hotkey-hints-bindings.json")


BINDINGS_PATH = sys.argv[1] if len(sys.argv) > 1 else default_bindings_path()


def load_bindings():
    # Re-stat (cheap) on every non-modifier keydown rather than on a timer, so
    # a just-refreshed keybindings list takes effect on the very next press.
    global known_bindings, bindings_mtime
    try:
        mtime = os.stat(BINDINGS_PATH).st_mtime
    except OSError:
        known_bindings = set()
        bindings_mtime = None
        return
    if mtime == bindings_mtime:
        return
    try:
        with open(BINDINGS_PATH) as f:
            data = json.load(f)
        known_bindings = {
            entry for entry in data
            if isinstance(entry, str) and IDENTITY_RE.match(entry)
        } if isinstance(data, list) else set()
        bindings_mtime = mtime
    except (OSError, ValueError):
        known_bindings = set()
        bindings_mtime = None


def tell(line):
    # A dead parent (shell restarted, plugin disabled) closes our stdout. That
    # is a normal end of life, not an error -- exit quietly.
    try:
        print(line, flush=True)
    except (BrokenPipeError, OSError):
        global stopping
        stopping = True


def on_key(code, value):
    if value == 2:  # autorepeat: irrelevant to both modifier tracking and
        return       # usage tracking (would otherwise spam `used` on a hold)
    pressed = value == 1

    mod = MODS.get(code)
    if mod:
        if pressed:
            if code in down:
                return
            down.add(code)
            if any(c in down for c, m in MODS.items() if m == mod and c != code):
                return
            tell("press " + mod)
        else:
            if code not in down:
                return
            down.discard(code)
            if any(c in down for c, m in MODS.items() if m == mod and c != code):
                return
            tell("release " + mod)
        return

    # Usage tracking: a non-modifier key going down while >=1 modifier is
    # held is a completed hotkey combo. Only report it if it matches a known,
    # currently-bound combo (see load_bindings) -- anything else (ordinary
    # typing, an app's own shortcut, an unbound combo) is dropped right here.
    if not pressed:
        return
    held_mods = sorted({MODS[c] for c in down})
    if not held_mods:
        return
    key_name = KEY_NAMES.get(code)
    if not key_name:
        return
    load_bindings()
    identity = "+".join(held_mods) + ":" + key_name
    if identity in known_bindings:
        tell("used " + identity)


def is_keyboard(dev):
    caps = dev.capabilities()
    return ecodes.EV_KEY in caps and ecodes.KEY_A in caps.get(ecodes.EV_KEY, [])


def open_devices():
    # Returns (opened, denied): how many new keyboards were opened, and how
    # many paths we were not allowed to read. The caller uses those counts
    # once, at startup, to report a precise reason for giving up.
    opened = denied = 0
    for path in glob.glob("/dev/input/event*"):
        if path in devices:
            continue
        try:
            dev = evdev.InputDevice(path)
        except PermissionError:
            denied += 1
            continue
        except OSError:
            continue
        try:
            if not is_keyboard(dev):
                dev.close()
                continue
        except OSError:
            dev.close()
            continue
        devices[path] = dev
        opened += 1
        for code in dev.active_keys():
            on_key(code, 1)
    return opened, denied


def forget_device(path):
    # Remove by PATH, never by fd: closing an InputDevice sets its .fd to -1,
    # so a filter like `d.fd != fd` would keep the very device it meant to drop
    # and then hand select() a -1, which raises ValueError and kills the loop.
    dev = devices.pop(path, None)
    if dev is None:
        return
    try:
        dev.close()
    except OSError:
        pass
    # A keyboard vanishing mid-hold (unplugged, or a Bluetooth link dropping)
    # would otherwise leave its modifiers stuck down here forever, and the
    # overlay stuck open with them. Report them up so the plugin can close.
    if not devices and down:
        for mod in sorted({MODS[c] for c in down}):
            tell("release " + mod)
        down.clear()


def drop_devices():
    for path, dev in list(devices.items()):
        gone = dev.fd < 0
        if not gone:
            try:
                gone = not glob.glob(path)
            except OSError:
                gone = True
        if gone:
            forget_device(path)


def on_signal(sig, frame):
    global stopping
    stopping = True


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)

opened, denied = open_devices()
if not opened:
    # Nothing to watch, and nothing that waiting will fix: report why and stop
    # so the plugin can tell the user instead of silently doing nothing.
    tell("error no-input-access" if denied else "error no-keyboard")
    sys.exit(1)

last_scan = time.monotonic()
while not stopping:
    # Build the fd -> (path, device) map fresh each pass, skipping any device
    # that has already been closed (fd == -1). An unplugged keyboard is the
    # normal way to get one of those, and handing select() a -1 raises
    # ValueError, which would otherwise take the whole watcher down.
    watching = {dev.fd: (path, dev) for path, dev in devices.items() if dev.fd >= 0}
    if not watching:
        # No keyboard right now (all unplugged). Idle until the rescan below
        # finds one again rather than spinning on an empty select().
        time.sleep(0.2)
    else:
        try:
            readable, _, _ = select.select(list(watching), [], [], SCAN_INTERVAL)
        except (OSError, ValueError):
            readable = []
        for fd in readable:
            path, dev = watching[fd]
            try:
                for ev in dev.read():
                    if ev.type == ecodes.EV_KEY:
                        on_key(ev.code, ev.value)
            except OSError:
                # Device went away mid-read. Drop it by path (see
                # forget_device) so it can't come back as a -1 fd.
                forget_device(path)
    if time.monotonic() - last_scan > SCAN_INTERVAL:
        open_devices()
        drop_devices()
        last_scan = time.monotonic()
