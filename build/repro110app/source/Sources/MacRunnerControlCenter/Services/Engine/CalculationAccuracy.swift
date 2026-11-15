import Foundation

/// Per-game setting "Calculation accuracy" (owner's decision, 12.11.2026).
/// Automatic leaves the choice to the game's bundled profile and the engine defaults.
/// Fast and Exact apply one named set from the engine description as a whole, never single keys:
/// the set lists only optimisations that change results, so Exact does not slow everything down.
enum CalculationAccuracy: String, CaseIterable, Sendable {
    case automatic = "auto"
    case fast
    case exact

    init(stored: String?) { self = stored.flatMap(CalculationAccuracy.init(rawValue:)) ?? .automatic }

    /// What the library entry keeps: nothing for Automatic, so old and untouched entries stay equal.
    var stored: String? { self == .automatic ? nil : rawValue }

    /// Positions offered for a program. Fast is offered to 32-bit programs only: the safety keys that accompany
    /// reduced x87 precision exist only in the 32-bit translator, so a 64-bit program gets Automatic and Exact.
    /// A program whose architecture cannot be read is treated like a 64-bit one.
    static func choices(for arch: GuestArch?) -> [CalculationAccuracy] {
        arch == .x86 ? [.automatic, .fast, .exact] : [.automatic, .exact]
    }

    /// The stored choice as it applies to this program: a position that is not offered falls back to Automatic.
    static func applicable(stored: String?, arch: GuestArch?) -> CalculationAccuracy {
        let choice = CalculationAccuracy(stored: stored)
        return choices(for: arch).contains(choice) ? choice : .automatic
    }

    /// Architecture from the PE header of the program (headers only); nil when the file is not a readable PE.
    static func guestArch(exePath: String) -> GuestArch? {
        (try? PEImportReader.read(URL(fileURLWithPath: exePath))).flatMap { GuestArch(machine: $0.machine) }
    }
}

/// The two named sets of ENGINE.json:
/// `"calculationAccuracy": {"schema": 1, "fast": {KEY: VALUE, …}, "exact": {KEY: VALUE, …}}`.
/// Both sets must name the same keys. An engine without a valid description offers no choice.
struct CalculationAccuracySets: Sendable, Equatable {
    let fast: [String: String]
    let exact: [String: String]

    static func load(manifest: [String: Any]) -> CalculationAccuracySets? {
        guard let object = manifest["calculationAccuracy"] as? [String: Any],
              object["schema"] as? Int == 1,
              let fast = object["fast"] as? [String: String],
              let exact = object["exact"] as? [String: String],
              !exact.isEmpty, Set(fast.keys) == Set(exact.keys), fast != exact,
              exact.keys.allSatisfy(isEngineKey)
        else { return nil }
        return CalculationAccuracySets(fast: fast, exact: exact)
    }

    /// Library and loader settings are never part of an accuracy set.
    private static func isEngineKey(_ key: String) -> Bool {
        !key.isEmpty && !EngineLauncher.isNativeLoaderSetting(key) && key != "WINEPREFIX" && key != "PATH"
            && key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }
    }

    func environment(for choice: CalculationAccuracy) -> [String: String] {
        switch choice {
        case .automatic: return [:]
        case .fast: return fast
        case .exact: return exact
        }
    }

    /// True when a launch environment already carries the whole Exact set (a game profile chose it).
    func isExact(_ environment: [String: String]) -> Bool {
        exact.allSatisfy { environment[$0.key] == $0.value }
    }
}

enum CalculationAccuracyPolicy {
    /// Keys of the game entry for one launch. Order of the whole launch: engine defaults, graphics layer,
    /// bundled game profile, then this dictionary. An explicit Fast or Exact replaces what the profile chose;
    /// keys typed into the entry by hand stay the most specific and win over the set.
    static func entryEnvironment(choice: CalculationAccuracy, sets: CalculationAccuracySets?,
                                 entry: [String: String]) -> [String: String] {
        guard let sets else { return entry }
        return sets.environment(for: choice).merging(entry) { _, manual in manual }
    }

    /// The mode a launch really uses, for the run record and problem reports.
    static func effective(choice: CalculationAccuracy, sets: CalculationAccuracySets?,
                          launchEnvironment: [String: String]) -> String {
        guard let sets else { return "unavailable" }
        switch choice {
        case .fast, .exact: return choice.rawValue
        case .automatic: return sets.isExact(launchEnvironment) ? "auto-exact" : "auto"
        }
    }
}

/// "Try Exact?" is offered once, never applied silently: two early failures of the same game in a row,
/// while the setting is Automatic and the launch did not already use the Exact set.
struct EarlyFailureOffer: Equatable, Sendable {
    static let failuresInARow = 2
    static let earlyMilliseconds = 30_000

    var streak: Int
    var offered: Bool

    /// The program started, lived less than 30 seconds and ended with a failure code. A stop by the user,
    /// a refusal before the program started and a clean exit are not early failures.
    static func isEarlyFailure(_ result: LauncherResult?) -> Bool {
        guard let result, result.status == "FAIL", let code = result.exitCode, code != 0,
              let lifetime = result.processLifetimeMs, lifetime < earlyMilliseconds else { return false }
        return true
    }

    /// Returns true when the question should be shown now.
    mutating func record(result: LauncherResult?, choice: CalculationAccuracy, usedExact: Bool, available: Bool) -> Bool {
        guard Self.isEarlyFailure(result) else {
            // A stop by the user says nothing; any other outcome ends the run of failures.
            if result?.status != "STOPPED" { streak = 0 }
            return false
        }
        streak += 1
        guard available, choice == .automatic, !usedExact, !offered, streak >= Self.failuresInARow else { return false }
        offered = true
        return true
    }
}
