import AppKit
import UserNotifications

/// What a notice is about, so it can be switched off by kind rather than all
/// at once. Somebody who wants to know when a drive appears does not
/// necessarily want to hear about every keyboard.
enum NoticeCategory: String, CaseIterable {
    case power
    case storage
    case device
}

/// One thing worth telling somebody about.
///
/// `id` is the notice's identity, not a fresh value per post: posting the same
/// id again updates what is already on screen instead of stacking a second
/// notice on top of it. That is what lets a notice go up the instant a drive is
/// plugged in and fill in its size a moment later, when the volume mounts —
/// rather than either making the user wait or telling them twice.
struct Notice: Equatable {
    let id: String
    let category: NoticeCategory
    var symbol: String
    var title: String
    var detail: String?
    /// Still waiting on the part that makes it worth reading.
    var isPending = false
}

/// Which surfaces a notice goes to. Both can be on at once.
struct NoticeDelivery: Equatable {
    var panel = true
    var notificationCenter = false
}

/// Sends notices to the panel by the menu bar, to Notification Center, or both.
///
/// The panel is the surface that always works: Wattson is ad-hoc signed and
/// Notification Center wants authorisation, which the user has to grant and can
/// revoke in System Settings without telling the app. So the panel stays the
/// default, and Notification Center is the opt-in that buys you a history.
@MainActor
final class NoticeCenter {
    var delivery = NoticeDelivery()

    private let toasts = ToastPresenter()
    /// Nil until asked for. Requested when the switch is turned on, not at
    /// launch: an app that asks on first run before it has anything to say is
    /// an app people say no to.
    private(set) var centerAuthorized = false

    /// A bare binary has no bundle identity, and `UNUserNotificationCenter`
    /// raises rather than returning nil for one. `--dump` must not trip on it.
    private var canUseNotificationCenter: Bool { Bundle.main.bundleIdentifier != nil }

    func post(_ notice: Notice) {
        if delivery.panel { toasts.show(notice) }
        guard delivery.notificationCenter, centerAuthorized, canUseNotificationCenter else { return }
        let content = UNMutableNotificationContent()
        content.title = notice.title
        content.body = notice.detail ?? ""
        // Passive: this is a status app reporting a change, never an
        // interruption worth breaking a Focus for.
        content.interruptionLevel = .passive
        // Same identifier as a delivered notice replaces it in place, which is
        // how a pending notice becomes a finished one without a second banner.
        let request = UNNotificationRequest(identifier: notice.id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    /// Called when the Notification Center switch is turned on. Answers whether
    /// notices will actually arrive, so Settings can put the switch back if the
    /// user says no here or has said no before.
    func authorizeNotificationCenter(_ completion: @escaping (Bool) -> Void) {
        guard canUseNotificationCenter else { return completion(false) }
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert]) { granted, _ in
            Task { @MainActor in
                self.centerAuthorized = granted
                completion(granted)
            }
        }
    }

    /// Whether authorisation is still in place, which the user can withdraw in
    /// System Settings at any time without the app hearing about it.
    func refreshAuthorization() {
        guard canUseNotificationCenter else { return }
        UNUserNotificationCenter.current().getNotificationSettings { settings in
            Task { @MainActor in
                self.centerAuthorized = settings.authorizationStatus == .authorized
            }
        }
    }
}

// MARK: - Building notices

/// Turns what changed into the fewest words that stay true.
enum NoticeBuilder {

    // MARK: Devices

    /// A batch of arrivals and departures as one notice.
    ///
    /// Attaching a seven-port hub fires an event per downstream device, so the
    /// interesting case is not "one device" — it is "a hub and everything
    /// behind it", which has to read as a single event.
    static func devices(
        arrived: [DeviceNode],
        left: [DeviceNode],
        id: String,
        volumes: (DeviceNode) -> [VolumeInfo]
    ) -> Notice? {
        if !arrived.isEmpty {
            var notice = summarise(arrived, verb: "attached", id: id, volumes: volumes)
            if !left.isEmpty {
                let removals = left.count == 1
                    ? "\(left[0].name) removed"
                    : "\(left.count) devices removed"
                notice.detail = [notice.detail, removals].compactMap { $0 }.joined(separator: " · ")
            }
            return notice
        }
        guard !left.isEmpty else { return nil }
        return summarise(left, verb: "removed", id: id, volumes: volumes)
    }

    private static func summarise(
        _ nodes: [DeviceNode],
        verb: String,
        id: String,
        volumes: (DeviceNode) -> [VolumeInfo]
    ) -> Notice {
        if nodes.count == 1, let node = nodes.first {
            return single(node, verb: verb, id: id, volumes: volumes)
        }
        // A hub in the batch names the whole batch: it is the thing that was
        // physically plugged in, and the rest came with it.
        if let hub = nodes.first(where: { $0.typeLabel == "Hub" }) {
            let others = nodes.count - 1
            return Notice(
                id: id,
                category: .device,
                symbol: hub.symbolName,
                title: "\(hub.name) \(verb)",
                detail: others == 1 ? "1 device" : "\(others) devices"
            )
        }
        return Notice(
            id: id,
            category: .device,
            symbol: "cable.connector",
            title: "\(nodes.count) devices \(verb)",
            detail: nodes.prefix(3).map(\.name).joined(separator: ", ")
                + (nodes.count > 3 ? "…" : "")
        )
    }

    /// One device, with whatever is known about it that is worth knowing.
    ///
    /// A drive gets its capacity as well as its speed — but the volume mounts a
    /// beat after the device appears on the bus, and for a locked or unformatted
    /// disk it never mounts at all. So the notice goes up straight away saying
    /// what it is still waiting for, and is updated in place when the volume
    /// arrives. Nobody has to wait, and nothing is announced twice.
    private static func single(
        _ node: DeviceNode,
        verb: String,
        id: String,
        volumes: (DeviceNode) -> [VolumeInfo]
    ) -> Notice {
        let mounted = volumes(node)
        let capacity = mounted.compactMap(\.capacitySummary).first
        let waiting = node.isStorage && verb == "attached" && capacity == nil

        // What the thing is comes first for anything that is not a drive — a
        // keyboard's notice is more use reading "Keyboard · 480 Mbps" than
        // quoting its bus allocation at somebody. For a drive, its size is the
        // headline and the label is redundant with the name and the icon.
        let parts: [String?] = node.isStorage
            ? [capacity, node.linkSummary, capacity == nil ? node.vendor : nil]
            : [node.typeLabel, node.linkSummary, node.powerSummary]
        return Notice(
            id: id,
            category: node.isStorage ? .storage : .device,
            symbol: node.symbolName,
            title: "\(node.name) \(verb)",
            detail: (parts.compactMap { $0 } + (waiting ? ["reading volume…"] : []))
                .joined(separator: " · ").nilIfEmpty,
            isPending: waiting
        )
    }

    // MARK: Power

    static let adapterNoticeID = "power.adapter"
    static let drainNoticeID = "power.drain"
    static let contractNoticeID = "power.contract"

    /// A charger going on. Posted the moment it is plugged in, while the PD
    /// contract is still being agreed, then updated once it is.
    static func adapterAttached(_ power: PowerSnapshot, settled: Bool) -> Notice {
        let rating = power.adapterWatts.map { String(format: "%.0f W", $0) }
        // Before the contract lands there is no rating and no name, and the
        // notice still has to read like a sentence.
        let name = power.adapterModelName
            ?? rating.map { "\($0) charger" }
            ?? "Charger"
        var parts: [String] = []
        if let contract = power.negotiatedContract { parts.append(contract) }
        if let watts = power.inputWatts, watts > 0.05 {
            parts.append(String(format: "drawing %.1f W", watts))
        }
        if let port = power.sourcePortName { parts.append(port) }
        return Notice(
            id: adapterNoticeID,
            category: .power,
            symbol: "powerplug.fill",
            title: "\(name) attached",
            detail: settled
                ? parts.joined(separator: " · ").nilIfEmpty
                : "negotiating…",
            isPending: !settled
        )
    }

    static func adapterRemoved(_ power: PowerSnapshot) -> Notice {
        var parts: [String] = []
        if let percent = power.batteryPercent { parts.append("\(percent)%") }
        if let watts = power.batteryWatts, watts < -0.05 {
            parts.append(String(format: "drawing %.1f W", abs(watts)))
        }
        return Notice(
            id: adapterNoticeID,
            category: .power,
            symbol: "battery.50percent",
            title: "Charger removed",
            detail: (["on battery"] + parts).joined(separator: " · ")
        )
    }

    /// The charger changing rails under the same cable — 9 V to 20 V and back.
    static func contractChanged(fromVolts: Double, toVolts: Double, amps: Double?, watts: Double?) -> Notice {
        var detail = String(format: "%.0f V → %.0f V", fromVolts, toVolts)
        if let amps { detail += String(format: " · %.2f A", amps) }
        if let watts { detail += String(format: " · %.1f W", watts) }
        return Notice(
            id: contractNoticeID,
            category: .power,
            symbol: "arrow.triangle.2.circlepath",
            title: "Charger renegotiated",
            detail: detail
        )
    }

    /// The battery going down while plugged in.
    ///
    /// Measured facts only: what is coming in, what the machine is drawing, and
    /// what the cell is losing to make up the difference. Deliberately says
    /// nothing about what this Mac could take from a bigger charger — a 30 W
    /// brick keeping a machine level is doing its job, and being told otherwise
    /// is how a warning becomes noise.
    static func drainingOnCharger(_ power: PowerSnapshot) -> Notice {
        var parts: [String] = []
        if let load = power.systemLoadWatts, let input = power.inputWatts {
            parts.append(String(format: "%.1f W needed, %.1f W coming in", load, input))
        }
        if let battery = power.batteryWatts {
            parts.append(String(format: "battery %+.1f W", battery))
        }
        if let percent = power.batteryPercent { parts.append("\(percent)%") }
        return Notice(
            id: drainNoticeID,
            category: .power,
            symbol: "exclamationmark.triangle.fill",
            title: "Battery draining on the charger",
            detail: parts.joined(separator: " · ").nilIfEmpty
        )
    }
}

extension PowerSnapshot {
    /// "20.0 V / 4.80 A", the contract as agreed.
    var negotiatedContract: String? {
        guard let volts = inputVolts, volts > 1, let amps = inputAmps, amps > 0 else { return nil }
        return String(format: "%.1f V / %.2f A", volts, amps)
    }
}

extension DeviceNode {
    /// Things that hold files, as opposed to things that merely plug in.
    var isStorage: Bool { typeLabel == "Storage" || typeLabel == "Card Reader" }

    /// "2.5 W from the bus", when the bus said so.
    var powerSummary: String? {
        guard let watts, watts > 0.05 else { return nil }
        return String(format: "%.1f W", watts)
    }
}
