import AppKit
import SwiftUI

/// What changed, in the fewest words that stay true.
struct ToastContent: Equatable {
    let symbol: String
    let title: String
    let detail: String?
}

/// A brief panel under the menu bar saying what was just plugged in or pulled.
///
/// Drawn in-app rather than through `UNUserNotificationCenter`: Wattson is
/// ad-hoc signed, and user notifications want a real bundle identity and an
/// authorisation prompt. This needs neither, and it appears next to the menu bar
/// item it is talking about.
@MainActor
final class ToastPresenter {
    private var panel: NSPanel?
    private var hosting: NSHostingView<ToastView>?
    private var dismissal: Task<Void, Never>?

    private static let visibleFor: TimeInterval = 3.5
    private static let width: CGFloat = 260

    /// True while a toast is on screen, so the caller can merge into it rather
    /// than stacking a second one on top.
    var isShowing: Bool { panel?.isVisible ?? false }

    func show(_ content: ToastContent) {
        let view = ToastView(content: content) { [weak self] in self?.dismiss() }
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
        dismissal = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.visibleFor * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.dismiss()
        }
    }

    func dismiss() {
        dismissal?.cancel()
        dismissal = nil
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

private struct ToastView: View {
    let content: ToastContent
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: content.symbol)
                .font(.system(size: 13, weight: .medium))
                .symbolVariant(.fill)
                .foregroundStyle(.secondary)
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                Text(content.title)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(2)
                if let detail = content.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(width: 260, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 11).fill(.regularMaterial))
        .overlay(
            RoundedRectangle(cornerRadius: 11).strokeBorder(.quaternary, lineWidth: 0.5)
        )
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .onTapGesture(perform: dismiss)
    }
}

/// Turns a batch of arrivals and departures into one line of text.
///
/// Attaching a seven-port hub fires a notification per downstream device, so the
/// interesting case is not "one device" — it is "a hub and everything behind
/// it", which has to read as a single event.
enum ToastSummary {
    static func content(arrived: [DeviceNode], left: [DeviceNode]) -> ToastContent? {
        if !arrived.isEmpty {
            var content = summarise(arrived, verb: "attached")
            if !left.isEmpty {
                let removals = left.count == 1
                    ? "\(left[0].name) removed"
                    : "\(left.count) devices removed"
                content = ToastContent(
                    symbol: content.symbol,
                    title: content.title,
                    detail: [content.detail, removals].compactMap { $0 }.joined(separator: " · ")
                )
            }
            return content
        }
        guard !left.isEmpty else { return nil }
        return summarise(left, verb: "removed")
    }

    private static func summarise(_ nodes: [DeviceNode], verb: String) -> ToastContent {
        if nodes.count == 1, let node = nodes.first {
            return ToastContent(
                symbol: node.symbolName,
                title: "\(node.name) \(verb)",
                detail: [node.typeLabel, node.linkSummary, node.vendor]
                    .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
            )
        }
        // A hub in the batch names the whole batch: it is the thing that was
        // physically plugged in, and the rest came with it.
        if let hub = nodes.first(where: { $0.typeLabel == "Hub" }) {
            let others = nodes.count - 1
            return ToastContent(
                symbol: hub.symbolName,
                title: "\(hub.name) \(verb)",
                detail: others == 1 ? "1 device" : "\(others) devices"
            )
        }
        return ToastContent(
            symbol: "cable.connector",
            title: "\(nodes.count) devices \(verb)",
            detail: nodes.prefix(3).map(\.name).joined(separator: ", ")
                + (nodes.count > 3 ? "…" : "")
        )
    }
}
