import Foundation

/// What this particular Mac can take in over USB-C.
///
/// This is a table, and it is a table reluctantly. The machine publishes plenty
/// about the adapter attached to it and nothing at all about its own ceiling —
/// `AppleHPMInterface` exposes no sink capabilities, and `AppleSmartBattery`
/// only describes the charger it can currently see. So the figure below is
/// Apple's published fast-charge rating per model, not something read off the
/// hardware, and it is the one number in this app that could go stale without
/// anything noticing.
///
/// Which is why an unknown model reports nothing rather than a guess: a machine
/// missing from this table is a machine nobody has checked, and inventing a
/// ceiling for it would be worse than staying quiet.
enum MacModel {
    /// "Mac16,12" — the identifier every spec table is keyed by.
    static let identifier: String = {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        sysctlbyname("hw.model", &bytes, &size, nil, 0)
        return String(cString: bytes)
    }()

    /// The most this Mac will draw to charge, whatever you plug into it.
    ///
    /// Nil on desktops, which have no battery to charge over USB-C, and on any
    /// laptop not in the table.
    static var maximumChargeWatts: Double? { chargeCeilings[identifier] }

    /// Apple silicon portables, by model identifier. Desktops are deliberately
    /// absent rather than zero: the question does not apply to them.
    private static let chargeCeilings: [String: Double] = [
        // MacBook Air
        "MacBookAir10,1": 30,   // M1, 13"
        "Mac14,2": 67,          // M2, 13"
        "Mac14,15": 70,         // M2, 15"
        "Mac15,12": 70,         // M3, 13"
        "Mac15,13": 70,         // M3, 15"
        "Mac16,12": 70,         // M4, 13"
        "Mac16,13": 70,         // M4, 15"

        // MacBook Pro 13"
        "MacBookPro17,1": 61,   // M1
        "Mac14,7": 67,          // M2

        // MacBook Pro 14"
        "MacBookPro18,3": 96,   // M1 Pro
        "MacBookPro18,4": 96,   // M1 Max
        "Mac14,5": 96,          // M2 Pro
        "Mac14,9": 96,          // M2 Max
        "Mac15,3": 70,          // M3
        "Mac15,6": 96,          // M3 Pro
        "Mac15,8": 96,          // M3 Max
        "Mac15,10": 96,         // M3 Max
        "Mac16,1": 70,          // M4
        "Mac16,6": 96,          // M4 Pro
        "Mac16,8": 96,          // M4 Max

        // MacBook Pro 16"
        "MacBookPro18,1": 140,  // M1 Pro
        "MacBookPro18,2": 140,  // M1 Max
        "Mac14,6": 140,         // M2 Max
        "Mac14,10": 140,        // M2 Pro
        "Mac15,7": 140,         // M3 Pro
        "Mac15,9": 140,         // M3 Max
        "Mac15,11": 140,        // M3 Max
        "Mac16,5": 140,         // M4 Pro
        "Mac16,7": 140          // M4 Max
    ]
}
