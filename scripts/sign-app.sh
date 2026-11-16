#!/bin/bash
# Run from the launcher/updater, outside Homebrew's isolated build/post-install.
set -euo pipefail
[ "$#" -eq 1 ] && [ -d "$1/Contents/MacOS" ] || exit 2
app=$1
[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -o - "$app/Contents/Info.plist")" = com.user.trackpointd ] || exit 2
source "$(cd "$(dirname "$0")" && pwd)/signing-identity.sh"
identity=$(trackpointd_signing_identity)
if [[ "$identity" =~ ^[[:xdigit:]]{40}$ ]]; then
    requirement="identifier \"com.user.trackpointd\" and certificate leaf = H\"$identity\""
    if codesign --verify --deep --strict -R="$requirement" "$app" 2>/dev/null; then
        exit 0
    fi
fi
# Never rewrite an executable while a daemon might be using it.
executable="$(cd "$app/Contents/MacOS" && pwd -P)/trackpointd"
for pid in $(pgrep -x trackpointd || true); do
    running=$(/bin/ps -p "$pid" -o comm= || true)
    if [ "$running" = "$executable" ]; then
        echo 'Quit this TrackPointD copy before changing its signing identity.' >&2
        exit 1
    fi
done
codesign --force --deep --sign "$identity" "$app"
codesign --verify --deep --strict "$app"
