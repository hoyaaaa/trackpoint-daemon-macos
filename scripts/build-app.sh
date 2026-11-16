#!/bin/bash
set -euo pipefail
[ "$#" -eq 1 ] || { echo "Usage: $0 OUTPUT.app" >&2; exit 2; }
source_dir="$(cd "$(dirname "$0")/.." && pwd)"
app="$1"
[ ! -e "$app" ] || { echo "Output already exists: $app" >&2; exit 1; }
version=$(awk '/^#define TRACKPOINTD_VERSION / {gsub(/"/, "", $3); print $3}' "$source_dir/version.h")
build=$(awk '/^#define TRACKPOINTD_BUILD / {gsub(/"/, "", $3); print $3}' "$source_dir/version.h")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$build" =~ ^[0-9]+$ ]] || { echo 'Invalid version.h' >&2; exit 1; }
source "$source_dir/scripts/signing-identity.sh"
signing_identity=$(trackpointd_signing_identity)
complete=false
trap 'if ! $complete; then rm -rf -- "$app"; fi' EXIT
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
clang -O2 -fobjc-arc -mmacosx-version-min=12.0 -o "$app/Contents/MacOS/trackpointd" \
    "$source_dir/trackpointd.m" -framework Cocoa -framework ApplicationServices \
    -framework CoreAudio -framework IOKit -lm
if [ -f "$source_dir/TrackPointD.icns" ]; then
    cp "$source_dir/TrackPointD.icns" "$app/Contents/Resources/TrackPointD.icns"
fi
cp "$source_dir/Resources/keyboard-windows.png" "$source_dir/Resources/f12-windows.png" "$app/Contents/Resources/"
cp "$source_dir/scripts/upgrade.sh" "$app/Contents/Resources/upgrade.sh"
cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>com.user.trackpointd</string>
<key>CFBundleName</key><string>TrackPointD</string>
<key>CFBundleDisplayName</key><string>TrackPointD</string>
<key>CFBundleExecutable</key><string>trackpointd</string>
<key>CFBundleShortVersionString</key><string>$version</string>
<key>CFBundleVersion</key><string>$build</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>TrackPointD</string>
<key>LSMinimumSystemVersion</key><string>12.0</string>
<key>LSUIElement</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
plutil -lint "$app/Contents/Info.plist" >/dev/null
"$app/Contents/MacOS/trackpointd" --self-test
codesign --force --deep --sign "$signing_identity" "$app"
codesign --verify --deep --strict "$app"
complete=true
