# kiyoctl

Field of view, HDR and autofocus for the **Razer Kiyo Pro** (`1532:0e05`) on macOS.

The Kiyo Pro is UVC-compliant, so macOS drives it for video out of the box. But FOV,
HDR and AF-mode are not standard UVC controls — they sit behind a Razer vendor-specific
**Extension Unit** in the camera's VideoControl interface. The macOS UVC driver exposes
only spec-defined units, so those controls are invisible to every Mac app and the camera
defaults to its widest, noticeably barrel-distorted ~103° FOV. Synapse 3 is Windows-only.

`kiyoctl` speaks to that extension unit directly.

```
kiyoctl fov narrow
```

No kext, no DriverKit extension, no `sudo`. Close Zoom, OBS, Photo Booth and other
camera clients before applying a setting; `kiyoctl` will not seize an in-use device.

---

## Before you build: check whether you need this

The camera has non-volatile storage and the protocol has an explicit **save** command,
so settings written with save survive unplug/replug *and* survive moving between hosts.

1. Update the camera firmware from Windows. Old Kiyo Pro firmware has broken autofocus,
   and the firmware revision affects which extension-unit behaviours work at all.
2. Set the FOV once from **Synapse 3** — not Synapse 4, which has been reported not to
   persist FOV to the device.
3. Unplug, plug into the Mac, and look at the preview.

If it held, this tool is a convenience rather than a necessity. It is still the right
thing to have, because it removes the Windows dependency entirely.

## Build

```bash
swift build -c release
```

The binary lands at `.build/release/kiyoctl`. To put it on your `PATH`:

```bash
install -m 755 .build/release/kiyoctl /usr/local/bin/kiyoctl
```

A plain non-sandboxed CLI needs no entitlement. A sandboxed GUI app built on `KiyoKit`
would need `com.apple.security.device.usb`; notarisation is otherwise unremarkable.

### Menu bar app

Build the native AppKit menu-bar app as a local, non-sandboxed application bundle:

```bash
Scripts/build-menu-app.sh
open dist/KiyoMenu.app
```

The camera icon appears in the macOS menu bar; the app has no Dock icon. Changes are
**session-only by default**. Check **Save changes to camera** to persist every subsequent
change. You can also make several session-only changes and then check it: the app sends
one persistence command to save the accumulated camera state. Uncheck it to return to
session-only changes.

At launch the menu app enumerates once, then makes six standard, read-only UVC requests
to learn the digital-zoom range. It does not write merely by launching or opening its menu.
The app disables controls while a command is running and uses the same pacing, transfer
ceiling, exact payload validation and no-retry behavior as the CLI. Checkmarks mean only
"successfully written by this app during this session." The locally built bundle is ad-hoc
signed without App Sandbox or USB entitlements.

#### Approximate digital FOV

The three Razer FOV modes remain the native bases: approximately 103°, 90° and 80°.
After choosing one, the menu also offers approximate digital crops at 70°, 60°, 50°, 40°,
30° and 24° where the selected base and zoom range can reach them. Choosing a native base
resets digital zoom to 100%.

This is the standard UVC Camera Terminal **Zoom Absolute** control, not another guessed
Razer payload. Firmware 8.21 advertises GET and SET support with a range of 100…400,
step 1 and default 100. Its focal-length descriptor fields are all zero, so the labels use
the rectilinear crop approximation
`effective = 2 × atan(tan(base / 2) / (zoom / 100))` and deliberately retain `~`.

The Razer persist command is proven for its vendor FOV/HDR/AF settings. Whether it also
commits the standard UVC zoom value is not yet verified, so a digital FOV reports
**save requested**, not **saved**, until an unplug/replug test confirms it.

## Usage

```
kiyoctl list                          matched cameras, discovered bUnitID, wIndex
kiyoctl fov wide|medium|narrow        ~103° / ~90° / ~80°
kiyoctl hdr on|off [--mode dark|bright]
kiyoctl af responsive|passive
kiyoctl set fov=narrow,hdr=off        batch, with a single persist at the end
kiyoctl status                        the write cache (see the caveat it prints)
kiyoctl probe                         read-back experiment; writes nothing
kiyoctl zoom-info                     read Zoom Absolute range; writes nothing
```

Useful flags: `--dry-run`, `--verbose`, `--no-save`, `--device <locationID>`,
`--delay <ms>`, `--json`. Run `kiyoctl --help` for the full list.

`--dry-run` never opens the device, so it is safe to run mid-call. It still enumerates,
so the `wIndex` it prints is the real discovered one:

```
$ kiyoctl fov narrow --dry-run
Dry run — nothing was sent.

Target: Razer Kiyo Pro at 0x14400000
    addressing          bUnitID 12, VideoControl interface 0, wIndex 0x0c00

Planned transfers (4, 100 ms apart):
  → GET_LEN  sel=0x01 wIndex=0x0c00            # expect 8
  → SET_CUR sel=0x01 wIndex=0x0c00 len=8  ff 01 00 03 02 00 00 00  # fov narrow — pre-write
  → SET_CUR sel=0x01 wIndex=0x0c00 len=8  ff 01 01 03 02 00 00 00  # fov narrow
  → SET_CUR sel=0x01 wIndex=0x0c00 len=8  c0 03 a8 00 00 00 00 00  # persist to camera
```

### Reading state back does not work

`GET_CUR` on the read-back selector does not answer on the firmware this protocol was
reverse-engineered against, so the tool is write-only by design. `kiyoctl status` shows
what *this tool last wrote*, cached in
`~/Library/Application Support/kiyoctl/state.json`, and says so every time it prints.
It is never authoritative — you may have changed the camera from Synapse on another
machine since. `kiyoctl probe` attempts the read anyway and treats failure as the
expected outcome.

## Protocol

| Item | Value |
|---|---|
| Vendor / Product | `0x1532` / `0x0E05` (strict — the Kiyo Pro **Ultra** is a different, undocumented device) |
| XU GUID | `23e49ed0-1178-4f31-ae52-d2fb8a8d3b48` |
| GUID on the wire | `d0 9e e4 23 78 11 31 4f ae 52 d2 fb 8a 8d 3b 48` |
| `bUnitID` | **discovered, never hardcoded** |
| Selectors | `0x01` SET_ISP (write), `0x02` GET_ISP_RESULT (read; does not work) |
| Payload length | 8 bytes |

Each command is a UVC `SET_CUR` aimed at the extension unit: `bmRequestType 0x21`,
`bRequest 0x01`, `wValue = selector << 8`, `wIndex = (bUnitID << 8) | vcInterface`,
`wLength 8`.

**Unit ID discovery.** The configuration descriptor is walked properly — tracking which
VideoControl interface each descriptor belongs to — and the extension unit is matched by
GUID. In a `VC_EXTENSION_UNIT` descriptor the GUID sits at offset 4, so `bUnitID` is the
byte immediately before it. If a malformed `bLength` breaks the walk, the code falls back
to a raw GUID scan (what the Linux tool does), still validating the descriptor type and
subtype preceding the match. Firmware revisions renumber units, so this is not optional.

**Field of view** is two writes, not one. Medium and narrow need a "pre" write with byte
2 = `00` followed by the real write with byte 2 = `01`; byte 4 carries the FOV index.
Wide needs only the single write. The mechanism behind the pre-write is not understood —
Synapse sends it, so `kiyoctl` sends it.

**Digital zoom** is separate and standards-based. The Camera Terminal is discovered from
its `VC_INPUT_TERMINAL` descriptor; Zoom Absolute support is bit D9 of `bmControls`.
Requests use selector `0x0b`, the discovered terminal ID in the high byte of `wIndex`, and
a two-byte little-endian value. Capability reads use `GET_INFO`, `GET_MIN`, `GET_MAX`,
`GET_RES`, `GET_DEF` and `GET_CUR`; the only write is a range- and step-validated `SET_CUR`.

**Persist** (`c0 03 a8 …`) goes last, once, after all the setting writes. Without it the
settings apply to the live session and are lost on replug.

The payload table lives in one place, [`Sources/KiyoKit/KiyoProtocol.swift`](Sources/KiyoKit/KiyoProtocol.swift).

## Why it is deliberately slow

The Kiyo Pro's firmware is brittle under control-transfer load. Roughly 25 rapid
consecutive UVC `SET_CUR` operations can overwhelm it and stall its endpoints. Current
investigation reports the failure across Linux, Windows and macOS, with severity ranging
from a wedged camera to a host-controller failure that disconnects the USB bus until a
reboot.

So: **at least 100 ms between every transfer**, no retries after a failed request, a hard
ceiling of 12 transfers per invocation, and no polling anywhere — no timers, no reapply
loop, no slider firing a transfer per pixel. These limits are enforced in `KiyoKit`, not
only in the CLI. Every write must use selector `SET_ISP` with exactly eight bytes, and the
`GET_LEN` check confirming that payload size cannot be disabled. A full FOV change is four
transfers. There is deliberately no arbitrary-payload or stress command.

## Architecture

```
Sources/CKiyoUSB/     IOKit transport. The whole platform-specific surface.
Sources/KiyoKit/      Protocol constants, sequencing, throttling, state cache.
Sources/kiyoctl/      CLI.
Sources/KiyoMenu/     Native AppKit menu-bar app.
```

The transport opens the **device**, not the VideoControl interface: the system UVC driver
holds the interfaces, so `USBInterfaceOpen` would fail. Device-level requests go out the
default control pipe. The recipient in `bmRequestType` stays *interface*; `wIndex` carries
the interface number.

Only `USBDeviceOpen` is used. On `kIOReturnExclusiveAccess`, the command stops and asks the
user to close camera applications; it never calls `USBDeviceOpenSeize`. Interface revisions
are queried newest-first from `942` down to `182` and used through the `182` struct, which
every later revision extends without reordering.

`KiyoKit` is a separate library product so a menu-bar app can link the same protocol and
transport without shelling out to the CLI.

## Verification

1. **Discovery** — `kiyoctl list` prints a plausible `bUnitID` and VideoControl interface.
   Cross-check against `system_profiler SPUSBDataType`, or an `lsusb -v` dump from Linux.
2. **Visual** — note the current crop in Photo Booth or QuickTime, close the preview, run
   `kiyoctl fov narrow`, then reopen the preview. Wide → narrow is obvious; the barrel
   distortion at the frame edges disappears.
3. **Persistence** — set narrow, quit everything, unplug, wait 10 s, replug, open Photo
   Booth. The setting should survive. This is what validates the persist command.
4. **Round-trip** — set narrow from macOS, boot Windows, confirm Synapse 3 reports narrow.
   Strongest evidence the protocol is being spoken correctly.

## Open questions

- What does `ff 04 00 …` do? Synapse sends it at startup. Its purpose is unknown, so the
  CLI does not expose it.
- Does `GET_CUR` on selector `0x02` return anything on current firmware? Upstream says no.
  `kiyoctl probe` is the one experiment.
- Is persist global or per-setting? Assumed global — `kiyoctl set` writes everything then
  persists once. If a batch does not stick, apply the settings one at a time instead.
- Kiyo Pro **Ultra** is out of scope: continuous zoom rather than three FOV steps, and
  undocumented payloads. Matching is strict on `0x0E05` so it can never be hit by accident.

## Credits

The protocol was reverse-engineered from Synapse USB captures by
[`soyersoyer/cameractrls`](https://github.com/soyersoyer/cameractrls) and its predecessor
[`soyersoyer/kiyoproctrls`](https://github.com/soyersoyer/kiyoproctrls) (MIT) — the primary
source for everything in the protocol table above.
[`itaybre/CameraController`](https://github.com/itaybre/CameraController) and
[`jtfrey/uvc-util`](https://github.com/jtfrey/uvc-util) are the references for IOKit UVC
transport on macOS. [`jphein/kiyo-xhci-fix`](https://github.com/jphein/kiyo-xhci-fix)
documents the firmware's control-transfer failure modes behind the throttling above.

MIT licensed — see [LICENSE](LICENSE), which preserves the `cameractrls` notice.
