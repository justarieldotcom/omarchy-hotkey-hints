#!/usr/bin/env python3
# Watches the physical modifier keys via evdev and mirrors every press/release
# into the t480.hotkey-hints plugin IPC. Hyprland's bindr release binds for bare
# modifier keys never fire (libinput-based compositors lose the held-key state),
# so the shell watches the kernel instead of trusting the session. Run as root
# (systemd service) since /dev/input is root-readable. Only reads devices, never
# grabs, so it steals no input. Keycodes below are raw evdev codes (pre-xkb);
# the standard modifier keys map 1:1 regardless of keyboard layout.
import glob
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

OMARCHY_PATH = "/usr/share/omarchy"
SCAN_INTERVAL = 2

down = set()
devices = {}
stopping = False


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


def tell(mod, kind):
    subprocess.run(["omarchy-shell", "-q", "t480.hotkey-hints", kind, mod],
                   env=session_env())


def on_key(code, pressed):
    mod = MODS.get(code)
    if not mod:
        return
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
            on_key(code, True)


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
                                on_key(ev.code, bool(ev.value))
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