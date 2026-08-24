import Foundation

/// Why a device did not get the link it says it is capable of.
///
/// Wattson already reads both halves of this and has never put them next to
/// each other: `bcdUSB` is the specification the device declares conformance
/// to, and `UsbLinkSpeed` is the rate its link actually came up at. A device
/// declaring USB 3.x that enumerated at 480 Mbps has demonstrably not got its
/// SuperSpeed pairs, and that is the whole of "why is the dock's ethernet
/// crawling" — a question the panel could show every number relevant to
/// without ever answering.
///
/// The test is a tier test rather than a rate test, and deliberately so.
/// `bcdUSB` states which specification a device conforms to, not how fast it
/// is: a USB 3.2 device is entitled to run at 5 Gbps and plenty do, so
/// "declared 3.2, negotiated 5 Gbps" is evidence of nothing. Falling all the
/// way back to High Speed is different — there is no reading of that where the
/// SuperSpeed pairs are working.
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
        case cableIsUSB2(vendor: String?)
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

    /// The specification the device declares, as it declares it: "USB 3.2".
    let declared: String
    /// The rate the link actually came up at.
    let negotiatedMbps: Double
    let cause: Cause

    /// One line for the device row.
    var summary: String {
        let got = SpeedFormat.usbLabel(mbps: negotiatedMbps)
        switch cause {
        case .displayTookTheLanes:
            return "Declares \(declared), running at \(got) — the display has both high-speed lanes"
        case .cableIsUSB2(let vendor):
            let whose = vendor.map { "\($0) cable" } ?? "cable"
            return "Declares \(declared), running at \(got) — the \(whose)'s own chip says USB 2.0"
        case .behindHub(let name):
            return "Declares \(declared), running at \(got) — everything behind \(name) is"
        case .portHasNoUSB3:
            return "Declares \(declared), running at \(got) — this port does not carry USB 3"
        case .unattributed:
            return "Declares \(declared), running at \(got) — something between them is USB 2.0 only"
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
        // Both halves have to be present. A device that declares no
        // specification, or whose link speed the controller did not report, is
        // one there is nothing to compare.
        guard let bcd = node.usbSpecBCD, let mbps = node.speedMbps else { return nil }
        guard bcd >= 0x0300 else { return nil }
        guard mbps < superSpeedMbps * 0.95 else { return nil }

        let declared = SpeedFormat.usbVersion(bcd: bcd)
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
            return .cableIsUSB2(vendor: cable.vendorName)
        }
        if let port, port.kind == .usbC, !port.transportsSupported.isEmpty,
           !port.transportsSupported.contains("USB3"), !port.transportsSupported.contains("CIO") {
            return .portHasNoUSB3
        }
        return .unattributed
    }
}
