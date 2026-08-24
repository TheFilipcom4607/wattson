import AppKit
import SwiftUI

@main
enum Entry {
    /// NSApplication holds its delegate weakly, so it has to be owned here.
    private static var delegate: AppDelegate?

    @MainActor
    static func main() {
        // `Wattson --dump` prints one reading as plain text, without the GUI.
        // `Wattson --watch` keeps printing the power line until interrupted.
        let arguments = CommandLine.arguments
        // `Wattson --selftest` replays recorded captures through the readers'
        // parse functions. It touches no hardware, so it is the only check
        // here that means the same thing on a machine with nothing plugged in.
        if arguments.contains("--selftest") {
            exit(SelfTest.run())
        }
        // `Wattson --json` is `--dump` in a shape something else can read.
        if arguments.contains("--json") {
            let ports = PortMonitor.read()
            var scan = Scanner.scan()
            PowerAttribution.apply(to: &scan.devices, ports: ports, map: PowerAttribution.storedMap)
            PowerAttribution.diagnoseLinks(&scan.devices, ports: ports, map: PowerAttribution.storedMap)
            print(JSONOutput.render(power: PowerMonitor.read(), ports: ports, scan: scan))
            exit(0)
        }
        if arguments.contains("--dump") {
            let ports = PortMonitor.read()
            var scan = Scanner.scan()
            PowerAttribution.apply(to: &scan.devices, ports: ports, map: PowerAttribution.storedMap)
            PowerAttribution.diagnoseLinks(&scan.devices, ports: ports, map: PowerAttribution.storedMap)

            dumpPower(PowerMonitor.read())
            print("")
            dumpPorts(ports)
            print("")
            dumpDevices(scan)
            print("")
            dumpFaults(ports)
            exit(0)
        }
        // `Wattson --throttle` prints thermal pressure and what the cores are
        // actually running at, once a second.
        if arguments.contains("--throttle") {
            guard let reader = CPUSpeedReader() else {
                print("Performance states are not readable on this machine.")
                exit(1)
            }
            while true {
                var snapshot = ThrottleSnapshot()
                snapshot.pressure = ThermalPressure(ProcessInfo.processInfo.thermalState)
                snapshot.clusters = reader.read() ?? []
                let speeds = snapshot.clusters
                    .filter(\.isMeaningful)
                    .map {
                        String(format: "%@ %.0f/%.0f MHz (%.0f%% busy)",
                               $0.name, $0.achievedMHz, $0.ceilingMHz, $0.busyFraction * 100)
                    }
                    .joined(separator: "  |  ")
                print("throttling: \(snapshot.level.label.lowercased())"
                      + "  |  thermal \(snapshot.pressure.label.lowercased())"
                      + (speeds.isEmpty ? "  |  (warming up)" : "  |  " + speeds))
                fflush(stdout)
                Thread.sleep(forTimeInterval: 1)
            }
        }
        if arguments.contains("--watch") {
            while true {
                let power = PowerMonitor.read()
                let input = power.inputWatts.map { String(format: "in %6.2f W", $0) } ?? "in    ? W"
                let load = power.systemLoadWatts.map { String(format: "load %6.2f W", $0) } ?? ""
                let battery = power.batteryWatts.map { String(format: "batt %+7.2f W", $0) } ?? ""
                print("\(input)  |  \(load)  |  \(battery)")
                fflush(stdout)
                Thread.sleep(forTimeInterval: 1)
            }
        }
        let application = NSApplication.shared
        delegate = AppDelegate()
        application.delegate = delegate
        // Menu bar only: no Dock icon, no app switcher entry.
        application.setActivationPolicy(.accessory)
        application.run()
    }

    private static func dumpPower(_ power: PowerSnapshot) {
        print("=== POWER ===")
        print("Adapter connected: \(power.externalConnected)")
        if let watts = power.inputWatts { print(String(format: "Input:       %.2f W", watts)) }
        if let volts = power.inputVolts, let amps = power.inputAmps {
            print(String(format: "Input rail:  %.2f V / %.3f A", volts, amps))
        }
        if let load = power.systemLoadWatts { print(String(format: "System load: %.2f W", load)) }
        if let accessories = power.accessoryWatts {
            print(String(format: "Accessories: %.2f W measured", accessories))
            if let mac = power.macOnlyWatts { print(String(format: "Mac itself:  %.2f W", mac)) }
        }
        if let battery = power.batteryDescription { print("Battery:     \(battery)") }
        if let volts = power.batteryVolts, let amps = power.batteryAmps {
            print(String(format: "Pack rail:   %.3f V / %+.3f A", volts / 1000, amps / 1000))
        }
        if let minutes = power.minutesToEmpty {
            print("Runs for:    \(minutes / 60) h \(minutes % 60) min at the current draw")
        }
        if let minutes = power.minutesToFull {
            print("Full in:     \(minutes / 60) h \(minutes % 60) min")
        }
        let health = power.health
        if health.hasAnything {
            var parts: [String] = []
            if let capacity = health.capacityPercent {
                parts.append(String(format: "%.1f%% of design capacity", capacity))
            }
            if let cycles = health.cycleCount {
                parts.append(health.designCycleCount.map { "\(cycles)/\($0) cycles" } ?? "\(cycles) cycles")
            }
            if let temperature = health.temperature {
                parts.append(String(format: "%.1f °C", temperature))
            }
            print("Condition:   \(parts.joined(separator: " · "))")
            if let low = health.minimumTemperature, let high = health.maximumTemperature {
                print(String(format: "Ever been:   %.0f °C to %.0f °C", low, high))
            }
            if health.needsService { print("             SERVICE RECOMMENDED — the gauge has latched a fault") }
        }
        if let reason = power.chargingHold.summary(
            externalConnected: power.externalConnected, isCharging: power.isCharging
        ) {
            print("Not charging: \(reason)")
        }
        if let rating = power.adapterWatts {
            print(String(format: "Charger:     %.0f W rated (\(power.adapterName ?? "unknown"))", rating))
            let maker = power.adapterManufacturer ?? "not reported"
            print("Charger made by: \(maker)\(power.isAppleAdapter ? " — Apple" : "")")
            if let serial = power.adapterSerial { print("Charger serial:  \(serial)") }
        }
        print("This Mac:    \(MacModel.identifier)", terminator: "")
        if let ceiling = MacModel.maximumChargeWatts {
            print(String(format: ", charges at up to %.0f W", ceiling))
        } else {
            print(", charge ceiling not in the table")
        }
        for profile in power.profiles {
            let marker = profile.id == power.negotiatedProfile ? " <- negotiated" : ""
            print(String(format: "   PD %2d: %5.1f V  %.2f A  = %5.1f W%@",
                         profile.id, profile.volts, profile.amps, profile.watts, marker))
        }
    }

    private static func dumpPorts(_ ports: [PortInfo]) {
        print("=== PORTS ===")
        for port in ports {
            print("\(port.name): \(port.isConnected ? "connected" : "empty")")
            // Printed before the empty-port skip on purpose: half the ways this
            // can disagree are a port that reads empty while the CC line says
            // otherwise, and skipping would hide exactly those.
            if port.occupancyDisagreement {
                let cc = port.ccActive == true ? "something is" : "nothing is"
                print("   NOTE:        The CC line says \(cc) in this port. The controller disagrees.")
            }
            guard port.isConnected else { continue }
            print("   Attached:    \(port.attachedHeadline)")
            if port.describesCable {
                print("   Max capable: \(port.cableCapability)")
                print("   Carrying:    \(port.activeSummary)")
                print("   Cable:       \(port.cableWiringSummary)")
                print("   Current:     \(port.currentRating)")
                if let maker = port.emarker?.vendorName {
                    print("   Cable made by: \(maker)")
                }
            }
            if let supported = TransportName.best(port.transportsSupported) {
                print("   Port max:   \(supported)")
            }
            if let partner = port.partner, let maker = partner.vendorName {
                print("   Far end:     \(maker)"
                      + (partner.productID.map { String(format: " · product 0x%04X", $0) } ?? ""))
            }
            if let lanes = port.phy?.laneSummary, port.isConnected {
                print("   Lanes:       \(lanes)")
            }
            if let display = port.phy?.displaySummary, port.isConnected {
                print("   Display:     \(display)")
            }
            if let display = port.display {
                print("   Screen:      \(display.modeSummary)")
            }
            if let verdict = port.displayCompression {
                print("   Compressed:  \(verdict)")
            }
            if port.displayIsUsingAllLanes {
                print("   NOTE:        The display has both lanes; anything else here is on USB 2.0.")
            }
            if let state = port.authentication {
                print("   Auth:        \(state)")
            }
            if let source = port.sourceDescription {
                print("   SMC calls it: \(source)")
            }
            if let liquid = port.liquid?.summary {
                print("   LIQUID:      \(liquid)")
            }
            if let capability = port.thunderbolt?.capabilityLabel {
                print("   TB link:     \(capability) controller")
            }
            if let achieved = port.thunderboltAchieved {
                print("   TB running:  \(achieved)")
            }
            if let negotiated = port.negotiated {
                print(String(format: "   Contract:    %.0f V / %.2f A (%.0f W)",
                             negotiated.volts, negotiated.amps, negotiated.watts))
            }
            if let watts = port.outputWatts, let volts = port.outputVolts, let amps = port.outputAmps {
                print(String(format: "   Power out:   %.2f W (%.2f V / %.3f A)", watts, volts, amps))
            }
            if port.describesCable {
                let pins = port.pins.sorted { $0.key < $1.key }
                    .map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                print("   Pins:        \(pins)")
            }
        }
    }

    /// Lifetime fault counters. Printed here rather than only in the panel
    /// because a dump is what somebody attaches to a bug report, and these are
    /// the only numbers in the app that describe a fault that has already
    /// finished happening.
    private static func dumpFaults(_ ports: [PortInfo]) {
        print("=== RECORDED FAULTS ===")
        var said = false
        for stats in PortStatsMonitor.readControllers(attributedTo: ports) where stats.hasFaults {
            said = true
            // The port where the attribution held, and the bare array position
            // where it did not — which is the same answer this always gave.
            print("\(stats.portName ?? "Port controller \(stats.index + 1)"):")
            for entry in stats.faultCounts { print("   \(entry.name): \(entry.count)") }
        }
        for stats in PortStatsMonitor.readUSBPorts() where stats.hasFaults {
            said = true
            print(stats.portNumber.map { "USB port \($0):" } ?? "USB port:")
            for entry in stats.faultCounts { print("   \(entry.name): \(entry.count)") }
        }
        if !said { print("None recorded since this machine was built.") }
    }

    private static func dumpDevices(_ result: ScanResult) {
        print("=== DEVICES (\(result.deviceCount)) ===")
        func show(_ nodes: [DeviceNode], indent: String) {
            for node in nodes {
                let subtitle = node.subtitle.map { " [\($0)]" } ?? ""
                print("\(indent)\(node.name)\(subtitle)")
                for line in node.detailLines() {
                    print("\(indent)  • \(line)")
                }
                show(node.children, indent: indent + "    ")
            }
        }
        show(result.devices, indent: "")
    }
}
