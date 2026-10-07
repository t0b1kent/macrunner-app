import AppKit
import Foundation

#if canImport(Sparkle)
import Sparkle
#endif

/// App, engine and graphics are one signed bundle. Deltas are optional release
/// artifacts, not a property promised by this client.
enum SparkleBootstrap {
    private static var retainedController: AnyObject?
    private static var startupError: String?

    @MainActor
    static func startIfAvailable() {
        let center = UpdateCenter.shared
        #if canImport(Sparkle)
        guard retainedController == nil, isConfigured else { return }
        let controller = SPUStandardUpdaterController(startingUpdater: false,
            updaterDelegate: center, userDriverDelegate: nil)
        retainedController = controller
        // Enforce safety even for a preference saved by an older build.
        controller.updater.automaticallyDownloadsUpdates = false
        do {
            try controller.updater.start()
            startupError = nil
            if center.installationArmed { controller.checkForUpdates(nil) }
        } catch {
            retainedController = nil
            startupError = error.localizedDescription
            center.cycleFinished(error: error)
        }
        #endif
    }

    @MainActor
    static func checkForUpdates() {
        #if canImport(Sparkle)
        guard isConfigured else { return }
        if retainedController == nil { startIfAvailable() }
        if let controller = retainedController as? SPUStandardUpdaterController {
            if controller.updater.canCheckForUpdates { controller.checkForUpdates(nil) }
        } else if let startupError {
            let alert = NSAlert()
            alert.messageText = L("Check for Updates…")
            alert.informativeText = startupError
            alert.runModal()
        }
        #endif
    }

    static var isConfigured: Bool {
        #if canImport(Sparkle)
        return UpdaterService.validatedFeed(info: Bundle.main.infoDictionary ?? [:]) != nil
        #else
        return false
        #endif
    }
}

/// Record namespaces before spawning. Windows children survive MacRunner quitting;
/// per-game TMPDIR overrides change the location of their wineserver socket.
enum GameActivity {
    private static let key = "MacRunnerEngineNamespaces"
    private static let lock = NSLock()

    static func remember(prefix: URL, environment: [String: String], defaults: UserDefaults = .standard) {
        let entry = ["prefix": prefix.path, "tmp": environment["TMPDIR"] ?? "/tmp"]
        lock.lock(); defer { lock.unlock() }
        if defaults.object(forKey: key) != nil, defaults.array(forKey: key) as? [[String: String]] == nil { return }
        var entries = defaults.array(forKey: key) as? [[String: String]] ?? []
        if !entries.contains(entry) { entries.append(entry); defaults.set(entries, forKey: key) }
    }

    static var anyRunning: Bool {
        BottleSetup.hasActiveRuns || recordedActivity()
    }

    static func recordedActivity(defaults: UserDefaults = .standard,
                                 probe: (URL, [String: String]) -> Bool = WineServerProbe.mayBeAlive) -> Bool {
        lock.lock()
        let stored = defaults.object(forKey: key)
        let decoded = stored as? [[String: String]]
        lock.unlock()
        if stored != nil, decoded == nil { return true }
        var entries = decoded ?? []
        entries.append(["prefix": EnginePaths.defaultBottle.path,
                        "tmp": ProcessInfo.processInfo.environment["TMPDIR"] ?? "/tmp"])
        return entries.contains { entry in
            guard let prefix = entry["prefix"], let tmp = entry["tmp"] else { return true }
            return probe(URL(fileURLWithPath: prefix), ["TMPDIR": tmp])
        }
    }
}

@MainActor
final class UpdateCenter: NSObject, ObservableObject {
    static let shared = UpdateCenter()
    @Published private(set) var readyVersion: String?
    @Published private(set) var installationArmed = false
    private var install: (() -> Void)?
    private let gate: UpdateSafetyGate
    private let activity: () -> Bool
    private let defaults: UserDefaults
    private let build: String
    private static let armedKey = "MacRunnerPendingInstallationHostBuild"

    init(gate: UpdateSafetyGate = .shared, activity: @escaping () -> Bool = { GameActivity.anyRunning },
         defaults: UserDefaults = .standard,
         build: String = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "development") {
        self.gate = gate
        self.activity = activity
        self.defaults = defaults
        self.build = build
        super.init()
        if let previousBuild = defaults.string(forKey: Self.armedKey) {
            if previousBuild == build {
                installationArmed = true
                _ = gate.beginUpdate(externalActivity: { false })
            } else {
                defaults.removeObject(forKey: Self.armedKey)
            }
        }
    }

    var isBusy: Bool { gate.hasActivities || activity() }
    var mayTerminate: Bool { !installationArmed || !isBusy }

    func beginCycle() throws {
        guard gate.beginUpdate(externalActivity: activity) else {
            throw NSError(domain: "MacRunner.Update", code: 1, userInfo: [
                NSLocalizedDescriptionKey: L("Close running programs before updating MacRunner.")])
        }
    }

    func armInstallation() {
        installationArmed = true
        defaults.set(build, forKey: Self.armedKey)
    }

    /// Sparkle 2.6.4 calls shouldProceed only on a fresh appcast, never when resuming
    /// its installer. A fresh check resolves a marker from a failed previous install.
    func confirmedFreshCheck() {
        installationArmed = false
        defaults.removeObject(forKey: Self.armedKey)
    }

    func cycleFinished(error: Error?) {
        if error != nil { readyVersion = nil; install = nil }
        // Nil can mean "install on quit". Disconnect/error does not prove the helper
        // stopped either. Retain the lease until a fresh check or a new host build.
        guard !installationArmed else { return }
        readyVersion = nil
        install = nil
        gate.endUpdate()
    }

    func offer(version: String, install: @escaping () -> Void) {
        readyVersion = version
        self.install = install
    }

    @discardableResult
    func installNow() -> Bool {
        guard let action = install, gate.beginUpdate(externalActivity: activity) else { return false }
        install = nil
        readyVersion = nil
        action()
        return true
    }
}

#if canImport(Sparkle)
// Sparkle 2.6.4 delivers delegate calls on the main thread but predates actor annotations.
extension UpdateCenter: @preconcurrency SPUUpdaterDelegate {
    // This admission hook also runs for downloaded/resumable updates.
    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        try beginCycle()
    }

    func updater(_ updater: SPUUpdater, shouldProceedWithUpdate item: SUAppcastItem,
                 updateCheck: SPUUpdateCheck) throws {
        confirmedFreshCheck()
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater, error: Error) {
        confirmedFreshCheck()
    }

    func feedURLString(for updater: SPUUpdater) -> String? {
        UpdaterService.validatedFeed(info: Bundle.main.infoDictionary ?? [:])?.absoluteString
    }

    func allowedChannels(for updater: SPUUpdater) -> Set<String> {
        let settings = ConfigStore.shared.loadSettings()
        return (UpdateChannel(rawValue: settings.updateChannel ?? "stable") ?? .stable).allowedChannels
    }

    // Arm before extraction: the installer can survive the host long before
    // willInstallUpdate is called.
    func updater(_ updater: SPUUpdater, willExtractUpdate item: SUAppcastItem) {
        armInstallation()
    }

    func updater(_ updater: SPUUpdater, willInstallUpdate item: SUAppcastItem) {
        armInstallation()
    }

    func updater(_ updater: SPUUpdater, shouldPostponeRelaunchForUpdate item: SUAppcastItem,
                 untilInvokingBlock installHandler: @escaping () -> Void) -> Bool {
        armInstallation()
        guard isBusy else { return false }
        offer(version: item.displayVersionString, install: installHandler)
        return true
    }

    func updater(_ updater: SPUUpdater, didAbortWithError error: Error) {
        cycleFinished(error: error)
    }

    func updater(_ updater: SPUUpdater, didFinishUpdateCycleFor updateCheck: SPUUpdateCheck, error: Error?) {
        cycleFinished(error: error)
    }
}
#endif

/// Sparkle can skip the relaunch hook when resuming. AppKit's termination veto
/// protects children that appeared outside the launch admission gate.
@MainActor
final class UpdateApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !UpdateCenter.shared.mayTerminate else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = L("Close running programs before updating MacRunner.")
        alert.runModal()
        return .terminateCancel
    }
}
