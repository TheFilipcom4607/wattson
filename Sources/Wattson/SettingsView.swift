import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: DeviceModel

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            group("Menu Bar") {
                // Each option previews what it would actually put up there,
                // live — the labels alone did not tell you what you would get.
                Picker("Show", selection: $model.titleMode) {
                    ForEach(TitleMode.allCases) { mode in
                        (Text(mode.label) + Text("   " + preview(mode)).foregroundColor(.secondary))
                            .tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
            }

            group("Panel") {
                Toggle("Wattage graph", isOn: $model.showSparkline)
                Toggle("Connections", isOn: $model.showDevices)
                Toggle("Cable diagnostics", isOn: $model.showCable)
                    .disabled(!model.showDevices)
                    .padding(.leading, 16)
                Toggle("Vendor names", isOn: $model.showVendors)
                    .disabled(!model.showDevices)
                    .padding(.leading, 16)
                Toggle("This Mac's limits", isOn: $model.showPortLimits)
                Toggle("Announce devices as they connect", isOn: $model.announceChanges)
            }

            group("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }

            Divider()

            Text("Wattson \(Bundle.main.shortVersion)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(20)
        .frame(width: 340)
        // Settings apply as you change them, so there is nothing to confirm —
        // Escape and ⌘W close it, the way a settings window should.
        .onExitCommand { NSApp.keyWindow?.close() }
    }

    private func preview(_ mode: TitleMode) -> String {
        model.title(for: mode) ?? "icon only"
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
                .toggleStyle(.checkbox)
        }
    }
}

/// Holds the settings window, which the accessory-mode app has to manage itself.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?

    func show(model: DeviceModel) {
        if window == nil {
            // Built from the hosting controller so the window sizes to the
            // content rather than to a hard-coded height that has to be kept
            // in step with it.
            let window = NSWindow(
                contentViewController: NSHostingController(rootView: SettingsView(model: model))
            )
            window.styleMask = [.titled, .closable]
            window.title = "Wattson Settings"
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            self.window = window
        }
        // An .accessory app has no Dock icon, so it must ask for focus itself.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    /// Drop back to menu-bar-only once the window goes away.
    nonisolated func windowWillClose(_ notification: Notification) {
        Task { @MainActor in NSApp.setActivationPolicy(.accessory) }
    }
}

extension Bundle {
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
    }
}
