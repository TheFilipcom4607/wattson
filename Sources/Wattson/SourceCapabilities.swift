import Foundation

/// One offer from a charger's Source_Capabilities, decoded from the raw 32-bit
/// power data object.
///
/// The layouts are USB PD R3.2 §6.4.1, checked field by field against two
/// independent readings of the same tables: Linux's `include/linux/usb/pd.h`
/// and whatcable's `PDO.decode`. All three agree on every shift, mask and unit.
///
/// What has been seen on hardware and what has not is not the same for every
/// case, and the difference matters:
///
/// - **Fixed** words are checked against a second publication every time they
///   are used (see `PowerMonitor.sourceCapabilities(from:)`), and have been
///   on the Amazon dock in both the 85 W and the 96 W shapes it has reported.
/// - **SPR PPS** has been seen from one 100 W charger: attached on 15
///   October, `0xc1a4325f`, 5-21 V at up to 4.75 A, on an array whose fixed
///   words agreed with the menu; and earlier as `0xc1a43264`, 5 A, left
///   behind after it had been unplugged.
/// - **EPR AVS, SPR AVS, Variable and Battery** have never been captured from a
///   real source. Their decodes rest on the spec layout alone, and the
///   `--selftest` fixtures for them are words assembled by hand from it.
///
/// A word whose APDO subtype is the reserved `11b` is not decoded at all.
/// whatcable falls back to the PPS layout there "so we still show something";
/// here that is exactly the thing not to do.
enum SourceOffer: Hashable {
    /// The spec's 50 mV and 10 mA units, kept as integers so a comparison with
    /// the adapter's own millivolt / milliamp menu is exact.
    case fixed(millivolts: Int, milliamps: Int)
    case variable(minMillivolts: Int, maxMillivolts: Int, milliamps: Int)
    case battery(minMillivolts: Int, maxMillivolts: Int, milliwatts: Int)
    /// SPR Programmable Power Supply. Bit 27, "PPS Power Limited", is not
    /// carried: it says the source may not hold the full current across the
    /// whole range, and "up to" already promises no more than that.
    case pps(minMillivolts: Int, maxMillivolts: Int, milliamps: Int)
    /// EPR Adjustable Voltage Supply, rated in watts (its PDP) rather than amps.
    case eprAVS(minMillivolts: Int, maxMillivolts: Int, watts: Int)
    /// SPR Adjustable Voltage Supply. It carries no voltages: the spec fixes
    /// the range at 9 V to 15 V, then 15 V to 20 V, and quotes a current for
    /// each. A zero second current means the range stops at 15 V.
    case sprAVS(milliamps9To15: Int, milliamps15To20: Int)

    /// Nil for a zero word, a reserved APDO subtype, and the filler words macOS
    /// is known to leave in the array (see `isPlausible`).
    init?(word: UInt32) {
        guard word != 0 else { return nil }
        let offer: SourceOffer
        switch word >> 30 {
        case 0b00:
            offer = .fixed(millivolts: Int((word >> 10) & 0x3FF) * 50,
                           milliamps: Int(word & 0x3FF) * 10)
        case 0b01:
            offer = .battery(minMillivolts: Int((word >> 10) & 0x3FF) * 50,
                             maxMillivolts: Int((word >> 20) & 0x3FF) * 50,
                             milliwatts: Int(word & 0x3FF) * 250)
        case 0b10:
            offer = .variable(minMillivolts: Int((word >> 10) & 0x3FF) * 50,
                              maxMillivolts: Int((word >> 20) & 0x3FF) * 50,
                              milliamps: Int(word & 0x3FF) * 10)
        default:
            switch (word >> 28) & 0b11 {
            case 0b00:
                offer = .pps(minMillivolts: Int((word >> 8) & 0xFF) * 100,
                             maxMillivolts: Int((word >> 17) & 0xFF) * 100,
                             milliamps: Int(word & 0x7F) * 50)
            case 0b01:
                offer = .eprAVS(minMillivolts: Int((word >> 8) & 0xFF) * 100,
                                maxMillivolts: Int((word >> 17) & 0x1FF) * 100,
                                watts: Int(word & 0xFF))
            case 0b10:
                offer = .sprAVS(milliamps9To15: Int((word >> 10) & 0x3FF) * 10,
                                milliamps15To20: Int(word & 0x3FF) * 10)
            default:
                return nil
            }
        }
        guard offer.isPlausible else { return nil }
        self = offer
    }

    /// False for a word that describes no supply at all.
    ///
    /// whatcable found these in its corpus, all in the last slot of the array:
    /// `0x808c8c8c`, which decodes as a Variable supply whose minimum is 40 V
    /// above its maximum, and `0x7` / `0xa` / `0xf`, Fixed supplies at 0 V.
    /// Unchecked, the first becomes a bogus 560 mW offer — and here, the second
    /// would break the comparison with the adapter's menu that the whole list
    /// is gated on.
    ///
    /// An offer of nothing is no offer either. On 15 October a 100 W charger
    /// on MagSafe had the panel print "PPS 4.8–21 V up to 0 A": a word whose
    /// voltages are the same charger's and whose current field is zero, on an
    /// array whose fixed words matched the menu. The sibling of the stale
    /// entries `sourceCapabilities(from:)` already guards against, most likely,
    /// and whatever it is, a source cannot offer zero amps. Dropping the word
    /// rather than the array is safe because the fixed words it sat beside are
    /// still checked against the menu on their own. A Fixed word at 0 A fails
    /// that check and takes the whole array with it, which is the silence to
    /// want from something that disagrees with itself.
    private var isPlausible: Bool {
        switch self {
        case .fixed(let mV, let mA):
            return mV > 0 && mA > 0
        case .variable(let low, let high, let mA), .pps(let low, let high, let mA):
            return high > 0 && low <= high && mA > 0
        case .battery(let low, let high, let mW):
            return high > 0 && low <= high && mW > 0
        case .eprAVS(let low, let high, let watts):
            return high > 0 && low <= high && watts > 0
        case .sprAVS(let first, _):
            return first > 0
        }
    }

    var isFixed: Bool {
        if case .fixed = self { return true }
        return false
    }

    /// "PPS 3.3–21 V up to 3 A". One line, in the units the charger's own
    /// label would use.
    var summary: String {
        switch self {
        case .fixed(let mV, let mA):
            return "\(Self.volts(mV)) V \(Self.amps(mA)) A"
        case .variable(let low, let high, let mA):
            return "Variable \(Self.volts(low))–\(Self.volts(high)) V up to \(Self.amps(mA)) A"
        case .battery(let low, let high, let mW):
            return "Battery \(Self.volts(low))–\(Self.volts(high)) V up to \(Self.trimmed(Double(mW) / 1000)) W"
        case .pps(let low, let high, let mA):
            return "PPS \(Self.volts(low))–\(Self.volts(high)) V up to \(Self.amps(mA)) A"
        case .eprAVS(let low, let high, let watts):
            return "AVS \(Self.volts(low))–\(Self.volts(high)) V up to \(watts) W"
        case .sprAVS(let first, let second):
            if second == 0 { return "AVS 9–15 V up to \(Self.amps(first)) A" }
            if second == first { return "AVS 9–20 V up to \(Self.amps(first)) A" }
            return "AVS 9–15 V up to \(Self.amps(first)) A, 15–20 V up to \(Self.amps(second)) A"
        }
    }

    /// The machine-readable form `--json` prints.
    var jsonObject: [String: Any] {
        switch self {
        case .fixed(let mV, let mA):
            return ["type": "fixed", "volts": Double(mV) / 1000, "maxAmps": Double(mA) / 1000]
        case .variable(let low, let high, let mA):
            return ["type": "variable", "minVolts": Double(low) / 1000,
                    "maxVolts": Double(high) / 1000, "maxAmps": Double(mA) / 1000]
        case .battery(let low, let high, let mW):
            return ["type": "battery", "minVolts": Double(low) / 1000,
                    "maxVolts": Double(high) / 1000, "maxWatts": Double(mW) / 1000]
        case .pps(let low, let high, let mA):
            return ["type": "pps", "minVolts": Double(low) / 1000,
                    "maxVolts": Double(high) / 1000, "maxAmps": Double(mA) / 1000]
        case .eprAVS(let low, let high, let watts):
            return ["type": "eprAvs", "minVolts": Double(low) / 1000,
                    "maxVolts": Double(high) / 1000, "maxWatts": watts]
        case .sprAVS(let first, let second):
            return ["type": "sprAvs", "maxAmps9To15V": Double(first) / 1000,
                    "maxAmps15To20V": Double(second) / 1000]
        }
    }

    private static func volts(_ millivolts: Int) -> String { trimmed(Double(millivolts) / 1000) }
    private static func amps(_ milliamps: Int) -> String { trimmed(Double(milliamps) / 1000) }

    /// "21", "3.3", "2.25": as many decimals as the value has, and no more.
    private static func trimmed(_ value: Double) -> String {
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        if text.hasSuffix(".") { text.removeLast() }
        return text
    }
}

/// Everything the attached charger offered, in the order it offered it.
struct SourceCapabilities: Hashable {
    struct Slot: Hashable {
        /// 1-based, which is what a request names.
        let position: Int
        let offer: SourceOffer
    }

    let slots: [Slot]
    /// How many of the leading fixed offers the adapter's own menu already
    /// lists, so the panel can show the rest without repeating any.
    let fixedInMenu: Int

    /// Every offer the PD profiles line does not already show: PPS and AVS
    /// ranges, and anything else the menu leaves out.
    var additionalOffers: [SourceOffer] {
        var skipped = 0
        return slots.compactMap { slot in
            if slot.offer.isFixed, skipped < fixedInMenu {
                skipped += 1
                return nil
            }
            return slot.offer
        }
    }
}

extension PowerMonitor {

    /// The attached charger's full Source_Capabilities, out of one
    /// `AppleSmartBattery` property dictionary. Nil wherever the array cannot
    /// be shown to belong to the charger that is plugged in now.
    ///
    /// The adapter details carry only the fixed offers, as `UsbHvcMenu`. The
    /// whole list — PPS and AVS ranges included — is in `PortControllerInfo`,
    /// one raw `PortControllerPortPDO` array per port controller. That array
    /// is a fixed 13 slots, 7 SPR then 6 EPR, and `PortControllerNPDOs` is not
    /// its length: it counts the fixed offers only, and every APDO sits after
    /// it. The captured PPS word is the sixth word on an entry saying 5, and
    /// whatcable records the same across its corpus — trimming to the count
    /// hid 536 of 540 non-fixed offers. So the array is read whole and only
    /// the zero words are dropped.
    ///
    /// What the array does not say is whether it is current. Captured on this
    /// Mac with nothing plugged in at all, one entry still held the Amazon
    /// dock's offers *and* the dock's request word, and another held a 100 W
    /// charger's offers from some earlier session. Neither a non-zero request
    /// nor a non-empty array is evidence of anything attached. The request is
    /// not even evidence about the entry it sits on: with that 100 W charger
    /// attached and delivering 20 V from its fifth slot, its entry carried
    /// the dock's request for the fourth.
    ///
    /// So the array is believed only where it says the same thing as
    /// `UsbHvcMenu`, which the adapter details publish separately and clear
    /// when the charger goes:
    /// its fixed offers, in order, must match the menu exactly, millivolt and
    /// milliamp. Agreement has to hold for the SPR slots alone or for every
    /// slot, because no capture shows whether an EPR brick's 28 V offer lands
    /// in the menu. Where more than one entry agrees they must also agree with
    /// each other — on macOS 27 two entries carried the dock's identical array
    /// — or nothing is shown.
    ///
    /// An empty menu therefore shows nothing, even with an array present. The
    /// BMW's rear port is exactly that: three fixed offers in the controller,
    /// no menu, and an adapter record describing 5 V at 3 A while the request
    /// names the third offer. Which of those is the truth is not something
    /// this can settle, so it does not try.
    static func sourceCapabilities(from properties: [String: Any]) -> SourceCapabilities? {
        guard properties["ExternalConnected"] as? Bool == true,
              let adapter = properties["AdapterDetails"] as? [String: Any],
              let menu = adapter["UsbHvcMenu"] as? [[String: Any]], !menu.isEmpty,
              let entries = properties["PortControllerInfo"] as? [[String: Any]]
        else { return nil }

        var menuOffers: [(index: Int, millivolts: Int, milliamps: Int)] = []
        for item in menu {
            guard let index = integer(item["Index"]),
                  let mV = integer(item["MaxVoltage"]),
                  let mA = integer(item["MaxCurrent"])
            else { return nil }
            menuOffers.append((Int(index), Int(mV), Int(mA)))
        }
        let expected: [SourceOffer] = menuOffers.sorted { $0.index < $1.index }
            .map { .fixed(millivolts: $0.millivolts, milliamps: $0.milliamps) }

        var candidates: [SourceCapabilities] = []
        for entry in entries {
            guard let words = entry["PortControllerPortPDO"] as? [Any] else { continue }
            var slots: [SourceCapabilities.Slot] = []
            for (position, raw) in words.enumerated() {
                guard let value = integer(raw) else { return nil }
                // The registry hands a word with its top bit set back as a
                // negative 64-bit number — the PPS word arrives as
                // 0xffffffffc1a43264 — so only the low 32 bits are the word.
                guard let offer = SourceOffer(word: UInt32(truncatingIfNeeded: value)) else { continue }
                slots.append(.init(position: position + 1, offer: offer))
            }
            let fixedSPR = slots.filter { $0.position <= 7 && $0.offer.isFixed }.map(\.offer)
            let fixedAll = slots.filter { $0.offer.isFixed }.map(\.offer)
            guard fixedSPR == expected || fixedAll == expected else { continue }
            candidates.append(SourceCapabilities(slots: slots, fixedInMenu: expected.count))
        }
        guard let first = candidates.first,
              candidates.allSatisfy({ $0 == first })
        else { return nil }
        return first
    }

    /// Whole numbers only, from either the integer the registry hands over or
    /// the string a capture might. Anything else is not a word to decode.
    private static func integer(_ value: Any?) -> Int64? {
        if let number = value as? NSNumber { return number.int64Value }
        if let string = value as? String { return Int64(string) }
        return nil
    }
}
