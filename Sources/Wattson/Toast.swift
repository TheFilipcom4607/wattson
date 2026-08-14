import AppKit
import SwiftUI

/// A brief panel under the menu bar saying what was just plugged in or pulled.
///
/// Drawn in-app rather than only through `UNUserNotificationCenter`: Wattson is
/// ad-hoc signed, and user notifications want a real bundle identity and an
/// authorisation prompt. This needs neither, and it appears next to the menu bar
/// item it is talking about.
@MainActor
final class ToastPresenter {
    private var panel: NSPanel?
    private var hosting: NSHostingView<ToastView>?
    private var dismissal: Task<Void, Never>?

    /// A notice still waiting on its facts stays up longer: it would otherwise
    /// spend most of its life on screen saying it does not know yet.
    private static let visibleFor: TimeInterval = 3.5
    private static let pendingFor: TimeInterval = 8
    /// Sized against a system notification banner, which is what it sits
    /// beside — a narrower panel in the same corner reads as a lesser one.
    static let width: CGFloat = 344

    /// True while a toast is on screen, so the caller can merge into it rather
    /// than stacking a second one on top.
    var isShowing: Bool { panel?.isVisible ?? false }
    /// Which notice that is, so an update can be told from a new arrival.
    private(set) var showingID: String?

    func show(_ notice: Notice) {
        showingID = notice.id
        let view = ToastView(content: notice) { [weak self] in self?.dismiss() }
        let panel = panel ?? makePanel()
        self.panel = panel

        if let hosting {
            hosting.rootView = view
        } else {
            let hosting = NSHostingView(rootView: view)
            panel.contentView = hosting
            self.hosting = hosting
        }

        guard let hosting else { return }
        hosting.layoutSubtreeIfNeeded()
        let size = hosting.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(origin(for: size))
        panel.alphaValue = 1
        panel.orderFrontRegardless()

        dismissal?.cancel()
        let showFor = notice.isPending ? Self.pendingFor : Self.visibleFor
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(showFor * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
        showingID = nil
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.2
            panel.animator().alphaValue = 0
        } completionHandler: { [weak panel] in
            panel?.orderOut(nil)
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 60),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        // A menu bar app must never steal focus to say something this small.
        panel.isFloatingPanel = true
        panel.becomesKeyOnlyIfNeeded = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isMovable = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        return panel
    }

    /// Top right, just under the menu bar — beside the status item it concerns.
    private func origin(for size: CGSize) -> NSPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let frame = screen.visibleFrame
        return NSPoint(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 6)
    }
}

struct ToastView: View {
    let content: Notice
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 11) {
            Image(systemName: content.symbol)
                .font(.system(size: 17, weight: .medium))
                .symbolVariant(.fill)
                .foregroundStyle(.secondary)
                .frame(width: 21)
                .padding(.top, 1)

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 13, weight: .semibold))
                    .lineLimit(2)
                if let detail = content.detail {
                    Text(detail)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 13)
        .frame(width: ToastPresenter.width, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 14).strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 14))
        .onTapGesture(perform: dismiss)
    }
}

