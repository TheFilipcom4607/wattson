import AppKit
import SwiftUI

/// One pane of Settings.
///
/// The column had grown past the height of a 13" screen. It is four panes now,
/// split by what you are changing rather than evenly — the menu bar picker is a
/// pane of its own because it is the one people come here for.
enum SettingsTab: String, CaseIterable {
    case menuBar
    case panel
    case notifications
    case general

    var title: String {
        switch self {
        case .menuBar: return "Menu Bar"
        case .panel: return "Panel"
        case .notifications: return "Notifications"
        case .general: return "General"
        }
    }

    var symbol: String {
        switch self {
        case .menuBar: return "menubar.rectangle"
        case .panel: return "rectangle.inset.filled"
        case .notifications: return "bell"
        case .general: return "gearshape"
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: DeviceModel
    let tab: SettingsTab
    /// Set when macOS refuses, which it does silently and permanently once the
    /// user has said no — the switch alone would look broken.
    @State private var deniedNotifications = false

    /// Just the one pane. The switching is the window's job, through a real
    /// toolbar — SwiftUI's own `TabView` draws the old boxed tab strip on
    /// macOS, which looks nothing like a settings window ought to.
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            switch tab {
            case .menuBar: menuBar
            case .panel: panel
            case .notifications: notifications
            case .general: general
            }
        }
        .padding(20)
        .frame(width: 380, alignment: .leading)
        // Settings apply as you change them, so there is nothing to confirm —
        // Escape and ⌘W close it, the way a settings window should.
        .onExitCommand { NSApp.keyWindow?.close() }
    }

    /// No group heading on the single-subject panes: the window's title bar is
    /// already saying it, and a settings window that captions every pane with
    /// its own name reads like a form.
    private var menuBar: some View {
        Group {
            // Each option previews what it would actually put up there, live —
            // the labels alone did not tell you what you would get.
            Picker("Show", selection: $model.titleMode) {
                ForEach(TitleMode.allCases) { mode in
                    (Text(mode.label) + Text("   " + preview(mode)).foregroundColor(.secondary))
                        .tag(mode)
                }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
        }
    }

    private var panel: some View {
        Group {
            plain {
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
        }
    }

    private var notifications: some View {
        Group {
            group("What to announce") {
                Toggle("Chargers", isOn: $model.announcePower)
                Toggle("Warn when the battery drains on a charger", isOn: $model.warnBatteryDrain)
                    .disabled(!model.announcePower)
                    .padding(.leading, 16)
                Toggle("Contract changes", isOn: $model.announceContract)
                    .disabled(!model.announcePower)
                    .padding(.leading, 16)
                Toggle("Drives and cards", isOn: $model.announceStorage)
                Toggle("Everything else that plugs in", isOn: $model.announceDevices)
            }

            group("Where they show") {
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
        }
    }

    private var general: some View {
        Group {
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

    /// A group with nothing to caption it, for a pane about one thing.
    private func plain<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            content()
                .toggleStyle(.checkbox)
        }
    }
}

/// Holds the settings window, which the accessory-mode app has to manage itself.
///
/// The panes are switched by a real `NSToolbar` in `.preference` style, which is
/// what gives a settings window the look people expect of one — big centred
/// icons under the title bar, the title naming the pane you are in. SwiftUI has
/// no equivalent outside a `Settings` scene, which a menu bar app does not have.
@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate, NSToolbarDelegate {
    private var window: NSWindow?
    private var hosting: NSHostingController<SettingsView>?
    private var model: DeviceModel?
    private var tab: SettingsTab = .menuBar

    func show(model: DeviceModel) {
        self.model = model
        if window == nil {
            // Built from the hosting controller so the window sizes to the
            // content rather than to a hard-coded height that has to be kept
            // in step with it.
            let hosting = NSHostingController(rootView: SettingsView(model: model, tab: tab))
            let window = NSWindow(contentViewController: hosting)
            window.styleMask = [.titled, .closable]
            window.isReleasedWhenClosed = false
            window.delegate = self

            let toolbar = NSToolbar(identifier: "settings")
            toolbar.delegate = self
            toolbar.allowsUserCustomization = false
            toolbar.displayMode = .iconAndLabel
            toolbar.selectedItemIdentifier = NSToolbarItem.Identifier(tab.rawValue)
            window.toolbar = toolbar
            window.toolbarStyle = .preference

            window.title = tab.title
            window.center()
            self.hosting = hosting
            self.window = window
        }
        // An .accessory app has no Dock icon, so it must ask for focus itself.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    @objc private func selectTab(_ sender: NSToolbarItem) {
        guard let tab = SettingsTab(rawValue: sender.itemIdentifier.rawValue), let model else { return }
        self.tab = tab
        window?.title = tab.title
        hosting?.rootView = SettingsView(model: model, tab: tab)
        resizeToFit()
    }

    /// Panes are different heights, so the window follows — growing downwards
    /// from where its title bar already is, rather than from its bottom edge,
    /// which is what every other settings window does.
    private func resizeToFit() {
        guard let window, let hosting else { return }
        hosting.view.layoutSubtreeIfNeeded()
        let content = hosting.view.fittingSize
        var frame = window.frame
        let target = window.frameRect(forContentRect: NSRect(origin: .zero, size: content))
        frame.origin.y += frame.height - target.height
        frame.size = target.size
        window.setFrame(frame, display: true, animate: true)
    }

    // MARK: - Toolbar

    private var identifiers: [NSToolbarItem.Identifier] {
        SettingsTab.allCases.map { NSToolbarItem.Identifier($0.rawValue) }
    }

    nonisolated func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { identifiers }
    }

    nonisolated func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { identifiers }
    }

    /// What makes the icons behave as a set of tabs rather than as buttons.
    nonisolated func toolbarSelectableItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        MainActor.assumeIsolated { identifiers }
    }

    nonisolated func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier identifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        MainActor.assumeIsolated {
            guard let tab = SettingsTab(rawValue: identifier.rawValue) else { return nil }
            let item = NSToolbarItem(itemIdentifier: identifier)
            item.label = tab.title
            item.image = NSImage(systemSymbolName: tab.symbol, accessibilityDescription: tab.title)
            item.target = self
            item.action = #selector(selectTab(_:))
            return item
        }
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
