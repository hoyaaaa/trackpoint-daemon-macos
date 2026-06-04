# trackpoint-daemon-macos

A lightweight macOS menu bar app that makes the ThinkPad TrackPoint Keyboard II work like it does on Windows.

## Features

- **Middle button scroll** — Hold middle button and move the TrackPoint to scroll (non-linear curve, sub-threshold accumulation)
- **Scroll direction** — Auto-detects macOS natural scroll setting and matches it
- **Right Option → F18** — Remap Right Option to F18 for input source switching
- **Left Opt ↔ Left Cmd swap** — Fix reversed modifier key layout on the Windows-designed keyboard
- **Pointer sensitivity** — Adjustable 1–9 via settings (BLE-compatible software scaling)
- **Scroll speed** — Adjustable 1.0–8.0 via settings
- **Mouse acceleration disabled** — Linear pointer movement while TrackPoint is connected; restored on disconnect
- **Auto-activate on connect** — All remaps apply when ThinkPad connects, revert on disconnect

## Why F18?

macOS uses a keyboard shortcut to switch input sources (e.g. English ↔ Korean). The Right Option key on the ThinkPad keyboard is inconvenient for this. By remapping it to F18, you can assign a clean, conflict-free shortcut:

**System Settings → Keyboard → Keyboard Shortcuts → Input Sources → Select the previous input source → press F18**

F18 is a safe choice because no app uses it by default.

## Why Left Opt ↔ Left Cmd swap?

The ThinkPad TrackPoint Keyboard II is designed for Windows, where the key order (left to right) is:

```
Ctrl  |  Win  |  Alt  |  Space  ...
```

On macOS the expected order is:

```
Ctrl  |  Option  |  Command  |  Space  ...
```

The physical keys are swapped compared to macOS convention. This setting corrects the layout so muscle memory from a MacBook keyboard works correctly.

## Requirements

- macOS 12+
- ThinkPad TrackPoint Keyboard II (VID `0x17EF`)
- Xcode Command Line Tools (`xcode-select --install`)

## Install

```bash
git clone https://github.com/hoyaaaa/trackpoint-daemon-macos.git
cd trackpoint-daemon-macos
bash install.sh
```

Grant **Accessibility** permission when prompted:
**System Settings → Privacy & Security → Accessibility → TrackPointD ✓**

> If you recompile from source, the code signature changes and macOS invalidates the permission — you must re-grant it.

## Uninstall

```bash
bash uninstall.sh
```

## Settings

Click the menu bar icon (`TP+` when connected, `TP-` when not, `TP!` if accessibility not granted) → **Settings...**

| Setting | Description |
|---|---|
| Right Option → F18 | Remap Right Option key to F18 |
| Left Opt ↔ Left Cmd Swap | Fix modifier key order for macOS layout |
| Pointer Sensitivity | 1 (slow) – 9 (fast), default 5. Applied in software, works over BLE. |
| Scroll Speed | 1.0 (slow) – 8.0 (fast), default 3.5. |
| Press-to-Select | Tap the TrackPoint stick briefly → left click. Off by default. |

## How it works

| Feature | Mechanism |
|---|---|
| Middle button scroll | Unified `CGEventTap` at `kCGHIDEventTap` (earliest level) |
| Scroll direction | Reads `com.apple.swipescrolldirection` from NSUserDefaults |
| Right Option → F18 | `CGEventTap` (HID level, no delay) |
| Left Opt ↔ Left Cmd swap | `hidutil` kernel-level key remap |
| Pointer sensitivity | `CGEventSetLocation` delta scaling (HID level) |
| Acceleration removal | `IOHIDSetMouseAcceleration(-1.0)` on connect, restored on disconnect |
| Device detection | `IOHIDManager` matching Lenovo VID `0x17EF` |

## Windows parity

| Behavior | Status |
|---|---|
| Middle button scroll | ✓ |
| Scroll direction (matches system setting) | ✓ |
| Key remapping (Opt↔Cmd, Right Opt→F18) | ✓ |
| Pointer sensitivity (1–9 scale) | ✓ (software scaling, not hardware) |
| Scroll speed adjustment | ✓ |
| Non-linear scroll curve | ✓ (approximate) |
| Acceleration curve | ✓ (sigmoid 1.0x–2.5x, approximate) |
| Press-to-select | ✓ (tap stick → left click; enable in Settings) |

## License

MIT © [hoyaaaa](https://github.com/hoyaaaa)
