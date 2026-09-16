#!/usr/bin/python3 -I
# Root-owned helper (installed to /usr/local/libexec/omarchy-hotkey-hints/).
# Opens /dev/input as root, then seteuid(--uid) for IPC and state I/O.
# Default: modifier keys only. Non-modifier keydowns are inspected only when
# the user has opted into rememberUsage via watch.json.
import argparse
import glob
import json
import os
import pwd
import select
import signal
import stat
import subprocess
import sys
import time

import evdev
from evdev import ecodes

PLUGIN_ID = "io.github.mikus2604.hotkey-hints"
OMARCHY_PATH = "/usr/share/omarchy"
SCAN_INTERVAL = 2
MAX_BINDINGS = 4096
MAX_BIND_LEN = 96
MAX_STATE_BYTES = 65536
TELL_TIMEOUT = 5

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

KEY_NAMES = {
    ecodes.KEY_ENTER: "RETURN",
    ecodes.KEY_KPENTER: "RETURN",
    ecodes.KEY_ESC: "ESCAPE",
    ecodes.KEY_LEFTBRACE: "BRACKETLEFT",
    ecodes.KEY_RIGHTBRACE: "BRACKETRIGHT",
    ecodes.KEY_DOT: "PERIOD",
    ecodes.KEY_SYSRQ: "PRINT",
    ecodes.KEY_MUTE: "XF86AUDIOMUTE",
    ecodes.KEY_VOLUMEDOWN: "XF86AUDIOLOWERVOLUME",
    ecodes.KEY_VOLUMEUP: "XF86AUDIORAISEVOLUME",
    ecodes.KEY_PLAYPAUSE: "XF86AUDIOPLAY",
    ecodes.KEY_NEXTSONG: "XF86AUDIONEXT",
    ecodes.KEY_PREVIOUSSONG: "XF86AUDIOPREV",
    ecodes.KEY_MICMUTE: "XF86AUDIOMICMUTE",
    ecodes.KEY_EJECTCD: "XF86EJECT",
    ecodes.KEY_CALC: "XF86CALCULATOR",
    ecodes.KEY_POWER: "XF86POWEROFF",
    ecodes.KEY_BRIGHTNESSDOWN: "XF86MONBRIGHTNESSDOWN",
    ecodes.KEY_BRIGHTNESSUP: "XF86MONBRIGHTNESSUP",
    ecodes.KEY_KBDILLUMDOWN: "XF86KBDBRIGHTNESSDOWN",
    ecodes.KEY_KBDILLUMUP: "XF86KBDBRIGHTNESSUP",
    ecodes.KEY_KBDILLUMTOGGLE: "XF86KBDLIGHTONOFF",
}
for _code, _name in ecodes.keys.items():
    if _code in KEY_NAMES or _code in MODS:
        continue
    _names = _name if isinstance(_name, (list, tuple)) else [_name]
    for _n in _names:
        if _n.startswith("KEY_") and _n[4:].isalnum():
            KEY_NAMES[_code] = _n[4:].upper()
            break

down = set()
devices = {}
stopping = False
known_bindings = set()
bindings_mtime = None
remember_usage = False
watch_mtime = None
usage_mtime = None
usage_counts = {}
target_uid = 0
target_gid = 0
pw_home = ""


def session_env():
    return {
        "HOME": pw_home,
        "USER": pwd.getpwuid(target_uid).pw_name,
        "XDG_RUNTIME_DIR": "/run/user/%d" % target_uid,
        "OMARCHY_PATH": OMARCHY_PATH,
        "PATH": "/usr/bin:/bin",
        "LC_ALL": "C",
    }


def as_root(fn):
    os.seteuid(0)
    try:
        return fn()
    finally:
        os.seteuid(target_uid)


def state_dir():
    return os.path.join(pw_home, ".local", "state", "omarchy", "hotkey-hints")


def open_state_file(name):
    path = os.path.join(state_dir(), name)
    flags = os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC
    fd = os.open(path, flags)
    try:
        st = os.fstat(fd)
        if (not stat.S_ISREG(st.st_mode) or st.st_uid != target_uid
                or st.st_nlink != 1 or st.st_size > MAX_STATE_BYTES):
            os.close(fd)
            return None
        os.set_blocking(fd, True)
        return fd, st.st_mtime
    except BaseException:
        os.close(fd)
        raise


def read_fd(fd):
    data = b""
    while len(data) <= MAX_STATE_BYTES:
        chunk = os.read(fd, min(65536, MAX_STATE_BYTES + 1 - len(data)))
        if not chunk:
            break
        data += chunk
    if len(data) > MAX_STATE_BYTES:
        return None
    return data


def load_bindings():
    global known_bindings, bindings_mtime
    try:
        fd, mtime = open_state_file("bindings.json")
    except (TypeError, OSError):
        known_bindings = set()
        bindings_mtime = None
        return
    if mtime == bindings_mtime:
        os.close(fd)
        return
    try:
        raw = read_fd(fd)
        data = json.loads(raw.decode("utf-8", "strict")) if raw else []
        if not isinstance(data, list):
            raise ValueError("bindings")
        out = set()
        for item in data[:MAX_BINDINGS]:
            if isinstance(item, str) and 0 < len(item) <= MAX_BIND_LEN:
                out.add(item.upper())
        known_bindings = out
        bindings_mtime = mtime
    except (ValueError, OSError, UnicodeError):
        known_bindings = set()
        bindings_mtime = None
    finally:
        os.close(fd)


def load_watch():
    global remember_usage, watch_mtime
    try:
        fd, mtime = open_state_file("watch.json")
    except (TypeError, OSError):
        remember_usage = False
        watch_mtime = None
        return
    if mtime == watch_mtime:
        os.close(fd)
        return
    try:
        raw = read_fd(fd)
        data = json.loads(raw.decode("utf-8", "strict")) if raw else {}
        remember_usage = isinstance(data, dict) and data.get("rememberUsage") is True
        watch_mtime = mtime
    except (ValueError, OSError, UnicodeError):
        remember_usage = False
        watch_mtime = None
    finally:
        os.close(fd)


def load_usage():
    global usage_counts, usage_mtime
    try:
        fd, mtime = open_state_file("usage.json")
    except (TypeError, OSError):
        usage_counts = {}
        usage_mtime = None
        return
    if mtime == usage_mtime:
        os.close(fd)
        return
    try:
        raw = read_fd(fd)
        data = json.loads(raw.decode("utf-8", "strict")) if raw else {}
        out = {}
        if isinstance(data, dict):
            for key, value in list(data.items())[:512]:
                if not isinstance(key, str):
                    continue
                try:
                    n = int(value)
                except (TypeError, ValueError):
                    continue
                if 0 < n <= 1000000:
                    out[key] = n
        usage_counts = out
        usage_mtime = mtime
    except (ValueError, OSError, UnicodeError):
        usage_counts = {}
        usage_mtime = None
    finally:
        os.close(fd)


def write_usage():
    directory = state_dir()
    payload = json.dumps(usage_counts, separators=(",", ":")).encode("utf-8") + b"\n"
    if len(payload) > MAX_STATE_BYTES:
        return
    tmp_name = ".usage.%s.tmp" % os.urandom(8).hex()
    tmp_path = os.path.join(directory, tmp_name)
    dest = os.path.join(directory, "usage.json")
    flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC
    try:
        fd = os.open(tmp_path, flags, 0o600)
    except OSError:
        return
    try:
        os.fchmod(fd, 0o600)
        view = memoryview(payload)
        while view:
            n = os.write(fd, view)
            view = view[n:]
        os.fsync(fd)
        os.replace(tmp_path, dest)
    except OSError:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
    finally:
        os.close(fd)


def tell(kind, value):
    try:
        subprocess.run(
            ["/usr/bin/omarchy-shell", "-q", PLUGIN_ID, kind, value],
            env=session_env(),
            timeout=TELL_TIMEOUT,
            check=False,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
    except (OSError, subprocess.TimeoutExpired):
        pass


def on_key(code, value):
    if value == 2:
        return
    pressed = value == 1

    mod = MODS.get(code)
    if mod:
        if pressed:
            if code in down:
                return
            down.add(code)
            if any(c in down for c, m in MODS.items() if m == mod and c != code):
                return
            tell("press", mod)
        else:
            if code not in down:
                return
            down.discard(code)
            if any(c in down for c, m in MODS.items() if m == mod and c != code):
                return
            tell("release", mod)
        return

    # Usage tracking is opt-in and match-before-write. Unmatched keydowns
    # never leave this process: no IPC, no log, no file.
    if not pressed:
        return
    load_watch()
    if not remember_usage:
        return
    held_mods = sorted({MODS[c] for c in down})
    if not held_mods:
        return
    key_name = KEY_NAMES.get(code)
    if not key_name:
        return
    load_bindings()
    identity = "+".join(held_mods) + ":" + key_name.upper()
    if identity not in known_bindings:
        return
    load_usage()
    usage_counts[identity] = min(1000000, (usage_counts.get(identity) or 0) + 1)
    if len(usage_counts) > 512:
        extra = sorted(usage_counts, key=usage_counts.get)[: len(usage_counts) - 512]
        for key in extra:
            del usage_counts[key]
    write_usage()


def is_keyboard(dev):
    caps = dev.capabilities()
    return ecodes.EV_KEY in caps and ecodes.KEY_A in caps.get(ecodes.EV_KEY, [])


def open_devices():
    def _open():
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

    as_root(_open)


def drop_devices():
    for path, dev in list(devices.items()):
        try:
            if not glob.glob(path):
                dev.close()
                del devices[path]
        except OSError:
            try:
                dev.close()
            except OSError:
                pass
            devices.pop(path, None)


def on_signal(sig, frame):
    global stopping
    stopping = True


def parse_args():
    parser = argparse.ArgumentParser(add_help=False)
    parser.add_argument("--uid", type=int, required=True)
    args = parser.parse_args()
    if args.uid <= 0:
        sys.exit(2)
    try:
        pwd.getpwuid(args.uid)
    except KeyError:
        sys.exit(2)
    return args.uid


def main():
    global target_uid, target_gid, pw_home
    target_uid = parse_args()
    pw = pwd.getpwuid(target_uid)
    target_gid = pw.pw_gid
    pw_home = pw.pw_dir

    if os.geteuid() != 0:
        sys.stderr.write("hotkey-watcher must start as root to open /dev/input\n")
        sys.exit(1)

    os.setgid(target_gid)
    os.seteuid(target_uid)

    signal.signal(signal.SIGTERM, on_signal)
    signal.signal(signal.SIGINT, on_signal)

    open_devices()
    last_scan = time.monotonic()
    while not stopping:
        try:
            fds = [dev.fd for dev in devices.values()]
            r, _, _ = select.select(fds, [], [], SCAN_INTERVAL)
            for fd in r:
                for dev in list(devices.values()):
                    if dev.fd != fd:
                        continue
                    try:
                        for ev in dev.read():
                            if ev.type == ecodes.EV_KEY:
                                on_key(ev.code, ev.value)
                    except OSError:
                        try:
                            dev.close()
                        except OSError:
                            pass
                        for p, d in list(devices.items()):
                            if d.fd == fd:
                                del devices[p]
                    break
        except OSError:
            pass
        if time.monotonic() - last_scan > SCAN_INTERVAL:
            open_devices()
            drop_devices()
            last_scan = time.monotonic()


if __name__ == "__main__":
    main()
