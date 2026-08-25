import Foundation

/// `--json`: the same reading `--dump` prints, in a shape something else can
/// consume.
///
/// Built by hand rather than by making the model types `Codable`. The models
/// carry fields that exist only to keep SwiftUI's diffing happy — per-instance
/// UUIDs, `id` strings derived from registry paths — and a synthesised encoder
/// would put every one of them in the output and turn them into a promise this
/// app cannot keep. What is here is what someone could reasonably script
/// against, and the key names are meant to stay put.
///
/// Nulls are omitted rather than emitted. A reading Wattson does not have is
/// not a reading of nothing, and the whole app is built on that distinction:
/// an absent key means the hardware did not say, which is different from a
/// zero it did say.
enum JSONOutput {

    static func render(power: PowerSnapshot, ports: [PortInfo], scan: ScanResult) -> String {
        var root: [String: Any] = [
            "capturedAt": ISO8601DateFormatter().string(from: Date()),
            "mac": compact([
                "model": MacModel.identifier,
                "maximumChargeWatts": MacModel.maximumChargeWatts,
            ]),
            "power": powerObject(power),
            "ports": ports.map(portObject),
            "devices": scan.devices.map(deviceObject),
        ]
        root["deviceCount"] = scan.deviceCount

        // Only what has actually gone wrong. A machine where nothing ever has
        // emits no key at all rather than a wall of zeroes.
        let faults = faultObjects(ports: ports)
        if !faults.isEmpty { root["recordedFaults"] = faults }

        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    // MARK: - Sections

    private static func faultObjects(ports: [PortInfo]) -> [[String: Any]] {
        var out: [[String: Any]] = []
        for stats in PortStatsMonitor.readControllers(attributedTo: ports) where stats.hasFaults {
            var entry: [String: Any] = [
                // Position in the controller's own array. Kept whether or not
                // the port below resolved, because it is the only identity the
                // array itself carries.
                "controller": stats.index + 1,
                "counts": Dictionary(uniqueKeysWithValues: stats.faultCounts.map { ($0.name, $0.count) }),
            ]
            // Present only where the roster made the attribution safe. An
            // absent key means these counters belong to a port nothing here can
            // name, not to no port.
            if let name = stats.portName { entry["port"] = name }
            out.append(entry)
        }
        for stats in PortStatsMonitor.readUSBPorts() where stats.hasFaults {
            var entry: [String: Any] = [
                "counts": Dictionary(uniqueKeysWithValues: stats.faultCounts.map { ($0.name, $0.count) }),
            ]
            if let number = stats.portNumber { entry["usbPort"] = number }
            out.append(entry)
        }
        return out
    }

    private static func powerObject(_ power: PowerSnapshot) -> [String: Any] {
        var object = compact([
            "externalConnected": power.externalConnected,
            "isCharging": power.isCharging,
            "inputWatts": power.inputWatts,
            "inputVolts": power.inputVolts,
            "inputAmps": power.inputAmps,
            "systemLoadWatts": power.systemLoadWatts,
            "accessoryWatts": power.accessoryWatts,
            "macOnlyWatts": power.macOnlyWatts,
            "batteryWatts": power.batteryWatts,
            "batteryPercent": power.batteryPercent,
        ])

        if power.adapterWatts != nil || power.adapterName != nil {
            object["adapter"] = compact([
                "ratedWatts": power.adapterWatts,
                "name": power.adapterName,
                "model": power.adapterModelName,
                "manufacturer": power.adapterManufacturer,
                "isApple": power.isAppleAdapter,
                "serial": power.adapterSerial,
                "firmware": power.adapterFirmware,
                "negotiatedProfile": power.negotiatedProfile,
            ])
        }
        if !power.profiles.isEmpty {
            object["pdProfiles"] = power.profiles.map { profile in
                [
                    "index": profile.id,
                    "volts": profile.volts,
                    "amps": profile.amps,
                    "watts": profile.watts,
                    "negotiated": profile.id == power.negotiatedProfile,
                ] as [String: Any]
            }
        }

        let health = power.health
        if health.hasAnything {
            object["battery"] = compact([
                "cycleCount": health.cycleCount,
                "designCycleCount": health.designCycleCount,
                "designCapacityMAh": health.designCapacity,
                "currentCapacityMAh": health.nominalChargeCapacity,
                "capacityPercent": health.capacityPercent,
                "cyclePercent": health.cyclePercent,
                "temperatureCelsius": health.temperature,
                "maximumTemperatureCelsius": health.maximumTemperature,
                "minimumTemperatureCelsius": health.minimumTemperature,
                "needsService": health.needsService,
            ])
        }

        // Emitted whenever the charger published anything, rather than only
        // when there is a sentence to go with it. This was gated on `summary`,
        // which was fine while a zero setpoint produced one — and became a way
        // of discarding evidence the moment it stopped. A pack held at a charge
        // limit is exactly the state whose `notChargingReasonRaw` a decode
        // would have to be built from, and it is the state with nothing to say.
        let hold = power.chargingHold
        let holdObject = compact([
            "summary": hold.summary(externalConnected: power.externalConnected,
                                    isCharging: power.isCharging),
            "chargingCurrentMA": hold.chargingCurrentMA,
            "chargingVoltageMV": hold.chargingVoltageMV,
            "secondsThermallyLimited": hold.secondsThermallyLimited,
            // Carried raw and unlabelled on purpose — see `ChargingHold`.
            "notChargingReasonRaw": hold.notChargingReason,
        ])
        if !holdObject.isEmpty { object["chargingHold"] = holdObject }
        return object
    }

    private static func portObject(_ port: PortInfo) -> [String: Any] {
        var object = compact([
            "name": port.name,
            "kind": port.kind.rawValue,
            "number": port.number,
            "connected": port.isConnected,
            "attached": port.isConnected ? port.attachedHeadline : nil,
            "transportsActive": port.transportsActive.isEmpty ? nil : port.transportsActive,
            "transportsSupported": port.transportsSupported.isEmpty ? nil : port.transportsSupported,
            "dataRole": port.dataRole,
            "tunnelled": port.isTunnelled,
            "restricted": port.isRestricted,
            "authorization": port.authorization,
            "authentication": port.authentication,
            // The CC line's own answer, kept beside `connected` rather than
            // folded into it: they are read from different places and there is
            // no third opinion to settle a disagreement with.
            "ccActive": port.ccActive,
            "sourceDescription": port.sourceDescription,
            "connectionCount": port.connectionCount,
            // Facts about what the cable's chip says, never a rating. Absent
            // when the chip published nothing.
            "cableNotes": port.cableNotes.isEmpty ? nil : port.cableNotes,
            "outputWatts": port.outputWatts,
            "outputVolts": port.outputVolts,
            "outputAmps": port.outputAmps,
        ])
        if let negotiated = port.negotiated {
            object["contract"] = compact([
                "volts": negotiated.volts,
                "amps": negotiated.amps,
                "watts": negotiated.watts,
                "mechanism": port.powerSourceKind,
            ])
        }
        if !port.powerOptions.isEmpty {
            object["offered"] = port.powerOptions.map {
                ["volts": $0.volts, "amps": $0.amps, "watts": $0.watts] as [String: Any]
            }
        }
        if let link = port.thunderbolt {
            object["thunderbolt"] = compact([
                "controller": link.capabilityLabel,
                "supportedLanes": link.supportedWidth,
                // Present only when the port says Thunderbolt is really up.
                "achieved": port.thunderboltAchieved,
                "achievedLanes": port.thunderboltAchieved == nil ? nil : link.currentWidth,
            ])
        }
        if let phy = port.phy, port.isConnected {
            object["lanes"] = compact([
                "summary": phy.laneSummary,
                "display": phy.displaySummary,
                "displayLinkRate": phy.displayLinkRate ?? phy.displayTunnelRate,
                "usb2Transport": phy.usb2Transport,
                "displayUsingAllLanes": port.displayIsUsingAllLanes,
                "assignments": phy.activeLanes.compactMap { lane -> [String: Any]? in
                    guard let transport = lane.transport else { return nil }
                    return ["lane": lane.name, "transport": transport]
                },
            ])
        }
        if let display = port.display {
            object["display"] = compact([
                "mode": display.modeSummary,
                "pixelWidth": display.pixelWidth,
                "pixelHeight": display.pixelHeight,
                "refreshHz": display.refreshHz,
                "minimumGbpsUncompressed": display.minimumGbps,
                "compression": port.displayCompression,
                // The controller's own account: which displays arrived on this
                // port, what each link came up at, and the mode where a serial
                // matched one.
                "displayLinks": port.displayLinks.map { link in
                    [
                        "index": link.index,
                        "name": link.productName,
                        "manufacturer": link.manufacturer,
                        "linkRate": link.linkRate,
                        "connector": link.connector,
                        "tunnelled": link.isTunnelled,
                        "mode": link.mode?.modeSummary,
                    ] as [String: Any?]
                },
            ])
        }
        if let liquid = port.liquid {
            object["liquidDetection"] = compact([
                "detected": liquid.detected,
                "mitigationsEnabled": liquid.mitigationsEnabled,
                "mitigationsActive": liquid.mitigationsActive,
                "userOverride": liquid.userOverride,
                "state": liquid.state,
                "summary": liquid.summary,
            ])
        }
        if let cable = port.emarker { object["cable"] = identityObject(cable) }
        if let partner = port.partner { object["partner"] = identityObject(partner) }
        return object
    }

    private static func identityObject(_ identity: CableEMarker) -> [String: Any] {
        compact([
            // The distinction the panel makes in words, made explicit here: a
            // node that exists but says nothing is not the same as a rating.
            "contentsWithheld": identity.contentsWithheld,
            "vendorID": identity.vendorID,
            "vendor": identity.vendorName,
            "productID": identity.productID,
            "productType": identity.productType,
            "productTypeDescription": identity.productTypeDescription,
            "specificationRevision": identity.specificationRevision,
            "usbSpeed": identity.usbSpeed,
            "maxAmps": identity.maxAmps,
            "maxVolts": identity.maxVolts,
            "maxWatts": identity.maxWatts,
            "certificationXID": identity.certificationXID.map { Int($0) },
            "speedGbps": identity.usbGbps,
            // Omitted rather than false when the responder never said.
            "active": identity.isActive,
        ])
    }

    private static func deviceObject(_ node: DeviceNode) -> [String: Any] {
        var object = compact([
            "name": node.name,
            "kind": node.kind.rawValue,
            "type": node.typeLabel,
            "vendor": node.vendor,
            "vendorID": node.vendorID,
            "productID": node.productID,
            "serial": node.serial,
            "version": node.version,
            "speeds": node.speeds.isEmpty ? nil : node.speeds,
            "speedMbps": node.speedMbps,
            "allocatedWatts": node.watts,
            "allocatedMilliamps": node.milliamps,
            "measuredWatts": node.measuredWatts,
            "hubBudgetMilliamps": node.hubBudgetMilliamps,
            "altMode": node.altMode,
            // Present only when a mode actually failed. A device whose modes
            // all came up emits no key rather than an empty one.
            "altModeFailure": node.altModeFailure,
            // Present only when a device declared SuperSpeed and did not get
            // it. A device running at its own maximum emits no key.
            "linkBottleneck": node.linkVerdict?.summary,
            // What the device's BOS descriptor claims it can do, which is not
            // what `version` says: that is the enumeration that happened.
            "claimsGbps": node.speedCapability?.declaredGbps,
            "claimsSuperSpeed": node.speedCapability?.supportsSuperSpeed,
            "isApple": node.isApple,
            // A device with no serial is keyed on where it is plugged in, and
            // anything scripting against this needs to know which it got.
            "stableIdentity": node.hasStableIdentity,
        ])
        if !node.children.isEmpty {
            object["children"] = node.children.map(deviceObject)
        }
        return object
    }

    // MARK: - Helpers

    /// Drops nil values, and unwraps the rest into things JSONSerialization
    /// will accept. A `Double?` left boxed as `Any` serialises as null.
    private static func compact(_ pairs: [String: Any?]) -> [String: Any] {
        var object: [String: Any] = [:]
        for (key, value) in pairs {
            switch value {
            case let value as Double: object[key] = value
            case let value as Int: object[key] = value
            case let value as Bool: object[key] = value
            case let value as String: object[key] = value
            case let value as [String]: object[key] = value
            case let value as [String: Any]: object[key] = value
            case .some(let value): object[key] = value
            case .none: continue
            }
        }
        return object
    }
}
