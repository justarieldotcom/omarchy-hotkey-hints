#!/usr/bin/bash
# One-shot, consented install of the root-owned watcher helper.
# Run in a visible terminal:
#   sudo bash ~/.config/omarchy/plugins/io.github.mikus2604.hotkey-hints/scripts/install.sh
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "This installer copies a helper into a root-owned path." >&2
  echo "Re-run: sudo bash $0" >&2
  exit 1
fi

TARGET_USER="${SUDO_USER:-}"
if [ -z "$TARGET_USER" ] || [ "$TARGET_USER" = "root" ]; then
  echo "Refusing to install without SUDO_USER (the desktop session owner)." >&2
  exit 1
fi

TARGET_UID="$(id -u "$TARGET_USER")"
TARGET_GID="$(id -g "$TARGET_USER")"
TARGET_HOME="$(getent passwd "$TARGET_USER" | awk -F: '{print $6}')"
if [ -z "$TARGET_HOME" ] || [ ! -d "$TARGET_HOME" ]; then
  echo "Could not resolve home for $TARGET_USER" >&2
  exit 1
fi

HERE="$(cd "$(dirname -- "$0")" && pwd)"
ROOT="$(cd "$HERE/.." && pwd)"
SRC="$ROOT/hotkey-watcher.py"
if [ ! -f "$SRC" ]; then
  echo "hotkey-watcher.py not found next to this installer: $SRC" >&2
  exit 1
fi

LIBEXEC=/usr/local/libexec/omarchy-hotkey-hints
UNIT=/etc/systemd/system/omarchy-hotkey-hints-watcher.service
STATE="$TARGET_HOME/.local/state/omarchy/hotkey-hints"

echo "Installing root-owned helper for uid $TARGET_UID ($TARGET_USER)"
echo "  from: $SRC"
echo "  to:   $LIBEXEC/hotkey-watcher.py"

install -o root -g root -d -m 0755 "$LIBEXEC"
install -o root -g root -m 0755 "$SRC" "$LIBEXEC/hotkey-watcher.py"

install -o "$TARGET_USER" -g "$TARGET_GID" -d -m 0700 \
  "$TARGET_HOME/.local/state/omarchy" "$STATE" 2>/dev/null || \
  sudo -u "$TARGET_USER" mkdir -p "$STATE"
chmod 700 "$STATE" || true
chown "$TARGET_USER:$TARGET_GID" "$STATE" || true

cat > "$UNIT" <<EOF
[Unit]
Description=Omarchy hotkey-hints modifier key watcher
After=systemd-user-sessions.service

[Service]
Type=simple
ExecStart=/usr/bin/python3 -I $LIBEXEC/hotkey-watcher.py --uid $TARGET_UID
Restart=on-failure
RestartSec=5
StartLimitBurst=5
StartLimitIntervalSec=60
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=read-only
PrivateTmp=yes
ReadWritePaths=-$STATE
DevicePolicy=closed
DeviceAllow=/dev/input/event* r
RestrictAddressFamilies=AF_UNIX AF_NETLINK
MemoryMax=64M
TasksMax=32
UMask=0077

[Install]
WantedBy=multi-user.target
EOF
chmod 644 "$UNIT"

systemctl daemon-reload
systemctl enable --now omarchy-hotkey-hints-watcher.service
systemctl --no-pager --full status omarchy-hotkey-hints-watcher.service || true

echo
echo "Watcher installed. Re-run this script after updating the plugin to refresh the helper."
echo "The overlay itself is loaded by: omarchy restart shell"
