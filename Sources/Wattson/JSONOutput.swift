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

        guard let data = try? JSONSerialization.data(
            withJSONObject: root, options: [.prettyPrinted, .sortedKeys]
        ), let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }

    // MARK: - Sections

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

        let hold = power.chargingHold
        if let summary = hold.summary(externalConnected: power.externalConnected,
                                      isCharging: power.isCharging) {
            object["chargingHold"] = compact([
                "summary": summary,
                "chargingCurrentMA": hold.chargingCurrentMA,
                "chargingVoltageMV": hold.chargingVoltageMV,
                "secondsThermallyLimited": hold.secondsThermallyLimited,
                // Carried raw and unlabelled on purpose — see `ChargingHold`.
                "notChargingReasonRaw": hold.notChargingReason,
            ])
        }
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
            "connectionCount": port.connectionCount,
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
            "productID": identity.productID,
            "productType": identity.productType,
            "productTypeDescription": identity.productTypeDescription,
            "specificationRevision": identity.specificationRevision,
            "usbSpeed": identity.usbSpeed,
            "maxAmps": identity.maxAmps,
            "maxVolts": identity.maxVolts,
            "maxWatts": identity.maxWatts,
            "certificationXID": identity.certificationXID.map { Int($0) },
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
