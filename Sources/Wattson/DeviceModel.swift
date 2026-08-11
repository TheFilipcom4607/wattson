import Foundation
import ServiceManagement
import SwiftUI

enum TitleMode: String, CaseIterable, Identifiable {
    case livePower
    case batteryFlow
    case deviceCount
    case fastestLink
    case adapterRating
    case iconOnly

    var id: String { rawValue }

    var label: String {
        switch self {
        case .livePower: return "Live wattage"
        case .batteryFlow: return "Battery flow"
        case .deviceCount: return "Device count"
        case .fastestLink: return "Fastest link"
        case .adapterRating: return "Charger rating"
        case .iconOnly: return "Icon only"
        }
    }
}

@MainActor
final class DeviceModel: ObservableObject {
    @Published private(set) var result = ScanResult()
    @Published private(set) var power = PowerSnapshot()
    @Published private(set) var ports: [PortInfo] = []
    /// Rolling history for the sparkline, oldest first.
    @Published private(set) var history: [PowerSample] = []

    private static let historyLimit = 150
    @Published private(set) var isScanning = false
    @Published private(set) var launchAtLogin = false

    /// Set while the popover is open, so power sampling can speed up.
    @Published var isPresented = false {
        didSet { restartPowerTimer() }
    }

    @Published var titleMode: TitleMode {
        didSet { UserDefaults.standard.set(titleMode.rawValue, forKey: Self.titleModeKey) }
    }

    // Which sections of the panel are shown.
    @Published var showSparkline: Bool { didSet { save(showSparkline, "showSparkline") } }
    @Published var showCable: Bool { didSet { save(showCable, "showCable") } }
    @Published var showPortLimits: Bool { didSet { save(showPortLimits, "showPortLimits") } }
    @Published var showDevices: Bool { didSet { save(showDevices, "showDevices") } }
    @Published var showVendors: Bool { didSet { save(showVendors, "showVendors") } }

    private static let titleModeKey = "titleMode"

    private func save(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Defaults to true when the key has never been written.
    private static func flag(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }
    private var watcher: HotplugWatcher?
    private var powerWatcher: PowerSourceWatcher?
    private var pendingRescan: Task<Void, Never>?
    private var powerTimer: Timer?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.titleModeKey) ?? ""
        titleMode = TitleMode(rawValue: stored) ?? .livePower
        showSparkline = Self.flag("showSparkline")
        showCable = Self.flag("showCable")
        showPortLimits = Self.flag("showPortLimits")
        showDevices = Self.flag("showDevices")
        showVendors = Self.flag("showVendors")

        watcher = HotplugWatcher { [weak self] in
            self?.scheduleRescan()
        }
        watcher?.start()

        // Plug and unplug should register immediately, not on the next tick.
        powerWatcher = PowerSourceWatcher { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        powerWatcher?.start()
        refreshLaunchAtLogin()
        refresh()
        restartPowerTimer()
    }

    var titleText: String? { title(for: titleMode) }

    /// Broken out from `titleText` so Settings can preview every mode live.
    func title(for mode: TitleMode) -> String? {
        switch mode {
        case .iconOnly:
            return nil

        case .livePower:
            // Plugged in: what is coming from the wall. On battery: what is
            // leaving the cell, which reads negative.
            if power.externalConnected, let watts = power.inputWatts {
                return format(watts)
            }
            if let watts = power.batteryWatts {
                return format(watts)
            }
            return "—"

        case .batteryFlow:
            // Always signed: -10.27 W draining, +10.27 W charging. A resting
            // battery would otherwise land on "-0.00 W".
            guard let watts = power.batteryWatts else { return "—" }
            if abs(watts) < 0.005 { return "0.00 W" }
            return String(format: "%+.2f W", watts)

        case .deviceCount:
            let count = result.deviceCount
            return count == 1 ? "1 Device" : "\(count) Devices"

        case .fastestLink:
            guard let mbps = result.fastestMbps, mbps > 0 else { return "—" }
            return SpeedFormat.humanRate(mbps)

        case .adapterRating:
            guard let watts = power.adapterWatts else { return "No Power" }
            return String(format: "%.0f W", watts)
        }
    }

    /// Match the panel exactly: if it reads 2.34 W, so does the menu bar.
    private func format(_ watts: Double) -> String {
        String(format: "%.2f W", watts)
    }

    var symbolName: String {
        switch titleMode {
        case .livePower, .adapterRating:
            return power.externalConnected ? "powerplug.fill" : "battery.100percent"
        case .batteryFlow:
            return (power.batteryWatts ?? 0) > 0.05 ? "battery.100percent.bolt" : "battery.100percent"
        default:
            return "cable.connector"
        }
    }

    // MARK: - Sampling

    func refresh() {
        readPower()
        guard !isScanning else { return }
        isScanning = true
        Task {
            let scan = await Task.detached(priority: .userInitiated) { Scanner.scan() }.value
            self.result = scan
            self.attributeMeasuredPower()
            self.isScanning = false
        }
    }

    /// Cheap: IORegistry reads, so they can run often while the panel is open.
    /// Port state has to be polled — attaching a charger fires no USB event.
    private func readPower() {
        power = PowerMonitor.read()
        ports = PortMonitor.read()

        // Accessory draw is the sum of what the USB-C rails actually deliver,
        // rather than every rail the SMC exposes.
        let accessories = ports
            .filter { $0.kind == .usbC }
            .compactMap(\.outputWatts)
            .reduce(0, +)
        power.accessoryWatts = accessories > 0.05 ? accessories : nil

        // Which port the charger is on, for the charger row.
        let source = ports.first { $0.isConnected && $0.negotiated != nil }
        power.sourcePortName = source?.name

        // Rail voltage from the registry lags 10-30 s, so a charger swap could
        // leave it reading 20 V on a 5 V source and inflate the derived amps.
        // The negotiated contract is current, so trust it when the two disagree.
        if let contract = source?.negotiated?.volts, contract > 1 {
            let stale = power.inputVolts.map { abs($0 - contract) / contract > 0.25 } ?? true
            if stale {
                power.inputVolts = contract
                power.inputAmps = power.inputWatts.map { $0 / contract }
            }
        }

        // Port wattage moves every second, so re-attribute on each sample.
        attributeMeasuredPower()

        // Track whatever the headline shows: input from the wall, or system draw.
        let watts = power.externalConnected
            ? power.inputWatts
            : power.systemLoadWatts
        if let watts {
            history.append(PowerSample(watts: watts, charging: power.externalConnected))
            if history.count > Self.historyLimit {
                history.removeFirst(history.count - Self.historyLimit)
            }
        }
    }

    // MARK: - Attributing measured power to a device

    /// USB controller (locationID high byte) -> AppleHPM port number.
    ///
    /// Seeded with the layout verified on this Mac, then re-learned at runtime
    /// whenever exactly one port is occupied — which makes it self-correcting
    /// on machines with a different topology.
    private var controllerMap: [Int: Int] {
        get { PowerAttribution.storedMap }
        set {
            let stored = Dictionary(uniqueKeysWithValues: newValue.map { (String($0.key), $0.value) })
            UserDefaults.standard.set(stored, forKey: "controllerPortMap")
        }
    }

    /// One occupied port and one active controller means the pairing is certain.
    private func learnControllerMapping() {
        let controllers = Set(result.devices.compactMap(\.controller))
        let occupied = ports.filter {
            $0.kind == .usbC && $0.isConnected && $0.number != nil && $0.outputWatts != nil
        }
        guard controllers.count == 1, occupied.count == 1,
              let controller = controllers.first, let number = occupied.first?.number,
              controllerMap[controller] != number
        else { return }

        var map = controllerMap
        map[controller] = number
        controllerMap = map
    }

    /// A port's measured VBUS belongs to a device only when that device is the
    /// sole thing on the port; behind a hub the rail is shared and unsplittable.
    private func attributeMeasuredPower() {
        learnControllerMapping()
        var devices = result.devices
        PowerAttribution.apply(to: &devices, ports: ports, map: controllerMap)
        result.devices = devices
    }

    // MARK: - Connections

    /// One card per physical connection, charger included.
    ///
    /// Ports and devices are two views of the same cable, so they are joined
    /// here rather than rendered as two lists that repeat each other's numbers.
    var connections: [Connection] {
        var claimed = Set<String>()
        var list: [Connection] = []
        let map = controllerMap

        for port in ports where port.isConnected {
            var attached: [DeviceNode] = []
            if port.kind == .usbC, let number = port.number {
                let controllers = Set(map.filter { $0.value == number }.map(\.key))
                attached = result.devices.filter { node in
                    node.controller.map(controllers.contains) ?? false
                }
                claimed.formUnion(attached.map(\.id))
            }
            list.append(connection(for: port, devices: attached))
        }

        // Thunderbolt has no controller number, and the USB map does not cover
        // every machine, so anything unplaced still gets a card of its own.
        for device in result.devices where !claimed.contains(device.id) {
            list.append(connection(forOrphan: device))
        }

        // Charger first, then things drawing power, then the merely plugged in.
        return list.enumerated()
            .sorted { ($0.element.role.rank, $0.offset) < ($1.element.role.rank, $1.offset) }
            .map(\.element)
    }

    private func connection(for port: PortInfo, devices: [DeviceNode]) -> Connection {
        let isSource = power.externalConnected && power.sourcePortName == port.name
        let role: Connection.Role = isSource ? .source : (port.isSourcing ? .sink : .idle)
        // A single device names its own card; with none or several, the port does.
        let naming = devices.count == 1 ? devices.first : nil

        var connection = Connection(
            id: port.id,
            title: naming?.name ?? port.name,
            subtitle: "",
            symbol: naming?.symbolName ?? (isSource ? "powerplug.fill" : "cable.connector")
        )
        connection.isApple = naming?.isApple ?? (port.kind == .magSafe)
        connection.role = role
        connection.port = port
        connection.devices = devices
        connection.extraDevices = naming.map { $0.children.flatMap { $0.flattenedRows() } }
            ?? devices.flatMap { $0.flattenedRows() }

        if isSource {
            connection.liveWatts = power.inputWatts
            connection.wattsNote = "in"
            connection.profiles = power.profiles
            connection.negotiatedProfile = power.negotiatedProfile
        } else if let watts = port.outputWatts, watts > 0.05 {
            connection.liveWatts = watts
            connection.wattsNote = "out"
        }
        connection.subtitle = subtitle(port: port, naming: naming, role: role)
        connection.detail = detail(port: port, naming: naming, role: role)
        return connection
    }

    private func connection(forOrphan device: DeviceNode) -> Connection {
        var connection = Connection(
            id: "device-\(device.id)",
            title: device.name,
            subtitle: device.kind == .thunderbolt ? "Thunderbolt" : "USB",
            detail: [device.typeLabel, device.linkSummary]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty,
            symbol: device.symbolName
        )
        connection.isApple = device.isApple
        connection.devices = [device]
        connection.extraDevices = device.children.flatMap { $0.flattenedRows() }
        if let watts = device.measuredWatts {
            connection.liveWatts = watts
            connection.wattsNote = "out"
        }
        return connection
    }

    /// Line one: what is happening, and where. The verb carries the direction,
    /// so the "in"/"out" beside the wattage never has to be guessed at.
    private func subtitle(port: PortInfo, naming: DeviceNode?, role: Connection.Role) -> String {
        var parts: [String] = []
        switch role {
        case .source: parts.append("Charging this Mac")
        case .sink: parts.append("Powered by this Mac")
        case .idle: parts.append(port.carriesData ? "Data only, no power" : "Nothing flowing")
        }
        // When a device names the card, the port becomes supporting detail.
        if naming != nil { parts.append(port.name) }
        return parts.joined(separator: " · ")
    }

    /// Line two: what is on the end of the cable, and how fast.
    private func detail(port: PortInfo, naming: DeviceNode?, role: Connection.Role) -> String? {
        if role == .source {
            return [power.adapterName, power.adapterWatts.map { String(format: "%.0f W max", $0) }]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }
        if let naming {
            return [naming.typeLabel, naming.linkSummary]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }
        return port.describesCable ? port.linkSummary : nil
    }

    /// The best link this Mac's ports can carry.
    var maximumTransfer: String? {
        TransportName.best(Array(Set(ports.flatMap(\.transportsSupported))))
    }

    /// The highest PD contract on offer at a connected port.
    var maximumCharging: PowerOption? {
        ports.filter(\.isConnected)
            .flatMap(\.powerOptions)
            .max { $0.watts < $1.watts }
    }

    /// Static hardware facts, compressed to one line — they never change, so
    /// they do not earn a heading and two rows in a live monitor.
    var portLimitsSummary: String? {
        var parts: [String] = []
        if let transfer = maximumTransfer { parts.append(transfer) }
        if let charging = maximumCharging {
            parts.append(String(format: "charges at up to %.0f W (%.0f V / %.2f A)",
                                charging.watts, charging.volts, charging.amps))
        }
        guard !parts.isEmpty else { return nil }
        return "This Mac's ports: " + parts.joined(separator: " · ")
    }

    private func restartPowerTimer() {
        powerTimer?.invalidate()
        // The SMC publishes fresh numbers about once a second, and reading it
        // costs microseconds, so sample at its own rate while the panel is open.
        let interval: TimeInterval = isPresented ? 1 : 2
        powerTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.readPower() }
        }
    }

    /// Hardware needs a moment to enumerate after a plug event, and a dock
    /// announces its downstream devices in bursts — so scan twice, quietly.
    private func scheduleRescan() {
        pendingRescan?.cancel()
        pendingRescan = Task {
            try? await Task.sleep(nanoseconds: 700_000_000)
            guard !Task.isCancelled else { return }
            refresh()
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            guard !Task.isCancelled else { return }
            refresh()
        }
    }

    // MARK: - Login item

    func refreshLaunchAtLogin() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Wattson: login item change failed: \(error.localizedDescription)")
        }
        refreshLaunchAtLogin()
    }
}
