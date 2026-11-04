import Darwin
import Foundation
import Testing
@testable import MacRunnerControlCenter

/// «Высокое разрешение (Retina)»: запись RetinaMode в user.reg бутылки. Без Wine, окна и игры:
/// реестр — текст, бутылка — каталог во временной папке, «живой wineserver» — свой сокет.
@Suite(.serialized)
struct RetinaModeTests {
    /// Кусок user.reg в том виде, в каком его сохраняет wineserver (заголовок с временем, `#time=`).
    static let wineSaved = """
    WINE REGISTRY Version 2
    ;; All keys relative to REGISTRY\\\\User\\\\S-1-5-21-0-0-0-1000

    #arch=win64

    [Control Panel\\\\Desktop] 1791175682
    #time=1dd5484b436e860
    "ActiveWndTrackTimeout"=dword:00000000
    "CaretWidth"=dword:00000001

    [Software\\\\Wine\\\\Fonts] 1793650279
    #time=1dd6b0652e1cb64
    "LogPixels"=dword:00000060

    """

    @Test func enablingWritesMacDriverKeyAndIsIdempotent() {
        let on = BottleSetup.retinaRegistry(Self.wineSaved, enabled: true)
        #expect(on.contains("[Software\\\\Wine\\\\Mac Driver]\n\"RetinaMode\"=\"y\"\n"))
        #expect(on.hasPrefix(Self.wineSaved))
        #expect(BottleSetup.retinaEnabled(in: on))
        #expect(!BottleSetup.retinaEnabled(in: Self.wineSaved))
        // Повторный запуск — тот же текст побайтно: файл не переписывается.
        #expect(BottleSetup.retinaRegistry(on, enabled: true) == on)
        // Снять — вернуть исходный файл побайтно.
        #expect(BottleSetup.retinaRegistry(on, enabled: false) == Self.wineSaved)
        #expect(BottleSetup.retinaRegistry(Self.wineSaved, enabled: false) == Self.wineSaved)
    }

    @Test func freshBottleGetsWineHeader() {
        let fresh = BottleSetup.retinaRegistry("", enabled: true)
        #expect(fresh == "WINE REGISTRY Version 2\n\n#arch=win64\n\n[Software\\\\Wine\\\\Mac Driver]\n\"RetinaMode\"=\"y\"\n")
        #expect(BottleSetup.retinaRegistry("", enabled: false) == "")
    }

    @Test func wineSavedSectionIsRemovedWholeAndOtherValuesSurvive() {
        // Wine сохранил наш раздел со временем: снятие убирает раздел целиком.
        let saved = Self.wineSaved + "\n[Software\\\\Wine\\\\Mac Driver] 1793650300\n#time=1dd6b0652e1cb99\n\"RetinaMode\"=\"y\"\n"
        #expect(BottleSetup.retinaEnabled(in: saved))
        #expect(BottleSetup.retinaRegistry(saved, enabled: false) == Self.wineSaved)
        // Чужая настройка того же раздела остаётся; значение встаёт после #time=.
        let other = Self.wineSaved + "\n[Software\\\\Wine\\\\Mac Driver] 1\n#time=2\n\"LeftOptionIsAlt\"=\"y\"\n\"RetinaMode\"=\"n\"\n"
        let on = BottleSetup.retinaRegistry(other, enabled: true)
        #expect(on.contains("[Software\\\\Wine\\\\Mac Driver] 1\n#time=2\n\"RetinaMode\"=\"y\"\n\"LeftOptionIsAlt\"=\"y\"\n"))
        #expect(!on.contains("\"RetinaMode\"=\"n\""))
        let off = BottleSetup.retinaRegistry(on, enabled: false)
        #expect(off.contains("\"LeftOptionIsAlt\"=\"y\""))
        #expect(!BottleSetup.retinaEnabled(in: off))
        #expect(off.contains("[Software\\\\Wine\\\\Mac Driver] 1\n#time=2\n"))
    }

    @Test func retinaValueIsReadLikeWinemac() {
        func registry(_ value: String, section: String = "[Software\\\\Wine\\\\Mac Driver]") -> String {
            "WINE REGISTRY Version 2\n\n\(section) 5\n\"RetinaMode\"=\(value)\n"
        }
        for value in ["\"y\"", "\"Y\"", "\"1\"", "\"true\"", "\"T\""] { #expect(BottleSetup.retinaEnabled(in: registry(value)), "\(value)") }
        for value in ["\"n\"", "\"0\"", "\"\"", "dword:00000001"] { #expect(!BottleSetup.retinaEnabled(in: registry(value)), "\(value)") }
        #expect(BottleSetup.retinaEnabled(in: "WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\Mac Driver]\n\"retinamode\"=\"y\"\n"))
        // Значение в другом разделе (AppDefaults) winemac для RetinaMode не читает.
        #expect(!BottleSetup.retinaEnabled(in: registry("\"y\"", section: "[Software\\\\Wine\\\\AppDefaults\\\\eldenring.exe\\\\Mac Driver]")))
    }

    @Test func logPixelsTrialArmRoundTrip() {
        let dpi = BottleSetup.registryValue(Self.wineSaved, section: BottleSetup.desktopSection, name: "LogPixels",
                                            line: BottleSetup.retinaLogPixelsLine)
        #expect(dpi.contains("[Control Panel\\\\Desktop] 1791175682\n#time=1dd5484b436e860\n\"LogPixels\"=dword:000000c0\n\"ActiveWndTrackTimeout\""))
        #expect(BottleSetup.registryValueText(dpi, section: BottleSetup.desktopSection, name: "logpixels") == "dword:000000c0")
        // Шрифтовой LogPixels в другом разделе не тронут.
        #expect(dpi.contains("[Software\\\\Wine\\\\Fonts] 1793650279\n#time=1dd6b0652e1cb64\n\"LogPixels\"=dword:00000060"))
        #expect(BottleSetup.registryValue(dpi, section: BottleSetup.desktopSection, name: "LogPixels", line: nil) == Self.wineSaved)
    }

    @Test func runAppEntryFlagIsNotPassedToTheGame() throws {
        let options = try AppPathCLI.acceptanceArguments(["--high-resolution", "-windowed"])
        #expect(options.highResolution)
        #expect(options.guest == ["-windowed"])
        #expect(!(try AppPathCLI.acceptanceArguments(["-windowed"]).highResolution))
        #expect(try AppPathCLI.acceptanceArguments(["--", "--high-resolution"]).guest == ["--high-resolution"])
    }

    @Test func libraryWithoutTheFieldStillLoads() throws {
        let old = #"[{"id":"7C8E3F36-6B57-4E2B-9E57-1E4E8E6E7A11","name":"ELDEN RING","exePath":"/g/eldenring.exe","d3dBackend":"none","createdAt":0,"updatedAt":0}]"#
        let apps = try JSONDecoder().decode([AppEntry].self, from: Data(old.utf8))
        #expect(apps.first?.highResolution == nil)
        var entry = try #require(apps.first)
        entry.highResolution = true
        let again = try JSONDecoder().decode(AppEntry.self, from: JSONEncoder().encode(entry))
        #expect(again.highResolution == true)
    }

    // MARK: - На каталоге бутылки, без Wine

    private func fixture() throws -> (root: URL, tmp: URL, engine: BundledEngine, log: EngineLog) {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("retina-\(UUID().uuidString)")
        let engineRoot = root.appendingPathComponent("engine")
        try fm.createDirectory(at: engineRoot.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": "retina-fixture", "environment": [String: String]()]
        try JSONSerialization.data(withJSONObject: manifest).write(to: engineRoot.appendingPathComponent("ENGINE.json"))
        // Заглушка: тесты Wine не запускают, но загрузчик движка требует исполняемый файл.
        let wine = engineRoot.appendingPathComponent("wine/bin/wine")
        try Data("#!/bin/sh\nexit 97\n".utf8).write(to: wine)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let engine = try #require(BundledEngine.load(from: engineRoot))
        // Путь сокета Wine ограничен 104 байтами: короткий TMPDIR — свой для каждого теста.
        let tmp = URL(fileURLWithPath: "/tmp/rt-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        return (root, tmp, engine, try EngineLog(url: root.appendingPathComponent("engine.log")))
    }

    @Test func offlineWriteRestoresTheBottleByteForByte() throws {
        let (root, tmp, engine, log) = try fixture()
        defer { log.close(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: tmp) }
        let prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let registry = prefix.appendingPathComponent("user.reg")
        try Data(Self.wineSaved.utf8).write(to: registry)
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: ["TMPDIR": tmp.path], log: log)
        try setup.applyRetina(true)
        #expect(BottleSetup.retinaModeInRegistry(prefix: prefix))
        let on = try Data(contentsOf: registry)
        try setup.applyRetina(true)
        #expect(try Data(contentsOf: registry) == on)
        try setup.applyRetina(nil)
        #expect(try Data(contentsOf: registry) == on)
        try setup.applyRetina(false)
        #expect(try Data(contentsOf: registry) == Data(Self.wineSaved.utf8))
        #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(BottleSetup.retinaLogPixelsMarker).path))
        #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(BottleSetup.retinaModesetMarker).path))
        // Нет бутылки и «выключено» — файл не создаётся.
        let empty = root.appendingPathComponent("empty-prefix")
        try BottleSetup(engine: engine, prefix: empty, environment: ["TMPDIR": tmp.path], log: log).applyRetina(false)
        #expect(!FileManager.default.fileExists(atPath: empty.appendingPathComponent("user.reg").path))
    }

    /// Полный список режимов: включённый переключатель ставит EmulateModeset=Y и возвращает прежнее значение;
    /// профиль игры со своим EmulateModeset главнее (Heroes III, Diablo).
    @Test func fullModeListCompanionRestoresAndYieldsToProfile() throws {
        let (root, tmp, engine, log) = try fixture()
        defer { log.close(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: tmp) }
        let prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let registry = prefix.appendingPathComponent("user.reg")
        let withN = BottleSetup.modesetRegistry(Self.wineSaved, enabled: false)
        try Data(withN.utf8).write(to: registry)
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: ["TMPDIR": tmp.path], log: log)
        try setup.applyRetina(true)
        var text = try String(contentsOf: registry, encoding: .utf8)
        #expect(text.contains("\"EmulateModeset\"=\"Y\""))
        #expect(BottleSetup.retinaEnabled(in: text))
        try setup.applyRetina(true)                       // повтор — без изменений
        #expect(try String(contentsOf: registry, encoding: .utf8) == text)
        try setup.applyRetina(false)                      // прежнее "N" вернулось, файл побайтно
        #expect(try String(contentsOf: registry, encoding: .utf8) == withN)
        // Профиль задаёт своё значение: компаньон не пишет и метку не заводит.
        try setup.applyRetina(true, profileModeset: false)
        text = try String(contentsOf: registry, encoding: .utf8)
        #expect(text.contains("\"EmulateModeset\"=\"N\""))
        #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent(BottleSetup.retinaModesetMarker).path))
        try setup.applyRetina(false)
        #expect(try String(contentsOf: registry, encoding: .utf8) == withN)
    }

    /// Обе руки: живой «wineserver» (слушающий сокет бутылки) — отказ и файл не тронут;
    /// то же значение, что уже стоит, — без отказа, переписывать нечего.
    @Test func liveServerRefusesOnlyAnActualChange() throws {
        let (root, tmp, engine, log) = try fixture()
        defer { log.close(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: tmp) }
        let prefix = root.appendingPathComponent("prefix")
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        let registry = prefix.appendingPathComponent("user.reg")
        try Data(Self.wineSaved.utf8).write(to: registry)
        let environment = ["TMPDIR": tmp.path]
        let path = try #require(WineServerProbe.socketPath(prefix: prefix, environment: environment))
        try FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        try #require(bytes.count < MemoryLayout.size(ofValue: address.sun_path))
        withUnsafeMutableBytes(of: &address.sun_path) { raw in raw.copyBytes(from: bytes); raw[bytes.count] = 0 }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        // Очередь с запасом: каждая проба подключается и не принимается — при очереди 1 вторая
        // проба получила бы ECONNREFUSED и сочла сервер мёртвым (поймано первым прогоном теста).
        try #require(bound == 0 && listen(fd, 64) == 0)
        #expect(WineServerProbe.isAlive(prefix: prefix, environment: environment))
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: environment, log: log)
        #expect(throws: BottleSetup.SetupError.self) { try setup.applyRetina(true) }
        #expect(try Data(contentsOf: registry) == Data(Self.wineSaved.utf8))
        try setup.applyRetina(false)   // уже выключено — отказа нет
        #expect(try Data(contentsOf: registry) == Data(Self.wineSaved.utf8))
    }

    @Test func warmSessionSignatureSeparatesRetinaStates() throws {
        let (root, tmp, engine, log) = try fixture()
        defer { log.close(); try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: tmp) }
        let off = try WarmBottleSessions.signature(engine: engine, environment: [:], layer: nil, retinaMode: false)
        let on = try WarmBottleSessions.signature(engine: engine, environment: [:], layer: nil, retinaMode: true)
        let untouched = try WarmBottleSessions.signature(engine: engine, environment: [:], layer: nil)
        #expect(off != on)
        #expect(untouched != on)
        #expect(off == (try WarmBottleSessions.signature(engine: engine, environment: ["WINEDEBUG": "-all"], layer: nil, retinaMode: false)))
    }
}
