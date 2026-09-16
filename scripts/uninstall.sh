#!/usr/bin/bash
# Stops the watcher and removes only paths this plugin's installer created.
# Run in a visible terminal:
#   sudo bash ~/.config/omarchy/plugins/io.github.mikus2604.hotkey-hints/scripts/uninstall.sh
# Add --purge to also delete ~/.local/state/omarchy/hotkey-hints for SUDO_USER.
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Re-run: sudo bash $0 [--purge]" >&2
  exit 1
fi

PURGE=0
if [ "${1:-}" = "--purge" ]; then
  PURGE=1
fi

UNIT=/etc/systemd/system/omarchy-hotkey-hints-watcher.service
LIBEXEC=/usr/local/libexec/omarchy-hotkey-hints
HELPER="$LIBEXEC/hotkey-watcher.py"

systemctl disable --now omarchy-hotkey-hints-watcher.service 2>/dev/null || true

if [ -f "$UNIT" ]; then
  rm -f -- "$UNIT"
fi
if [ -f "$HELPER" ]; then
  rm -f -- "$HELPER"
fi
if [ -d "$LIBEXEC" ]; then
  rmdir --ignore-fail-on-non-empty -- "$LIBEXEC" 2>/dev/null || true
fi
systemctl daemon-reload

if [ "$PURGE" -eq 1 ]; then
  TARGET_USER="${SUDO_USER:-}"
  if [ -n "$TARGET_USER" ] && [ "$TARGET_USER" != "root" ]; then
    TARGET_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
    STATE="$TARGET_HOME/.local/state/omarchy/hotkey-hints"
    # Delete only the literal directory this plugin owns, and only if it is a
    # real directory owned by the session user (never follow a symlink).
    if [ -n "$TARGET_HOME" ] && [ -d "$STATE" ] && [ ! -L "$STATE" ]; then
      OWNER="$(stat -c '%U' "$STATE" 2>/dev/null || true)"
      if [ "$OWNER" = "$TARGET_USER" ]; then
        rm -f -- "$STATE/usage.json" "$STATE/bindings.json" "$STATE/watch.json"
        rmdir --ignore-fail-on-non-empty -- "$STATE" 2>/dev/null || true
      fi
    fi
  fi
fi

echo "Watcher removed. Plugin QML (if still installed):"
echo "  omarchy plugin remove io.github.mikus2604.hotkey-hints"
