#!/usr/bin/env python3
# Watches the physical modifier keys via evdev and mirrors every press/release
# into the t480.hotkey-hints plugin IPC. Hyprland's bindr release binds for bare
# modifier keys never fire (libinput-based compositors lose the held-key state),
# so the shell watches the kernel instead of trusting the session. Run as root
# (systemd service) since /dev/input is root-readable. Only reads devices, never
# grabs, so it steals no input. Keycodes below are raw evdev codes (pre-xkb);
# the standard modifier keys map 1:1 regardless of keyboard layout.
#
# Usage tracking (opt-in, see the plugin's `rememberUsage` setting): this also
# watches for a non-modifier key going down while a modifier is held, i.e. a
# completed hotkey combo. It is matched in-process against KNOWN_BINDINGS
# (loaded from bindings_path, written by Overlay.qml from the live keybindings
# list) BEFORE anything is reported — an unmatched key (ordinary typing, an
# app's own Ctrl+C, an unbound combo) never leaves this process: no IPC call,
# no log line, nothing written anywhere. Only a keypress that matches an
# actual, currently-bound hotkey ever results in a `used` IPC call, and even
# then only the mods+key identity is sent — never timing, never content.
import glob
import json
import os
import pwd
import select
import signal
import subprocess
import sys
import time

import evdev
from evdev import ecodes

# Canonical modifier per physical evdev keycode. emit release only when both
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
# KNOWN_BINDINGS once mapped) is simply never reported — best-effort by
# design, matching this watcher's existing minimal/read-only philosophy.
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

OMARCHY_PATH = "/usr/share/omarchy"
SCAN_INTERVAL = 2

down = set()
devices = {}
stopping = False
known_bindings = set()
bindings_mtime = None


def session_env():
    uid = 1000
    for sock in sorted(glob.glob("/run/user/*/wayland-[0-9]*")):
        if sock.endswith(".lock"):
            continue
        uid = int(sock.split("/")[3])
        break
    return {
        "HOME": pwd.getpwuid(uid).pw_dir,
        "XDG_RUNTIME_DIR": f"/run/user/{uid}",
        "OMARCHY_PATH": OMARCHY_PATH,
        "PATH": "/usr/bin:/bin",
    }


def bindings_path():
    return os.path.join(session_env()["HOME"], ".local/state/omarchy/hotkey-hints-bindings.json")


def load_bindings():
    # Re-stat (cheap) on every non-modifier keydown rather than on a timer, so
    # a just-refreshed keybindings list takes effect on the very next press.
    global known_bindings, bindings_mtime
    try:
        mtime = os.stat(bindings_path()).st_mtime
    except OSError:
        known_bindings = set()
        bindings_mtime = None
        return
    if mtime == bindings_mtime:
        return
    try:
        with open(bindings_path()) as f:
            data = json.load(f)
        known_bindings = set(data) if isinstance(data, list) else set()
        bindings_mtime = mtime
    except (OSError, ValueError):
        known_bindings = set()
        bindings_mtime = None


def tell(value, kind):
    subprocess.run(["omarchy-shell", "-q", "t480.hotkey-hints", kind, value],
                   env=session_env())


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
            tell(mod, "press")
        else:
            if code not in down:
                return
            down.discard(code)
            if any(c in down for c, m in MODS.items() if m == mod and c != code):
                return
            tell(mod, "release")
        return

    # Usage tracking: a non-modifier key going down while >=1 modifier is
    # held is a completed hotkey combo. Only report it if it matches a known,
    # currently-bound combo (see load_bindings) — anything else (ordinary
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
        tell(identity, "used")


def is_keyboard(dev):
    caps = dev.capabilities()
    return ecodes.EV_KEY in caps and ecodes.KEY_A in caps.get(ecodes.EV_KEY, [])


def open_devices():
    for path in glob.glob("/dev/input/event*"):
        if path in devices:
            continue
        try:
            dev = evdev.InputDevice(path)
            if not is_keyboard(dev):
                dev.close()
                continue
        except OSError:
            continue
        devices[path] = dev
        for code in dev.active_keys():
            on_key(code, 1)


def drop_devices():
    for path, dev in list(devices.items()):
        try:
            if not glob.glob(path):
                dev.close()
                del devices[path]
        except OSError:
            dev.close()
            del devices[path]


def on_signal(sig, frame):
    global stopping
    stopping = True


signal.signal(signal.SIGTERM, on_signal)
signal.signal(signal.SIGINT, on_signal)

open_devices()
last_scan = time.monotonic()
while not stopping:
    try:
        fds = [dev.fd for dev in devices.values()]
        r, _, _ = select.select(fds, [], [], SCAN_INTERVAL)
        for fd in r:
            for dev in devices.values():
                if dev.fd == fd:
                    try:
                        for ev in dev.read():
                            if ev.type == ecodes.EV_KEY:
                                on_key(ev.code, ev.value)
                    except OSError:
                        dev.close()
                        devices = {p: d for p, d in devices.items() if d.fd != fd}
                    break
    except OSError:
        pass
    if time.monotonic() - last_scan > SCAN_INTERVAL:
        open_devices()
        drop_devices()
        last_scan = time.monotonic()