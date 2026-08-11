import AppKit
import SwiftUI

struct MenuContentView: View {
    @ObservedObject var model: DeviceModel
    var onOpenSettings: () -> Void = {}

    /// Which connection cards are showing their detail rows. Keyed by the
    /// connection's stable id so a rescan does not collapse them.
    @State private var expanded: Set<String> = []
    /// Measured height of the scrolling body: a ScrollView has no intrinsic
    /// height and the popover sizes to fit, so it would collapse to nothing.
    @State private var bodyHeight: CGFloat = 0

    private static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)

            Divider().padding(.top, 10).padding(.bottom, 8)

            scrollingBody

            Divider().padding(.vertical, 6)
            footer
        }
        .frame(width: Self.width)
        .padding(.vertical, 10)
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Text(model.power.externalConnected ? "DRAWING FROM CHARGER" : "ON BATTERY")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                IconButton(symbol: "arrow.clockwise", help: "Rescan now", action: model.refresh)
                    .opacity(model.isScanning ? 0.35 : 1)
                IconButton(symbol: "gearshape.fill", help: "Settings", action: onOpenSettings)
            }

            headline

            if let allocation = model.power.allocation {
                if allocation.isInformative {
                    AllocationBar(allocation: allocation)
                    AllocationLegend(allocation: allocation)
                }
                caption(for: allocation)
            }

            if model.showSparkline, model.history.count > 1 {
                Sparkline(samples: model.history).padding(.top, 2)
            }
        }
    }

    /// The live wattage, as the one number you read at a glance.
    ///
    /// On battery this is the battery's own flow, so it reads negative — power
    /// leaving the cell. Plugged in it is what is arriving from the charger.
    private var headline: some View {
        let watts = model.power.externalConnected
            ? model.power.inputWatts
            : model.power.batteryWatts

        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(watts.map { String(format: "%.2f", $0) } ?? "—")
                .font(.system(size: 34, weight: .medium, design: .rounded))
                .monospacedDigit()
            Text("W")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)

            Spacer()

            if let volts = model.power.inputVolts, let amps = model.power.inputAmps,
               model.power.externalConnected {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.2f V", volts))
                    Text(String(format: "%.3f A", amps))
                }
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            }
        }
    }

    private func caption(for allocation: PowerAllocation) -> some View {
        HStack(spacing: 6) {
            if let battery = batteryCaption(for: allocation) {
                Text(battery)
            }
            Spacer()
            if let headroom = allocation.headroom {
                Text(String(format: "%.0f W headroom", headroom))
            }
        }
        .font(.system(size: 10))
        .monospacedDigit()
        .foregroundStyle(.tertiary)
        .lineLimit(1)
    }

    /// "Battery 80% · draining · -2.31 W"
    ///
    /// The flow is spelled out whenever the bar is not already carrying it —
    /// which is exactly the case where it matters most: plugged in, but the
    /// charger is not keeping up and the cell is still going down.
    private func batteryCaption(for allocation: PowerAllocation) -> String? {
        guard let summary = model.power.batterySummary else { return nil }
        let inBar = allocation.segments.contains { $0.id == "battery" }
        guard model.power.externalConnected, !inBar,
              let watts = model.power.batteryWatts, abs(watts) > 0.05
        else { return summary }
        return summary + String(format: " · %+.2f W", watts)
    }

    // MARK: - Body

    /// How tall the scrolling region may grow before it starts scrolling.
    /// The old fixed 360 pt cut the device list off on every machine.
    private var maxBodyHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(160, min(560, visible - 380))
    }

    private var overflows: Bool { bodyHeight > maxBodyHeight + 1 }

    private var scrollingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if model.showDevices {
                    let connections = model.connections
                    if connections.isEmpty {
                        Text("Nothing connected")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(connections) { connection in
                        ConnectionCard(
                            connection: connection,
                            showCable: model.showCable,
                            showVendors: model.showVendors,
                            isExpanded: expanded.contains(connection.id),
                            toggle: { toggle(connection.id) }
                        )
                    }
                }

                if model.showPortLimits, let limits = model.portLimitsSummary {
                    Text(limits)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .padding(.top, 2)
                }
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 4)
            .background(
                GeometryReader { geometry in
                    Color.clear.preference(key: BodyHeightKey.self, value: geometry.size.height)
                }
            )
        }
        .frame(height: min(max(bodyHeight, 24), maxBodyHeight))
        // Fade the last few points so "there is more below" is visible before
        // you happen to scroll; overlay scrollers show nothing at rest.
        .mask(overflows ? AnyView(bottomFade) : AnyView(Color.black))
        .onPreferenceChange(BodyHeightKey.self) { bodyHeight = $0 }
    }

    private var bottomFade: some View {
        LinearGradient(
            stops: [
                .init(color: .black, location: 0),
                .init(color: .black, location: 0.93),
                .init(color: .clear, location: 1)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }

    private func toggle(_ id: String) {
        if expanded.contains(id) {
            expanded.remove(id)
        } else {
            expanded.insert(id)
        }
    }

    // MARK: - Footer

    /// Just the two things that are not settings. Menu-bar display and launch
    /// at login used to live here as well as in Settings, which meant two
    /// places to change one thing.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            MenuButton(title: "Settings…", trailing: "⌘,", action: onOpenSettings)
                .keyboardShortcut(",")
            MenuButton(title: "Quit Wattson", trailing: "⌘Q") {
                NSApplication.shared.terminate(nil)
            }
            .keyboardShortcut("q")
        }
        .padding(.horizontal, 4)
    }
}

// MARK: - Power allocation

/// Which slice of the bar belongs to what. Kept together so the bar and its
/// legend cannot drift apart.
private func allocationColor(_ id: String) -> Color {
    switch id {
    case "accessories": return .teal
    case "battery": return .green
    default: return .accentColor
    }
}

/// Where the power goes, as one stacked bar: Mac, accessories, battery, and
/// whatever the charger still has spare.
private struct AllocationBar: View {
    let allocation: PowerAllocation

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 1.5) {
                ForEach(allocation.segments) { segment in
                    Rectangle()
                        .fill(allocationColor(segment.id))
                        .frame(width: width(of: segment, in: geometry.size.width))
                }
                // Takes whatever is left, so an empty tail is the headroom.
                Rectangle().fill(.quaternary)
            }
            .clipShape(Capsule())
        }
        .frame(height: 7)
    }

    private func width(of segment: PowerAllocation.Segment, in total: CGFloat) -> CGFloat {
        max(0, total * segment.watts / allocation.capacity)
    }
}

private struct AllocationLegend: View {
    let allocation: PowerAllocation

    var body: some View {
        // Fixed gaps with a trailing Spacer: distributing them edge to edge
        // made two segments read as two unrelated readouts rather than a key.
        HStack(spacing: 14) {
            ForEach(allocation.segments) { segment in
                HStack(spacing: 4) {
                    Circle()
                        .fill(allocationColor(segment.id))
                        .frame(width: 6, height: 6)
                    Text(segment.label).foregroundStyle(.secondary)
                    Text(String(format: "%.1f W", segment.watts)).monospacedDigit()
                }
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
    }
}

/// Wattage over the recent past, so spikes and charge ramps are visible.
private struct Sparkline: View {
    let samples: [PowerSample]

    private var peak: Double { max(samples.map(\.watts).max() ?? 1, 0.5) }

    /// Zero-based, so the height still means something absolute, but with
    /// headroom above the peak — a steady load pinned to the ceiling filled the
    /// whole box and read as a solid rectangle rather than a graph.
    private var ceiling: Double { peak * 1.2 }

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("LAST \(span)")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.tertiary)
                Spacer()
                Text(String(format: "peak %.1f W", peak))
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }

            GeometryReader { geometry in
                ZStack {
                    areaPath(in: geometry.size)
                        .fill(
                            LinearGradient(
                                colors: [.accentColor.opacity(0.22), .accentColor.opacity(0.01)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                    linePath(in: geometry.size)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                }
            }
            .frame(height: 34)
            .background(RoundedRectangle(cornerRadius: 5).fill(.quaternary.opacity(0.35)))
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
    }

    private func point(_ index: Int, in size: CGSize) -> CGPoint {
        let step = samples.count > 1 ? size.width / CGFloat(samples.count - 1) : size.width
        return CGPoint(
            x: CGFloat(index) * step,
            y: size.height - CGFloat(samples[index].watts / ceiling) * size.height
        )
    }

    private func linePath(in size: CGSize) -> Path {
        Path { path in
            guard let first = samples.indices.first else { return }
            path.move(to: point(first, in: size))
            for index in samples.indices.dropFirst() {
                path.addLine(to: point(index, in: size))
            }
        }
    }

    private func areaPath(in size: CGSize) -> Path {
        Path { path in
            guard !samples.isEmpty else { return }
            path.move(to: CGPoint(x: 0, y: size.height))
            for index in samples.indices {
                path.addLine(to: point(index, in: size))
            }
            path.addLine(to: CGPoint(x: point(samples.count - 1, in: size).x, y: size.height))
            path.closeSubpath()
        }
    }

    /// How much wall time the samples cover.
    private var span: String {
        guard let first = samples.first?.at, let last = samples.last?.at else { return "—" }
        let seconds = Int(last.timeIntervalSince(first))
        if seconds < 90 { return "\(max(seconds, 1))s" }
        return "\(seconds / 60) min"
    }
}

// MARK: - Connections

/// One physical connection: what it is, what is flowing, and — on demand —
/// everything about the cable and the device on the end of it.
private struct ConnectionCard: View {
    let connection: Connection
    var showCable = true
    var showVendors = true
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { headerRow }
                .buttonStyle(.plain)

            if !connection.extraDevices.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(connection.extraDevices) { entry in
                        DeviceLine(entry: entry, showVendors: showVendors)
                    }
                }
                .padding(.top, 7)
            }

            if isExpanded, !detailRows.isEmpty || !connection.profiles.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Divider().opacity(0.5).padding(.bottom, 2)
                    ForEach(Array(detailRows.enumerated()), id: \.offset) { _, row in
                        DetailRow(label: row.label, value: row.value)
                    }
                    if !connection.profiles.isEmpty {
                        ProfileRow(
                            profiles: connection.profiles,
                            negotiated: connection.negotiatedProfile
                        )
                    }
                }
                .padding(.top, 7)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 7).fill(.quaternary.opacity(0.45)))
    }

    private var headerRow: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: connection.symbol)
                .font(.system(size: 12))
                .foregroundStyle(connection.role == .source
                    ? AnyShapeStyle(.tint)
                    : AnyShapeStyle(.secondary))
                .frame(width: 16)

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(connection.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
                    if connection.isApple {
                        Image(systemName: "apple.logo").font(.system(size: 9))
                    }
                }
                Text(connection.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let detail = connection.detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: 4)

            if let watts = connection.liveWatts {
                VStack(alignment: .trailing, spacing: 0) {
                    Text(String(format: "%.2f W", watts))
                        .font(.system(size: 13, weight: .semibold))
                        .monospacedDigit()
                    if let note = connection.wattsNote {
                        Text(note)
                            .font(.system(size: 9))
                            .foregroundStyle(.tertiary)
                    }
                }
                .fixedSize()
            }

            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
                .frame(width: 10)
                .padding(.top, 3)
        }
        .contentShape(Rectangle())
    }

    private var detailRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []

        if let port = connection.port {
            if let negotiated = port.negotiated {
                rows.append(("Contract", String(
                    format: "%.0f V / %.2f A (%.0f W)",
                    negotiated.volts, negotiated.amps, negotiated.watts
                )))
            }
            if port.isSourcing, let volts = port.outputVolts, let amps = port.outputAmps {
                rows.append(("Measured", String(format: "%.2f V / %.3f A", volts, amps)))
            }
            if showCable, port.describesCable {
                // With no data link the card's own subtitle already says so.
                if port.carriesData {
                    rows.append(("Link now", port.activeSummary))
                }
                rows.append(("Cable max", port.cableCapability))
                rows.append(("Cable", port.cableWiringSummary))
                rows.append(("Current", port.currentRating))
            }
        }

        for device in connection.devices {
            rows.append(contentsOf: device.detailRows(includeVendor: showVendors))
        }
        return rows
    }
}

/// A device hanging below whatever names the card — a hub's downstream ports.
private struct DeviceLine: View {
    let entry: FlatDevice
    var showVendors = true

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: entry.node.symbolName)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .frame(width: 12)
            Text(entry.node.name)
                .font(.system(size: 11))
                .lineLimit(1)
            if let link = entry.node.linkSummary {
                Text(link)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)
            if let watts = entry.node.measuredWatts ?? entry.node.watts {
                Text(String(format: "%.1f W", watts))
                    .font(.system(size: 10))
                    .monospacedDigit()
                    // Solid when the rail was actually measured, faded when it
                    // is only the budget the port granted.
                    .foregroundStyle(entry.node.measuredWatts != nil
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(.tertiary))
            }
        }
        .padding(.leading, CGFloat(entry.depth) * 12 + 24)
        // Nested devices get no expanded section of their own, so their full
        // detail — descriptive speed, measured vs allocated, vendor — lives here.
        .help(entry.node.detailLines(includeVendor: showVendors).joined(separator: "\n"))
    }
}

/// The voltage ladder the charger offers, on one line instead of five chips.
private struct ProfileRow: View {
    let profiles: [PDProfile]
    let negotiated: Int?

    var body: some View {
        DetailRow(label: "PD profiles", value: nil) {
            HStack(spacing: 0) {
                ForEach(Array(profiles.enumerated()), id: \.element.id) { index, profile in
                    let isActive = profile.id == negotiated
                    Text(String(format: "%.0f", profile.volts))
                        .font(.system(size: 11, weight: isActive ? .bold : .regular))
                        .foregroundStyle(isActive ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                    if index < profiles.count - 1 {
                        Text(" / ").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
                Text(" V").font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .monospacedDigit()
            // The ladder is shown as volts alone to keep it to one line; the
            // current and wattage of each step are a hover away.
            .help(profiles
                .map { String(format: "%.0f V · %.2f A · %.0f W", $0.volts, $0.amps, $0.watts) }
                .joined(separator: "\n"))
        }
    }
}

// MARK: - Shared pieces

/// A fixed label column with a wrapping value, so rows line up.
private struct DetailRow<Content: View>: View {
    let label: String
    let value: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label)
                .font(.system(size: 10))
                .foregroundStyle(.tertiary)
                .frame(width: 74, alignment: .leading)
            if let value {
                Text(value)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            content()
            Spacer(minLength: 0)
        }
    }
}

extension DetailRow where Content == EmptyView {
    init(label: String, value: String) {
        self.init(label: label, value: value) { EmptyView() }
    }
}

private struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 10, weight: .semibold))
                .frame(width: 20, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .help(help)
    }
}

/// Height of the scrolling body, measured so the ScrollView can be given a
/// real frame.
private struct BodyHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// A row that highlights like a native menu item.
private struct MenuButton: View {
    let title: String
    var trailing: String? = nil
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title)
                Spacer()
                if let trailing {
                    Text(trailing)
                        .font(.system(size: 11))
                        .foregroundStyle(isHovering
                            ? AnyShapeStyle(.white.opacity(0.75))
                            : AnyShapeStyle(.secondary))
                }
            }
            .font(.system(size: 13))
            .foregroundStyle(isHovering ? AnyShapeStyle(.white) : AnyShapeStyle(.primary))
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 5)
                    .fill(isHovering ? AnyShapeStyle(.tint) : AnyShapeStyle(.clear))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
    }
}
