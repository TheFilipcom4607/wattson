import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: DeviceModel
    /// Set when macOS refuses, which it does silently and permanently once the
    /// user has said no — the switch alone would look broken.
    @State private var deniedNotifications = false

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
            }

            group("Notifications") {
                Toggle("Chargers", isOn: $model.announcePower)
                Toggle("Warn when the battery drains on a charger", isOn: $model.warnBatteryDrain)
                    .disabled(!model.announcePower)
                    .padding(.leading, 16)
                Toggle("Contract changes", isOn: $model.announceContract)
                    .disabled(!model.announcePower)
                    .padding(.leading, 16)
                Toggle("Drives and cards", isOn: $model.announceStorage)
                Toggle("Everything else that plugs in", isOn: $model.announceDevices)

                Divider().padding(.vertical, 2)

                Toggle("Beside the menu bar", isOn: $model.noticesInPanel)
                Toggle("In Notification Center", isOn: Binding(
                    get: { model.noticesInCenter },
                    set: { wanted in
                        model.noticesInCenter = wanted
                        // Permission is asked for here, when it is turned on,
                        // and the switch goes back by itself if it is refused.
                        guard wanted else { return }
                        model.enableNotificationCenter { granted in
                            deniedNotifications = !granted
                        }
                    }
                ))
                if deniedNotifications {
                    Text("macOS is not letting Wattson post notifications. Turn them on for Wattson in System Settings › Notifications.")
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.lowPower.isSupported {
                group("Low Power Mode") {
                    if model.lowPowerPromptless == true {
                        Text("The switch in the panel can change Low Power Mode without asking for a password.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Button("Revoke Permission…") { model.removeLowPowerRule() }
                            .disabled(model.lowPowerBusy)
                    } else {
                        Text("Changing Low Power Mode needs root, which macOS grants no other way. The switch in the panel will offer to set this up.")
                            .font(.system(size: 10))
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            group("Startup") {
                Toggle("Launch at login", isOn: Binding(
                    get: { model.launchAtLogin },
                    set: { model.setLaunchAtLogin($0) }
                ))
            }

            group("Debug Options") {
                Toggle("Show raw hardware capture", isOn: $model.showDebugOptions)
                Text("Adds a diagnostic capture command to the menu. Reports can be large and may include serial numbers.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
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
    /// Info.plist is the only place the version is written. The fallback is
    /// deliberately not a number: a second copy of it here would be wrong the
    /// moment the real one moves, and has been.
    var shortVersion: String {
        object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }
}
