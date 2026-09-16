#!/usr/bin/bash
# Bounded producer for `omarchy menu keybindings --print`.
set -uo pipefail
MAX=262144
LC_ALL=C
export LC_ALL
if [ ! -x /usr/bin/omarchy ]; then
  echo "omarchy binary not found at /usr/bin/omarchy" >&2
  exit 127
fi
out=$(/usr/bin/timeout -k 2 -- 20 /usr/bin/omarchy menu keybindings --print | /usr/bin/head -c $((MAX + 1)))
rc=$?
if [ ${#out} -gt "$MAX" ]; then
  echo "keybindings output exceeded ${MAX} bytes" >&2
  exit 1
fi
[ "$rc" -eq 0 ] || exit "$rc"
printf '%s' "$out"
