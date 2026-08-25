import AppKit
import Combine
import SwiftUI

/// Whether the app currently wants a Dock icon and a menu bar.
///
/// An accessory app has neither, so opening a window means asking for
/// `.regular` and closing one means giving it back. Each window controller used
/// to do that on its own, which meant closing either of them dropped the policy
/// while the *other* one was still on screen — a Settings window left with no
/// menu bar above it and no ⌘W to close it with. The policy belongs to the app,
/// so the decision is made once, here, by counting what is left.
@MainActor
enum ActivationPolicy {
    static func claim() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    /// A closing window is still in `NSApp.windows` when its delegate hears
    /// about it, so it is excluded by identity rather than by visibility.
    ///
    /// `canBecomeMain` is what separates a real window from the app's other
    /// surfaces: the popover's window and the toast panel are both visible and
    /// neither is a reason to keep a menu bar on screen.
    static func relinquish(after closing: NSWindow?) {
        let remaining = NSApp.windows.contains {
            $0 !== closing && $0.isVisible && $0.canBecomeMain
        }
        guard !remaining else { return }
        NSApp.setActivationPolicy(.accessory)
    }
}

/// Owns the menu bar item and the popover.
///
/// This is AppKit rather than SwiftUI's `MenuBarExtra` on purpose: MenuBarExtra
/// renders a `Label` as icon-only, so the wattage text never appeared.
/// `NSStatusItem` lets us set image and title directly.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    /// Made on the first opening and kept for good; its contents come and go
    /// with each opening instead. See `panelPopover` and `teardownPanelContent`.
    private var popover: NSPopover?
    private let model = DeviceModel()
    /// The panel's expansion and search state, kept out here so it survives the
    /// view being discarded.
    private let panelState = PanelState()
    private let settings = SettingsWindowController()
    private let diagnostics = DiagnosticsWindowController()
    private var cancellables = Set<AnyCancellable>()
    /// What the button's image is currently drawn from.
    private var shownIcon: MenuBarIcon?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        // Monospaced digits stop the item resizing every time the wattage ticks.
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        // objectWillChange fires *before* the value changes, so hop a runloop
        // turn to read the new one.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatusItem() }
            .store(in: &cancellables)

        // The debug capture command must genuinely disappear until the user
        // turns it on in Settings, including from the app's normal menu.
        model.$showDebugOptions
            .dropFirst()
            .sink { [weak self] _ in self?.installMainMenu() }
            .store(in: &cancellables)

        updateStatusItem()
    }

    /// An accessory app has no menu bar of its own, but opening Settings flips
    /// the activation policy to `.regular` — which used to hand the user a
    /// completely empty menu bar and no ⌘W to close the window with.
    private func installMainMenu() {
        let main = NSMenu()

        let appMenu = NSMenu(title: "Wattson")
        appMenu.addItem(
            withTitle: "About Wattson",
            action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)),
            keyEquivalent: ""
        )
        appMenu.addItem(.separator())
        if model.showDebugOptions {
            appMenu.addItem(withTitle: "Capture Raw Hardware Data…", action: #selector(openDiagnostics), keyEquivalent: "")
        }
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",")
        appMenu.addItem(.separator())
        appMenu.addItem(
            withTitle: "Quit Wattson",
            action: #selector(NSApplication.terminate(_:)),
            keyEquivalent: "q"
        )

        // Text fields in Settings need these to work at all.
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(
            withTitle: "Select All",
            action: #selector(NSText.selectAll(_:)),
            keyEquivalent: "a"
        )

        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(
            withTitle: "Close",
            action: #selector(NSWindow.performClose(_:)),
            keyEquivalent: "w"
        )

        for menu in [appMenu, editMenu, windowMenu] {
            let item = NSMenuItem()
            item.submenu = menu
            main.addItem(item)
        }
        NSApp.mainMenu = main
        NSApp.windowsMenu = windowMenu
    }

    @objc private func openSettings() {
        settings.show(model: model)
    }

    @objc private func openDiagnostics() {
        diagnostics.show(model: model)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        // The battery is drawn rather than looked up, and this runs on every
        // power tick, so redraw only when the picture would actually differ.
        let icon = model.menuBarIcon
        if icon != shownIcon {
            shownIcon = icon
            switch icon {
            case .battery(let percent, let charging, let lowPower):
                button.image = BatteryGlyph.menuBarImage(
                    percent: percent, charging: charging, lowPower: lowPower
                )
            case .symbol(let name):
                button.image = NSImage(systemSymbolName: name, accessibilityDescription: "Wattson")
                button.image?.isTemplate = true
            }
        }

        if let title = model.titleText {
            button.title = " " + title
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    @objc private func togglePopover() {
        if let popover, popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        model.refresh()
        model.isPresented = true

        let popover = panelPopover()
        popover.contentViewController = makePanelController()
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the first click inside the popover only brings it forward.
        popover.contentViewController?.view.window?.makeKey()
    }

    /// The popover itself, made once and kept.
    ///
    /// Kept rather than rebuilt per opening on purpose. `NSPopover` owns a
    /// window, and a window owns backing surfaces the render server allocates;
    /// throwing the popover away and making another one leaves those surfaces
    /// behind to be collected in their own time, and opening the panel twenty
    /// times ran the process up by tens of megabytes of `IOSurface` that way.
    /// Reusing one popover keeps one window and one set of surfaces for good.
    private func panelPopover() -> NSPopover {
        if let popover { return popover }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        self.popover = popover
        return popover
    }

    /// The panel's contents, built fresh each time it is opened.
    ///
    /// This is the expensive half and the half that need not persist: a SwiftUI
    /// hosting controller holds a view tree, a layer tree and the caches behind
    /// them, none of which a closed panel needs. Building it takes a few
    /// milliseconds, against a popover that does not animate.
    private func makePanelController() -> NSHostingController<MenuContentView> {
        let hosting = NSHostingController(
            rootView: MenuContentView(
                model: model,
                ui: panelState,
                onOpenSettings: { [weak self] in
                    guard let self else { return }
                    self.popover?.performClose(nil)
                    self.settings.show(model: self.model)
                },
                onOpenDiagnostics: { [weak self] in
                    guard let self else { return }
                    self.popover?.performClose(nil)
                    self.diagnostics.show(model: self.model)
                },
                // Escape reaches the panel's own handler first, so closing has
                // to be something it can ask for.
                onClose: { [weak self] in self?.popover?.performClose(nil) }
            )
        )
        // Let the popover follow the panel as sections expand and collapse.
        hosting.sizingOptions = [.preferredContentSize]
        return hosting
    }

    /// Give the panel's contents back once it is off screen, keeping the
    /// popover and its window.
    ///
    /// Deliberately a runloop turn late: AppKit is still inside its own close
    /// when the delegate hears about it, and pulling the content view out from
    /// under it there is not safe. `malloc_zone_pressure_relief` is the second
    /// half of the job — releasing the objects only marks the pages free, and
    /// this is what hands them back to the kernel rather than leaving them on
    /// the heap's free list, where they still count against the process.
    private func teardownPanelContent() {
        guard let popover, !popover.isShown else { return }
        // An empty controller rather than nil: it collapses the popover's
        // window to nothing, where nil leaves AppKit holding a surface the
        // size of the panel that just closed.
        let empty = NSViewController()
        empty.view = NSView(frame: .zero)
        popover.contentViewController = empty
        malloc_zone_pressure_relief(nil, 0)
    }
}

extension AppDelegate: NSPopoverDelegate {
    /// Sampling slows back down once nobody is looking.
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in
            model.isPresented = false
            teardownPanelContent()
        }
    }
}
