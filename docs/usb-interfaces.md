# Keyboard II USB interface investigation

Observed on a physical USB receiver `17EF:60EE` on 2026-11-15. These are logical
interfaces of one receiver, not additional physical keyboards or mice.

| Interface | Primary usage | Advertised reports relevant here | TrackPointD action |
|---|---|---|---|
| Keyboard | Generic Desktop / Keyboard (`0001:0006`) | Input `00`: 8 bytes; Output `00`: 1 byte | Standard typing/remaps; no feature `13` writes |
| Pointer and controls | Generic Desktop / Mouse (`0001:0002`) | Feature `13`: 8 bytes; Input `05`: 2 bytes; Input `16`: 3 bytes | Hardware configuration, hotkeys and scrolling |
| Vendor-only | Vendor page / usage (`FF00:0005`) | Feature `04`: 32 bytes including report ID; no normal input report | No configuration writes or invented feature |

The vendor-only descriptor read from the receiver is:

```text
06 00 ff 09 05 a1 01 85 04 19 00 2a ff 00 15 00 26 ff 00 75 08 95 1f b1 02 c0
```

It declares a 31-byte vendor-defined Feature payload plus report ID `04`.
It does not describe what commands or response fields mean. A vendor-defined
usage alone is not evidence of battery status, firmware flashing, pairing, or an
unimplemented user-facing feature. The exact semantics remain undocumented in
the sources checked; TrackPointD neither sends guesses nor reads unknown data
from that channel.

## Evidence and boundaries

- The physical receiver's report descriptors were read from IORegistry. An
  independent read-only IOKit probe using `IOHIDDeviceCopyMatchingElements`
  confirmed that only the pointer interface advertises Feature `13`; only the
  vendor interface advertises Feature `04`. No report was sent by that probe.
- [Apple's element-query API](https://developer.apple.com/documentation/iokit/1588671-iohiddevicecopymatchingelements)
  supports querying the exact report ID and element type before a write.
- [Linux's Lenovo driver](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-lenovo.c)
  configures Keyboard II USB with Feature `13`; BLE uses Output `18`.
- [tp2ctl's original configuration tool](https://github.com/telecastr/tp2ctl/blob/main/src/tp2ctl/tp2ctl.py)
  targets USB interface 1 for the keyboard settings. Its three public
  [USB captures](https://github.com/telecastr/tp2ctl/tree/main/pcaps) contain
  respectively 12, 12 and 20 Feature `13` SET_REPORT requests on interface 1,
  and no Feature `04` request. This establishes the captured normal-settings
  path, not the meaning or absence of other possible vendor commands.
- Lenovo's [official Windows package](https://support.lenovo.com/us/en/downloads/ds543713-thinkpad-trackpoint-keyboard-ii-software-for-windows-7-windows-10)
  was retrieved with its published SHA-256
  `d14fc7c06306db52fb9c0b01b50efdba0b89dfdae6f75d9ff22bf5198189b3c5`.
  Merely identifying that package does not establish Feature `04` semantics;
  proprietary binaries are not included in this repository.

## Implemented correction

Before `IOHIDDeviceSetReport`, query whether that exact interface exposes the
expected Feature `13` (USB) or Output `18` (BLE). If the element list is absent,
empty, or contains only a different report/type, skip the write. A supported
report whose actual write fails still uses the normal software fallback.

Keep all exact-model interfaces in the HID manager so typing, modifier remaps,
hotkeys and input callbacks continue to work. Sensitivity status is determined
only from interfaces with confirmed pointer movement; successful hardware and
software fallback devices are shown separately when mixed.

Tests cover vendor Feature `04` only, standard keyboard Output `00`, the wrong
report type with the right ID, unavailable enumeration, valid USB/BLE writes,
real write failure, and USB composite-device status. Test effects are intercepted;
physical USB reads confirmed the matching criteria without mutating the device.
