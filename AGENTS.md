# AGENTS.md — TrackPointD for macOS

## Scope

Single-file Objective-C menu bar app for the ThinkPad TrackPoint Keyboard II.
Keep it dependency-free and compatible with macOS 12+.

Supported hardware (exact matching only):

- VID `0x17EF`, USB receiver PID `0x60EE`
- VID `0x17EF`, Bluetooth LE PID `0x60E1`
- Experimental: VID `0x17EF`, Compact Bluetooth PID `0x6048`; physical-hardware
  verification pending. No hardware configuration, hotkeys or key remaps for this model.

Do not broaden matching to every Lenovo device.

## Architecture

```text
IOHIDManager (exact VID/PID)
  ├─ IOHIDDeviceSetReport → speed, Fn Lock, Preferred Scrolling
  ├─ manager-owned input reports → wheel, deferred middle click, Lenovo hotkeys/F12
  └─ manager-owned exact-device X/Y values → origin confirmation

hidutil --matching → device-only modifier/F18 remaps

one kCGHIDEventTap → compatibility scroll fallback and software speed fallback
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
- Register manager callbacks before scheduling/opening it. Do not double-open,
  double-schedule, or create a second input queue for a matched device.
- Resolve a value callback's device through `IOHIDElementGetDevice()`; older
  IOKit versions pass their internal queue as that callback's `sender`.
- Do not write global mouse defaults or global acceleration properties.
- Do not clear global `UserKeyMapping`; always use exact `hidutil --matching`.
- Treat absent `com.apple.swipescrolldirection` as natural scrolling enabled.

## Windows parity boundaries

Real Keyboard II Windows settings are hardware speed, Preferred Scrolling, and
F12 user action. Fn Lock is firmware. Modifier swaps, F18, natural direction,
and scroll-speed tuning are macOS additions. Keyboard II exposes no pressure/Z
signal or native Press-to-Select command; do not emulate it from X/Y movement.

## Build and verify

Every feature addition or behavior change, including a bug fix, must include
new or extended automated test code. Bug fixes need a regression test that fails
before the fix and passes afterward. Existing passing CI without coverage of the
changed behavior is insufficient. Do not weaken or skip tests to make CI pass.
See `CONTRIBUTING.md` and `tests/README.md`.

Run the full required suite before submitting or updating a PR:

```bash
bash scripts/test.sh
```

The latest `macOS tests` CI check must pass before any merge into main, including
maintainer merges. Tests must isolate preferences/files and intercept real input,
device writes, system commands, audio changes and permission prompts.

The installer must build and verify a staged bundle before replacing the live
app. Do not reset privacy permissions automatically.

## Source hygiene

Lenovo's Windows binaries are proprietary. Linux `hid-lenovo.c` is
GPL-2.0-or-later. Use public protocol facts and independent code; do not paste
decompiled Lenovo or GPL implementation code into this MIT repository. Do not
add `Co-Authored-By:` lines to commits.
