#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/trackpointd-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
flags=(-O2 -fobjc-arc -mmacosx-version-min=12.0)
frameworks=(-framework Cocoa -framework ApplicationServices -framework CoreAudio -framework IOKit -lm)
clang "${flags[@]}" -o "$build_dir/trackpointd" trackpointd.m "${frameworks[@]}"
"$build_dir/trackpointd" --self-test
expected_version=$(awk '/^#define TRACKPOINTD_VERSION / {gsub(/"/, "", $3); print $3}' version.h)
[ "$("$build_dir/trackpointd" --version)" = "$expected_version" ]
for test_file in tests/*_test.m; do
    test_name=$(basename "$test_file" .m)
    clang "${flags[@]}" -o "$build_dir/$test_name" "$test_file" "${frameworks[@]}"
    "$build_dir/$test_name"
done
for test_file in tests/*_test.py; do
    python3 "$test_file"
done
bash -n install.sh uninstall.sh scripts/*.sh
ruby -c Formula/trackpointd.rb
if command -v brew >/dev/null 2>&1; then
    HOMEBREW_NO_AUTO_UPDATE=1 TRACKPOINTD_SIGN_IDENTITY=- brew ruby tests/formula_test.rb
fi
TRACKPOINTD_SIGN_IDENTITY=- bash install.sh --check
