#!/usr/bin/env bash
PLIST="$HOME/Library/LaunchAgents/com.user.trackpointd.plist"
APP="$HOME/Applications/TrackPointD.app"

launchctl unload "$PLIST" 2>/dev/null || true
rm -f "$PLIST"

osascript -e 'tell application "System Events" to delete login item "TrackPointD"' 2>/dev/null || true

pkill -f "trackpointd" 2>/dev/null || true
rm -rf "$APP"
defaults delete -g com.apple.mouse.linear 2>/dev/null || true
tccutil reset Accessibility com.user.trackpointd 2>/dev/null || true
echo "trackpointd uninstalled"
