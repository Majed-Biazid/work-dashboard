#!/bin/bash
# Build "Manara.app" into ~/Applications from this checkout.
#
#   ./build.sh            build (and restart the app if it is running)
#   ./build.sh --login    also open it at login and after every wake
#
# The app reads web/ and scripts/ live from THIS folder (its path is written into
# the app's Info.plist), so editing a page or a collector needs only ⌘R — no rebuild.
# Rebuild only after changing app/*.swift. A rebuild changes the ad-hoc signature,
# so macOS asks for Calendar and Notifications permission again.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
APP="$HOME/Applications/Manara.app"
OLD="$HOME/Applications/Work Dashboard.app"   # the app's earlier name: replaced by Manara.app below
BIN="$APP/Contents/MacOS/WorkDashboard"

for tool in xcrun jq gh; do command -v "$tool" >/dev/null || { echo "missing: $tool (see README → Requirements)"; exit 1; }; done

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
xcrun swiftc -O -swift-version 5 -target "$(uname -m)-apple-macos14" -o "$BIN.new" "$HERE"/app/*.swift
mv "$BIN.new" "$BIN"
cp "$HERE/app/Info.plist" "$APP/Contents/Info.plist"
plutil -replace WDRoot -string "$HERE" "$APP/Contents/Info.plist"
[ -f "$HERE/app/AppIcon.icns" ] && cp "$HERE/app/AppIcon.icns" "$APP/Contents/Resources/"
codesign --force --sign - --identifier com.workdashboard.app "$APP" >/dev/null
chmod +x "$HERE"/scripts/*.sh "$HERE"/scripts/*.py "$HERE"/launchd/*.sh
echo "built: $APP"

if [ "${1:-}" = "--login" ]; then
  PLIST="$HOME/Library/LaunchAgents/com.workdashboard.open.plist"
  # fill the template without sed, so any character in the path is safe
  ROOT="$HERE" HOMEDIR="$HOME" perl -pe 's/__ROOT__/$ENV{ROOT}/g; s/__HOMEDIR__|__HOME__/$ENV{HOMEDIR}/g' \
    "$HERE/launchd/com.workdashboard.open.plist" >"$PLIST"
  launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
  # bootout finishes asynchronously; retry bootstrap briefly instead of failing
  for i in 1 2 3 4 5; do launchctl bootstrap "gui/$(id -u)" "$PLIST" 2>/dev/null && break; sleep 1; done
  launchctl print "gui/$(id -u)/com.workdashboard.open" >/dev/null 2>&1 || { echo "could not load $PLIST"; exit 1; }
  echo "opens at login and after every wake: $PLIST"
fi

RUNNING=0; pgrep -xq WorkDashboard && RUNNING=1
# the earlier "Work Dashboard.app" (same app, old name): quit it and remove it, once
if [ -d "$OLD" ]; then pkill -x WorkDashboard 2>/dev/null; sleep 1; rm -rf "$OLD"; echo "replaced: $OLD"; fi
if [ $RUNNING = 1 ]; then pkill -x WorkDashboard 2>/dev/null; sleep 1; open "$APP"; echo "restarted"; fi
