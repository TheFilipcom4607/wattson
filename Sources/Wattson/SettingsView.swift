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

            // Every pane, not just General: it is what the window says about
            // itself, and which pane you happen to be standing in is no reason
            // for the version to be somewhere else.
            Divider()
            credits
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
                Toggle("CPU speed", isOn: $model.showThrottle)
            }
        }
    }

    private var notifications: some View {
        Group {
            group("What to announce") {
                Toggle("Chargers", isOn: $model.announcePower)
                Toggle("Warn when the battery drains on a charger", isOn: $model.warnBatteryDrain)
                Toggle("Warn when liquid is detected in a port", isOn: $model.warnLiquid)
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
        }
    }

    /// What this is, where it lives, and who to blame for it.
    private var credits: some View {
        HStack(spacing: 6) {
            Link(destination: URL(string: "https://github.com/TheFilipcom4607/wattson")!) {
                HStack(spacing: 5) {
                    GitHubMark()
                        .frame(width: 12, height: 12)
                    Text("Wattson \(Bundle.main.shortVersion)")
                }
            }
            .help("github.com/TheFilipcom4607/wattson")

            Text("·").foregroundStyle(.tertiary)

            HStack(spacing: 0) {
                Text("made by ").foregroundStyle(.secondary)
                Link("thefilip", destination: URL(string: "https://github.com/TheFilipcom4607")!)
                    .help("github.com/TheFilipcom4607")
            }
        }
        .font(.system(size: 11))
        .buttonStyle(.plain)
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

/// GitHub's own mark, from octicons' `mark-github-16`.
///
/// Its one elliptical arc is converted to cubics here, so this stays a plain
/// SwiftUI path with nothing to parse at runtime and no asset to ship.
private struct GitHubMark: Shape {
    func path(in rect: CGRect) -> Path {
        // The mark is drawn on a 16 x 16 box, scaled into whatever it is given.
        func p(_ x: CGFloat, _ y: CGFloat, _ rect: CGRect) -> CGPoint {
            CGPoint(x: rect.minX + x / 16 * rect.width, y: rect.minY + y / 16 * rect.height)
        }
        var path = Path()
        path.move(to: p(6.766, 11.328, rect))
        path.addCurve(to: p(3.25, 7.672, rect), control1: p(4.703, 11.078, rect), control2: p(3.25, 9.594, rect))
        path.addCurve(to: p(4, 5.484, rect), control1: p(3.25, 6.891, rect), control2: p(3.531, 6.047, rect))
        path.addCurve(to: p(4.063, 3.422, rect), control1: p(3.797, 4.969, rect), control2: p(3.828, 3.875, rect))
        path.addCurve(to: p(6.031, 4.125, rect), control1: p(4.688, 3.344, rect), control2: p(5.531, 3.672, rect))
        path.addCurve(to: p(8.016, 3.844, rect), control1: p(6.625, 3.938, rect), control2: p(7.25, 3.844, rect))
        path.addCurve(to: p(9.969, 4.109, rect), control1: p(8.781, 3.844, rect), control2: p(9.406, 3.938, rect))
        path.addCurve(to: p(11.938, 3.422, rect), control1: p(10.453, 3.672, rect), control2: p(11.313, 3.344, rect))
        path.addCurve(to: p(11.984, 5.469, rect), control1: p(12.156, 3.844, rect), control2: p(12.188, 4.937, rect))
        path.addCurve(to: p(12.75, 7.672, rect), control1: p(12.484, 6.062, rect), control2: p(12.75, 6.859, rect))
        path.addCurve(to: p(9.203, 11.312, rect), control1: p(12.75, 9.594, rect), control2: p(11.297, 11.047, rect))
        path.addCurve(to: p(10.093, 13.266, rect), control1: p(9.734, 11.656, rect), control2: p(10.093, 12.406, rect))
        path.addLine(to: p(10.093, 14.891, rect))
        path.addCurve(to: p(10.953, 15.438, rect), control1: p(10.093, 15.359, rect), control2: p(10.484, 15.625, rect))
        path.addCurve(to: p(16, 8.03, rect), control1: p(13.781, 14.359, rect), control2: p(16, 11.53, rect))
        path.addCurve(to: p(7.984, 0, rect), control1: p(16, 3.61, rect), control2: p(12.406, 0, rect))
        path.addCurve(to: p(0, 8.031, rect), control1: p(3.563, 0, rect), control2: p(0, 3.61, rect))
        path.addCurve(to: p(5.172, 15.453, rect), control1: p(-0.009, 11.347, rect), control2: p(2.058, 14.314, rect))
        path.addCurve(to: p(6, 14.906, rect), control1: p(5.594, 15.609, rect), control2: p(6, 15.328, rect))
        path.addLine(to: p(6, 13.656, rect))
        path.addCurve(to: p(5.25, 13.812, rect), control1: p(5.781, 13.75, rect), control2: p(5.5, 13.812, rect))
        path.addCurve(to: p(3.172, 12.203, rect), control1: p(4.219, 13.812, rect), control2: p(3.61, 13.25, rect))
        path.addCurve(to: p(2.453, 11.484, rect), control1: p(3, 11.781, rect), control2: p(2.812, 11.531, rect))
        path.addCurve(to: p(2.203, 11.297, rect), control1: p(2.266, 11.469, rect), control2: p(2.203, 11.391, rect))
        path.addCurve(to: p(2.828, 10.969, rect), control1: p(2.203, 11.109, rect), control2: p(2.516, 10.969, rect))
        path.addCurve(to: p(4.078, 11.829, rect), control1: p(3.281, 10.969, rect), control2: p(3.672, 11.25, rect))
        path.addCurve(to: p(5.109, 12.484, rect), control1: p(4.391, 12.281, rect), control2: p(4.718, 12.484, rect))
        path.addCurve(to: p(6.109, 11.984, rect), control1: p(5.5, 12.484, rect), control2: p(5.75, 12.344, rect))
        path.addCurve(to: p(6.766, 11.328, rect), control1: p(6.375, 11.719, rect), control2: p(6.579, 11.484, rect))
        return path
    }
}
