# Razer Kiyo Pro — FOV / HDR / AF control on macOS

**Implementation brief for a coding agent.**

Target device: **Razer Kiyo Pro**, USB `1532:0e05`.
Goal: a macOS tool that switches the camera's field of view (wide / medium / narrow) and optionally HDR and autofocus mode, replicating what Razer Synapse 3 does on Windows.

---

## 1. Problem statement

The Kiyo Pro is a UVC-compliant camera, so macOS drives it out of the box for video. However, FOV, HDR and AF-mode are **not** standard UVC controls — they live behind a Razer **vendor-specific Extension Unit (XU)** in the camera's VideoControl interface. The macOS UVC driver exposes only spec-defined units (Camera Terminal, Processing Unit), so these controls are invisible to every Mac app, and the camera reports its widest (~103°, noticeably barrel-distorted) FOV by default.

Razer Synapse is Windows-only. Synapse 4 for macOS exists but as of this writing does not support Kiyo products.

**The protocol is already reverse-engineered** — from Synapse USB captures, by the `cameractrls` project (Linux). This brief restates that protocol and specifies the macOS port. The only thing that needs rewriting is the transport layer: Linux uses a `uvcvideo` ioctl that has no macOS equivalent, so the same USB control transfers must be issued directly through IOKit or libusb.

### Important pre-work note

The camera has non-volatile storage, and the protocol includes an explicit **save** command. Settings written with save persist across unplug/replug and across hosts. So before building anything, confirm the baseline: set the FOV once from a Windows machine using **Synapse 3** (Synapse 4 has been reported not to persist FOV to the device), unplug, plug into the Mac, and check whether it holds. If it does, the tool below is a convenience rather than a necessity — but it's still the right thing to build, since it removes the Windows dependency entirely.

Also update the camera firmware from Windows first. Old Kiyo Pro firmware has broken autofocus and the firmware version affects which XU behaviours work.

---

## 2. Protocol specification

### 2.1 Extension unit identity

| Item | Value |
|---|---|
| Vendor / Product ID | `0x1532` / `0x0E05` |
| XU GUID (canonical) | `23e49ed0-1178-4f31-ae52-d2fb8a8d3b48` |
| XU GUID (on-the-wire byte order) | `d0 9e e4 23 78 11 31 4f ae 52 d2 fb 8a 8d 3b 48` |
| Unit ID | **Do not hardcode** — discover it (§2.2) |
| Selector: SET_ISP | `0x01` (write) |
| Selector: GET_ISP_RESULT | `0x02` (read; see caveat §2.5) |
| Payload length | 8 bytes |

The GUID's first three fields are little-endian in the descriptor, per the USB/GUID convention — that's why the wire order differs from the canonical string form.

### 2.2 Discovering the unit ID

Read the full configuration descriptor and scan it for the 16-byte GUID above. In a UVC Extension Unit descriptor the layout is:

```
bLength | bDescriptorType (0x24) | bDescriptorSubType (0x06 = VC_EXTENSION_UNIT)
| bUnitID | guidExtensionCode[16] | ...
```

So **the byte immediately preceding the GUID is `bUnitID`**. This is the same trick the Linux tool uses (it scans the raw descriptor blob rather than trusting a fixed ID). Firmware revisions can renumber units, so discovery is not optional.

While scanning the descriptors, also record the **VideoControl interface number** (`bInterfaceClass = 0x0E` video, `bInterfaceSubClass = 0x01` videocontrol) — normally `0`, but read it rather than assuming.

### 2.3 Control transfer format

Every command is a UVC class `SET_CUR` request aimed at the extension unit:

| Field | Value |
|---|---|
| `bmRequestType` | `0x21` (host→device, class, recipient = interface) |
| `bRequest` | `0x01` (`SET_CUR`) |
| `wValue` | `selector << 8` → `0x0100` for SET_ISP |
| `wIndex` | `(bUnitID << 8) \| bVideoControlInterfaceNumber` |
| `wLength` | `8` |
| Data | the 8-byte payload from §2.4 |

Optionally query the control's length first with `GET_LEN` (`bmRequestType 0xA1`, `bRequest 0x85`, 2-byte little-endian response) and assert it returns 8. The Linux tool does this; hardcoding 8 is acceptable but the check is cheap insurance against firmware drift.

### 2.4 Payloads

All payloads are 8 bytes. Byte 0 is `0xFF` for the ISP commands; byte 1 selects the function.

**Field of view** (Kiyo Pro FOV steps are approximately 103° / 90° / 80°):

| Setting | Sequence |
|---|---|
| Wide | `ff 01 00 03 00 00 00 00` (single write) |
| Medium | `ff 01 00 03 01 00 00 00` **then** `ff 01 01 03 01 00 00 00` |
| Narrow | `ff 01 00 03 02 00 00 00` **then** `ff 01 01 03 02 00 00 00` |

Medium and narrow require the two-step "pre" write followed by the real write — byte 2 goes `00` → `01`, byte 4 carries the FOV index. Wide needs only the single write. Do not skip the pre-write; the mechanism behind it is not understood, and Synapse sends it.

**Other controls on the same unit:**

| Control | Payload |
|---|---|
| HDR off | `ff 02 00 00 00 00 00 00` |
| HDR on | `ff 02 01 00 00 00 00 00` |
| HDR mode dark | `ff 07 00 00 00 00 00 00` |
| HDR mode bright | `ff 07 01 00 00 00 00 00` |
| AF responsive | `ff 06 00 00 00 00 00 00` |
| AF passive | `ff 06 01 00 00 00 00 00` |
| Unidentified init | `ff 04 00 00 00 00 00 00` |
| **Persist to camera** | `c0 03 a8 00 00 00 00 00` |

The `ff 04 ...` command is sent by Synapse at startup and its purpose is unknown; it is safe to omit initially, but worth having behind a flag if something misbehaves.

**Ordering:** apply the desired setting writes, then send the persist command last. Without the persist command the setting applies to the live session but is lost on replug.

### 2.5 Reading state — don't rely on it

Reading current values via `GET_CUR` on selector `0x02` **does not work** on the firmware the Linux authors tested; the code path is present but commented out upstream. Design the tool as write-only:

- Cache the last-applied state in `~/Library/Application Support/<tool>/state.json` for UI purposes only.
- Never present the cache as authoritative — the user may have changed the setting elsewhere.
- If you want to attempt a read on newer firmware, do it behind a flag and treat failure as normal, not an error.

---

## 3. macOS implementation

### 3.1 Transport: which API

Two viable routes. **Recommended: IOKit `IOUSBLib`.**

**Route A — IOKit (recommended).** The legacy user-space USB API still works on Apple silicon and current macOS, and this is exactly what [CameraController](https://github.com/itaybre/CameraController) uses to drive standard UVC controls on the Mac — read its USB layer as a reference implementation, since the only difference for this project is the unit ID and selector in `wIndex`/`wValue`.

Sketch:

1. `IOServiceMatching(kIOUSBDeviceClassName)`, filter on `idVendor == 0x1532 && idProduct == 0x0E05`.
2. `IOCreatePlugInInterfaceForService` → `QueryInterface` for `IOUSBDeviceInterface` (942 or newer; fall back gracefully).
3. `GetConfigurationDescriptorPtr(0, &desc)` → parse for the XU unit ID and the VideoControl interface number (§2.2).
4. Open the device: try `USBDeviceOpen`; on `kIOReturnExclusiveAccess` fall back to `USBDeviceOpenSeize`. **Open the device, not the interface** — the system UVC driver holds the VideoControl and VideoStreaming interfaces, so `USBInterfaceOpen` will fail. Device-level requests go out the default control pipe and coexist with the streaming driver, which is why the camera can stay live in Zoom/OBS while you retarget it.
5. Issue each command as an `IOUSBDevRequest` with `bmRequestType` built via `USBmakebmRequestType(kUSBOut, kUSBClass, kUSBInterface)`. The recipient stays *interface* even though the request is made through the device handle — `wIndex` carries the interface number.
6. `USBDeviceClose`, release everything.

**Route B — libusb.** Simpler to prototype: `libusb_open_device_with_vid_pid(ctx, 0x1532, 0x0E05)` then `libusb_control_transfer(handle, 0x21, 0x01, 0x0100, (unitId << 8) | vcInterface, payload, 8, 1000)`. No `libusb_claim_interface` is needed for control transfers on the default pipe, which is the whole reason this works alongside the kernel driver. Fine for a proof of concept; adds a dylib dependency you probably don't want to ship in a signed app.

### 3.2 Entitlements and distribution

- A plain non-sandboxed CLI binary needs no special entitlement — start here.
- A sandboxed GUI app needs `com.apple.security.device.usb`. Notarisation is otherwise unremarkable.
- No kext, no DriverKit system extension, no `sudo` required. If the implementation seems to need any of those, the transport is wrong.
- The built-in FaceTime camera is off-limits to third-party UVC control on T2/Apple-silicon Macs — irrelevant here, but don't be confused by that limitation when reading CameraController's docs.

### 3.3 Firmware fragility — hard requirement

The Kiyo Pro's firmware is genuinely brittle under control-transfer load. Linux investigation of this device found that roughly 25 rapid consecutive UVC `SET_CUR` operations can overwhelm the firmware and stall endpoints, and that the resulting stall can cascade into a host-controller failure that takes the whole USB bus down. Whether macOS's xHCI stack degrades the same way is untested, but assume it might.

Therefore:

- **Sleep 50–100 ms between every control transfer**, including between the pre-write and the real write.
- Never poll. No timers, no "reapply every N seconds", no live-dragging a slider that fires a transfer per pixel. Debounce all UI to a single write on commit.
- Retry at most twice on failure, with backoff, then surface the error and stop.
- Total transfers for a full FOV change should be ≤4 (optional GET_LEN, pre-write, write, persist).

### 3.4 Suggested deliverable

A Swift Package producing a CLI, with the USB layer isolated so a menu-bar app can be added later:

```
kiyoctl list                         # show matched devices, discovered unit ID, VC interface
kiyoctl fov wide|medium|narrow
kiyoctl hdr on|off  [--mode dark|bright]
kiyoctl af responsive|passive
kiyoctl set fov=narrow,hdr=off       # batch, single persist at the end
  --no-save                          # skip the persist command (session-only)
  --dry-run                          # print the transfers without sending
  --verbose                          # log every transfer as hex
```

`--dry-run` and hex logging are worth building on day one; they make the inevitable debugging against a black-box device tractable.

Optional second phase: a `launchd` LaunchAgent watching `IOServiceAddMatchingNotification` for the device appearing, reapplying the cached settings on hotplug. Only build this if the persist command turns out not to hold — it adds a background process and more chances to hammer the firmware.

---

## 4. Verification plan

1. **Discovery** — `kiyoctl list` prints a plausible unit ID and VC interface number. Cross-check against `system_profiler SPUSBDataType` and, if available, a `lsusb -v` dump from a Linux box.
2. **Visual confirmation** — open Photo Booth or QuickTime (New Movie Recording) as a live preview, run `kiyoctl fov narrow`, and confirm the crop changes on screen without restarting the preview. Wide→narrow is an obvious change; the barrel distortion at the frame edges disappears.
3. **Persistence** — set narrow, quit everything, unplug the camera, wait 10 s, replug, open Photo Booth. Setting should survive. This validates the persist command.
4. **Coexistence** — repeat step 2 while the camera is in use by a videoconferencing app, confirming the device-level transfer doesn't disturb the stream or get blocked.
5. **Round-trip against Synapse** — if a Windows machine is available, set narrow from macOS, boot into Windows, and confirm Synapse 3 reports narrow. Strongest possible evidence the protocol is being spoken correctly.
6. **Stress sanity** — deliberately fire 30 transfers back-to-back once, in a disposable session, to characterise whether the macOS stack tolerates what Linux does not. Do this last, and not on a machine with important work open.

---

## 5. References

- `soyersoyer/cameractrls` — https://github.com/soyersoyer/cameractrls — Linux camera control tool; contains the Kiyo Pro extension. MIT licensed. **Primary source for the protocol.**
- `soyersoyer/kiyoproctrls` — https://github.com/soyersoyer/kiyoproctrls — the standalone predecessor, now merged into the above. Smaller and easier to read; the payload constants and the two-step FOV sequence are plainly visible in `kiyoproctrls.py`.
- `itaybre/CameraController` — https://github.com/itaybre/CameraController — macOS UVC control app. **Reference for the IOKit transport layer.** Handles standard units only; vendor-specific extensions are on its roadmap but unimplemented, which is precisely the gap this project fills.
- `jtfrey/uvc-util` — https://github.com/jtfrey/uvc-util — Objective-C macOS UVC utility, IOKit-based, useful as a second transport reference.
- `jphein/kiyo-xhci-fix` — https://github.com/jphein/kiyo-xhci-fix — documents the Kiyo Pro firmware's control-transfer failure modes; the source for the throttling requirement in §3.3.
- Linux UVC driver docs — https://docs.kernel.org/userspace-api/media/drivers/uvcvideo.html — background on how XU controls are addressed, useful for understanding what the ioctl in the Linux code is doing underneath.

Licensing: the reference implementations are MIT. The protocol constants are facts about a hardware device rather than creative expression, but if any code is lifted from `cameractrls`, preserve the MIT notice.

---

## 6. Open questions for the implementer

- What does `ff 04 00 ...` do? Synapse sends it at startup. Unknown whether it's required for anything.
- Does `GET_CUR` on selector `0x02` return anything useful on current Kiyo Pro firmware? Upstream says no. Worth one experiment.
- Is the persist command scoped per-setting or global? Assumed global (write all settings, then persist once), but untested — if a batch doesn't stick, try persisting after each individual setting.
- Kiyo Pro **Ultra** is a different device with a continuous zoom slider rather than three FOV steps, and its payloads are not publicly documented. Out of scope, but don't let the tool match on it blindly — filter strictly on `0x0E05`.
