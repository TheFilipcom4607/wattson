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

/// What the diagnostics window has to remember across its contents being
/// thrown away on close — including a capture that is still running when the
/// window goes, which has to finish into something that is still there.
@MainActor
final class DiagnosticsState: ObservableObject {
    @Published var selectedID = ""
    @Published var label = ""
    @Published var isCapturing = false
    @Published var outcome: String?
}

/// A non-guided way to collect the raw hardware evidence needed to improve
/// support for a dock, cable or peripheral. Nothing has to be unplugged or
/// replugged: it captures the hardware's state exactly when Save is pressed.
struct DiagnosticsView: View {
    @ObservedObject var model: DeviceModel
    @ObservedObject var state: DiagnosticsState
    /// Closing is the window controller's job: this view is hosted in a plain
    /// `NSWindow`, which `@Environment(\.dismiss)` knows nothing about.
    let dismiss: () -> Void

    private var targets: [DiagnosticTarget] { DiagnosticTarget.available(in: model) }
    private var selection: DiagnosticTarget? { targets.first { $0.id == state.selectedID } }

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
                    Picker("Connected item", selection: $state.selectedID) {
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
                    TextField("e.g. Anker dock + 2 m cable", text: $state.label)
                        .textFieldStyle(.roundedBorder)
                }

                Label("The report contains the complete raw IOKit registry plus every other source Wattson reads. It can be large and may include serial numbers.", systemImage: "lock.doc")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let outcome = state.outcome {
                Text(outcome)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()
            HStack {
                Button("Rescan") { model.refresh() }
                    .disabled(state.isCapturing)
                Spacer()
                Button(state.isCapturing ? "Collecting…" : "Save Diagnostic Report…") {
                    capture()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(selection == nil || state.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || state.isCapturing)
            }
        }
        .padding(20)
        .frame(width: 500)
        .onAppear { synchronizeSelection() }
        .onChange(of: targets.map(\.id)) { _ in synchronizeSelection() }
        .onExitCommand { dismiss() }
    }

    private func synchronizeSelection() {
        if !targets.contains(where: { $0.id == state.selectedID }) {
            state.selectedID = targets.first?.id ?? ""
        }
    }

    private func capture() {
        guard let selection else { return }
        let captureLabel = state.label.trimmingCharacters(in: .whitespacesAndNewlines)
        state.isCapturing = true
        state.outcome = nil

        Task {
            let report = await Task.detached(priority: .userInitiated) {
                DiagnosticReport.capture(label: captureLabel, target: selection)
            }.value
            state.isCapturing = false
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
            state.outcome = "Capture collected but not saved."
            return
        }
        do {
            try report.write(to: url, atomically: true, encoding: .utf8)
            // The save panel has already shown where the file went, so a success
            // line here would only ever be read by whoever opens the window next.
            // Close instead, and leave no stale outcome behind for that visit.
            state.outcome = nil
            dismiss()
        } catch {
            state.outcome = "Could not save the report: \(error.localizedDescription)"
        }
    }
}

@MainActor
final class DiagnosticsWindowController: NSObject, NSWindowDelegate {
    /// Kept for good once made; its contents are rebuilt on each opening and
    /// given back on each close, as Settings' and the panel's are.
    private var window: NSWindow?
    private var hosting: NSHostingController<DiagnosticsView>?
    private let state = DiagnosticsState()
    /// Where the title bar was when the window closed. Giving the contents
    /// back collapses the window, which moves it.
    private var topLeft: NSPoint?

    func show(model: DeviceModel) {
        if window == nil {
            let hosting = makeHosting(model: model)
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.title = "Capture Device Diagnostic"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.hosting = hosting
            self.window = window
        } else if hosting == nil, let window {
            let hosting = makeHosting(model: model)
            window.contentViewController = hosting
            self.hosting = hosting
            window.fit(to: hosting.view, topLeft: topLeft)
        }
        model.refresh()
        ActivationPolicy.claim()
        window?.makeKeyAndOrderFront(nil)
    }

    private func makeHosting(model: DeviceModel) -> NSHostingController<DiagnosticsView> {
        NSHostingController(
            rootView: DiagnosticsView(model: model, state: state) { [weak self] in self?.window?.close() }
        )
    }

    /// Give the contents back once the window is closed, keeping the window.
    /// See `SettingsWindowController.teardownContent`.
    private func teardownContent() {
        guard let window, !window.isVisible, hosting != nil else { return }
        topLeft = NSPoint(x: window.frame.minX, y: window.frame.maxY)
        hosting = nil
        releaseHostedContent { window.contentViewController = $0 }
    }

    /// Only once nothing else is left open — Settings may still be up behind
    /// this one. See `ActivationPolicy`.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in
            ActivationPolicy.relinquish(after: self.window)
            self.teardownContent()
        }
    }
}
