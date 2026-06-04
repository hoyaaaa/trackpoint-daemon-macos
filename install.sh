#!/usr/bin/env bash
# trackpoint/install.sh
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
DAEMON_SRC="$SCRIPT_DIR/trackpointd.m"
APP="$HOME/Applications/TrackPointD.app"
DAEMON_BIN="$APP/Contents/MacOS/trackpointd"
OLD_PLIST="$HOME/Library/LaunchAgents/com.user.trackpointd.plist"

GREEN='\033[0;32m'; NC='\033[0m'
log() { echo -e "${GREEN}[+]${NC} $1"; }

echo "=============================="
echo " TrackPoint daemon install"
echo "=============================="

# ── 0. Stop running instance ────────────────────────────────────
if pgrep -f "trackpointd" > /dev/null 2>&1; then
    log "Stopping running TrackPointD..."
    pkill -f "trackpointd" 2>/dev/null || true
    sleep 0.5
fi

# ── 1. Compile (only if source changed) ───────────────────────
mkdir -p "$APP/Contents/MacOS"

NEED_COMPILE=false
if [ ! -f "$DAEMON_BIN" ]; then
    NEED_COMPILE=true
elif [ "$DAEMON_SRC" -nt "$DAEMON_BIN" ]; then
    NEED_COMPILE=true
fi

# ── 2. Resources + Info.plist (before codesign) ─────────────────
mkdir -p "$APP/Contents/Resources"
if [ -f "$SCRIPT_DIR/TrackPointD.icns" ]; then
    cp "$SCRIPT_DIR/TrackPointD.icns" "$APP/Contents/Resources/TrackPointD.icns"
fi

cat > "$APP/Contents/Info.plist" << 'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>     <string>com.user.trackpointd</string>
    <key>CFBundleName</key>           <string>TrackPointD</string>
    <key>CFBundleExecutable</key>     <string>trackpointd</string>
    <key>CFBundleVersion</key>        <string>1.0</string>
    <key>CFBundlePackageType</key>    <string>APPL</string>
    <key>CFBundleIconFile</key>       <string>TrackPointD</string>
    <key>LSUIElement</key>            <true/>
    <key>NSPrincipalClass</key>       <string>NSApplication</string>
</dict>
</plist>
EOF

if $NEED_COMPILE; then
    log "Compiling..."
    clang -O2 -fobjc-arc -o /tmp/trackpointd_build "$DAEMON_SRC" \
        -framework Cocoa \
        -framework ApplicationServices \
        -framework IOKit \
        -lm || { echo "Compile failed"; exit 1; }
    install -m 755 /tmp/trackpointd_build "$DAEMON_BIN"

    log "Code signing..."
    codesign --force --deep -s - "$APP"

    # Signature changed — reset TCC (re-grant required)
    log "Resetting accessibility permission (re-grant required)..."
    tccutil reset Accessibility com.user.trackpointd 2>/dev/null || true
else
    log "Source unchanged — skipping recompile (signature preserved)"
fi

# Force Launch Services to re-index the bundle (icon refresh)
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$APP" 2>/dev/null || true

# ── 3. Mouse defaults ───────────────────────────────────────────
log "Applying mouse defaults..."
defaults write -g com.apple.mouse.scaling 5
defaults write -g com.apple.mouse.linear 1

# ── 4. Remove old LaunchAgent -> replace with Login Item ────────
if [ -f "$OLD_PLIST" ]; then
    launchctl unload "$OLD_PLIST" 2>/dev/null || true
    rm -f "$OLD_PLIST"
    log "Old LaunchAgent removed"
fi

log "Registering Login Item..."
osascript << APPLESCRIPT
tell application "System Events"
    if (exists login item "TrackPointD") then
        delete login item "TrackPointD"
    end if
    make login item at end with properties {path:"$APP", hidden:true}
end tell
APPLESCRIPT

# ── 5. Launch now ───────────────────────────────────────────────
log "Launching app..."
pkill -f "trackpointd" 2>/dev/null || true
sleep 0.5
open -g -a "$APP"

echo ""
echo -e "${GREEN}Done!${NC}"
echo ""
if $NEED_COMPILE; then
    echo "  Source was recompiled — re-grant accessibility permission:"
    echo "  System Settings -> Privacy & Security -> Accessibility"
    echo "  -> Enable TrackPointD (toggle off and on if already listed)"
    echo ""
fi
echo "Log: tail -f /tmp/trackpointd.log"
echo "Uninstall: bash $SCRIPT_DIR/uninstall.sh"
