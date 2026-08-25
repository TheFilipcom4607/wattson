import AppKit
import Foundation
import SwiftUI

/// A capture target is deliberately either a device or a physical USB-C port.
/// Cables do not enumerate as USB devices, so the port is the only accurate
/// target for a cable-only connection.
struct DiagnosticTarget: Identifiable, Hashable {
    enum Kind {
        case device
        case cable
    }

    let id: String
    let kind: Kind
    let title: String
    let subtitle: String

    @MainActor
    static func available(in model: DeviceModel) -> [DiagnosticTarget] {
        let cables = model.ports
            .filter { $0.kind == .usbC && $0.isConnected }
            .map {
                DiagnosticTarget(
                    id: "port:\($0.id)", kind: .cable,
                    title: "Cable / connection on \($0.name)",
                    subtitle: $0.attachedHeadline
                )
            }

        let devices = model.result.devices
            .flatMap { $0.flattenedRows() }
            .map { row in
                DiagnosticTarget(
                    id: "device:\(row.node.id)", kind: .device,
                    title: row.node.name,
                    subtitle: [row.node.kind == .thunderbolt ? "Thunderbolt" : "USB", row.node.subtitle]
                        .compactMap { $0 }
                        .joined(separator: " · ")
                )
            }

        return cables + devices
    }
}

/// A non-guided way to collect the raw hardware evidence needed to improve
/// support for a dock, cable or peripheral. Nothing has to be unplugged or
/// replugged: it captures the hardware's state exactly when Save is pressed.
struct DiagnosticsView: View {
    @ObservedObject var model: DeviceModel
    /// Closing is the window controller's job: this view is hosted in a plain
    /// `NSWindow`, which `@Environment(\.dismiss)` knows nothing about.
    let dismiss: () -> Void
    @State private var selectedID = ""
    @State private var label = ""
    @State private var isCapturing = false
    @State private var outcome: String?

    private var targets: [DiagnosticTarget] { DiagnosticTarget.available(in: model) }
    private var selection: DiagnosticTarget? { targets.first { $0.id == selectedID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Label("Device Diagnostic", systemImage: "stethoscope")
                    .font(.system(size: 16, weight: .semibold))
                Text("Choose the connected device or cable, give the setup a useful name, and save one complete raw snapshot. There is no plug/unplug checklist.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if targets.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "cable.connector.slash")
                        .font(.system(size: 22))
                        .foregroundStyle(.secondary)
                    Text("Nothing to capture")
                        .font(.system(size: 13, weight: .medium))
                    Text("Connect a USB-C cable, dock or device, then click Rescan in Wattson if it does not appear here.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("CONNECTED ITEM")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    Picker("Connected item", selection: $selectedID) {
                        ForEach(targets) { target in
                            Text(target.title + (target.subtitle.isEmpty ? "" : " — \(target.subtitle)"))
                                .tag(target.id)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }

                VStack(alignment: .leading, spacing: 7) {
                    Text("YOUR NAME FOR THIS SETUP")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    TextField("e.g. Anker dock + 2 m cable", text: $label)
                        .textFieldStyle(.roundedBorder)
                }

                Label("The report contains the complete raw IOKit registry plus every other source Wattson reads. It can be large and may include serial numbers.", systemImage: "lock.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let outcome {
                Text(outcome)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Rescan") { model.refresh() }
                    .disabled(isCapturing)
                Spacer()
                Button(isCapturing ? "Collecting…" : "Save Diagnostic Report…") {
                    capture()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || isCapturing)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { synchronizeSelection() }
        .onChange(of: targets.map(\.id)) { _ in synchronizeSelection() }
        .onExitCommand { dismiss() }
    }

    private func synchronizeSelection() {
        if !targets.contains(where: { $0.id == selectedID }) {
            selectedID = targets.first?.id ?? ""
        }
    }

    private func capture() {
        guard let selection else { return }
        let captureLabel = label.trimmingCharacters(in: .whitespacesAndNewlines)
        isCapturing = true
        outcome = nil

        Task {
            let report = await Task.detached(priority: .userInitiated) {
                DiagnosticReport.capture(label: captureLabel, target: selection)
            }.value
            isCapturing = false
            save(report: report, suggestedName: captureLabel)
        }
    }

    private func save(report: String, suggestedName: String) {
        let panel = NSSavePanel()
        panel.title = "Save Wattson Diagnostic"
        panel.message = "Save this text report to share with Wattson's developer."
        panel.nameFieldStringValue = DiagnosticReport.fileName(for: suggestedName)
        panel.allowedContentTypes = [.plainText]
        panel.canCreateDirectories = true

        let response = panel.runModal()
        guard response == .OK, let url = panel.url else {
            outcome = "Capture collected but not saved."
            return
        }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            // The save panel has already shown where the file went, so a success
            // line here would only ever be read by whoever opens the window next.
            // Close instead, and leave no stale outcome behind for that visit.
            outcome = nil
            dismiss()
        } catch {
            outcome = "Could not save the report: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class DiagnosticsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(model: DeviceModel) {
        if window == nil {
            let window = NSWindow(
                contentViewController: NSHostingController(
                    rootView: DiagnosticsView(model: model) { [weak self] in self?.window?.close() }
                )
            )
            window.styleMask = [.titled, .closable]
            window.title = "Capture Device Diagnostic"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        model.refresh()
        ActivationPolicy.claim()
        window?.makeKeyAndOrderFront(nil)
    }

    /// Only once nothing else is left open — Settings may still be up behind
    /// this one. See `ActivationPolicy`.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in ActivationPolicy.relinquish(after: self.window) }
    }
}
