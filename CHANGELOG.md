# Changelog

Version numbers follow MAJOR.MINOR.PATCH. `version.h` defines the app version and
monotonically increasing bundle build number. A stable release uses tag `vVERSION`.
Only published, non-prerelease GitHub Releases are offered as updates.

## 2.7.0 — 2026-11-16

### Changed
- Remove the scroll-speed slider and ignore its previously saved value.
- Replace custom pixel scaling and pointer-motion acceleration with the observed
  Windows Preferred Scrolling delta policy: horizontal wheel steps and 80ms USB
  vertical batching. Keep native Bluetooth vertical wheels unchanged.
- Cancel pending scroll batches on release, disconnect, pause and wake. Document
  Windows-specific dispatch differences rather than claiming pixel-identical output.

## 2.6.2 — 2026-11-16

### Fixed
- Sign from the app launcher and updater after Homebrew exits. Homebrew isolates
  post-install as well as builds, so its hooks cannot use the login keychain.
- Verify an existing certificate-bound signature before rewriting the app, refuse
  to re-sign a running daemon, and never launch after a signing failure.

## 2.6.1 — 2026-11-16

### Fixed
- Pass the ad-hoc build override through `env` when Homebrew invokes the staged
  build. Formula commands do not accept Ruby's leading environment Hash.
- Make the formula smoke test reject that unsupported call format so it cannot
  pass locally while failing during a real Homebrew upgrade.

## 2.6.0 — 2026-11-16

### Changed
- Group settings into TrackPoint, Keyboard, Permissions and Supported Models
  tabs; move F12/remaps to Keyboard and scrolling/middle-click controls to TrackPoint.
- Align macOS integration group titles, body padding and control rows in a
  shared coordinate space; remove native NSBox insets from the Windows theme.
- Recreate the Windows Keyboard Properties theme using its original keyboard/F12
  images, blue title bar, rectangular controls and tabs. Add OK/Cancel/Apply
  checkpoints and match the F12 editor's original dimensions and field positions.

### Added
- Automatically create and reuse a dedicated local code-signing certificate in
  the login keychain for source/Homebrew builds; preserve existing keys and stop
  on keychain/signing errors without silently falling back to ad-hoc signing.
- Support a persistent local code-signing certificate pinned by fingerprint in
  `~/.config/trackpointd/signing-identity`, shared by Homebrew builds and the
  direct installer. Fail if an explicitly configured identity cannot be used,
  rather than silently replacing its identity with an ad-hoc signature.

## 2.5.2 — 2026-11-15

### Changed
- Render in-app release notes with styled headings, bullet/numbered lists,
  hanging indents, emphasis and code fonts instead of raw Markdown markers.
  Parse locally with native macOS support; keep upgrade/error logs as plain text
  and do not load remote images, HTML or active links.

## 2.5.1 — 2026-11-15

### Fixed
- Refresh only the official TrackPointD tap before in-app upgrades instead of
  running a global brew update. Preserve unrelated Homebrew repositories and
  refuse a modified tap, custom branch/source or local commits rather than
  overwriting them.

## 2.5.0 — 2026-11-15

### Added
- Show the latest GitHub Release patch notes inside the update dialog, including
  when the installed app is already up to date.
- Homebrew-installed apps can use Upgrade and Reopen directly, with a native
  progress/log window. Check formula availability and installed signature,
  version and self-test before restarting through the stable Homebrew path.
- Pause enhancements only for the duration of installation without saving that
  pause. Show errors and restore the enabled/paused state if an upgrade fails.

### Changed
- Replace Copy Upgrade Command with Upgrade and Reopen. Source installations
  retain the canonical release-page option; no new dependencies are required.

## 2.4.2 — 2026-11-15

### Fixed
- Close the permission helper when the TrackPointD settings window or the macOS
  settings window closes, including when System Settings quits in the background.
- Explain how to replace an older TrackPointD permission entry after an ad-hoc
  upgrade. An enabled switch for an old signature does not authorize the new app;
  permission labels continue to reflect the OS access check.

## 2.4.1 — 2026-11-15

### Changed
- Center the draggable permission helper below System Settings instead of beside
  it, keeping the helper on screen when there is not enough room underneath.

## 2.4.0 — 2026-11-15

### Added
- A floating permission helper exposes the running TrackPointD.app as a draggable
  icon beside System Settings, with Show in Finder as a fallback. It follows
  the settings window and closes after the selected permission is granted.
- Both permission buttons open the matching settings pane after requesting access.
  Permission approval remains manual; ad-hoc upgrades can require approval again.

## 2.3.2 — 2026-11-15

### Changed
- Replace the app icon with a borderless dark terminal shape and centered
  TrackPoint-red circle. Share the menu bar's exact 16:12 body ratio, 5-unit
  circle diameter and sRGB red (#E2231A); square app assets use transparent
  padding instead of stretching the icon. Remove the menu icon's thin outline.

## 2.3.1 — 2026-11-15

### Fixed
- Query interface report capabilities before sending hardware settings; do not
  send pointer configuration to USB keyboard or vendor-only interfaces.
- Sensitivity status now reflects interfaces with confirmed pointer input rather
  than treating configuration rejection by a USB keyboard's non-pointer
  interfaces as a global fallback. Mixed pointer devices are labeled separately;
  unconfirmed input is shown as awaiting verification.

## 2.3.0 — 2026-11-15

### Added
- Experimental detection and software sensitivity for the ThinkPad Compact Bluetooth
  Keyboard with TrackPoint (17EF:6048); physical-hardware verification is still needed.
- Optional middle-click blocking while preserving TrackPoint scrolling.
- Supported Models settings tab, verification warnings and hardware test requests.
- Automated protocol/runtime/settings/installer tests and required macOS CI.
- In-app latest-release checks, release notes and Homebrew upgrade instructions.
- Versioned release preparation and Homebrew source-build packaging.

### Fixed
- Keyboard II hardware sensitivity no longer disables Compact's software fallback
  just because both models are connected.
- BLE scroll-speed changes snapshot linked scroll fields to avoid repeated scaling.

### Verification limits
- Compact and simultaneous physical-device behavior remain unverified.
- Source builds use local/ad-hoc signing; privacy permissions may need approval
  again after an upgrade. No notarized prebuilt application is distributed.

## 2.2.1 — Historical baseline

This was the version embedded in the installer before versioned GitHub Releases
were introduced. It is not a previously published GitHub Release.
