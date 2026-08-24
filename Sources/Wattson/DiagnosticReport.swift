import Foundation
import IOKit.ps

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

        // The one thing ioreg cannot produce. A BOS descriptor arrives over a
        // control transfer, so without this a capture carries no evidence about
        // alternate modes or declared link speeds — which are exactly the
        // readings that need a dock present to observe, and so exactly the ones
        // most likely to be worked on from a capture rather than the hardware.
        report.append("\n=== USB BOS DESCRIPTORS — raw bytes (BOSDescriptor source) ===")
        report.append("Fetched with GET_DESCRIPTOR(BOS) over IOUSBDeviceInterface, without opening "
            + "any device. Carries the Billboard capability (why an alternate mode failed) and the "
            + "SuperSpeed / SuperSpeedPlus capabilities (what speed the device says it can do, "
            + "which bcdUSB does not tell you). Not present in any ioreg output.")
        report.append(BOSDescriptor.allDescriptors())

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

        // The Thunderbolt device tree as IOKit sees it, which is the route the
        // app deliberately does not use yet. Every switch on an idle Mac is a
        // host router at Depth 0; a switch at Depth 1 or more is an attached
        // device, and no capture has ever contained one.
        rawSection("IOREG — IOThunderboltSwitch (device tree; Depth > 0 means something is attached)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-r", "-c", "IOThunderboltSwitch"], into: &report)
        rawSection("IOREG — IOThunderboltPort (ThunderboltMonitor source)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-r", "-c", "IOThunderboltPort"], into: &report)

        // PortMonitor: the full controller trees include Power Delivery children,
        // active transports, pin configuration, and e-marker nodes.
        rawSection("IOREG — AppleHPMInterface (PortMonitor source)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-r", "-c", "AppleHPMInterface"], into: &report)
        rawSection("IOREG — IOPortTransportComponentCCUSBPDSOPp (e-marker source)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-r", "-c", "IOPortTransportComponentCCUSBPDSOPp"],
                   into: &report,
                   emptyNote: """
                   No e-marker node exists right now. This is the normal case, not a fault: the \
                   chip in a cable is only interrogated when there is a reason to negotiate with \
                   it, so the node appears when the cable is e-marked AND something is attached \
                   at the far end. A capture of an e-marked cable lying idle in a port is empty \
                   here — attach a charger or device to the other end and capture again.
                   """)

        rawSection("IOREG — IOPortTransportState (per-transport state, all subclasses)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-r", "-c", "IOPortTransportState"], into: &report,
                   emptyNote: """
                   Only the CC node exists on an idle machine. The DisplayPort, USB3 and CIO \
                   nodes are created when that transport actually comes up, so a capture taken \
                   with nothing attached shows one node per port and no more. Capture again with \
                   the dock and the monitors running to get the rest.
                   """)
        rawSection("IOREG — AppleTypeCPhy (PhyMonitor source: lane assignment and DP link rate)",
                   command: "/usr/sbin/ioreg",
                   arguments: ["-l", "-w", "0", "-r", "-c", "AppleTypeCPhy"], into: &report,
                   emptyNote: """
                   An idle port's lanes are parked and the controller keeps reporting the last \
                   assignment it made, so these readings only mean anything while something is \
                   plugged in.
                   """)

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
        report.append("\n=== APPLESMC KEYS — every key the controller publishes ===")
        report.append("Walked from the SMC's own key index, so this can show readings Wattson "
            + "does not yet know to look for. Raw bytes are printed beside each decoded value.")
        report.append(SMCMonitor.allKeyValues())

        // The power-source API reaches the adapter by a different route than
        // AppleSmartBattery, and the two do not always carry the same fields.
        report.append("\n=== IOPS — IOPSCopyExternalPowerAdapterDetails (PowerMonitor cross-check) ===")
        report.append(externalPowerAdapterDetails())

        // DisplayMonitor is the app's only non-IOKit reader, so nothing above
        // carries the display half of a USB-C link.
        report.append("\n=== CORE GRAPHICS DISPLAYS — every mode offered (DisplayMonitor source) ===")
        report.append("The full mode list matters more than the current one: \"which mode is it "
            + "running\" is a single number, and \"which modes did the display offer, and did macOS "
            + "take the top one\" is the question a monitor on a dock actually raises. It cannot be "
            + "reconstructed later.")
        report.append(DisplayMonitor.diagnosticValues())

        // A different path to the same displays. The two do not always agree,
        // and where they do not that is itself the finding — the same reason
        // the IOPS adapter details sit beside AppleSmartBattery above.
        rawSection("SYSTEM_PROFILER JSON — SPDisplaysDataType (cross-check on the displays above)",
                   command: "/usr/sbin/system_profiler",
                   arguments: ["-json", "SPDisplaysDataType"], into: &report)

        rawSection("SYSCTL — hw.model (MacModel source)",
                   command: "/usr/sbin/sysctl", arguments: ["hw.model"], into: &report)
        report.append("\n=== FILEMANAGER VOLUME RESOURCE VALUES (VolumeMonitor source) ===")
        report.append(mountedVolumeResourceValues())

        return report.joined(separator: "\n") + "\n"
    }

    private static func rawSection(
        _ title: String,
        command: String,
        arguments: [String],
        into report: inout [String],
        emptyNote: String? = nil
    ) {
        report.append("\n=== \(title) ===")
        report.append("$ \(command) \(arguments.joined(separator: " "))")
        let output = run(command, arguments: arguments)
        report.append(output)
        // An empty section reads as a broken capture unless it says otherwise.
        if let emptyNote, output.hasPrefix("<no output") {
            report.append("\nWHY THIS IS EMPTY: " + emptyNote)
        }
    }

    /// What the power-source API says about the adapter, which is a different
    /// path to the same hardware than the `AppleSmartBattery` dictionary above.
    private static func externalPowerAdapterDetails() -> String {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?
            .takeRetainedValue() as? [String: Any]
        else {
            return "<no adapter details; nothing is plugged in, or the API returned nothing>"
        }
        return details.keys.sorted()
            .map { "\($0) = \(details[$0]!)" }
            .joined(separator: "\n")
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
            return text.isEmpty
                ? "<no output; exit status \(process.terminationStatus)>"
                : collapsingHugeValues(text)
        } catch {
            return "<could not run command: \(error.localizedDescription)>"
        }
    }

    /// How much of one property value is worth keeping.
    ///
    /// Ordinary properties run to a few hundred characters. A handful do not:
    /// a HID element table or an IOReportLegend is a single value of several
    /// hundred kilobytes, and together they are about half of a capture. None
    /// of them feed a power, cable or device reading.
    private static let maximumValueLength = 4000

    /// ioreg puts each property on one line, so an oversized value can be cut
    /// without disturbing the structure around it. The key and the start of the
    /// value survive, which is enough to recognise what was dropped and to go
    /// back for it deliberately.
    private static func collapsingHugeValues(_ text: String) -> String {
        var lines: [String] = []
        var omitted = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            guard line.count > maximumValueLength else {
                lines.append(String(line))
                continue
            }
            let rest = line.count - maximumValueLength
            omitted += rest
            lines.append(String(line.prefix(maximumValueLength))
                + " …[\(rest) more characters of this value omitted]")
        }
        guard omitted > 0 else { return text }
        lines.append("""

        [\(omitted / 1024) KB of oversized property values omitted — HID element tables and \
        IOReportLegend, which no Wattson reading uses. Raise \
        DiagnosticReport.maximumValueLength to keep them in full.]
        """)
        return lines.joined(separator: "\n")
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
