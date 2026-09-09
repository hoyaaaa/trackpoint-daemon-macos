#!/usr/bin/env bash
set -euo pipefail

CHECK_ONLY=false
case "${1:-}" in
    "") ;;
    --check) CHECK_ONLY=true ;;
    *) printf 'Usage: %s [--check]\n' "$0" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { printf 'Usage: %s [--check]\n' "$0" >&2; exit 2; }

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
APP="${HOME:?}/Applications/TrackPointD.app"
OLD_PLIST="$HOME/Library/LaunchAgents/com.user.trackpointd.plist"
if ! $CHECK_ONLY && [ -e "$APP" ] && [ ! -d "$APP" ]; then
    printf 'Refusing to replace non-app path: %s\n' "$APP" >&2
    exit 1
fi
BUILD_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/trackpointd-install.XXXXXX")"
STAGED_APP="$BUILD_ROOT/TrackPointD.app"
BACKUP_APP="$BUILD_ROOT/TrackPointD.previous.app"
INSTALL_COMPLETE=false
APP_MOVED=false
APP_BACKED_UP=false
SIGNING_IDENTITY="${TRACKPOINTD_SIGN_IDENTITY:-}"
if [ -z "$SIGNING_IDENTITY" ]; then
    AVAILABLE_IDENTITIES="$(security find-identity -v -p codesigning 2>/dev/null || true)"
    EXISTING_AUTHORITY=""
    if [ -d "$APP" ]; then
        EXISTING_AUTHORITY="$({ codesign -dv --verbose=4 "$APP" 2>&1 || true; } |
            awk -F= '/^Authority=/{print substr($0, index($0, "=") + 1); exit}')"
    fi
    if [ -n "$EXISTING_AUTHORITY" ] &&
       [[ "$AVAILABLE_IDENTITIES" == *\"$EXISTING_AUTHORITY\"* ]]; then
        SIGNING_IDENTITY="$EXISTING_AUTHORITY"
    else
        SIGNING_IDENTITY="$(printf '%s\n' "$AVAILABLE_IDENTITIES" | awk '
        /"Developer ID Application:/ && !developer_id { developer_id=$2 }
        /"Apple Development:/ && !development { development=$2 }
        END { if (developer_id) print developer_id; else if (development) print development }
        ')"
    fi
fi
[ -n "$SIGNING_IDENTITY" ] || SIGNING_IDENTITY="-"

stop_daemon() {
    pkill -x trackpointd 2>/dev/null || true
    for _ in {1..20}; do
        pgrep -x trackpointd >/dev/null 2>&1 || return 0
        sleep 0.05
    done
    pkill -KILL -x trackpointd 2>/dev/null || true
}

cleanup() {
    if ! $INSTALL_COMPLETE; then
        if $APP_MOVED; then
            stop_daemon
            [ ! -e "$APP" ] || rm -rf -- "$APP"
        fi
        if $APP_BACKED_UP && [ -d "$BACKUP_APP" ]; then
            mv "$BACKUP_APP" "$APP"
            open -g "$APP" >/dev/null 2>&1 || true
        fi
    fi
    case "$BUILD_ROOT" in
        "${TMPDIR:-/tmp}"/trackpointd-install.*) rm -rf -- "$BUILD_ROOT" ;;
    esac
}
trap cleanup EXIT

log() { printf '[+] %s\n' "$1"; }

printf '%s\n' '==============================' ' TrackPointD install / upgrade' '=============================='

log 'Building a complete staged app...'
mkdir -p "$STAGED_APP/Contents/MacOS" "$STAGED_APP/Contents/Resources"
clang -O2 -fobjc-arc -mmacosx-version-min=12.0 \
    -o "$STAGED_APP/Contents/MacOS/trackpointd" "$SCRIPT_DIR/trackpointd.m" \
    -framework Cocoa \
    -framework ApplicationServices \
    -framework CoreAudio \
    -framework IOKit \
    -lm

if [ -f "$SCRIPT_DIR/TrackPointD.icns" ]; then
    cp "$SCRIPT_DIR/TrackPointD.icns" "$STAGED_APP/Contents/Resources/TrackPointD.icns"
fi

cat > "$STAGED_APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>        <string>com.user.trackpointd</string>
    <key>CFBundleName</key>              <string>TrackPointD</string>
    <key>CFBundleDisplayName</key>       <string>TrackPointD</string>
    <key>CFBundleExecutable</key>        <string>trackpointd</string>
    <key>CFBundleShortVersionString</key><string>2.2.1</string>
    <key>CFBundleVersion</key>           <string>12</string>
    <key>CFBundlePackageType</key>       <string>APPL</string>
    <key>CFBundleIconFile</key>          <string>TrackPointD</string>
    <key>LSMinimumSystemVersion</key>    <string>12.0</string>
    <key>LSUIElement</key>               <true/>
    <key>NSPrincipalClass</key>          <string>NSApplication</string>
</dict>
</plist>
PLIST

plutil -lint "$STAGED_APP/Contents/Info.plist" >/dev/null
"$STAGED_APP/Contents/MacOS/trackpointd" --self-test
if [ "$SIGNING_IDENTITY" = "-" ]; then
    log 'Code signing: ad-hoc (permissions may need approval again after upgrades).'
else
    log 'Code signing: stable local Apple identity.'
fi
codesign --force --deep --sign "$SIGNING_IDENTITY" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"

if $CHECK_ONLY; then
    INSTALL_COMPLETE=true
    log 'Build, self-test, property list, and code-signing checks passed.'
    exit 0
fi

log 'Installing verified app...'
mkdir -p "$(dirname "$APP")"
if [ -d "$APP" ]; then
    APP_BACKED_UP=true
    mv "$APP" "$BACKUP_APP"
fi
APP_MOVED=true
mv "$STAGED_APP" "$APP"
stop_daemon

/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

open -g "$APP"
INSTALL_COMPLETE=true

log 'Registering Login Item...'
if osascript - "$APP" >/dev/null <<'APPLESCRIPT'
on run argv
    set appPath to item 1 of argv
    tell application "System Events"
        set needsCreate to true
        if exists login item "TrackPointD" then
            set existingItem to login item "TrackPointD"
            if path of existingItem is appPath then
                set hidden of existingItem to true
                set needsCreate to false
            else
                delete existingItem
            end if
        end if
        if needsCreate then
            make login item at end with properties {path:appPath, hidden:true}
        end if
    end tell
end run
APPLESCRIPT
then
    if [ -f "$OLD_PLIST" ]; then
        launchctl unload "$OLD_PLIST" 2>/dev/null || true
        rm -f -- "$OLD_PLIST" ||
            printf '[!] Could not remove the legacy LaunchAgent: %s\n' "$OLD_PLIST" >&2
    fi
else
    printf '[!] Could not register the Login Item. Add TrackPointD in Login Items manually.\n' >&2
fi

printf '\nDone. If the menu bar icon has an orange center dot, open:\n'
printf '  TrackPointD → Settings… → macOS Integration → Request Access…\n'
printf 'macOS registers TrackPointD and opens the correct privacy pane; you approve the final switch.\n\n'
printf 'Log: tail -f /tmp/trackpointd.log\n'
printf 'Uninstall: bash %s/uninstall.sh\n' "$SCRIPT_DIR"
