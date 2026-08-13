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

    /// Every key the SMC will admit to, with its type, decoded value and raw
    /// bytes.
    ///
    /// The keys Wattson reads had to be known in advance to be read at all, so
    /// a capture that lists only those can confirm what is already understood
    /// and never turn up anything new. This walks the controller's own key
    /// index instead, which is the only way a future reading gets found rather
    /// than guessed at.
    ///
    /// The raw bytes are printed next to every decoded value on purpose: the
    /// type table below covers what Apple actually uses for power, and a
    /// mistake in it should cost a misread line, not the evidence.
    static func allKeyValues() -> String {
        guard open() else { return "<AppleSMC could not be opened>" }
        guard let (_, countBytes) = rawBytes(forKey: "#KEY"), countBytes.count >= 4 else {
            return "<AppleSMC would not report its key count>"
        }
        let count = Int(UInt32(countBytes[0]) << 24 | UInt32(countBytes[1]) << 16
            | UInt32(countBytes[2]) << 8 | UInt32(countBytes[3]))
        guard count > 0, count < 10_000 else { return "<implausible key count \(count)>" }

        var lines = ["\(count) keys reported by the controller"]
        for index in 0..<count {
            guard let key = keyName(at: index) else {
                lines.append("[\(index)] <no key at this index>")
                continue
            }
            guard let (info, bytes) = rawBytes(forKey: key) else {
                lines.append("\(key)  <unreadable>")
                continue
            }
            let hex = bytes.map { String(format: "%02X", $0) }.joined()
            let type = typeCode(info.dataType).trimmingCharacters(in: .whitespaces)
            let decoded = decode(bytes: bytes, type: typeCode(info.dataType)) ?? "—"
            lines.append(String(format: "%@  type=%-4@ size=%u  value=%@  raw=%@",
                                key, type as NSString, info.dataSize, decoded, hex))
        }
        return lines.joined(separator: "\n")
    }

    /// SMC scalars are big-endian, except `flt` which is a little-endian IEEE
    /// float — the one exception that matters, since every power key is one.
    private static func decode(bytes: [UInt8], type: String) -> String? {
        func unsigned(_ count: Int) -> UInt64? {
            guard bytes.count >= count else { return nil }
            return bytes.prefix(count).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Float(bitPattern: bits)
            return value.isFinite ? String(value) : nil
        case "ui8 ", "hex_": return unsigned(1).map(String.init)
        case "ui16": return unsigned(2).map(String.init)
        case "ui32": return unsigned(4).map(String.init)
        case "si8 ": return bytes.first.map { String(Int8(bitPattern: $0)) }
        case "si16":
            return unsigned(2).map { String(Int16(bitPattern: UInt16(truncatingIfNeeded: $0))) }
        case "sp78":
            // Signed fixed point, eight fractional bits.
            return unsigned(2).map {
                String(Double(Int16(bitPattern: UInt16(truncatingIfNeeded: $0))) / 256)
            }
        case "flag": return bytes.first.map { $0 == 0 ? "false" : "true" }
        case "ch8*":
            let text = String(bytes: bytes.prefix { $0 != 0 }, encoding: .ascii)
            return text?.isEmpty == false ? text : nil
        default: return nil
        }
    }

    private static func keyName(at index: Int) -> String? {
        var input = ParamStruct()
        input.data8 = readKeyFromIndex
        input.data32 = UInt32(index)
        guard let output = call(&input) else { return nil }
        let key = output.key
        let characters = [UInt8((key >> 24) & 0xFF), UInt8((key >> 16) & 0xFF),
                          UInt8((key >> 8) & 0xFF), UInt8(key & 0xFF)]
        guard characters.allSatisfy({ $0 >= 0x20 && $0 < 0x7F }) else { return nil }
        return String(bytes: characters, encoding: .ascii)
    }

    private static func rawBytes(forKey key: String) -> (KeyInfo, [UInt8])? {
        guard let info = info(for: key), info.dataSize > 0 else { return nil }
        var input = ParamStruct()
        input.key = code(key)
        input.keyInfo = info
        input.data8 = readBytes
        guard let output = call(&input) else { return nil }
        var raw = output.bytes
        return (info, withUnsafeBytes(of: &raw) { Array($0.prefix(Int(min(info.dataSize, 32)))) })
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
    private static let readKeyFromIndex: UInt8 = 8
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
