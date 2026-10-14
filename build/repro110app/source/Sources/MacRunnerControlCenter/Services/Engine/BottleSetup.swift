import CryptoKit
import Foundation

/// Бутылка (префикс Wine) для встроенного движка: создание и дозаполнение.
///
/// ★★★ ОТКУДА ПОРЯДОК. Это перенос того, что в рабочих прогонах делали
///   `scripts/mr-run.sh` (ветка dxmt) и `scripts/sync-prefix-from-dist.sh` для пути FEX:
///   `wineboot` сам НЕ кладёт в `syswow64` ни одного модуля i386 (замер 23.09:
///   0 файлов против 825 в рабочем префиксе), а без них не запустится ни одна
///   32-битная программа. Остальное — ровно тот же набор, что в рабочем префиксе:
///   сборка ARM64X в `system32`, x86_64-графика DXMT, `xtajit`/`wow64cpu`/`wow64*`,
///   comctl32 v6 в WinSxS. Шаблон префикса из прогонов раздавать нельзя: он снят
///   с чужой бутылки, поэтому бутылка создаётся на машине игрока.
///
///   Файлы копируются через `FileManager.copyItem`: на APFS это клонирование, и
///   ~1 100 модулей не занимают места, пока их не перезапишут.
struct BottleSetup {
    let engine: BundledEngine
    let prefix: URL
    let environment: [String: String]
    let log: EngineLog

    static let markerName = ".macrunner-bottle.json"
    static let updatingName = ".macrunner-bottle-updating"
    /// Запуски приложения по бутылкам: слой графики нельзя менять под идущей игрой.
    private static var activeRuns: [String: Int] = [:]
    private static let runsLock = NSLock()

    static func beginRun(prefix: URL) {
        runsLock.lock(); activeRuns[prefix.path, default: 0] += 1; runsLock.unlock()
    }

    /// Идёт ли хоть один запуск приложения в любой бутылке.
    static var hasActiveRuns: Bool {
        runsLock.lock(); defer { runsLock.unlock() }
        return activeRuns.values.contains { $0 > 0 }
    }

    static func endRun(prefix: URL) {
        runsLock.lock(); activeRuns[prefix.path, default: 1] -= 1; runsLock.unlock()
    }

    /// Занята ли бутылка: наш запуск в ней идёт или жив её wineserver (запущено извне).
    func isBusy() -> Bool {
        Self.runsLock.lock()
        let ours = Self.activeRuns[prefix.path, default: 0] > 0
        Self.runsLock.unlock()
        return ours || WineServerProbe.isAlive(prefix: prefix, environment: environment)
    }

    /// Одна подготовка за раз: две игры, запущенные вместе на пустой бутылке,
    /// иначе создавали бы её одновременно.
    private static let lock = NSRecursiveLock()

    enum SetupError: LocalizedError {
        case bootFailed(Int32)
        case setupServerFailed(Int32)
        case wicRegistrationFailed(Int32)
        case missing(String)
        case graphicsMismatch(String)
        case busy(String)
        case gameDataMissing(String)
        case noFreeMediaDrive

        var errorDescription: String? {
            switch self {
            case .bootFailed(let rc):
                return String(format: L("Could not create the Windows environment (wineboot exit code %d)."), rc)
            case .setupServerFailed(let rc):
                return String(format: L("Could not prepare the Windows server (exit code %d)."), rc)
            case .wicRegistrationFailed(let rc):
                return String(format: L("Could not prepare Windows image decoding (WIC registration exit code %d)."), rc)
            case .graphicsMismatch(let module):
                return String(format: L("The graphics module %@ in the Windows environment does not match the MacRunner engine."), module)
            case .busy(let layer):
                return String(format: L("This game needs the %@ graphics set, but another program is still running in the same Windows environment. Close it and try again."), layer)
            case .missing(let what):
                return String(format: L("The MacRunner engine is incomplete: %@ is missing. Reinstall MacRunner."), what)
            case .gameDataMissing(let filename):
                return String(format: L("This game needs %@ next to its executable. Add the original game data and try again."), filename)
            case .noFreeMediaDrive:
                return L("No free drive letter is available for this game's CD data.")
            }
        }
    }

    /// Отпечаток движка: хеш `ENGINE.json`, а в нём хеши всех файлов пакета.
    /// Сменился движок (обновление приложения) — бутылку надо обновить.
    var engineStamp: String { Self.engineStamp(engine) }

    static func engineStamp(_ engine: BundledEngine) -> String {
        let data = (try? Data(contentsOf: engine.root.appendingPathComponent("ENGINE.json"))) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Wine also records installation paths in its environment. Identical engine
    /// bytes at a new location still need wineboot -u; a symlink alias does not.
    var engineRootPath: String { Self.engineRootPath(engine) }

    static func engineRootPath(_ engine: BundledEngine) -> String {
        engine.root.resolvingSymlinksInPath().standardizedFileURL.path
    }

    private var markerURL: URL { prefix.appendingPathComponent(Self.markerName) }

    private func readMarker() -> [String: Any]? { Self.readMarker(prefix: prefix) }

    private static func readMarker(prefix: URL) -> [String: Any]? {
        guard let data = try? Data(contentsOf: prefix.appendingPathComponent(markerName)) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func writeMarker(layers: [String], wicRegistration: [String: String]? = nil,
                              updateInputs: BottleUpdateCatalogue? = nil, stamp: String? = nil) throws {
        var marker: [String: Any] = ["engine": stamp ?? engineStamp, "engineRoot": engineRootPath,
                                     "engineName": engine.name, "layers": layers,
                                     "prepared": ISO8601DateFormatter().string(from: Date())]
        if let wicRegistration { marker["wicRegistration"] = wicRegistration }
        if let updateInputs {
            marker["updateInputs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(updateInputs))
        }
        let data = try JSONSerialization.data(withJSONObject: marker, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: markerURL, options: .atomic)
    }

    var isReady: Bool { Self.isReady(engine: engine, prefix: prefix) }

    /// Готова ли бутылка под этот движок — без журнала (фоновая проверка при открытии приложения).
    static func isReady(engine: BundledEngine, prefix: URL, stamp: String? = nil) -> Bool {
        guard !FileManager.default.fileExists(atPath: prefix.appendingPathComponent(updatingName).path) else { return false }
        guard let marker = readMarker(prefix: prefix) else { return false }
        return marker["engine"] as? String == (stamp ?? engineStamp(engine))
            && marker["engineRoot"] as? String == engineRootPath(engine)
            && marker["bootstrapPending"] as? Bool != true
            && FileManager.default.fileExists(atPath: prefix.appendingPathComponent("system.reg").path)
    }

    /// Слои графики, стоящие в бутылке сейчас.
    var installedLayers: [String] { readMarker()?["layers"] as? [String] ?? [] }

    /// Создаёт бутылку или обновляет её под новый движок. Блокирует поток —
    /// вызывать не с главного.
    func prepareIfNeeded(requiredLayer: GraphicsLayer? = nil, emulateModeset: Bool? = nil,
                          cdromDataFilename: String? = nil, gameDirectory: URL? = nil,
                          allowTemplate: Bool = true,
                          checkCancellation: () throws -> Void = {},
                          beforeRegistration: (() throws -> Void)? = nil) throws {
        Self.lock.lock()
        defer { Self.lock.unlock() }
        try checkCancellation()
        if let filename = cdromDataFilename {
            guard let directory = gameDirectory,
                  filename == URL(fileURLWithPath: filename).lastPathComponent,
                  FileManager.default.isReadableFile(atPath: directory.appendingPathComponent(filename).path) else {
                throw SetupError.gameDataMissing(filename)
            }
        }
        if emulateModeset != nil || cdromDataFilename != nil {
            // A changed warm profile is drained before Backend.prepare. Never
            // edit a registry that an active or external Wine session owns.
            guard !isBusy(), !WineServerProbe.mayBeAlive(prefix: prefix, environment: environment) else {
                throw SetupError.busy(requiredLayer?.id ?? engine.name)
            }
        }
        var ownedServerStarted = false
        var installedFromPackage = false
        if readMarker()?["bootstrapPending"] as? Bool == true {
            guard !isBusy() else { throw SetupError.busy(engine.name) }
            try quarantine(prefix)
        }
        if allowTemplate, !isReady, templatesRequested,
           !FileManager.default.fileExists(atPath: prefix.path) {
            ownedServerStarted = try prepareFromTemplate(requiredLayer: requiredLayer,
                emulateModeset: emulateModeset, cdromDataFilename: cdromDataFilename, gameDirectory: gameDirectory,
                checkCancellation: checkCancellation, beforeRegistration: beforeRegistration)
            // Successful template return means clone or ordinary package creation;
            // ownedServerStarted only describes the warm callback, not installation.
            installedFromPackage = true
        }
        try checkCancellation()
        if !ownedServerStarted { try applyModeset(emulateModeset) }
        // Read the current inventory once for this preparation. This is scoped
        // to one update, so later updates still see a replaced ENGINE.json.
        let manifest = try Data(contentsOf: engine.root.appendingPathComponent("ENGINE.json"))
        let stamp = BottleUpdateCatalogue.digest(manifest)
        let updating = !Self.isReady(engine: engine, prefix: prefix, stamp: stamp)
        if updating {
            guard !isBusy(), !WineServerProbe.mayBeAlive(prefix: prefix, environment: environment) else {
                throw SetupError.busy(requiredLayer?.id ?? engine.name)
            }
            try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
            try Data(stamp.utf8).write(to: prefix.appendingPathComponent(Self.updatingName), options: .atomic)
            if !(try updateByDifference(manifest: manifest)) {
                try create(checkCancellation: checkCancellation)
                installedFromPackage = true
            }
        }
        if let filename = cdromDataFilename, let directory = gameDirectory {
            // The first wineboot must initialize C: and Z: itself. Creating
            // system.reg for a CD drive before it changes --init to -u and
            // leaves a fresh bottle without those essential DOS mappings.
            guard !isBusy(), !WineServerProbe.mayBeAlive(prefix: prefix, environment: environment) else {
                throw SetupError.busy(requiredLayer?.id ?? engine.name)
            }
            // The first ordinary wineboot creates C:/Z:. Clone media is installed
            // on its unpublished staged prefix, before its bootstrap starts Wine.
            try prepareCDROM(gameDirectory: directory, filename: filename)
        }
        if let requiredLayer, !installedLayers.contains(requiredLayer.id) {
            try switchTo(requiredLayer)
        }
        //0093: bind a successful registration to engine bytes, physical package
        // path and codec bytes; relocation/update/replacement invalidates it.
        launchPhase("wicBegin")
        let dll = windows.appendingPathComponent("system32/windowscodecs.dll")
        guard FileManager.default.fileExists(atPath: dll.path) else {
            throw SetupError.missing("system32/windowscodecs.dll")
        }
        let codec = SHA256.hash(data: try Data(contentsOf: dll)).map { String(format: "%02x", $0) }.joined()
        let registration = ["engine": stamp, "engineRoot": engineRootPath, "codec": codec]
        // All prefix/module/layer replacement has finished. The warm backend may
        // now own the server used by WIC, instead of draining it and booting again.
        // Run even on a registration hit: Ready still needs a live owned session.
        try checkCancellation()
        if !ownedServerStarted { try beforeRegistration?() }
        if readMarker()?["wicRegistration"] as? [String: String] != registration {
            try refreshWICRegistration()
            try writeMarker(layers: installedLayers, wicRegistration: registration, stamp: stamp)
        }
        // Record installation identity only for files copied from this package.
        // An unchanged legacy Ready marker cannot attest its mutable DLLs.
        if installedFromPackage,
           let catalogue = try? currentCatalogue(layers: installedLayers, manifest: manifest) {
            let installed = try catalogue.recordingInstallation(prefix: prefix)
            try writeMarker(layers: installedLayers, wicRegistration: registration, updateInputs: installed, stamp: stamp)
        }
        if updating { try FileManager.default.removeItem(at: prefix.appendingPathComponent(Self.updatingName)) }
        launchPhase("wicEnd")
    }

    private var defaultLayerIDs: [String] {
        var installed: [GraphicsLayer] = []
        for layer in engine.graphics.layers where engine.incompleteLayers[layer.id] == nil {
            if !installed.contains(where: { engine.graphics.conflicts($0, layer) }) { installed.append(layer) }
        }
        return installed.map(\.id)
    }

    private func currentCatalogue(layers: [String], manifest: Data) throws -> BottleUpdateCatalogue? {
        try BottleUpdateCatalogue.make(manifest: manifest,
            engineRoot: engineRootPath, prefix: prefix, graphics: engine.graphics, layers: layers)
    }

    /// A changed release/translator stamp does not imply changed Wine setup.
    /// Missing history, relocation, registration/layer changes or foreign DLLs
    /// keep the established full route. No Wine command is used on the fast route.
    private func updateByDifference(manifest: Data) throws -> Bool {
        guard !isBusy(), !WineServerProbe.mayBeAlive(prefix: prefix, environment: environment) else {
            throw SetupError.busy(engine.name)
        }
        guard crashDialogIsDisabled(), let marker = readMarker(), let previousStamp = marker["engine"] as? String,
              marker["engineRoot"] as? String == engineRootPath,
              marker["layers"] as? [String] == defaultLayerIDs,
              let registration = marker["wicRegistration"] as? [String: String],
              registration["engine"] == previousStamp, registration["engineRoot"] == engineRootPath
        else { return false }
        do {
            let previous: BottleUpdateCatalogue
            if let object = marker["updateInputs"] {
                let stored = try JSONDecoder().decode(BottleUpdateCatalogue.self,
                    from: JSONSerialization.data(withJSONObject: object))
                guard stored.engine == previousStamp,
                      let verified = try stored.restored(prefix: prefix, package: engine.root) else { return false }
                previous = verified
            } else {
                let name = "bottle-inputs-" + previousStamp
                guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "BottleCatalogues")
                    ?? Bundle.module.url(forResource: name, withExtension: "json") else { return false }
                let data = try Data(contentsOf: url)
                guard BottleUpdateCatalogue.digest(data) == previousStamp,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["graphics"] != nil,
                      let value = try BottleUpdateCatalogue.make(manifest: data, engineRoot: engineRootPath, prefix: prefix,
                        graphics: GraphicsCatalog.load(manifest: object, engineRoot: engine.root), layers: defaultLayerIDs)
                else { return false }
                previous = value
            }
            guard registration["codec"] == previous.files["drive_c/windows/system32/windowscodecs.dll"]?.sha256,
                  let current = try currentCatalogue(layers: defaultLayerIDs, manifest: manifest),
                  let delta = try current.delta(from: previous, prefix: prefix) else { return false }
            try current.apply(delta, from: previous, prefix: prefix, package: engine.root)
            let codec = current.files["drive_c/windows/system32/windowscodecs.dll"]!.sha256
            let updatedRegistration = ["engine": current.engine, "engineRoot": engineRootPath, "codec": codec]
            // Commit last. Any failure leaves the old stamp and Ready=false for
            // the new engine; the existing full route repairs the prefix.
            let installed = try current.recordingInstallation(prefix: prefix)
            try writeMarker(layers: defaultLayerIDs, wicRegistration: updatedRegistration, updateInputs: installed, stamp: current.engine)
            log.note("bottle: delta update copied=\(delta.count) unchanged=\(current.files.count - delta.count); Wine setup inputs unchanged")
            return true
        } catch {
            log.note("bottle: delta update refused; using full preparation (\(type(of: error)))")
            return false
        }
    }

    private func crashDialogIsDisabled() -> Bool {
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8) else { return false }
        var wanted = false
        for line in text.components(separatedBy: .newlines) {
            if line.hasPrefix("[") { wanted = line.hasPrefix(#"[Software\\Wine\\WineDbg]"#) }
            if wanted, line == #""ShowCrashDialog"=dword:00000000"# { return true }
        }
        return false
    }

    /// Update only the global legacy display setting; preserve other registry
    /// entries and sections. Wine requires doubled backslashes in its disk format.
    private func applyModeset(_ enabled: Bool?) throws {
        guard let enabled else { return }
        guard !isBusy(), !WineServerProbe.mayBeAlive(prefix: prefix, environment: environment) else {
            throw SetupError.busy(engine.name)
        }
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let registry = prefix.appendingPathComponent("user.reg")
        let previous = FileManager.default.fileExists(atPath: registry.path)
            ? try String(contentsOf: registry, encoding: .utf8) : ""
        let updated = Self.modesetRegistry(previous, enabled: enabled)
        try Data(updated.utf8).write(to: registry, options: .atomic)
        let digest = SHA256.hash(data: Data(updated.utf8)).map { String(format: "%02x", $0) }.joined()
        log.note("profile: EmulateModeset=\(enabled ? "Y" : "N") global X11 Driver, offline before Wine; user.reg SHA256=\(digest)")
    }

    /// Preserve r5's global Wine display key, including unrelated registry values.
    static func modesetRegistry(_ previous: String, enabled: Bool) -> String {
        registrySetting(previous, section: "[Software\\\\Wine\\\\X11 Driver]",
                        name: "EmulateModeset", value: enabled ? "Y" : "N")
    }

    static func cdromRegistry(_ previous: String, drive: String) -> String {
        registrySetting(previous, section: "[Software\\\\Wine\\\\Drives]", name: drive, value: "cdrom")
    }

    private static func registrySetting(_ previous: String, section: String, name: String, value: String) -> String {
        let setting = "\"\(name)\"=\"\(value)\""
        var lines = (previous.isEmpty ? "WINE REGISTRY Version 2\n\n#arch=win64\n" : previous)
            .components(separatedBy: "\n")
        if let start = lines.firstIndex(where: { $0 == section || $0.hasPrefix(section + " ") }) {
            let end = ((start + 1)..<lines.count).first(where: { lines[$0].hasPrefix("[") }) ?? lines.count
            let kept = lines[(start + 1)..<end].filter { !$0.hasPrefix("\"\(name)\"=") }
            lines.replaceSubrange((start + 1)..<end, with: [setting] + kept)
        } else {
            lines += ["", section, setting, ""]
        }
        return lines.joined(separator: "\n")
    }

    /// Offline before bootstrap. The sealed seed never contains game media.
    private func prepareCDROM(gameDirectory: URL, filename: String) throws {
        let manager = FileManager.default
        let identity = SHA256.hash(data: Data(gameDirectory.resolvingSymlinksInPath().path.utf8))
            .map { String(format: "%02x", $0) }.joined()
        let directory = prefix.appendingPathComponent("media-cd/" + identity, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent(filename)
        let source = gameDirectory.appendingPathComponent(filename).resolvingSymlinksInPath()
        if let existing = try? manager.destinationOfSymbolicLink(atPath: file.path) {
            guard existing == source.path else { throw SetupError.graphicsMismatch("CD data mapping") }
        } else if (try? manager.attributesOfItem(atPath: file.path)) == nil {
            try manager.createSymbolicLink(at: file, withDestinationURL: source)
        } else {
            throw SetupError.graphicsMismatch("CD data mapping")
        }
        let devices = prefix.appendingPathComponent("dosdevices", isDirectory: true)
        try manager.createDirectory(at: devices, withIntermediateDirectories: true)
        let letters = Array("rstuvwxyfghijklmnopq")
        var chosen: String?
        let target = directory.resolvingSymlinksInPath().standardizedFileURL
        for letter in letters {
            let drive = "\(letter):"
            let link = devices.appendingPathComponent(drive)
            if let existing = try? manager.destinationOfSymbolicLink(atPath: link.path) {
                let resolved = URL(fileURLWithPath: existing, relativeTo: devices)
                    .resolvingSymlinksInPath().standardizedFileURL
                if resolved == target { chosen = drive; break }
            } else if (try? manager.attributesOfItem(atPath: link.path)) == nil {
                // The clone is still staged. A relative DOS mapping survives
                // transaction publication (rename staged prefix -> final prefix).
                try manager.createSymbolicLink(atPath: link.path, withDestinationPath: "../media-cd/" + identity)
                chosen = drive
                break
            }
        }
        guard let drive = chosen else { throw SetupError.noFreeMediaDrive }
        let registry = prefix.appendingPathComponent("system.reg")
        let previous = manager.fileExists(atPath: registry.path)
            ? try String(contentsOf: registry, encoding: .utf8) : ""
        let updated = Self.cdromRegistry(previous, drive: drive)
        try Data(updated.utf8).write(to: registry, options: .atomic)
        log.note("profile: game data mapped to \(drive) as cdrom, offline before Wine")
    }

    private var templatesRequested: Bool {
        ProcessInfo.processInfo.environment["MACRUNNER_BOTTLE_TEMPLATE"] != "0"
            && engine.localNameOnlyWineboot
    }

    /// Kept under the explicit data root. The acceptance driver moves all of this
    /// root to Flash Trash after collecting receipts; existing bottles are never
    /// offered to this function as a template or overwritten by its fallback.
    private func quarantine(_ item: URL) throws {
        let fm = FileManager.default
        let directory = EnginePaths.base.appendingPathComponent("FailedPrefixTransactions", isDirectory: true)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try fm.moveItem(at: item, to: directory.appendingPathComponent(UUID().uuidString))
    }

    private func drainOwnedSetup(_ env: [String: String]) throws {
        let outcome = try EngineProcess.run(engine.wineserver, ["-k"], environment: env, log: log)
        guard outcome.status == 0, !outcome.signaled else { throw SetupError.setupServerFailed(outcome.status) }
        EngineProcess.waitForServer(engine: engine, environment: env, log: log)
        guard !WineServerProbe.mayBeAlive(prefix: URL(fileURLWithPath: env["WINEPREFIX"]!), environment: env) else {
            throw SetupError.busy(engine.name)
        }
    }

    private func prepareFromTemplate(requiredLayer: GraphicsLayer?, emulateModeset: Bool?,
                                     cdromDataFilename: String?, gameDirectory: URL?, checkCancellation: () throws -> Void,
                                     beforeRegistration: (() throws -> Void)?) throws -> Bool {
        let fm = FileManager.default
        let manifest = try Data(contentsOf: engine.root.appendingPathComponent("ENGINE.json"))
        let generation = BottleTemplate.generation(manifest: manifest)
        let cache = EnginePaths.base.appendingPathComponent("BottleTemplates", isDirectory: true)
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let seed = cache.appendingPathComponent(generation, isDirectory: true)
        var receipt: BottleTemplate.Receipt
        do {
            receipt = try BottleTemplate.validate(seed, generation: generation)
            log.note("template: cache hit generation=\(generation)")
        } catch {
            if fm.fileExists(atPath: seed.path) { try quarantine(seed) }
            let build = cache.appendingPathComponent(".building-\(UUID().uuidString)", isDirectory: true)
            let source = build.appendingPathComponent("prefix", isDirectory: true)
            try fm.createDirectory(at: build, withIntermediateDirectories: true)
            launchPhase("templateGenerationBegin")
            do {
                // Missing/invalid template uses the existing ordinary creation in
                // the backend's OWN namespace. Cancellation and App lifetime must
                // not target another prefix while a hidden seed server is alive.
                try BottleSetup(engine: engine, prefix: prefix, environment: environment, log: log)
                    .prepareIfNeeded(requiredLayer: requiredLayer, allowTemplate: false, checkCancellation: checkCancellation)
                try drainOwnedSetup(environment)
                try checkCancellation()
                guard clonefile(prefix.path, source.path, 0) == 0 else {
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                let values = BottleTemplate.substitutions(engine: engine.root, prefix: prefix,
                    data: EnginePaths.data(for: engine), home: environment["HOME"] ?? "")
                try BottleTemplate.seal(source, generation: generation, values: values)
                receipt = try BottleTemplate.validate(source, generation: generation)
                try fm.moveItem(at: source, to: seed)
                try quarantine(build)
                launchPhase("templateGenerationEnd")
                log.note("template: ordinary first bottle published neutral generation=\(generation)")
                return false
            } catch {
                // A failed seed is never published. A failed stop is fail-closed,
                // rather than starting a second server on a still-live namespace.
                try drainOwnedSetup(environment)
                if fm.fileExists(atPath: build.path) { try quarantine(build) }
                log.note("template: generation failed, ordinary creation: \(error.localizedDescription)")
                if fm.fileExists(atPath: prefix.path) { try quarantine(prefix) }
                try checkCancellation()
                try ordinaryFallback(emulateModeset: emulateModeset, checkCancellation: checkCancellation)
                return false
            }
        }
        let values = BottleTemplate.substitutions(engine: engine.root, prefix: prefix,
            data: EnginePaths.data(for: engine), home: environment["HOME"] ?? "")
        launchPhase("templateCloneBegin")
        let cloned = try BottleTemplate.transaction(destination: prefix, clone: { staged in
            // Darwin clonefile recursively clones a directory on APFS, preserving
            // writable independence. No hardlinks and no system cp subprocess.
            guard clonefile(seed.path, staged.path, 0) == 0 else {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
            }
        }, prepare: { staged in
            try BottleTemplate.unseal(staged, receipt: receipt, values: values,
                engineStamp: engineStamp, engineRoot: engineRootPath)
            let setup = BottleSetup(engine: engine, prefix: staged, environment: environment, log: log)
            try setup.applyModeset(emulateModeset)
            if let filename = cdromDataFilename, let directory = gameDirectory {
                try setup.prepareCDROM(gameDirectory: directory, filename: filename)
            }
        }, bootstrap: {
            try checkCancellation()
            launchPhase("templateBootstrapBegin")
            if let beforeRegistration { try beforeRegistration() }
            else { try startSetupServer() }
            let arguments = beforeRegistration == nil
                ? ["C:\\windows\\system32\\cmd.exe", "/d", "/c", "exit", "0"]
                : [EngineLauncher.windowsPath(for: engine.programJobLauncher, prefix: prefix), "--ready"]
            let boot = try EngineProcess.run(engine.wine,
                arguments, environment: environment, log: log)
            if beforeRegistration == nil { EngineProcess.waitForServer(engine: engine, environment: environment, log: log) }
            guard boot.status == 0, !boot.signaled,
                  fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
                throw BottleTemplate.Failure.invalidBootstrap
            }
            launchPhase("templateBootstrapEnd")
        }, stop: { try drainOwnedSetup(environment) }, quarantine: { try quarantine($0) }, onFailure: { error in
            let failure = error as NSError
            log.note("template: transaction failure domain=\(failure.domain) code=\(failure.code)")
        }, fallback: {
            try checkCancellation()
            log.note("template: clone/bootstrap failed, ordinary creation")
            try ordinaryFallback(emulateModeset: emulateModeset, checkCancellation: checkCancellation)
        })
        launchPhase("templateCloneEnd")
        log.note("template: result=\(cloned ? "clone" : "ordinary") generation=\(generation)")
        return cloned && beforeRegistration != nil
    }

    private func ordinaryFallback(emulateModeset: Bool? = nil, checkCancellation: () throws -> Void) throws {
        do {
            try applyModeset(emulateModeset)
            try create(checkCancellation: checkCancellation)
        }
        catch {
            // Ordinary creation can fail too (e.g. ENOSPC). Preserve its evidence
            // outside Bottles, after scoped drain, without publishing partial state.
            try drainOwnedSetup(environment)
            if FileManager.default.fileExists(atPath: prefix.path) { try quarantine(prefix) }
            throw error
        }
    }

    private func launchPhase(_ name: String) {
        if ProcessInfo.processInfo.environment["MACRUNNER_LAUNCH_PHASES"] == "1" { log.mark(name) }
    }

    func refreshWICRegistration() throws {
        let dll = windows.appendingPathComponent("system32/windowscodecs.dll")
        guard FileManager.default.fileExists(atPath: dll.path) else {
            throw SetupError.missing("system32/windowscodecs.dll")
        }
        let registration = try EngineProcess.run(engine.wine,
            ["C:\\windows\\system32\\regsvr32.exe", "/s", "C:\\windows\\system32\\windowscodecs.dll"],
            environment: environment, log: log)
        guard registration.status == 0, !registration.signaled else {
            throw SetupError.wicRegistrationFailed(registration.status)
        }
        log.note("bottle: WIC registration refreshed engine=\(engineRootPath)")
    }

    private func create(checkCancellation: () throws -> Void = {}) throws {
        try checkCancellation()
        let fm = FileManager.default
        let fresh = !fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path)
        // Обновление под новый движок меняет модули бутылки — под идущей программой нельзя.
        if !fresh, isBusy() { throw SetupError.busy(engine.name) }
        try fm.createDirectory(at: prefix.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: prefix.path) {
            try fm.createDirectory(at: prefix, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        }
        log.note("bottle: \(fresh ? "create" : "update") \(prefix.path) engine=\(engine.name)")

        launchPhase("setupServerBootBegin")
        try startSetupServer()
        launchPhase("setupServerBootEnd")
        launchPhase("winebootBegin")
        // A fresh standalone command waits for the loader's automatic wineboot.
        // Explicit --init would reset that event and start services a second time.
        // Keep explicit -u for an existing bottle whose engine generation changed.
        let bootstrapArguments = fresh
            ? ["C:\\windows\\system32\\cmd.exe", "/d", "/c", "exit", "0"]
            : ["wineboot", "-u"]
        let boot = try EngineProcess.run(engine.wine, bootstrapArguments,
                                         environment: environment, log: log)
        launchPhase("winebootEnd")
        launchPhase("bootServerDrainBegin")
        EngineProcess.waitForServer(engine: engine, environment: environment, log: log)
        launchPhase("bootServerDrainEnd")
        guard boot.status == 0, fm.fileExists(atPath: prefix.appendingPathComponent("system.reg").path) else {
            throw SetupError.bootFailed(boot.status)
        }
        try checkCancellation()

        launchPhase("moduleSyncBegin")
        try syncModules()
        launchPhase("moduleSyncEnd")

        // Окно Wine «Program Error» со ссылкой на CodeWeavers игроку не поможет:
        // отказ покажет само приложение, по тексту движка из журнала.
        launchPhase("setupServerRegBegin")
        try checkCancellation()
        try startSetupServer()
        launchPhase("setupServerRegEnd")
        launchPhase("crashDialogRegBegin")
        _ = try EngineProcess.run(engine.wine, ["reg", "add", "HKCU\\Software\\Wine\\WineDbg",
                                                "/v", "ShowCrashDialog", "/t", "REG_DWORD", "/d", "0", "/f"],
                                  environment: environment, log: log)
        launchPhase("crashDialogRegEnd")
        launchPhase("regServerDrainBegin")
        EngineProcess.waitForServer(engine: engine, environment: environment, log: log)
        launchPhase("regServerDrainEnd")

        // Слои по умолчанию: все, что не спорят между собой за модули, в порядке пакета.
        var installed: [GraphicsLayer] = []
        launchPhase("graphicsInstallBegin")
        for layer in engine.graphics.layers where engine.incompleteLayers[layer.id] == nil {
            guard !installed.contains(where: { engine.graphics.conflicts($0, layer) }) else { continue }
            try install(layer)
            installed.append(layer)
        }
        launchPhase("graphicsInstallEnd")
        launchPhase("bottleMarkerBegin")
        try writeMarker(layers: installed.map(\.id))
        launchPhase("bottleMarkerEnd")
        log.note("bottle: ready layers=\(installed.map(\.id))")
    }

    /// Module staging drains Wine before copying DLLs. Use stock zero-idle for
    /// each isolated setup transaction instead of three idle seconds per drain.
    /// WIC/application then starts a NEW default server; its lifetime is unchanged.
    private func startSetupServer() throws {
        let server = try EngineProcess.run(engine.wineserver, ["-p0"], environment: environment, log: log)
        guard server.status == 0, !server.signaled else { throw SetupError.setupServerFailed(server.status) }
    }

    // MARK: - Слои графики

    /// Ставит слой целиком и сверяет каждый модуль с пакетом байт в байт.
    ///
    /// ★★★ 23.09 проверка без этого шага смешала DXMT `dxgi`/`winemetal` с ARM64 `d3d11`
    ///   самого Wine (его кладёт `wineboot`) и упала внутри него (разбор Astra,
    ///   APP-ENGINE-INTEGRATION-REVIEW-20260923). Разошлось — бутылка не готова.
    func install(_ layer: GraphicsLayer) throws {
        if let missing = engine.incompleteLayers[layer.id] {
            throw SetupError.missing(missing.joined(separator: ", "))
        }
        let windows = self.windows
        for (target, source) in engine.graphics.placements(of: layer).sorted(by: { $0.key < $1.key }) {
            let from = engine.root.appendingPathComponent(source)
            let to = windows.appendingPathComponent(target)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            try replace(from, to)
            guard FileManager.default.contentsEqual(atPath: from.path, andPath: to.path) else {
                throw SetupError.graphicsMismatch(target)
            }
        }
        log.note("bottle: layer \(layer.id) installed")
    }

    /// Снимает слой: на место его модулей возвращаются модули самого Wine (или ничего,
    /// если у Wine такого нет).
    func uninstall(_ layer: GraphicsLayer) throws {
        for target in engine.graphics.placements(of: layer).keys.sorted() {
            let to = windows.appendingPathComponent(target)
            let name = to.lastPathComponent
            let base = target.hasPrefix("syswow64/") ? "i386-windows" : "aarch64-windows"
            let original = wineLib.appendingPathComponent("\(base)/\(name)")
            if FileManager.default.fileExists(atPath: original.path) {
                try replace(original, to)
            } else {
                try? FileManager.default.removeItem(at: to)
            }
        }
        log.note("bottle: layer \(layer.id) removed")
    }

    /// Смена набора под маршрут. Под идущей программой — нельзя: она держит старые модули.
    private func switchTo(_ layer: GraphicsLayer) throws {
        guard !isBusy() else { throw SetupError.busy(layer.title) }
        var keep: [String] = []
        for id in installedLayers {
            guard let other = engine.graphics.layer(id) else { continue }
            if engine.graphics.conflicts(other, layer) { try uninstall(other) } else { keep.append(id) }
        }
        try install(layer)
        try writeMarker(layers: keep + [layer.id])
    }

    // MARK: - Модули (перенос sync-prefix-from-dist.sh, ветка FEX)

    private var wineLib: URL { engine.root.appendingPathComponent("wine/lib/wine") }
    private var windows: URL { prefix.appendingPathComponent("drive_c/windows") }

    /// Не `private`: проверяется тестами на поддельном дереве движка, без Wine.
    func syncModules() throws {
        let fm = FileManager.default
        let system32 = windows.appendingPathComponent("system32")
        let syswow64 = windows.appendingPathComponent("syswow64")
        for arch in ["aarch64-windows", "i386-windows", "x86_64-windows"] {
            guard fm.fileExists(atPath: wineLib.appendingPathComponent(arch).path) else {
                throw SetupError.missing("wine/lib/wine/\(arch)")
            }
        }

        // ntdll грузится из движка; копия в префиксе устарела бы при первом же обновлении.
        try? fm.removeItem(at: system32.appendingPathComponent("ntdll.dll"))
        try? fm.removeItem(at: syswow64.appendingPathComponent("ntdll.dll"))

        // FEX: системные модули — гибриды ARM64X из aarch64-windows, графика — x86_64.
        var copied = try copyArchSet("aarch64-windows", to: system32)
        copied += try copyArchSet("i386-windows", to: syswow64)

        let aarch64 = wineLib.appendingPathComponent("aarch64-windows")
        let x86_64 = wineLib.appendingPathComponent("x86_64-windows")
        let extras: [(URL, [URL])] = [
            (aarch64.appendingPathComponent("xtajit.dll"), [system32, syswow64]),
            (x86_64.appendingPathComponent("wow64cpu.dll"), [system32, syswow64]),
            (x86_64.appendingPathComponent("wow64.dll"), [syswow64]),
            (x86_64.appendingPathComponent("wow64win.dll"), [syswow64]),
        ]
        for (source, targets) in extras where fm.fileExists(atPath: source.path) {
            for dir in targets {
                try replace(source, dir.appendingPathComponent(source.lastPathComponent)); copied += 1
            }
        }
        try syncCommonControls()

        // wine.inf направляет TEMP в C:\windows\temp; Unity без него не создаёт окно.
        try fm.createDirectory(at: windows.appendingPathComponent("temp"), withIntermediateDirectories: true)
        log.note("bottle: synced \(copied) modules")
    }

    private func copyArchSet(_ arch: String, to target: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: target, withIntermediateDirectories: true)
        var count = 0
        for source in try fm.contentsOfDirectory(at: wineLib.appendingPathComponent(arch),
                                                 includingPropertiesForKeys: [.isRegularFileKey]) {
            let name = source.lastPathComponent
            guard name != "ntdll.dll", !name.hasSuffix(".a"),
                  (try? source.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            try replace(source, target.appendingPathComponent(name))
            count += 1
        }
        return count
    }

    /// comctl32 v6 в каталогах WinSxS: как `sync-prefix-from-dist.sh`, включая создание
    /// манифестов arm64/x86 из имеющегося, если их нет.
    private func syncCommonControls() throws {
        let fm = FileManager.default
        let winsxs = windows.appendingPathComponent("winsxs")
        guard fm.fileExists(atPath: winsxs.path) else { return }
        let sources = ["amd64": "x86_64-windows", "x86": "i386-windows", "arm64": "aarch64-windows"]

        func dirs(_ arch: String) -> [URL] {
            ((try? fm.contentsOfDirectory(at: winsxs, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.lastPathComponent.hasPrefix("\(arch)_microsoft.windows.common-controls")
                    && $0.lastPathComponent.contains("_6.") && !$0.lastPathComponent.hasSuffix(".manifest") }
        }
        /// Манифест для `arch` по образцу из `from`; возвращает false, если образца нет.
        func ensure(_ arch: String, from templates: [String]) throws -> Bool {
            let manifests = winsxs.appendingPathComponent("manifests")
            let all = (try? fm.contentsOfDirectory(at: manifests, includingPropertiesForKeys: nil)) ?? []
            for source in templates {
                guard let template = all.first(where: {
                    $0.lastPathComponent.hasPrefix("\(source)_microsoft.windows.common-controls")
                        && $0.lastPathComponent.contains("_6.") && $0.pathExtension == "manifest"
                }) else { continue }
                let rest = template.lastPathComponent.drop(while: { $0 != "_" }).dropFirst()
                let manifest = manifests.appendingPathComponent("\(arch)_\(rest)")
                try fm.createDirectory(at: winsxs.appendingPathComponent(manifest.deletingPathExtension().lastPathComponent),
                                       withIntermediateDirectories: true)
                if !fm.fileExists(atPath: manifest.path) {
                    let text = try String(contentsOf: template, encoding: .utf8)
                        .replacingOccurrences(of: #"processorArchitecture="(amd64|x86|arm64)""#,
                                              with: "processorArchitecture=\"\(arch)\"", options: .regularExpression)
                    try text.write(to: manifest, atomically: true, encoding: .utf8)
                }
                return true
            }
            return false
        }

        if dirs("arm64").isEmpty { _ = try ensure("arm64", from: ["amd64", "x86"]) }
        if dirs("x86").isEmpty { _ = try ensure("x86", from: ["arm64", "amd64"]) }
        for (arch, lib) in sources {
            let source = wineLib.appendingPathComponent("\(lib)/comctl32_v6.dll")
            guard fm.fileExists(atPath: source.path) else { continue }
            for dir in dirs(arch) {
                try replace(source, dir.appendingPathComponent("comctl32.dll"))
            }
        }
    }

    private func replace(_ source: URL, _ destination: URL) throws {
        // Удаляем без проверки: `fileExists` не видит висящую ссылку, а `copyItem`
        // на неё упадёт.
        try? FileManager.default.removeItem(at: destination)
        try FileManager.default.copyItem(at: source, to: destination)
    }
}
