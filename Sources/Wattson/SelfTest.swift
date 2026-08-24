import Foundation

/// Replays recorded hardware captures through the readers' parse functions.
///
/// This exists because the readers can otherwise only be exercised by plugging
/// something in. Every reader here reads a private, undocumented IORegistry
/// shape, and a shape that is read wrongly returns nothing at all rather than
/// returning something visibly broken — which is indistinguishable from the
/// platform withholding the data. The e-marker reader was wrong for the whole
/// life of the app for exactly that reason: it read `VDOs` from the top level
/// of a node that publishes them one level down, and every Mac agreed by
/// staying silent.
///
/// The fixtures below are lifted verbatim from captures in `probes/`, reduced
/// to the keys the parse functions read and stripped of serial numbers. They
/// are checked in deliberately: the hardware they came from is not always to
/// hand, and the point is to be able to catch a regression without it.
///
/// Most checks are self-validating rather than asserting a remembered number.
/// A Discover Identity node publishes its vendor ID twice — once as a plain
/// integer, and once inside the low 16 bits of the ID Header VDO — so decoding
/// the VDOs correctly means the two agree, and no byte order but the right one
/// makes that happen five times over.
enum SelfTest {

    static func run() -> Int32 {
        var checks: [Check] = []
        checks += identityChecks()
        checks += batteryChecks()
        checks += portStatsChecks()
        checks += thunderboltChecks()
        checks += liquidChecks()
        checks += phyChecks()
        checks += displayChecks()
        checks += smcChecks()
        checks += connectionStateChecks()
        checks += billboardChecks()
        checks += linkBottleneckChecks()
        checks += cableNoteChecks()
        checks += headlineChecks()
        checks += packTemperatureChecks()

        let failures = checks.filter { !$0.passed }
        for check in checks {
            print("\(check.passed ? "  ok  " : "FAILED") \(check.name)")
            // Detail is what a failure needs to be actionable without a
            // debugger; on a passing check it is just noise.
            if !check.passed, let detail = check.detail { print("         \(detail)") }
        }
        print("")
        print("\(checks.count - failures.count)/\(checks.count) checks passed.")
        return failures.isEmpty ? 0 : 1
    }

    struct Check {
        let name: String
        let passed: Bool
        var detail: String?
    }

    // MARK: - SMC decoding and the D-channel join

    /// Four SMC keys read at the same instant as the IORegistry values they
    /// have to equal, captured on this Mac.
    ///
    /// This is the self-validating shape the identity fixtures use, applied to
    /// a question that is otherwise a matter of opinion: the raw bytes are here
    /// beside a figure published independently elsewhere in the system, and no
    /// byte order but the right one makes all four agree. Read the other way
    /// round the cycle count is 3328 and the design capacity 5394, which is
    /// what every capture said before this.
    private static let smcIntegerCapture: [(key: String, type: String, bytes: [UInt8], registry: Int)] = [
        // AppleSmartBattery.CycleCount
        (key: "B0CT", type: "ui16", bytes: [0x0d, 0x00], registry: 13),
        // AppleSmartBattery.DesignCapacity
        (key: "B0DC", type: "ui16", bytes: [0x15, 0x12], registry: 4629),
        // AppleSmartBattery.BatteryData.Qmax[0]
        (key: "BQX1", type: "ui16", bytes: [0x25, 0x13], registry: 4901),
        // AppleSmartBattery.BatteryData.DataFlashWriteCount
        (key: "BFWC", type: "ui16", bytes: [0x8b, 0x12], registry: 4747),
    ]

    private static func smcChecks() -> [Check] {
        var checks: [Check] = []
        for capture in smcIntegerCapture {
            let decoded = SMCMonitor.decode(bytes: capture.bytes, type: capture.type, key: capture.key)
            checks.append(Check(
                name: "smc: \(capture.key) agrees with the value the registry publishes",
                passed: decoded == String(capture.registry),
                detail: "got \(decoded ?? "nil"), registry says \(capture.registry)"))
        }

        // `#KEY` is the controller's own key count and is the one key that is
        // genuinely big-endian. Read like the rest it comes out as 1376256000.
        checks.append(Check(
            name: "smc: #KEY is still read big-endian",
            passed: SMCMonitor.decode(bytes: [0x00, 0x00, 0x08, 0x52], type: "ui32", key: "#KEY") == "2130",
            detail: "got \(SMCMonitor.decode(bytes: [0x00, 0x00, 0x08, 0x52], type: "ui32", key: "#KEY") ?? "nil")"))

        // A rail is claimed by the controller that names it, not by the port
        // whose number happens to match. The numbering here is deliberately
        // crossed: it is the case the UUID exists to survive.
        let channels = [
            SMCMonitor.PortChannel(index: 1, controllerUUID: "aaaa0000000000000000000000000001",
                                   sourceDescription: "pd charger",
                                   power: SMCMonitor.PortPower(volts: 20, amps: 2.25)),
            SMCMonitor.PortChannel(index: 2, controllerUUID: "aaaa0000000000000000000000000002",
                                   sourceDescription: nil, power: nil),
        ]
        var far = PortInfo(name: "USB-C", kind: .usbC, number: 4, isConnected: true)
        far.controllerUUID = "aaaa0000000000000000000000000001"
        checks.append(Check(
            name: "smc: a rail follows its controller, not the matching port number",
            passed: PortMonitor.channel(for: far, among: channels)?.index == 1,
            detail: "port 4 should take channel 1, got \(PortMonitor.channel(for: far, among: channels)?.index.description ?? "nil")"))

        var unknown = PortInfo(name: "USB-C", kind: .usbC, number: 1, isConnected: true)
        unknown.controllerUUID = nil
        checks.append(Check(
            name: "smc: a port that names no controller takes no rail",
            passed: PortMonitor.channel(for: unknown, among: channels) == nil,
            detail: "matching by number here is how a port's power lands on its neighbour"))

        // A machine whose SMC publishes no UUIDs at all is the one case where
        // matching numbers is the best available answer, and is what Wattson
        // has always done.
        let unnamed = [
            SMCMonitor.PortChannel(index: 1, controllerUUID: nil, sourceDescription: nil, power: nil),
            SMCMonitor.PortChannel(index: 2, controllerUUID: nil, sourceDescription: nil,
                                   power: SMCMonitor.PortPower(volts: 5, amps: 0.5)),
        ]
        var plain = PortInfo(name: "USB-C", kind: .usbC, number: 2, isConnected: true)
        plain.controllerUUID = nil
        checks.append(Check(
            name: "smc: without DxUI anywhere, rail number is still used",
            passed: PortMonitor.channel(for: plain, among: unnamed)?.index == 2))
        return checks
    }

    // MARK: - What the CC line says about the socket

    /// This Mac's own `IOPortTransportStateCC` node for USB-C port 1, read with
    /// nothing plugged in.
    private static let ccCapture: [String: Any] = [
        "Active": false,
        "TransportTypeDescription": "CC",
        "ParentBuiltInPortNumber": 1,
        "ParentPortTypeDescription": "USB-C",
        "AuthenticationStatus": 0,
        "AuthenticationStatusDescription": "Idle",
        "AuthenticationRequired": false,
        "AuthorizationStatusDescription": "Not Required",
        "Tunneled": false,
    ]

    private static func connectionStateChecks() -> [Check] {
        var checks: [Check] = []
        let idle = PortMonitor.connectionState(from: ccCapture)
        checks.append(Check(name: "cc: an empty socket reports nothing on the line",
                            passed: !idle.active))
        // "Idle" is what every port that has never authenticated anything says,
        // and a line reading "Auth: Idle" on all three ports is noise.
        checks.append(Check(name: "cc: an idle handshake is not a state worth a line",
                            passed: idle.authentication == nil,
                            detail: "got \(idle.authentication ?? "nil")"))

        var challenged = ccCapture
        challenged["Active"] = true
        challenged["AuthenticationStatusDescription"] = "Authentication Failed"
        let failed = PortMonitor.connectionState(from: challenged)
        checks.append(Check(name: "cc: a live socket and a real handshake both survive",
                            passed: failed.active && failed.authentication == "Authentication Failed",
                            detail: "got \(failed.active), \(failed.authentication ?? "nil")"))

        // The two occupancy readings come from different places, so the
        // interesting case is them disagreeing — including the direction where
        // the port reads empty, which is the one a connected-only view hides.
        var quiet = PortInfo(name: "USB-C", kind: .usbC, number: 1, isConnected: false)
        quiet.ccActive = true
        checks.append(Check(name: "cc: a plug the controller has not noticed is a disagreement",
                            passed: quiet.occupancyDisagreement))
        var agreed = quiet
        agreed.ccActive = false
        checks.append(Check(name: "cc: two readings that agree are not a disagreement",
                            passed: !agreed.occupancyDisagreement))
        var silent = quiet
        silent.ccActive = nil
        checks.append(Check(name: "cc: a port with no CC node disagrees with nothing",
                            passed: !silent.occupancyDisagreement))
        return checks
    }

    // MARK: - Billboard alternate modes

    /// A Billboard capability built to the USB Billboard Device Class spec:
    /// two alternate modes, DisplayPort having been attempted and failed,
    /// Thunderbolt's having come up, and the device reporting that it cannot
    /// talk USB-PD.
    ///
    /// This fixture is written from the specification, not lifted from a
    /// capture — no device carrying one has ever been attached to this machine.
    /// So it is worth being clear about what these checks do and do not prove.
    /// They prove the offsets in `Billboard.capability(from:)` agree with the
    /// offsets used to build this, and that a descriptor which does not add up
    /// is refused. They do not prove the specification is what the hardware
    /// sends. The first dock plugged into this Mac settles that, and the
    /// length equation below is what stands in until one is.
    private static func billboardDescriptor(
        modes: [(svid: Int, index: Int, state: Int)],
        claimedModeCount: Int? = nil,
        failureInfo: UInt8 = 0x01
    ) -> [UInt8] {
        var capability = [UInt8](repeating: 0, count: 44 + modes.count * 4)
        capability[0] = UInt8(44 + modes.count * 4)
        capability[1] = 0x10                                  // DEVICE CAPABILITY
        capability[2] = 0x0D                                  // BILLBOARD
        capability[4] = UInt8(claimedModeCount ?? modes.count)
        capability[5] = 0                                     // preferred mode
        capability[40] = 0x21                                 // bcdVersion 1.21
        capability[41] = 0x01
        capability[42] = failureInfo
        for (index, mode) in modes.enumerated() {
            // Two bits per mode inside bmConfigured, which starts at offset 8.
            capability[8 + index / 4] |= UInt8(mode.state << ((index % 4) * 2))
            let base = 44 + index * 4
            capability[base] = UInt8(mode.svid & 0xFF)
            capability[base + 1] = UInt8((mode.svid >> 8) & 0xFF)
            capability[base + 2] = UInt8(mode.index)
        }
        let total = 5 + capability.count
        return [5, 0x0F, UInt8(total & 0xFF), UInt8(total >> 8), 1] + capability
    }

    private static func billboardChecks() -> [Check] {
        var checks: [Check] = []
        let bos = billboardDescriptor(modes: [
            (svid: 0xFF01, index: 0, state: BillboardMode.State.failed.rawValue),
            (svid: 0x8087, index: 1, state: BillboardMode.State.succeeded.rawValue),
        ])
        guard let capability = Billboard.parse(bos: bos) else {
            checks.append(Check(name: "billboard: the capability is found inside the BOS descriptor",
                                passed: false, detail: "parse returned nil"))
            return checks
        }
        checks.append(Check(name: "billboard: the capability is found inside the BOS descriptor",
                            passed: capability.modes.count == 2,
                            detail: "got \(capability.modes.count) modes"))
        checks.append(Check(
            name: "billboard: each mode keeps its own SVID and its own outcome",
            passed: capability.modes.first?.svid == 0xFF01
                && capability.modes.first?.state == .failed
                && capability.modes.last?.svid == 0x8087
                && capability.modes.last?.state == .succeeded,
            detail: "got \(capability.modes.map { "\($0.svidName) \($0.state)" }.joined(separator: ", "))"))
        checks.append(Check(name: "billboard: the failing mode is the one reported",
                            passed: capability.failures.count == 1
                                && capability.summary?.contains("DisplayPort") == true))
        checks.append(Check(name: "billboard: a device with no USB-PD says so alongside",
                            passed: capability.lacksPowerDelivery
                                && capability.summary?.contains("no USB-PD capability") == true,
                            detail: "got \(capability.summary ?? "nil")"))

        // A device whose modes all came up has nothing to explain, and a line
        // reading "DisplayPort entered" under a working monitor is noise.
        let working = billboardDescriptor(
            modes: [(svid: 0xFF01, index: 0, state: BillboardMode.State.succeeded.rawValue)],
            failureInfo: 0)
        checks.append(Check(name: "billboard: a mode that came up is not worth a line",
                            passed: Billboard.parse(bos: working)?.summary == nil))

        // The guard that stands in for a real capture: a descriptor claiming a
        // different number of modes than its own length accounts for has not
        // been understood, whatever else it might look like.
        let inconsistent = billboardDescriptor(
            modes: [(svid: 0xFF01, index: 0, state: 2)], claimedModeCount: 3)
        checks.append(Check(name: "billboard: a descriptor that does not add up is refused",
                            passed: Billboard.parse(bos: inconsistent) == nil))

        checks.append(Check(name: "billboard: a device with no BOS descriptor reports nothing",
                            passed: Billboard.parse(bos: [0, 0, 0, 0, 0]) == nil))
        // A zero-length capability descriptor would walk the BOS list forever.
        checks.append(Check(name: "billboard: a zero-length capability does not hang the walk",
                            passed: Billboard.parse(bos: [5, 0x0F, 9, 0, 1, 0, 0x10, 0x0D, 0]) == nil))
        return checks
    }

    // MARK: - What took the SuperSpeed link

    /// A passive cable whose Cable VDO declares the given speed rung. The
    /// VDO is at index 3 and the rung is its low three bits, both of which
    /// the e-marker checks above already establish against real captures.
    private static func cable(speedRung: UInt32, vendorID: Int = 0x05AC) -> CableEMarker {
        var emarker = CableEMarker()
        emarker.productType = 3
        emarker.vendorID = vendorID
        emarker.vdos = [0, 0, 0, speedRung]
        return emarker
    }

    private static func device(bcd: Int?, mbps: Double?, name: String = "Ethernet") -> DeviceNode {
        var node = DeviceNode(name: name, kind: .usb)
        node.usbSpecBCD = bcd
        node.speedMbps = mbps
        return node
    }

    private static func linkBottleneckChecks() -> [Check] {
        var checks: [Check] = []
        let fallen = device(bcd: 0x0320, mbps: 480)

        // Nothing to explain: a device running at the tier it declares.
        checks.append(Check(name: "link: a device at its own speed is not a fault",
                            passed: LinkBottleneck.verdict(
                                for: device(bcd: 0x0320, mbps: 5000), port: nil, behind: nil) == nil))
        checks.append(Check(name: "link: a USB 2.0 device at 480 Mbps is not a fault",
                            passed: LinkBottleneck.verdict(
                                for: device(bcd: 0x0200, mbps: 480), port: nil, behind: nil) == nil))
        checks.append(Check(name: "link: a device whose rate was never reported says nothing",
                            passed: LinkBottleneck.verdict(
                                for: device(bcd: 0x0320, mbps: nil), port: nil, behind: nil) == nil))

        // The cable's own chip declaring USB 2.0 is the cable admitting it has
        // no SuperSpeed pairs in it.
        var usb2Port = PortInfo(name: "USB-C", kind: .usbC, number: 1, isConnected: true)
        usb2Port.transportsSupported = ["CC", "USB2", "USB3", "CIO"]
        usb2Port.emarker = cable(speedRung: 0b000)
        let blamed = LinkBottleneck.verdict(for: fallen, port: usb2Port, behind: nil)
        checks.append(Check(name: "link: a USB 2.0 cable is named as the cause",
                            passed: blamed?.cause == .cableIsUSB2(chip: "Apple"),
                            detail: "got \(blamed.map { String(describing: $0.cause) } ?? "nil")"))
        checks.append(Check(name: "link: the verdict states both figures",
                            passed: blamed?.summary.contains("USB 3.2") == true
                                && blamed?.summary.contains("480 Mbps") == true,
                            detail: blamed?.summary ?? "nil"))

        // A cable claiming more than the link delivered is a disagreement, not
        // a confession. Blaming it would accuse a cable that says it is fine.
        var fastCablePort = usb2Port
        fastCablePort.emarker = cable(speedRung: 0b010)
        checks.append(Check(name: "link: a cable claiming 10 Gbps is not blamed for a 480 Mbps link",
                            passed: LinkBottleneck.verdict(
                                for: fallen, port: fastCablePort, behind: nil)?.cause == .unattributed))

        // Lanes outrank the cable: a display holding both of them is a stated
        // assignment, and it explains the same symptom.
        var displayPort = fastCablePort
        displayPort.phy = PhyLink(index: 0, lanes: [
            PhyLane(name: "Lane 0", transport: "DisplayPort", powerLevel: "on", client: nil),
            PhyLane(name: "Lane 1", transport: "DisplayPort", powerLevel: "on", client: nil),
        ])
        checks.append(Check(name: "link: a display holding both lanes outranks the cable",
                            passed: LinkBottleneck.verdict(
                                for: fallen, port: displayPort, behind: nil)?.cause == .displayTookTheLanes,
                            detail: "takesAllLanes = \(displayPort.displayIsUsingAllLanes)"))

        // One cable, one accusation. A hub that lost SuperSpeed explains
        // everything under it, and the devices point at the hub rather than
        // each repeating the charge against the cable.
        var hub = device(bcd: 0x0320, mbps: 480, name: "USB2.0 Hub")
        hub.children = [device(bcd: 0x0320, mbps: 480, name: "Ethernet"),
                        device(bcd: 0x0320, mbps: 480, name: "Card reader")]
        var tree = [hub]
        LinkBottleneck.annotate(&tree, port: usb2Port)
        checks.append(Check(name: "link: the hub is the one blamed for the cable",
                            passed: tree[0].linkVerdict?.cause == .cableIsUSB2(chip: "Apple")
                                && tree[0].linkVerdict?.isRootCause == true))
        checks.append(Check(
            name: "link: everything behind the hub points at the hub",
            passed: tree[0].children.allSatisfy {
                $0.linkVerdict?.cause == .behindHub(name: "USB2.0 Hub")
                    && $0.linkVerdict?.isRootCause == false
            },
            detail: "got \(tree[0].children.map { String(describing: $0.linkVerdict?.cause) }.joined(separator: ", "))"))

        // A port with no USB 3 at all. Not a Mac, but the reader does not know
        // that and the branch should not quietly become unreachable.
        var slowPort = PortInfo(name: "USB-C", kind: .usbC, number: 1, isConnected: true)
        slowPort.transportsSupported = ["CC", "USB2"]
        checks.append(Check(name: "link: a port with no USB 3 answers for itself",
                            passed: LinkBottleneck.verdict(
                                for: fallen, port: slowPort, behind: nil)?.cause == .portHasNoUSB3))
        return checks
    }

    // MARK: - What the cable's chip claims

    /// The two real cables in `probes/`, as the same VDO bytes the identity
    /// fixtures above already check against their captures.
    ///
    /// Two cables is a very small corpus, and it is why there are no
    /// reserved-bit tells here. What it is big enough for is the point these
    /// notes exist to make: the INIU cable publishes a vendor ID of zero and
    /// charges an iPhone at 100 W, so a zeroed chip cannot be a verdict about
    /// anything. whatcable reached the same conclusion from a corpus large
    /// enough to catch Apple's own cables tripping their static flags.
    private static func corpusCable(_ vdos: [[UInt8]], revision: Int = 3) -> CableEMarker {
        var emarker = CableEMarker()
        emarker.specificationRevision = revision
        emarker.productType = 3
        emarker.vendorID = Int(UInt32(vdos[0][0]) | UInt32(vdos[0][1]) << 8)
        emarker.vdos = vdos.map { UInt32($0[0]) | UInt32($0[1]) << 8 | UInt32($0[2]) << 16 | UInt32($0[3]) << 24 }
        return emarker
    }

    private static func cableNoteChecks() -> [Check] {
        var checks: [Check] = []
        // 240 W 20 Gbps C-to-C: vendor 1709, and a real certification ID.
        let certified = corpusCable([[0xad, 0x06, 0x60, 0x1c], [0xf3, 0x29, 0x00, 0x00],
                                     [0x00, 0x00, 0x00, 0x00], [0x42, 0x46, 0x08, 0x00]])
        // Short INIU C-to-C: vendor zero, no certification ID, 100 W, USB 2.0.
        let zeroed = corpusCable([[0x00, 0x00, 0x60, 0x18], [0x00, 0x00, 0x00, 0x00],
                                  [0x00, 0x00, 0x00, 0x00], [0x40, 0x40, 0x08, 0x00]])

        // The figure and the label come from one switch, so this is really a
        // check that they cannot drift: the labels are already pinned against
        // the captures by the identity checks above.
        checks.append(Check(name: "cable: the speed figure agrees with the speed label",
                            passed: certified.usbGbps == 10 && zeroed.usbGbps == 0.48,
                            detail: "got \(show(certified.usbGbps)) and \(show(zeroed.usbGbps))"))

        let certifiedNotes = PortInfo.cableNotes(
            emarker: certified, negotiatedWatts: nil, achievedGbps: nil)
        checks.append(Check(name: "cable: a certification ID is reported as an ID",
                            passed: certifiedNotes.count == 1
                                && certifiedNotes[0].contains("0x29F3"),
                            detail: "got \(certifiedNotes.joined(separator: " | "))"))

        let zeroedNotes = PortInfo.cableNotes(emarker: zeroed, negotiatedWatts: nil, achievedGbps: nil)
        checks.append(Check(name: "cable: a zeroed vendor ID is a note, not a verdict",
                            passed: zeroedNotes.count == 1
                                && zeroedNotes[0].contains("no vendor ID")
                                && !zeroedNotes[0].lowercased().contains("fake"),
                            detail: "got \(zeroedNotes.joined(separator: " | "))"))
        checks.append(Check(name: "cable: an uncertified cable is not accused of anything",
                            passed: !zeroedNotes.contains { $0.contains("XID") }))

        // Rated 100 W by its own chip. One-way: above the rating is proof,
        // at or under it is the ordinary case and says nothing.
        checks.append(Check(
            name: "cable: being run above its own rating is stated",
            passed: PortInfo.cableNotes(emarker: zeroed, negotiatedWatts: 140, achievedGbps: nil)
                .contains { $0.contains("140 W") && $0.contains("100 W") }))
        checks.append(Check(
            name: "cable: being run at its rating is not worth a word",
            passed: !PortInfo.cableNotes(emarker: zeroed, negotiatedWatts: 100, achievedGbps: nil)
                .contains { $0.contains("rates at") }))

        // The chip claims 10 Gbps and the controller measured 40. Both are
        // stated; neither is silently preferred.
        let contradiction = PortInfo.cableNotes(
            emarker: certified, negotiatedWatts: nil, achievedGbps: 40)
        checks.append(Check(name: "cable: a link faster than the chip claims states both figures",
                            passed: contradiction.contains { $0.contains("40 Gbps") && $0.contains("10 Gbps") },
                            detail: "got \(contradiction.joined(separator: " | "))"))
        checks.append(Check(
            name: "cable: a link matching the chip is not a contradiction",
            passed: !PortInfo.cableNotes(emarker: certified, negotiatedWatts: nil, achievedGbps: 10)
                .contains { $0.contains("came up at") }))

        // A chip that answered with nothing has made no claims to check.
        var withheld = CableEMarker()
        withheld.productType = 3
        withheld.vendorID = 0
        checks.append(Check(name: "cable: a chip that published nothing gets no notes",
                            passed: PortInfo.cableNotes(
                                emarker: withheld, negotiatedWatts: 140, achievedGbps: 40).isEmpty))
        return checks
    }

    // MARK: - What is on the end of the cable

    private static func headlineChecks() -> [Check] {
        var checks: [Check] = []
        // A pair of headphones charging off the Mac negotiates no contract and
        // presents no data. Read from the contract alone it is a bare cable.
        var sinking = PortInfo(name: "USB-C", kind: .usbC, number: 2, isConnected: true)
        sinking.transportsActive = ["CC"]
        sinking.outputVolts = 5.14
        sinking.outputAmps = 1.015
        sinking.outputWatts = 5.21
        checks.append(Check(name: "headline: a device drawing power is not a bare cable",
                            passed: sinking.attachedHeadline == "Drawing power — no data link",
                            detail: "got \(sinking.attachedHeadline)"))

        var bare = sinking
        bare.outputVolts = nil
        bare.outputAmps = nil
        bare.outputWatts = nil
        checks.append(Check(name: "headline: a cable with nothing on it still says so",
                            passed: bare.attachedHeadline == "Cable only — nothing negotiated",
                            detail: "got \(bare.attachedHeadline)"))

        var data = sinking
        data.transportsActive = ["CC", "USB3"]
        checks.append(Check(name: "headline: a data device drawing power says both",
                            passed: data.attachedHeadline == "Data device, drawing power",
                            detail: "got \(data.attachedHeadline)"))
        return checks
    }

    // MARK: - Lifetime pack temperature

    private static func packTemperatureChecks() -> [Check] {
        var checks: [Check] = []
        // This Mac: whole degrees by magnitude, and the current reading sits
        // inside the range, so both signals agree.
        let whole = PowerMonitor.lifetimeTemperatureRange(minimum: 1, maximum: 38, current: 30.2)
        checks.append(Check(name: "pack temperature: whole degrees read as whole degrees",
                            passed: whole?.minimum == 1 && whole?.maximum == 38,
                            detail: "got \(whole.map { "\($0.minimum)...\($0.maximum)" } ?? "nil")"))

        // The reading that had another tool reporting 454 °C.
        let tenths = PowerMonitor.lifetimeTemperatureRange(minimum: -80, maximum: 454, current: 30.2)
        checks.append(Check(name: "pack temperature: 454 is 45.4 °C, not 454 °C",
                            passed: tenths?.maximum == 45.4 && tenths?.minimum == -8,
                            detail: "got \(tenths.map { "\($0.minimum)...\($0.maximum)" } ?? "nil")"))

        // Magnitude says tenths, containment says whole degrees. Two signals
        // pointing opposite ways is not a resolved scale.
        checks.append(Check(name: "pack temperature: a disagreement reports nothing",
                            passed: PowerMonitor.lifetimeTemperatureRange(
                                minimum: 20, maximum: 90, current: 85) == nil))

        // An uninitialised blob reads as zero whichever way it is scaled.
        checks.append(Check(name: "pack temperature: an empty range is not a reading",
                            passed: PowerMonitor.lifetimeTemperatureRange(
                                minimum: 0, maximum: 0, current: 30.2) == nil))
        return checks
    }

    // MARK: - PD Discover Identity

    /// One recorded `IOPortTransportComponentCCUSBPD*` node.
    private struct IdentityCapture {
        let name: String
        /// Where it was read: the cable's chip, or the far end.
        let isCablePath: Bool
        let properties: [String: Any]
        /// What the reader should make of it, in the terms the panel uses.
        let expectedSpeed: String?
        let expectedAmps: Double?
        let expectedWatts: Double?
    }

    private static func vdoData(_ bytes: [UInt8]) -> Data { Data(bytes) }

    /// Captures from `probes/`, oldest first. Each carries a real cable or
    /// device that was actually plugged into this Mac.
    private static let identityCaptures: [IdentityCapture] = [
        IdentityCapture(
            name: "SOP' — 240 W 20 Gbps C-to-C (Lenovo dock, Sony XM6 captures)",
            isCablePath: true,
            properties: [
                "Specification Revision": 3,
                "Vendor ID": 1709,
                "Product ID": 0,
                "Product Type": 3,
                "Product Type Description": "Passive Cable",
                "Metadata": [
                    "Vendor ID": 1709,
                    "Product ID": 0,
                    "Product Type": 3,
                    "Product Type Description": "Passive Cable",
                    "VDO Count": 4,
                    "VDOs": [
                        vdoData([0xad, 0x06, 0x60, 0x1c]),
                        vdoData([0xf3, 0x29, 0x00, 0x00]),
                        vdoData([0x00, 0x00, 0x00, 0x00]),
                        vdoData([0x42, 0x46, 0x08, 0x00]),
                    ],
                ] as [String: Any],
            ],
            expectedSpeed: "USB 3.2 Gen 2 — 10 Gbps",
            expectedAmps: 5,
            expectedWatts: 240
        ),
        IdentityCapture(
            name: "SOP' — short INIU C-to-C (iPhone 16 Pro capture)",
            isCablePath: true,
            properties: [
                "Specification Revision": 3,
                "Vendor ID": 0,
                "Product ID": 0,
                "Product Type": 3,
                "Product Type Description": "Passive Cable",
                "Metadata": [
                    "Vendor ID": 0,
                    "Product ID": 0,
                    "Product Type": 3,
                    "Product Type Description": "Passive Cable",
                    "VDO Count": 4,
                    "VDOs": [
                        vdoData([0x00, 0x00, 0x60, 0x18]),
                        vdoData([0x00, 0x00, 0x00, 0x00]),
                        vdoData([0x00, 0x00, 0x00, 0x00]),
                        vdoData([0x40, 0x40, 0x08, 0x00]),
                    ],
                ] as [String: Any],
            ],
            // A 100 W cable that carries nothing faster than USB 2.0. This is
            // the pairing worth being able to state out loud: it charges a
            // laptop and it will still make a drive crawl.
            expectedSpeed: "USB 2.0 — 480 Mbps",
            expectedAmps: 5,
            expectedWatts: 100
        ),
        IdentityCapture(
            name: "SOP — Belkin 70 W travel charger",
            isCablePath: false,
            properties: [
                "Specification Revision": 3,
                "Vendor ID": 12054,
                "Product ID": 0,
                "Metadata": [
                    "Vendor ID": 12054,
                    "Product ID": 0,
                    "bcdDevice": 0,
                    "VDO Count": 4,
                    "VDOs": [
                        vdoData([0x16, 0x2f, 0xc0, 0x01]),
                        vdoData([0x00, 0x00, 0x00, 0x00]),
                        vdoData([0x00, 0x00, 0x00, 0x00]),
                        vdoData([0x00, 0x00, 0x00, 0x40]),
                    ],
                ] as [String: Any],
            ],
            // A charger is not a cable, so the cable readings must stay silent
            // even though there is a fourth VDO sitting there to misread.
            expectedSpeed: nil, expectedAmps: nil, expectedWatts: nil
        ),
        IdentityCapture(
            name: "SOP — iPhone 16 Pro (six VDOs)",
            isCablePath: false,
            properties: [
                "Specification Revision": 3,
                "Vendor ID": 1452,
                "Product ID": 29975,
                "Metadata": [
                    "Vendor ID": 1452,
                    "Product ID": 29975,
                    "bcdDevice": 12547,
                    "VDO Count": 6,
                    "VDOs": [
                        vdoData([0xac, 0x05, 0x40, 0xd5]),
                        vdoData([0x00, 0x00, 0x00, 0x00]),
                        vdoData([0x03, 0x31, 0x17, 0x75]),
                        vdoData([0x32, 0x00, 0x00, 0x65]),
                        vdoData([0x00, 0x00, 0x00, 0x00]),
                        vdoData([0x00, 0x00, 0x00, 0x43]),
                    ],
                ] as [String: Any],
            ],
            expectedSpeed: nil, expectedAmps: nil, expectedWatts: nil
        ),
        IdentityCapture(
            name: "SOP — Ludtom USB-C hub",
            isCablePath: false,
            properties: [
                "Specification Revision": 3,
                "Vendor ID": 8457,
                "Product ID": 258,
                "Metadata": [
                    "Vendor ID": 8457,
                    "Product ID": 258,
                    "bcdDevice": 1,
                    "VDO Count": 4,
                    "VDOs": [
                        vdoData([0x09, 0x21, 0x00, 0x6c]),
                        vdoData([0x7e, 0x03, 0x00, 0x00]),
                        vdoData([0x01, 0x00, 0x02, 0x01]),
                        vdoData([0x3b, 0x00, 0x00, 0x00]),
                    ],
                ] as [String: Any],
            ],
            expectedSpeed: nil, expectedAmps: nil, expectedWatts: nil
        ),
        IdentityCapture(
            name: "SOP' — empty Metadata (Belkin capture, cable idle)",
            isCablePath: true,
            properties: [
                "Specification Revision": 1,
                "Metadata": [:] as [String: Any],
            ],
            // The node exists, so there is an e-marker. It said nothing, so
            // nothing may be claimed about it.
            expectedSpeed: nil, expectedAmps: nil, expectedWatts: nil
        ),
        IdentityCapture(
            name: "SOP — bare node, no Metadata at all (lone cable capture)",
            isCablePath: false,
            properties: ["ParentPortNumber": 2],
            expectedSpeed: nil, expectedAmps: nil, expectedWatts: nil
        ),
    ]

    /// `String(describing:)` on an optional prints "Optional(5.0)"; this is
    /// only ever read by a person comparing two values in a terminal.
    private static func show(_ value: Double?) -> String {
        guard let value else { return "nil" }
        return String(format: "%g", value)
    }

    private static func identityChecks() -> [Check] {
        var checks: [Check] = []
        for capture in identityCaptures {
            let identity = PortMonitor.identity(from: capture.properties)

            // The cross-check that pins the byte order without a spec to hand.
            if let vendorID = identity.vendorID, let header = identity.vdos.first {
                let fromVDO = Int(header & 0xFFFF)
                checks.append(Check(
                    name: "\(capture.name): ID Header vendor matches published vendor",
                    passed: fromVDO == vendorID,
                    detail: fromVDO == vendorID
                        ? nil
                        : "VDO[0] says 0x\(String(fromVDO, radix: 16)), node says 0x\(String(vendorID, radix: 16)) — byte order is wrong"
                ))
            } else if !capture.properties.isEmpty, capture.properties["Metadata"] != nil,
                      let metadata = capture.properties["Metadata"] as? [String: Any], !metadata.isEmpty {
                checks.append(Check(
                    name: "\(capture.name): VDOs decoded",
                    passed: false,
                    detail: "no VDOs came back from a capture that has them"
                ))
            }

            checks.append(Check(
                name: "\(capture.name): speed",
                passed: identity.usbSpeed == capture.expectedSpeed,
                detail: identity.usbSpeed == capture.expectedSpeed
                    ? nil : "got \(identity.usbSpeed ?? "nil"), expected \(capture.expectedSpeed ?? "nil")"
            ))
            checks.append(Check(
                name: "\(capture.name): current rating",
                passed: identity.maxAmps == capture.expectedAmps,
                detail: identity.maxAmps == capture.expectedAmps
                    ? nil : "got \(show(identity.maxAmps)), expected \(show(capture.expectedAmps))"
            ))
            checks.append(Check(
                name: "\(capture.name): wattage rating",
                passed: identity.maxWatts == capture.expectedWatts,
                detail: identity.maxWatts == capture.expectedWatts
                    ? nil : "got \(show(identity.maxWatts)), expected \(show(capture.expectedWatts))"
            ))
        }
        // An endpoint that never stated a product type must not be reported
        // as a passive cable, and a node carrying only a spec revision does
        // not identify anybody. Both were live bugs: an empty SOP node was
        // filed as a partner device, and every unread chip read as "passive".
        let lone = PortMonitor.identity(from: [
            "Specification Revision": 1, "Metadata": [:] as [String: Any],
        ])
        checks.append(Check(name: "identity: an unread chip is neither active nor passive",
                            passed: lone.isActive == nil))
        checks.append(Check(name: "identity: a spec revision alone identifies nobody",
                            passed: !lone.identifiesItself))
        let cable = PortMonitor.identity(from: identityCaptures[0].properties)
        checks.append(Check(name: "identity: a stated passive cable is reported as passive",
                            passed: cable.isActive == false && cable.identifiesItself))
        let charger = PortMonitor.identity(from: identityCaptures[2].properties)
        checks.append(Check(name: "identity: a charger with VDOs identifies itself",
                            passed: charger.identifiesItself && charger.isActive == nil))

        // A PD endpoint publishes a vendor ID and never a name, so the table
        // is the only route from a cable's chip to a manufacturer.
        checks.append(Check(name: "identity: a known vendor ID resolves to a name",
                            passed: cable.vendorName == "Greatland Electronics",
                            detail: "got \(cable.vendorName ?? "nil")"))
        checks.append(Check(name: "identity: the charger's vendor resolves too",
                            passed: charger.vendorName == "Shenzhen Kejinming",
                            detail: "got \(charger.vendorName ?? "nil")"))
        // An unlisted ID still says something useful: it is what you would
        // paste into a search.
        let unlisted = PortMonitor.identity(from: ["Metadata": ["Vendor ID": 0x9ABC] as [String: Any]])
        checks.append(Check(name: "identity: an unlisted vendor falls back to its ID",
                            passed: unlisted.vendorName == "0x9ABC",
                            detail: "got \(unlisted.vendorName ?? "nil")"))
        checks.append(Check(name: "identity: no vendor ID means no vendor",
                            passed: lone.vendorName == nil))
        // 0x2E99 read "Anker" for as long as the table has existed and belongs
        // to Hynetek Semiconductor, who make the PD controller inside a great
        // many cables — including the Baseus C-to-C that this Mac reported as
        // Anker. Checked against the USB-IF list, which is what the ID in a PD
        // e-marker is registered with.
        checks.append(Check(name: "identity: 0x2E99 is the chip maker, not a cable brand",
                            passed: Scanner.vendorName(forID: 0x2E99) == "Hynetek Semiconductor",
                            detail: "got \(Scanner.vendorName(forID: 0x2E99) ?? "nil")"))

        // A populated node met first, then an empty one for the same address:
        // the walk visits children in whatever order IOKit hands them over,
        // and the reading that says something has to survive.
        let populated = PortMonitor.identity(from: identityCaptures[0].properties)
        let empty = PortMonitor.identity(from: ["Metadata": [:] as [String: Any]])
        checks.append(Check(
            name: "identity: an empty node does not wipe out a chip that answered",
            passed: !populated.contentsWithheld && empty.contentsWithheld
        ))
        return checks
    }

    // MARK: - Battery condition and charging holds

    /// This Mac's own `AppleSmartBattery` dictionary, reduced to the keys the
    /// readers touch. A healthy machine reports zero for every fault counter,
    /// so a live read cannot tell a working parse from one that silently
    /// returns nothing — hence the deliberately damaged fixtures further down.
    private static let batteryCapture: [String: Any] = [
        "CycleCount": 12,
        "DesignCycleCount9C": 1000,
        "DesignCapacity": 4629,
        "NominalChargeCapacity": 4746,
        "AppleRawMaxCapacity": 4619,
        "Temperature": 3006,
        "PermanentFailureStatus": 0,
        "BatteryCellDisconnectCount": 0,
        "BatteryData": [
            "CycleCount": 12,
            // The extremes are one level down, in LifetimeData, and this
            // fixture used to put them beside it — matching what the reader
            // expected rather than what the hardware publishes, so it passed
            // while the app showed nothing.
            "LifetimeData": [
                "MaximumTemperature": 38,
                "MinimumTemperature": 1,
            ] as [String: Any],
        ] as [String: Any],
        "ChargerData": [
            "ChargingVoltage": 4249,
            "ChargingCurrent": 0,
            "NotChargingReason": 128,
            "SlowChargingReason": 0,
            "ChargerInhibitReason": 0,
            "TimeChargingThermallyLimited": 0,
        ] as [String: Any],
    ]

    private static func batteryChecks() -> [Check] {
        var checks: [Check] = []
        let health = PowerMonitor.health(from: batteryCapture)

        checks.append(Check(name: "battery: cycle count", passed: health.cycleCount == 12,
                            detail: "got \(health.cycleCount.map(String.init) ?? "nil")"))
        checks.append(Check(name: "battery: temperature is hundredths of a degree",
                            passed: health.temperature == 30.06,
                            detail: "got \(show(health.temperature)) °C"))
        // A pack fresh enough to exceed its design figure. The reader must not
        // quietly clamp this — the UI is what decides how to show it.
        let capacity = health.capacityPercent ?? 0
        checks.append(Check(name: "battery: capacity is reported uncapped above 100%",
                            passed: capacity > 102 && capacity < 103,
                            detail: "got \(show(health.capacityPercent))%"))
        checks.append(Check(name: "battery: cycle life used", passed: health.cyclePercent == 1.2,
                            detail: "got \(show(health.cyclePercent))%"))
        checks.append(Check(name: "battery: temperature extremes come from LifetimeData",
                            passed: health.maximumTemperature == 38 && health.minimumTemperature == 1,
                            detail: "got \(show(health.minimumTemperature)) to \(show(health.maximumTemperature))"))
        checks.append(Check(name: "battery: a healthy pack does not ask for service",
                            passed: !health.needsService))

        // A latched fault has to survive being read, or the one condition
        // worth interrupting someone over never gets there.
        var faulty = batteryCapture
        faulty["PermanentFailureStatus"] = 1
        checks.append(Check(name: "battery: a latched permanent failure asks for service",
                            passed: PowerMonitor.health(from: faulty).needsService))
        var disconnected = batteryCapture
        disconnected["BatteryCellDisconnectCount"] = 2
        checks.append(Check(name: "battery: a disconnected cell asks for service",
                            passed: PowerMonitor.health(from: disconnected).needsService))

        let hold = PowerMonitor.chargingHold(from: batteryCapture)
        checks.append(Check(name: "charging: raw reason is carried, not interpreted",
                            passed: hold.notChargingReason == 128))
        // On battery there is no adapter, so there is nothing to explain.
        checks.append(Check(name: "charging: says nothing with no adapter attached",
                            passed: hold.summary(externalConnected: false, isCharging: false) == nil))
        checks.append(Check(name: "charging: says nothing while charging normally",
                            passed: hold.summary(externalConnected: true, isCharging: true) == nil))
        // Attached, not charging, setpoint zero: a fact, and worth saying.
        checks.append(Check(
            name: "charging: a zero setpoint on a charger is explained",
            passed: hold.summary(externalConnected: true, isCharging: false)
                == "The charger has set its charge current to zero."))

        var hot = PowerMonitor.chargingHold(from: batteryCapture)
        hot.secondsThermallyLimited = 90
        checks.append(Check(
            name: "charging: heat outranks the zero setpoint as an explanation",
            passed: hot.summary(externalConnected: true, isCharging: false)
                == "Charging is being limited by temperature."))
        return checks
    }

    // MARK: - Port counters

    private static let portControllerCapture: [String: Any] = [
        "PortControllerInfo": [
            [
                "PortControllerAttachCount": 0,
                "PortControllerDetachCount": 0,
                "PortControllerHardResetCount": 0,
                "PortControllerI2cErrCount": 0,
                "PortControllerFwVersion": 3_171_072,
            ] as [String: Any],
            // The same controller after a dock that keeps dropping off: the
            // shape this feature exists to surface.
            [
                "PortControllerAttachCount": 214,
                "PortControllerDetachCount": 213,
                "PortControllerHardResetCount": 9,
                "PortControllerI2cErrCount": 3,
                "PortControllerVdoFailCount": 2,
                "PortControllerFwVersion": 3_171_072,
            ] as [String: Any],
        ] as [[String: Any]],
    ]

    private static let usbPortCapture: [String: Any] = [
        "UsbIOPort": "IOService:/AppleARMPE/arm-io@10F00000/AppleHPMDeviceHALType3@C/Port-USB-C@2",
        "link-error-count": 0,
        "port-statistics": [
            "kPortStatConnectCount": 4,
            "kPortStatOverCurrentCount": 0,
            "kPortStatEnumerationFailureCount": 0,
            "kPortStatAddressFailureCount": 0,
            "kPortStatRemoteWakeCount": 1,
            "kPortStatEOF2ViolationCount": 0,
        ] as [String: Any],
    ]

    private static func portStatsChecks() -> [Check] {
        var checks: [Check] = []
        let controllers = PortStatsMonitor.controllers(from: portControllerCapture)
        checks.append(Check(name: "port controllers: both entries decoded",
                            passed: controllers.count == 2,
                            detail: "got \(controllers.count)"))
        guard controllers.count == 2 else { return checks }

        // Unplugging a cable is not a fault. A machine that has had things
        // plugged into it must not light up as faulty.
        checks.append(Check(name: "port controllers: attach and detach are not faults",
                            passed: !controllers[0].hasFaults))
        checks.append(Check(name: "port controllers: real faults are surfaced",
                            passed: controllers[1].hasFaults))
        let named = controllers[1].faultCounts.map(\.name)
        checks.append(Check(
            name: "port controllers: fault list names what actually moved",
            passed: named.contains("Hard resets") && named.contains("I²C errors")
                && named.contains("Identity request failures") && named.count == 3,
            detail: "got \(named.joined(separator: ", "))"))
        checks.append(Check(name: "port controllers: a busy port is still not a faulty one",
                            passed: controllers[1].attachCount == 214))

        guard let usb = PortStatsMonitor.usbPort(from: usbPortCapture, id: "test") else {
            checks.append(Check(name: "usb port: statistics decoded", passed: false,
                                detail: "port-statistics container not found"))
            return checks
        }
        checks.append(Check(name: "usb port: counters decoded", passed: usb.connectCount == 4))
        checks.append(Check(name: "usb port: physical port read from the registry path",
                            passed: usb.portNumber == 2,
                            detail: "got \(usb.portNumber.map(String.init) ?? "nil")"))
        checks.append(Check(name: "usb port: a clean port reports no faults", passed: !usb.hasFaults))

        var noisy = usbPortCapture
        noisy["port-statistics"] = [
            "kPortStatOverCurrentCount": 2,
            "kPortStatEnumerationFailureCount": 7,
        ] as [String: Any]
        let noisyStats = PortStatsMonitor.usbPort(from: noisy, id: "test")
        checks.append(Check(name: "usb port: over-current and enumeration failures surface",
                            passed: noisyStats?.faultCounts.count == 2))
        checks += attributionChecks()
        return checks
    }

    /// A machine whose USB-C ports are numbered with a gap in them, which is
    /// the case that tells the ordinal rule apart from "offset + 1 is the port
    /// number". Both rules agree on 1 and 2; only one of them puts the third
    /// entry on port 4.
    private static func gappedPorts() -> [PortInfo] {
        [
            PortInfo(name: "USB-C 1", kind: .usbC, number: 1, isConnected: false),
            PortInfo(name: "USB-C 2", kind: .usbC, number: 2, isConnected: false),
            PortInfo(name: "USB-C 4", kind: .usbC, number: 4, isConnected: false),
        ]
    }

    private static func attributionChecks() -> [Check] {
        var checks: [Check] = []
        let entries = (0..<3).map { PortControllerStats(index: $0) }

        let gapped = PortStatsMonitor.attributed(entries, to: gappedPorts(), channels: [])
        checks.append(Check(
            name: "controller attribution: ports are taken in order, not by number",
            passed: gapped.map(\.portName) == ["USB-C 1", "USB-C 2", "USB-C 4"],
            detail: "got \(gapped.map { $0.portName ?? "nil" }.joined(separator: ", "))"))

        // Three entries against two USB-C ports and a MagSafe: this Mac's own
        // shape, and the trailing entry is the MagSafe controller.
        let withMagSafe = [
            PortInfo(name: "USB-C 1", kind: .usbC, number: 1, isConnected: false),
            PortInfo(name: "USB-C 2", kind: .usbC, number: 2, isConnected: false),
            PortInfo(name: "MagSafe 3", kind: .magSafe, number: 1, isConnected: false),
        ]
        let trailing = PortStatsMonitor.attributed(entries, to: withMagSafe, channels: [])
        checks.append(Check(
            name: "controller attribution: the spare entry is the MagSafe controller",
            passed: trailing.map(\.portName) == ["USB-C 1", "USB-C 2", "MagSafe 3"],
            detail: "got \(trailing.map { $0.portName ?? "nil" }.joined(separator: ", "))"))

        // Two entries against three ports fits neither count, so nothing is
        // named. A counter on the wrong port is worse than one on no port.
        let short = PortStatsMonitor.attributed(Array(entries.prefix(2)), to: gappedPorts(), channels: [])
        checks.append(Check(name: "controller attribution: an unexpected count names nothing",
                            passed: short.allSatisfy { $0.portName == nil }))

        // The keyed route: offset j is SMC channel j+1, and that channel names
        // the port's own controller. Made to disagree here — channel 1 points
        // at the port the ordinal rule puts third — and the whole attribution
        // has to go, not just that entry.
        var first = PortInfo(name: "USB-C 1", kind: .usbC, number: 1, isConnected: false)
        first.controllerUUID = "aaaa0000000000000000000000000001"
        var third = PortInfo(name: "USB-C 4", kind: .usbC, number: 4, isConnected: false)
        third.controllerUUID = "aaaa0000000000000000000000000003"
        let crossed = [first, PortInfo(name: "USB-C 2", kind: .usbC, number: 2, isConnected: false), third]
        let disagreeing = [
            SMCMonitor.PortChannel(index: 1, controllerUUID: "aaaa0000000000000000000000000003",
                                   sourceDescription: nil, power: nil),
        ]
        checks.append(Check(
            name: "controller attribution: a keyed disagreement drops the lot",
            passed: PortStatsMonitor.attributed(entries, to: crossed, channels: disagreeing)
                .allSatisfy { $0.portName == nil }))

        let agreeing = [
            SMCMonitor.PortChannel(index: 1, controllerUUID: "aaaa0000000000000000000000000001",
                                   sourceDescription: nil, power: nil),
        ]
        checks.append(Check(
            name: "controller attribution: a keyed agreement lets it stand",
            passed: PortStatsMonitor.attributed(entries, to: crossed, channels: agreeing)
                .map(\.portName) == ["USB-C 1", "USB-C 2", "USB-C 4"]))
        return checks
    }

    // MARK: - Thunderbolt link state

    /// This Mac's `IOThunderboltPort` adapters, as read with nothing attached.
    /// Two sockets, two link halves each, plus the adapters that are not
    /// physical ports at all.
    private static let thunderboltCapture: [[String: Any]] = [
        ["Description": "Thunderbolt Native Host Interface Adapter", "Port Number": 7],
        ["Description": "Thunderbolt Port", "Socket ID": "1", "Port Number": 1,
         "Current Link Speed": 8, "Current Link Width": 1,
         "Supported Link Speed": 12, "Supported Link Width": 2, "Thunderbolt Version": 32],
        ["Description": "Thunderbolt Port", "Socket ID": "1", "Port Number": 2,
         "Current Link Speed": 8, "Current Link Width": 1,
         "Supported Link Speed": 12, "Supported Link Width": 2, "Thunderbolt Version": 32],
        ["Description": "Thunderbolt Port", "Socket ID": "2", "Port Number": 1,
         "Current Link Speed": 8, "Current Link Width": 1,
         "Supported Link Speed": 12, "Supported Link Width": 2, "Thunderbolt Version": 32],
        ["Description": "Thunderbolt Port", "Socket ID": "2", "Port Number": 2,
         "Current Link Speed": 8, "Current Link Width": 1,
         "Supported Link Speed": 12, "Supported Link Width": 2, "Thunderbolt Version": 32],
    ]

    private static func thunderboltChecks() -> [Check] {
        var checks: [Check] = []
        let links = ThunderboltMonitor.links(from: thunderboltCapture)
        checks.append(Check(name: "thunderbolt: one entry per socket, host adapter ignored",
                            passed: links.count == 2 && links[1] != nil && links[2] != nil,
                            detail: "got \(links.count) sockets"))
        checks.append(Check(name: "thunderbolt: controller class read from the supported mask",
                            passed: links[1]?.capabilityLabel == "Thunderbolt 4 / USB4 — 40 Gbps",
                            detail: "got \(links[1]?.capabilityLabel ?? "nil")"))

        // The trap this reader exists to avoid: an idle port on this Mac
        // reports a live-looking current speed and width with nothing plugged
        // in, so the achieved link must be gated on the port's own evidence
        // that Thunderbolt is really running.
        var idle = PortInfo(name: "USB-C", kind: .usbC, number: 1, isConnected: false)
        idle.thunderbolt = links[1]
        idle.transportsActive = []
        checks.append(Check(name: "thunderbolt: an empty port claims no achieved link",
                            passed: idle.thunderboltAchieved == nil,
                            detail: "got \(idle.thunderboltAchieved ?? "nil")"))

        var power = idle
        power.isConnected = true
        power.transportsActive = ["CC"]
        checks.append(Check(name: "thunderbolt: a charger on the port is not a Thunderbolt link",
                            passed: power.thunderboltAchieved == nil))

        var running = idle
        running.isConnected = true
        running.transportsActive = ["CC", "CIO"]
        var fast = links[1]
        fast?.currentSpeedCode = 0x4
        fast?.currentWidth = 2
        running.thunderbolt = fast
        checks.append(Check(name: "thunderbolt: a real link reports its lanes and rate",
                            passed: running.thunderboltAchieved == "40 Gbps (2 lanes)",
                            detail: "got \(running.thunderboltAchieved ?? "nil")"))

        // A TB5 controller, which this Mac is not, so the mask has to be read
        // rather than assumed from the machine it was written on.
        let tb5 = ThunderboltMonitor.links(from: [[
            "Description": "Thunderbolt Port", "Socket ID": "1",
            "Supported Link Speed": 14, "Supported Link Width": 2,
        ]])
        checks.append(Check(name: "thunderbolt: a TB5-capable controller is recognised",
                            passed: tb5[1]?.capabilityLabel == "Thunderbolt 5 / USB4 v2 — 80 Gbps",
                            detail: "got \(tb5[1]?.capabilityLabel ?? "nil")"))

        // An unknown speed code must vanish, not be guessed at.
        let odd = ThunderboltMonitor.links(from: [[
            "Description": "Thunderbolt Port", "Socket ID": "1",
            "Supported Link Speed": 1, "Supported Link Width": 2,
        ]])
        checks.append(Check(name: "thunderbolt: an unknown speed code reports nothing",
                            passed: odd[1]?.capabilityLabel == nil))
        return checks
    }

    // MARK: - Liquid detection

    /// A dry port on this Mac, verbatim.
    private static let dryPort: [String: Any] = [
        "FeatureTypeDescription": "LDCM",
        "LiquidDetected": false,
        "StateDescription": "Hardware Controlled",
        "MitigationsEnabled": false,
        "MitigationsStatus": 0,
        "UserOverrideActive": false,
    ]

    private static func liquidChecks() -> [Check] {
        var checks: [Check] = []
        let dry = PortMonitor.liquidDetection(from: dryPort)
        // A dry port is the case that must stay silent, and it is the only one
        // that can be tested against real hardware without ruining a laptop.
        checks.append(Check(name: "liquid: a dry port says nothing",
                            passed: !dry.isNoteworthy && dry.summary == nil))
        checks.append(Check(name: "liquid: the controller's own state is read",
                            passed: dry.state == "Hardware Controlled"))

        var wet = dryPort
        wet["LiquidDetected"] = true
        let detected = PortMonitor.liquidDetection(from: wet)
        checks.append(Check(name: "liquid: a detection is noteworthy",
                            passed: detected.isNoteworthy
                                && detected.summary == "Liquid detected in this port"))

        var held = wet
        held["MitigationsStatus"] = 2
        checks.append(Check(
            name: "liquid: a detection that is cutting the port says both",
            passed: PortMonitor.liquidDetection(from: held).summary
                == "Liquid detected — this port is being held down"))

        // Mitigation without a current detection: the port is still being held
        // down, and saying nothing would leave a dead port unexplained.
        var latched = dryPort
        latched["MitigationsStatus"] = 1
        let stillHeld = PortMonitor.liquidDetection(from: latched)
        checks.append(Check(name: "liquid: a held-down port is explained even once dry",
                            passed: stillHeld.isNoteworthy
                                && stillHeld.summary == "This port is being held down by liquid mitigation"))

        // A node that is not the liquid circuit must not be read as one.
        let notLDCM = PortMonitor.liquidDetection(from: ["FeatureTypeDescription": "Power In"])
        checks.append(Check(name: "liquid: absent keys default to a dry, quiet port",
                            passed: !notLDCM.isNoteworthy))
        return checks
    }

    // MARK: - Lane assignment

    /// The Lenovo ThinkStation monitor capture: a display over USB-C that took
    /// both high-speed lanes at HBR3, leaving the dock's own devices on USB 2.0.
    /// This is the shape the whole feature exists to explain, and it only
    /// occurs while a display is attached.
    private static let displayPhyCapture: [String: Any] = [
        "AppleTypeCPhyID": 1,
        "AppleTypeCPhyLane": [
            "Lane 0": [
                "Transport": "DisplayPort", "Power Level": "on",
                "Client": "AppleATCDPAltModePort(atc1-dpphy)",
            ] as [String: Any],
            "Lane 1": [
                "Transport": "DisplayPort", "Power Level": "on",
                "Client": "AppleATCDPAltModePort(atc1-dpphy)",
            ] as [String: Any],
        ] as [String: Any],
        "AppleTypeCPhyDisplayPortPclk": [
            "PCLK 1": [
                "Clients": ["AppleATCDPAltModePort(atc1-dpphy)"],
                "Link Rate": "8.10Gbps/lane (HBR3)",
            ] as [String: Any],
        ] as [String: Any],
        "AppleTypeCPhyDisplayPortTunnel": [:] as [String: Any],
        "AppleTypeCPhyUSB2": [
            "Transport": "USB2", "Power Level": "on", "Client": "AppleT8132USBXHCI",
        ] as [String: Any],
    ]

    /// The same Mac's other PHY in the same capture: nothing attached.
    private static let idlePhyCapture: [String: Any] = [
        "AppleTypeCPhyID": 0,
        "AppleTypeCPhyLane": ["Lane 0": [:] as [String: Any], "Lane 1": [:] as [String: Any]] as [String: Any],
        "AppleTypeCPhyDisplayPortPclk": [:] as [String: Any],
        "AppleTypeCPhyUSB2": [:] as [String: Any],
    ]

    private static func phyChecks() -> [Check] {
        var checks: [Check] = []
        guard let display = PhyMonitor.phy(from: displayPhyCapture),
              let idle = PhyMonitor.phy(from: idlePhyCapture)
        else {
            return [Check(name: "lanes: captures decoded", passed: false)]
        }

        checks.append(Check(name: "lanes: both lanes read as DisplayPort",
                            passed: display.laneSummary == "Both lanes: DisplayPort",
                            detail: "got \(display.laneSummary ?? "nil")"))
        // 8.10 per lane across the two lanes actually carrying the display.
        checks.append(Check(name: "lanes: display bandwidth is summed over its own lanes",
                            passed: display.displaySummary == "16.2 Gbps over 2 lanes HBR3",
                            detail: "got \(display.displaySummary ?? "nil")"))
        checks.append(Check(name: "lanes: the rate name comes from the controller's string",
                            passed: display.displayLinkRate == "8.10Gbps/lane (HBR3)"))
        checks.append(Check(name: "lanes: the USB 2.0 pair is read separately",
                            passed: display.usb2Transport == "USB2"))
        checks.append(Check(name: "lanes: a display on both lanes is flagged",
                            passed: display.takesAllLanesForDisplay))

        // An unpowered lane is not an assignment.
        checks.append(Check(name: "lanes: an idle port claims no lane assignment",
                            passed: idle.laneSummary == nil && !idle.takesAllLanesForDisplay))
        checks.append(Check(name: "lanes: an idle port claims no display",
                            passed: idle.displaySummary == nil))

        // The consequence is only stated about a port with something on it.
        var empty = PortInfo(name: "USB-C", kind: .usbC, number: 2, isConnected: false)
        empty.phy = display
        checks.append(Check(name: "lanes: no lane verdict on a port with nothing plugged in",
                            passed: !empty.displayIsUsingAllLanes))
        var occupied = empty
        occupied.isConnected = true
        checks.append(Check(name: "lanes: the USB 2.0 consequence is stated when connected",
                            passed: occupied.displayIsUsingAllLanes))

        // One lane for display and one for USB3 is a real and different case.
        var mixed = displayPhyCapture
        mixed["AppleTypeCPhyLane"] = [
            "Lane 0": ["Transport": "DisplayPort", "Power Level": "on"] as [String: Any],
            "Lane 1": ["Transport": "USB3", "Power Level": "on"] as [String: Any],
        ] as [String: Any]
        let split = PhyMonitor.phy(from: mixed)
        checks.append(Check(name: "lanes: a split assignment names both transports",
                            passed: split?.laneSummary == "Both lanes: DisplayPort + USB3",
                            detail: "got \(split?.laneSummary ?? "nil")"))
        checks.append(Check(name: "lanes: a split assignment is not a display taking everything",
                            passed: split?.takesAllLanesForDisplay == false))
        checks.append(Check(name: "lanes: display bandwidth counts only the display's lane",
                            passed: split?.displaySummary == "8.1 Gbps over 1 lane HBR3",
                            detail: "got \(split?.displaySummary ?? "nil")"))
        return checks
    }

    // MARK: - Displays

    private static func displayChecks() -> [Check] {
        var checks: [Check] = []

        // A 4K60 panel: 3840 x 2160 x 60 x 24 bits, plus 8b/10b, is ~14.9 Gbps
        // before a single line of blanking.
        var uhd = DisplayInfo(id: 1)
        uhd.pixelWidth = 3840; uhd.pixelHeight = 2160; uhd.refreshHz = 60
        let floor = uhd.minimumGbps ?? 0
        checks.append(Check(name: "display: 4K60's uncompressed floor is about 14.9 Gbps",
                            passed: floor > 14.8 && floor < 15.0,
                            detail: String(format: "got %.2f", floor)))

        // Both lanes at HBR3 is 16.2 Gbps, which clears the floor — and the
        // app must still say nothing, because the floor understates the need.
        checks.append(Check(name: "display: nothing is claimed when a mode appears to fit",
                            passed: !uhd.cannotFitUncompressed(in: 16.2)
                                && uhd.compressionVerdict(linkGbps: 16.2) == nil))

        // One lane at HBR3 is 8.1 Gbps. The floor alone exceeds it, so the
        // picture provably cannot be uncompressed.
        checks.append(Check(name: "display: a mode over the floor is proved compressed",
                            passed: uhd.cannotFitUncompressed(in: 8.1)))
        let verdict = uhd.compressionVerdict(linkGbps: 8.1) ?? ""
        checks.append(Check(name: "display: the verdict states both figures",
                            passed: verdict.contains("14.9") && verdict.contains("8.1")
                                && verdict.contains("DSC"),
                            detail: verdict))

        // A mode with nothing in it must not produce arithmetic.
        let blank = DisplayInfo(id: 2)
        checks.append(Check(name: "display: an unread mode computes nothing",
                            passed: blank.minimumGbps == nil
                                && !blank.cannotFitUncompressed(in: 1)))

        // Attribution: unambiguous or not at all.
        var builtIn = DisplayInfo(id: 3); builtIn.isBuiltIn = true
        var one = DisplayInfo(id: 4); one.pixelWidth = 2560; one.pixelHeight = 1440; one.refreshHz = 60
        var two = DisplayInfo(id: 5); two.pixelWidth = 1920; two.pixelHeight = 1080; two.refreshHz = 60
        checks.append(Check(name: "display: the built-in panel is never the external one",
                            passed: DisplayMonitor.soleExternal(from: [builtIn]) == nil))
        checks.append(Check(name: "display: one external display attributes",
                            passed: DisplayMonitor.soleExternal(from: [builtIn, one])?.id == 4))
        checks.append(Check(name: "display: two external displays attribute to neither",
                            passed: DisplayMonitor.soleExternal(from: [builtIn, one, two]) == nil))

        // The port-level verdict needs both halves; neither alone will do.
        var port = PortInfo(name: "USB-C", kind: .usbC, number: 2, isConnected: true)
        port.display = uhd
        checks.append(Check(name: "display: no verdict without a known link rate",
                            passed: port.displayCompression == nil))
        return checks
    }
}
