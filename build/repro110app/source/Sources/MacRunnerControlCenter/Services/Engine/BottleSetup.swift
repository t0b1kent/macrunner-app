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
        /// Настройка на всю бутылку (RetinaMode) не совпадает с той, под которой в ней уже идёт программа.
        case settingsConflict

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
            case .settingsConflict:
                return L("Another program is still running in the same Windows environment with different settings. Close it and try again.")
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
                              updateInputs: BottleUpdateCatalogue? = nil,
                              registrationInputs: BottleUpdateCatalogue.RegistrationReceipt? = nil,
                              stamp: String? = nil) throws {
        var marker: [String: Any] = ["engine": stamp ?? engineStamp, "engineRoot": engineRootPath,
                                     "engineName": engine.name, "layers": layers,
                                     "prepared": ISO8601DateFormatter().string(from: Date())]
        if let wicRegistration { marker["wicRegistration"] = wicRegistration }
        if let updateInputs {
            marker["updateInputs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(updateInputs))
        }
        if let registrationInputs {
            marker["registrationInputs"] = try JSONSerialization.jsonObject(with: JSONEncoder().encode(registrationInputs))
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
                          retinaMode: Bool? = nil,
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
        var registrationAfterStaging = false
        if readMarker()?["bootstrapPending"] as? Bool == true {
            guard !isBusy() else { throw SetupError.busy(engine.name) }
            try quarantine(prefix)
        }
        if allowTemplate, !isReady, templatesRequested,
           !FileManager.default.fileExists(atPath: prefix.path) {
            ownedServerStarted = try prepareFromTemplate(requiredLayer: requiredLayer,
                emulateModeset: emulateModeset, retinaMode: retinaMode,
                cdromDataFilename: cdromDataFilename, gameDirectory: gameDirectory,
                checkCancellation: checkCancellation, beforeRegistration: beforeRegistration)
            // Successful template return means clone or ordinary package creation;
            // ownedServerStarted only describes the warm callback, not installation.
            installedFromPackage = true
        }
        try checkCancellation()
        if !ownedServerStarted {
            try applyModeset(emulateModeset)
            try applyRetina(retinaMode, profileModeset: emulateModeset)
        }
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
                registrationAfterStaging = true
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
            let inputs = registrationAfterStaging ? try catalogue.registrationReceipt(package: engine.root) : nil
            try writeMarker(layers: installedLayers, wicRegistration: registration, updateInputs: installed,
                            registrationInputs: inputs, stamp: stamp)
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
    /// keep the established full route. File copies are incremental; registration
    /// and host device refresh still use Wine's own setup transaction.
    private func updateByDifference(manifest: Data) throws -> Bool {
        guard !isBusy(), !WineServerProbe.mayBeAlive(prefix: prefix, environment: environment) else {
            throw SetupError.busy(engine.name)
        }
        // Every refusal names its reason in the log: in the field "no history" and
        // "a receipt identity moved" must be distinguishable (r9 answered silently).
        func refuse(_ reason: String) -> Bool {
            log.note("bottle: fast update refused: \(reason); using full preparation")
            return false
        }
        guard BottleUpdateCatalogue.classRuleEnabled else {
            return refuse("switched off by MACRUNNER_BOTTLE_FAST_CLASSES=0")
        }
        guard crashDialogIsDisabled() else { return refuse("ShowCrashDialog is not disabled in user.reg") }
        guard let marker = readMarker(), let previousStamp = marker["engine"] as? String else { return refuse("no bottle marker") }
        guard marker["engineRoot"] as? String == engineRootPath else { return refuse("engine root differs from the marker") }
        guard marker["layers"] as? [String] == defaultLayerIDs else { return refuse("default graphics layers differ from the marker") }
        guard let registration = marker["wicRegistration"] as? [String: String],
              registration["engine"] == previousStamp, registration["engineRoot"] == engineRootPath
        else { return refuse("WIC registration record missing or from another engine") }
        do {
            let previous: BottleUpdateCatalogue
            var trustedLegacy = false
            if let object = marker["updateInputs"] {
                let stored = try JSONDecoder().decode(BottleUpdateCatalogue.self,
                    from: JSONSerialization.data(withJSONObject: object))
                guard stored.engine == previousStamp,
                      let verified = try stored.restored(prefix: prefix, package: engine.root) else {
                    return refuse("stored catalogue does not restore")
                }
                previous = verified
            } else {
                let name = "bottle-inputs-" + previousStamp
                guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "BottleCatalogues")
                    ?? Bundle.module.url(forResource: name, withExtension: "json") else {
                    return refuse("no bundled catalogue for the previous engine")
                }
                let data = try Data(contentsOf: url)
                guard BottleUpdateCatalogue.digest(data) == previousStamp,
                      let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                      object["graphics"] != nil,
                      let value = try BottleUpdateCatalogue.make(manifest: data, engineRoot: engineRootPath, prefix: prefix,
                        graphics: GraphicsCatalog.load(manifest: object, engineRoot: engine.root), layers: defaultLayerIDs)
                else { return refuse("bundled catalogue unusable") }
                previous = value
                trustedLegacy = true
            }
            guard registration["codec"] == previous.files["drive_c/windows/system32/windowscodecs.dll"]?.sha256 else {
                return refuse("registered codec differs from the previous catalogue")
            }
            guard let current = try currentCatalogue(layers: defaultLayerIDs, manifest: manifest) else {
                return refuse("current catalogue unavailable")
            }
            // Closed by default. The route is allowed only for an engine pair that the release gate
            // approved (a record in the pair file shipped with this release); anything else takes the full route.
            var pairModes: [String: mode_t]? = nil
            var previousActual: [String: String] = [:]
            if !BottleUpdateCatalogue.pairGateMode {
                switch BottleUpdateCatalogue.pairLookup(file: Self.pairFileData(), from: previousStamp, to: current.engine) {
                case .refused(let reason): return refuse(reason)
                case .approved(let record): pairModes = record.modes; previousActual = record.fromActual
                }
            } else {
                previousActual = BottleUpdateCatalogue.pairGateActual
            }
            // A legacy bottle was written by the OLD app from the OLD package's real bytes. If that package's
            // inventory misdescribes some file, the signed record carries the real digest (see PairRecord.fromActual).
            let effective = trustedLegacy ? previous.correcting(previousActual) : previous
            if trustedLegacy, !previousActual.isEmpty {
                log.note("bottle: previous inventory corrected for \(previousActual.count) package file(s) by the engine-pair record")
            }
            let began = DispatchTime.now().uptimeNanoseconds
            let normalisation = BottleUpdateCatalogue.Normalisation.current
            let decision = try current.deltaDecision(from: effective, prefix: prefix, package: engine.root,
                                                      classRule: true, trustedLegacy: trustedLegacy,
                                                      normalisation: normalisation)
            guard case .delta(let delta) = decision else {
                if case .refuse(let reason) = decision { return refuse(reason) }
                return false
            }
            if trustedLegacy {
                log.note("bottle: legacy bottle adopted by SHA-256 of \(effective.files.count) targets in \((DispatchTime.now().uptimeNanoseconds - began) / 1_000_000) ms")
            }
            let decided = DispatchTime.now().uptimeNanoseconds
            let registrationInputs = try current.registrationReceipt(package: engine.root)
            var registrationCurrent = false
            var registrationPrevious = false
            if let expected = registrationInputs, let object = marker["registrationInputs"],
               let data = try? JSONSerialization.data(withJSONObject: object),
               let stored = try? JSONDecoder().decode(BottleUpdateCatalogue.RegistrationReceipt.self, from: data) {
                registrationCurrent = stored == expected
                registrationPrevious = stored == (try effective.registrationReceipt(package: engine.root))
            }
            try current.apply(delta, from: effective, prefix: prefix, package: engine.root)
            let applied = DispatchTime.now().uptimeNanoseconds
            // Older markers do not prove post-staging i386 registration. Enroll
            // them once. A valid receipt permits zero registrations, but devices
            // still need their cold initialization (plain cmd omits displays and printers).
            let beforeSetup = try current.recordingInstallation(prefix: prefix)
            if registrationCurrent, syncUpdateTimestamp() {
                try refreshDevicesOnly()
                log.note("bottle: registration inputs unchanged; registration calls=0; devices refreshed")
            } else if registrationPrevious,
                      let selection = try current.registrationSelection(from: effective, package: engine.root) {
                try refreshDeltaRegistration(selection: selection)
                log.note("bottle: selective registration calls=\(selection.values.reduce(0) { $0 + $1.count }); devices refreshed")
            } else {
                try refreshDeltaRegistration()
                log.note("bottle: post-staging registration completed; receipt enrolled")
            }
            let repaired = try current.repairSetupChanges(from: beforeSetup, prefix: prefix, package: engine.root)
            log.note("bottle: repaired \(repaired.count) setup-mutated files")
            if let pairModes { try applyFullRouteModes(current, modes: pairModes) }
            let normalised = DispatchTime.now().uptimeNanoseconds
            let codec = current.files["drive_c/windows/system32/windowscodecs.dll"]!.sha256
            let updatedRegistration = ["engine": current.engine, "engineRoot": engineRootPath, "codec": codec]
            // Commit last. Any failure leaves the old stamp and Ready=false for
            // the new engine; the existing full route repairs the prefix.
            let installed = try current.recordingInstallation(prefix: prefix)
            let receipted = DispatchTime.now().uptimeNanoseconds
            try writeMarker(layers: defaultLayerIDs, wicRegistration: updatedRegistration, updateInputs: installed,
                            registrationInputs: registrationInputs, stamp: current.engine)
            let done = DispatchTime.now().uptimeNanoseconds
            log.note("bottle: delta update copied=\(delta.count) unchanged=\(current.files.count - delta.count); registration current; devices refreshed")
            log.note("bottle: fast update phases decision=\((decided - began) / 1_000) us apply=\((applied - decided) / 1_000) us fixups=\((normalised - applied) / 1_000) us receipt=\((receipted - normalised) / 1_000) us marker=\((done - receipted) / 1_000) us")
            return true
        } catch let failure as BottleUpdateCatalogue.NormalisationFailure {
            // after the files are in place: the next full route repairs the prefix (marker not committed)
            log.note("bottle: fast update stopped after the copy: \(failure.reason); using full preparation")
            return false
        } catch {
            log.note("bottle: delta update refused; using full preparation (\(type(of: error)))")
            return false
        }
    }

    /// Enroll both registration views with observed results. Wineboot does not
    /// propagate failed DLL registrations or an EXE's exit code. A small INF
    /// section runs only registrations; the helper checks every callback and
    /// runs each EXE itself. Device discovery remains a separate operation.
    private func refreshDeltaRegistration(selection: [String: [String]]? = nil) throws {
        guard syncUpdateTimestamp() else { throw SetupError.missing("Wine update timestamp") }
        func resource(_ name: String, _ ext: String) throws -> URL {
            guard let url = Bundle.module.url(forResource: name, withExtension: ext, subdirectory: "BottleTools")
                    ?? Bundle.module.url(forResource: name, withExtension: ext) else {
                throw SetupError.missing("bottle registration helper")
            }
            return url
        }
        func windowsPath(_ url: URL) -> String { "Z:" + url.path.replacingOccurrences(of: "/", with: "\\") }
        let wrapper = try resource("checked-registration", "inf")
        let inf = engine.root.appendingPathComponent("wine/share/wine/wine.inf")
        let temporary = prefix.appendingPathComponent(".macrunner-registration-\(UUID().uuidString)")
        if selection != nil { try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false) }
        defer { if selection != nil { try? FileManager.default.removeItem(at: temporary) } }
        for view in ["native", "32"] {
            var selectedINF = inf
            if let selection {
                let rows = selection[view] ?? []
                if rows.isEmpty { continue }
                selectedINF = temporary.appendingPathComponent(view + ".inf")
                try ("[Version]\nSignature=\"$Windows NT$\"\n[RegisterDllsSection]\n" + rows.joined(separator: "\n") + "\n")
                    .write(to: selectedINF, atomically: true, encoding: .utf8)
            }
            let helper = try resource("macrunner-bottle-register-" + view, "exe")
            try startSetupServer()
            let outcome = try EngineProcess.run(engine.wine, [helper.path, windowsPath(selectedINF), windowsPath(wrapper)],
                                                environment: environment, log: log)
            EngineProcess.waitForServer(engine: engine, environment: environment, log: log)
            guard outcome.status == 0, !outcome.signaled else { throw SetupError.bootFailed(outcome.status) }
        }
        try refreshDevicesOnly()
    }

    /// regsvr32's OLE/display initialization updates devices BEFORE loading WIC.
    /// Use that initialization directly, plus Wine's printer discovery, without
    /// calling any DLL registration entrypoint or forcing the INF to run again.
    private func refreshDevicesOnly() throws {
        guard let helper = Bundle.module.url(forResource: "macrunner-bottle-devices", withExtension: "exe", subdirectory: "BottleTools")
                ?? Bundle.module.url(forResource: "macrunner-bottle-devices", withExtension: "exe") else {
            throw SetupError.missing("bottle device preparation helper")
        }
        try startSetupServer()
        let outcome = try EngineProcess.run(engine.wine, [helper.path, "spool"], environment: environment, log: log)
        EngineProcess.waitForServer(engine: engine, environment: environment, log: log)
        guard outcome.status == 0, !outcome.signaled else { throw SetupError.bootFailed(outcome.status) }
        try finishSetupRefresh()
    }

    private func finishSetupRefresh() throws {
        guard !WineServerProbe.mayBeAlive(prefix: prefix, environment: environment) else {
            throw SetupError.busy(engine.name)
        }
        // syncModules deliberately excludes ntdll; Wine's INF puts it back.
        for arch in ["system32", "syswow64"] {
            let file = windows.appendingPathComponent("\(arch)/ntdll.dll")
            if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
        }
    }

    /// The pair file shipped with the release (`BottleCatalogues/bottle-fast-pairs.json`, written by the release gate).
    private static func pairFileData() -> Data? {
        if let override = BottleUpdateCatalogue.pairFileOverride { return try? Data(contentsOf: override) }
        let name = "bottle-fast-pairs"
        guard let url = Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "BottleCatalogues")
                ?? Bundle.module.url(forResource: name, withExtension: "json") else { return nil }
        return try? Data(contentsOf: url)
    }

    /// Permission bits of the modules `wineboot -u` re-creates, as the gate measured them for this engine pair.
    private func applyFullRouteModes(_ current: BottleUpdateCatalogue, modes: [String: mode_t]) throws {
        let changed = try current.applyModes(modes, prefix: prefix)
        if !changed.isEmpty { log.note("bottle: permission bits aligned to the full route on \(changed.count) modules") }
    }

    /// Repairs the one registry group that only `wineboot -u` would have rewritten. The bottle is stopped
    /// (checked at the start of the route). `text`: rewrite system.reg through a new file and a rename;
    /// `regsvr32`: reference arm, one Wine process; `refuse`: the decision already stopped the route.
    private func normaliseShell32(strategy: BottleUpdateCatalogue.Normalisation) throws {
        guard BottleUpdateCatalogue.unnormalisedRegistration(prefix: prefix, engineRoot: engineRootPath) != nil else { return }
        guard !isBusy(), !WineServerProbe.mayBeAlive(prefix: prefix, environment: environment) else {
            throw SetupError.busy(engine.name)
        }
        switch strategy {
        case .refuse:
            throw BottleUpdateCatalogue.NormalisationFailure(reason: "registry normalisation refused")
        case .text:
            let replaced = try BottleUpdateCatalogue.normaliseRegistry(prefix: prefix, engineRoot: engineRootPath)
            log.note("bottle: shell32 registration normalised in system.reg (\(replaced) values, no Wine)")
        case .regsvr32:
            try startSetupServer()
            let outcome = try EngineProcess.run(engine.wine, ["C:\\windows\\system32\\regsvr32.exe", "/s", "C:\\windows\\system32\\shell32.dll"],
                                               environment: environment, log: log)
            EngineProcess.waitForServer(engine: engine, environment: environment, log: log)
            guard outcome.status == 0, !outcome.signaled else { throw SetupError.wicRegistrationFailed(outcome.status) }
            log.note("bottle: shell32 registered with Wine (reference arm)")
        }
        guard BottleUpdateCatalogue.unnormalisedRegistration(prefix: prefix, engineRoot: engineRootPath) == nil else {
            throw BottleUpdateCatalogue.NormalisationFailure(reason: "shell32 registration still names the package")
        }
    }

    /// wineboot compares `.update-timestamp` with the mtime of wine.inf at every cold server start and
    /// re-runs the whole INF when they differ (wineboot.c update_timestamp). The full route leaves the
    /// current mtime there; the fast route must leave the same number, or the first program start pays
    /// for the INF.
    @discardableResult private func syncUpdateTimestamp() -> Bool {
        let file = prefix.appendingPathComponent(".update-timestamp")
        var info = stat()
        let inf = engine.root.appendingPathComponent("wine/share/wine/wine.inf").path
        guard stat(inf, &info) == 0, let old = try? String(contentsOf: file, encoding: .utf8) else { return false }
        if let text = Self.alignedTimestamp(existing: old, infMtime: UInt64(info.st_mtimespec.tv_sec)) {
            do { try Data(text.utf8).write(to: file, options: .atomic) } catch { return false }
            log.note("bottle: .update-timestamp aligned to wine.inf mtime")
        }
        return true
    }

    /// nil = already the number wineboot would write. wineboot (a PE program, text-mode file) writes
    /// "<mtime>\r\n" and compares with strtoul, so equality is by NUMBER and a rewrite keeps CRLF
    /// (a bare LF would be a byte difference against the full route).
    static func alignedTimestamp(existing: String, infMtime: UInt64) -> String? {
        let first = existing.prefix { $0.isNumber }
        if let value = UInt64(first), value == infMtime { return nil }
        return "\(infMtime)\r\n"
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

    // MARK: - Высокое разрешение (Retina)

    /// ★ RetinaMode winemac читает ТОЛЬКО из HKCU\Software\Wine\Mac Driver, без AppDefaults
    ///   (`macdrv_main.c`, setup_options: «DPI и размеры мониторов должны совпадать у всех процессов
    ///   префикса»), и один раз — при старте процесса. Значит, настройка общая на бутылку и
    ///   меняется только при остановленном Wine: бегущий wineserver держит реестр в памяти и
    ///   при выходе перезапишет файл. Поэтому — как EmulateModeset: правка user.reg до Wine,
    ///   а тёплая сессия с другим значением сначала гасится (`WarmBottleSessions.signature`).
    static let macDriverSection = "[Software\\\\Wine\\\\Mac Driver]"
    static let desktopSection = "[Control Panel\\\\Desktop]"
    /// Метка «LogPixels поставили мы» — чтобы снять только своё значение, а не чужую настройку DPI.
    static let retinaLogPixelsMarker = ".macrunner-retina-logpixels"
    static let retinaLogPixelsLine = "\"LogPixels\"=dword:000000c0"

    /// Рука испытания, по умолчанию выключена: вместе с RetinaMode удвоить DPI (LogPixels 96 → 192),
    /// как High Resolution Mode у CrossOver. ★ В нашем Wine 11 системный DPI 192 включает
    ///   виртуализацию для программ без объявленной DPI-осведомлённости (win32u, monitor_get_dpi):
    ///   такая игра снова видит 1512×982 и растягивается. В манифесте eldenring.exe dpiAware нет.
    static var retinaLogPixelsRequested: Bool {
        ProcessInfo.processInfo.environment["MACRUNNER_RETINA_LOGPIXELS"] == "1"
    }

    /// ★ Полный список разрешений вместе с Retina (03.11, куратор: «включено = игра видит полный список разрешений этого
    ///   Мака»). У встроенного экрана в списке macOS нет ни одного режима 16:9 (прибор RETINA tools/modelist); их даёт только
    ///   эмуляция смены режима Wine (EmulateModeset, win32u get_virtual_modes: 1600×900, 1920×1080, 2560×1440, 2880×1620 до
    ///   родного). Поэтому включённый переключатель ставит и EmulateModeset=Y — если его не задаёт профиль игры (у Heroes III
    ///   и Diablo он свой). Предыдущее значение хранится в метке и возвращается при выключении. Рука испытания
    ///   `MACRUNNER_RETINA_EMULATE_MODESET=0` (ключ процесса приложения) — Retina без эмуляции.
    static let retinaModesetMarker = ".macrunner-retina-modeset"
    static var retinaModesetRequested: Bool {
        ProcessInfo.processInfo.environment["MACRUNNER_RETINA_EMULATE_MODESET"] != "0"
    }
    private static let x11DriverSection = "[Software\\\\Wine\\\\X11 Driver]"

    /// Включён ли RetinaMode в тексте user.reg: первая буква значения y/Y/t/T/1 (IS_OPTION_TRUE winemac).
    static func retinaEnabled(in registry: String) -> Bool {
        guard let value = registryValueText(registry, section: macDriverSection, name: "RetinaMode"),
              value.hasPrefix("\""), let first = value.dropFirst().first else { return false }
        return "yYtT1".contains(first)
    }

    /// Состояние RetinaMode бутылки сейчас (фоновой тёплой сессии — чтобы не гасить её зря).
    static func retinaModeInRegistry(prefix: URL) -> Bool {
        guard let text = try? String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8) else { return false }
        return retinaEnabled(in: text)
    }

    /// true — `"RetinaMode"="y"`; false — значения нет (умолчание Wine). Уже как надо — тот же текст
    /// побайтно: повторный запуск файл не трогает.
    static func retinaRegistry(_ previous: String, enabled: Bool) -> String {
        if enabled, registryValueText(previous, section: macDriverSection, name: "RetinaMode") == "\"y\"" { return previous }
        return registryValue(previous, section: macDriverSection, name: "RetinaMode",
                             line: enabled ? "\"RetinaMode\"=\"y\"" : nil)
    }

    /// RetinaMode, полный список режимов (EmulateModeset, если его не задал профиль) и по руке испытания LogPixels —
    /// в user.reg, офлайн до Wine. nil — не трогать.
    func applyRetina(_ enabled: Bool?, profileModeset: Bool? = nil) throws {
        guard let enabled else { return }
        let fm = FileManager.default
        let registry = prefix.appendingPathComponent("user.reg")
        let marker = prefix.appendingPathComponent(Self.retinaLogPixelsMarker)
        let previous = fm.fileExists(atPath: registry.path) ? try String(contentsOf: registry, encoding: .utf8) : ""
        let wantDPI = enabled && Self.retinaLogPixelsRequested
        let ownDPI = fm.fileExists(atPath: marker.path)
        var updated = Self.retinaRegistry(previous, enabled: enabled)
        let dpi = Self.registryValueText(updated, section: Self.desktopSection, name: "LogPixels")
        if wantDPI, dpi != "dword:000000c0" {
            updated = Self.registryValue(updated, section: Self.desktopSection, name: "LogPixels", line: Self.retinaLogPixelsLine)
        } else if !wantDPI, ownDPI, dpi == "dword:000000c0" {
            updated = Self.registryValue(updated, section: Self.desktopSection, name: "LogPixels", line: nil)
        }
        // EmulateModeset — компаньон Retina: ставим, только если его не задаёт профиль; прежнее значение — в метке.
        let modesetMarker = prefix.appendingPathComponent(Self.retinaModesetMarker)
        let ownModeset = fm.fileExists(atPath: modesetMarker.path)
        let wantModeset = enabled && Self.retinaModesetRequested && profileModeset == nil
        let modesetBefore = Self.registryValueText(updated, section: Self.x11DriverSection, name: "EmulateModeset")
        var modesetPrevious: String? = nil   // для метки: текст значения до нас, "" — значения не было
        if wantModeset, !ownModeset {
            modesetPrevious = modesetBefore ?? ""
            if modesetBefore != "\"Y\"" {
                updated = Self.registryValue(updated, section: Self.x11DriverSection, name: "EmulateModeset", line: "\"EmulateModeset\"=\"Y\"")
            }
        } else if !wantModeset, ownModeset {
            let stored = (try? String(contentsOf: modesetMarker, encoding: .utf8)) ?? ""
            // Профиль задал своё значение — оно главнее; иначе возвращаем прежнее (или снимаем).
            if profileModeset == nil {
                updated = Self.registryValue(updated, section: Self.x11DriverSection, name: "EmulateModeset",
                                             line: stored.isEmpty ? nil : "\"EmulateModeset\"=" + stored)
            }
        }
        let markerChange = (wantModeset != ownModeset)
        let state = "RetinaMode=\(enabled ? "y" : "off") EmulateModeset=\(wantModeset ? "Y (full mode list)" : ownModeset ? "restored" : "untouched") LogPixels=\(wantDPI ? "192 (trial arm)" : ownDPI ? "restored" : "untouched")"
        guard updated != previous || wantDPI != ownDPI || markerChange else {
            log.note("profile: \(state) already in user.reg (HKCU Mac Driver); unchanged")
            return
        }
        // Бегущий wineserver держит реестр в памяти и при выходе запишет старое значение поверх.
        // Меняются только метки (реестр уже как надо) — Wine не мешает.
        if updated != previous {
            guard !isBusy(), !WineServerProbe.mayBeAlive(prefix: prefix, environment: environment) else {
                throw SetupError.settingsConflict
            }
        }
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        if updated != previous { try Data(updated.utf8).write(to: registry, options: .atomic) }
        if wantDPI, !ownDPI { try Data().write(to: marker, options: .atomic) }
        if !wantDPI, ownDPI { try fm.removeItem(at: marker) }
        if let modesetPrevious { try Data(modesetPrevious.utf8).write(to: modesetMarker, options: .atomic) }
        if !wantModeset, ownModeset { try fm.removeItem(at: modesetMarker) }
        let digest = SHA256.hash(data: Data(updated.utf8)).map { String(format: "%02x", $0) }.joined()
        log.note("profile: \(state) (HKCU Mac Driver), offline before Wine; user.reg SHA256=\(digest)")
    }

    /// Текст значения после `=` в разделе (`"y"`, `dword:000000c0`); имя без учёта регистра, как в Wine.
    static func registryValueText(_ text: String, section: String, name: String) -> String? {
        let key = "\"" + name.lowercased() + "\"="
        let lines = text.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0 == section || $0.hasPrefix(section + " ") }) else { return nil }
        let end = ((start + 1)..<lines.count).first(where: { lines[$0].hasPrefix("[") }) ?? lines.count
        for line in lines[(start + 1)..<end] where line.lowercased().hasPrefix(key) {
            return String(line.dropFirst(key.count))
        }
        return nil
    }

    /// Ставит (`line` задан) или снимает (`nil`) одно значение раздела, остальное — побайтно.
    /// Новое значение встаёт после заголовка и его строк `#time=`; нет раздела — он дописывается
    /// в конец, как его записал бы Wine. Раздел, где после снятия не осталось значений,
    /// убирается вместе с пустой строкой перед ним: «добавил — снял» возвращает исходный файл.
    static func registryValue(_ previous: String, section: String, name: String, line: String?) -> String {
        let key = "\"" + name.lowercased() + "\"="
        var lines = previous.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: { $0 == section || $0.hasPrefix(section + " ") }) else {
            guard let line else { return previous }
            lines = (previous.isEmpty ? "WINE REGISTRY Version 2\n\n#arch=win64\n" : previous).components(separatedBy: "\n")
            if lines.last != "" { lines.append("") }
            lines.insert(contentsOf: ["", section, line], at: lines.count - 1)
            return lines.joined(separator: "\n")
        }
        let end = ((start + 1)..<lines.count).first(where: { lines[$0].hasPrefix("[") }) ?? lines.count
        let existing = ((start + 1)..<end).filter { lines[$0].lowercased().hasPrefix(key) }
        if line == nil, existing.isEmpty { return previous }
        if let line, existing.count == 1, lines[existing[0]] == line { return previous }
        for index in existing.reversed() { lines.remove(at: index) }
        let sectionEnd = end - existing.count
        if let line {
            var insert = start + 1
            while insert < sectionEnd, lines[insert].hasPrefix("#") { insert += 1 }
            lines.insert(line, at: insert)
        } else if lines[(start + 1)..<sectionEnd].allSatisfy({ $0.isEmpty || $0.hasPrefix("#") }) {
            var stop = sectionEnd
            while stop > start + 1, lines[stop - 1].isEmpty { stop -= 1 }
            let from = start > 0 && lines[start - 1].isEmpty ? start - 1 : start
            lines.removeSubrange(from..<stop)
        }
        return lines.joined(separator: "\n")
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

    private func prepareFromTemplate(requiredLayer: GraphicsLayer?, emulateModeset: Bool?, retinaMode: Bool?,
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
                try ordinaryFallback(emulateModeset: emulateModeset, retinaMode: retinaMode, checkCancellation: checkCancellation)
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
            try setup.applyRetina(retinaMode, profileModeset: emulateModeset)
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
            try ordinaryFallback(emulateModeset: emulateModeset, retinaMode: retinaMode, checkCancellation: checkCancellation)
        })
        launchPhase("templateCloneEnd")
        log.note("template: result=\(cloned ? "clone" : "ordinary") generation=\(generation)")
        return cloned && beforeRegistration != nil
    }

    private func ordinaryFallback(emulateModeset: Bool? = nil, retinaMode: Bool? = nil,
                                  checkCancellation: () throws -> Void) throws {
        do {
            try applyModeset(emulateModeset)
            try applyRetina(retinaMode, profileModeset: emulateModeset)
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

        // Both architecture sets must exist BEFORE the INF registers them.
        // In particular, the first boot's i386 placeholders cannot attest a
        // later staged installation. The post-boot sync below restores files
        // that Wine setup itself replaces.
        launchPhase("preRegistrationModuleSyncBegin")
        try syncModules()
        launchPhase("preRegistrationModuleSyncEnd")

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
        let layers = installed.map(\.id)
        let manifest = try Data(contentsOf: engine.root.appendingPathComponent("ENGINE.json"))
        if let catalogue = try currentCatalogue(layers: layers, manifest: manifest) {
            let beforeSetup = try catalogue.recordingInstallation(prefix: prefix)
            try refreshDeltaRegistration()
            _ = try catalogue.repairSetupChanges(from: beforeSetup, prefix: prefix, package: engine.root)
            let codec = try BottleUpdateCatalogue.digest(windows.appendingPathComponent("system32/windowscodecs.dll"))
            let registration = ["engine": engineStamp, "engineRoot": engineRootPath, "codec": codec]
            try writeMarker(layers: layers, wicRegistration: registration)
        } else {
            // Older unclassified packages keep their full path, without a
            // checked-registration receipt to authorize later skipping.
            try writeMarker(layers: layers)
        }
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
