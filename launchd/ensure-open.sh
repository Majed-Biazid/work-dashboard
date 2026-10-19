#!/bin/bash
# Opens Manara after a restart/login and after every wake (lid open) if it
# is not running. Runs every minute but acts only once per boot+wake, so quitting
# the app mid-session sticks until the next lid-open.
APP="$HOME/Applications/Manara.app"
STAMP="$HOME/Library/Caches/work-dashboard/last-wake"
mkdir -p "$(dirname "$STAMP")"
sec() { sysctl -n "$1" 2>/dev/null | sed -nE 's/^\{ sec = ([0-9]+),.*/\1/p'; }
mark="$(sec kern.boottime)-$(sec kern.waketime)"
[ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$mark" ] && exit 0
# -g + --background: open behind your work, never taking focus or switching Space;
# it goes full screen when you first bring it up
pgrep -xq WorkDashboard || /usr/bin/open -g -a "$APP" --args --background
# stamp this wake only once the app is really up — if the GUI wasn't ready at
# login, the next minute's run tries again
sleep 3
pgrep -xq WorkDashboard && echo "$mark" >"$STAMP"
