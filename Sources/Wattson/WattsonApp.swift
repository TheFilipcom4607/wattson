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
        if arguments.contains("--dump") {
            let ports = PortMonitor.read()
            var scan = Scanner.scan()
            PowerAttribution.apply(to: &scan.devices, ports: ports, map: PowerAttribution.storedMap)

            dumpPower(PowerMonitor.read())
            print("")
            dumpPorts(ports)
            print("")
            dumpDevices(scan)
            exit(0)
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
            guard port.isConnected else { continue }
            print("   Attached:    \(port.attachedHeadline)")
            if port.describesCable {
                print("   Max capable: \(port.cableCapability)")
                print("   Carrying:    \(port.activeSummary)")
                print("   Cable:       \(port.cableWiringSummary)")
                print("   Current:     \(port.currentRating)")
            }
            if let supported = TransportName.best(port.transportsSupported) {
                print("   Port max:   \(supported)")
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
