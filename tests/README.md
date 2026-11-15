# Automated test coverage

Run `bash scripts/test.sh` on macOS with Xcode Command Line Tools and Python 3.
The same command runs in the required `macOS tests` CI job. No third-party test
frameworks or packages are needed. An assertion or failed command stops the run.

| Feature | Automated checks | Test owner |
|---|---|---|
| Device protocol | USB/BLE report types, bytes, padding, length/ID rejection, Compact configuration/hotkey exclusion | self-test, core_test.m |
| Device matching/lifecycle | Exact VID/PID, unsupported device, duplicate attach, disconnect, pause/resume, wake reapply, shutdown cleanup | runtime_test.m |
| HID manager / event tap | Callback registration order, exact device match list, delayed permission setup, tap creation failures, recovery and cleanup | runtime_test.m |
| Hardware sensitivity / Fn Lock / scrolling settings | Requested commands/values, USB/BLE success/failure, Compact skip, per-device sensitivity fallback, unsupported interface/report-type rejection | runtime_test.m |
| Modifier / F18 remaps | Every enabled/swap/F18 combination, exact device scoping, Compact exclusion, pause/shutdown clearing | runtime_test.m |
| Native scrolling | USB axes, natural direction, BLE horizontal-only synthesis, one-shot BLE vertical scaling, expired pending scroll, malformed/paused/disabled input | runtime_test.m |
| Pointer sensitivity | Unknown-origin pass-through, software scaling, hardware bypass, active-display clamping, mixed-device origin classification; real settings-label regressions for USB auxiliary interfaces, true fallback, mixed devices and wake | runtime_test.m, self-test |
| Middle click / fallback scroll | Option on/off, native/deferred click, compatibility drag, ordinary mouse buttons, pause/disconnect, Preferred Scrolling off | block_middle_test.m |
| Input callbacks | X/Y confirmation, standard/vendor middle button, BLE middle reports, hotkey deduplication/release | runtime_test.m |
| F12 actions | Disabled, valid/rejected URL, existing/missing file, Unicode text and length cap, permissions | runtime_test.m, core_test.m |
| System hotkeys | Fn Lock toggle, Bluetooth/settings requests, screenshot command, Notification Center Fn-N, F12 routing, unknown usage | runtime_test.m |
| Microphone mute | Mute/unmute, missing device/property, read-only control, lookup/read/write errors | runtime_test.m |
| Preferences | Defaults, save/readback, numeric bounds, invalid stored types, four-file limit, pause and checkbox actions | runtime_test.m |
| F12 editor / settings | Mode controls, URL rejection, text warning, save/cancel, duplicate/file-limit handling, selected-file removal, summaries, model text bounds, permission-request routing, drag-helper permission selection/cleanup, owner/System Settings window closure and launch grace, copy-only drag and multi-display positioning | runtime_test.m |
| Installer | Build/self-test/sign/verify failures, verified upgrade/new install, move/open failure rollback, check-only behavior, non-app refusal, Login Item failure/legacy preservation, staging cleanup | installer_test.py |
| Uninstaller | Existing/missing app, exact two Keyboard II mapping resets, legacy removal, unrelated-file preservation, argument rejection | installer_test.py |
| Updates / releases / Homebrew | Semantic version comparison, stable-only metadata validation, update errors/timeouts/size limits/reentrancy, canonical notes URL and copied upgrade command, deterministic archives, version/tag agreement, notes extraction and source checksum | update_test.m, runtime_test.m, release_test.py, homebrew_test.py, formula_test.rb |
| Real bundle build | App build, protocol self-test, Info.plist lint, ad-hoc code signing and signature verification in `--check` mode | install.sh --check |

## Safety and limits

- Runtime tests execute production functions but replace system boundaries in the
  test translation unit. Mouse/keyboard events, HID writes, audio changes, tasks,
  file/URL opening, and permission requests never reach the real system.
- Real AppKit controls/windows are constructed without presenting dialogs. The
  automated checks cover state, text and bounds, not a screenshot or usability.
- Test preferences use a random suite that is removed after success; the app's
  preference domain and global settings are not written. A crash may leave only
  that test suite behind.
- Installer tests redirect only private script copies to a temporary user tree;
  they do not replace HOME or run the real app, process-kill, Login Item, launchctl
  or hidutil commands. The production scripts themselves are not changed.
- Asynchronous action blocks run immediately in the runtime test. Scheduling,
  real callback timing and multi-device attribution are not proven by these tests.
- Tests use real CoreGraphics event objects. In particular, the BLE regression
  checks a 10-pixel scroll becomes 20 pixels at 2× and is not scaled a second
  time. This catches related-field setter interactions rather than mocking them.

## Still requires manual / physical verification

- USB and Bluetooth enumeration/report delivery, firmware settings, reconnect and
  sleep/wake behavior on each real model. Compact remains experimental.
- Simultaneous physical devices, timing-sensitive source attribution, actual
  acceleration/scroll feel and application-specific middle-button behavior.
- Actual macOS permissions, denied/reapproved TCC transitions, Login Items,
  hidutil effects, microphone hardware support and global system shortcuts.
- Real app/file/URL opening, text insertion into applications, screenshot UI,
  visual layout, keyboard navigation, VoiceOver and multiple macOS versions.
- Developer ID signing/notarization and privacy identity continuity during a
  real installed upgrade. Ad-hoc `--check` is only a local bundle validation.

Passing these tests establishes software behavior at intercepted boundaries;
it does not establish that every feature works on physical hardware.
