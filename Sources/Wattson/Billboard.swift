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

/// Reads the Billboard Capability out of a device's BOS descriptor.
///
/// IOKit does not publish the parsed capability, so the descriptor is fetched
/// with a standard `GET_DESCRIPTOR(BOS)` control transfer over the legacy
/// `IOUSBDeviceInterface`. This works from an unsandboxed app with no USB
/// entitlement, and — this is the important part — **without opening the
/// device**. A no-open `DeviceRequest` either returns the descriptor or returns
/// an error; it does not disturb a device a kernel driver is holding.
///
/// There is deliberately no fallback to `USBDeviceOpen` on a failed read.
/// whatcable shipped that fallback and it seized a wireless mouse receiver from
/// its kernel HID driver and froze the user's input (their issue #370). A read
/// that fails is final here.
///
/// **Not yet verified against hardware.** The layout below is taken from the
/// USB Billboard Device Class specification rather than from a capture, because
/// no device that publishes one has been attached to this machine. It is built
/// to fail into silence accordingly: the descriptor's own length has to account
/// for exactly the number of alternate modes it claims, and any disagreement
/// returns nothing rather than a guess. A misread offset fails that equation
/// almost every time.
enum Billboard {

    // MARK: - Parsing

    /// Finds the Billboard capability inside a BOS descriptor and decodes it.
    /// Pure, so a recorded descriptor replays through exactly this.
    static func parse(bos: [UInt8]) -> BillboardCapability? {
        // BOS header: bLength, bDescriptorType (0x0F), wTotalLength, bNumDeviceCaps.
        guard bos.count >= 5, bos[1] == 0x0F else { return nil }
        let total = Int(bos[2]) | Int(bos[3]) << 8
        guard total <= bos.count else { return nil }

        var offset = Int(bos[0])
        while offset + 3 <= total {
            let length = Int(bos[offset])
            // A zero-length descriptor would loop here forever, and a
            // descriptor running past the end is a malformed one.
            guard length >= 3, offset + length <= total else { return nil }
            // 0x10 DEVICE CAPABILITY, 0x0D BILLBOARD.
            if bos[offset + 1] == 0x10, bos[offset + 2] == 0x0D {
                return capability(from: Array(bos[offset..<(offset + length)]))
            }
            offset += length
        }
        return nil
    }

    /// Decodes one Billboard Capability Descriptor.
    ///
    /// Fixed part is 44 bytes — through `bReserved` — followed by four bytes
    /// per alternate mode. `bmConfigured` is a 32-byte bitmap carrying two bits
    /// per mode, least significant pair first, which is where the per-mode
    /// state comes from.
    static func capability(from bytes: [UInt8]) -> BillboardCapability? {
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

    /// Reads and parses a device's Billboard capability, or nothing.
    ///
    /// Cached by locationID, which is stable for as long as the device stays in
    /// the same port. The descriptor cannot change while a device is plugged
    /// in, and the alternative is two control transfers per device on every
    /// scan — the app rescans every one to two seconds.
    static func capability(for service: io_service_t, locationID: Int) -> BillboardCapability? {
        cacheLock.lock()
        if let cached = cache[locationID] {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let result = fetchBOS(service).flatMap(parse)
        cacheLock.lock()
        // Stored even when nil: a device with no Billboard capability must not
        // be asked again on every scan for the rest of its life in the port.
        cache[locationID] = .some(result)
        cacheLock.unlock()
        return result
    }

    /// Drops anything no longer plugged in, so the cache tracks the machine
    /// rather than growing for the lifetime of the process.
    static func forget(except locations: Set<Int>) {
        cacheLock.lock()
        defer { cacheLock.unlock() }
        cache = cache.filter { locations.contains($0.key) }
    }

    private static let cacheLock = NSLock()
    private static var cache: [Int: BillboardCapability?] = [:]

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

    private static func fetchBOS(_ service: io_service_t) -> [UInt8]? {
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
