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
            "MaximumTemperature": 38,
            "MinimumTemperature": 1,
            "CycleCount": 12,
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
        checks.append(Check(name: "battery: temperature extremes come from BatteryData",
                            passed: health.maximumTemperature == 38 && health.minimumTemperature == 1))
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
        return checks
    }
}
