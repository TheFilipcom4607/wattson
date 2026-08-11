import AppKit
import Combine
import SwiftUI

/// Owns the menu bar item and the popover.
///
/// This is AppKit rather than SwiftUI's `MenuBarExtra` on purpose: MenuBarExtra
/// renders a `Label` as icon-only, so the wattage text never appeared.
/// `NSStatusItem` lets us set image and title directly.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var popover: NSPopover!
    private let model = DeviceModel()
    private let settings = SettingsWindowController()
    private let cableTest = CableTestWindowController()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)
        // Monospaced digits stop the item resizing every time the wattage ticks.
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 13, weight: .regular)

        let hosting = NSHostingController(
            rootView: MenuContentView(
                model: model,
                onOpenSettings: { [weak self] in
                    guard let self else { return }
                    self.popover.performClose(nil)
                    self.settings.show(model: self.model)
                },
                onOpenCableTest: { [weak self] in
                    guard let self else { return }
                    self.popover.performClose(nil)
                    self.cableTest.show(model: self.model)
                }
            )
        )
        // Let the popover follow the panel as sections expand and collapse.
        hosting.sizingOptions = [.preferredContentSize]

        popover = NSPopover()
        popover.behavior = .transient
        popover.animates = false
        popover.contentViewController = hosting
        popover.delegate = self

        // objectWillChange fires *before* the value changes, so hop a runloop
        // turn to read the new one.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] in self?.updateStatusItem() }
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
        appMenu.addItem(withTitle: "Test Your Cable…", action: #selector(openCableTest), keyEquivalent: "")
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

    @objc private func openCableTest() {
        cableTest.show(model: model)
    }

    private func updateStatusItem() {
        guard let button = statusItem.button else { return }

        button.image = NSImage(
            systemSymbolName: model.symbolName,
            accessibilityDescription: "Wattson"
        )
        button.image?.isTemplate = true

        if let title = model.titleText {
            button.title = " " + title
            button.imagePosition = .imageLeading
        } else {
            button.title = ""
            button.imagePosition = .imageOnly
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
            return
        }
        guard let button = statusItem.button else { return }
        model.refresh()
        model.isPresented = true
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Without this the first click inside the popover only brings it forward.
        popover.contentViewController?.view.window?.makeKey()
    }
}

extension AppDelegate: NSPopoverDelegate {
    /// Sampling slows back down once nobody is looking.
    nonisolated func popoverDidClose(_ notification: Notification) {
        Task { @MainActor in model.isPresented = false }
    }
}
