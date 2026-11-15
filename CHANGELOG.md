# Changelog

Version numbers follow MAJOR.MINOR.PATCH. `version.h` defines the app version and
monotonically increasing bundle build number. A stable release uses tag `vVERSION`.
Only published, non-prerelease GitHub Releases are offered as updates.

## Unreleased

### Fixed
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
