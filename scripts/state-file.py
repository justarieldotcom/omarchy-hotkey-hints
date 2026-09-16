#!/usr/bin/python3 -I
"""Descriptor-bound read/write for plugin state.

Invoked as an argv array from QML. Open once, fstat the descriptor, read/write
that descriptor — never re-resolve the pathname.

  /usr/bin/python3 -I scripts/state-file.py read  shell|usage
  /usr/bin/python3 -I scripts/state-file.py write usage|bindings|watch   # stdin
"""
import json
import os
import pwd
import re
import stat
import sys
import secrets

MAX_STATE = 65536
MAX_SHELL = 1048576
_COMPONENT = re.compile(r"[A-Za-z0-9._-]+")
_IDENTITY = re.compile(r"^[A-Z0-9+]{1,80}:[A-Z0-9._-]{1,64}$")


def _ok_component(name):
    return bool(_COMPONENT.fullmatch(name)) and name not in (".", "..")


def open_dir_chain(parts, mode_leaf=False):
    if not parts or not all(_ok_component(p) for p in parts):
        raise PermissionError("refusing directory chain")
    home = pwd.getpwuid(os.geteuid()).pw_dir
    fd = os.open(home, os.O_RDONLY | os.O_DIRECTORY | os.O_CLOEXEC)
    try:
        for i, name in enumerate(parts):
            try:
                nfd = os.open(
                    name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=fd,
                )
            except FileNotFoundError:
                if not mode_leaf:
                    os.close(fd)
                    raise
                try:
                    os.mkdir(name, 0o700, dir_fd=fd)
                except FileExistsError:
                    pass
                nfd = os.open(
                    name,
                    os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC,
                    dir_fd=fd,
                )
            os.close(fd)
            fd = nfd
            st = os.fstat(fd)
            if not stat.S_ISDIR(st.st_mode) or st.st_uid != os.geteuid():
                raise PermissionError("untrusted directory component %s" % name)
            if mode_leaf and i == len(parts) - 1 and st.st_mode & 0o077:
                os.fchmod(fd, 0o700)
        return fd
    except BaseException:
        os.close(fd)
        raise


def read_bounded(dirfd, name, max_bytes, require_private):
    try:
        fd = os.open(
            name,
            os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK | os.O_CLOEXEC,
            dir_fd=dirfd,
        )
    except FileNotFoundError:
        return None
    try:
        st = os.fstat(fd)
        if not stat.S_ISREG(st.st_mode) or st.st_uid != os.geteuid() or st.st_nlink != 1:
            raise PermissionError("refusing state file")
        if require_private and st.st_mode & 0o077:
            raise PermissionError("refusing world/group-accessible state file")
        if st.st_size > max_bytes:
            raise PermissionError("state file too large")
        os.set_blocking(fd, True)
        data = b""
        while len(data) <= max_bytes:
            chunk = os.read(fd, min(65536, max_bytes + 1 - len(data)))
            if not chunk:
                break
            data += chunk
        if len(data) > max_bytes:
            raise PermissionError("state file grew past the limit")
        return data
    finally:
        os.close(fd)


def write_atomic(dirfd, name, data):
    if len(data) > MAX_STATE:
        raise ValueError("payload too large")
    tmp = ".%s.%s.tmp" % (name, secrets.token_hex(8))
    fd = os.open(
        tmp,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
        0o600,
        dir_fd=dirfd,
    )
    try:
        os.fchmod(fd, 0o600)
        view = memoryview(data)
        while view:
            n = os.write(fd, view)
            view = view[n:]
        os.fsync(fd)
        os.rename(tmp, name, src_dir_fd=dirfd, dst_dir_fd=dirfd)
        os.fsync(dirfd)
    except BaseException:
        try:
            os.unlink(tmp, dir_fd=dirfd)
        except OSError:
            pass
        raise
    finally:
        os.close(fd)


def validate_usage(payload):
    parsed = json.loads(payload.decode("utf-8", "strict") or "{}")
    if not isinstance(parsed, dict):
        raise ValueError("usage is not an object")
    out = {}
    for key, value in list(parsed.items())[:512]:
        if not isinstance(key, str) or not _IDENTITY.fullmatch(key):
            continue
        try:
            n = int(value)
        except (TypeError, ValueError):
            continue
        if 0 < n <= 1000000:
            out[key] = n
    return json.dumps(out, separators=(",", ":")).encode("utf-8") + b"\n"


def validate_bindings(payload):
    parsed = json.loads(payload.decode("utf-8", "strict") or "[]")
    if not isinstance(parsed, list):
        raise ValueError("bindings is not a list")
    out = []
    seen = set()
    for item in parsed[:4096]:
        if not isinstance(item, str) or not _IDENTITY.fullmatch(item):
            continue
        if item in seen:
            continue
        seen.add(item)
        out.append(item)
    return json.dumps(out, separators=(",", ":")).encode("utf-8") + b"\n"


def validate_watch(payload):
    parsed = json.loads(payload.decode("utf-8", "strict") or "{}")
    if not isinstance(parsed, dict):
        raise ValueError("watch is not an object")
    flag = parsed.get("rememberUsage") is True
    return json.dumps({"rememberUsage": flag}, separators=(",", ":")).encode("utf-8") + b"\n"


def main():
    if len(sys.argv) != 3:
        sys.exit(2)
    op, name = sys.argv[1], sys.argv[2]
    if name not in ("shell", "usage", "bindings", "watch"):
        sys.exit(2)

    if name == "shell":
        if op != "read":
            sys.exit(2)
        dirfd = open_dir_chain([".config", "omarchy"], mode_leaf=False)
        try:
            raw = read_bounded(dirfd, "shell.json", MAX_SHELL, require_private=False)
            sys.stdout.buffer.write(raw or b"{}")
        finally:
            os.close(dirfd)
        return

    dirfd = open_dir_chain([".local", "state", "omarchy", "hotkey-hints"], mode_leaf=True)
    try:
        if op == "read":
            raw = read_bounded(dirfd, name + ".json", MAX_STATE, require_private=True)
            sys.stdout.buffer.write(raw or (b"{}" if name != "bindings" else b"[]"))
        elif op == "write":
            payload = sys.stdin.buffer.read(MAX_STATE + 1)
            if len(payload) > MAX_STATE:
                sys.exit(3)
            if name == "usage":
                data = validate_usage(payload)
            elif name == "bindings":
                data = validate_bindings(payload)
            else:
                data = validate_watch(payload)
            write_atomic(dirfd, name + ".json", data)
        else:
            sys.exit(2)
    finally:
        os.close(dirfd)


if __name__ == "__main__":
    try:
        main()
    except (OSError, PermissionError, ValueError, json.JSONDecodeError):
        sys.exit(1)
