import Foundation
import Testing
@testable import MacRunnerControlCenter

@Suite struct CalculationAccuracyTests {
    static let manifest: [String: Any] = ["calculationAccuracy": [
        "schema": 1,
        "fast": ["FEX_X87REDUCEDPRECISION": "1", "HBDX9_QUERY_PREDICT": "1"],
        "exact": ["FEX_X87REDUCEDPRECISION": "0", "HBDX9_QUERY_PREDICT": "0"]]]
    static let sets = CalculationAccuracySets.load(manifest: manifest)!

    @Test func storedChoiceKeepsOldEntriesAutomatic() {
        #expect(CalculationAccuracy(stored: nil) == .automatic)
        #expect(CalculationAccuracy(stored: "nonsense") == .automatic)
        #expect(CalculationAccuracy(stored: "exact") == .exact)
        #expect(CalculationAccuracy.automatic.stored == nil)
        #expect(CalculationAccuracy.fast.stored == "fast")
    }

    @Test func oldLibraryEntriesDecodeWithoutTheNewFields() throws {
        let entry = AppEntry.new(name: "Game", exePath: "/tmp/game.exe")
        var object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(entry)) as? [String: Any])
        for key in ["calculationAccuracy", "lastCalculationAccuracy", "earlyFailureStreak", "accuracyOfferShown"] { object[key] = nil }
        let decoded = try JSONDecoder().decode(AppEntry.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(decoded.calculationAccuracy == nil)
        #expect(decoded.earlyFailureStreak == nil)
        #expect(decoded.accuracyOfferShown == nil)
    }

    @Test func engineDescriptionIsTakenWholeOrNotAtAll() {
        #expect(Self.sets.exact == ["FEX_X87REDUCEDPRECISION": "0", "HBDX9_QUERY_PREDICT": "0"])
        #expect(CalculationAccuracySets.load(manifest: [:]) == nil)
        // A partly described set is worse than none: different key lists, equal sets, wrong schema, loader keys.
        let bad: [[String: Any]] = [
            ["schema": 1, "fast": ["A": "1"], "exact": ["A": "0", "B": "0"]],
            ["schema": 1, "fast": ["A": "1"], "exact": ["A": "1"]],
            ["schema": 2, "fast": ["A": "1"], "exact": ["A": "0"]],
            ["schema": 1, "fast": [String: String](), "exact": [String: String]()],
            ["schema": 1, "fast": ["DYLD_LIBRARY_PATH": "/x"], "exact": ["DYLD_LIBRARY_PATH": "/y"]],
            ["schema": 1, "fast": ["A B": "1"], "exact": ["A B": "0"]],
            ["schema": 1, "fast": ["A": 1], "exact": ["A": 0]]]
        for object in bad { #expect(CalculationAccuracySets.load(manifest: ["calculationAccuracy": object]) == nil) }
    }

    @Test func automaticAddsNothingAndExplicitChoiceAddsTheWholeSet() {
        let entry = ["MANUAL": "x"]
        #expect(CalculationAccuracyPolicy.entryEnvironment(choice: .automatic, sets: Self.sets, entry: entry) == entry)
        #expect(CalculationAccuracyPolicy.entryEnvironment(choice: .exact, sets: Self.sets, entry: entry)
                == ["MANUAL": "x", "FEX_X87REDUCEDPRECISION": "0", "HBDX9_QUERY_PREDICT": "0"])
        #expect(CalculationAccuracyPolicy.entryEnvironment(choice: .fast, sets: Self.sets, entry: [:]) == Self.sets.fast)
        // Keys typed into the entry by hand stay the most specific.
        #expect(CalculationAccuracyPolicy.entryEnvironment(choice: .exact, sets: Self.sets, entry: ["HBDX9_QUERY_PREDICT": "1"])
                == ["FEX_X87REDUCEDPRECISION": "0", "HBDX9_QUERY_PREDICT": "1"])
        // An engine without a description: the stored choice changes nothing.
        #expect(CalculationAccuracyPolicy.entryEnvironment(choice: .exact, sets: nil, entry: entry) == entry)
    }

    @Test func effectiveModeNamesWhatTheLaunchUsed() {
        let exact = Self.sets.exact
        #expect(CalculationAccuracyPolicy.effective(choice: .automatic, sets: Self.sets, launchEnvironment: [:]) == "auto")
        #expect(CalculationAccuracyPolicy.effective(choice: .automatic, sets: Self.sets, launchEnvironment: exact) == "auto-exact")
        #expect(CalculationAccuracyPolicy.effective(choice: .automatic, sets: Self.sets,
                                                    launchEnvironment: ["FEX_X87REDUCEDPRECISION": "0"]) == "auto")
        #expect(CalculationAccuracyPolicy.effective(choice: .fast, sets: Self.sets, launchEnvironment: exact) == "fast")
        #expect(CalculationAccuracyPolicy.effective(choice: .exact, sets: Self.sets, launchEnvironment: [:]) == "exact")
        #expect(CalculationAccuracyPolicy.effective(choice: .exact, sets: nil, launchEnvironment: [:]) == "unavailable")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["APP32_ENGINE_ROOT"] != nil))
    func explicitChoiceWinsOverEngineDefaultsOnlyForThatLaunch() throws {
        let root = try #require(ProcessInfo.processInfo.environment["APP32_ENGINE_ROOT"])
        let engine = try #require(BundledEngine.load(from: URL(fileURLWithPath: root)))
        let launcher = EngineLauncher(engine: engine, prefix: FileManager.default.temporaryDirectory.appendingPathComponent("accuracy-\(UUID().uuidString)"))
        let base = launcher.makeEnvironment(extra: [:], inherited: [:])
        let extra = CalculationAccuracyPolicy.entryEnvironment(choice: .exact, sets: Self.sets, entry: [:])
        let exact = launcher.makeEnvironment(extra: extra, inherited: [:])
        for (key, value) in Self.sets.exact { #expect(exact[key] == value) }
        var a = base, b = exact
        for key in Self.sets.exact.keys { a[key] = nil; b[key] = nil }
        #expect(a == b)
        let automatic = CalculationAccuracyPolicy.entryEnvironment(choice: .automatic, sets: Self.sets, entry: [:])
        #expect(launcher.makeEnvironment(extra: automatic, inherited: [:]) == base)
    }

    @Test func fastIsOfferedToThirtyTwoBitProgramsOnly() throws {
        #expect(CalculationAccuracy.choices(for: .x86) == [.automatic, .fast, .exact])
        #expect(CalculationAccuracy.choices(for: .x86_64) == [.automatic, .exact])
        #expect(CalculationAccuracy.choices(for: .arm64) == [.automatic, .exact])
        #expect(CalculationAccuracy.choices(for: nil) == [.automatic, .exact])
        // A stored Fast does not apply to a 64-bit program; Exact and Automatic are unaffected.
        #expect(CalculationAccuracy.applicable(stored: "fast", arch: .x86) == .fast)
        #expect(CalculationAccuracy.applicable(stored: "fast", arch: .x86_64) == .automatic)
        #expect(CalculationAccuracy.applicable(stored: "fast", arch: nil) == .automatic)
        #expect(CalculationAccuracy.applicable(stored: "exact", arch: .x86_64) == .exact)
        #expect(CalculationAccuracy.applicable(stored: nil, arch: .x86) == .automatic)
        // The architecture comes from the program's own PE header.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("accuracy-arch-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let game32 = directory.appendingPathComponent("game32.exe"), game64 = directory.appendingPathComponent("game64.exe")
        try FakePE.make(machine: 0x14c, imports: ["d3d9.dll"]).write(to: game32)
        try FakePE.make(machine: 0x8664, imports: ["d3d11.dll"]).write(to: game64)
        #expect(CalculationAccuracy.guestArch(exePath: game32.path) == .x86)
        #expect(CalculationAccuracy.guestArch(exePath: game64.path) == .x86_64)
        #expect(CalculationAccuracy.guestArch(exePath: directory.appendingPathComponent("missing.exe").path) == nil)
        // With a stored Fast, a 64-bit launch gets no set at all; a 32-bit launch gets the Fast set.
        let fast64 = CalculationAccuracy.applicable(stored: "fast", arch: CalculationAccuracy.guestArch(exePath: game64.path))
        #expect(CalculationAccuracyPolicy.entryEnvironment(choice: fast64, sets: Self.sets, entry: [:]).isEmpty)
        let fast32 = CalculationAccuracy.applicable(stored: "fast", arch: CalculationAccuracy.guestArch(exePath: game32.path))
        #expect(CalculationAccuracyPolicy.entryEnvironment(choice: fast32, sets: Self.sets, entry: [:]) == Self.sets.fast)
    }

    @Test func technicalDetailsNameTheModeOfTheLastLaunch() {
        #expect(GameTechnicalDetails.accuracyText(nil) == nil)
        #expect(GameTechnicalDetails.accuracyText("unavailable") == nil)
        for mode in ["auto", "auto-exact", "fast", "exact"] { #expect(GameTechnicalDetails.accuracyText(mode) != nil) }
        #expect(GameTechnicalDetails.accuracyText("exact") != GameTechnicalDetails.accuracyText("auto-exact"))
    }

    private func result(_ status: String, code: Int?, lifetime: Int?) -> LauncherResult {
        var result = LauncherResult()
        result.status = status
        result.exitCode = code
        result.processLifetimeMs = lifetime
        return result
    }

    @Test func earlyFailureIsAStartedProgramThatFailedWithinThirtySeconds() {
        #expect(EarlyFailureOffer.isEarlyFailure(result("FAIL", code: 5, lifetime: 4_000)))
        #expect(!EarlyFailureOffer.isEarlyFailure(result("FAIL", code: 5, lifetime: 30_000)))
        #expect(!EarlyFailureOffer.isEarlyFailure(result("FAIL", code: 5, lifetime: nil)))   // never started
        #expect(!EarlyFailureOffer.isEarlyFailure(result("FAIL", code: nil, lifetime: 4_000)))
        #expect(!EarlyFailureOffer.isEarlyFailure(result("PASS", code: 0, lifetime: 4_000)))
        #expect(!EarlyFailureOffer.isEarlyFailure(result("STOPPED", code: 1, lifetime: 4_000)))
        #expect(!EarlyFailureOffer.isEarlyFailure(nil))
    }

    @Test func offerComesOnceAfterTwoEarlyFailuresInARow() {
        let crash = result("FAIL", code: 5, lifetime: 3_000)
        var offer = EarlyFailureOffer(streak: 0, offered: false)
        let asked1 = offer.record(result: crash, choice: .automatic, usedExact: false, available: true)
        #expect(!asked1)
        let asked2 = offer.record(result: crash, choice: .automatic, usedExact: false, available: true)
        #expect(asked2)
        #expect(offer == EarlyFailureOffer(streak: 2, offered: true))
        // Asked once: further failures do not ask again.
        let asked3 = offer.record(result: crash, choice: .automatic, usedExact: false, available: true)
        #expect(!asked3)
    }

    @Test func offerIsNotMadeWhenItCannotHelpOrWasInterrupted() {
        let crash = result("FAIL", code: 5, lifetime: 3_000)
        func twice(choice: CalculationAccuracy, usedExact: Bool, available: Bool) -> Bool {
            var offer = EarlyFailureOffer(streak: 0, offered: false)
            _ = offer.record(result: crash, choice: choice, usedExact: usedExact, available: available)
            return offer.record(result: crash, choice: choice, usedExact: usedExact, available: available)
        }
        #expect(!twice(choice: .exact, usedExact: false, available: true))      // already exact by the player's choice
        #expect(!twice(choice: .fast, usedExact: false, available: true))       // the player chose; do not argue
        #expect(!twice(choice: .automatic, usedExact: true, available: true))   // the profile already uses Exact
        #expect(!twice(choice: .automatic, usedExact: false, available: false)) // engine has no description
        // A good run between two failures ends the streak; a stop by the user does not.
        var offer = EarlyFailureOffer(streak: 0, offered: false)
        _ = offer.record(result: crash, choice: .automatic, usedExact: false, available: true)
        _ = offer.record(result: result("PASS", code: 0, lifetime: 600_000), choice: .automatic, usedExact: false, available: true)
        #expect(offer.streak == 0)
        let asked4 = offer.record(result: crash, choice: .automatic, usedExact: false, available: true)
        #expect(!asked4)
        _ = offer.record(result: result("STOPPED", code: nil, lifetime: 2_000), choice: .automatic, usedExact: false, available: true)
        #expect(offer.streak == 1)
        let asked5 = offer.record(result: crash, choice: .automatic, usedExact: false, available: true)
        #expect(asked5)
    }

    @Test func wordingExistsInBothReviewedLanguages() throws {
        let keys = ["Calculation accuracy", "Automatic (recommended) — MacRunner picks what this game needs",
                    "Fast — same approach as Windows on Arm", "Exact — as on an Intel/AMD processor, noticeably slower",
                    "Change this only if the game misbehaves: crashes at launch, freezes, or has broken sound or physics. This mode does not improve speed or graphics — the game will run slower.",
                    "This game uses Exact mode.", "Did it help? Tell us and we'll turn it on for this game for everyone.", "Advanced",
                    "The game closed right after launch twice. Try Exact calculation mode? It is slower.", "Try it", "Not now",
                    "Fast", "Exact", "Exact (game profile)", "Auto"]
        for language in ["en", "ru", "de", "es", "fr", "it", "ja", "ko", "pl", "pt-BR", "tr", "zh-Hans"] {
            let url = try #require(Bundle.appResources.url(forResource: "Localizable", withExtension: "strings", subdirectory: nil, localization: language))
            let table = try #require(NSDictionary(contentsOf: url) as? [String: String])
            for key in keys { #expect(!(table[key] ?? "").isEmpty, "\(language): \(key)") }
            // The name must not promise an improvement.
            #expect(!(table["Calculation accuracy"] ?? "").lowercased().contains("compatib"))
            #expect(!(table["Calculation accuracy"] ?? "").lowercased().contains("совместим"))
        }
    }
}
