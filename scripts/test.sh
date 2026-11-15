#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
build_dir=$(mktemp -d "${TMPDIR:-/tmp}/trackpointd-tests.XXXXXX")
trap 'rm -rf "$build_dir"' EXIT
flags=(-O2 -fobjc-arc -mmacosx-version-min=12.0)
frameworks=(-framework Cocoa -framework ApplicationServices -framework CoreAudio -framework IOKit -lm)
clang "${flags[@]}" -o "$build_dir/trackpointd" trackpointd.m "${frameworks[@]}"
"$build_dir/trackpointd" --self-test
for test_file in tests/*_test.m; do
    test_name=$(basename "$test_file" .m)
    clang "${flags[@]}" -o "$build_dir/$test_name" "$test_file" "${frameworks[@]}"
    "$build_dir/$test_name"
done
python3 tests/installer_test.py
bash -n install.sh uninstall.sh scripts/test.sh
TRACKPOINTD_SIGN_IDENTITY=- bash install.sh --check
