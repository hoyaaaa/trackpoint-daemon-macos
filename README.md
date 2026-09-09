# TrackPointD for macOS

A native menu bar companion for the Lenovo ThinkPad TrackPoint Keyboard II. It
implements the useful parts of Lenovo's Windows control-panel software without
drivers or third-party dependencies.

## Version 2 highlights

- Rebuilds the settings window around Lenovo's Windows layout: an
  `External TrackPoint Keyboard` page plus the original F12 `Modify…` flow.
- Separates macOS permissions and platform-specific extras into a dedicated
  `macOS Integration` page so they are not presented as Lenovo features.
- Sends the keyboard's real hardware speed setting instead of pretending with
  a made-up acceleration curve.
- Supports both official transports: USB receiver `17EF:60EE` and Bluetooth LE
  `17EF:60E1`.
- Adds the Windows `ThinkPad Preferred Scrolling` switch and parses the native
  horizontal/vertical wheel reports.
- Adds the Windows F12 star-key actions: open up to four files/apps, open a web
  site, or type saved text.
- Adds Fn Lock control and reapplies keyboard settings after reconnect or wake.
- Maps the confirmed F4 and F8 vendor reports to default-input microphone mute
  and macOS Notification Center.
- Moves both modifier remaps to exact-device `hidutil` rules. Other keyboards
  and the user's global remaps are no longer touched.
- Removes all global mouse acceleration/defaults changes.
- Fixes the recursive middle-click event loop, event-tap state recovery, and
  exact-device input delivery.
- Replaces the in-place installer with build, self-test, sign, verify, then a
  staged replacement with rollback.

## Settings UI

Click the white keyboard icon in the menu bar, then **Settings…**. Its center
dot is red when connected, orange when attention is required, and dark gray
when the keyboard is disconnected.

Use **Try 1** and **Try 9** beside Pointer speed for an obvious slow/fast
comparison. The status below the slider says whether the level was applied to
the keyboard or saved for its next connection. **TrackPointD Enabled** in the
menu pauses remaps, shortcuts, and scrolling enhancements while leaving basic
pointer input available. Scroll speed affects both axes on USB and Bluetooth;
the default position preserves macOS's existing Bluetooth vertical speed.

The first tab follows Lenovo's Windows `Keyboard Properties → External
TrackPoint Keyboard` page: keyboard graphic, nine-position `Slow`–`Fast`
slider, Preferred Scrolling, and an F12 action summary with **Modify…**. The
F12 editor mirrors the Windows mode picker and its files list with Add/Remove,
URL field, text field, and OK/Cancel flow. Lenovo's proprietary artwork is not
copied; the keyboard graphic is drawn from a macOS system symbol.

The second tab contains the two required macOS permissions and all macOS-only
options. When access has not been requested, **Request Access…** invokes
Apple's native permission API and registers TrackPointD. The macOS prompt can
then open the matching System Settings pane; only the user can approve the
final switch. After a denial or approval, the button becomes **Open Settings…**.

| Setting | What it does | Origin |
|---|---|---|
| Pointer Sensitivity | Hardware level 1–9, default 5 | Lenovo Windows parity |
| ThinkPad Preferred Scrolling | Middle button + stick, vertical and horizontal | Lenovo Windows parity |
| User Defined Key (F12 ★) | Files/apps, HTTP(S) URL, text, or disabled | Lenovo Windows parity |
| Fn Lock | Standard F1–F12 vs. icon actions | Keyboard firmware |
| Right Option → F18 | Convenient macOS input-source shortcut | macOS adaptation |
| Left Opt ↔ Left Cmd | Mac-style physical modifier order | macOS adaptation |
| Scroll Speed | Vertical and horizontal TrackPoint scrolling on USB and Bluetooth | macOS adaptation |

Saved text is stored in macOS user defaults as plain text. Do not put passwords
or sensitive personal information in the F12 text action.

## What Lenovo's Windows program actually provides

Lenovo's public package is version `1.0.8.06241` (2021-08-17). Its Control
Panel page, **External TrackPoint Keyboard**, exposes exactly three user-facing
settings:

1. Pointer speed: nine positions, internal value 0–8, default 4. The device
   receives 1–9, default 5.
2. ThinkPad Preferred Scrolling: on by default.
3. F12 user-defined action: open files/apps, open a web site, or enter text.

The package has no published source. Inspection of Lenovo's official installer
(`SHA-256 d14fc7c06306db52fb9c0b01b50efdba0b89dfdae6f75d9ff22bf5198189b3c5`)
shows a user-space stack rather than a custom kernel driver:

| Windows component | Role established from the package |
|---|---|
| `ADDPage.dll` | External TrackPoint Keyboard Control Panel UI |
| `SetSpeed.exe` + `fsHid*.dll` | HID configuration reports |
| `HScrollFun.exe` | Raw Input vertical/horizontal scrolling |
| `HKF12.exe` | F12 files/apps, URL, and text actions |
| `osd.exe` + `ExternalTPKBSvc.exe` | Hotkeys, OSD, and settings reapply |

| Windows behavior | macOS status |
|---|---|
| Hardware pointer speed 1–9 | Implemented over USB and BLE |
| Preferred vertical/horizontal scrolling | Implemented with native reports plus compatibility fallback |
| Middle click when no scroll occurred | Implemented with deferred click, matching the Linux state machine |
| F12 files/apps, URL, text | Implemented; up to four files/apps |
| Fn+Esc / Fn Lock | Implemented and persisted |
| F9 Settings, F10 Bluetooth, F11 keyboard settings | Adapted to the equivalent macOS panes/UI |
| Fn+PrtSc snipping tool | Adapted to macOS interactive screenshot |
| Volume and brightness keys/OSD | Handled by macOS when the host exposes the standard usages |
| F4 microphone mute | Toggles the current default input through CoreAudio when that device exposes a writable mute control |
| F8 Action Center | Adapted to macOS Notification Center using the documented Fn-N shortcut |
| F7 external-display management; SysRq/Break/Scroll Lock/Pause | Not emulated; no stable exact macOS equivalent |
| Fn+4 sleep | Standard HID System Sleep report is left to macOS; no duplicate event is synthesized |
| Swift Pair | Windows-only; use normal macOS Bluetooth pairing |
| Pairing mode, LEDs, six-key assistive input | Keyboard firmware; no daemon implementation needed |

So the Windows control panel's three configurable features are all present,
but the complete Windows experience is not a 100% clone. Windows-only OS
integrations and Lenovo OSD behavior remain intentionally outside the parity
claim.

Natural scrolling, modifier swaps, F18, and adjustable scroll speed are useful
macOS additions, not Lenovo Windows features. Press-to-Select is deliberately
not included: Keyboard II exposes no pressure/Z signal or native command, so
ordinary pointer movement cannot be distinguished reliably from a press.

## Requirements

- macOS 12 or newer
- ThinkPad TrackPoint Keyboard II:
  - USB receiver: VID `0x17EF`, PID `0x60EE`
  - Bluetooth LE: VID `0x17EF`, PID `0x60E1`
- Xcode Command Line Tools (`xcode-select --install`)
- Accessibility and Input Monitoring permission for TrackPointD

Other Lenovo devices no longer activate the daemon.

## Install or upgrade

```bash
git clone https://github.com/hoyaaaa/trackpoint-daemon-macos.git
cd trackpoint-daemon-macos
bash install.sh --check   # build and verify without installing
bash install.sh
```

The installer prefers an available Developer ID Application or Apple
Development signing identity so macOS recognizes upgrades as the same app and
keeps privacy approvals. Later upgrades reuse the installed app's signer when
that identity is still available. If no stable identity is available it falls
back to ad-hoc signing; macOS may then require both permissions again after an
upgrade. Set `TRACKPOINTD_SIGN_IDENTITY=-` to force ad-hoc signing, or set it
to a specific local code-signing identity.

This script is for building on the Mac that will run the app. A prebuilt app
for public GitHub Releases must additionally use a Developer ID Application
certificate, hardened runtime, Apple notarization, and stapling in the release
pipeline; a local Apple Development signature is not a public distribution
signature.

The installer builds a separate app, runs its protocol self-test, signs and
verifies it, and only then replaces the installed copy. A failed upgrade rolls
back to the previous app.

Grant both permissions:

1. **System Settings → Privacy & Security → Accessibility → TrackPointD**
2. **System Settings → Privacy & Security → Input Monitoring → TrackPointD**

If an existing permission stops working after a new build, toggle TrackPointD
off and on in that pane. The installer does not erase TCC permissions.

Karabiner-Elements cannot modify this keyboard at the same time as TrackPointD:
its **Modify events** mode takes exclusive ownership, so TrackPointD cannot
confirm TrackPoint movement. In Karabiner-Elements → **Devices**, turn off
**Modify events** for **TrackPoint Keyboard II**. TrackPointD supplies its own
device-only modifier remaps; other keyboards can remain enabled in Karabiner.
If the dot remains orange after moving the stick, quit and reopen TrackPointD
once.

## Uninstall

```bash
bash uninstall.sh
```

Uninstall removes the app, Login Item, legacy LaunchAgent, and the per-device
key-mapping property for the two TrackPoint Keyboard II IDs. If you manually
added other `hidutil` mappings to those exact IDs, reapply them afterward. No
other keyboard, global mouse setting, or privacy permission is changed.

## How it works

| Feature | Mechanism |
|---|---|
| Device detection | `IOHIDManager`, exact VID/PID matching |
| Hardware settings | `IOHIDDeviceSetReport` on attach, change, reconnect, and wake |
| Preferred scrolling | Report `0x16` on both transports; BLE standard vertical + vendor horizontal; fallback if needed |
| Middle click | Hold pending; emit click only if no wheel report/movement occurred |
| F12 and Lenovo hotkeys | Exact-device input-report callback |
| Key remaps | `hidutil --matching` for this model only |
| Pointer-origin confirmation | Manager-owned exact-device X/Y callback; no secondary HID queue |
| Software sensitivity fallback | One `kCGHIDEventTap`, fail-closed origin filter |

Configuration reports, independently reconstructed from public protocol facts:

| Transport | Report | Bytes |
|---|---|---|
| USB `60EE` | Feature report `0x13`, 8 bytes | `13 command value 00 00 00 00 00` |
| BLE `60E1` | Output report `0x18`, 3 bytes | `18 command value` |

Commands: `0x02` hardware speed, `0x05` Fn Lock, `0x09` Preferred Scrolling.
The undocumented Windows initialization command is deliberately not sent.

The native wheel input report ID is `0x16` (22 decimal) on both USB and BLE.
BLE additionally sends standard vertical-wheel input. TrackPointD scales that
existing event and synthesizes only the vendor horizontal value, avoiding
double vertical scrolling.
Hotkey report `0x05` is 2 bytes over USB and 3 bytes over BLE; the BLE-only
middle-button report `0x15` is 9 bytes. All lengths and embedded IDs are checked
before a report is used.

## Build check

```bash
clang -O2 -fobjc-arc -mmacosx-version-min=12.0 \
  -o /tmp/trackpointd trackpointd.m \
  -framework Cocoa -framework ApplicationServices -framework CoreAudio \
  -framework IOKit -lm
/tmp/trackpointd --self-test
```

## Research sources and licensing

- [Lenovo Windows download page](https://support.lenovo.com/us/en/downloads/ds543713-thinkpad-trackpoint-keyboard-ii-software-for-windows-7-windows-10)
- [Official English user guide](https://download.lenovo.com/consumer/options/trackpoint_keyboard_II_user_guide_en.pdf)
- [Official Korean user guide](https://download.lenovo.com/consumer/options/trackpoint_keyboard_II_user_guide_ko.pdf)
- [Linux `hid-lenovo.c`](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-lenovo.c)
- [Linux Keyboard II support commit](https://github.com/torvalds/linux/commit/24401f291dcc4f2c18b9e2f65763cbaadc7a1528)
- [USB capture and descriptor from the Linux support report](https://gitlab.freedesktop.org/libinput/libinput/-/issues/547#note_1104344)
- [Linux resume/reapply fix](https://github.com/torvalds/linux/commit/2f2bd7cbd1d1)
- [tp2ctl protocol captures](https://github.com/telecastr/tp2ctl)
- [Karabiner-Elements input-grabbing architecture](https://github.com/pqrs-org/Karabiner-Elements/blob/main/DEVELOPMENT.md)

The Lenovo binaries are proprietary and are not copied or redistributed. Linux
is GPL-2.0-or-later; this MIT project uses protocol facts and an independent
implementation, not copied Linux source. Repositories without a clear license
were treated as behavioral references only.

## License

MIT © [hoyaaaa](https://github.com/hoyaaaa)
