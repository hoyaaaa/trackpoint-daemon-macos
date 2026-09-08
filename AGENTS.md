# AGENTS.md — TrackPointD for macOS

## Scope

Single-file Objective-C menu bar app for the ThinkPad TrackPoint Keyboard II.
Keep it dependency-free and compatible with macOS 12+.

Supported hardware only:

- VID `0x17EF`, USB receiver PID `0x60EE`
- VID `0x17EF`, Bluetooth LE PID `0x60E1`

Do not broaden matching to every Lenovo device.

## Architecture

```text
IOHIDManager (exact VID/PID)
  ├─ IOHIDDeviceSetReport → speed, Fn Lock, Preferred Scrolling
  ├─ native input reports → wheel, deferred middle click, Lenovo hotkeys/F12
  └─ one queue per device → origin confirmation

hidutil --matching → device-only modifier/F18 remaps

one kCGHIDEventTap → compatibility scroll fallback, software speed fallback, PTS
```

## Protocol contract

| Transport | Config report |
|---|---|
| USB `60EE` | Feature `0x13`, 8 bytes: `13 command value 00 00 00 00 00` |
| BLE `60E1` | Output `0x18`, 3 bytes: `18 command value` |

- `0x02`: speed 1–9
- `0x05`: Fn Lock, 0/1
- `0x09`: Preferred Scrolling, 0/1
- Native wheel input uses report ID `0x16` (22 decimal) on both USB and BLE.
- Hotkey input `0x05` is 2 bytes on USB and 3 bytes on BLE; BLE native middle
  input `0x15` is 9 bytes. Validate exact lengths and the embedded report ID.

Never send `01 03`; that is for an older Compact keyboard and breaks Keyboard
II Fn+Esc behavior. Do not add undocumented initialization packets without real
hardware evidence.

## Invariants

- Hardware speed and software speed must never multiply. Software scaling is a
  fallback only when the HID setting fails.
- Native middle-down is held. A wheel report marks scrolling; a middle-up with
  no scroll emits one downstream middle click.
- BLE already emits a standard vertical wheel event. Do not synthesize its raw
  vertical value again; use the vendor report only for horizontal scrolling.
- Synthetic clicks/scrolls go to `kCGSessionEventTap`, downstream of the HID
  tap. Never post them back to `kCGHIDEventTap` and recurse.
- Unknown event origin fails closed. The one exception is an already-consumed,
  exact-device compatibility middle gesture: swallow unattributed moves until
  its release rather than leaking an orphan drag to applications.
- Each physical IOHID device owns its queue, report buffer, and timestamps.
- Cancel and release every PTS timer on replacement, disconnect, timeout, and
  termination.
- Do not write global mouse defaults or global acceleration properties.
- Do not clear global `UserKeyMapping`; always use exact `hidutil --matching`.
- Treat absent `com.apple.swipescrolldirection` as natural scrolling enabled.

## Windows parity boundaries

Real Keyboard II Windows settings are hardware speed, Preferred Scrolling, and
F12 user action. Fn Lock is firmware. Modifier swaps, F18, natural direction,
scroll-speed tuning, and legacy Press-to-Select are macOS additions. Do not call
the old sigmoid curve or Keyboard II Press-to-Select “Windows parity.”

## Build and verify

```bash
clang -O2 -fobjc-arc -mmacosx-version-min=12.0 \
  -o /tmp/trackpointd trackpointd.m \
  -framework Cocoa -framework ApplicationServices -framework IOKit -lm
/tmp/trackpointd --self-test
bash -n install.sh
bash -n uninstall.sh
```

The installer must build and verify a staged bundle before replacing the live
app. Do not reset privacy permissions automatically.

## Source hygiene

Lenovo's Windows binaries are proprietary. Linux `hid-lenovo.c` is
GPL-2.0-or-later. Use public protocol facts and independent code; do not paste
decompiled Lenovo or GPL implementation code into this MIT repository. Do not
add `Co-Authored-By:` lines to commits.
