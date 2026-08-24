import Foundation
import IOKit

/// Lifetime counters the port controller has been keeping since the machine
/// was built.
///
/// Everything else in the app is a reading of what is happening now. This is
/// the opposite: it is the only place Wattson can say something about a fault
/// that has already finished happening, which is exactly the case the panel
/// was worst at. A dock that drops off the bus once an hour leaves nothing
/// behind to look at by the time anyone opens the panel, and these counters
/// are the record that it happened at all.
///
/// The controller does not say which physical port each entry belongs to, so
/// entries are numbered by their position in the array and nothing more is
/// claimed. That is the same reason port numbering is hedged everywhere else.
struct PortControllerStats: Identifiable, Hashable {
    /// Position in the controller's array. Not a port number.
    let index: Int
    var id: Int { index }

    var attachCount: Int?
    var detachCount: Int?
    var hardResetCount: Int?
    var shortDetectCount: Int?
    var i2cErrorCount: Int?
    var dataRoleSwapCount: Int?
    var dataRoleSwapFailCount: Int?
    var powerRoleSwapCount: Int?
    var powerRoleSwapFailCount: Int?
    var vdoFailCount: Int?
    var fetEnableFailCount: Int?
    var wakeFailCount: Int?
    var wakeTimeoutCount: Int?
    var stuckCommandCount: Int?
    var surpriseNackCount: Int?
    var firmwareVersion: Int?

    /// Counters that only move when something went wrong.
    ///
    /// Attach and detach are excluded on purpose: unplugging a cable is not a
    /// fault, and counting it as one would put a permanent warning on every
    /// machine anyone has ever used.
    var faultCounts: [(name: String, count: Int)] {
        [
            ("Hard resets", hardResetCount),
            ("Short detected", shortDetectCount),
            ("I²C errors", i2cErrorCount),
            ("Data role swap failures", dataRoleSwapFailCount),
            ("Power role swap failures", powerRoleSwapFailCount),
            ("Identity request failures", vdoFailCount),
            ("Power switch enable failures", fetEnableFailCount),
            ("Wake failures", wakeFailCount),
            ("Wake timeouts", wakeTimeoutCount),
            ("Stuck commands", stuckCommandCount),
            ("Unexpected NAKs", surpriseNackCount),
        ].compactMap { name, value in
            guard let value, value > 0 else { return nil }
            return (name, value)
        }
    }

    var hasFaults: Bool { !faultCounts.isEmpty }
}

/// Per-port USB host counters, which cover the data side rather than the power
/// side: a device that enumerates and vanishes, or one drawing more than the
/// port will give it.
struct USBHostPortStats: Identifiable, Hashable {
    let id: String
    var portNumber: Int?
    var connectCount: Int?
    var overcurrentCount: Int?
    var enumerationFailureCount: Int?
    var addressFailureCount: Int?
    var remoteWakeCount: Int?
    /// Link-layer errors counted by the host controller.
    var linkErrorCount: Int?
    /// End-of-frame timing violations — a device or cable putting traffic
    /// where the bus does not allow it.
    var eof2ViolationCount: Int?

    var faultCounts: [(name: String, count: Int)] {
        [
            ("Over-current", overcurrentCount),
            ("Enumeration failures", enumerationFailureCount),
            ("Address failures", addressFailureCount),
            ("Link errors", linkErrorCount),
            ("Frame timing violations", eof2ViolationCount),
        ].compactMap { name, value in
            guard let value, value > 0 else { return nil }
            return (name, value)
        }
    }

    var hasFaults: Bool { !faultCounts.isEmpty }
}

/// Reads both sets of counters. Neither costs a subprocess and neither moves
/// often, so this is read on panel open rather than on the power tick.
enum PortStatsMonitor {

    static func readControllers() -> [PortControllerStats] {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return [] }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return [] }
        return controllers(from: properties)
    }

    /// Decodes the controller array out of an `AppleSmartBattery` property
    /// dictionary. Split from the read above so `--selftest` can replay a
    /// recorded one; the counters are all zero on a healthy machine, which
    /// makes a live read a poor test of whether the parse works at all.
    static func controllers(from properties: [String: Any]) -> [PortControllerStats] {
        guard let entries = properties["PortControllerInfo"] as? [[String: Any]] else { return [] }
        return entries.enumerated().map { index, entry in
            var stats = PortControllerStats(index: index)
            stats.attachCount = int(entry["PortControllerAttachCount"])
            stats.detachCount = int(entry["PortControllerDetachCount"])
            stats.hardResetCount = int(entry["PortControllerHardResetCount"])
            stats.shortDetectCount = int(entry["PortControllerShortDetectCount"])
            stats.i2cErrorCount = int(entry["PortControllerI2cErrCount"])
            stats.dataRoleSwapCount = int(entry["PortControllerDataRoleSwapCount"])
            stats.dataRoleSwapFailCount = int(entry["PortControllerDataRoleSwapFailCount"])
            stats.powerRoleSwapCount = int(entry["PortControllerPwrRoleSwapCount"])
            stats.powerRoleSwapFailCount = int(entry["PortControllerPwrRoleSwapFailCount"])
            stats.vdoFailCount = int(entry["PortControllerVdoFailCount"])
            stats.fetEnableFailCount = int(entry["PortControllerInpFetEnFailCount"])
            stats.wakeFailCount = int(entry["PortControllerWakeFailCount"])
            stats.wakeTimeoutCount = int(entry["PortControllerWakeTimeoutCount"])
            stats.stuckCommandCount = int(entry["PortControllerStuckCmdCount"])
            stats.surpriseNackCount = int(entry["PortControllerSurpriseNackCount"])
            stats.firmwareVersion = int(entry["PortControllerFwVersion"])
            return stats
        }
    }

    static func readUSBPorts() -> [USBHostPortStats] {
        var iterator: io_iterator_t = 0
        // The base class covers every controller-specific subclass by name.
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault, IOServiceMatching("AppleUSBHostPort"), &iterator
        ) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var results: [USBHostPortStats] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            var unmanaged: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let properties = unmanaged?.takeRetainedValue() as? [String: Any],
                  let stats = usbPort(from: properties, id: "port-\(results.count)")
            else { continue }
            results.append(stats)
        }
        return results
    }

    /// Decodes one `AppleUSBHostPort` property dictionary.
    ///
    /// The physical port comes from `UsbIOPort`, a registry path to the HPM
    /// node — the port's own `UsbCPortNumber` is deliberately not consulted,
    /// because it numbers ports within a controller rather than on the case.
    static func usbPort(from properties: [String: Any], id: String) -> USBHostPortStats? {
        // The container is kebab-case where every counter inside it is not.
        guard let raw = properties["port-statistics"] as? [String: Any] else { return nil }
        var stats = USBHostPortStats(id: id)
        if let path = properties["UsbIOPort"] as? String,
           let last = path.split(separator: "@").last,
           let number = Int(last.prefix(while: \.isNumber)) {
            stats.portNumber = number
        }
        stats.connectCount = int(raw["kPortStatConnectCount"])
        stats.overcurrentCount = int(raw["kPortStatOverCurrentCount"])
        stats.enumerationFailureCount = int(raw["kPortStatEnumerationFailureCount"])
        stats.addressFailureCount = int(raw["kPortStatAddressFailureCount"])
        stats.remoteWakeCount = int(raw["kPortStatRemoteWakeCount"])
        stats.eof2ViolationCount = int(raw["kPortStatEOF2ViolationCount"])
        // Counted on the port itself rather than inside the statistics dict.
        stats.linkErrorCount = int(properties["link-error-count"])
        return stats
    }

    private static func int(_ value: Any?) -> Int? {
        (value as? NSNumber)?.intValue
    }
}

/// One heading's worth of fault counters, as the panel renders them.
struct PortFaultGroup: Identifiable {
    let id: String
    let name: String
    let entries: [(name: String, count: Int)]
}
