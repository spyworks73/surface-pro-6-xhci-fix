#!/bin/bash
# rotate-manual.sh - toggle the screen between landscape and portrait
# (display + touchscreen) with a single keypress.
#
# Written for a Surface Pro 6 on an X11 session where the internal sensor hub
# is blocked (see docs/ish-freeze-kernel-6.19.8.md), so iio-sensor-proxy
# cannot rotate the screen automatically.
#
# Requires: xrandr, xinput. Make it executable: chmod +x rotate-manual.sh
# Example binding in ~/.xbindkeysrc (Mod4 = Super / Windows / Command key):
#   "/path/to/rotate-manual.sh"
#      Mod4+o
#
# State is kept in /tmp/rotation-state ("normal" or "left"). If the file is
# missing, it is initialised from the current screen geometry
# (width > height => landscape). /tmp is a tmpfs, so the state is recreated at
# every boot and can never be stale.
# All output, including the shell trace, goes to /tmp/rotate.log so that
# keypresses coming from a keyboard shortcut can be debugged.
export DISPLAY=:0
exec >>/tmp/rotate.log 2>&1
set -x
echo "--- $(date '+%F %T') ---"

STATE=/tmp/rotation-state
TOUCH=$(xinput list | grep -i "touch\|IPTS" | grep -oP 'id=\K\d+' | head -1)

# Initialise from the geometry: width > height => landscape.
if [ ! -f "$STATE" ]; then
    GEO=$(xrandr | awk '/ connected/{ for(i=1;i<=NF;i++) if ($i ~ /^[0-9]+x[0-9]+\+/) {print $i; exit} }')
    W=${GEO%%x*}
    H=${GEO#*x}
    H=${H%%+*}
    if [ -n "$W" ] && [ -n "$H" ] && [ "$W" -gt "$H" ]; then
        echo normal > "$STATE"
    else
        echo left > "$STATE"
    fi
fi

CUR=$(cat "$STATE")

if [ "$CUR" = "normal" ]; then
    xrandr -o left || exit 1
    [ -n "$TOUCH" ] && xinput set-prop "$TOUCH" "Coordinate Transformation Matrix" 0 -1 1 1 0 0 0 0 1
    echo left > "$STATE"
    echo "portrait (left-up)"
else
    xrandr -o normal || exit 1
    [ -n "$TOUCH" ] && xinput set-prop "$TOUCH" "Coordinate Transformation Matrix" 1 0 0 0 1 0 0 0 1
    echo normal > "$STATE"
    echo "landscape (normal)"
fi
