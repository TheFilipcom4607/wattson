import AppKit
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
    /// Mounted volumes, mapped to the USB devices they live on.
    @Published private(set) var volumes: [VolumeInfo] = []
    /// Eject failures, kept next to the button that caused them.
    @Published private(set) var ejectErrors: [String: String] = [:]
    @Published private(set) var ejecting: Set<String> = []

    /// What was attached and when, for as long as this app was running.
    let log = ConnectionLog()

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
    /// Diagnostic capture is deliberately opt-in: its reports can be large and
    /// may contain serial numbers and other hardware identifiers.
    @Published var showDebugOptions: Bool { didSet { save(showDebugOptions, "showDebugOptions") } }
    /// Off unless asked for: an app that starts talking after an update is an
    /// app people quit.
    @Published var announceChanges: Bool { didSet { save(announceChanges, "announceChanges") } }

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
    private let volumeMonitor = VolumeMonitor()
    private var volumeObservers: [NSObjectProtocol] = []

    /// The first scan of a run is a baseline, not a burst of arrivals.
    private var hasScanned = false
    private let toasts = ToastPresenter()
    private var toastTask: Task<Void, Never>?
    private var pendingArrivals: [DeviceNode] = []
    private var pendingDepartures: [DeviceNode] = []
    private var shownArrivals: [DeviceNode] = []
    private var shownDepartures: [DeviceNode] = []

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.titleModeKey) ?? ""
        titleMode = TitleMode(rawValue: stored) ?? .livePower
        showSparkline = Self.flag("showSparkline")
        showCable = Self.flag("showCable")
        showPortLimits = Self.flag("showPortLimits")
        showDevices = Self.flag("showDevices")
        showVendors = Self.flag("showVendors")
        showDebugOptions = UserDefaults.standard.bool(forKey: "showDebugOptions")
        announceChanges = UserDefaults.standard.bool(forKey: "announceChanges")

        watcher = HotplugWatcher { [weak self] in
            self?.scheduleRescan()
        }
        watcher?.start()

        // Plug and unplug should register immediately, not on the next tick.
        powerWatcher = PowerSourceWatcher { [weak self] in
            Task { @MainActor in self?.refresh() }
        }
        powerWatcher?.start()

        // Mounting is its own event: an encrypted volume can be unlocked long
        // after the drive it lives on was plugged in, and no USB event fires.
        for name in [NSWorkspace.didMountNotification,
                     NSWorkspace.didUnmountNotification,
                     NSWorkspace.didRenameVolumeNotification] {
            let observer = NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.readVolumes() }
            }
            volumeObservers.append(observer)
        }

        refreshLaunchAtLogin()
        refresh()
        restartPowerTimer()
    }

    deinit {
        volumeObservers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
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
            let before = self.presentDevices
            self.result = scan
            self.attributeMeasuredPower()
            self.noteChanges(from: before)
            self.readVolumes()
            self.isScanning = false
        }
    }

    // MARK: - What changed

    /// Everything on the tree right now, keyed by the identity history uses.
    private var presentDevices: [String: DeviceNode] {
        var devices: [String: DeviceNode] = [:]
        for row in result.devices.flatMap({ $0.flattenedRows() }) {
            devices[row.node.persistentKey] = row.node
        }
        return devices
    }

    /// The log and the toast are the same fact told twice, and both fall out of
    /// diffing consecutive scans — `HotplugWatcher` only ever says "something
    /// changed", never what.
    private func noteChanges(from before: [String: DeviceNode]) {
        let after = presentDevices
        // The first scan of a run is the baseline. Everything already attached
        // at launch would otherwise read as having just arrived, and the log is
        // explicit that it covers only what happened while Wattson watched.
        guard hasScanned else {
            hasScanned = true
            return
        }

        let arrived = after.filter { before[$0.key] == nil }.map(\.value)
        let left = before.filter { after[$0.key] == nil }.map(\.value)
        guard !arrived.isEmpty || !left.isEmpty else { return }

        let now = Date()
        log.append(
            arrived.map {
                ConnectionEvent(device: $0.persistentKey, name: $0.name, kind: .connected, at: now)
            } + left.map {
                ConnectionEvent(device: $0.persistentKey, name: $0.name, kind: .disconnected, at: now)
            }
        )

        // Nothing to announce to somebody already looking at the list.
        guard announceChanges, !isPresented else { return }
        pendingArrivals += arrived
        pendingDepartures += left
        scheduleToast()
    }

    /// A hub announces its downstream devices in a burst, which would put one
    /// toast per device on screen. The debounce collapses the burst; merging
    /// into a toast that is still up collapses the second rescan into the first.
    private func scheduleToast() {
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled else { return }
            self?.presentToast()
        }
    }

    private func presentToast() {
        if toasts.isShowing {
            pendingArrivals = unique(shownArrivals + pendingArrivals)
            pendingDepartures = unique(shownDepartures + pendingDepartures)
        }
        guard let content = ToastSummary.content(
            arrived: pendingArrivals, left: pendingDepartures
        ) else { return }

        shownArrivals = pendingArrivals
        shownDepartures = pendingDepartures
        pendingArrivals = []
        pendingDepartures = []
        toasts.show(content)
    }

    private func unique(_ nodes: [DeviceNode]) -> [DeviceNode] {
        var seen = Set<String>()
        return nodes.filter { seen.insert($0.persistentKey).inserted }
    }

    // MARK: - Volumes

    private func readVolumes() {
        volumes = volumeMonitor.read()
    }

    func volumes(for node: DeviceNode) -> [VolumeInfo] {
        volumes.filter { $0.deviceID == node.id }
    }

    func reveal(_ volume: VolumeInfo) {
        NSWorkspace.shared.activateFileViewerSelecting([volume.url])
    }

    func eject(_ volume: VolumeInfo) {
        ejectErrors[volume.id] = nil
        ejecting.insert(volume.id)
        volumeMonitor.eject(volume) { [weak self] message in
            Task { @MainActor in
                guard let self else { return }
                self.ejecting.remove(volume.id)
                self.ejectErrors[volume.id] = message
                self.readVolumes()
                // A successful eject takes the device off the bus, which the
                // tree should show without waiting for the hotplug rescan.
                if message == nil { self.refresh() }
            }
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

    /// The same cards, with anything that does not match the query taken out.
    ///
    /// Pure UI over the existing model — no new data, and no new scan.
    func connections(matching query: String) -> [Connection] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return connections }

        return connections.compactMap { connection in
            // Searching for the hub means wanting to see what is on it, so a
            // card that matches by name keeps its whole tree.
            if connection.title.lowercased().contains(needle)
                || connection.devices.contains(where: { matches($0, needle) }) {
                return connection
            }
            let kept = keeping(connection.extraDevices, matching: needle)
            guard !kept.isEmpty else { return nil }
            var filtered = connection
            filtered.extraDevices = kept
            return filtered
        }
    }

    private func matches(_ node: DeviceNode, _ needle: String) -> Bool {
        [node.name, node.vendor ?? "", node.typeLabel ?? "", node.serial ?? ""]
            .contains { $0.lowercased().contains(needle) }
    }

    /// Keeps every match and whatever leads to it — a hit three levels into a
    /// hub still belongs under that hub, not orphaned at the root.
    private func keeping(_ rows: [FlatDevice], matching needle: String) -> [FlatDevice] {
        var keep = Set<Int>()
        for (index, row) in rows.enumerated() where matches(row.node, needle) {
            keep.insert(index)
            // Walk back up: the nearest earlier row at each shallower depth is
            // this row's parent, and so on to the root of the card.
            var depth = row.depth
            var cursor = index - 1
            while cursor >= 0, depth > 0 {
                if rows[cursor].depth < depth {
                    keep.insert(cursor)
                    depth = rows[cursor].depth
                }
                cursor -= 1
            }
        }
        return rows.enumerated().filter { keep.contains($0.offset) }.map(\.element)
    }

    private func connection(for port: PortInfo, devices: [DeviceNode]) -> Connection {
        let isSource = power.externalConnected && power.sourcePortName == port.name
        let role: Connection.Role = isSource ? .source : (port.isSourcing ? .sink : .idle)
        // A single device names its own card; with none or several, the port does.
        let naming = devices.count == 1 ? devices.first : nil
        // And with nothing plugged in but the charger, the charger names it —
        // "35W USB-C Power Adapter" is what that card is about, and the port it
        // arrived on is the supporting detail.
        let adapterName = naming == nil && role == .source ? power.adapterModelName : nil

        var connection = Connection(
            id: port.id,
            title: naming?.name ?? adapterName ?? port.name,
            subtitle: "",
            symbol: naming?.symbolName ?? (isSource ? "powerplug.fill" : "cable.connector")
        )
        // The mark belongs to whatever names the card. A port is not Apple, a
        // charger is — and a third-party dock fed by an Apple brick must not
        // end up with an Apple logo against its own name.
        connection.isApple = naming?.isApple
            ?? (port.kind == .magSafe || (adapterName != nil && power.isAppleAdapter))
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
        connection.subtitle = subtitle(
            port: port, named: naming != nil || adapterName != nil, role: role
        )
        connection.detail = detail(
            port: port, naming: naming, role: role, titledByAdapter: adapterName != nil
        )
        if role == .source { connection.adapterRows = adapterRows }
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
    private func subtitle(port: PortInfo, named: Bool, role: Connection.Role) -> String {
        var parts: [String] = []
        switch role {
        case .source: parts.append("Charging this Mac")
        case .sink: parts.append("Powered by this Mac")
        case .idle: parts.append(port.carriesData ? "Data only, no power" : "Nothing flowing")
        }
        // When anything else names the card, the port becomes supporting detail.
        if named { parts.append(port.name) }
        return parts.joined(separator: " · ")
    }

    /// Line two: what is on the end of the cable, and how fast.
    private func detail(
        port: PortInfo,
        naming: DeviceNode?,
        role: Connection.Role,
        titledByAdapter: Bool = false
    ) -> String? {
        if role == .source {
            // A source with no name of its own gets described by what it is
            // doing instead. macOS calls a monitor feeding this Mac over
            // Type-C a "usb host", which tells nobody anything; that it is
            // pushing current without a PD contract tells them why it is 15 W.
            let described = power.adapterModelName == nil
                && port.negotiated != nil && !port.hasPDContract
                ? "Type-C source, no PD contract"
                : power.adapterName
            // The name is only worth repeating here when something else took
            // the title — otherwise the line would say the adapter twice.
            return [
                titledByAdapter ? nil : described,
                power.adapterWatts.map { String(format: "%.0f W max", $0) }
            ].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }
        if let naming {
            // Vendor rides along on the card's second line rather than living
            // only in the expanded rows — it is the fastest way to tell two
            // identically-named devices apart.
            return [naming.typeLabel, naming.linkSummary, showVendors ? naming.vendor : nil]
                .compactMap { $0 }.joined(separator: " · ").nilIfEmpty
        }
        return port.describesCable ? port.linkSummary : nil
    }

    /// The charger's own account of itself. Apple's bricks fill all of this in;
    /// third-party PD chargers frequently report none of it, which is itself
    /// the answer to "is this an Apple charger".
    private var adapterRows: [(label: String, value: String)] {
        var rows: [(label: String, value: String)] = []
        if let manufacturer = power.adapterManufacturer {
            rows.append(("Made by", manufacturer))
        }
        if let firmware = power.adapterFirmware {
            rows.append(("Firmware", firmware))
        }
        if let serial = power.adapterSerial {
            rows.append(("Serial", serial.middleTruncated(to: 28)))
        }
        return rows
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
        // What this Mac will accept beats what the attached charger offers:
        // it is the ceiling that does not change when you swap the brick. The
        // port's own offer stands in only for machines missing from the table.
        if let ceiling = MacModel.maximumChargeWatts {
            parts.append(String(format: "charges at up to %.0f W", ceiling))
        } else if let charging = maximumCharging {
            parts.append(String(format: "this charger offers %.0f W (%.0f V / %.2f A)",
                                charging.watts, charging.volts, charging.amps))
        }
        guard !parts.isEmpty else { return nil }
        return "This Mac: " + parts.joined(separator: " · ")
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
