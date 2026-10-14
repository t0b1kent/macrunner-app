import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Распаковка установщиков Inno Setup без запуска: разбор вывода innoextract (строки сняты с настоящих
/// установщиков GOG 24.09.2026), выбор языка, имя папки и выбор игры по `goggame-*.info`.
struct InstallerUnpackerTests {
    @Test func titleFromListingAndInspecting() {
        #expect(InstallerUnpacker.parseTitle("Listing \"Clair Obscur - Expedition 33\" - setup data version 5.6.2 (unicode)\n") == "Clair Obscur - Expedition 33")
        #expect(InstallerUnpacker.parseTitle("Inspecting \"Terraria\" - setup data version 5.6.2 (unicode)\n - en-US\nDone.\n") == "Terraria")
        #expect(InstallerUnpacker.parseTitle("Not a supported Inno Setup installer!\n") == nil)
    }

    @Test func languagesFromListLanguages() {
        let text = "Inspecting \"Diablo 1 HD Mod (Belzebub)\" - setup data version 5.6.2 (unicode)\n - cs-CZ\n - en-US\n - pt-BR\nDone.\n"
        #expect(InstallerUnpacker.parseLanguages(text) == ["cs-CZ", "en-US", "pt-BR"])
    }

    @Test func sizesSkipTemporaryFiles() {
        let text = """
        Listing "Indiana Jones" - setup data version 5.6.2 (unicode)
         - "__redist/ISI/scriptinterpreter.exe" (1.2 MiB)
         - "goggame-1318792284.info" [neutral] (294 B)
         - "Belzebub.exe" [en-US] (2.7 MiB) - overwritten
         - "tmp/background.jpg" [temp] (500 KiB)
        """
        let expected = Int64((1.2 * 1024 * 1024).rounded()) + 294 + Int64((2.7 * 1024 * 1024).rounded())
        #expect(InstallerUnpacker.parseTotalBytes(text) == expected)
        #expect(InstallerUnpacker.parseSize("868 KiB") == Int64(868 * 1024))
        #expect(InstallerUnpacker.parseSize("1.5 GiB") == Int64(1.5 * 1024 * 1024 * 1024))
        #expect(InstallerUnpacker.parseSize("12 parsecs") == nil)
    }

    /// Прогресс приходит кусками с `\r` и ANSI-стиранием строки; берётся последний процент.
    @Test func progressFromBarChunk() {
        let chunk = "\u{1b}[K - \"goggame.info\" [neutral]\r\u{1b}[K[===========>        ] 17.6%   128 MiB/s\r\u{1b}[K[=============>      ] 23.0%"
        #expect(InstallerUnpacker.parseProgress(chunk) == 0.23)
        #expect(InstallerUnpacker.parseProgress("no numbers here") == nil)
        #expect(InstallerUnpacker.parseProgress("[>     ]  0.0% ") == 0)
    }

    @Test func languageFollowsInterface() {
        let langs = ["cs-CZ", "en-US", "ru-RU", "zh-Hans"]
        #expect(InstallerUnpacker.chooseLanguage(available: langs, interface: "ru") == "ru-RU")
        #expect(InstallerUnpacker.chooseLanguage(available: langs, interface: "zh-Hans") == "zh-Hans")
        #expect(InstallerUnpacker.chooseLanguage(available: langs, interface: "de") == "en-US")
        #expect(InstallerUnpacker.chooseLanguage(available: ["en-US"], interface: "ru") == nil)   // один язык — без выбора
    }

    @Test func folderNamesAreSafe() {
        #expect(InstallerUnpacker.folderName(for: "Clair Obscur: Expedition 33") == "Clair Obscur Expedition 33")
        #expect(InstallerUnpacker.folderName(for: "  WRATH: Aeon of Ruin. ") == "WRATH Aeon of Ruin")
        #expect(InstallerUnpacker.folderName(for: "???") == "Game")
    }

    @Test func destinationIsNeverAnExistingFolder() throws {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("unpack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        try FileManager.default.createDirectory(at: base.appendingPathComponent("Terraria"), withIntermediateDirectories: true)
        #expect(InstallerUnpacker.destination(base: base, title: "Terraria").lastPathComponent == "Terraria (2)")
        #expect(InstallerUnpacker.destination(base: base, title: "Noita").lastPathComponent == "Noita")
    }

    /// Как у настоящего Crysis 3 Remastered: главный exe — задача `isPrimary` в `goggame-*.info` в корне.
    @Test func gogPrimaryTaskIsSuggested() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("unpack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Bin64"), withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: root.appendingPathComponent("Bin64/Crysis3Remastered.exe"))
        try Data("MZ".utf8).write(to: root.appendingPathComponent("Bin64/Editor.exe"))
        let info = """
        {"gameId": "2020416039", "name": "Crysis 3 Remastered", "playTasks": [
         {"category": "game", "isPrimary": true, "name": "Crysis 3 Remastered", "path": "Bin64\\\\Crysis3Remastered.exe", "type": "FileTask"},
         {"category": "tool", "name": "Editor", "path": "Bin64/Editor.exe", "type": "FileTask"},
         {"category": "document", "name": "Support", "type": "URLTask"}]}
        """
        try Data(info.utf8).write(to: root.appendingPathComponent("goggame-2020416039.info"))
        let found = InstallerUnpacker.foundGames(in: root)
        #expect(found.count == 1)
        #expect(found.first?.name == "Crysis 3 Remastered")
        #expect(found.first?.suggested == true)
        #expect(found.first?.url.lastPathComponent == "Crysis3Remastered.exe")
    }

    // MARK: - Репаки (строки сняты с настоящих установщиков 24.09.2026)

    /// dixen18 LIMBO: распаковщики во временной папке, в самой оболочке — одна иконка.
    @Test func repackHelpersFromListing() {
        let listing = """
        Listing "LIMBO" - setup data version 5.5.0.1 (unicode)
         - "tmp/Image.bmp" [temp] (527 KiB)
         - "tmp/idp.dll" [temp] (232 KiB)
         - "tmp/arc.ini" [temp] (1.34 KiB)
         - "tmp/CLS.ini" [temp] (303 B)
         - "tmp/facompress.dll" [temp] (355 KiB)
         - "tmp/ISDone.dll" [temp] (452 KiB)
         - "tmp/unarc.dll" [temp] (320 KiB)
         - "tmp/cls-lolz.dll" [temp] (16 KiB)
         - "tmp/cls-lolz_x64.exe" [temp] (335 KiB)
         - "tmp/xt66.exe" [temp] (4.17 MiB)
         - "app/2.ico" (108 KiB)
        Done.
        """
        #expect(InstallerUnpacker.parseRepackHelpers(listing)
                == ["arc.ini", "CLS.ini", "facompress.dll", "ISDone.dll", "unarc.dll", "cls-lolz.dll", "cls-lolz_x64.exe", "xt66.exe"])
        #expect(InstallerUnpacker.parseTotalBytes(listing) == 108 * 1024)
    }

    /// Установщик GOG тоже носит свои dll во временной папке — они не признак репака.
    /// А unarc.dll внутри самой игры (не `[temp]`) — тем более.
    @Test func gogTemporaryFilesAreNotRepackHelpers() {
        let listing = """
        Listing "Dome Keeper" - setup data version 5.6.2 (unicode)
         - "tmp/InnoCallback.dll" [temp] (64 KiB)
         - "tmp/botva2.dll" [temp] (38 KiB)
         - "tmp/crcdll.dll" [temp] (10 KiB)
         - "tmp/md5log.ini" [temp] (1 KiB)
         - "tmp/InnoExt.dll" [temp] (451 KiB)
         - "tools/unarc.dll" (320 KiB)
         - "domekeeper.exe" (72 MiB)
        """
        #expect(InstallerUnpacker.parseRepackHelpers(listing).isEmpty)
    }

    @Test func repackDecision() {
        let mib: Int64 = 1024 * 1024
        // Архивы FreeArc рядом — репак в любом случае.
        #expect(InstallerUnpacker.repackSigns(helpers: [], archives: ["fg-01.bin"], payloadBytes: 3 * mib) == ["fg-01.bin"])
        // Показ: архивы, затем главные распаковщики, затем остальное в исходном порядке.
        #expect(InstallerUnpacker.repackSigns(helpers: ["arc.ini", "CLS.ini", "ISDone.dll", "unarc.dll", "cls-lolz.dll"],
                                              archives: ["Data01.dxn"], payloadBytes: 0)
                == ["Data01.dxn", "ISDone.dll", "unarc.dll", "cls-lolz.dll", "arc.ini", "CLS.ini"])
        // Распаковщики без архивов рядом: пустая оболочка — репак (архивы в подпапке) …
        #expect(InstallerUnpacker.repackSigns(helpers: ["ISDone.dll"], archives: [], payloadBytes: 108 * 1024) == ["ISDone.dll"])
        // … а если игра лежит в самом установщике, innoextract её достанет — не репак.
        #expect(InstallerUnpacker.repackSigns(helpers: ["ISDone.dll"], archives: [], payloadBytes: 1500 * mib).isEmpty)
        #expect(InstallerUnpacker.repackSigns(helpers: [], archives: [], payloadBytes: 0).isEmpty)
    }

    /// Архив FreeArc узнаётся по первым байтам `ArC\x01`; части GOG (`idska32`) и сам установщик — нет.
    @Test func freeArcArchivesByMagic() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("repack-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("Redist"), withIntermediateDirectories: true)
        try Data([0x41, 0x72, 0x43, 0x01, 0x00, 0x00, 0x06, 0x07]).write(to: dir.appendingPathComponent("Data01.dxn"))
        try Data("idska32\u{1a}".utf8).write(to: dir.appendingPathComponent("setup-1.bin"))
        try Data("MZP\u{0}".utf8).write(to: dir.appendingPathComponent("Setup.exe"))
        try Data([0x41, 0x72]).write(to: dir.appendingPathComponent("short.bin"))
        #expect(InstallerUnpacker.freeArcArchives(near: dir.appendingPathComponent("Setup.exe")) == ["Data01.dxn"])
    }

    /// Проверка на настоящем репаке: только если задан MACRUNNER_REPACK_E2E=<путь к Setup.exe репака>.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACRUNNER_REPACK_E2E"] != nil))
    func repackIsRecognized() async throws {
        let installer = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACRUNNER_REPACK_E2E"]!)
        let verdict = try ExeInspector.inspect(at: installer)
        let probe = try await InstallerUnpacker.probe(installer)
        #expect(probe.isRepack)
        print("repack e2e:", verdict.kind, probe.title, probe.totalBytes, probe.repackSigns)
    }

    /// Сквозная проверка на настоящем установщике: только если задан MACRUNNER_INNO_E2E=<путь к setup_*.exe>.
    /// Распаковывает во временную папку, находит игру по сведениям GOG и удаляет всё за собой.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACRUNNER_INNO_E2E"] != nil))
    func endToEndOnRealInstaller() async throws {
        let installer = URL(fileURLWithPath: ProcessInfo.processInfo.environment["MACRUNNER_INNO_E2E"]!)
        let probe = try await InstallerUnpacker.probe(installer)
        #expect(!probe.title.isEmpty)
        #expect(probe.totalBytes > 0)
        #expect(!probe.isRepack)
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("unpack-e2e-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = InstallerUnpacker.destination(base: base, title: probe.title)
        let seen = ProgressBox()
        try await InstallerUnpacker.unpack(installer, to: destination, language: nil, handle: InstallerUnpacker.Handle()) { seen.add($0) }
        #expect(seen.values.contains { $0 > 0 && $0 < 1 })        // промежуточный прогресс был
        #expect(!FileManager.default.fileExists(atPath: destination.appendingPathComponent("tmp").path))  // -m: без временных
        let found = InstallerUnpacker.foundGames(in: destination)
        #expect(found.first?.suggested == true)
        if let exe = found.first { #expect(FileManager.default.fileExists(atPath: exe.url.path)) }
        print("e2e:", probe.title, probe.totalBytes, found.map { $0.name + " -> " + $0.url.lastPathComponent })
    }

    final class ProgressBox: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [Double] = []
        func add(_ v: Double) { lock.lock(); stored.append(v); lock.unlock() }
        var values: [Double] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    /// При разработке инструмент берётся из `Vendor/innoextract` рядом с исходниками (или из Homebrew).
    @Test func toolIsFound() {
        let tool = InstallerUnpacker.toolURL()
        #expect(tool != nil)
        if let tool { #expect(FileManager.default.isExecutableFile(atPath: tool.path)) }
    }
}
