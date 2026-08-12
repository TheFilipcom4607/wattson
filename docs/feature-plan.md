# What to take from the device-inventory apps, and what not to

Work order, written from screenshots of a paid USB-inventory app for macOS.
Feature and interaction ideas only — no assets, icons or wording get lifted.

## The filter

The reference app is a **device inventory**: its organising question is "what is
plugged in, and what is it". Wattson is a **power instrument**: "where is the
power going, and is this cable lying to me". Both draw a device tree, which is
why the overlap looks bigger than it is.

That difference is the whole filter. Copying its surface wholesale would leave
Wattson a worse version of a thing that already exists. The features worth
taking are the ones that answer a question Wattson *already implicitly poses*
and currently leaves hanging.

## Inventory of the gap

| Reference app has | Wattson today |
| --- | --- |
| Serial, VID/PID on every device | Vendor name only |
| Power in mA and W | W only (mA is read, then discarded) |
| Timestamped connect/disconnect log | Nothing |
| Toast on attach/detach | `HotplugWatcher` fires, silently |
| Volumes: used/free, Show in Finder, Safe Eject | Nothing |
| Detail inspector per device | Nested rows get a `.help` tooltip |
| Search field | Nothing |
| Speed pills, colour-coded by tier | Plain text |
| `P1`/`P2` port badges | Port numbering exists, known unreliable |
| Pin a device | Nothing |
| Autostart toggle in the footer | In Settings, deliberately |
| Device/hub count in header | `TitleMode.deviceCount` in the menu bar |

## Verdict

**Take:** serial + VID/PID + mA, the scan diff (toast *and* log), a real device
inspector, volumes with eject, search.

**Adapt:** one speed pill, not a wall of them.

**Reject:** port badges, footer autostart, pinning. Reasons at the bottom —
each is a decision Wattson already made on purpose.

---

## The keystone: device identity is currently port identity

This is the thing to fix first, and it is not visible in any screenshot.

`Scanner.usbDevices()` sets `node.id = "usb-\(location)"`, with the comment that
the locationID "is stable for as long as the device stays plugged into the same
port". True, and exactly right for its current job — keeping SwiftUI from
rebuilding rows twice a second.

But it is a **port** identity, not a **device** identity. Three of the features
above quietly need the second one:

- Move a drive from one port to another → it is a different device, and its
  connection history starts over.
- Plug a *different* drive into the port the first one just left → it inherits
  the previous device's history.
- Any per-device preference (pinning, "don't notify me about this one") attaches
  to the hole in the side of the Mac rather than the thing in it.

The fix is the serial number, which Scanner does not currently read. So
`kUSBSerialNumberString` is not a nice extra field for the inspector — it is the
prerequisite for the log being *true*. Do this before anything in Phase 2.

Keep both identities and keep them separate:

```swift
/// Stable while the device stays in one port. Row identity for SwiftUI.
var id: String
/// Stable across ports and reboots, when the device offers a serial at all.
/// Cheap hubs and card readers frequently do not — fall back to the port id
/// and accept that their history resets when they move.
var persistentID: String?
```

Derive `persistentID` as `"\(idVendor):\(idProduct):\(serial)"` and fall back to
`id` when the serial is missing. Anything keyed on history must key on
`persistentID` and must degrade gracefully when it is a fallback — a log that
silently lies is worse than no log.

---

## Phase 1 — three fields already in the dictionary

`Scanner.swift` fetches the whole property dictionary per device and reads four
keys out of it. These three are sitting in the same dictionary, unread:

```diff
+ node.serial   = properties["USB Serial Number"] as? String
+ node.vendorID  = (properties["idVendor"] as? NSNumber)?.intValue
+ node.productID = (properties["idProduct"] as? NSNumber)?.intValue
  if let mA = (properties["UsbPowerSinkAllocation"] as? NSNumber)?.doubleValue, mA > 0 {
      node.watts = mA * 5 / 1000
+     node.milliamps = mA
  }
```

`idVendor` is already read for the `isApple` check and thrown away; `idProduct`
is never read; the mA figure is converted to watts and dropped. No new IOKit
traversal, no new cost on a scan.

Surface them in `detailRows()` — `VID/PID` as `%04X:%04X`, the serial truncated
in the middle rather than the tail (the distinguishing digits on flash media are
usually at the end). The mA figure belongs next to the existing watts line and
should say plainly that it is an allocation, which `detailRows()` already does.

**Cost:** an hour. **Unblocks:** everything below.

---

## Phase 2 — the scan diff, which is two features

`HotplugWatcher` already fires on attach and detach and calls `scheduleRescan()`.
It carries no identity — it only says "something changed". Both the toast and
the log fall out of **diffing consecutive `ScanResult`s**, not from new IOKit
work.

In `DeviceModel.refresh()`, where `self.result = scan` is assigned, compare the
flattened device sets by `persistentID` first:

```swift
let before = Set(result.devices.flatMap { $0.flattenedRows() }.map(\.node.persistentKey))
// … assign the new scan …
let after  = …
// arrived = after.subtracting(before), left = before.subtracting(after)
```

Then:

**2a — connection log.** Append `(persistentID, .connected/.disconnected, Date())`
to a ring buffer. Persist to `UserDefaults` as JSON, cap it hard (200 entries
total, and 10 per device) — this is a menu bar app, not a database. Render it in
the inspector as the reference app does: a two-column list, time-only for today
and `dd.MM.yyyy, HH:mm` beyond it.

One caveat worth designing for rather than discovering: the log only records
what happens **while Wattson is running**, so a device that was attached before
launch has no "Connected" entry. Say so in the UI ("since Wattson started")
rather than showing a device its own history with the first line missing.

**2b — the toast.** Draw it in-app, as a small borderless `NSWindow` near the
menu bar — which is what the reference app appears to be doing, and it sidesteps
`UNUserNotificationCenter` entirely. That matters here: the app is ad-hoc signed
(`build.sh`), and user notifications want a real bundle identity and an
authorisation prompt. An in-app toast needs neither.

Coalesce aggressively. Attaching a 7-port hub fires one notification per
downstream device and would put seven toasts on screen — debounce ~400 ms and
collapse to "Hub attached · 6 devices". Gate it behind a Settings toggle in the
existing `group("Panel")`, defaulted **off**: an app that starts talking after
an update is an app people quit.

**Cost:** a day for both. **Depends on:** Phase 1.

---

## Phase 3 — a real inspector

Today a nested device gets `.help(...)` — a tooltip, only on hover, unselectable,
and it is where the serial and VID/PID would otherwise go to die. The card
headers get expandable `DetailRow`s; the tree rows get nothing comparable.

Do **not** copy the reference app's separate floating window. Wattson's panel is
an `NSPopover` that closes on click-outside, so a second window fights the
interaction model. Expand in place instead, reusing `DetailRow` and the
`expanded: Set<String>` pattern that `ConnectionCard` already has — the machinery
and the visual language both exist.

Order the sections so the power answer stays first, because that is what Wattson
is for: **Power** (allocated mA/W, measured where known) → **Link** (speed,
version) → **Identity** (vendor, VID/PID, serial) → **History** (Phase 2a).

**Cost:** a day. **Depends on:** Phases 1 and 2a.

---

## Phase 4 — volumes and eject

The most expensive item and the highest user-visible value: "which of these is
my drive, and let me eject it" is the single most common reason to open a USB
list at all.

New plumbing — DiskArbitration, the only new framework in this plan.

Map **volume → device**, not device → volume. There are a handful of mounted
volumes and potentially dozens of USB nodes, and the volume side gives a
direct handle:

1. `FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys:)`
2. `DADiskCreateFromVolumePath` → `DADiskCopyIOMedia` → walk up
   `kIOServicePlane` to the enclosing `IOUSBHostDevice`
3. Read that parent's `locationID` and match it to the node already keyed by it

Capacity comes free from `URLResourceKey.volumeTotalCapacityKey` and
`.volumeAvailableCapacityKey` on the URL from step 1.

For eject, unmount the **whole disk** rather than per-volume. The reference
app's own screenshot shows a stick with two volumes and a Safe Eject button on
each, which is a trap: ejecting one volume of a two-volume stick leaves the
device half-mounted. Use `DADiskUnmount` with `kDADiskUnmountOptionWhole` on the
parent disk, then `DADiskEject`, and surface the failure — unmount fails
routinely because something still holds a file open, and a button that silently
does nothing is worse than no button.

Show in Finder is `NSWorkspace.shared.activateFileViewerSelecting([url])`.

Progress bars: the reference app puts a segmented capacity bar on the collapsed
row. Wattson already owns a bar idiom in `AllocationBar`, and it means *power*.
A second, differently-shaped bar meaning *disk space* on an adjacent row is a
collision — keep capacity inside the expanded inspector, where there is nothing
to collide with.

**Cost:** two to three days, most of it in step 2 and in eject failure handling.
**Depends on:** nothing above. Can be built in parallel.

---

## Phase 5 — search, conditionally

Pure UI over the existing model, no new data. Filter on name, vendor, type and
serial; keep a matched device's ancestors visible so a hit three levels into a
hub does not appear at the root.

Only show the field when the tree is big enough to need it — past roughly 8
devices. A permanent search box over a four-row list is an admission that the
list is too long, on a panel where it usually is not. `scrollingBody` already
measures the device count, so the condition is free.

Watch the focus interaction: this lives in an `NSPopover`, and a focused text
field changes what Escape does. Escape should clear a non-empty query and close
the panel when it is already empty.

**Cost:** half a day.

---

## Adapt: one pill, not a wall of them

The reference app puts three or four pills on every row — version, speed,
wattage, each in its own colour. It works there because the app is an inventory
where every row is equal.

Wattson's rows are not equal, and its current hierarchy is typographic: weight
and opacity on plain text, with colour reserved for the allocation bar, where
colour *means* something (Mac / accessories / battery). A colour-per-speed-tier
scale would be a second colour language on the same panel, and the two would be
read as related when they are not.

This is the same call flagged as Tier 3 in `icon-legibility.md`, and it should
be answered the same way in both places, or the panel ends up with three
independent colour systems.

If one pill is wanted, make it the **wattage** — it is the number Wattson exists
to show — and keep the speed as text. Try it on the card headers only, where
there are two or three rows, never in the tree.

## Reject, with reasons

- **`P1`/`P2` port badges.** The README states plainly that port numbering says
  nothing about physical position and was hand-mapped on one machine. A badge
  reading `P1` is an assertion of fact about something Wattson knows to be
  unreliable. The existing "(front)" / "(rear)" wording is already at the limit
  of what the data supports.
- **Autostart in the footer.** It was moved to Settings on purpose — the comment
  on `footer` says two places to change one thing. Re-adding it is a regression
  of a decision already made.
- **Pinning.** Earns its keep in an always-open window. This is a popover open
  for about five seconds at a time; sorting by power already puts the
  interesting row on top.
- **Device/hub count in the header.** `TitleMode.deviceCount` covers it, in the
  menu bar, where it is visible without opening anything.

## Order

Phase 1 → Phase 2 → Phase 3 is one dependency chain and the highest value per
day of work; Phase 1 is an hour and unblocks the rest. Phase 4 is independent
and can run alongside. Phase 5 last — it is the only one whose value grows with
the others, since it is worth most once rows carry serials to search.
