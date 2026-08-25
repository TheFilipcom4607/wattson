import AppKit
import SwiftUI

/// What the panel remembers between openings.
///
/// This was `@State` on `MenuContentView` and had to leave it: the view and its
/// whole SwiftUI backing are now thrown away when the panel closes, to give the
/// memory back, and `@State` would go with them — every card collapsed and the
/// search box cleared on each reopen. Held here instead, on an object the app
/// delegate keeps, it costs a few strings and outlives the view that shows it.
final class PanelState: ObservableObject {
    /// Which connection cards are showing their detail rows. Keyed by the
    /// connection's stable id so a rescan does not collapse them.
    @Published var expanded: Set<String> = []
    /// The same, for individual devices in the tree.
    @Published var expandedDevices: Set<String> = []
    @Published var query = ""
    /// Measured height of the scrolling body: a ScrollView has no intrinsic
    /// height and the popover sizes to fit, so it would collapse to nothing.
    @Published var bodyHeight: CGFloat = 0
}

struct MenuContentView: View {
    @ObservedObject var model: DeviceModel
    @ObservedObject var ui: PanelState
    var onOpenSettings: () -> Void = {}
    var onOpenDiagnostics: () -> Void = {}
    var onClose: () -> Void = {}

    private static let width: CGFloat = 380

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 14)

            Divider().padding(.top, 10).padding(.bottom, 8)

            if showsSearch { searchField }

            scrollingBody

            Divider().padding(.vertical, 6)
            footer
        }
        .frame(width: Self.width)
        .padding(.vertical, 10)
        // Escape clears the query first and closes the panel only once there is
        // nothing left to clear — a focused text field changes what Escape means.
        .onExitCommand {
            if ui.query.isEmpty {
                onClose()
            } else {
                ui.query = ""
            }
        }
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

            if let allocation = model.power.allocation, allocation.isInformative {
                AllocationBar(allocation: allocation)
                AllocationLegend(allocation: allocation, headroom: allocation.headroom)
            }

            // A latched pack fault, said where a fault should be said. Wear
            // never reaches this line: a battery at 79% of design is working as
            // built, and the capacity and cycle figures behind that judgement
            // stay in --dump and --json where they can be read in full.
            if model.power.health.needsService {
                WarningRow(
                    symbol: "exclamationmark.triangle.fill",
                    text: "Service recommended",
                    detail: "The battery's own gauge has latched a fault."
                )
            }

            if model.showSparkline, model.history.count > 1 {
                Sparkline(samples: model.history).padding(.top, 2)
            }

            if let hold = chargingHoldText { chargingHoldRow(hold) }

            if model.showThrottle, model.canReadSpeed { speedRow }

            if model.lowPower.isSupported { lowPowerRow }
        }
    }

    /// Why the battery is not filling, when the charger has said why.
    ///
    /// This sits directly under the headline because it answers the question
    /// the headline provokes: a charger delivering power while the percentage
    /// refuses to move. Wattson could previously only report that the two
    /// disagreed; the charger publishes its own account and this is it.
    private var chargingHoldText: String? {
        model.power.chargingHold.summary(
            externalConnected: model.power.externalConnected,
            isCharging: model.power.isCharging
        )
    }

    private func chargingHoldRow(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: model.power.chargingHold.isThermallyLimited
                  ? "thermometer.medium" : "pause.circle")
                .font(.system(size: 10))
                .foregroundStyle(.orange)
            Text(text)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    /// What the cores actually ran at, against what this machine can do.
    ///
    /// The frequency is evidence, not a verdict. A Mac sitting well under its
    /// ceiling because nothing is asking it to go faster is not being throttled,
    /// and nothing about the number alone can tell that apart from a Mac being
    /// held down — so the number is stated plainly and only turns orange, with a
    /// reason under it, when Wattson can name a cause it can actually see.
    private var speedRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "speedometer")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Throttling")
                    .font(.system(size: 11))
                Spacer(minLength: 4)
                Text(model.throttle.level.label)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(levelColor)
            }

            if let cluster = model.throttle.headline {
                SpeedBar(
                    fraction: cluster.fractionOfCeiling,
                    held: model.throttle.level >= .moderate
                )
            }

            // The evidence under the verdict: what the cores actually reached,
            // and the cause when there is one that can be named.
            if let cluster = model.throttle.headline {
                Text(
                    gigahertz(cluster.achievedMHz) + " of " + gigahertz(cluster.ceilingMHz)
                        + (model.throttleReason.map { " · " + $0.lowercasedFirst } ?? "")
                )
                    .font(.system(size: 9))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    /// Escalating rather than alarming: a machine dipping slightly under its
    /// ceiling is the normal state of a busy laptop and must not look like a
    /// fault, so only the top two levels take a warning colour.
    private var levelColor: AnyShapeStyle {
        switch model.throttle.level {
        case .none: return AnyShapeStyle(.tertiary)
        case .slight: return AnyShapeStyle(.secondary)
        case .moderate: return AnyShapeStyle(.orange)
        case .heavy: return AnyShapeStyle(.red)
        }
    }

    /// 4464 MHz reads as 4.46 GHz, which is how the number is spoken.
    private func gigahertz(_ megahertz: Double) -> String {
        String(format: "%.2f GHz", megahertz / 1000)
    }

    /// The one control the system's battery menu has that this panel did not.
    private var lowPowerRow: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 6) {
                Image(systemName: "tortoise.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                Text("Low Power Mode")
                    .font(.system(size: 11))
                if model.lowPower.isSplit {
                    // Two sources set differently is a state this one switch
                    // cannot describe, so it says so rather than lying.
                    Text(model.power.externalConnected ? "on charger only" : "on battery only")
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                }
                Spacer(minLength: 4)
                if model.lowPowerBusy {
                    ProgressView().controlSize(.small).scaleEffect(0.7)
                }
                // Labelled, then hidden. `Toggle("")` reads out as a bare
                // "switch" with nothing to say what it switches — the visible
                // caption to its left is a separate Text that VoiceOver has no
                // reason to associate with it.
                Toggle("Low Power Mode", isOn: Binding(
                    get: { model.lowPower.inEffect(externalConnected: model.power.externalConnected) },
                    set: { toggleLowPower(to: $0) }
                ))
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
                .disabled(model.lowPowerBusy)
            }
            if let error = model.lowPowerError {
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.red)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.top, 2)
    }

    /// Writing this setting needs root, so the first use explains exactly what
    /// is about to be installed before any password is asked for.
    private func toggleLowPower(to on: Bool) {
        guard model.lowPowerPromptless == false else {
            model.setLowPower(on, installingIfNeeded: false)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Wattson needs permission to change Low Power Mode"
        alert.informativeText = """
        macOS only lets root change this setting, and there is no API for it — \
        pmset is the only way in.

        Wattson can install a rule granting your account permission to run that \
        one command, with those exact arguments, without a password. It grants \
        nothing else, and you can remove it in Settings at any time.

        \(model.lowPowerRule)
        """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Set Up…")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        model.setLowPower(on, installingIfNeeded: true)
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
            // Both pinned. Everything else in this row can give a little; the
            // headline figure cannot, and without this it was the thing that
            // got squeezed once the battery block below wanted its full width.
            Text(watts.map { String(format: "%.2f", $0) } ?? "—")
                .font(.system(size: 34, weight: .medium, design: .rounded))
                .monospacedDigit()
                .fixedSize()
            Text("W")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.secondary)
                .fixedSize()

            Spacer(minLength: 8)

            // The charge rides in the space beside the wattage rather than on a
            // row of its own: on battery that space is empty, and a row that is
            // three quarters air is a row not worth its height.
            if let percent = model.power.batteryPercent {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        BatteryGauge(
                            percent: percent, charging: model.isCharging, lowPower: model.isLowPowerOn
                        )
                            // A shape has no baseline of its own, so it would sit
                            // on the wattage's — which puts it a little low
                            // against digits.
                            .alignmentGuide(.firstTextBaseline) { $0[.bottom] - 2 }
                        Text("\(percent)")
                            .font(.system(size: 23, weight: .medium, design: .rounded))
                            .monospacedDigit()
                        Text("%")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(.secondary)
                        if let state = batteryStateText {
                            Text(state)
                                .font(.system(size: 10))
                                .monospacedDigit()
                                .foregroundStyle(.tertiary)
                                .lineLimit(1)
                                // Plugged in, this shares the row with the volts
                                // and amps; it gives way rather than pushing
                                // them off.
                                .minimumScaleFactor(0.75)
                                .layoutPriority(-1)
                        }
                    }
                    // The half of this corner the wattage's height already paid
                    // for and nothing was using. Both facts are about the cell
                    // the gauge above them draws, so this is where they belong —
                    // a battery section of their own put a second thing called
                    // "Battery" a few points from the bar's own legend entry.
                    if let note = model.batteryNote {
                        Text(note)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            // A floor, not a target. Only the crowded case —
                            // flow, estimate and temperature all at once — ever
                            // reaches it.
                            .minimumScaleFactor(0.8)
                    }
                }
                // The whole point of the priority: a Text carrying a
                // minimumScaleFactor reports a minimum width far below its
                // ideal, which makes it the cheapest thing in the row to
                // squeeze — so the Spacer kept its 50-odd points of nothing
                // while the note rendered at eight and a half. Claiming the
                // width first puts that back the right way round.
                .layoutPriority(1)
            }

            if let volts = model.power.inputVolts, let amps = model.power.inputAmps,
               model.power.externalConnected {
                VStack(alignment: .trailing, spacing: 1) {
                    Text(String(format: "%.2f V", volts))
                    Text(String(format: "%.3f A", amps))
                }
                .font(.system(size: 11, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.secondary)
                .fixedSize()
                .padding(.leading, 6)
            }
        }
    }

    /// "charging", "draining", "holding". The flow that used to be appended to
    /// this now lives on the line below, where there is room for it — see
    /// `DeviceModel.batteryNote`.
    private var batteryStateText: String? { model.power.batteryState }

    // MARK: - Body

    /// How tall the scrolling region may grow before it starts scrolling.
    /// The old fixed 360 pt cut the device list off on every machine.
    private var maxBodyHeight: CGFloat {
        let visible = NSScreen.main?.visibleFrame.height ?? 800
        return max(160, min(560, visible - 380))
    }

    private var overflows: Bool { ui.bodyHeight > maxBodyHeight + 1 }

    /// Only once the tree is big enough to need it. A permanent search box over
    /// a four-row list is an admission that the list is too long, on a panel
    /// where it usually is not.
    private var showsSearch: Bool {
        model.showDevices && (model.result.deviceCount > 8 || !ui.query.isEmpty)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.tertiary)
            TextField("Search devices", text: $ui.query)
                .textFieldStyle(.plain)
                .font(.system(size: 11))
            if !ui.query.isEmpty {
                Button { ui.query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(.quaternary.opacity(0.45)))
        .padding(.horizontal, 14)
        .padding(.bottom, 8)
    }

    /// What every device row needs from the model, gathered once.
    private var rowContext: DeviceRowContext {
        DeviceRowContext(
            showVendors: model.showVendors,
            history: { model.log.history(for: $0) },
            volumes: { model.volumes(for: $0) },
            isEjecting: { model.ejecting.contains($0.id) },
            ejectError: { model.ejectErrors[$0.id] },
            reveal: { model.reveal($0) },
            eject: { model.eject($0) }
        )
    }

    private var scrollingBody: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                if model.showDevices {
                    let connections = model.connections(matching: ui.query)
                    if connections.isEmpty {
                        Text(ui.query.isEmpty ? "Nothing connected" : "No device matches “\(ui.query)”")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(connections) { connection in
                        ConnectionCard(
                            connection: connection,
                            showCable: model.showCable,
                            context: rowContext,
                            isExpanded: ui.expanded.contains(connection.id),
                            toggle: { toggle(connection.id) },
                            expandedDevices: ui.expandedDevices,
                            toggleDevice: { id in
                                if ui.expandedDevices.contains(id) {
                                    ui.expandedDevices.remove(id)
                                } else {
                                    ui.expandedDevices.insert(id)
                                }
                            }
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
        .frame(height: min(max(ui.bodyHeight, 24), maxBodyHeight))
        // Fade the last few points so "there is more below" is visible before
        // you happen to scroll; overlay scrollers show nothing at rest.
        .mask(overflows ? AnyView(bottomFade) : AnyView(Color.black))
        .onPreferenceChange(BodyHeightKey.self) { ui.bodyHeight = $0 }
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
        if ui.expanded.contains(id) {
            ui.expanded.remove(id)
        } else {
            ui.expanded.insert(id)
        }
    }

    // MARK: - Footer

    /// Just the two things that are not settings. Menu-bar display and launch
    /// at login used to live here as well as in Settings, which meant two
    /// places to change one thing.
    private var footer: some View {
        VStack(alignment: .leading, spacing: 2) {
            if model.showDebugOptions {
                MenuButton(title: "Capture Raw Hardware Data…", action: onOpenDiagnostics)
            }
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
/// How much of its ceiling the cluster is reaching, as a bar.
///
/// Drawn to the same proportions as the allocation bar above it so the two read
/// as the same kind of thing, and filled from the same quaternary tail — what is
/// empty here is the headroom the machine is not using, whether or not it could.
private struct SpeedBar: View {
    let fraction: Double
    /// Something is holding the cores down, and the bar says so in the same
    /// colour the figure beside it uses.
    let held: Bool

    var body: some View {
        GeometryReader { geometry in
            HStack(spacing: 0) {
                Rectangle()
                    .fill(held ? AnyShapeStyle(.orange) : AnyShapeStyle(.tint))
                    .frame(width: max(0, geometry.size.width * min(max(fraction, 0), 1)))
                Rectangle().fill(.quaternary)
            }
            .clipShape(Capsule())
        }
        // The clock and its ceiling are spelled out in the row below this.
        .accessibilityHidden(true)
        .frame(height: 5)
    }
}

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
        // Every segment is named and totalled in the legend underneath.
        .accessibilityHidden(true)
        .frame(height: 7)
    }

    private func width(of segment: PowerAllocation.Segment, in total: CGFloat) -> CGFloat {
        max(0, total * segment.watts / allocation.capacity)
    }
}

private struct AllocationLegend: View {
    let allocation: PowerAllocation
    /// What the charger still has spare. It belongs on the key rather than on a
    /// row of its own: it is a fact about this bar, and it is what fills the
    /// empty tail the bar already draws.
    let headroom: Double?

    /// Three segments, their wattages and a headroom figure do not fit across
    /// 352 points at this size, and what gave way was the word "Accessories" —
    /// truncated to "Access…", which is the one label a reader cannot infer
    /// from the colour of its dot. Headroom drops to a line of its own instead:
    /// it is the least urgent thing here and it is already drawn, as the empty
    /// tail of the bar above.
    private var headroomNeedsItsOwnLine: Bool { allocation.segments.count > 2 }

    var body: some View {
        VStack(alignment: .trailing, spacing: 1) {
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
                Spacer(minLength: 4)
                if let headroom, !headroomNeedsItsOwnLine {
                    headroomText(headroom)
                }
            }
            if let headroom, headroomNeedsItsOwnLine {
                headroomText(headroom)
            }
        }
        .font(.system(size: 10))
        .lineLimit(1)
        .minimumScaleFactor(0.75)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func headroomText(_ headroom: Double) -> some View {
        Text(String(format: "%.0f W headroom", headroom))
            .monospacedDigit()
            .foregroundStyle(.tertiary)
    }
}

/// Wattage over the recent past, so spikes and charge ramps are visible.
private struct Sparkline: View {
    let samples: [PowerSample]

    private var peak: Double { max(samples.map(\.watts).max() ?? 1, 0.5) }

    /// Zero-based, so the height still means something absolute, but with
    /// headroom above the peak — a steady load pinned to the ceiling filled the
    /// whole box and read as a solid rectangle rather than a graph.
    ///
    /// 1.2 was not enough of it. A machine holding a constant draw is the
    /// ordinary case, and at 1.2 its line sat at 83% of the box with a
    /// saturated fill under all of it: the panel's largest element, carrying
    /// the least information in it. The fill is lighter now for the same
    /// reason — the line is the figure, and the wash under it is shading.
    private var ceiling: Double { peak * 1.45 }

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
                                colors: [.accentColor.opacity(0.16), .accentColor.opacity(0)],
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
            // The span and the peak are Text directly above, and a trace of a
            // hundred and fifty samples has no reading a screen reader could
            // use that those two do not already give.
            .accessibilityHidden(true)
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
    let context: DeviceRowContext
    let isExpanded: Bool
    let toggle: () -> Void
    var expandedDevices: Set<String> = []
    var toggleDevice: (String) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { headerRow }
                .buttonStyle(.plain)

            // On the card itself rather than behind the chevron, and rather
            // than only in a notice. macOS shows its own alert the moment the
            // circuit fires and nothing ever again, so a port that has quietly
            // stopped charging has to leave something behind that can be gone
            // and looked at — which a toast three seconds long is not.
            if let liquid = connection.port?.liquid?.summary {
                WarningRow(
                    symbol: "drop.triangle.fill",
                    text: liquid,
                    detail: "Disconnect the cable and let the port dry."
                )
                .padding(.top, 6)
            }

            if !connection.extraDevices.isEmpty {
                // No spacing between rows: the tree guides are drawn per row
                // and have to meet to read as continuous lines.
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(connection.extraDevices) { entry in
                        DeviceLine(
                            entry: entry,
                            context: context,
                            isExpanded: expandedDevices.contains(entry.node.id),
                            toggle: { toggleDevice(entry.node.id) }
                        )
                    }
                }
                .padding(.top, 6)
            }

            if isExpanded, !detailRows.isEmpty || !connection.profiles.isEmpty || !cableNotes.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Divider().opacity(0.5).padding(.bottom, 2)
                    ForEach(Array(detailRows.enumerated()), id: \.offset) { _, row in
                        DetailRow(label: row.label, value: row.value)
                    }
                    if !cableNotes.isEmpty { CableNotesRow(notes: cableNotes) }
                    if !connection.profiles.isEmpty {
                        ProfileRow(
                            profiles: connection.profiles,
                            negotiated: connection.negotiatedProfile
                        )
                    }
                    // A drive plugged straight into a port names its own card
                    // and has no tree row, so this is the only place its
                    // volumes and its history can appear. With several devices
                    // on the port they each have a tree row of their own, and
                    // repeating them here would say everything twice.
                    if connection.devices.count == 1, let device = connection.devices.first {
                        DeviceAttachments(node: device, context: context)
                    }
                }
                .padding(.top, 7)
                // As the device inspector already is. A charger's serial and
                // firmware were the two things on this panel nobody could copy,
                // and they are the two most likely to be typed into a search box.
                .textSelection(.enabled)
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
                // The mark leads the name because it is part of the name: this
                // is an Apple 61W USB-C Power Adapter, not a 61W USB-C Power
                // Adapter that happens to be Apple.
                HStack(spacing: 4) {
                    if connection.isApple {
                        Image(systemName: "apple.logo")
                            .font(.system(size: 10))
                            .baselineOffset(-1)
                    }
                    Text(connection.title)
                        .font(.system(size: 13, weight: .semibold))
                        .lineLimit(1)
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

    /// Facts about the cable's chip that are sentences rather than values, so
    /// they cannot share the label column with the rest.
    private var cableNotes: [String] {
        guard showCable, let port = connection.port else { return [] }
        return port.cableNotes
    }

    private var detailRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []

        if let port = connection.port {
            if let negotiated = port.negotiated {
                let figures = String(format: "%.0f V / %.2f A (%.0f W)",
                                     negotiated.volts, negotiated.amps, negotiated.watts)
                // Calling a Type-C current advertisement a "contract" would be
                // the app agreeing that a handshake happened when none did.
                rows.append(port.hasPDContract
                    ? ("Contract", figures)
                    : ("No contract", figures + " — Type-C current only, no PD handshake"))
            }
            if port.isSourcing, let volts = port.outputVolts, let amps = port.outputAmps {
                rows.append(("Measured", String(format: "%.2f V / %.3f A", volts, amps)))
            }
            if showCable, port.describesCable {
                // With no data link the card's own subtitle already says so.
                if port.carriesData {
                    rows.append(("Link now", port.activeSummary))
                }
                // What the link actually settled on, as against what the port
                // is capable of. Already gated on an active CIO transport,
                // because an idle port on this Mac reports a perfectly
                // plausible 10 Gbps link with nothing attached at all.
                if let achieved = port.thunderboltAchieved {
                    rows.append(("Thunderbolt", achieved))
                }
                // "Cable max" claimed a ceiling that is only knowable when the
                // cable's own chip is readable. Otherwise this is a floor: the
                // fastest thing seen so far, which may be the device's limit.
                rows.append((port.emarker?.usbSpeed != nil ? "Rated" : "Fastest seen",
                             port.cableCapability))
                rows.append(("Cable", port.cableWiringSummary))
                rows.append(("Current", port.currentRating))
                // The far end's own account of itself, read at the SOP address.
                // A dock or a charger answers here whether or not it enumerates
                // as a USB device, and for some of them it is the only identity
                // published anywhere the Mac can reach.
                if let partner = port.partner, partner.identifiesItself {
                    let described = [partner.vendorName, partner.productTypeDescription]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !described.isEmpty { rows.append(("Far end", described)) }
                }
            }

            // How the two high-speed lanes are actually assigned — the answer
            // to a dock's ethernet crawling while a monitor is plugged in.
            // Gated on the port being occupied: an idle port's lanes are parked
            // rather than contended, and AppleTypeCPhy goes on reporting the
            // last assignment it made.
            if port.describesCable, port.isConnected, let phy = port.phy {
                if let lanes = phy.laneSummary {
                    rows.append(("Lanes", lanes))
                }
                if let display = phy.displaySummary {
                    rows.append(("Display link", display))
                }
            }
            // One way only. `displayCompression` is nil for every mode that
            // appears to fit, because the figure it is compared against is a
            // floor — exceeding it proves a mode cannot be carried
            // uncompressed, and coming in under it proves nothing at all.
            if let compression = port.displayCompression {
                rows.append(("Compressed", compression))
            }
            // Why a device can enumerate and then do nothing: macOS declined
            // it. Nothing else in the panel can account for that.
            if port.isRestricted {
                rows.append(("Blocked", [port.restrictionState, port.restrictionProfile]
                    .compactMap { $0 }.joined(separator: " · ")))
            } else if let authorization = port.authorization, authorization != "Not Required" {
                rows.append(("Accessory", authorization))
            }
            // A separate axis from the row above: authentication is the
            // accessory proving what it is, authorisation is the policy
            // deciding whether to let it in. "Idle" is what everything that
            // never starts one reports, and says nothing worth a row.
            if let authentication = port.authentication, authentication != "Idle" {
                rows.append(("Authentication", authentication))
            }
            if port.isTunnelled {
                rows.append(("Tunnelled", "Carried inside USB4"))
            }
            // Host is what a Mac always is; the other way round is the news.
            if let role = port.dataRole, role != "Host" {
                rows.append(("Data role", role))
            }
            // Two readings taken from different places for different reasons,
            // disagreeing. Stated as a disagreement rather than resolved into
            // an answer, because there is no third opinion to break the tie.
            if port.occupancyDisagreement {
                rows.append(("Occupancy", port.ccActive == true
                    ? "The CC line says something is in the socket; the controller says nothing is"
                    : "The controller says something is in the socket; the CC line says nothing is"))
            }
            if let count = port.connectionCount {
                rows.append(("Port use", count == 1
                    ? "1 connection since new"
                    : "\(count) connections since new"))
            }
        }

        rows.append(contentsOf: connection.adapterRows)

        for device in connection.devices {
            rows.append(contentsOf: device.detailRows(includeVendor: context.showVendors))
        }
        return rows
    }
}

/// What a device row needs from the model, so the tree does not have to carry
/// the whole thing around.
struct DeviceRowContext {
    var showVendors = true
    var history: (DeviceNode) -> [ConnectionEvent] = { _ in [] }
    var volumes: (DeviceNode) -> [VolumeInfo] = { _ in [] }
    var isEjecting: (VolumeInfo) -> Bool = { _ in false }
    var ejectError: (VolumeInfo) -> String? = { _ in nil }
    var reveal: (VolumeInfo) -> Void = { _ in }
    var eject: (VolumeInfo) -> Void = { _ in }
}

/// A device hanging below whatever names the card — a hub's downstream ports.
///
/// Expands in place rather than into a window of its own: the panel is a
/// transient popover that closes on click-outside, so a second window would
/// fight the interaction model the whole way.
private struct DeviceLine: View {
    let entry: FlatDevice
    let context: DeviceRowContext
    let isExpanded: Bool
    let toggle: () -> Void

    @State private var isHovering = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button(action: toggle) { row }
                .buttonStyle(.plain)

            if isExpanded {
                // The guides continue down the side of the open inspector: they
                // are drawn per row, and a gap here would break the lines just
                // where the tree is deepest.
                HStack(alignment: .top, spacing: 0) {
                    guides
                    DeviceInspector(node: entry.node, context: context)
                        .padding(.leading, 19)
                }
                .padding(.top, 5)
                .padding(.bottom, 6)
            }
        }
        .onHover { isHovering = $0 }
    }

    /// One thin rule per level of nesting. Indentation alone stopped being
    /// legible three levels into a hub-behind-a-hub.
    private var guides: some View {
        ForEach(0..<entry.depth, id: \.self) { _ in
            Rectangle()
                .fill(.quaternary)
                .frame(width: 1)
                .padding(.leading, 4)
                .padding(.trailing, 8)
        }
    }

    private var row: some View {
        HStack(alignment: .top, spacing: 0) {
            guides

            // Legibility here is a function of ink, not area: 9 pt at .regular
            // and .tertiary left the hairline glyphs as smudges. Filled, heavier
            // and one contrast step up, in the same 19 pt column as before — the
            // hierarchy against the name is carried by colour, not size.
            Image(systemName: entry.node.symbolName)
                .font(.system(size: 11, weight: .medium))
                .symbolVariant(.fill)
                .foregroundStyle(.secondary)
                .frame(width: 14)
                .padding(.top, 1)
                .padding(.trailing, 5)

            // Name on its own line, everything else beneath it. One line for
            // all of it meant the vendor was always the part that got cut.
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 6) {
                    Text(entry.node.name)
                        .font(.system(size: 11))
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    if let watts = entry.node.measuredWatts ?? entry.node.watts {
                        Text(String(format: "%.1f W", watts))
                            .font(.system(size: 10))
                            .monospacedDigit()
                            // Solid when the rail was actually measured, faded
                            // when it is only the budget the port granted.
                            .foregroundStyle(entry.node.measuredWatts != nil
                                ? AnyShapeStyle(.secondary)
                                : AnyShapeStyle(.tertiary))
                    } else if let budget = entry.node.hubBudgetShort {
                        // A hub draws nothing of its own; what it has to hand
                        // out is the number worth putting in the empty slot.
                        Text(budget)
                            .font(.system(size: 10))
                            .monospacedDigit()
                            .foregroundStyle(.tertiary)
                    }
                }
                if let meta {
                    Text(meta)
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }

            // Reserved width, drawn only on hover or while open: a chevron on
            // every row at rest is noise on a list that is mostly just read.
            Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                .font(.system(size: 8, weight: .semibold))
                .foregroundStyle(.tertiary)
                .opacity(isExpanded || isHovering ? 1 : 0)
                .frame(width: 9)
                .padding(.leading, 4)
                .padding(.top, 3)
        }
        .padding(.vertical, 3)
        .contentShape(Rectangle())
        .help(entry.node.detailLines(includeVendor: context.showVendors).joined(separator: "\n"))
    }

    private var meta: String? {
        [entry.node.typeLabel, entry.node.linkSummary, context.showVendors ? entry.node.vendor : nil]
            .compactMap { $0 }
            .joined(separator: " · ")
            .nilIfEmpty
    }
}

/// A device's expanded detail, ordered so the power answer comes first —
/// that is what this app is for.
private struct DeviceInspector: View {
    let node: DeviceNode
    let context: DeviceRowContext

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Divider().opacity(0.5)
            ForEach(node.inspectorSections()) { section in
                InspectorBlock(title: section.title) {
                    ForEach(Array(section.rows.enumerated()), id: \.offset) { _, row in
                        DetailRow(label: row.label, value: row.value)
                    }
                }
            }
            DeviceAttachments(node: node, context: context)
        }
        // A serial nobody can copy is a serial nobody can look up.
        .textSelection(.enabled)
    }
}

/// Volumes and history: the two parts of a device's detail that are lists
/// rather than label/value pairs, and that a card header needs as much as a
/// tree row does.
private struct DeviceAttachments: View {
    let node: DeviceNode
    let context: DeviceRowContext

    var body: some View {
        let volumes = context.volumes(node)
        VStack(alignment: .leading, spacing: 7) {
            if !volumes.isEmpty {
                InspectorBlock(title: "Volumes") {
                    ForEach(volumes) { volume in
                        VolumeRow(volume: volume, context: context)
                    }
                }
            }
            InspectorBlock(title: "History") {
                HistoryList(node: node, events: context.history(node))
            }
        }
    }
}

private struct InspectorBlock<Content: View>: View {
    let title: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            content()
        }
    }
}

/// A mounted volume, with the two things anyone opens a USB list to do.
private struct VolumeRow: View {
    let volume: VolumeInfo
    let context: DeviceRowContext

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 4) {
                Text(volume.name)
                    .font(.system(size: 11))
                    .lineLimit(1)
                Spacer(minLength: 4)
                if context.isEjecting(volume) {
                    ProgressView()
                        .controlSize(.small)
                        .scaleEffect(0.6)
                        .frame(width: 20, height: 16)
                } else {
                    IconButton(symbol: "folder", help: "Show in Finder") { context.reveal(volume) }
                    IconButton(symbol: "eject.fill", help: "Eject") { context.eject(volume) }
                }
            }
            if let summary = volume.capacitySummary {
                Text(summary)
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(.tertiary)
            }
            if let fraction = volume.usedFraction {
                CapacityBar(fraction: fraction)
            }
            // Unmount fails routinely because something still holds a file
            // open. A button that silently does nothing is worse than none.
            if let error = context.ejectError(volume) {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// Deliberately monochrome. The panel's one coloured bar means power, and a
/// second bar in the accent colours would be read as part of the same story.
private struct CapacityBar: View {
    let fraction: Double

    var body: some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(.quaternary)
                Capsule()
                    .fill(.secondary)
                    .frame(width: max(1, geometry.size.width * fraction))
            }
        }
        // `capacitySummary` states the same thing in words directly above.
        .accessibilityHidden(true)
        .frame(height: 3)
    }
}

/// When this device came and went, for as long as anyone was watching.
private struct HistoryList: View {
    let node: DeviceNode
    let events: [ConnectionEvent]

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            if events.isEmpty {
                Text("Already attached when Wattson started")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ForEach(Array(events.prefix(6))) { event in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(event.kind.label)
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                            .frame(width: 74, alignment: .leading)
                        Text(event.timeLabel)
                            .font(.system(size: 11))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Spacer(minLength: 0)
                    }
                }
            }
            Text(caveat)
                .font(.system(size: 9))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 1)
        }
    }

    /// Whichever of the two things this list cannot let somebody assume: that
    /// it is complete, or that it is about this device rather than this port.
    private var caveat: String {
        node.hasStableIdentity
            ? "Recorded only while Wattson was running."
            : "No serial reported, so this history follows the port, not the device."
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

/// What the cable's chip said, where it is not a label/value pair.
///
/// Several short sentences, each of which stands alone, under one label rather
/// than repeating a label per line. Deliberately not totalled into a rating:
/// every note here is something the hardware stated outright or something two
/// readings disagreed about, and none of them is a verdict on whether the cable
/// is any good — whatcable built that score, ran it against a real corpus and
/// found it firing on Apple's own cables.
private struct CableNotesRow: View {
    let notes: [String]

    var body: some View {
        DetailRow(label: "Cable notes", value: nil) {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(notes, id: \.self) { note in
                    Text(note)
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

// MARK: - Shared pieces

/// Something wrong with the hardware, said where it cannot be missed.
///
/// Not folded into the detail rows: those are behind a chevron, and a fault
/// nobody expands the card to find is a fault nobody sees.
private struct WarningRow: View {
    let symbol: String
    let text: String
    var detail: String?

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.orange)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 1) {
                Text(text)
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                if let detail {
                    Text(detail)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(.orange.opacity(0.12)))
    }
}

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
                // The column is fixed so the values line up, and a label that
                // does not fit it used to wrap onto a second line — which put
                // the value beside the wrong half of its own label. Shrinking
                // is the lesser of the two: it costs a point of size on the
                // longest labels only, and nothing on any of the short ones.
                .lineLimit(1)
                .minimumScaleFactor(0.8)
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
        // `.help` fills in accessibilityHelp, not the label — so these read out
        // as unnamed buttons, or as whatever SF Symbol name happens to be in
        // the image. The tooltip is already the right words; use them.
        .accessibilityLabel(help)
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
