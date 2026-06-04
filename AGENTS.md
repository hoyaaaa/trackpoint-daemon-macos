# AGENTS.md — TrackPoint Daemon for macOS

## Project Overview

Single-file macOS menu bar daemon (`trackpointd.m`) that makes the ThinkPad TrackPoint Keyboard II behave like it does on Windows. Compiled with Clang into a `.app` bundle and registered as a Login Item.

## Architecture

```
IOHIDManager ──► device added/removed callbacks
                     │
                     ▼
              set_tap_enabled(true/false)
                     │
                     ▼
         CGEventTap (kCGHIDEventTap, unified_callback)
              │            │             │
        key remap     middle-btn      pointer scaling
       (F18, Cmd↔Opt)  scroll mode   + sigmoid accel
```

All event interception happens in a **single** `CGEventTap` at `kCGHIDEventTap` (earliest pipeline level, before the cursor moves). This is intentional — using multiple taps at different levels causes state desync and cursor freeze.

## Key Decisions

### Single unified tap at kCGHIDEventTap
Earlier versions used separate taps for scrolling vs. pointer scaling. This caused the cursor to freeze after releasing the middle button because move events stopped reaching one of the taps while `s_middleDown` was true. Merging all handlers into one tap fixed it.

### s_middleDown state
Middle button state is tracked via global `s_middleDown`. `CGEventSourceButtonState` was tried but doesn't work reliably for BLE keyboards — the Lenovo keyboard's button state is not reflected in `kCGEventSourceStateHIDSystemState`. Stick with `s_middleDown`.

### Natural scroll detection
`[[NSUserDefaults standardUserDefaults] objectForKey:@"com.apple.swipescrolldirection"]`
Returns `nil` when the key has never been set — macOS default is natural scroll **ON**, so `nil` must be treated as `true`. Using `boolForKey:` (returns `false` for absent keys) gives the wrong default.

### Scroll direction sign
`CGEventCreateScrollWheelEvent` positive `wheel1` = content scrolls down. `dy < 0` when stick moves up (natural up). So: natural scroll OFF → `sign = 1`, natural scroll ON → `sign = -1`.

### Acceleration curve
`accel = 1.0 + 1.5 * (1.0 - exp(-speed / 3.0))` — sigmoid shape, 1.0x at rest, ~2.5x at high speed. Applied on top of the pointer sensitivity factor.

### pollAccess timer
The accessibility permission poller (`pollAccess:`) must call `try_create_event_tap()` **directly** before calling `[self refresh]`. If `self.accessTimer` is set to `nil` first and then `refresh` is called, the refresh method's guard `accessible && self.accessTimer == nil && s_tap == NULL` will be false and the tap never gets created.

### Accessibility permission resets on recompile
`codesign` with a new ad-hoc signature invalidates the TCC entry. `tccutil reset Accessibility com.user.trackpointd` is called automatically by `install.sh`. The user must re-grant in **System Settings → Privacy & Security → Accessibility**.

## File Layout

```
trackpoint/
├── trackpointd.m     # Full source (Objective-C, single file)
├── install.sh        # Compile → bundle → Login Item → launch
├── uninstall.sh      # Remove Login Item, kill process
├── TrackPointD.icns  # Menu bar icon source
├── README.md
└── AGENTS.md         # This file
```

## Building

```bash
bash install.sh
```

Manual compile (no bundling):
```bash
clang -O2 -fobjc-arc -o /tmp/trackpointd trackpointd.m \
  -framework Cocoa \
  -framework ApplicationServices \
  -framework IOKit \
  -lm
```

## Debugging

```bash
tail -f /tmp/trackpointd.log
```

Key log lines to look for:
- `[tp] EventTap ON` — tap enabled (ThinkPad connected)
- `[tp] middle DOWN` — middle button captured correctly
- `[tp] scroll dy=...` — scroll events firing
- `[tp] EventTap DISABLED BY TIMEOUT — re-enabling` — tap timed out; auto-re-enabled

If scroll fires but cursor doesn't move after release: check whether `middle UP (moved=yes)` appears. If not, `OtherMouseUp` is not reaching the tap.

## Settings (persisted via NSUserDefaults)

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `f18Enabled` | Bool | true | Remap Right Option → F18 |
| `swapModifiers` | Bool | true | Left Opt ↔ Left Cmd via hidutil |
| `sensitivity` | Int | 5 | Pointer sensitivity 1–9 |
| `scrollSpeed` | Float | 3.5 | Scroll speed multiplier 1.0–8.0 |

## What NOT to change

- **Do not split the unified tap** into separate taps per feature. This was tried and caused cursor freeze.
- **Do not use `CGEventSourceButtonState`** to detect middle button state. It doesn't work for BLE.
- **Do not use `boolForKey:` for natural scroll detection**. Use `objectForKey:` and treat `nil` as `true`.
- **Do not add `Co-Authored-By:` lines** to commit messages.
