import Darwin
import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Admission and recovery tests only: no updater network requests or Wine processes.
struct OTAUpdateTests {
    private final class DefaultsFixture {
        let name = "MacRunner.OTA.tests.\(UUID().uuidString)"
        let defaults: UserDefaults

        init() throws {
            defaults = try #require(UserDefaults(suiteName: name))
            defaults.removePersistentDomain(forName: name)
        }

        deinit { defaults.removePersistentDomain(forName: name) }
    }

    private final class Admissions: @unchecked Sendable {
        private let lock = NSLock()
        private var activity: UUID?
        private var update = false

        func record(activity: UUID?) {
            lock.lock(); defer { lock.unlock() }
            self.activity = activity
        }

        func record(update: Bool) {
            lock.lock(); defer { lock.unlock() }
            self.update = update
        }

        func snapshot() -> (UUID?, Bool) {
            lock.lock(); defer { lock.unlock() }
            return (activity, update)
        }
    }

    private var validInfo: [String: Any] {
        ["SUFeedURL": "https://updates.example.invalid/macrunner/appcast.xml",
         // Public-key-shaped validation fixture, never used to sign anything.
         "SUPublicEDKey": Data(repeating: 0, count: 32).base64EncodedString(),
         "SUAllowsAutomaticUpdates": false,
         "SUAutomaticallyUpdate": false]
    }

    @Test func concurrentLaunchAndUpdateHaveExactlyOneAdmission() {
        for _ in 0..<64 {
            let gate = UpdateSafetyGate()
            let result = Admissions()
            DispatchQueue.concurrentPerform(iterations: 2) { index in
                if index == 0 { result.record(activity: gate.beginActivity()) }
                else { result.record(update: gate.beginUpdate(externalActivity: { false })) }
            }
            let (activity, update) = result.snapshot()
            #expect((activity != nil) != update)
            if let activity { gate.endActivity(activity) }
            if update { gate.endUpdate() }
            #expect(!gate.hasActivities)
            #expect(!gate.isUpdating)
        }
    }

    @Test func everyPreparationMustFinishBeforeUpdateAdmission() throws {
        let gate = UpdateSafetyGate()
        let first = try #require(gate.beginActivity())
        let second = try #require(gate.beginActivity())
        #expect(!gate.beginUpdate(externalActivity: { false }))
        gate.endActivity(first)
        gate.endActivity(first) // Duplicate cleanup must not release another run.
        #expect(!gate.beginUpdate(externalActivity: { false }))
        gate.endActivity(second)
        #expect(gate.beginUpdate(externalActivity: { false }))
        #expect(gate.beginActivity() == nil)
        gate.endUpdate()
        #expect(!gate.beginUpdate(externalActivity: { true }))
        #expect(!gate.isUpdating)
    }

    @Test func blockedLauncherDoesNotReachPreparationOrCreateRunFiles() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ota-blocked-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let gate = UpdateSafetyGate()
        #expect(gate.beginUpdate(externalActivity: { false }))
        let engine = BundledEngine(root: root.appendingPathComponent("engine"), name: "fixture", environmentTemplate: [:])
        let prefix = root.appendingPathComponent("prefix")
        let launcher = EngineLauncher(engine: engine, prefix: prefix, gate: gate)
        let plan = GraphicsPlan(arch: nil, api: nil, route: nil, layer: nil,
                                decision: .refuse("This decision must not be reached during update."))
        let result = launcher.run(exe: root.appendingPathComponent("absent.exe"), arguments: [], workdir: nil,
                                  extraEnvironment: [:], runDirectory: root.appendingPathComponent("run"), graphics: plan)
        #expect(result.status == "FAIL")
        #expect(result.error != nil)
        #expect(result.graphicsRoute == nil)
        #expect(!FileManager.default.fileExists(atPath: root.path))
        #expect(!gate.hasActivities)
        #expect(gate.isUpdating)
        gate.endUpdate()
    }

    @Test @MainActor func activePreparationAndExternalActivityRejectCheck() throws {
        let fixture = try DefaultsFixture()
        let gate = UpdateSafetyGate()
        var external = false
        let center = UpdateCenter(gate: gate, activity: { external }, defaults: fixture.defaults, build: "100")
        let preparation = try #require(gate.beginActivity())
        #expect(throws: (any Error).self) { try center.beginCycle() }
        #expect(!gate.isUpdating)
        gate.endActivity(preparation)
        external = true
        #expect(throws: (any Error).self) { try center.beginCycle() }
        external = false
        try center.beginCycle()
        #expect(gate.beginActivity() == nil)
        center.cycleFinished(error: nil)
        #expect(!gate.isUpdating)
    }

    @Test @MainActor func unarmedFailureAndDismissalClearCallbacksAndReleaseAdmission() throws {
        let outcomes: [Error?] = [nil, NSError(domain: "OTA.tests", code: 1)]
        for error in outcomes {
            let fixture = try DefaultsFixture()
            let gate = UpdateSafetyGate()
            let center = UpdateCenter(gate: gate, activity: { false }, defaults: fixture.defaults, build: "100")
            var calls = 0
            try center.beginCycle()
            center.offer(version: "101") { calls += 1 }
            center.cycleFinished(error: error)
            center.cycleFinished(error: error) // Sparkle can report abort and completion.
            #expect(center.readyVersion == nil)
            #expect(!center.installNow())
            #expect(calls == 0)
            #expect(!gate.isUpdating)
            let launch = try #require(gate.beginActivity())
            gate.endActivity(launch)
        }
    }

    @Test @MainActor func armedFinishAndFailureRemainBlockedUntilFreshCheck() throws {
        let fixture = try DefaultsFixture()
        let gate = UpdateSafetyGate()
        let center = UpdateCenter(gate: gate, activity: { false }, defaults: fixture.defaults, build: "100")
        var staleCalls = 0
        try center.beginCycle()
        center.armInstallation()
        center.offer(version: "101") { staleCalls += 1 }
        center.cycleFinished(error: nil)
        #expect(center.installationArmed)
        #expect(gate.beginActivity() == nil)
        center.cycleFinished(error: NSError(domain: "OTA.tests", code: 2))
        #expect(center.readyVersion == nil)
        #expect(!center.installNow())
        #expect(staleCalls == 0)
        #expect(gate.isUpdating)

        try center.beginCycle() // A retry can reuse the retained admission.
        center.confirmedFreshCheck()
        #expect(!center.installationArmed)
        #expect(gate.isUpdating) // Fresh-check proof doesn't finish the current cycle.
        center.cycleFinished(error: nil)
        #expect(!gate.isUpdating)
        let restored = UpdateCenter(gate: UpdateSafetyGate(), activity: { false }, defaults: fixture.defaults, build: "100")
        #expect(!restored.installationArmed)
    }

    @Test @MainActor func armedMarkerSurvivesRestartAndClearsForNewHostBuild() throws {
        let fixture = try DefaultsFixture()
        let original = UpdateCenter(gate: UpdateSafetyGate(), activity: { false }, defaults: fixture.defaults, build: "100")
        try original.beginCycle()
        original.armInstallation()

        let restoredGate = UpdateSafetyGate()
        var survivingGame = true
        let restored = UpdateCenter(gate: restoredGate, activity: { survivingGame }, defaults: fixture.defaults, build: "100")
        #expect(restored.installationArmed)
        #expect(restoredGate.beginActivity() == nil)
        #expect(!restored.mayTerminate)
        #expect(throws: (any Error).self) { try restored.beginCycle() }
        restored.cycleFinished(error: NSError(domain: "OTA.tests", code: 3))
        #expect(restoredGate.isUpdating)
        survivingGame = false
        #expect(restored.mayTerminate)

        let updatedGate = UpdateSafetyGate()
        let updated = UpdateCenter(gate: updatedGate, activity: { false }, defaults: fixture.defaults, build: "101")
        #expect(!updated.installationArmed)
        #expect(!updatedGate.isUpdating)
        let launch = try #require(updatedGate.beginActivity())
        updatedGate.endActivity(launch)
        let reread = UpdateCenter(gate: UpdateSafetyGate(), activity: { false }, defaults: fixture.defaults, build: "101")
        #expect(!reread.installationArmed)
    }

    @Test @MainActor func installCallbackWaitsForIdleAndRunsOnlyOnce() throws {
        let fixture = try DefaultsFixture()
        let gate = UpdateSafetyGate()
        var external = false
        let center = UpdateCenter(gate: gate, activity: { external }, defaults: fixture.defaults, build: "100")
        var calls = 0
        try center.beginCycle()
        center.armInstallation()
        center.offer(version: "101") { calls += 1 }
        external = true
        #expect(!center.installNow())
        #expect(center.readyVersion == "101")
        #expect(!center.mayTerminate)
        external = false
        #expect(center.installNow())
        #expect(!center.installNow())
        #expect(calls == 1)
        #expect(center.readyVersion == nil)
        #expect(gate.isUpdating)
    }

    @Test @MainActor func sparkleOptionalDelegateHooksHaveExactObjectiveCSelectors() throws {
        let fixture = try DefaultsFixture()
        let center = UpdateCenter(gate: UpdateSafetyGate(), activity: { false }, defaults: fixture.defaults, build: "100")
        for selector in ["updater:mayPerformUpdateCheck:error:",
                         "updater:shouldProceedWithUpdate:updateCheck:error:",
                         "updaterDidNotFindUpdate:error:",
                         "updater:willExtractUpdate:",
                         "updater:willInstallUpdate:",
                         "updater:didAbortWithError:",
                         "updater:didFinishUpdateCycleForUpdateCheck:error:",
                         "updater:shouldPostponeRelaunchForUpdate:untilInvokingBlock:",
                         "feedURLStringForUpdater:", "allowedChannelsForUpdater:"] {
            #expect(center.responds(to: NSSelectorFromString(selector)), "Missing Sparkle hook: \(selector)")
        }
    }

    @Test func updaterRequiresHTTPSPublicKeyAndExplicitManualInstallation() {
        #expect(UpdaterService.validatedFeed(info: validInfo)?.scheme == "https")
        for feed in ["http://updates.example.invalid/feed.xml", "file:///tmp/feed.xml",
                     "https:///", "https://user:password@updates.example.invalid/feed.xml",
                     "https://updates.example.invalid/feed.xml#fragment", ""] {
            var info = validInfo
            info["SUFeedURL"] = feed
            #expect(UpdaterService.validatedFeed(info: info) == nil)
        }
        for key in ["", "not-base64", Data(repeating: 0, count: 31).base64EncodedString(),
                    Data(repeating: 0, count: 33).base64EncodedString()] {
            var info = validInfo
            info["SUPublicEDKey"] = key
            #expect(UpdaterService.validatedFeed(info: info) == nil)
        }
        for field in ["SUAllowsAutomaticUpdates", "SUAutomaticallyUpdate"] {
            var info = validInfo
            info[field] = true
            #expect(UpdaterService.validatedFeed(info: info) == nil)
            info.removeValue(forKey: field)
            #expect(UpdaterService.validatedFeed(info: info) == nil)
        }
        #expect(UpdaterService.validatedFeed(info: [:]) == nil)
    }

    @Test func channelsUseOneSignedFeedAndSafeFallback() {
        #expect(UpdateChannel.stable.allowedChannels.isEmpty)
        #expect(UpdateChannel.beta.allowedChannels == Set(["beta"]))
        #expect(UpdateChannel.nightly.allowedChannels == Set(["beta", "nightly"]))
        for channel in UpdateChannel.allCases {
            var settings = AppSettings.default
            settings.updateChannel = channel.rawValue
            let config = UpdaterService().configuration(settings: settings, info: validInfo)
            #expect(config.channel == channel)
            #expect(config.sparkleEnabled)
            #expect(config.appcastURL == UpdaterService.validatedFeed(info: validInfo))
        }
        var settings = AppSettings.default
        settings.updateChannel = "unknown"
        let disabled = UpdaterService().configuration(settings: settings, info: [:])
        #expect(disabled.channel == .stable)
        #expect(!disabled.sparkleEnabled)
        #expect(disabled.appcastURL == nil)
    }

    @Test func cacheIdentityChangesWithEngineOrGraphicsManifestWithoutRemovingOldData() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ota-cache-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = Data(#"{"name":"engine","wine":"one","graphics":"one"}"#.utf8)
        let engineChange = Data(#"{"name":"engine","wine":"two","graphics":"one"}"#.utf8)
        let graphicsChange = Data(#"{"name":"engine","wine":"one","graphics":"two"}"#.utf8)
        let old = EnginePaths.cacheDirectory(manifest: original, under: root)
        try FileManager.default.createDirectory(at: old, withIntermediateDirectories: true)
        let sentinel = old.appendingPathComponent("surviving-game-cache")
        try Data("keep".utf8).write(to: sentinel)
        #expect(EnginePaths.cacheDirectory(manifest: original, under: root) == old)
        #expect(EnginePaths.cacheDirectory(manifest: engineChange, under: root) != old)
        #expect(EnginePaths.cacheDirectory(manifest: graphicsChange, under: root) != old)
        #expect(try Data(contentsOf: sentinel) == Data("keep".utf8))
    }

    @Test func registryPreservesCustomTMPDIRAndMissingTMPDIRFallbackAcrossReads() throws {
        let fixture = try DefaultsFixture()
        let custom = URL(fileURLWithPath: "/tmp/ota-custom-\(UUID().uuidString)")
        let fallback = URL(fileURLWithPath: "/tmp/ota-fallback-\(UUID().uuidString)")
        GameActivity.remember(prefix: custom, environment: ["TMPDIR": "/tmp/custom-wine-namespace"], defaults: fixture.defaults)
        GameActivity.remember(prefix: custom, environment: ["TMPDIR": "/tmp/custom-wine-namespace"], defaults: fixture.defaults)
        GameActivity.remember(prefix: fallback, environment: [:], defaults: fixture.defaults)
        var visits = [String: [String]]()
        #expect(!GameActivity.recordedActivity(defaults: fixture.defaults) { prefix, environment in
            visits[prefix.path, default: []].append(environment["TMPDIR"] ?? "missing")
            return false
        })
        #expect(visits[custom.path] == ["/tmp/custom-wine-namespace"])
        #expect(visits[fallback.path] == ["/tmp"])
        #expect(GameActivity.recordedActivity(defaults: fixture.defaults) { prefix, environment in
            prefix == custom && environment["TMPDIR"] == "/tmp/custom-wine-namespace"
        })
    }

    @Test func malformedNamespaceRegistryFailsClosed() throws {
        let fixture = try DefaultsFixture()
        let key = "MacRunnerEngineNamespaces"
        let malformedValues: [Any] = ["invalid", [["prefix": "/tmp/unknown-prefix"]]]
        for corrupt in malformedValues {
            fixture.defaults.set(corrupt, forKey: key)
            #expect(GameActivity.recordedActivity(defaults: fixture.defaults) { _, _ in false })
            GameActivity.remember(prefix: URL(fileURLWithPath: "/tmp/new-prefix"), environment: [:], defaults: fixture.defaults)
            #expect(GameActivity.recordedActivity(defaults: fixture.defaults) { _, _ in false })
        }
    }

    @Test func socketProbeDistinguishesMissingPrefixFromUnknownFilesystemFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ota-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(!WineServerProbe.mayBeAlive(prefix: root.appendingPathComponent("absent"), environment: [:]))
        let file = root.appendingPathComponent("not-a-directory")
        try Data().write(to: file)
        let invalidPrefix = file.appendingPathComponent("prefix")
        #expect(!WineServerProbe.isAlive(prefix: invalidPrefix, environment: [:]))
        #expect(WineServerProbe.mayBeAlive(prefix: invalidPrefix, environment: [:]))
    }

    @Test func localSocketListenerStaleSocketAndNonSocketHaveSafeVerdicts() throws {
        let root = URL(fileURLWithPath: "/private/tmp/ota-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let prefix = root.appendingPathComponent("p", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let environment = ["TMPDIR": root.path]
        let path = try #require(WineServerProbe.socketPath(prefix: prefix, environment: environment))
        let socketURL = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(at: socketURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        try #require(fd >= 0)
        var closed = false
        defer { if !closed { close(fd) } }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
            raw[bytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        try #require(bound == 0)
        try #require(listen(fd, 4) == 0)
        #expect(WineServerProbe.mayBeAlive(prefix: prefix, environment: environment))
        #expect(WineServerProbe.isAlive(prefix: prefix, environment: environment))

        close(fd)
        closed = true
        #expect(FileManager.default.fileExists(atPath: path))
        #expect(!WineServerProbe.mayBeAlive(prefix: prefix, environment: environment))
        try FileManager.default.removeItem(at: socketURL)
        try Data("not a socket".utf8).write(to: socketURL)
        #expect(!WineServerProbe.isAlive(prefix: prefix, environment: environment))
        #expect(WineServerProbe.mayBeAlive(prefix: prefix, environment: environment))
    }
}
