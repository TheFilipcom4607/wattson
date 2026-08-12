import DiskArbitration
import Foundation
import IOKit

/// A mounted volume, tied to the USB device it lives on.
struct VolumeInfo: Identifiable, Hashable {
    /// BSD name of the volume's own media, e.g. "disk4s1".
    let id: String
    let name: String
    let url: URL
    /// `DeviceNode.id` of the enclosing USB device. A volume with no USB device
    /// above it is somebody else's problem and never reaches this struct.
    let deviceID: String
    let totalBytes: Int64?
    let availableBytes: Int64?

    /// "58.2 GB free of 128 GB"
    var capacitySummary: String? {
        guard let totalBytes else { return nil }
        let total = Self.format(totalBytes)
        guard let availableBytes else { return total }
        return "\(Self.format(availableBytes)) free of \(total)"
    }

    /// How full it is, for the bar. Nil when the volume did not report both.
    var usedFraction: Double? {
        guard let totalBytes, totalBytes > 0, let availableBytes else { return nil }
        return min(max(Double(totalBytes - availableBytes) / Double(totalBytes), 0), 1)
    }

    private static func format(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}

/// Finds mounted volumes and maps each one to the USB device underneath it.
///
/// The mapping runs volume → device rather than device → volume: there are a
/// handful of volumes and potentially dozens of USB nodes, and the volume side
/// hands you a direct route down to the media and back up the service plane.
final class VolumeMonitor {
    private let session: DASession?

    init() {
        session = DASessionCreate(kCFAllocatorDefault)
        // Unmount and eject answer asynchronously; main is where the answer is
        // wanted, and both callbacks do nothing but hand a string back.
        if let session {
            DASessionSetDispatchQueue(session, DispatchQueue.main)
        }
    }

    func read() -> [VolumeInfo] {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ]
        guard let session,
              let urls = FileManager.default.mountedVolumeURLs(
                  includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
              )
        else { return [] }

        return urls.compactMap { url -> VolumeInfo? in
            guard let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL),
                  let bsdName = DADiskGetBSDName(disk).map({ String(cString: $0) }),
                  let location = usbLocation(of: disk)
            else { return nil }

            let values = try? url.resourceValues(forKeys: Set(keys))
            return VolumeInfo(
                id: bsdName,
                name: values?.volumeName ?? url.lastPathComponent,
                url: url,
                deviceID: "usb-\(location)",
                totalBytes: values?.volumeTotalCapacity.map(Int64.init),
                availableBytes: values?.volumeAvailableCapacity.map(Int64.init)
            )
        }
    }

    /// Walks up the service plane from the volume's media to the USB device
    /// enclosing it, and reads the locationID the device tree is already keyed by.
    private func usbLocation(of disk: DADisk) -> Int? {
        var entry = DADiskCopyIOMedia(disk)
        defer { if entry != IO_OBJECT_NULL { IOObjectRelease(entry) } }

        // Deep enough for media → partition scheme → block storage → interface →
        // device, with room to spare; a runaway loop here would hang a scan.
        for _ in 0..<24 {
            guard entry != IO_OBJECT_NULL else { return nil }
            if IOObjectConformsTo(entry, "IOUSBHostDevice") != 0 {
                var properties: Unmanaged<CFMutableDictionary>?
                guard IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                      let dictionary = properties?.takeRetainedValue() as? [String: Any]
                else { return nil }
                return (dictionary["locationID"] as? NSNumber)?.intValue
            }
            var parent: io_registry_entry_t = 0
            let status = IORegistryEntryGetParentEntry(entry, kIOServicePlane, &parent)
            IOObjectRelease(entry)
            entry = status == KERN_SUCCESS ? parent : IO_OBJECT_NULL
        }
        return nil
    }

    /// Unmounts the whole disk and then ejects it.
    ///
    /// Whole rather than per-volume on purpose: a stick with two partitions
    /// ejected one volume at a time is left half-mounted, which is exactly the
    /// state "safe to remove" is supposed to rule out.
    ///
    /// `completion` gets nil on success, or a line to show the user — unmount
    /// fails routinely because something still holds a file open, and a button
    /// that silently does nothing is worse than no button.
    func eject(_ volume: VolumeInfo, completion: @escaping (String?) -> Void) {
        guard let session,
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume.url as CFURL),
              let whole = DADiskCopyWholeDisk(disk)
        else {
            completion("Could not find the disk to eject")
            return
        }
        let request = Unmanaged.passRetained(EjectRequest(completion)).toOpaque()
        DADiskUnmount(whole, DADiskUnmountOptions(kDADiskUnmountOptionWhole), unmountCallback, request)
    }
}

/// Carries the completion handler through DiskArbitration's C callbacks, which
/// cannot capture context any other way.
private final class EjectRequest {
    let completion: (String?) -> Void

    init(_ completion: @escaping (String?) -> Void) {
        self.completion = completion
    }
}

private let unmountCallback: DADiskUnmountCallback = { disk, dissenter, context in
    guard let context else { return }
    if let dissenter {
        let request = Unmanaged<EjectRequest>.fromOpaque(context).takeRetainedValue()
        request.completion(describe(dissenter, fallback: "Could not unmount the disk"))
        return
    }
    // Unmounted cleanly. Ejecting spins the media down and powers the slot off
    // where the bus supports it; the disk is already safe to pull either way.
    DADiskEject(disk, DADiskEjectOptions(kDADiskEjectOptionDefault), ejectCallback, context)
}

private let ejectCallback: DADiskEjectCallback = { _, dissenter, context in
    guard let context else { return }
    let request = Unmanaged<EjectRequest>.fromOpaque(context).takeRetainedValue()
    request.completion(dissenter.map {
        describe($0, fallback: "Unmounted, but the drive did not power down")
    })
}

/// DiskArbitration usually dissents with a status code and no string, and
/// "error 0xF8DA0002" is not something to put in front of somebody.
private func describe(_ dissenter: DADissenter, fallback: String) -> String {
    if let reason = DADissenterGetStatusString(dissenter) as String?, !reason.isEmpty {
        return reason
    }
    let status = DADissenterGetStatus(dissenter)
    if matches(status, kDAReturnBusy) {
        return "Something is still using it — close any open files and try again"
    }
    if matches(status, kDAReturnNotPermitted) || matches(status, kDAReturnNotPrivileged) {
        return "macOS would not allow it"
    }
    if matches(status, kDAReturnNotMounted) {
        return "It is not mounted"
    }
    return fallback
}

/// `DAReturn` is a signed 32-bit code and the constants import as `Int` in the
/// 0xF8DA____ range, so neither side can be widened to the other without a trap.
private func matches(_ status: DAReturn, _ constant: Int) -> Bool {
    UInt32(bitPattern: Int32(truncatingIfNeeded: status))
        == UInt32(bitPattern: Int32(truncatingIfNeeded: constant))
}
