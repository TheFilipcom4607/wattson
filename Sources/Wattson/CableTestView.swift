import AppKit
import SwiftUI

struct CableTestView: View {
    @ObservedObject var model: DeviceModel
    @StateObject private var test = CableTestModel()

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            if test.isGuided {
                guidedTest
            } else {
                verdict
            }

            Divider()
            footer
        }
        .frame(width: 420)
        .onAppear { test.update(ports: model.ports) }
        .onReceive(model.$ports) { test.update(ports: $0) }
        .onExitCommand { NSApp.keyWindow?.close() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "cable.connector.horizontal")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.tint)
                Text("Cable Test")
                    .font(.system(size: 15, weight: .semibold))
                Spacer()
                if test.candidates.filter(\.isConnected).count > 1 {
                    portPicker
                }
            }

            PortDiagram(
                ports: test.candidates,
                activeID: test.evidence.portID,
                isLive: test.evidence.isConnected
            )
        }
        .padding(16)
    }

    /// Only shown when both ports are occupied and the app has to be told which
    /// cable is the one under test.
    private var portPicker: some View {
        Picker("", selection: Binding(
            get: { test.pinnedPortID ?? test.evidence.portID ?? "" },
            set: { test.pinnedPortID = $0 }
        )) {
            ForEach(test.candidates.filter(\.isConnected)) { port in
                Text(port.name).tag(port.id)
            }
        }
        .labelsHidden()
        .pickerStyle(.segmented)
        .fixedSize()
    }

    // MARK: - Verdict

    private var verdict: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 4) {
                Text(test.assessment.headline.uppercased())
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .foregroundStyle(test.assessment.isConnected
                        ? AnyShapeStyle(.primary)
                        : AnyShapeStyle(.tertiary))
                Text(test.assessment.summary)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if !test.assessment.findings.isEmpty {
                VStack(spacing: 0) {
                    ForEach(Array(test.assessment.findings.enumerated()), id: \.element.id) { index, finding in
                        if index > 0 { Divider().opacity(0.4) }
                        FindingRow(finding: finding)
                    }
                }
                .background(RoundedRectangle(cornerRadius: 8).fill(.quaternary.opacity(0.4)))
            }

            // Says where the numbers come from without contradicting the Chip
            // row, which reports per-Mac whether the e-marker could be read.
            //
            // Where the chip is sealed, that limit is worth stating outright
            // rather than leaving somebody to work out why a 240 W cable keeps
            // reading as 100 W: what is measured is the lowest of three things,
            // and only one of them is the cable.
            Label(
                test.assessment.chipContentsWithheld
                    ? "This Mac reports that a cable carries an e-marker, never what it says. So every row is a floor the hardware has cleared through this cable — the lowest of what the cable, the charger and this Mac will each do. A bigger charger raises that floor; nothing an app can reach states the cable's own rating."
                    : "Nothing here is read off the cable's printing. Every row is either negotiated by the hardware or reported by the cable's own chip.",
                systemImage: "info.circle"
            )
            .font(.system(size: 10))
            .foregroundStyle(.tertiary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Guided test

    private var guidedTest: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("GUIDED TEST")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)

            ForEach(test.steps) { step in
                StepRow(step: step)
            }

            Divider().opacity(0.5)

            VStack(alignment: .leading, spacing: 5) {
                ForEach(test.assessment.findings) { finding in
                    HStack(spacing: 6) {
                        StatusDot(confidence: finding.confidence)
                        Text(finding.label)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(width: 44, alignment: .leading)
                        Text(finding.value)
                            .font(.system(size: 11, weight: .medium))
                        Spacer(minLength: 0)
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Footer

    private var footer: some View {
        HStack(spacing: 10) {
            Button(test.isGuided ? "Back to Summary" : "Run Guided Test…") {
                test.isGuided.toggle()
            }
            Button("Start Over") { test.restart() }
                .disabled(!test.assessment.isConnected)
            Spacer()
            Button("Done") { NSApp.keyWindow?.close() }
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

// MARK: - Pieces

/// The two USB-C ports, drawn so it is obvious which one is under test.
private struct PortDiagram: View {
    let ports: [PortInfo]
    let activeID: String?
    let isLive: Bool

    var body: some View {
        HStack(spacing: 8) {
            ForEach(ports) { port in
                let isActive = port.id == activeID
                VStack(spacing: 5) {
                    RoundedRectangle(cornerRadius: 3)
                        .fill(isActive
                            ? AnyShapeStyle(.tint)
                            : AnyShapeStyle(port.isConnected ? .secondary : .quaternary))
                        .frame(height: 7)
                    Text(port.name)
                        .font(.system(size: 9))
                        .foregroundStyle(isActive ? AnyShapeStyle(.primary) : AnyShapeStyle(.tertiary))
                        .lineLimit(1)
                    Text(port.isConnected ? (isActive ? "testing" : "occupied") : "empty")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
            }
        }
    }
}

private struct FindingRow: View {
    let finding: CableFinding

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            StatusDot(confidence: finding.confidence).padding(.top, 4)

            Text(finding.label)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 44, alignment: .leading)

            VStack(alignment: .leading, spacing: 2) {
                Text(finding.value)
                    .font(.system(size: 12, weight: .medium))
                    .fixedSize(horizontal: false, vertical: true)
                if let hint = finding.hint {
                    Text(hint)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Spacer(minLength: 4)

            Text(finding.confidence.label)
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.top, 2)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}

private struct StatusDot: View {
    let confidence: CableFinding.Confidence

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 7, height: 7)
    }

    private var color: Color {
        switch confidence {
        case .proven: return .green
        case .partial: return .yellow
        case .untested: return .gray.opacity(0.5)
        }
    }
}

private struct StepRow: View {
    let step: CableTestStep

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol)
                .font(.system(size: 13))
                .foregroundStyle(tint)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title)
                    .font(.system(size: 12, weight: step.state == .current ? .semibold : .regular))
                    .foregroundStyle(step.state == .pending
                        ? AnyShapeStyle(.tertiary)
                        : AnyShapeStyle(.primary))
                if step.state != .pending {
                    Text(step.instruction)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var symbol: String {
        switch step.state {
        case .done: return "checkmark.circle.fill"
        case .current: return "arrow.right.circle.fill"
        case .pending: return "circle"
        }
    }

    private var tint: AnyShapeStyle {
        switch step.state {
        case .done: return AnyShapeStyle(.green)
        case .current: return AnyShapeStyle(.tint)
        case .pending: return AnyShapeStyle(.tertiary)
        }
    }
}

/// Holds the cable test window, which the accessory-mode app manages itself.
@MainActor
final class CableTestWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(model: DeviceModel) {
        if window == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: CableTestView(model: model))
            )
            window.styleMask = [.titled, .closable]
            window.title = "Cable Test"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
    }
}
