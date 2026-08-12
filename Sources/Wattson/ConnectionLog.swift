import Foundation

/// One attach or detach, as it happened.
struct ConnectionEvent: Codable, Identifiable, Hashable {
    enum Kind: String, Codable {
        case connected
        case disconnected

        var label: String {
            switch self {
            case .connected: return "Connected"
            case .disconnected: return "Disconnected"
            }
        }
    }

    /// The device's `persistentKey`. For anything without a serial that is a
    /// port id, so the entry is only as true as that device's identity — which
    /// is why the inspector says which of the two it got.
    let device: String
    /// Kept alongside the key so an entry still reads as something after the
    /// device is gone and there is no node left to look a name up on.
    let name: String
    let kind: Kind
    let at: Date

    var id: String { "\(device)|\(kind.rawValue)|\(at.timeIntervalSince1970)" }

    /// Time alone for today, full date beyond it — the year is noise on
    /// something that happened four minutes ago.
    var timeLabel: String {
        Calendar.current.isDateInToday(at)
            ? Self.todayFormat.string(from: at)
            : Self.olderFormat.string(from: at)
    }

    private static let todayFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    private static let olderFormat: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "dd.MM.yyyy, HH:mm"
        return formatter
    }()
}

/// What was plugged in and when, for as long as Wattson was watching.
///
/// This is a menu bar app, not a database: the buffer is capped in both
/// directions and lives in UserDefaults as a single JSON blob.
@MainActor
final class ConnectionLog: ObservableObject {
    @Published private(set) var events: [ConnectionEvent] = []

    /// When this run started watching. Anything already attached at that moment
    /// has no "Connected" entry and never will get one, so the UI says so
    /// rather than showing a device a history with its first line missing.
    let watchingSince = Date()

    private static let key = "connectionLog"
    private static let totalLimit = 200
    private static let perDeviceLimit = 10

    init() {
        guard let data = UserDefaults.standard.data(forKey: Self.key),
              let stored = try? JSONDecoder().decode([ConnectionEvent].self, from: data)
        else { return }
        events = stored
    }

    /// Oldest first, which is the order they are recorded in.
    func append(_ newEvents: [ConnectionEvent]) {
        guard !newEvents.isEmpty else { return }
        events.append(contentsOf: newEvents.sorted { $0.at < $1.at })
        trim()
        save()
    }

    /// Newest first: an inspector reads downwards from what just happened.
    func history(for node: DeviceNode) -> [ConnectionEvent] {
        Array(events.filter { $0.device == node.persistentKey }.reversed())
    }

    func clear() {
        events = []
        UserDefaults.standard.removeObject(forKey: Self.key)
    }

    /// Per-device first, then overall — one device replugged forty times must
    /// not push every other device out of the log.
    private func trim() {
        var perDevice: [String: Int] = [:]
        var kept: [ConnectionEvent] = []
        for event in events.reversed() {
            let count = perDevice[event.device, default: 0]
            guard count < Self.perDeviceLimit else { continue }
            perDevice[event.device] = count + 1
            kept.append(event)
            if kept.count == Self.totalLimit { break }
        }
        events = Array(kept.reversed())
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(events) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
