#!/usr/bin/env bash
set -euo pipefail

[ "$#" -eq 0 ] || { printf 'Usage: %s\n' "$0" >&2; exit 2; }

APP="${HOME:?}/Applications/TrackPointD.app"
OLD_PLIST="$HOME/Library/LaunchAgents/com.user.trackpointd.plist"
EMPTY_MAPPING='{"UserKeyMapping":[]}'

pkill -x trackpointd 2>/dev/null || true
for _ in {1..20}; do
    pgrep -x trackpointd >/dev/null 2>&1 || break
    sleep 0.05
done
pkill -KILL -x trackpointd 2>/dev/null || true
launchctl unload "$OLD_PLIST" 2>/dev/null || true
rm -f -- "$OLD_PLIST"
osascript -e 'tell application "System Events" to delete login item "TrackPointD"' \
    2>/dev/null || true

for product in 24814 24801; do
    /usr/bin/hidutil property \
        --matching "{\"VendorID\":6127,\"ProductID\":$product}" \
        --set "$EMPTY_MAPPING" >/dev/null 2>&1 || true
done

case "$APP" in
    "$HOME/Applications/TrackPointD.app") rm -rf -- "$APP" ;;
    *) printf 'Refusing unexpected app path: %s\n' "$APP" >&2; exit 1 ;;
esac

printf 'TrackPointD and its device mappings were removed. macOS mouse settings were left unchanged.\n'
