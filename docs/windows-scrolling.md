# Preferred Scrolling: Windows policy and macOS mapping

## Evidence

The reference is Lenovo's official ThinkPad TrackPoint Keyboard II Windows
package 1.0.8.06241, not an assumed acceleration curve. Its source is not public.
The official binary was inspected locally to establish protocol/behavior facts;
no Windows executable, disassembly or vendor source code is distributed.

- Installer SHA-256: `d14fc7c06306db52fb9c0b01b50efdba0b89dfdae6f75d9ff22bf5198189b3c5`.
- `HScrollFun.exe` SHA-256: `e5cefef96e33e5e3c4a8be9d90b8852fb4a8dc6a340d728d408a2bc88d7cf2c9`.
- Raw Input handling matches Lenovo `17EF:60EE` and `17EF:60E1`, report `0x16`.
- Horizontal handling uses one positive/negative wheel step per accepted report.
- The vertical timer interval is 80ms. Its normal desktop message path multiplies
  the accumulated signed report count (including accepted horizontal reports)
  by the most recent vertical magnitude,
  then clears the batch. It does not use our former user multiplier or power curve.
- `mouse_event` uses a Windows wheel notch of 120, as documented by
  [Microsoft](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-mouse_event).

Observed accepted byte magnitudes:

| Raw byte | Vertical magnitude/direction | Horizontal step |
|---|---:|---:|
| `01` … `07` | +1 … +7 | +1 |
| `FF` | -1 | -1 |
| `FE` … `F9` | -1 … -6 | -1 |

The negative mapping is the observed Windows behavior, not an assumption that
all payloads are conventional signed integer deltas. Neutral, unsupported and
simultaneous two-axis vendor payloads do not produce synthetic wheel events.

## Independent macOS implementation

`scrolling.h` implements these input/batch decisions independently. Each keyboard
has its own batch; no connected device can contribute another device's count.
USB and Bluetooth start an 80ms timer on middle-down (or the first wheel report if that
edge was unavailable). Horizontal steps are emitted immediately. Releasing the
button, detaching, pausing or resetting after wake cancels queued work.

Bluetooth already produces OS vertical wheel input. For a native event whose
original HID sender is the exact matched BLE device (or its registry descendant),
TrackPointD suppresses that event and feeds its unaccelerated HID vertical delta
into the same 80ms Windows batch. Vendor report vertical data is never fed again.
Horizontal vendor reports still emit immediate steps and contribute to that
keyboard's batch count, as on USB. No timestamps or last-active-device guesses
are used to attribute wheel input.

The original HID sender/delta uses optional system SPI (`CGEventCopyIOHIDEvent`,
`IOHIDEventGetSenderID`, `IOHIDEventGetFloatValue`), resolved dynamically rather
than adding a dependency. Apple lists the sender and raw-scroll field signatures
in [WebKit's IOKit SPI declarations](https://github.com/WebKit/WebKit/blob/main/Source/WebCore/PAL/pal/spi/mac/IOKitSPIMac.h);
the [HID scroll-report handler](https://github.com/apple-oss-distributions/IOHIDFamily/blob/main/IOHIDFamily/IOHIDEventDriver.cpp)
provides the unaccelerated wheel delta used here. These are not public Apple API contracts. If they are
unavailable, the sender cannot be resolved, or the raw payload is unsupported,
the native event passes through without synthetic vertical output for that event.
This fallback preserves input and prevents duplicate delivery; it does not claim
Windows batching on an unsupported system. Other mice, trackpads and synthetic
wheel events with no matching HID source are left unchanged.

Both synthetic paths post standard Quartz **line** events downstream of the HID
tap. There is no speed slider, `tpScrollSpeed` runtime setting, power acceleration,
or conversion of ordinary pointer X/Y movement into scroll events. An old saved
speed value is left in preferences but is ignored and is no longer registered.

## Platform boundary

This reproduces the observed normal Windows desktop input/batch policy, not every
Win32 application workaround. The Windows binary also selects `WM_MOUSEWHEEL`,
`WM_MOUSEHWHEEL`, scrollbar/key-message paths and special injection behavior for
`Windows.UI.Core.CoreWindow` / `ApplicationFrameWindow`. Those Windows window
classes and message mechanisms do not exist in macOS; Quartz wheel delivery is
used instead. The original global cross-axis state is not shared across devices.

A Windows notch and a Quartz line are different OS units. Rendering distance,
OS scroll preferences and application behavior can therefore differ even when
input deltas and batch decisions agree. The macOS driver remains in place; only
identified BLE vertical events are replaced downstream.

## Verification

`tests/scroll_test.m` exhaustively checks all 256 input byte values, direction,
batching, cancellation, invalid payloads and numeric bounds. Runtime tests cover
80ms scheduling, output event units, BLE native replacement without counting its
vendor report twice, unchanged simultaneous other-mouse input, separate keyboard
batches, optional-SPI/source failure fallback, all 256 BLE raw byte values, middle-button
release, detach/wake/pause resets, removal of the speed UI and ignoring old speed
preferences. Windows-only window-message routing is outside the macOS tests.
