import Foundation

/// The cable is what is capping the power reaching this Mac.
///
/// Asked for as "does it flag when the cable is what limits charging", and the
/// honest answer is narrower than the question, because the evidence that
/// would settle it is erased by the very thing being tested for. A charger
/// facing a cable it has not confirmed as 5 A is required to offer no more
/// than 3 A at any voltage — USB-IF compliance testing checks exactly that,
/// with a cable emulator limited to 3 A. So a 100 W charger behind a 3 A cable
/// advertises 20 V at 3 A, the same as a 60 W charger does through any cable.
/// Seen on this desk on 15 October: one 100 W charger offered 20 V at 4.99 A
/// and PPS 4.8–21 V over MagSafe, then 20 V at 3 A and PPS 5–21 V at 3 A
/// through a "60 W" C-to-C cable whose chip never answered. The panel then
/// called it a 60 W charger, because every figure the Mac can read follows
/// the offer: `UsbHvcMenu`, the
/// controller's raw PDO words, and the adapter's `Watts`, which is the chosen
/// offer multiplied out (96 W on the dock is 20 V × 4.8 A, 85 W is 20 V ×
/// 4.25 A) rather than anything the brick says about itself. Nothing reachable
/// carries the charger's own rating. The Source_Capabilities_Extended PDP field
/// would, and no capture has ever shown macOS publishing it.
///
/// What can be proven is that the cable is a ceiling the charge is pressed
/// against, and that is what this says. Every one of these has to hold:
///
/// - **The cable's own chip states 3 A.** Not inferred from a 3 A contract —
///   that is the invalid direction `PortInfo.currentRating` documents, and a
///   5 A cable on a 60 W charger negotiates 3 A like any other. And not from
///   silence either. An unmarked cable is limited to 3 A by the Type-C spec,
///   but "no e-marker answered" is not "this cable has no chip", and a charger
///   that never asks the cable clamps to 3 A on its own account, in which case
///   a better cable would change nothing.
/// - **The contract sits exactly at what that carries: 20 V at 3 A.** A 3 A
///   cable is barred from EPR, so 20 V is as high as it goes. A charger whose
///   top offer is 15 V, or 20 V at 2.25 A, is below the cable, and it is the
///   charger that explains the wattage. A contract above 3 A over a chip
///   stating 3 A is the opposite case, and `cableNotes` already says so.
/// - **This Mac would take more.** Its table ceiling has to clear 60 W by
///   more than rounding: the 13" M1 Pro's 61 W is Apple's adapter rating, and
///   a watt above the cap is not a limit anyone could measure. A Mac missing
///   from `MacModel` gets nothing, as everywhere else.
/// - **It is drawing all of it right now.** The one check that is a
///   measurement rather than a rule, and the one that keeps the battery out of
///   it. At an 80% hold this Mac has been seen drawing 27 W and 33 W from a
///   96 W contract with the pack slowly draining, and on 15 October 21.5 W
///   from a 100 W contract against a 34.6 W load. Below the cap, the battery or the load is
///   what is deciding the wattage, so a cable that could carry more than is
///   being taken is not limiting anything. At the cap, a near-full pack, a
///   charge hold and a light load are all ruled out by the fact of the draw.
///   The margin is for the gap between a contract and a measured rail; no
///   capture shows how close an Apple sink gets to a 60 W contract, so it is
///   generous.
///
/// What is left unsaid is whether the charger could give more, and `caveat`
/// says that out loud rather than leaving the line to imply it. "The cable is
/// capping power at 60 W" stays true when the charger is a 60 W charger: both
/// ceilings are then met at once, and replacing only the charger would not
/// raise the wattage either.
///
/// No 3 A e-marker appears in any capture in `probes/`: every chip that has
/// answered on this Mac declares 5 A. The firing case is therefore checked
/// against a fixture assembled by hand from a captured Cable VDO with only its
/// current field changed, and the silent cases against real readings.
///
/// The chip is the rarer of the two ways in. A cable needs an e-marker only
/// to carry more than 3 A or SuperSpeed data, so the plain 60 W charging cable
/// almost everyone owns has nothing to answer with — three of them on this
/// desk, and not one replied. For those the only witness is the charger
/// itself, seen earlier offering more: see `Evidence.sameCharger`.
struct CableLimit: Hashable {
    /// Why the cable, and not something else, is the ceiling.
    enum Evidence: Hashable {
        /// The cable's own chip declares 3 A.
        case chip
        /// This very charger, by serial, has offered this many watts before,
        /// and now offers 3 A through a cable that never claimed 5 A.
        ///
        /// Proof only because the serial makes it the same brick, and because
        /// the bricks that publish one are Apple's, which are single-port: a
        /// multi-port charger lowers its offer when something else plugs into
        /// it, and that would read exactly like this. Hence `isAppleAdapter`
        /// is required before anything is remembered at all. No capture in
        /// `probes/` carries an adapter serial — the third-party brick these
        /// cables were tested on publishes neither maker nor serial — so this
        /// path is checked against fixtures only.
        case sameCharger(bestWatts: Double)
    }

    /// What the cable can carry, which is also what the charge is pinned at.
    let watts: Double
    let amps: Double
    let evidence: Evidence

    /// One line for the charger's card.
    var summary: String {
        switch evidence {
        case .chip:
            return String(format: "This cable is capping power at %.0f W: its chip rates it for "
                          + "%.0f A, and this Mac can take more", watts, amps)
        case .sameCharger(let best):
            return String(format: "This cable is capping power at %.0f W: this charger has "
                          + "offered %.0f W before, and offers %.0f A through this cable",
                          watts, best, amps)
        }
    }

    /// The half of the question the hardware cannot answer, or the reason it
    /// could.
    var caveat: String {
        switch evidence {
        case .chip:
            return String(format: "Whether the charger has more to give cannot be seen from here: "
                          + "through a cable not marked for 5 A a charger offers no more than "
                          + "%.0f A, so a larger charger's offer stops at the same %.0f W.",
                          amps, watts)
        case .sameCharger:
            // "More again", not "the 140 W again": a 140 W offer is EPR, and
            // over USB-C to a Mac that does not take EPR the most a 5 A cable
            // gets back is 100 W.
            return String(format: "A charger offers no more than %.0f A through a cable it cannot "
                          + "confirm for 5 A. A cable whose chip declares 5 A should let it "
                          + "offer more again.", amps)
        }
    }

    /// The current a 3 A e-marker declares, and the highest voltage such a
    /// cable can be asked to carry. EPR's 28 V and up needs a 5 A cable.
    private static let ratedAmps = 3.0
    private static let topVolts = 20.0

    /// Decides it for the port the charger is on. Split from the port so the
    /// captures replay through it, as `cableNotes` is.
    static func verdict(
        port: PortInfo, inputWatts: Double?, macCeilingWatts: Double?,
        chargerBestWatts: Double? = nil
    ) -> CableLimit? {
        verdict(
            isUSBC: port.kind == .usbC,
            hasPDContract: port.hasPDContract,
            emarker: port.emarker,
            contract: port.negotiated,
            inputWatts: inputWatts,
            macCeilingWatts: macCeilingWatts,
            chargerBestWatts: chargerBestWatts
        )
    }

    /// `chargerBestWatts` is the most this same charger has been seen to
    /// offer, from `ChargerMemory`; nil for any charger without a serial.
    static func verdict(
        isUSBC: Bool,
        hasPDContract: Bool,
        emarker: CableEMarker?,
        contract: PowerOption?,
        inputWatts: Double?,
        macCeilingWatts: Double?,
        chargerBestWatts: Double? = nil
    ) -> CableLimit? {
        // MagSafe's cable is Apple's own and answers nothing; a Type-C current
        // advertisement opens no PD session, so nothing asked the cable.
        guard isUSBC, hasPDContract else { return nil }

        let cap = ratedAmps * topVolts
        let evidence: Evidence
        if emarker?.maxAmps == ratedAmps {
            evidence = .chip
        } else if emarker?.maxAmps != 5, let best = chargerBestWatts, best > cap * 1.05 {
            // A chip declaring 5 A rules the cable out: the charger was told
            // it could offer more and did not, so something else is holding
            // it back. Silence, or a chip with no current, leaves the cable
            // as the only thing that changed.
            evidence = .sameCharger(bestWatts: best)
        } else {
            return nil
        }

        // At the cable's cap and no further. The upper bound only keeps the
        // stated figure honest: nothing in SPR offers 3 A above 20 V.
        guard let contract, contract.milliamps <= ratedAmps * 1000,
              contract.watts >= cap * 0.95, contract.watts <= cap * 1.02
        else { return nil }

        guard let ceiling = macCeilingWatts, ceiling > cap * 1.05 else { return nil }
        guard let input = inputWatts, input >= contract.watts * 0.9 else { return nil }

        return CableLimit(watts: cap, amps: ratedAmps, evidence: evidence)
    }

    /// The port the charger is on, where that is unambiguous.
    ///
    /// The measured input is one figure for the whole machine. With contracts
    /// on two ports there is no saying which of them it arrived over, so
    /// nothing is attributed — the same rule `PowerAttribution` applies to
    /// measured VBUS.
    static func chargingPort(in ports: [PortInfo]) -> PortInfo? {
        let charging = ports.filter { $0.isConnected && $0.negotiated != nil }
        return charging.count == 1 ? charging.first : nil
    }
}

/// The most each Apple charger has been seen to offer, by serial.
///
/// The one record of a charger's capability that a cable cannot lower after
/// the fact: once a brick has offered 96 W through a cable that let it, a
/// later 60 W offer from the same serial is the cable talking. Kept in
/// `UserDefaults` beside the connection log, which already keys on serials,
/// and emptied with it by `DeviceModel.clearHistory`.
enum ChargerMemory {
    private static let key = "chargerBestOfferWatts"

    static func bestWatts(forSerial serial: String) -> Double? {
        (UserDefaults.standard.dictionary(forKey: key) as? [String: Double])?[serial]
    }

    /// Only ever raises the figure, so a reading through a poor cable never
    /// overwrites one through a good cable.
    static func record(_ power: PowerSnapshot) {
        guard power.externalConnected, power.isAppleAdapter,
              let serial = power.adapterSerial,
              let offered = power.profiles.map(\.watts).max(), offered > 0
        else { return }
        var stored = UserDefaults.standard.dictionary(forKey: key) as? [String: Double] ?? [:]
        guard offered > (stored[serial] ?? 0) else { return }
        stored[serial] = offered
        UserDefaults.standard.set(stored, forKey: key)
    }

    /// The remembered best for the charger attached now, where it is one
    /// this can vouch for.
    static func bestWatts(for power: PowerSnapshot) -> Double? {
        guard power.isAppleAdapter, let serial = power.adapterSerial else { return nil }
        return bestWatts(forSerial: serial)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
