import CryptoKit
import Foundation

/// Запуск Windows-программы встроенным движком — без `run-windows-app.sh`, bash и python.
///
/// ★★★ ЧЕМ ОТЛИЧАЕТСЯ ОТ СЦЕНАРИЯ РАЗРАБОТЧИКА.
///   * Лимита времени НЕТ. Сценарий гасил прогон через 45 с — для замеров это верно,
///     для игрока это «игра закрылась сама». Игра идёт, пока человек играет; остановить
///     её можно кнопкой, и это `wineserver -k` ТОЛЬКО своей бутылки.
///   * Итог ждёт ВСЕ процессы бутылки (`wineserver -w`), а не первый: лаунчеры и
///     установщики запускают настоящую программу и выходят сами.
///   * Причина отказа — только текст движка (`wine: Unhandled …` и т. п.) из журнала.
///     Код выхода Wine усечён до байта: 0xc0000005 превращается в 5, и по нему одному
///     падение от обычной ошибки не отличить.
final class EngineLauncher: @unchecked Sendable {
    let engine: BundledEngine
    let prefix: URL
    private let updateGate: UpdateSafetyGate
    private let lock = NSLock()
    private var stopRequested = false
    private var environment: [String: String] = [:]

    init(engine: BundledEngine, prefix: URL = EnginePaths.defaultBottle, gate: UpdateSafetyGate = .shared) {
        self.engine = engine
        self.prefix = prefix
        self.updateGate = gate
    }

    /// Окружение процесса движка. От приложения берём только то, без чего не живёт
    /// любой процесс; остальное (в том числе DYLD_* от отладчика) не передаём.
    func makeEnvironment(extra: [String: String]) -> [String: String] {
        let inherited = ProcessInfo.processInfo.environment
        var env: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"] {
            if let value = inherited[key] { env[key] = value }
        }
        env["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        env.merge(engine.environment(prefix: prefix, data: EnginePaths.data(for: engine))) { _, new in new }
        // Explicit diagnostic switch overrides the packaged hardware TSO default.
        // Forward invalid values too: the shared policy prints them and selects safe software TSO.
        if let value = inherited["MACRUNNER_FEX_HW_TSO"] {
            env["MACRUNNER_FEX_HW_TSO"] = value
        }
        env.merge(extra) { _, new in new }
        env["WINEPREFIX"] = prefix.path
        GameActivity.remember(prefix: prefix, environment: env)
        return env
    }

    /// Запуск целиком: бутылка → программа → ожидание всех процессов бутылки.
    /// Блокирует поток — вызывать не с главного.
    func run(exe: URL, arguments: [String], workdir: URL?, extraEnvironment: [String: String],
             runDirectory: URL, graphics plan: GraphicsPlan, minimumProcessLifetime: TimeInterval? = nil,
             onProgress: @escaping @Sendable (LaunchPhase) -> Void = { _ in }) -> LauncherResult {
        guard let activity = updateGate.beginActivity() else {
            return LauncherResult(status: "FAIL", error: L("Finish or cancel the update before starting a program."))
        }
        defer { updateGate.endActivity(activity) }
        let started = Date()
        // Окружение: движок → маршрут графики → поправки записи игры (они главнее: это
        // ручная настройка). В журнал — загрузки модулей, чтобы видеть, ЧЬЯ графика пришла.
        var env = makeEnvironment(extra: plan.environment.merging(extraEnvironment) { _, own in own })
        // Журналы DXMT — в каталог запуска, а не в папку игры: `dxmt-instr.log` по умолчанию
        // пишется в текущий каталог (engine/dxmt/src/util/instr.cpp), то есть рядом с игрой.
        if env["DXMT_INSTR_LOG"] == nil {
            env["DXMT_INSTR_LOG"] = "Z:" + runDirectory.appendingPathComponent("dxmt-instr.log").path
                .replacingOccurrences(of: "/", with: "\\")
        }
        if env["DXMT_LOG_PATH"] == nil { env["DXMT_LOG_PATH"] = runDirectory.path }
        if let debug = env["WINEDEBUG"], !debug.contains("loaddll") {
            env["WINEDEBUG"] = debug.isEmpty ? "+loaddll" : debug + ",+loaddll"
        }
        lock.lock(); environment = env; lock.unlock()

        var result = LauncherResult()
        result.schemaVersion = 1
        result.launchAchievement = "PROCESS_NOT_STARTED"
        result.minimumProcessLifetimeMs = minimumProcessLifetime.map { Int($0 * 1000) }
        result.exe = exe.lastPathComponent
        result.exePath = exe.path
        result.executionLane = "bundled-\(engine.name)"
        result.args = arguments + plan.extraArguments
        result.arch = plan.arch?.rawValue
        result.graphicsSummary = plan.summary
        result.graphicsRoute = [plan.api?.rawValue ?? "unknown", plan.arch?.rawValue ?? "unknown",
                                plan.route?.layer ?? "-", plan.route?.status.rawValue ?? "-"].joined(separator: " ")
        result.graphicsWarnings = plan.warnings.isEmpty ? nil : plan.warnings
        result.graphicsEvidence = plan.evidence.isEmpty ? nil : plan.evidence
        func finish(_ status: String, rc: Int? = nil, error: String? = nil, log: EngineLog? = nil) -> LauncherResult {
            result.status = status
            result.rc = rc
            result.exitCode = rc
            result.error = error
            result.durationMs = Int(Date().timeIntervalSince(started) * 1000)
            if let log {
                log.close()
                // Раскладка запуска по этапам, секунды от нажатия (см. EngineLog.milestones).
                result.timeline = log.milestones.isEmpty ? nil : log.milestones
                result.stderrPath = log.url.path
                result.stderrTail = log.meaningfulTail()
                let modules = log.graphicsModules
                result.graphicsModules = modules.isEmpty ? nil : modules.map { "\($0.name) \($0.kind) \($0.path)" }
                // Своя графика Wine в процессе, где маршрут велит слой пакета, — ровно та смесь,
                // что уронила проверку 23.09. Называем её в итоге, а не молчим.
                if let layer = plan.layer,
                   !layer.modules.values.flatMap({ $0 }).contains("wined3d.dll"),
                   modules.contains(where: { $0.name == "wined3d.dll" }) {
                    result.graphicsProvenanceNote = "wined3d.dll loaded although the route uses layer \(layer.id)"
                }
            }
            if let data = try? JSONEncoder().encode(result) {
                try? data.write(to: runDirectory.appendingPathComponent("last-run.json"), options: .atomic)
            }
            return result
        }

        if case .refuse(let reason) = plan.decision {
            return finish("UNSUPPORTED", error: reason)
        }
        guard Self.isWindowsExecutable(exe) else {
            return finish("INVALID_EXE", error: String(format: L("Not a Windows program or unreadable: %@"), exe.path))
        }
        let log: EngineLog
        do {
            try FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)
            log = try EngineLog(url: runDirectory.appendingPathComponent("engine.log"))
        } catch {
            return finish("FAIL", error: error.localizedDescription)
        }

        // Exact post-merge child environment hash plus shareable settings. Keep
        // private login names/home out of diagnostic artifacts.
        let environmentBytes = (try? JSONSerialization.data(withJSONObject: env, options: [.sortedKeys])) ?? Data()
        let selected = ["wine/bin/wine", "wine/bin/wineserver",
            "fex/aarch64-windows/xtajit.dll", "fex/aarch64-windows/xtajit64.dll",
            "fex/aarch64-unix/libwow64fex.so", "fex/aarch64-unix/libarm64ecfex.so",
            "wine/lib/wine/aarch64-unix/libwow64fex.so",
            "wine/lib/wine/aarch64-windows/wow64.dll", "wine/lib/wine/aarch64-windows/wow64win.dll"]
        var binaries: [String: String] = [:]
        for path in selected {
            if let bytes = try? Data(contentsOf: engine.root.appendingPathComponent(path)) {
                binaries[path] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
        }
        let receipt: [String: Any] = [
            "classification": "DIAGNOSTIC_ONLY/NOT_GOLDEN",
            "utc": ISO8601DateFormatter().string(from: Date()),
            "systemUptime": ProcessInfo.processInfo.systemUptime,
            "environmentSHA256": SHA256.hash(data: environmentBytes).map { String(format: "%02x", $0) }.joined(),
            "environment": env.filter { !["HOME", "USER", "LOGNAME", "__CF_USER_TEXT_ENCODING"].contains($0.key) },
            "privateEnvironmentKeys": ["HOME", "USER", "LOGNAME", "__CF_USER_TEXT_ENCODING"].filter { env[$0] != nil },
            "engineManifestSHA256": BottleSetup.engineStamp(engine),
            "selectedBinaries": binaries,
            "exe": exe.path, "arguments": arguments + plan.extraArguments,
            "prefix": prefix.path, "graphicsRoute": result.graphicsRoute ?? "unknown"
        ]
        if let bytes = try? JSONSerialization.data(withJSONObject: receipt, options: [.prettyPrinted, .sortedKeys]) {
            try? bytes.write(to: runDirectory.appendingPathComponent("launch-receipt.json"), options: .atomic)
        }

        do {
            if isStopRequested { return finish("STOPPED", log: log) }
            onProgress(.preparing)
            log.note("graphics: \(result.graphicsRoute ?? "-") engine=\(engine.name) overridden=\(plan.overridden)")
            for line in plan.evidence { log.note("graphics evidence: \(line)") }
            try BottleSetup(engine: engine, prefix: prefix, environment: env, log: log)
                .prepareIfNeeded(requiredLayer: plan.layer, emulateModeset: plan.emulateModeset,
                                 cdromDataFilename: plan.cdromDataFilename,
                                 gameDirectory: exe.deletingLastPathComponent())
            log.mark("bottleReady")
        } catch {
            // Остановили во время подготовки — это не отказ бутылки.
            if isStopRequested { return finish("STOPPED", log: log) }
            return finish("FAIL", error: error.localizedDescription, log: log)
        }
        if isStopRequested { return finish("STOPPED", log: log) }

        let target = Self.windowsPath(for: exe, prefix: prefix)
        let directory = workdir ?? exe.deletingLastPathComponent()
        let fullArguments = arguments + plan.extraArguments
        log.note("run: \(target) args=\(fullArguments) cwd=\(directory.path)")
        let outcome: EngineProcess.Outcome
        let executionStarted = ProcessInfo.processInfo.systemUptime
        BottleSetup.beginRun(prefix: prefix)
        defer { BottleSetup.endRun(prefix: prefix) }
        do {
            onProgress(.starting)
            outcome = try EngineProcess.run(engine.wine, [target] + fullArguments, environment: env,
                                            directory: directory, log: log,
                                            onStarted: { log.mark("processStarted"); onProgress(.active) })
        } catch {
            return finish("FAIL", error: error.localizedDescription, log: log)
        }
        // Лаунчеры и установщики уходят раньше настоящей программы — ждём всю бутылку.
        EngineProcess.waitForServer(engine: engine, environment: env, log: log)
        log.note("run: exit=\(outcome.status) signaled=\(outcome.signaled)")
        let processLifetime = ProcessInfo.processInfo.systemUptime - executionStarted
        result.processLifetimeMs = Int(processLifetime * 1000)
        let earlyExit = Self.exitedTooSoon(elapsed: processLifetime, minimum: minimumProcessLifetime)
        result.launchAchievement = earlyExit ? "EARLY_EXIT" : minimumProcessLifetime == nil
            ? "PROCESS_COMPLETED" : "PROCESS_LIVED_AT_LEAST_MINIMUM"

        let rc = Int(outcome.status)
        if isStopRequested { return finish("STOPPED", rc: rc, log: log) }
        if let crash = log.crashMessage { return finish("CRASH", rc: rc, error: crash, log: log) }
        if outcome.signaled {
            return finish("CRASH", rc: rc, error: String(format: L("The engine was terminated by signal %d."), rc), log: log)
        }
        if rc == 0, earlyExit {
            return finish("EARLY_EXIT", rc: rc, error: L("The game closed immediately after launch."), log: log)
        }
        if rc == 0 { return finish("PASS", rc: rc, log: log) }
        return finish("FAIL", rc: rc, error: log.engineMessage, log: log)
    }

    /// Остановить всё, что запущено в этой бутылке. Чужие бутылки и чужие прогоны
    /// не трогаются: `wineserver -k` действует только в пределах WINEPREFIX.
    func stop() {
        lock.lock()
        stopRequested = true
        let env = environment
        lock.unlock()
        guard !env.isEmpty else { return }
        let process = Process()
        process.executableURL = engine.wineserver
        process.arguments = ["-k"]
        process.environment = env
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }

    private var isStopRequested: Bool {
        lock.lock(); defer { lock.unlock() }
        return stopRequested
    }

    // MARK: - Пути

    static func exitedTooSoon(elapsed: TimeInterval, minimum: TimeInterval?) -> Bool {
        guard let minimum else { return false }
        return elapsed < minimum
    }

    /// Путь для Wine. Внутри бутылки — `C:\…` (некоторые игры проверяют, что стоят
    /// на диске C), снаружи — `Z:\…`, это корень файловой системы Mac.
    /// Путь Unix Wine пустил бы через `start.exe /exec`, и код выхода был бы уже не игры.
    static func windowsPath(for exe: URL, prefix: URL) -> String {
        let path = exe.resolvingSymlinksInPath().path
        let driveC = prefix.appendingPathComponent("drive_c").resolvingSymlinksInPath().path + "/"
        if path.hasPrefix(driveC) {
            return "C:\\" + path.dropFirst(driveC.count).replacingOccurrences(of: "/", with: "\\")
        }
        return "Z:" + path.replacingOccurrences(of: "/", with: "\\")
    }

    /// Программа Windows начинается с «MZ». Проверяем до создания бутылки, чтобы
    /// не готовить её ради файла, который не запустится.
    static func isWindowsExecutable(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 2)) == Data("MZ".utf8)
    }
}

extension EngineLauncher {
    /// Обновить бутылку под новый движок ЗАРАНЕЕ — при открытии приложения, а не по «Играть».
    ///
    /// ★ Замер 23.09, запуск HK 13:38: после установки новой сборки движка первый же запуск
    ///   игры сначала обновлял бутылку (`wineboot -u` + 1617 модулей) — это секунды до Unity,
    ///   которые человек ждал у нажатой кнопки. Теперь это делается в фоне сразу после
    ///   открытия. Новую бутылку не создаём: её создаст первый запуск. Допуск тот же, что у
    ///   запуска игры, — с установкой обновления не пересечётся; нажатие «Играть» в это время
    ///   просто дождётся готовой бутылки (общий замок `BottleSetup`).
    static func prepareBottleInBackground(engine: BundledEngine, prefix: URL = EnginePaths.defaultBottle,
                                          gate: UpdateSafetyGate = .shared) {
        guard FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path),
              !BottleSetup.isReady(engine: engine, prefix: prefix),
              !GameActivity.anyRunning,
              let activity = gate.beginActivity() else { return }
        DispatchQueue.global(qos: .utility).async {
            defer { gate.endActivity(activity) }
            let launcher = EngineLauncher(engine: engine, prefix: prefix, gate: gate)
            let env = launcher.makeEnvironment(extra: [:])
            let runDirectory = EnginePaths.newRunDirectory().appendingPathExtension("bottle-update")
            guard (try? FileManager.default.createDirectory(at: runDirectory, withIntermediateDirectories: true)) != nil,
                  let log = try? EngineLog(url: runDirectory.appendingPathComponent("engine.log")) else { return }
            do {
                try BottleSetup(engine: engine, prefix: prefix, environment: env, log: log).prepareIfNeeded()
            } catch {
                log.note("background bottle update failed: \(error.localizedDescription)")
            }
            log.close()
        }
    }
}

// MARK: - Процесс

enum EngineProcess {
    struct Outcome {
        let status: Int32
        let signaled: Bool
    }

    /// Запускает процесс движка; его вывод идёт прямо в файл журнала (`EngineLog`).
    @discardableResult
    static func run(_ executable: URL, _ arguments: [String], environment: [String: String],
                    directory: URL? = nil, log: EngineLog,
                    onStarted: () -> Void = {}) throws -> Outcome {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        if let directory { process.currentDirectoryURL = directory }
        let output = log.outputHandle()
        process.standardOutput = output
        process.standardError = output
        process.standardInput = FileHandle.nullDevice
        try process.run()
        log.note("owned-process pid=\(process.processIdentifier) executable=\(executable.path) argv=\(arguments)")
        onStarted()
        process.waitUntilExit()
        return Outcome(status: process.terminationStatus, signaled: process.terminationReason == .uncaughtSignal)
    }

    /// Ждёт, пока в бутылке не останется процессов (`wineserver -w`).
    static func waitForServer(engine: BundledEngine, environment: [String: String], log: EngineLog) {
        let process = Process()
        process.executableURL = engine.wineserver
        process.arguments = ["-w"]
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            log.note("wineserver -w failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Журнал

/// Журнал одного запуска: процессы движка пишут в файл САМИ, приложение его только читает.
///
/// ★★★ НЕ ЧЕРЕЗ КАНАЛ В ПРИЛОЖЕНИЕ (23.09.2026). Первый запуск Hollow Knight из .app вёл
///   вывод через Pipe. Приложение закрыли — канал оборвался, журнал встал на 09:22, игра
///   (она пишет диагностику в stderr непрерывно) завершилась, а семь служебных процессов
///   Wine остались сиротами. Теперь у каждого процесса движка свой дескриптор файла
///   (O_APPEND), и игре всё равно, открыто ли окно MacRunner.
///
/// ★ Потолок размера. Движок печатает диагностику безусловно (сотни МБ на долгой игре,
///   Elden Ring 090–093). Пока приложение открыто, журнал раз в 2 с дочитывается (сообщения
///   Wine, загрузки графики), а при переполнении первые 32 МБ сохраняются в engine.head.log
///   и engine.log усекается — запись O_APPEND продолжается с начала файла. Приложение
///   закрыто — журнал растёт до конца игры без потолка.
final class EngineLog: @unchecked Sendable {
    let url: URL
    var headURL: URL { url.deletingLastPathComponent().appendingPathComponent("engine.head.log") }
    private let fd: Int32
    private let lock = NSLock()
    private var readOffset: UInt64 = 0
    private var carry = Data()
    private var closed = false
    private var headSaved = false
    private var droppedBytes: UInt64 = 0
    private var timer: DispatchSourceTimer?
    private(set) var crashMessage: String?
    private(set) var engineMessage: String?
    /// Загруженные графические модули: имя, путь, «builtin»/«native» (`trace:loaddll`).
    private(set) var graphicsModules: [(name: String, path: String, kind: String)] = []
    /// Когда журнал впервые увидел этап запуска, секунды от открытия журнала.
    ///
    /// ★ Чтобы на вопрос «почему долго» отвечать числами, а не датами файлов (23.09 этапы
    ///   запуска HK восстанавливались по времени создания Player.log и журналов DXMT).
    ///   Журнал дочитывается раз в 2 с, поэтому точность этапов из него — ±2 с.
    private(set) var milestones: [String: Double] = [:]
    private let openedAt = Date()
    /// Служебные окна Wine — не окно игры.
    static let wineWindowClasses: Set<String> = [
        "IME", "Wine IME", "Message", "OleMainThreadWndClass", "WineDdeServerName", "WineDdeEventClass",
        "Shell_TrayWnd", "#32769", "WineAppBar", "class_rundll32", "__wine_clipboard_manager",
        "__wine_gaming_input_devnotify", "__wine_display_settings_restorer",
    ]
    static let graphicsModuleNames: Set<String> = [
        "d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d10core.dll", "d3d11.dll", "d3d12.dll",
        "d3d12core.dll", "dxgi.dll", "winemetal.dll", "wined3d.dll", "ddraw.dll", "opengl32.dll",
        "vulkan-1.dll", "winevulkan.dll", "dxcore.dll",
    ]

    static let headLimit: UInt64 = 32 << 20
    static let rotateLimit: UInt64 = 48 << 20

    init(url: URL) throws {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let descriptor = open(url.path, O_WRONLY | O_APPEND | O_CLOEXEC)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        self.url = url
        fd = descriptor
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.schedule(deadline: .now() + 2, repeating: 2)
        timer.setEventHandler { [weak self] in self?.poll() }
        timer.resume()
        self.timer = timer
    }

    deinit {
        timer?.cancel()
        if !closed { Darwin.close(fd) }
    }

    /// Дескриптор для stdout/stderr процесса движка — свой дубликат, файл общий.
    func outputHandle() -> FileHandle {
        FileHandle(fileDescriptor: dup(fd), closeOnDealloc: true)
    }

    func append(_ data: Data) {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        writeAll(data)
    }

    func note(_ text: String) {
        append(Data("[macrunner-app] +\(String(format: "%.1f", elapsed))s \(text)\n".utf8))
    }

    /// Секунды от открытия журнала (≈ от нажатия «Играть»).
    var elapsed: Double { Date().timeIntervalSince(openedAt) }

    /// Отметить этап вручную (бутылка готова, процесс стартовал) — точно, без опроса.
    func mark(_ milestone: String) {
        lock.lock(); defer { lock.unlock() }
        if milestones[milestone] == nil { milestones[milestone] = elapsed }
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        timer?.cancel()
        readNew(all: true)
        if droppedBytes > 0 {
            writeAll(Data("\n[macrunner-app] \(droppedBytes) bytes dropped; the start of the log is in engine.head.log\n".utf8))
        }
        closed = true
        Darwin.close(fd)
    }

    /// Последние строки, по которым человек что-то поймёт: без приборов движка
    /// (`macrunner-…`, трассы, dyld), но с сообщениями Wine и ошибками `err:`.
    func meaningfulTail(maxLines: Int = 20) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: size > 262_144 ? size - 262_144 : 0)
        let text = String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
        let noise = ["macrunner-", "dyld[", "msync:", "[macrunner-app]", "MacRunner HyperBridge", "pid="]
        let lines = text.split(whereSeparator: \.isNewline).map(String.init).filter { line in
            !line.trimmingCharacters(in: .whitespaces).isEmpty
                && !noise.contains(where: { line.hasPrefix($0) })
                && !line.contains(":trace:") && !line.contains(":fixme:")
        }
        let last = lines.suffix(maxLines)
        return last.isEmpty ? nil : last.joined(separator: "\n")
    }

    // MARK: Внутреннее (под lock)

    private func writeAll(_ data: Data) {
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let written = write(fd, raw.baseAddress! + offset, raw.count - offset)
                if written <= 0 { break }
                offset += written
            }
        }
    }

    private func poll() {
        lock.lock(); defer { lock.unlock() }
        guard !closed else { return }
        readNew(all: false)
        rotateIfNeeded()
    }

    /// Дочитать новое с прошлого места: сообщения Wine и загрузки графики.
    private func readNew(all: Bool) {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        if size < readOffset { readOffset = 0; carry = Data() }   // усечён
        try? handle.seek(toOffset: readOffset)
        var budget = all ? Int.max : 16 << 20
        while budget > 0, let chunk = try? handle.read(upToCount: min(4 << 20, budget)), !chunk.isEmpty {
            scan(chunk)
            readOffset += UInt64(chunk.count)
            budget -= chunk.count
        }
    }

    private func rotateIfNeeded() {
        var info = stat()
        guard fstat(fd, &info) == 0, UInt64(info.st_size) > Self.rotateLimit else { return }
        if !headSaved, let handle = try? FileHandle(forReadingFrom: url) {
            let head = (try? handle.read(upToCount: Int(Self.headLimit))) ?? Data()
            try? handle.close()
            try? head.write(to: headURL)
            headSaved = true
        }
        readNew(all: true)
        droppedBytes += UInt64(info.st_size)
        ftruncate(fd, 0)
        readOffset = 0
        carry = Data()
        writeAll(Data("[macrunner-app] log truncated at \(droppedBytes) bytes; the start is in engine.head.log\n".utf8))
    }

    /// `…:trace:loaddll:build_module Loaded L"C:\\windows\\system32\\d3d11.dll" at 000…: builtin`
    private func recordModuleLoad(_ line: String) {
        guard let open = line.range(of: "Loaded L\""),
              let close = line.range(of: "\" at ", range: open.upperBound..<line.endIndex) else { return }
        let path = String(line[open.upperBound..<close.lowerBound]).replacingOccurrences(of: "\\\\", with: "\\")
        let name = (path.split(separator: "\\").last.map(String.init) ?? path).lowercased()
        guard Self.graphicsModuleNames.contains(name) else { return }
        if milestones["graphicsLoaded"] == nil { milestones["graphicsLoaded"] = elapsed }
        let kind = line.split(separator: ":").last.map { $0.trimmingCharacters(in: .whitespaces) } ?? "?"
        guard graphicsModules.count < 64,
              !graphicsModules.contains(where: { $0.path == path && $0.kind == kind }) else { return }
        graphicsModules.append((name, path, kind))
    }

    /// `macrunner-createwnd: pid=… класс=L"UnityWndClass" … style=00cf0000 … parent=0x0` —
    /// первое окно верхнего уровня не из служебных классов Wine и есть окно игры.
    private func noteWindow(_ line: String) {
        guard let open = line.range(of: "=L\""),
              let close = line.range(of: "\"", range: open.upperBound..<line.endIndex) else { return }
        let windowClass = String(line[open.upperBound..<close.lowerBound])
        guard !Self.wineWindowClasses.contains(windowClass), !windowClass.hasPrefix("__wine"),
              line.contains("parent=0x0") else { return }
        milestones["gameWindow"] = elapsed
    }

    /// Сообщения самого Wine: `wine: Unhandled page fault …` — падение программы,
    /// прочие `wine: …` с отказом — причина, если программа не запустилась.
    private func scan(_ data: Data) {
        carry.append(data)
        var start = carry.startIndex
        while let newline = carry[start...].firstIndex(of: 0x0A) {
            let line = carry[start..<newline]
            if line.count > 40, line.range(of: Data(":trace:loaddll:".utf8)) != nil {
                recordModuleLoad(String(decoding: line, as: UTF8.self))
            } else if milestones["gameWindow"] == nil, line.starts(with: Data("macrunner-createwnd:".utf8)) {
                noteWindow(String(decoding: line, as: UTF8.self))
            } else if line.count > 6, line.starts(with: Data("wine: ".utf8)) {
                let text = String(decoding: line, as: UTF8.self)
                if text.contains("Unhandled") {
                    if crashMessage == nil { crashMessage = text }
                } else if engineMessage == nil,
                          ["could not", "cannot", "failed", "not found", "Bad EXE", "not supported"]
                            .contains(where: { text.localizedCaseInsensitiveContains($0) }) {
                    engineMessage = text
                }
            }
            start = carry.index(after: newline)
        }
        // Строка длиннее 4 КБ — не сообщение Wine; держать её незачем.
        carry = start == carry.endIndex ? Data() : Data(carry[start...].suffix(4096))
    }
}

extension EnginePaths {
    /// Данные движка (кэш трансляции FEX) — СВОИ у каждой версии движка.
    ///
    /// ★ Обновление по воздуху меняет FEX, а кэш хранит уже переведённый им код: старый кэш
    ///   под новым транслятором — это чужой машинный код в игре. Старые каталоги
    ///   сохраняются: ими может пользоваться игра, пережившая закрытие приложения.
    static func data(for engine: BundledEngine) -> URL {
        let fm = FileManager.default
        let manifest = (try? Data(contentsOf: engine.root.appendingPathComponent("ENGINE.json"))) ?? Data()
        let current = cacheDirectory(manifest: manifest, under: data)
        try? fm.createDirectory(at: current, withIntermediateDirectories: true)
        return current
    }

    static func cacheDirectory(manifest: Data, under root: URL) -> URL {
        let stamp = SHA256.hash(data: manifest).map { String(format: "%02x", $0) }.joined()
        return root.appendingPathComponent(stamp, isDirectory: true)
    }

    /// Новый каталог прогона; старые сверх двадцати последних убираются.
    static func newRunDirectory() -> URL {
        let fm = FileManager.default
        try? fm.createDirectory(at: runs, withIntermediateDirectories: true)
        let existing = ((try? fm.contentsOfDirectory(at: runs, includingPropertiesForKeys: nil)) ?? [])
            .filter { $0.hasDirectoryPath }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for old in existing.dropLast(19) { try? fm.removeItem(at: old) }
        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        return runs.appendingPathComponent("\(stamp)-\(UUID().uuidString.prefix(8))", isDirectory: true)
    }
}
