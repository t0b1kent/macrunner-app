import Darwin
import Foundation

/// Automatic cleanup is scoped to one prefix and its actual Wine socket.
/// The guest job helper queries Wine directly, including reparented processes.
enum WineBackgroundProcesses {
    private static let lock = NSLock()
    private static var launches: [URL: Int] = [:]
    private static let interval: TimeInterval = 2.5
    private static let grace: TimeInterval = 5

    static func beginLaunch(_ prefix: URL) -> URL {
        let key = prefix.resolvingSymlinksInPath().standardizedFileURL
        lock.lock(); defer { lock.unlock() }
        launches[key, default: 0] += 1
        return key
    }

    static func endLaunch(_ key: URL) {
        lock.lock(); defer { lock.unlock() }
        if let count = launches[key], count > 1 { launches[key] = count - 1 }
        else { launches.removeValue(forKey: key) }
    }

    private static func isExclusive(_ key: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return launches[key] == 1
    }

    /// Output is one short record on success. A failed, incomplete, or timed-out
    /// probe is deliberately indistinguishable from an active foreground program.
    private static func helperCount(engine: BundledEngine, prefix: URL,
                                    environment: [String: String]) -> Int? {
        guard WineServerProbe.isAlive(prefix: prefix, environment: environment) else { return nil }
        let output = Pipe()
        let helper = EngineLauncher.windowsPath(for: engine.programJobLauncher, prefix: prefix)
        var env = environment
        env["WINEDEBUG"] = "-all"
        guard let data = execute(engine.wine, [helper, "--probe-background"],
                                 environment: env, output: output),
              let text = String(data: data, encoding: .utf8) else { return nil }
        let prefix = "MACRUNNER_BACKGROUND_ONLY "
        let record = text.split(whereSeparator: \.isNewline).filter { $0.hasPrefix(prefix) }
        guard record.count == 1 else { return nil }
        return Int(record[0].dropFirst(prefix.count)).flatMap { $0 >= 0 ? $0 : nil }
    }

    @discardableResult
    private static func execute(_ executable: URL, _ arguments: [String], environment: [String: String],
                                output: Pipe? = nil) -> Data? {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.standardOutput = output.map { $0 as Any } ?? FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + 4) == .timedOut {
            if process.isRunning { process.terminate() }
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        // Wine children can inherit stdout. Read available bytes instead of
        // waiting for EOF from unrelated descendants.
        guard let output else { return Data() }
        let fd = output.fileHandleForReading.fileDescriptor
        guard fcntl(fd, F_SETFL, O_NONBLOCK) == 0 else { return nil }
        var bytes = [UInt8](repeating: 0, count: 4096)
        let count = bytes.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0, count < bytes.count else { return nil }
        return Data(bytes.prefix(count))
    }

    private static func stopIfExclusive(key: URL, engine: BundledEngine, environment: [String: String],
                                        log: EngineLog) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard launches[key] == 1,
              helperCount(engine: engine, prefix: key, environment: environment) != nil,
              execute(engine.wineserver, ["-k"], environment: environment) != nil else { return false }
        log.note("bottle: stopped Wine after only background processes remained")
        return true
    }

    /// Before a launch, or after a warm job leaves launcher helpers outside
    /// its job object, do not touch the server unless all samples are idle.
    static func cleanIdle(key: URL, engine: BundledEngine, environment: [String: String],
                          log: EngineLog, requireLauncherHelper: Bool, cancelled: () -> Bool) {
        let deadline = ProcessInfo.processInfo.systemUptime + grace
        repeat {
            guard !cancelled(), isExclusive(key),
                  let helpers = helperCount(engine: engine, prefix: key, environment: environment),
                  !requireLauncherHelper || helpers > 0 else { return }
            if ProcessInfo.processInfo.systemUptime >= deadline {
                _ = stopIfExclusive(key: key, engine: engine, environment: environment, log: log)
                return
            }
            Thread.sleep(forTimeInterval: interval)
        } while true
    }

    static func waitForColdRun(key: URL, engine: BundledEngine, environment: [String: String],
                               log: EngineLog, cancelled: () -> Bool) {
        let waiter = Process()
        waiter.executableURL = engine.wineserver
        waiter.arguments = ["-w"]
        waiter.environment = environment
        waiter.standardOutput = FileHandle.nullDevice
        waiter.standardError = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        waiter.terminationHandler = { _ in finished.signal() }
        do { try waiter.run() } catch {
            log.note("wineserver -w failed: \(error.localizedDescription)")
            return
        }
        var idleSince: TimeInterval?
        while finished.wait(timeout: .now() + interval) == .timedOut {
            if cancelled() {
                if waiter.isRunning { waiter.terminate() }
                return
            }
            guard isExclusive(key), helperCount(engine: engine, prefix: key, environment: environment) != nil else {
                idleSince = nil
                continue
            }
            let now = ProcessInfo.processInfo.systemUptime
            if let idleSince, now - idleSince >= grace,
               stopIfExclusive(key: key, engine: engine, environment: environment, log: log) {
                if finished.wait(timeout: .now() + 4) == .timedOut, waiter.isRunning { waiter.terminate() }
                return
            }
            if idleSince == nil { idleSince = now }
        }
    }
}
