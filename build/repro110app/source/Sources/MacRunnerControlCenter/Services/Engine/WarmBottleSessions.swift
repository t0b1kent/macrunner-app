import CryptoKit
import Darwin
import Foundation

/// Owned foreground wineserver, separate from the lifetime of a Windows program job.
/// opt-in only; release metadata must declare the no-network wineboot capability.
enum WarmBottleSessions {
    private final class Entry {
        let signature: String
        let backend: Backend
        let state: WarmSessionState
        init(key: String, signature: String, backend: Backend) {
            self.signature = signature
            self.backend = backend
            state = WarmSessionState(prepare: backend.prepare, stop: backend.stop, isAlive: backend.isAlive,
                                     idleTimeout: WarmBottleSessions.idleTimeout,
                                     idleDidClose: { state in retireIdle(key: key, state: state) })
        }
    }
    private final class Backend {
        let engine: BundledEngine, prefix: URL, log: EngineLog
        let environment: [String: String], layer: GraphicsLayer?
        let emulateModeset: Bool?, cdromDataFilename: String?, gameDirectory: URL?
        private var server: Process?
        private var lifetimeWriter: FileHandle?
        private var ownsSetup = false
        private var cancelled = false
        private let lock = NSLock()
        init(engine: BundledEngine, prefix: URL, environment: [String: String], layer: GraphicsLayer?, log: EngineLog,
             emulateModeset: Bool?, cdromDataFilename: String?, gameDirectory: URL?) throws {
            self.engine = engine; self.prefix = prefix; self.environment = environment; self.layer = layer
            self.emulateModeset = emulateModeset; self.cdromDataFilename = cdromDataFilename
            self.gameDirectory = gameDirectory
            // A session outlives each game's log. Keep its own bounded collector alive.
            let file = log.url.deletingLastPathComponent().appendingPathComponent("warm-session-\(UUID().uuidString).log")
            self.log = try EngineLog(url: file)
            log.note("warm session log: \(file.lastPathComponent)")
        }
        func isAlive() -> Bool { lock.lock(); defer { lock.unlock() }; return server?.isRunning == true }
        func prepare() throws {
            log.mark("warmPrepareBegin")
            guard !WineServerProbe.mayBeAlive(prefix: prefix, environment: environment) else {
                throw NSError(domain: "MacRunner.Warm", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bottle already has an unowned Wine session."])
            }
            lock.lock(); ownsSetup = true; let stopped = cancelled; lock.unlock()
            if stopped { throw WarmSessionState.Failure.closed }
            try BottleSetup(engine: engine, prefix: prefix, environment: environment, log: log)
                .prepareIfNeeded(requiredLayer: layer, emulateModeset: emulateModeset,
                                 cdromDataFilename: cdromDataFilename, gameDirectory: gameDirectory, checkCancellation: {
                    self.lock.lock(); let stopped = self.cancelled; self.lock.unlock()
                    if stopped { throw WarmSessionState.Failure.closed }
                }, beforeRegistration: { try self.startServer() })
            let outcome = try EngineProcess.run(engine.wine,
                [EngineLauncher.windowsPath(for: engine.programJobLauncher, prefix: prefix), "--ready"],
                environment: environment, log: log)
            guard outcome.status == 0, !outcome.signaled, isAlive() else {
                throw NSError(domain: "MacRunner.Warm", code: 2, userInfo: [NSLocalizedDescriptionKey: "The owned Wine session did not become ready."])
            }
            log.mark("warmReady")
            saveTimeline()
        }
        private func startServer() throws {
            guard !WineServerProbe.mayBeAlive(prefix: prefix, environment: environment) else {
                throw NSError(domain: "MacRunner.Warm", code: 1, userInfo: [NSLocalizedDescriptionKey: "The bottle already has an unowned Wine session."])
            }
            let process = Process()
            process.executableURL = engine.sessionSupervisor
            process.arguments = [engine.wineserver.path, "-f", "-p"]
            process.environment = environment
            let lifetime = Pipe()
            let writerFD = lifetime.fileHandleForWriting.fileDescriptor
            let fdFlags = fcntl(writerFD, F_GETFD)
            guard fdFlags >= 0, fcntl(writerFD, F_SETFD, fdFlags | FD_CLOEXEC) == 0 else {
                try? lifetime.fileHandleForReading.close(); try? lifetime.fileHandleForWriting.close()
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
            process.standardInput = lifetime.fileHandleForReading
            process.standardOutput = log.outputHandle(); process.standardError = log.outputHandle()
            lock.lock()
            // A clone bootstrap may have failed and been drained before ordinary
            // creation. Release the completed guardian before replacing its fd.
            if server?.isRunning == false {
                try? lifetimeWriter?.close()
                lifetimeWriter = nil
                server = nil
            }
            if cancelled { lock.unlock(); throw WarmSessionState.Failure.closed }
            do { try process.run() } catch {
                try? lifetime.fileHandleForReading.close(); try? lifetime.fileHandleForWriting.close()
                lock.unlock(); throw error
            }
            try? lifetime.fileHandleForReading.close()
            lifetimeWriter = lifetime.fileHandleForWriting
            server = process; ownsSetup = false; lock.unlock()
            log.mark("warmServerStarted")
        }
        private func saveTimeline() {
            guard ProcessInfo.processInfo.environment["MACRUNNER_LAUNCH_PHASES"] == "1" else { return }
            do {
                let data = try JSONEncoder().encode(log.snapshotTimeline())
                try data.write(to: log.url.deletingPathExtension().appendingPathExtension("json"), options: .atomic)
            } catch { log.note("warm timeline save failed: \(error.localizedDescription)") }
        }
        func stop() {
            defer { saveTimeline(); log.close() }
            requestCancellation()
            lock.lock(); let owned = server; lock.unlock()
            // Never kill a new/unowned server that appeared after our foreground server died.
            guard let owned, owned.isRunning else { return }
            let ended = DispatchSemaphore(value: 0)
            DispatchQueue.global(qos: .utility).async { owned.waitUntilExit(); ended.signal() }
            if ended.wait(timeout: .now() + 3) == .timedOut, owned.isRunning {
                log.note("warm scoped stop timed out; terminating the owned foreground server")
                owned.terminate()
            }
            log.mark("warmStopRequested")
        }
        /// Interrupt a preparing bottle too. Do not block the AppKit cancellation callback.
        func requestCancellation() {
            lock.lock()
            cancelled = true
            let writer = lifetimeWriter
            lifetimeWriter = nil
            let ownsNamespace = ownsSetup
            ownsSetup = false
            lock.unlock()
            // Closing is kernel-enforced on App death too; supervisor owns exact child PID.
            if let writer { try? writer.close(); return }
            guard ownsNamespace else { return }
            let process = Process()
            process.executableURL = engine.wineserver; process.arguments = ["-k"]
            process.environment = environment; process.standardInput = FileHandle.nullDevice
            process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
            do { try process.run() } catch { log.note("warm cancel failed: \(error.localizedDescription)") }
        }
    }
    private static let lock = NSLock()
    private static var entries: [String: Entry] = [:]

    private static func retireIdle(key: String, state: WarmSessionState) {
        lock.lock(); defer { lock.unlock() }
        // A replacement may have been admitted while the old timer was closing.
        // Keep failed cleanup observable rather than losing an owned live server.
        guard let entry = entries[key], entry.state === state, !entry.backend.isAlive() else { return }
        entries.removeValue(forKey: key)
    }

    /// Bound persistent services to ten idle minutes. The shortened acceptance arm
    /// uses the same timer; there is no polling or timer work while a program owns a lease.
    static var idleTimeout: TimeInterval {
        if ProcessInfo.processInfo.environment["MACRUNNER_LAUNCH_WARM_CONTROL"] == "1",
           let raw = ProcessInfo.processInfo.environment["MACRUNNER_ACCEPTANCE_WARM_TTL_SECONDS"],
           let seconds = Double(raw), seconds >= 1, seconds <= 600 { return seconds }
        return 600
    }

    static var requested: Bool {
        let override = ProcessInfo.processInfo.environment["MACRUNNER_WARM_SESSION"]
        let stored = UserDefaults.standard.object(forKey: "macrunner.warmSession") as? Bool
        return requested(override: override, storedPreference: stored)
    }
    /// Candidate 1.0.9 default; the engine capability check still gates execution.
    static func requested(override: String?, storedPreference: Bool?) -> Bool {
        override.map { $0 == "1" } ?? storedPreference ?? true
    }
    static func enabled(engine: BundledEngine) -> Bool {
        requested && engine.localNameOnlyWineboot && FileManager.default.fileExists(atPath: engine.programJobLauncher.path)
            && FileManager.default.isExecutableFile(atPath: engine.sessionSupervisor.path)
    }
    private static func namespace(prefix: URL, environment: [String: String]) -> String {
        prefix.resolvingSymlinksInPath().path + "\n" + (environment["TMPDIR"] ?? "/tmp")
    }
    static func signature(engine: BundledEngine, environment: [String: String], layer: GraphicsLayer?,
                          emulateModeset: Bool? = nil, cdromDataFilename: String? = nil,
                          gameDirectory: URL? = nil) throws -> String {
        var identity = environment
        for key in ["WINEDEBUG", "DXMT_INSTR_LOG", "DXMT_LOG_PATH"] { identity.removeValue(forKey: key) }
        identity["engineGeneration"] = BottleSetup.engineStamp(engine)
        identity["engineRoot"] = BottleSetup.engineRootPath(engine)
        identity["graphicsLayer"] = layer?.id ?? "wine"
        // Profile changes require the old idle session to drain before offline
        // registry/media edits. An active program's lease prevents replacement.
        identity["emulateModeset"] = emulateModeset.map { $0 ? "Y" : "N" } ?? "unchanged"
        identity["cdromDataFilename"] = cdromDataFilename ?? ""
        identity["cdromDirectory"] = cdromDataFilename == nil ? "" : gameDirectory?.resolvingSymlinksInPath().path ?? ""
        let bytes = try JSONSerialization.data(withJSONObject: identity, options: [.sortedKeys])
        return SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }
    static func session(engine: BundledEngine, prefix: URL, environment: [String: String],
                        layer: GraphicsLayer?, log: EngineLog, admitProgram: Bool = false,
                        emulateModeset: Bool? = nil, cdromDataFilename: String? = nil,
                        gameDirectory: URL? = nil) throws -> WarmSessionState {
        let key = namespace(prefix: prefix, environment: environment)
        let wanted = try signature(engine: engine, environment: environment, layer: layer,
                                  emulateModeset: emulateModeset, cdromDataFilename: cdromDataFilename,
                                  gameDirectory: gameDirectory)
        lock.lock(); defer { lock.unlock() }
        // Switching bottles releases other idle sessions. Active programs keep their leases.
        for (otherKey, entry) in entries where otherKey != key {
            if entry.state.close(onlyIfIdle: true) { entries.removeValue(forKey: otherKey) }
        }
        if let existing = entries[key] {
            if existing.signature == wanted {
                if admitProgram {
                    if try existing.state.reserveProgramLease() { return existing.state }
                } else if existing.state.canReuse { return existing.state }
            }
            guard existing.state.close(onlyIfIdle: true) else { throw WarmSessionState.Failure.changedGeneration }
            entries.removeValue(forKey: key)
        }
        let entry = Entry(key: key, signature: wanted, backend: try Backend(engine: engine, prefix: prefix,
            environment: environment, layer: layer, log: log, emulateModeset: emulateModeset,
            cdromDataFilename: cdromDataFilename, gameDirectory: gameDirectory))
        entries[key] = entry
        if admitProgram {
            guard try entry.state.reserveProgramLease() else { throw WarmSessionState.Failure.closed }
        }
        return entry.state
    }
    /// Admission is atomic with idle invalidation; preparation remains outside
    /// the registry lock so cancellation can still reach a preparing backend.
    static func beginProgram(engine: BundledEngine, prefix: URL, environment: [String: String],
                             layer: GraphicsLayer?, log: EngineLog, emulateModeset: Bool? = nil,
                             cdromDataFilename: String? = nil, gameDirectory: URL? = nil) throws -> WarmSessionState {
        let state = try session(engine: engine, prefix: prefix, environment: environment,
                                layer: layer, log: log, admitProgram: true, emulateModeset: emulateModeset,
                                cdromDataFilename: cdromDataFilename, gameDirectory: gameDirectory)
        do { try state.ensureReady() }
        catch { state.endProgram(); throw error }
        return state
    }
    static func discard(prefix: URL, environment: [String: String]) {
        let key = namespace(prefix: prefix, environment: environment)
        lock.lock(); let entry = entries[key]; lock.unlock()
        guard let entry else { return }
        entry.backend.requestCancellation()
        DispatchQueue.global(qos: .utility).async {
            entry.state.close()
            lock.lock(); defer { lock.unlock() }
            if entries[key] === entry { entries.removeValue(forKey: key) }
        }
    }
    static func closeIdle() {
        lock.lock(); defer { lock.unlock() }
        for (key, entry) in entries where entry.state.close(onlyIfIdle: true) { entries.removeValue(forKey: key) }
    }
    static func closeAll() {
        lock.lock(); let owned = Array(entries.values); entries.removeAll(); lock.unlock()
        for entry in owned { entry.backend.requestCancellation(); entry.state.close() }
    }
    #if LAUNCH_QUALIFICATION
    static func qualificationSnapshot() -> [String: Int] {
        lock.lock(); defer { lock.unlock() }
        return ["entries": entries.count, "live": entries.values.filter { $0.backend.isAlive() }.count,
                "reusable": entries.values.filter { $0.state.canReuse }.count]
    }
    #endif
}
