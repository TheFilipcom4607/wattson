import Foundation
import IOKit

/// One point on the sparkline.
struct PowerSample: Identifiable, Hashable {
    let id = UUID()
    let watts: Double
    /// Whether this reading came from the wall or from the battery.
    let charging: Bool
    let at = Date()
}

/// One PD voltage/current pair the attached charger advertises.
struct PDProfile: Identifiable, Hashable {
    let id: Int
    let volts: Double
    let amps: Double
    var watts: Double { volts * amps }
}

/// A single reading of what power is flowing right now.
struct PowerSnapshot {
    var externalConnected = false
    var isCharging = false

    /// Live power arriving from the adapter.
    var inputWatts: Double?
    var inputVolts: Double?
    var inputAmps: Double?

    /// What the whole machine is consuming.
    var systemLoadWatts: Double?
    /// Measured draw of everything on the USB-C ports, included in the load above.
    var accessoryWatts: Double?
    /// Which port the charger is attached to, e.g. "MagSafe 3".
    var sourcePortName: String?

    /// The machine's own consumption, once accessories are taken out.
    var macOnlyWatts: Double? {
        guard let load = systemLoadWatts else { return nil }
        return max(load - (accessoryWatts ?? 0), 0)
    }

    /// Positive while charging, negative while the battery is being drained.
    var batteryWatts: Double?
    var batteryPercent: Int?

    /// What the adapter is rated for, as opposed to what it is delivering.
    var adapterWatts: Double?
    var adapterName: String?
    /// The adapter's own account of who built it. Apple's own bricks report
    /// "Apple Inc." here; third-party PD chargers report their own name, or
    /// nothing at all.
    var adapterManufacturer: String?
    var adapterSerial: String?
    var adapterFirmware: String?

    /// Whether the thing charging this Mac is Apple's own.
    var isAppleAdapter: Bool {
        adapterManufacturer?.localizedCaseInsensitiveContains("apple") ?? false
    }
    var profiles: [PDProfile] = []
    var negotiatedProfile: Int?

    var hasAdapter: Bool { externalConnected && adapterWatts != nil }

    /// Signed battery flow: negative is leaving the battery, positive is going in.
    var batterySigned: String? {
        guard let watts = batteryWatts else { return nil }
        if abs(watts) < 0.05 { return "0.00 W" }
        return String(format: "%+.2f W", watts)
    }

    var batteryState: String? {
        guard let watts = batteryWatts else { return nil }
        if abs(watts) < 0.05 { return externalConnected ? "holding" : "idle" }
        return watts > 0 ? "charging" : "draining"
    }

    /// "-10.27 W · draining · 100%"
    var batteryDescription: String? {
        guard let signed = batterySigned, let state = batteryState else { return nil }
        return [signed, state, batteryPercent.map { "\($0)%" }]
            .compactMap { $0 }
            .joined(separator: " · ")
    }

    /// "Battery 76% · charging"
    var batterySummary: String? {
        let charge = batteryPercent.map { "Battery \($0)%" }
        return [charge, batteryState].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    }

    /// Where the power is going, as segments of one bar.
    ///
    /// This replaced a stack of "System draw / accessories / Mac itself /
    /// Battery" rows that made you do the arithmetic yourself to see whether
    /// the charger had anything left to give.
    var allocation: PowerAllocation? {
        guard let load = systemLoadWatts, load > 0 else { return nil }
        let accessories = accessoryWatts ?? 0
        var segments: [PowerAllocation.Segment] = [
            .init(id: "mac", label: "Mac", watts: max(load - accessories, 0))
        ]
        if accessories > 0.05 {
            segments.append(.init(id: "accessories", label: "Accessories", watts: accessories))
        }
        // Charge going into the cell is the third place the wall's power lands.
        if externalConnected, let battery = batteryWatts, battery > 0.05 {
            segments.append(.init(id: "battery", label: "Battery", watts: battery))
        }

        let used = segments.reduce(0) { $0 + $1.watts }
        // On battery there is no ceiling to show headroom against, so the bar
        // just splits the draw itself.
        let capacity = externalConnected ? max(adapterWatts ?? used, used) : used
        return PowerAllocation(segments: segments, capacity: max(capacity, 0.1))
    }
}

/// The split of the power currently flowing, sized against what the charger
/// can supply.
struct PowerAllocation {
    struct Segment: Identifiable {
        let id: String
        let label: String
        let watts: Double
    }

    var segments: [Segment]
    /// Full width of the bar: the charger's rating when plugged in, otherwise
    /// just the total being drawn.
    var capacity: Double

    var used: Double { segments.reduce(0) { $0 + $1.watts } }
    var headroom: Double? { capacity - used > 0.5 ? capacity - used : nil }

    /// Whether the bar is worth drawing at all.
    ///
    /// On battery there is no ceiling to measure against, so a lone segment
    /// fills the whole width and reads as "maxed out" while actually saying
    /// nothing — and its legend just repeats the headline.
    var isInformative: Bool { segments.count > 1 || headroom != nil }
}

/// Reads Apple's SMC power telemetry out of the IORegistry.
///
/// `AppleSmartBattery` publishes `PowerTelemetryData`, which is where the live
/// numbers live — the adapter's `Watts` field is only its advertised rating.
enum PowerMonitor {

    static func read() -> PowerSnapshot {
        var snapshot = PowerSnapshot()

        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSmartBattery")
        )
        guard service != 0 else { return snapshot }
        defer { IOObjectRelease(service) }

        var unmanaged: Unmanaged<CFMutableDictionary>?
        guard IORegistryEntryCreateCFProperties(service, &unmanaged, kCFAllocatorDefault, 0) == KERN_SUCCESS,
              let properties = unmanaged?.takeRetainedValue() as? [String: Any]
        else { return snapshot }

        snapshot.externalConnected = properties["ExternalConnected"] as? Bool ?? false
        snapshot.isCharging = properties["IsCharging"] as? Bool ?? false
        snapshot.batteryPercent = number(properties["CurrentCapacity"]).map { Int($0) }

        // Telemetry arrives in milliwatts / millivolts / milliamps. It only
        // refreshes every 10-30 s, so it is a fallback for the SMC values below.
        if let telemetry = properties["PowerTelemetryData"] as? [String: Any] {
            snapshot.inputWatts = number(telemetry["SystemPowerIn"]).map { $0 / 1000 }
            snapshot.inputVolts = number(telemetry["SystemVoltageIn"]).map { $0 / 1000 }
            snapshot.inputAmps = number(telemetry["SystemCurrentIn"]).map { $0 / 1000 }
            snapshot.systemLoadWatts = number(telemetry["SystemLoad"]).map { $0 / 1000 }
            snapshot.batteryWatts = number(telemetry["BatteryPower"]).map { $0 / 1000 }
        }

        // The SMC updates about once a second; prefer it wherever it answers.
        let smc = SMCMonitor.read()
        if let watts = smc.systemWatts { snapshot.systemLoadWatts = watts }
        if let watts = smc.adapterWatts { snapshot.inputWatts = watts }
        if let flow = smc.batteryFlow { snapshot.batteryWatts = flow }
        if smc.systemWatts != nil {
            snapshot.externalConnected = smc.hasAdapter
            // Keep volts/amps consistent with the fresher wattage.
            if let watts = smc.adapterWatts, let volts = snapshot.inputVolts, volts > 1 {
                snapshot.inputAmps = watts / volts
            } else if !smc.hasAdapter {
                snapshot.inputVolts = 0
                snapshot.inputAmps = 0
            }
        }

        // Fall back to battery voltage x amperage if telemetry is unavailable.
        if snapshot.batteryWatts == nil,
           let mV = number(properties["Voltage"]),
           let mA = number(properties["InstantAmperage"]) ?? number(properties["Amperage"]) {
            snapshot.batteryWatts = mV * mA / 1_000_000
        }

        if let adapter = properties["AdapterDetails"] as? [String: Any] {
            let watts = number(adapter["Watts"])
            snapshot.adapterWatts = (watts ?? 0) > 0 ? watts : nil
            // "Name" is the brick as it is written on the brick — "35W USB-C
            // Power Adapter". "Description" is the category it falls into, and
            // is usually the far less useful "pd charger".
            let name = (adapter["Name"] as? String)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty
            if let name {
                snapshot.adapterName = name
            } else if let description = adapter["Description"] as? String, !description.isEmpty {
                snapshot.adapterName = description.capitalizedFirst
            }
            snapshot.adapterManufacturer = (adapter["Manufacturer"] as? String)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty
            snapshot.adapterSerial = (adapter["SerialString"] as? String)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty
            snapshot.adapterFirmware = (adapter["FwVersion"] as? String)?
                .trimmingCharacters(in: .whitespaces).nilIfEmpty
            snapshot.negotiatedProfile = number(adapter["UsbHvcHvcIndex"]).map { Int($0) }

            if let menu = adapter["UsbHvcMenu"] as? [[String: Any]] {
                snapshot.profiles = menu.compactMap { entry in
                    guard let index = number(entry["Index"]),
                          let mV = number(entry["MaxVoltage"]),
                          let mA = number(entry["MaxCurrent"])
                    else { return nil }
                    return PDProfile(id: Int(index), volts: mV / 1000, amps: mA / 1000)
                }
                .sorted { $0.volts < $1.volts }
            }
        }

        return snapshot
    }

    private static func number(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let string = value as? String { return Double(string) }
        return nil
    }
}

private extension String {
    /// "pd charger" -> "PD charger"
    var capitalizedFirst: String {
        if lowercased().hasPrefix("pd ") { return "PD " + dropFirst(3) }
        return prefix(1).uppercased() + dropFirst()
    }
}
