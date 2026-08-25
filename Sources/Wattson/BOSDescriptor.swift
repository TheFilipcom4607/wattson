import Foundation
import IOKit
import IOKit.usb
import IOKit.usb.IOUSBLib

/// A USB device's own account of an alternate mode it tried to enter, and
/// whether it worked.
///
/// This is the one thing that explains a dock whose display output silently
/// does nothing. A device that fails to enter DisplayPort alt mode is required
/// to come back as a Billboard device and say so, and the reason is in the
/// descriptor rather than anywhere macOS surfaces. `Scanner` already reads
/// `UsbBillboardCurrentMode` off the registry, but that is only published for
/// a device macOS itself recognised as a Billboard, and it says which mode
/// exists rather than what happened to it.
///
/// The layout came from the specification and no capture, because nothing
/// carrying one had ever been attached to this machine. A Lenovo dock settled
/// it on 2026-08-25: a VIA Labs billboard (2109:0102) answered with 81 bytes
/// across three capabilities — a container ID, a Billboard capability of
/// exactly 48 bytes, and a Billboard Alt Mode capability — and every offset
/// guessed from the specification landed. bNumberOfAlternateModes reads 1 and
/// the capability is 44 + 4 x 1 bytes long, the mode's SVID at offset 44 is
/// 0xFF01, and its two bits in bmConfigured read 3.
///
/// So the fixture proves the structure and the "succeeded" state. It does not
/// prove the failure states: that dock's DisplayPort works, which is why the
/// app correctly says nothing about it. A mode reading 2 is still unobserved.
struct BillboardMode: Hashable {
    /// Standard or Vendor ID. 0xFF01 is DisplayPort.
    let svid: Int
    /// Which of that SVID's modes, as the device numbers them.
    let index: Int
    let state: State

    /// The two bits the device sets per mode. All four values are meaningful,
    /// including the two that are not failures.
    enum State: Int, Hashable {
        case unspecifiedError = 0
        case notAttempted = 1
        case failed = 2
        case succeeded = 3
    }

    /// 0xFF01 is the only SVID with a name worth hard-coding; everything else
    /// falls back to its hex, which is the form somebody would search for.
    var svidName: String {
        svid == 0xFF01 ? "DisplayPort" : String(format: "SVID 0x%04X", svid)
    }

    var summary: String {
        switch state {
        case .succeeded: return "\(svidName) entered"
        case .failed: return "\(svidName) was attempted and did not come up"
        case .notAttempted: return "\(svidName) was never attempted"
        case .unspecifiedError: return "\(svidName) failed, with no reason given"
        }
    }

    var isFailure: Bool { state == .failed || state == .unspecifiedError }
}

struct BillboardCapability: Hashable {
    var modes: [BillboardMode] = []
    /// Which mode the device would rather be in, as an index into `modes`.
    var preferred: Int?
    /// The device says it cannot talk USB PD at all, which is a sufficient
    /// explanation on its own for an alt mode that never happened.
    var lacksPowerDelivery = false
    /// The device says it did not have enough power to try.
    var insufficientPower = false

    var failures: [BillboardMode] { modes.filter(\.isFailure) }

    /// The line worth putting on a device row, or nothing.
    ///
    /// A device whose modes all came up has nothing to explain, and saying
    /// "DisplayPort entered" under a working monitor is noise. This speaks only
    /// when something did not work.
    var summary: String? {
        guard let failure = failures.first else { return nil }
        var parts = [failure.summary]
        if lacksPowerDelivery { parts.append("the device reports no USB-PD capability") }
        if insufficientPower { parts.append("the device reports insufficient power") }
        return parts.joined(separator: " — ")
    }
}

/// A device's own account of how fast it can go, from the BOS descriptor.
///
/// This exists because `bcdUSB` cannot answer the question. It looked like it
/// could: a device declaring USB 3.x that enumerated at 480 Mbps has plainly
/// lost its SuperSpeed pairs. But `bcdUSB` describes the enumeration that
/// happened, not the device's capability, and a SuperSpeed device that came up
/// on a USB 2.0 cable trains only on D+/D- and reports itself as USB 2.1. The
/// test could never fire for the exact case it was written for.
///
/// An iPhone 16 Pro on a USB 2.0 cable is that case, and it is what caught it:
/// `bcdUSB` 0x0210, link speed 480 Mbps, and a BOS descriptor saying
/// `wSpeedsSupported` = 0x000E with a SuperSpeedPlus capability declaring
/// 10 Gbps. The 0x0210 is itself the tell — USB 2.1 means "this device has a
/// BOS descriptor", which is where the real answer was the whole time.
struct SpeedCapability: Hashable {
    /// Bit 3 of `wSpeedsSupported`. The device says it has SuperSpeed pairs,
    /// whatever it happens to have enumerated at.
    var supportsSuperSpeed = false
    /// The fastest sublink the SuperSpeedPlus capability declares, in Gbps.
    /// Nil on a device that carries no such capability — plain 5 Gbps
    /// SuperSpeed devices do not — which is why `supportsSuperSpeed` is the
    /// thing gating the verdict and this only sharpens the wording.
    var declaredGbps: Double?
}

/// Fetches and caches a USB device's BOS descriptor, and parses the two
/// capabilities Wattson has a use for.
///
/// IOKit does not publish the BOS, so it is fetched with a standard
/// `GET_DESCRIPTOR(BOS)` control transfer over the legacy
/// `IOUSBDeviceInterface`. This works from an unsandboxed app with no USB
/// entitlement, and — the part that matters — **without opening the device**. A
/// no-open `DeviceRequest` either returns the descriptor or returns an error;
/// it does not disturb a device a kernel driver is holding.
///
/// There is deliberately no fallback to `USBDeviceOpen` on a failed read.
/// whatcable shipped that fallback and force-opening a device its kernel HID
/// driver owned seized a wireless mouse receiver and froze the user's input
/// (their issue #370). A read that fails here is final.
///
/// Verified on hardware: an iPhone 16 Pro answers with 70 bytes across four
/// capabilities and a Ugreen NVMe enclosure with 42 bytes across three, read
/// while both were mounted and in use, with no interruption to either. A
/// Lenovo dock later answered for all thirteen devices behind it at once,
/// including three that returned nothing — a hub, a wireless receiver and a
/// monitor controller, all of them plain USB 2.0 devices with no BOS
/// descriptor to give, which is the ordinary case and not a failure.
enum BOSDescriptor {

    // MARK: - Parsing

    /// Walks the capability list and hands each one to `body` until it returns
    /// a value. Shared by both parses so the walk's bounds checks exist once.
    ///
    /// A zero-length capability would loop here forever and a capability
    /// running past the end is a malformed descriptor; both abandon the walk.
    private static func firstCapability<T>(
        in bos: [UInt8], _ body: (_ type: UInt8, _ bytes: ArraySlice<UInt8>) -> T?
    ) -> T? {
        // BOS header: bLength, bDescriptorType (0x0F), wTotalLength, bNumDeviceCaps.
        guard bos.count >= 5, bos[1] == 0x0F else { return nil }
        let total = Int(bos[2]) | Int(bos[3]) << 8
        guard total <= bos.count else { return nil }

        var offset = Int(bos[0])
        while offset + 3 <= total {
            let length = Int(bos[offset])
            guard length >= 3, offset + length <= total else { return nil }
            // 0x10 is DEVICE CAPABILITY; anything else is not a capability.
            if bos[offset + 1] == 0x10,
               let found = body(bos[offset + 2], bos[offset..<(offset + length)]) {
                return found
            }
            offset += length
        }
        return nil
    }

    /// The Billboard capability (`0x0D`), or nothing.
    static func billboard(in bos: [UInt8]) -> BillboardCapability? {
        firstCapability(in: bos) { type, bytes in
            type == 0x0D ? billboardCapability(from: Array(bytes)) : nil
        }
    }

    /// What the device says it can do, from the SuperSpeed (`0x03`) and
    /// SuperSpeedPlus (`0x0A`) capabilities.
    ///
    /// Both are consulted: `0x03` is the one that says whether SuperSpeed
    /// exists at all, and `0x0A` is the one that says how fast. A device with
    /// neither reports nothing, which is the right answer for a genuinely
    /// USB 2.0 device.
    static func speeds(in bos: [UInt8]) -> SpeedCapability? {
        var capability = SpeedCapability()
        var found = false

        _ = firstCapability(in: bos) { type, bytes -> Bool? in
            let raw = Array(bytes)
            // SuperSpeed USB Device Capability: wSpeedsSupported at offset 4,
            // bit 3 being SuperSpeed.
            if type == 0x03, raw.count >= 10 {
                let speeds = UInt16(raw[4]) | UInt16(raw[5]) << 8
                capability.supportsSuperSpeed = speeds & 0x08 != 0
                found = true
            }
            if type == 0x0A, let gbps = superSpeedPlusGbps(from: raw) {
                capability.declaredGbps = gbps
                found = true
            }
            // Never satisfied, so the walk visits every capability.
            return nil
        }
        return found ? capability : nil
    }

    /// The fastest sublink a SuperSpeedPlus capability declares.
    ///
    /// Each Sublink Speed Attribute is four bytes: a 16-bit mantissa in the top
    /// half and a two-bit exponent selecting bps / Kbps / Mbps / Gbps. Both
    /// devices to hand publish two attributes, a receive and a transmit lane,
    /// each reading mantissa 10 with the Gbps exponent — which is the 10 Gbps
    /// they are sold as.
    static func superSpeedPlusGbps(from bytes: [UInt8]) -> Double? {
        guard bytes.count >= 12 else { return nil }
        let count = Int(bytes[4] & 0x1F) + 1
        guard bytes.count >= 12 + count * 4 else { return nil }

        var best: Double?
        for index in 0..<count {
            let offset = 12 + index * 4
            let attribute = UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8
                | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24
            let mantissa = Double((attribute >> 16) & 0xFFFF)
            guard mantissa > 0 else { continue }
            // 0 bps, 1 Kbps, 2 Mbps, 3 Gbps.
            let gbps: Double
            switch (attribute >> 4) & 0b11 {
            case 3: gbps = mantissa
            case 2: gbps = mantissa / 1000
            case 1: gbps = mantissa / 1_000_000
            default: gbps = mantissa / 1_000_000_000
            }
            // A sublink faster than USB4's own ceiling is a misread, not a
            // device: nothing on USB declares more than 80 Gbps.
            guard gbps > 0, gbps <= 80 else { continue }
            best = max(best ?? 0, gbps)
        }
        return best
    }

    /// Decodes one Billboard Capability Descriptor.
    ///
    /// Fixed part is 44 bytes — through `bReserved` — followed by four bytes
    /// per alternate mode. `bmConfigured` is a 32-byte bitmap carrying two bits
    /// per mode, least significant pair first, which is where the per-mode
    /// state comes from.
    static func billboardCapability(from bytes: [UInt8]) -> BillboardCapability? {
        let fixed = 44
        guard bytes.count >= fixed else { return nil }
        let count = Int(bytes[4])
        // The self-check. A descriptor claiming N modes is exactly 44 + 4N long,
        // and nothing else is a descriptor we have understood.
        guard count <= 128, bytes.count == fixed + count * 4 else { return nil }

        var capability = BillboardCapability()
        let preferred = Int(bytes[5])
        if preferred < count { capability.preferred = preferred }

        let failureInfo = bytes[42]
        capability.lacksPowerDelivery = failureInfo & 0x01 != 0
        capability.insufficientPower = failureInfo & 0x02 != 0

        for index in 0..<count {
            let base = fixed + index * 4
            let svid = Int(bytes[base]) | Int(bytes[base + 1]) << 8
            // bmConfigured starts at offset 8: two bits per mode, so mode i is
            // in byte 8 + i/4 at bit position (i % 4) * 2.
            let configured = bytes[8 + index / 4]
            let raw = Int((configured >> UInt8((index % 4) * 2)) & 0x03)
            guard let state = BillboardMode.State(rawValue: raw) else { return nil }
            capability.modes.append(
                BillboardMode(svid: svid, index: Int(bytes[base + 2]), state: state)
            )
        }
        return capability
    }

    // MARK: - Fetching

    /// Everything Wattson reads out of one device's BOS descriptor.
    ///
    /// Cached by locationID, which is stable for as long as the device stays in
    /// the same port. The descriptor cannot change while a device is plugged
    /// in, and the alternative is two control transfers per device on every
    /// scan — the app rescans every one to two seconds.
    static func read(for service: io_service_t, locationID: Int)
        -> (billboard: BillboardCapability?, speeds: SpeedCapability?) {
        cacheLock.lock()
        if let cached = cache[locationID] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let bos = fetch(service)
        let parsed = (billboard: bos.flatMap(billboard(in:)), speeds: bos.flatMap(speeds(in:)))
        cacheLock.lock()
        // Stored even when both are nil: a device with no BOS descriptor must
        // not be asked again on every scan for the rest of its life in the port.
        cache[locationID] = parsed
        cacheLock.unlock()
        return parsed
    }

    /// Every attached USB device's BOS descriptor as raw bytes, for the
    /// diagnostic capture.
    ///
    /// This exists because `ioreg` cannot produce it. The BOS arrives over a
    /// control transfer, not through the registry, so a capture without this
    /// section carries no evidence about alternate modes or declared link
    /// speeds at all — the two things that need a real dock to observe and are
    /// therefore the two most likely to be worked on from a capture rather
    /// than from the hardware.
    ///
    /// Bytes only, deliberately. The capture's job is the unparsed source; a
    /// capability breakdown here would be Wattson's reading of it, which is the
    /// thing the whole feature exists to keep out.
    ///
    /// Reads fresh rather than through the cache, and does not populate it: a
    /// capture is a moment, and it should not leave the app's state different
    /// from how it found it.
    static func allDescriptors() -> String {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator
        ) == KERN_SUCCESS else { return "<could not enumerate USB devices>" }
        defer { IOObjectRelease(iterator) }

        var lines: [String] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            let properties = IORegistryEntryCreateCFProperties(
                service, &unmanaged, kCFAllocatorDefault, 0
            ) == KERN_SUCCESS ? unmanaged?.takeRetainedValue() as? [String: Any] : nil

            let name = (properties?["USB Product Name"] as? String) ?? "<unnamed>"
            let vendor = (properties?["idVendor"] as? NSNumber)?.intValue ?? 0
            let product = (properties?["idProduct"] as? NSNumber)?.intValue ?? 0
            let location = (properties?["locationID"] as? NSNumber)?.intValue ?? 0
            let bcd = (properties?["bcdUSB"] as? NSNumber)?.intValue ?? 0
            let speed = (properties?["UsbLinkSpeed"] as? NSNumber)?.doubleValue ?? 0
            lines.append(String(
                format: "%@  VID/PID %04X:%04X  locationID 0x%08X  bcdUSB 0x%04X  UsbLinkSpeed %.0f",
                name, vendor, product, location, bcd, speed))

            guard let bos = fetch(service) else {
                // Both are ordinary. A USB 2.0 device predating the BOS
                // descriptor has none to give, and a device a driver is holding
                // exclusively can refuse the request.
                lines.append("   <no BOS descriptor returned — the device has none, or refused the read>")
                continue
            }
            lines.append("   \(bos.count) bytes: "
                + bos.map { String(format: "%02x", $0) }.joined(separator: " "))
        }
        return lines.isEmpty ? "<no USB devices attached>" : lines.joined(separator: "\n")
    }

    /// Drops anything no longer plugged in, so the cache tracks the machine
    /// rather than growing for the lifetime of the process.
    static func forget(except locations: Set<Int>) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache = cache.filter { locations.contains($0.key) }
    }

    private static let cacheLock = NSLock()
    private static var cache: [Int: (billboard: BillboardCapability?, speeds: SpeedCapability?)] = [:]

    // The IOUSBLib plug-in UUIDs. The C headers define these as macros Swift
    // cannot import, so they are rebuilt from their bytes.
    private static let plugInTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
        0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
        0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
    private static let userClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
        0x9D, 0xC7, 0xB7, 0x80, 0x9E, 0xC0, 0x11, 0xD4,
        0xA5, 0x4F, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)
    private static let deviceInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
        0x5C, 0x81, 0x87, 0xD0, 0x9E, 0xF3, 0x11, 0xD4,
        0x8B, 0x45, 0x00, 0x0A, 0x27, 0x05, 0x28, 0x61)

    private static func fetch(_ service: io_service_t) -> [UInt8]? {
        var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
        var score: Int32 = 0
        guard IOCreatePlugInInterfaceForService(
            service, userClientTypeID, plugInTypeID, &plugIn, &score
        ) == KERN_SUCCESS, let plugIn, let interface = plugIn.pointee else { return nil }

        var raw: UnsafeMutableRawPointer?
        let queried = interface.pointee.QueryInterface(
            UnsafeMutableRawPointer(plugIn), CFUUIDGetUUIDBytes(deviceInterfaceID), &raw
        )
        IODestroyPlugInInterface(plugIn)
        guard queried == 0, let raw else { return nil }

        let device = raw.assumingMemoryBound(to: UnsafeMutablePointer<IOUSBDeviceInterface>?.self)
        defer { _ = device.pointee?.pointee.Release(device) }

        // GET_DESCRIPTOR(BOS): device-to-host, standard, device recipient.
        func request(into buffer: inout [UInt8], length: UInt16) -> Int32 {
            var request = IOUSBDevRequest()
            request.bmRequestType = 0x80
            request.bRequest = 0x06
            request.wValue = UInt16(0x0F) << 8
            request.wIndex = 0
            request.wLength = length
            return buffer.withUnsafeMutableBytes { bytes in
                request.pData = bytes.baseAddress
                return device.pointee?.pointee.DeviceRequest(device, &request) ?? -1
            }
        }

        // The five-byte header first, to learn how long the whole thing is.
        var header = [UInt8](repeating: 0, count: 5)
        guard request(into: &header, length: 5) == kIOReturnSuccess, header[1] == 0x0F
        else { return nil }
        let total = Int(header[2]) | Int(header[3]) << 8
        guard total >= 5, total <= 4096 else { return nil }

        var buffer = [UInt8](repeating: 0, count: total)
        guard request(into: &buffer, length: UInt16(total)) == kIOReturnSuccess else { return nil }
        return buffer
    }
}
