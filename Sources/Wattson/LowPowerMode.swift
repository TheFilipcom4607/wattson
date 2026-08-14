import Foundation

/// macOS's Low Power Mode, which is the one thing the system's own battery menu
/// does that Wattson could not.
///
/// There is no API for it. It is not in IOKit's public headers, and it is not
/// in the PowerManagement plists either — `pmset` is the entire interface:
/// readable by anybody, writable only by root. Hence the rule below, which is
/// what buys the switch the right to write it without a password every time.
enum LowPowerMode {
    private static let pmset = "/usr/bin/pmset"
    private static let sudo = "/usr/bin/sudo"
    static let sudoersPath = "/etc/sudoers.d/wattson"

    /// The setting, per power source. macOS keeps one for each, and System
    /// Settings' "Only on Battery" is those two disagreeing.
    struct State: Equatable {
        var onBattery: Bool?
        var onCharger: Bool?

        /// False on a Mac with no such setting to have.
        var isSupported: Bool { onBattery != nil || onCharger != nil }

        /// What is actually in force, which is the one the switch shows.
        func inEffect(externalConnected: Bool) -> Bool {
            (externalConnected ? onCharger : onBattery) ?? false
        }

        /// Set on one source but not the other, so a plain on/off switch cannot
        /// tell the whole truth about it.
        var isSplit: Bool {
            guard let onBattery, let onCharger else { return false }
            return onBattery != onCharger
        }
    }

    enum Failure: LocalizedError {
        case cancelled
        /// Root asked for a password, so whatever the rule file says, it is not
        /// doing its job.
        case needsSetup
        case setupFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .cancelled: return nil
            case .needsSetup: return "Permission is not in force. Use the switch again to set it up."
            case .setupFailed(let message): return message
            case .writeFailed(let message): return message
            }
        }
    }

    // MARK: - Reading

    /// About 10 ms, so this is read when the panel opens and after a change —
    /// never on the sampling timer.
    static func read() -> State {
        var state = State()
        guard let output = run(pmset, ["-g", "custom"])?.output else { return state }

        // Settings are listed under a heading per power source.
        var source: Substring?
        for line in output.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            if text.hasPrefix("Battery Power") { source = "battery"; continue }
            if text.hasPrefix("AC Power") { source = "ac"; continue }
            guard text.hasPrefix("lowpowermode") else { continue }
            let on = text.split(separator: " ").last.flatMap { Int($0) }.map { $0 != 0 }
            if source == "battery" { state.onBattery = on }
            if source == "ac" { state.onCharger = on }
        }
        return state
    }

    /// Whether Wattson's rule is installed.
    ///
    /// This looks for the file rather than asking `sudo -n -l` whether the
    /// command is allowed, which was the obvious way and is wrong: listing
    /// stops requiring a password the moment a user has any NOPASSWD rule at
    /// all, so on a machine carrying one for something else entirely it answers
    /// "yes" for every command on the system, this one included. The file is
    /// the only thing that means this rule specifically. `/etc/sudoers.d` is
    /// world readable, so this costs nothing and asks nobody.
    ///
    /// The file being there is not proof it is in force — a `sudoers` that does
    /// not include the directory would leave it inert — so `set` treats being
    /// asked for a password as `needsSetup` rather than trusting this.
    static var isPromptless: Bool {
        FileManager.default.fileExists(atPath: sudoersPath)
    }

    // MARK: - Writing

    /// Both power sources at once, so the switch means what it looks like it
    /// means. Requires `isPromptless`.
    static func set(_ on: Bool) throws {
        guard let result = run(sudo, ["-n", pmset, "-a", "lowpowermode", on ? "1" : "0"]) else {
            throw Failure.writeFailed("Could not run pmset.")
        }
        guard result.status != 0 else { return }
        // `-n` never prompts, so this is sudo saying the rule is not covering
        // this command — the file may be missing, or present and not read.
        if result.output.contains("password is required") { throw Failure.needsSetup }
        throw Failure.writeFailed(
            result.output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "pmset would not set Low Power Mode."
        )
    }

    /// What the rule says, in full, so it can be shown to the user before they
    /// are asked to install it.
    ///
    /// One user, one command, two exact argument lists — no wildcards, so it
    /// cannot be talked into running anything else as root.
    static func rule(for user: String = NSUserName()) -> String {
        """
        # Installed by Wattson so its Low Power Mode switch works without asking
        # for a password every time. It grants one account permission to run one
        # command: pmset setting lowpowermode, and nothing else.
        #
        # Remove it from Wattson's Settings, or by hand:
        #   sudo rm \(sudoersPath)
        \(user) ALL=(root) NOPASSWD: \(pmset) -a lowpowermode 0, \(pmset) -a lowpowermode 1
        """
    }

    /// Installs the rule, asking for an administrator password once.
    ///
    /// Checked with `visudo` before it goes in and again once it is there, and
    /// taken straight back out if the second check fails: a bad file in
    /// `/etc/sudoers.d` can lock the machine out of `sudo` entirely, and this
    /// one is not worth that.
    static func installPromptless() throws {
        let directory = URL(fileURLWithPath: NSTemporaryDirectory())
        let ruleFile = directory.appendingPathComponent("wattson.sudoers")
        let scriptFile = directory.appendingPathComponent("wattson-install.sh")

        do {
            try rule().write(to: ruleFile, atomically: true, encoding: .utf8)
            // Only this user can read the staging directory, and the file is
            // root's the instant it lands.
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o600], ofItemAtPath: ruleFile.path
            )
        } catch {
            throw Failure.setupFailed("Could not write the rule: \(error.localizedDescription)")
        }
        defer {
            try? FileManager.default.removeItem(at: ruleFile)
            try? FileManager.default.removeItem(at: scriptFile)
        }

        // Refuse to hand root anything that does not already parse.
        guard run("/usr/sbin/visudo", ["-cf", ruleFile.path])?.status == 0 else {
            throw Failure.setupFailed("The rule did not pass visudo, so it was not installed.")
        }

        let script = """
        set -e
        /usr/bin/install -m 0440 -o root -g wheel '\(ruleFile.path)' '\(sudoersPath)'
        if ! /usr/sbin/visudo -c >/dev/null 2>&1; then
            /bin/rm -f '\(sudoersPath)'
            exit 2
        fi
        """
        do {
            try script.write(to: scriptFile, atomically: true, encoding: .utf8)
        } catch {
            throw Failure.setupFailed("Could not stage the installer: \(error.localizedDescription)")
        }

        try runAsAdministrator("/bin/sh '\(scriptFile.path)'")
    }

    static func removePromptless() throws {
        try runAsAdministrator("/bin/rm -f '\(sudoersPath)'")
    }

    // MARK: - Running things

    private struct Result {
        let status: Int32
        let output: String
    }

    private static func run(_ path: String, _ arguments: [String]) -> Result? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Result(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    /// The standard macOS authorisation dialog, by way of AppleScript. The
    /// command is a path this code wrote itself, never anything a user typed.
    private static func runAsAdministrator(_ command: String) throws {
        let script = "do shell script \"\(command.replacingOccurrences(of: "\"", with: "\\\""))\" "
            + "with administrator privileges"
        guard let result = run("/usr/bin/osascript", ["-e", script]) else {
            throw Failure.setupFailed("Could not ask for permission.")
        }
        guard result.status != 0 else { return }
        // -128 is the user closing the dialog, which is an answer, not a fault.
        if result.output.contains("-128") { throw Failure.cancelled }
        throw Failure.setupFailed(
            result.output.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                ?? "The change was not made."
        )
    }
}
