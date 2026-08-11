import Foundation
import SwiftUI

/// What has actually been observed about the cable currently in a port.
///
/// macOS does not publish a cable's e-marker — there is no VID, no PID, no
/// declared speed or current rating anywhere in the IORegistry. So nothing here
/// is read off the cable: every fact is either something the hardware
/// negotiated through it, or an admission that it is not yet known.
///
/// Evidence accumulates while a cable stays plugged in, because a cable cannot
/// be shown a charger and a fast drive at the same instant.
struct CableEvidence {
    var isConnected = false
    var portName: String?
    var portID: String?
    var isActiveCable = false
    var isOpticalCable = false
    /// Union of everything the link has carried since this cable went in.
    var transportsSeen: Set<String> = []
    /// The most demanding contract negotiated through the cable.
    var bestContract: PowerOption?
    /// Highest power the Mac has pushed out through it.
    var maxSourcedWatts: Double = 0
    /// What the cable's own chip said, once anything has made the Mac ask.
    var emarker: CableEMarker?

    mutating func absorb(_ port: PortInfo) {
        isConnected = port.isConnected
        portName = port.name
        portID = port.id
        isActiveCable = port.isActiveCable
        isOpticalCable = port.isOpticalCable
        if let found = port.emarker { emarker = found }
        transportsSeen.formUnion(port.transportsActive.filter { $0 != "CC" })
        if let contract = port.negotiated,
           contract.watts > (bestContract?.watts ?? 0) {
            bestContract = contract
        }
        maxSourcedWatts = max(maxSourcedWatts, port.outputWatts ?? 0)
    }
}

/// A single line of the verdict: what was established, how firmly, and — when
/// it could not be — what would establish it.
struct CableFinding: Identifiable {
    enum Confidence {
        case proven    // the hardware negotiated it; not a guess
        case partial   // a floor, not a ceiling
        case untested  // nothing has exercised this yet

        var label: String {
            switch self {
            case .proven: return "proven"
            case .partial: return "at least"
            case .untested: return "untested"
            }
        }
    }

    let id: String
    let label: String
    let value: String
    let confidence: Confidence
    /// What the user could do to turn an untested row into a proven one.
    var hint: String?
}

/// The verdict for one cable.
struct CableAssessment {
    var headline: String
    var summary: String
    var findings: [CableFinding]
    var isConnected: Bool

    /// How far the guided test has got.
    var provedData: Bool
    var provedPower: Bool
}

enum CableAnalysis {

    // MARK: - Data

    /// The fastest thing the link has actually carried.
    ///
    /// A cable can never be shown to be *slower* than what ran over it, but it
    /// can easily be faster than the device on the end — plugging a phone into
    /// a 40 Gbps cable proves only 480 Mbps. So this is always a floor.
    private static func dataFinding(_ evidence: CableEvidence) -> CableFinding {
        // The chip's own claim beats anything inferred, when we can see it.
        if let speed = evidence.emarker?.usbSpeed {
            return CableFinding(
                id: "data", label: "Speed", value: speed,
                confidence: .proven
            )
        }
        if evidence.transportsSeen.contains("CIO") {
            return CableFinding(
                id: "data", label: "Data", value: "Thunderbolt / USB4 — 40 Gbps",
                confidence: .proven
            )
        }
        if evidence.transportsSeen.contains("USB3") {
            return CableFinding(
                id: "data", label: "Data", value: "USB 3.x — 5 Gbps or better",
                confidence: .partial,
                hint: "A Thunderbolt device would show whether it can do 40 Gbps."
            )
        }
        if evidence.transportsSeen.contains("USB2") {
            return CableFinding(
                id: "data", label: "Data", value: "USB 2.0 — 480 Mbps",
                confidence: .partial,
                hint: "That may be the device's limit, not the cable's. Try a SuperSpeed drive."
            )
        }
        return CableFinding(
            id: "data", label: "Data", value: "No data link yet",
            confidence: .untested,
            hint: "Plug a drive, dock or phone into the far end."
        )
    }

    // MARK: - Power

    /// What the cable has been shown to carry.
    ///
    /// The only hard evidence is a PD contract: above 3 A proves a 5 A e-marker,
    /// and anything above 20 V is Extended Power Range, which is only legal over
    /// a 240 W cable. The Mac sourcing power proves nothing — it caps its own
    /// output at 3 A no matter what the cable could take.
    private static func powerFinding(_ evidence: CableEvidence) -> CableFinding {
        if let watts = evidence.emarker?.maxWatts, let volts = evidence.emarker?.maxVolts {
            return CableFinding(
                id: "power", label: "Power",
                value: String(format: "%.0f W — rated to %.0f V", watts, volts),
                confidence: .proven
            )
        }
        guard let contract = evidence.bestContract else {
            return CableFinding(
                id: "power", label: "Power", value: "Nothing negotiated yet",
                confidence: .untested,
                hint: evidence.maxSourcedWatts > 0.05
                    ? "This Mac is feeding the cable, which caps at 3 A and proves nothing. Plug a charger into the far end."
                    : "Plug a USB-C charger into the far end."
            )
        }
        if contract.volts > 21 {
            return CableFinding(
                id: "power", label: "Power", value: "240 W — EPR rated",
                confidence: .proven
            )
        }
        if contract.milliamps > 3000 {
            return CableFinding(
                id: "power", label: "Power",
                value: String(format: "%.0f W — 5 A e-marked", contract.watts),
                confidence: .partial,
                hint: "A 240 W charger would show whether it is EPR rated."
            )
        }
        return CableFinding(
            id: "power", label: "Power",
            value: String(format: "%.0f W", contract.watts),
            confidence: .partial,
            hint: "A higher-wattage charger would push this further."
        )
    }

    // MARK: - Video

    private static func videoFinding(_ evidence: CableEvidence) -> CableFinding {
        if evidence.transportsSeen.contains("DisplayPort") {
            return CableFinding(
                id: "video", label: "Video", value: "DisplayPort alt mode",
                confidence: .proven
            )
        }
        if evidence.transportsSeen.contains("CIO") {
            return CableFinding(
                id: "video", label: "Video", value: "Carried over Thunderbolt",
                confidence: .proven
            )
        }
        return CableFinding(
            id: "video", label: "Video", value: "Not established",
            confidence: .untested,
            hint: "Plug a USB-C monitor into the far end."
        )
    }

    // MARK: - Build

    /// The one thing the registry does state outright about the cable itself.
    private static func buildFinding(_ evidence: CableEvidence) -> CableFinding {
        let kind = evidence.isOpticalCable ? "Optical"
            : (evidence.isActiveCable || evidence.emarker?.isActive == true)
                ? "Active — has its own signal chip"
                : "Passive"
        return CableFinding(id: "build", label: "Build", value: kind, confidence: .proven)
    }

    /// Whether the cable carries an identity chip at all.
    ///
    /// Presence alone is informative: USB-C requires an e-marker before a cable
    /// may carry 5 A, or run USB4 and Thunderbolt. A cable without one is
    /// limited to 3 A and USB 2.0 or 3.x speeds by definition.
    private static func chipFinding(_ evidence: CableEvidence) -> CableFinding {
        guard let emarker = evidence.emarker else {
            return CableFinding(
                id: "chip", label: "Chip", value: "Not interrogated yet",
                confidence: .untested,
                hint: "The chip is only read during a power negotiation. Attach a charger to the far end."
            )
        }
        if emarker.contentsWithheld {
            return CableFinding(
                id: "chip", label: "Chip", value: "Present — contents not published by this Mac",
                confidence: .proven,
                hint: "This Mac reports that the cable has an e-marker but not what it says, so speed and wattage have to be established by negotiation instead."
            )
        }
        let vendor = emarker.vendorID.map { String(format: "VID 0x%04X", $0) }
        return CableFinding(
            id: "chip", label: "Chip",
            value: ["Present, read in full", vendor].compactMap { $0 }.joined(separator: " · "),
            confidence: .proven
        )
    }

    // MARK: - Verdict

    static func assess(_ evidence: CableEvidence) -> CableAssessment {
        guard evidence.isConnected else {
            return CableAssessment(
                headline: "No cable",
                summary: "Plug a USB-C cable into either port to begin.",
                findings: [],
                isConnected: false,
                provedData: false,
                provedPower: false
            )
        }

        let data = dataFinding(evidence)
        let power = powerFinding(evidence)
        let findings = [data, power, videoFinding(evidence), chipFinding(evidence), buildFinding(evidence)]

        let provedData = data.confidence != .untested
        let provedPower = power.confidence != .untested

        return CableAssessment(
            headline: headline(evidence),
            summary: summary(evidence, provedData: provedData, provedPower: provedPower),
            findings: findings,
            isConnected: true,
            provedData: provedData,
            provedPower: provedPower
        )
    }

    /// The best guess, stated as a class of cable.
    private static func headline(_ evidence: CableEvidence) -> String {
        if let speed = evidence.emarker?.usbSpeed {
            return speed.components(separatedBy: " — ").first ?? speed
        }
        if evidence.transportsSeen.contains("CIO") { return "Thunderbolt / USB4" }
        if evidence.transportsSeen.contains("USB3") { return "USB 3.x" }
        if evidence.transportsSeen.contains("USB2") { return "USB 2.0" }
        // A 5 A contract is only legal over an e-marked cable, so this is a
        // real classification rather than a shrug.
        if let contract = evidence.bestContract, contract.milliamps > 3000 {
            return "100 W cable"
        }
        if evidence.bestContract != nil { return "Charging cable" }
        if evidence.emarker != nil { return "E-marked cable" }
        return "Cable detected"
    }

    private static func summary(_ evidence: CableEvidence, provedData: Bool, provedPower: Bool) -> String {
        switch (provedData, provedPower) {
        case (true, true):
            return "Both ends tested. This is a floor, not a ceiling — a faster device or charger could prove more."
        case (true, false):
            return "Data tested. Power has not been exercised yet."
        case (false, true):
            return "Power tested. No data has crossed this cable yet."
        case (false, false):
            return "Nothing has crossed this cable yet. Run the guided test to find out what it can do."
        }
    }
}

// MARK: - Guided test

/// The guided test, as a short sequence of things to physically do.
struct CableTestStep: Identifiable {
    enum State { case done, current, pending }

    let id: String
    let title: String
    let instruction: String
    var state: State
}

@MainActor
final class CableTestModel: ObservableObject {
    @Published private(set) var evidence = CableEvidence()
    @Published private(set) var assessment = CableAssessment(
        headline: "No cable", summary: "", findings: [],
        isConnected: false, provedData: false, provedPower: false
    )
    /// Which port the user is testing, when both are occupied.
    @Published var pinnedPortID: String?
    @Published var isGuided = false

    /// Ports with something in them, for the picker.
    @Published private(set) var candidates: [PortInfo] = []

    func update(ports: [PortInfo]) {
        candidates = ports.filter { $0.kind == .usbC }

        let connected = candidates.filter(\.isConnected)
        // Stick with the pinned port if it is still occupied, else take
        // whichever one has a cable in it.
        let target = connected.first { $0.id == pinnedPortID } ?? connected.first

        guard let target else {
            // Everything unplugged: the next cable is a different cable, so the
            // accumulated evidence has to go.
            if evidence.isConnected || evidence.portID != nil { evidence = CableEvidence() }
            assessment = CableAnalysis.assess(evidence)
            return
        }

        // A different port, or a replug, means a new cable.
        if evidence.portID != target.id { evidence = CableEvidence() }
        evidence.absorb(target)
        assessment = CableAnalysis.assess(evidence)
    }

    func restart() {
        evidence = CableEvidence()
        assessment = CableAnalysis.assess(evidence)
    }

    var steps: [CableTestStep] {
        let connected = evidence.isConnected
        let power = assessment.provedPower
        let data = assessment.provedData

        return [
            CableTestStep(
                id: "connect",
                title: "Plug the cable into this Mac",
                instruction: "Either USB-C port. Leave the far end free for now.",
                state: connected ? .done : .current
            ),
            CableTestStep(
                id: "power",
                title: "Attach a charger to the far end",
                instruction: "The contract it negotiates is the only proof of what the cable can carry. A higher-wattage charger proves more.",
                state: power ? .done : (connected ? .current : .pending)
            ),
            CableTestStep(
                id: "data",
                title: "Attach the fastest device you own",
                instruction: "A Thunderbolt drive or dock. Whatever link it negotiates is a floor for the cable.",
                state: data ? .done : (power ? .current : .pending)
            )
        ]
    }
}
