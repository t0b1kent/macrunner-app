import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Имя игры в библиотеке: `goggame-*.info` → профиль → папка → имя файла.
/// Установки собираются во временной папке так же, как их раскладывает GOG.
struct GameTitleTests {
    private func makeInstall(_ files: [String: String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("game-title-\(UUID().uuidString)", isDirectory: true)
        for (path, text) in files {
            let url = root.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        return root
    }

    private let divinityInfo = """
    {"gameId": "1445516929", "name": "Divinity: Original Sin - Enhanced Edition",
     "playTasks": [
      {"category": "game", "isPrimary": true, "name": "Divinity - Original Sin Enhanced Edition", "path": "Shipping/EoCApp.exe"},
      {"category": "document", "name": "Support", "type": "URLTask"},
      {"category": "tool", "name": "The Divinity Engine", "path": "The Divinty Engine Enhanced Edition\\\\TheDivinityEngine.exe"}
     ]}
    """

    /// Случай владельца: exe во вложенной `Shipping`, сведения GOG — папкой выше.
    @Test func gogInfoNamesTheGameAboveTheExe() throws {
        let root = try makeInstall([
            "Divinity-Original-Sin-EE-2.0.119.430/goggame-1445516929.info": divinityInfo,
            "Divinity-Original-Sin-EE-2.0.119.430/Shipping/EoCApp.exe": "MZ"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent("Divinity-Original-Sin-EE-2.0.119.430/Shipping/EoCApp.exe")
        let gog = GameTitle.gogInstall(for: exe)
        #expect(gog == .init(gameID: "1445516929", title: "Divinity: Original Sin - Enhanced Edition", isGame: true))
        #expect(GameTitle.resolve(exe: exe, profiles: []) == "Divinity: Original Sin - Enhanced Edition")
    }

    /// Редактор из той же установки — не «игра», и имя у него своё; путь с обратной чертой.
    @Test func gogToolKeepsItsTaskName() throws {
        let root = try makeInstall([
            "Div/goggame-1445516929.info": divinityInfo,
            "Div/The Divinty Engine Enhanced Edition/TheDivinityEngine.exe": "MZ"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let gog = GameTitle.gogInstall(for: root.appendingPathComponent("Div/The Divinty Engine Enhanced Edition/TheDivinityEngine.exe"))
        #expect(gog?.isGame == false)
        #expect(gog?.title == "Divinity: Original Sin - Enhanced Edition – The Divinity Engine")
    }

    /// Файл, которого нет в задачах запуска (установщик из `__redist`), игрой не называем.
    @Test func exeOutsidePlayTasksIsNotClaimed() throws {
        let root = try makeInstall([
            "Div/goggame-1445516929.info": divinityInfo,
            "Div/__redist/vcredist_x64.exe": "MZ"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let exe = root.appendingPathComponent("Div/__redist/vcredist_x64.exe")
        #expect(GameTitle.gogInstall(for: exe) == nil)
        #expect(GameTitle.resolve(exe: exe, profiles: []) == "vcredist_x64")
    }

    @Test func brokenInfoIsIgnored() throws {
        let root = try makeInstall([
            "G/goggame-1.info": "{not json",
            "G/goggame-2.info": #"{"gameId": "../2", "name": "X", "playTasks": [{"category": "game", "path": "a.exe"}]}"#,
            "G/a.exe": "MZ"
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(GameTitle.gogInstall(for: root.appendingPathComponent("G/a.exe")) == nil)
    }

    /// Папка — только если exe в служебной папке; одиночный файл из «Загрузок» — по имени файла.
    @Test func folderOnlyThroughGenericDirectories() {
        let shipped = URL(fileURLWithPath: "/tmp/nowhere/Divinity-Original-Sin-EE-2.0.119.430/Shipping/EoCApp.exe")
        #expect(GameTitle.folderTitle(for: shipped) == "Divinity Original Sin EE")
        let unreal = URL(fileURLWithPath: "/tmp/nowhere/Some Game/Binaries/Win64/SomeGame-Win64-Shipping.exe")
        #expect(GameTitle.folderTitle(for: unreal) == "Some Game")
        #expect(GameTitle.folderTitle(for: URL(fileURLWithPath: "/fixture-home/user/Downloads/setup.exe")) == nil)
        #expect(GameTitle.folderTitle(for: URL(fileURLWithPath: "/fixture-home/user/Downloads/bin/tool.exe")) == nil)
    }

    @Test func folderNameCleanup() {
        #expect(GameTitle.cleanedFolderName("Hedon-2.4.2") == "Hedon")
        #expect(GameTitle.cleanedFolderName("Stardew-Valley-1.6.15") == "Stardew Valley")
        #expect(GameTitle.cleanedFolderName("WRATH v1.1.2") == "WRATH")
        #expect(GameTitle.cleanedFolderName("Half-Life 2") == "Half-Life 2")
        #expect(GameTitle.cleanedFolderName("1.0") == "1.0")
    }

    /// Переименовываем только имена, выставленные по файлу: своё имя человека не трогаем.
    @Test func onlyFileStemNamesAreAutomatic() {
        #expect(GameTitle.isFileStem("EoCApp", exePath: "/g/Shipping/EoCApp.exe"))
        #expect(!GameTitle.isFileStem("Divinity", exePath: "/g/Shipping/EoCApp.exe"))
        #expect(!GameTitle.isFileStem("", exePath: ""))
    }
}
