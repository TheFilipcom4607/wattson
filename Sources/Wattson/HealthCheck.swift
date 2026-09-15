import Foundation

/// `--health`: one line per hardware source, saying whether it answered.
///
/// Written for the day macOS moves something. Every reader here fails into
/// silence by design, which is right for the panel and useless for finding out
/// what broke: after an OS upgrade a vanished reading and an empty port look
/// identical in `--dump`. This names each source separately so two runs, taken
/// either side of an upgrade with the same things plugged in, can be diffed
/// line by line.
///
/// Deliberately no values that move — watts, percentages, temperatures. A line
/// says a source answered, or how many things it answered with, so that a diff
/// between two healthy runs is empty and anything that shows up in one is a
/// change in what the platform will tell us, not in what the machine is doing.
enum HealthCheck {

    static func run() -> Int32 {
        var lines: [(String, String)] = []
        func say(_ name: String, _ value: String) { lines.append((name, value)) }
        func present(_ value: Any?) -> String { value == nil ? "none" : "ok" }

        let os = ProcessInfo.processInfo.operatingSystemVersion
        print("WATTSON HEALTH CHECK")
        print("macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion) · \(MacModel.identifier)")
        print("\"none\" is expected for anything that needs something plugged in. Compare two")
        print("runs taken with the same setup; a line that changes is what to look at.")
        print("")

        // SMC. Opening it is one question and each key is another: a key can
        // be renamed while the controller still opens fine.
        let smc = SMCMonitor.diagnosticValues()
        let smcOpens = !smc.hasPrefix("<AppleSMC could not be opened>")
        say("smc.opens", smcOpens ? "ok" : "none")
        if smcOpens {
            for line in smc.split(separator: "\n") {
                let key = line.prefix { $0 != " " && $0 != "=" }
                say("smc.key.\(key)", line.contains("<not available>") ? "none" : "ok")
            }
        }
        let reading = SMCMonitor.read()
        say("smc.systemWatts", present(reading.systemWatts))
        say("smc.adapterWatts", present(reading.adapterWatts))
        let battery = SMCMonitor.battery()
        say("smc.battery.volts", present(battery.volts))
        say("smc.battery.amps", present(battery.amps))
        say("smc.battery.cycleCount", present(battery.cycleCount))
        say("smc.portChannels", "\(SMCMonitor.portChannels().count)")

        // AppleSmartBattery, through the reader that interprets it.
        let power = PowerMonitor.read()
        say("battery.externalConnected", power.externalConnected ? "yes" : "no")
        say("battery.percent", present(power.batteryPercent))
        say("battery.inputWatts", present(power.inputWatts))
        say("battery.systemLoadWatts", present(power.systemLoadWatts))
        say("battery.batteryWatts", present(power.batteryWatts))
        say("battery.health.cycleCount", present(power.health.cycleCount))
        say("battery.health.capacityPercent", present(power.health.capacityPercent))
        say("battery.health.temperature", present(power.health.temperature))
        say("battery.adapterWatts", present(power.adapterWatts))
        say("battery.adapterName", present(power.adapterName))
        say("battery.pdProfiles", "\(power.profiles.count)")
        say("battery.mac.chargeCeiling", present(MacModel.maximumChargeWatts))

        // Ports, and each reader that joins onto them.
        let ports = PortMonitor.read()
        say("ports.count", "\(ports.count)")
        say("ports.connected", "\(ports.filter(\.isConnected).count)")
        for port in ports {
            let prefix = "port.\(port.name)"
            say("\(prefix).connected", port.isConnected ? "yes" : "no")
            say("\(prefix).transportsSupported", port.transportsSupported.isEmpty ? "none" : "ok")
            say("\(prefix).thunderbolt", present(port.thunderbolt))
            say("\(prefix).phy", present(port.phy))
            say("\(prefix).liquid", present(port.liquid))
            say("\(prefix).ccActive", present(port.ccActive))
            say("\(prefix).sourceDescription", present(port.sourceDescription))
            guard port.isConnected else { continue }
            say("\(prefix).contract", present(port.negotiated))
            say("\(prefix).emarker", present(port.emarker))
            say("\(prefix).emarker.vendorID", present(port.emarker?.vendorID))
            say("\(prefix).partner", present(port.partner))
            say("\(prefix).partner.vendorID", present(port.partner?.vendorID))
            say("\(prefix).outputWatts", present(port.outputWatts))
            say("\(prefix).display", present(port.display))
            say("\(prefix).displayLinks", "\(port.displayLinks.count)")
            say("\(prefix).pins", port.pins.isEmpty ? "none" : "ok")
        }

        // Readers queried on their own, so a join that stopped matching is
        // distinguishable from a source that stopped answering.
        say("thunderbolt.adapters", "\(ThunderboltMonitor.read().count)")
        say("phy.ports", "\(PhyMonitor.read().count)")
        say("portStats.controllers", "\(PortStatsMonitor.readControllers().count)")
        say("portStats.usbPorts", "\(PortStatsMonitor.readUSBPorts().count)")
        say("displays.active", "\(DisplayMonitor.read().count)")
        say("displays.links", "\(DisplayLinkMonitor.read().count)")
        say("volumes.onUSB", "\(VolumeMonitor().read().count)")

        let scan = Scanner.scan()
        say("devices.count", "\(scan.deviceCount)")
        say("systemProfiler.thunderbolt", thunderboltProfilerAnswers() ? "ok" : "none")

        // IOReport. The reader exists only if the symbols resolved and the
        // device tree still has its frequency ladders; a reading is whether
        // the channels are still shaped the way it expects, which takes two
        // samples a second apart.
        if let reader = CPUSpeedReader() {
            say("ioreport.cpuSpeedReader", "ok")
            _ = reader.read()
            Thread.sleep(forTimeInterval: 1)
            let clusters = reader.read()?.filter(\.isMeaningful) ?? []
            say("ioreport.clusters", "\(clusters.count)")
        } else {
            say("ioreport.cpuSpeedReader", "none")
        }

        let lowPower = LowPowerMode.read()
        say("lowPowerMode.readable", lowPower.isSupported ? "ok" : "none")
        say("lowPowerMode.sudoersRule", LowPowerMode.isPromptless ? "installed" : "absent")

        let width = (lines.map(\.0.count).max() ?? 0) + 2
        for (name, value) in lines {
            print(name.padding(toLength: width, withPad: " ", startingAt: 0) + value)
        }
        return 0
    }

    /// Whether `system_profiler` still returns a Thunderbolt section at all.
    /// Its USB sibling went empty on a previous release without warning, and
    /// this is the one subprocess the device tree still depends on.
    private static func thunderboltProfilerAnswers() -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["-json", "SPThunderboltDataType"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let items = root["SPThunderboltDataType"] as? [Any]
        else { return false }
        return !items.isEmpty
    }
}
