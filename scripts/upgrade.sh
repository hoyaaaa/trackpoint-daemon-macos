#!/bin/bash
# Fixed Homebrew operations only. Release text never becomes shell code.
set -euo pipefail
mode=${1:-}
if [ "$mode" = relaunch ]; then
    [ "$#" -eq 3 ] && [[ "$2" =~ ^[1-9][0-9]*$ ]] || exit 2
    case "$3" in "/opt/homebrew"|"/usr/local") ;; *) exit 2 ;; esac
    for _ in {1..100}; do
        if ! kill -0 "$2" 2>/dev/null; then
            /usr/bin/open "$3/opt/trackpointd/TrackPointD.app"
            exit $?
        fi
        sleep 0.1
    done
    echo 'TrackPointD did not quit; reopen the updated app manually.' >&2
    exit 1
fi
[ "$mode" = upgrade ] && [ "$#" -eq 4 ] || exit 2
brew=$2
prefix=$3
expected=$4
case "$prefix" in "/opt/homebrew"|"/usr/local") ;; *) exit 2 ;; esac
[ "$brew" = "$prefix/bin/brew" ] && [ -x "$brew" ] || exit 2
[[ "$expected" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]] || exit 2
export PATH="$prefix/bin:/usr/bin:/bin:/usr/sbin:/sbin"
export NONINTERACTIVE=1 HOMEBREW_NO_AUTO_UPDATE=1
formula=hoyaaaa/trackpointd/trackpointd
echo 'Refreshing the TrackPointD package…'
tap=$("$brew" --repo hoyaaaa/trackpointd)
origin=$(/usr/bin/git -C "$tap" remote get-url origin)
case "$origin" in
    https://github.com/hoyaaaa/trackpoint-daemon-macos|https://github.com/hoyaaaa/trackpoint-daemon-macos.git|git@github.com:hoyaaaa/trackpoint-daemon-macos.git) ;;
    *) echo 'The TrackPointD tap has an unexpected source; no changes made.' >&2; exit 5 ;;
esac
branch=$(/usr/bin/git -C "$tap" symbolic-ref --short HEAD)
changes=$(/usr/bin/git -C "$tap" status --porcelain)
[ "$branch" = main ] && [ -z "$changes" ] || {
    echo 'The TrackPointD tap has local changes or a custom branch. No changes made.' >&2; exit 5;
}
/usr/bin/git -C "$tap" fetch origin main
/usr/bin/git -C "$tap" merge-base --is-ancestor HEAD FETCH_HEAD || {
    echo 'The TrackPointD tap has local commits. No merge attempted.' >&2; exit 5;
}
/usr/bin/git -C "$tap" merge --ff-only FETCH_HEAD
available=$("$brew" info --json=v2 "$formula" | /usr/bin/plutil -extract formulae.0.versions.stable raw -o - -)
if [ "$available" != "$expected" ]; then
    echo "Homebrew offers $available; requested release $expected is not ready. Check again later." >&2
    exit 3
fi
echo "Installing TrackPointD ${expected}…"
"$brew" upgrade "$formula"
app="$prefix/opt/trackpointd/TrackPointD.app"
/usr/bin/codesign --verify --deep --strict "$app"
actual=$("$app/Contents/MacOS/trackpointd" --version)
[ "$actual" = "$expected" ] || { echo "Installed version $actual does not match $expected." >&2; exit 4; }
"$app/Contents/MacOS/trackpointd" --self-test
echo "TrackPointD $actual verified. Reopening…"
