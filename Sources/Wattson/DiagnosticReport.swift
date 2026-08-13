import Foundation

/// Captures the original, unparsed sources Wattson reads. The app's own
/// summaries are intentionally excluded: this is the evidence to inspect when
/// adding support for an unfamiliar dock, cable or controller.
enum DiagnosticReport {
    static func fileName(for label: String) -> String {
        let safe = label
            .replacingOccurrences(of: "[^A-Za-z0-9._-]+", with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        let stamp = ISO8601DateFormatter().string(from: Date())
            .replacingOccurrences(of: ":", with: "-")
        return "Wattson-\(safe.isEmpty ? "diagnostic" : safe)-\(stamp).txt"
    }

    static func capture(label: String, target: DiagnosticTarget) -> String {
        var report = [
            "WATTSON RAW HARDWARE CAPTURE",
            "Captured: \(ISO8601DateFormatter().string(from: Date()))",
            "Setup name: \(label)",
            "Selected item: \(target.title)",
            "Selected item kind: \(target.kind == .cable ? "USB-C cable / port" : "connected device")",
            "",
            "This report contains the raw, unprocessed sources Wattson reads. It intentionally does not contain Wattson's interpreted device, cable, or power summaries.",
            "Raw data can include serial numbers and other device identifiers; review it before sharing."
        ]

        // Scanner: the full property dictionaries for every USB host device.
        rawSection("IOREG — IOUSBHostDevice (Scanner source)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-r", "-c", "IOUSBHostDevice"], into: &report)

        // A complete service-plane dump preserves every child property that
        // Scanner and PortMonitor can walk to, including classes Apple changes
        // between macOS releases. The class-specific sections below remain so a
        // report is still easy to inspect without opening the full archive.
        rawSection("IOREG — COMPLETE IOService PLANE (all IOKit data Wattson can read)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-x", "-p", "IOService"], into: &report)

        // Scanner: this exact JSON source is parsed to build the Thunderbolt tree.
        rawSection("SYSTEM_PROFILER JSON — SPThunderboltDataType (Scanner source)",
                   command: "/usr/sbin/system_profiler",
                   arguments: ["-json", "SPThunderboltDataType"], into: &report)

        // PortMonitor: the full controller trees include Power Delivery children,
        // active transports, pin configuration, and e-marker nodes.
        rawSection("IOREG — AppleHPMInterface (PortMonitor source)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-r", "-c", "AppleHPMInterface"], into: &report)
        rawSection("IOREG — IOPortTransportComponentCCUSBPDSOPp (e-marker source)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-r", "-c", "IOPortTransportComponentCCUSBPDSOPp"], into: &report)

        // PowerMonitor's unprocessed property dictionary, including adapter and
        // battery telemetry. AppleSMC telemetry itself is read through a private
        // kernel client and has no equivalent command-line raw property dump.
        rawSection("IOREG — AppleSmartBattery (PowerMonitor source)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-r", "-c", "AppleSmartBattery"], into: &report)
        rawSection("IOREG — AppleSMC (SMC controller metadata)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-r", "-c", "AppleSMC"], into: &report)
        report.append("\n=== APPLESMC KEYS — direct values read by SMCMonitor ===")
        report.append(SMCMonitor.diagnosticValues())

        rawSection("SYSCTL — hw.model (MacModel source)",
                   command: "/usr/sbin/sysctl", arguments: ["hw.model"], into: &report)
        report.append("\n=== FILEMANAGER VOLUME RESOURCE VALUES (VolumeMonitor source) ===")
        report.append(mountedVolumeResourceValues())

        return report.joined(separator: "\n") + "\n"
    }

    private static func rawSection(_ title: String, command: String, arguments: [String], into report: inout [String]) {
        report.append("\n=== \(title) ===")
        report.append("$ \(command) \(arguments.joined(separator: " "))")
        report.append(run(command, arguments: arguments))
    }

    private static func run(_ executable: String, arguments: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(data: data, encoding: .utf8) ?? "<command returned non-UTF-8 data>"
            return text.isEmpty ? "<no output; exit status \(process.terminationStatus)>" : text
        } catch {
            return "<could not run command: \(error.localizedDescription)>"
        }
    }

    /// The exact URL resource keys VolumeMonitor asks Foundation for, emitted
    /// without the model's formatting or its USB-device association.
    private static func mountedVolumeResourceValues() -> String {
        let keys: [URLResourceKey] = [
            .volumeNameKey, .volumeTotalCapacityKey, .volumeAvailableCapacityKey
        ]
        guard let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: keys, options: [.skipHiddenVolumes]
        ) else {
            return "<mountedVolumeURLs returned no volumes>"
        }
        return urls.map { url in
            let values = try? url.resourceValues(forKeys: Set(keys))
            let name = values?.volumeName ?? "<not available>"
            let total = values?.volumeTotalCapacity.map { String($0) } ?? "<not available>"
            let available = values?.volumeAvailableCapacity.map { String($0) } ?? "<not available>"
            return [
                "url=\(url.path)",
                "volumeName=\(name)",
                "volumeTotalCapacity=\(total)",
                "volumeAvailableCapacity=\(available)"
            ].joined(separator: "\n")
        }
        .joined(separator: "\n\n")
    }
}
