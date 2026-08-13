import Foundation
import IOKit

/// Direct AppleSMC reader.
///
/// The IORegistry's battery entry only refreshes every 10-30 seconds, which is
/// far too slow for a live meter. The SMC itself updates about once a second,
/// so the wattage numbers come from here instead.
///
/// Keys used:
///   PSTR — total system power draw, watts
///   PDTR — power arriving from the adapter, watts
///   PPBR — power crossing the battery rail, watts (unsigned)
enum SMCMonitor {

    // MARK: - Public

    /// Measured power leaving one USB-C port toward an accessory.
    struct PortPower {
        var volts: Double
        var amps: Double
        var watts: Double { volts * amps }
    }

    /// VBUS output per port, measured rather than budgeted.
    ///
    /// Keys are D<n>JV (volts) and D<n>JI (amps); rail number matches the port
    /// number AppleHPM reports. Verified against a phone charging on port 2 and
    /// cross-checked with an inline USB-C meter.
    static func portPower() -> [Int: PortPower] {
        guard open() else { return [:] }
        var result: [Int: PortPower] = [:]
        for index in 1...3 {
            guard let volts = value(forKey: "D\(index)JV"),
                  let amps = value(forKey: "D\(index)JI"),
                  volts > 0.1, amps > 0.001
            else { continue }
            result[index] = PortPower(volts: volts, amps: amps)
        }
        return result
    }

    struct Reading {
        /// What the machine consumes, excluding anything going into the battery.
        var systemWatts: Double?
        var adapterWatts: Double?

        /// Positive charges the battery, negative drains it.
        ///
        /// Whatever arrives and is not consumed is charging; when nothing
        /// arrives, consumption comes out of the cell. Verified against the
        /// battery's own volts x amps while charging: 38.5 W here, 39.4 W there.
        var batteryFlow: Double? {
            guard let system = systemWatts else { return nil }
            return (adapterWatts ?? 0) - system
        }

        var hasAdapter: Bool { (adapterWatts ?? 0) > 0.05 }
    }

    static func read() -> Reading {
        guard open() else { return Reading() }
        return Reading(
            systemWatts: value(forKey: "PSTR"),
            adapterWatts: value(forKey: "PDTR")
        )
    }

    /// The direct SMC key values Wattson reads for its live power display.
    /// They are intentionally not combined or converted into any UI summary;
    /// this is used by the raw diagnostic capture.
    static func diagnosticValues() -> String {
        let keys = ["PSTR", "PDTR", "D1JV", "D1JI", "D2JV", "D2JI", "D3JV", "D3JI"]
        guard open() else { return "<AppleSMC could not be opened>" }
        return keys.map { key in
            guard let value = value(forKey: key) else { return "\(key)=<not available>" }
            return "\(key)=\(value)"
        }
        .joined(separator: "\n")
    }

    // MARK: - Connection

    private static var connection: io_connect_t = 0
    private static var keyInfoCache: [String: KeyInfo] = [:]

    @discardableResult
    private static func open() -> Bool {
        guard connection == 0 else { return true }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == kIOReturnSuccess
    }

    private static func value(forKey key: String) -> Double? {
        guard let info = info(for: key) else { return nil }
        var input = ParamStruct()
        input.key = code(key)
        input.keyInfo = info
        input.data8 = readBytes
        guard let output = call(&input) else { return nil }

        var raw = output.bytes
        let bytes = withUnsafeBytes(of: &raw) { Array($0.prefix(Int(info.dataSize))) }
        // Every power key is a little-endian float; other types are not needed here.
        guard typeCode(info.dataType) == "flt ", bytes.count >= 4 else { return nil }
        let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
            | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
        let result = Double(Float(bitPattern: bits))
        return result.isFinite ? result : nil
    }

    private static func info(for key: String) -> KeyInfo? {
        if let cached = keyInfoCache[key] { return cached }
        var input = ParamStruct()
        input.key = code(key)
        input.data8 = readKeyInfo
        guard let output = call(&input) else { return nil }
        keyInfoCache[key] = output.keyInfo
        return output.keyInfo
    }

    private static func call(_ input: inout ParamStruct) -> ParamStruct? {
        var output = ParamStruct()
        var size = MemoryLayout<ParamStruct>.stride
        let status = IOConnectCallStructMethod(
            connection, kernelIndex, &input, MemoryLayout<ParamStruct>.stride, &output, &size
        )
        return status == kIOReturnSuccess && output.result == 0 ? output : nil
    }

    private static func code(_ key: String) -> UInt32 {
        key.utf8.reduce(UInt32(0)) { ($0 << 8) + UInt32($1) }
    }

    private static func typeCode(_ value: UInt32) -> String {
        String(bytes: [UInt8((value >> 24) & 0xFF), UInt8((value >> 16) & 0xFF),
                       UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)],
               encoding: .ascii) ?? ""
    }

    // MARK: - AppleSMC structures

    private static let kernelIndex: UInt32 = 2
    private static let readBytes: UInt8 = 5
    private static let readKeyInfo: UInt8 = 9

    private typealias Bytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                               UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    private struct Version {
        var major: UInt8 = 0, minor: UInt8 = 0, build: UInt8 = 0, reserved: UInt8 = 0
        var release: UInt16 = 0
    }

    private struct PLimitData {
        var version: UInt16 = 0, length: UInt16 = 0
        var cpuPLimit: UInt32 = 0, gpuPLimit: UInt32 = 0, memPLimit: UInt32 = 0
    }

    private struct KeyInfo {
        var dataSize: UInt32 = 0, dataType: UInt32 = 0, dataAttributes: UInt8 = 0
    }

    private struct ParamStruct {
        var key: UInt32 = 0
        var vers = Version()
        var pLimitData = PLimitData()
        var keyInfo = KeyInfo()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: Bytes = (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
                            0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    }
}
