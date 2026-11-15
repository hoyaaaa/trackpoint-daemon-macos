# Changelog

Version numbers follow MAJOR.MINOR.PATCH. `version.h` defines the app version and
monotonically increasing bundle build number. A stable release uses tag `vVERSION`.
Only published, non-prerelease GitHub Releases are offered as updates.

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
