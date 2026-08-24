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
///   D<n>UI — the port controller a D channel belongs to, as a UUID
///   D<n>DE — the SMC's own words for what is on that channel
///   D<n>JV / D<n>JI — VBUS out on that channel, volts and amps
///   B0AV / B0AC — live pack voltage and current
///   B0FC / B0DC / B0CT — full-charge and design capacity, cycle count
///   B0TE / B0TF — minutes to empty and to full
///
/// Integers are little-endian, which is not what the older published SMC
/// descriptions say. Four independent cross-checks against the IORegistry
/// settle it on this Mac: B0CT reads 13 against `CycleCount` 13, B0DC 4629
/// against `DesignCapacity` 4629, BQX1 4901 against `BatteryData.Qmax[0]`
/// 4901, and BFWC 4747 against `BatteryData.DataFlashWriteCount` 4747. Every
/// one of those is nonsense read the other way round. `#KEY` is the exception
/// and is genuinely big-endian — read little-endian its key count comes out as
/// 1,376,256,000.
enum SMCMonitor {

    // MARK: - Public

    /// Measured power leaving one USB-C port toward an accessory.
    struct PortPower {
        var volts: Double
        var amps: Double
        var watts: Double { volts * amps }
    }

    /// One of the SMC's `D` channels: a power rail, and the port controller it
    /// belongs to.
    struct PortChannel {
        /// The `n` in `D<n>JV`. Numbering internal to the SMC.
        let index: Int
        /// `D<n>UI`, as 32 lowercase hex characters with the dashes taken out.
        ///
        /// This is what ties a channel to a physical port. It is the same value
        /// the port's own controller node publishes as `UUID`, so the join is a
        /// stated identity rather than an assumption about numbering.
        let controllerUUID: String?
        /// `D<n>DE` — how the SMC describes whatever is on the channel, in its
        /// own words. Reads "pd charger" for a charging brick. Carried through
        /// verbatim; it is a label, not a classification we made.
        let sourceDescription: String?
        /// Measured VBUS, when the rail is actually carrying something.
        let power: PortPower?
    }

    /// Every D channel the SMC will answer for, measured rather than budgeted.
    ///
    /// The index is *not* the physical port number. It happens to match on this
    /// Mac — D1UI is the controller behind Port-USB-C@1 and D2UI the one behind
    /// Port-USB-C@2 — but that is a fact this reader now establishes rather
    /// than assumes, because `D<n>UI` names the controller outright. Machines
    /// that number their USB-C ports non-contiguously are the case where the
    /// old assumption put a port's measured VBUS on a different port.
    ///
    /// Scanned to 4. Six-port machines exist and publish D5UI/D6UI, but no
    /// capture anywhere shows them publishing D5/D6 *rails*, so a wider scan
    /// would only turn up channels whose volts and amps are structurally zero.
    static func portChannels() -> [PortChannel] {
        guard open() else { return [] }
        return (1...4).compactMap { index in
            let uuid = hexString(forKey: "D\(index)UI")
            let description = text(forKey: "D\(index)DE")
            var power: PortPower?
            if let volts = value(forKey: "D\(index)JV"),
               let amps = value(forKey: "D\(index)JI"),
               volts > 0.1, amps > 0.001 {
                power = PortPower(volts: volts, amps: amps)
            }
            // A channel that names no controller, describes nothing and carries
            // nothing is an empty slot in the SMC's table, not a port.
            guard uuid != nil || description != nil || power != nil else { return nil }
            return PortChannel(
                index: index,
                controllerUUID: uuid,
                sourceDescription: description,
                power: power
            )
        }
    }

    /// What the fuel gauge is doing right now, as opposed to when the
    /// IORegistry last copied it out.
    ///
    /// The registry's `Voltage` and `InstantAmperage` sit still for 10-30 s at
    /// a time; these keys move every sample. Watched over three seconds with
    /// nothing plugged in, B0AC read -410, -554 and -455 mA while the registry
    /// held -401 throughout.
    ///
    /// Capacities are the gauge's own figures, not macOS's rounded ones: B0FC
    /// tracks `AppleRawMaxCapacity` exactly (4637 against 4637), which is the
    /// number Wattson already computes health from, rather than the smoothed
    /// `MaxCapacity` percentage.
    struct BatteryReading {
        var volts: Double?
        /// Positive charges the pack, negative drains it.
        var amps: Double?
        var fullChargeCapacity: Int?
        var designCapacity: Int?
        var cycleCount: Int?
        /// Minutes. The gauge reports 65535 for "no estimate", which is dropped
        /// here rather than shown as a 45-day runtime.
        var minutesToEmpty: Int?
        var minutesToFull: Int?

        var watts: Double? {
            guard let volts, let amps else { return nil }
            return volts * amps / 1_000_000
        }
    }

    static func battery() -> BatteryReading {
        guard open() else { return BatteryReading() }
        func estimate(_ key: String) -> Int? {
            guard let minutes = integer(forKey: key), minutes != 0xFFFF else { return nil }
            return minutes
        }
        return BatteryReading(
            volts: integer(forKey: "B0AV").map(Double.init),
            amps: integer(forKey: "B0AC").map(Double.init),
            fullChargeCapacity: integer(forKey: "B0FC"),
            designCapacity: integer(forKey: "B0DC"),
            cycleCount: integer(forKey: "B0CT"),
            minutesToEmpty: estimate("B0TE"),
            minutesToFull: estimate("B0TF")
        )
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
            let decoded = decode(bytes: bytes, type: typeCode(info.dataType), key: key) ?? "—"
            lines.append(String(format: "%@  type=%-4@ size=%u  value=%@  raw=%@",
                                key, type as NSString, info.dataSize, decoded, hex))
        }
        return lines.joined(separator: "\n")
    }

    /// SMC scalars are little-endian on Apple silicon, `flt` included.
    ///
    /// This used to decode integers big-endian, which is what the older
    /// published descriptions of the SMC say and is how it worked on Intel. It
    /// printed `CycleCount` 13 as 3328 and `DesignCapacity` 4629 as 5394 in
    /// every capture. Four keys settle it against IORegistry values that cannot
    /// both be right: B0CT/`CycleCount`, B0DC/`DesignCapacity`,
    /// BQX1/`BatteryData.Qmax[0]` and BFWC/`BatteryData.DataFlashWriteCount`.
    ///
    /// `#KEY` really is big-endian and is the only key excepted. It is not a
    /// measurement — it is the controller's own key count, and the walk above
    /// reads it separately for exactly that reason.
    ///
    /// One question is left open on purpose: whatport reads D<n>MP / D<n>MV /
    /// D<n>MI as big-endian, and this Mac reports them as zero with nothing
    /// plugged in, so there is no reading here that could tell the two apart.
    /// Wattson does not read those keys, and this dump prints the raw bytes
    /// beside every value, so a key that disagrees costs a line rather than the
    /// evidence.
    static func decode(bytes: [UInt8], type: String, key: String) -> String? {
        func unsigned(_ count: Int) -> UInt64? {
            guard bytes.count >= count else { return nil }
            guard key != "#KEY" else {
                return bytes.prefix(count).reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
            }
            return bytes.prefix(count).reversed().reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        }
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16 | UInt32(bytes[3]) << 24
            let value = Float(bitPattern: bits)
            return value.isFinite ? String(value) : nil
        case "ui8 ": return unsigned(1).map(String.init)
        // `hex_` is a blob, not a number. DxUI is sixteen bytes of it, and
        // decoding only the first one hid the join key this reader now uses.
        case "hex_": return bytes.map { String(format: "%02x", $0) }.joined()
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

    /// An SMC integer, little-endian, sign-extended when the key's own type
    /// says it is signed.
    ///
    /// The type comes from the controller rather than a table here, so a key
    /// that changes width between machines still reads correctly, and a key
    /// that is not an integer at all reads as nothing instead of as garbage.
    private static func integer(forKey key: String) -> Int? {
        guard let (info, bytes) = rawBytes(forKey: key) else { return nil }
        let width = Int(info.dataSize)
        guard width > 0, width <= 8, bytes.count >= width else { return nil }
        let magnitude = bytes.prefix(width).reversed()
            .reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
        switch typeCode(info.dataType) {
        case "si8 ", "si16", "si32", "si64":
            // Sign bit is the top bit of the value's own width, not of UInt64.
            let signBit = UInt64(1) << (width * 8 - 1)
            guard magnitude & signBit != 0 else { return Int(magnitude) }
            return Int(bitPattern: UInt(magnitude | ~(signBit &* 2 &- 1)))
        case "ui8 ", "ui16", "ui32", "ui64", "hex_", "flag":
            return Int(magnitude)
        default:
            return nil
        }
    }

    /// A `hex_` key as lowercase hex, which is the form the port controllers
    /// publish their UUIDs in once the dashes are taken out.
    private static func hexString(forKey key: String) -> String? {
        guard let (_, bytes) = rawBytes(forKey: key), !bytes.isEmpty else { return nil }
        // A channel with no controller answers with zeros rather than refusing,
        // and an all-zero UUID would join to nothing while looking like an
        // answer.
        guard bytes.contains(where: { $0 != 0 }) else { return nil }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }

    /// A `ch8*` key as text, trimmed at the first NUL.
    private static func text(forKey key: String) -> String? {
        guard let (_, bytes) = rawBytes(forKey: key) else { return nil }
        let value = String(bytes: bytes.prefix { $0 != 0 }, encoding: .ascii)?
            .trimmingCharacters(in: .whitespaces)
        return value?.isEmpty == false ? value : nil
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
