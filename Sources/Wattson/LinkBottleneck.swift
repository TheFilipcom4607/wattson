import Foundation

/// Why a device did not get the link it says it is capable of.
///
/// The device's claim comes from its BOS descriptor and the rate it got comes
/// from `UsbLinkSpeed`. A device whose BOS declares SuperSpeed and which
/// enumerated at 480 Mbps has demonstrably not got its SuperSpeed pairs, and
/// that is the whole of "why is the dock's ethernet crawling" — a question the
/// panel could show every number relevant to without ever answering.
///
/// The claim deliberately does **not** come from `bcdUSB`, and the reason is
/// worth keeping. `bcdUSB` looked like exactly the right field and is not: it
/// describes the enumeration that happened rather than the device's
/// capability. A SuperSpeed device on a USB 2.0 cable trains only on D+/D- and
/// reports itself as USB 2.1, so a test built on `bcdUSB` can never fire for
/// the one case it exists to catch. An iPhone 16 Pro on a USB 2.0 cable is
/// that case and is what caught it: `bcdUSB` 0x0210, 480 Mbps, and a BOS
/// descriptor declaring SuperSpeed and 10 Gbps. The 0x0210 is itself the tell
/// — USB 2.1 means "this device has a BOS descriptor".
///
/// A Ugreen NVMe enclosure on the other port is the control: the same 10 Gbps
/// claim in its BOS, and 10 Gbps actually negotiated. It must stay silent, and
/// it does.
///
/// The test is a tier test rather than a rate test, deliberately. Devices
/// declare a top sublink speed and are entitled to run below it, so
/// "claims 10 Gbps, negotiated 5 Gbps" is evidence of nothing. Falling all the
/// way back to High Speed is different — there is no reading of 480 Mbps where
/// the SuperSpeed pairs are working.
///
/// The inference runs one way, like the display compression verdict it sits
/// beside. Losing SuperSpeed proves something took it; keeping SuperSpeed
/// proves nothing about whether the link is as fast as it could be, and
/// nothing here will ever say a link is fine.
struct LinkVerdict: Hashable {
    /// What took it, in descending order of how certain the attribution is.
    enum Cause: Hashable {
        /// The port's high-speed lanes are both carrying DisplayPort, so there
        /// is nothing left for USB 3. The most certain of these: the lane
        /// controller states the assignment outright.
        case displayTookTheLanes
        /// The cable's own chip declares USB 2.0 and nothing more. Also
        /// certain — the cable is saying it has no SuperSpeed pairs in it.
        /// The associated name is the chip's vendor, which is usually not the
        /// brand printed on the cable.
        case cableIsUSB2(chip: String?)
        /// Everything below a hub that lost SuperSpeed is behind that hub's
        /// problem, not its own. Named so the same cable is not blamed once
        /// per device hanging off it.
        case behindHub(name: String)
        /// The port itself does not carry USB 3. Never true on an Apple
        /// silicon USB-C port, but a Mac is not the only thing this could run
        /// on one day.
        case portHasNoUSB3
        /// Something took it and nothing here can say what. Stated as the two
        /// facts rather than as a guess.
        case unattributed
    }

    /// What the device's own BOS descriptor claims: "10 Gbps", or plain
    /// "SuperSpeed" where it declares the pairs but not a rate.
    let declared: String
    /// The rate the link actually came up at.
    let negotiatedMbps: Double
    let cause: Cause

    /// One line for the device row.
    var summary: String {
        let got = SpeedFormat.usbLabel(mbps: negotiatedMbps)
        switch cause {
        case .displayTookTheLanes:
            return "Claims \(declared), running at \(got) — the display has both high-speed lanes"
        case .cableIsUSB2(let chip):
            // The chip's vendor, not the cable's brand: a PD e-marker has
            // nowhere to publish the name on the jacket. See
            // `CableEMarker.vendorName`.
            let whose = chip.map { " (\($0))" } ?? ""
            return "Claims \(declared), running at \(got) — the cable's own chip\(whose) says USB 2.0"
        case .behindHub(let name):
            return "Claims \(declared), running at \(got) — everything behind \(name) is"
        case .portHasNoUSB3:
            return "Claims \(declared), running at \(got) — this port does not carry USB 3"
        case .unattributed:
            return "Claims \(declared), running at \(got) — something between them is USB 2.0 only"
        }
    }

    /// Whether this is the device to look at, as opposed to one caught behind
    /// something else that is.
    var isRootCause: Bool {
        if case .behindHub = cause { return false }
        return true
    }
}

enum LinkBottleneck {

    /// SuperSpeed starts at 5 Gbps. The tolerance matches `SpeedFormat`'s: a
    /// controller reporting 4.8 or 5.1 Gbps is reporting 5 Gbps.
    private static let superSpeedMbps: Double = 5000

    /// Annotates a device tree with the verdicts, in place.
    ///
    /// The walk carries the nearest ancestor that has itself lost SuperSpeed,
    /// so a hub on USB 2.0 with six devices behind it produces one explanation
    /// and six pointers at it, rather than six separate accusations against the
    /// same cable.
    static func annotate(_ devices: inout [DeviceNode], port: PortInfo?) {
        for index in devices.indices {
            annotate(&devices[index], port: port, behind: nil)
        }
    }

    private static func annotate(_ node: inout DeviceNode, port: PortInfo?, behind hub: String?) {
        node.linkVerdict = verdict(for: node, port: port, behind: hub)
        // A device that lost SuperSpeed becomes the explanation for everything
        // under it, whether or not it is a hub by class: anything downstream of
        // a High Speed link is on a High Speed link.
        let downstream = node.linkVerdict != nil ? node.name : hub
        for index in node.children.indices {
            annotate(&node.children[index], port: port, behind: downstream)
        }
    }

    /// One device's verdict. Pure, so `--selftest` drives exactly this.
    static func verdict(for node: DeviceNode, port: PortInfo?, behind hub: String?) -> LinkVerdict? {
        // Both halves have to be present. A device that published no BOS
        // descriptor, or whose link speed the controller did not report, is one
        // there is nothing to compare. A genuinely USB 2.0 device is the first
        // of those and is meant to fall out here.
        guard let capability = node.speedCapability, capability.supportsSuperSpeed,
              let mbps = node.speedMbps
        else { return nil }
        guard mbps < superSpeedMbps * 0.95 else { return nil }

        // The rate sharpens the wording where the device published one; the
        // verdict itself turns on the SuperSpeed bit either way.
        let declared = capability.declaredGbps
            .map { String(format: "%g Gbps", $0) } ?? "SuperSpeed"
        return LinkVerdict(
            declared: declared,
            negotiatedMbps: mbps,
            cause: cause(port: port, cable: port?.emarker, behind: hub)
        )
    }

    /// Most certain attribution first. Every branch but the last is something
    /// the hardware stated rather than something inferred from it.
    private static func cause(
        port: PortInfo?, cable: CableEMarker?, behind hub: String?
    ) -> LinkVerdict.Cause {
        if let hub { return .behindHub(name: hub) }
        if port?.displayIsUsingAllLanes == true { return .displayTookTheLanes }
        // The cable's chip declaring USB 2.0 is the cable saying it has no
        // SuperSpeed pairs. Only the 2.0 rung counts: a cable claiming 5 Gbps
        // on a link that came up at 480 Mbps is a disagreement, not a cause,
        // and naming it would blame a cable that says it is innocent.
        if let cable, cable.usbSpeed?.hasPrefix("USB 2.0") == true {
            return .cableIsUSB2(chip: cable.vendorName)
        }
        if let port, port.kind == .usbC, !port.transportsSupported.isEmpty,
           !port.transportsSupported.contains("USB3"), !port.transportsSupported.contains("CIO") {
            return .portHasNoUSB3
        }
        return .unattributed
    }
}
