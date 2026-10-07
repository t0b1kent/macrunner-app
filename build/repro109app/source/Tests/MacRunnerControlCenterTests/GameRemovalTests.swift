import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Проверки на удаление.
///
/// ★★★ ЭТО САМЫЕ ВАЖНЫЕ ТЕСТЫ В ПРОЕКТЕ ПО ЦЕНЕ ОШИБКИ. Всё остальное при промахе
///   показывает не тот значок. Здесь промах СТИРАЕТ ЧУЖИЕ ФАЙЛЫ.
///
///   Поэтому главный тест — не «удаляет правильное», а «НЕ ТРОГАЕТ ЧУЖОЕ».
struct GameRemovalTests {

    private func makeTemp() throws -> URL {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("mr-removal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func touch(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("MZ".utf8).write(to: url)
    }

    @Test("★ Файл ВНЕ наших папок не удаляется никогда")
    func outsideOurFoldersIsNeverDeleted() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let ours = root.appendingPathComponent("bottles")
        let theirs = root.appendingPathComponent("Documents/Моя игра/game.exe")
        try touch(theirs)
        try FileManager.default.createDirectory(at: ours, withIntermediateDirectories: true)

        let plan = GameRemoval.plan(exePath: theirs.path, ourFolders: [ours.path])
        #expect(plan == .libraryOnly(reason: .outsideOurFolders))
    }

    @Test("★★ Папка с ПОХОЖИМ именем не считается нашей")
    func similarlyNamedSiblingIsNotInside() throws {
        // /tmp/x/Games-прочее НЕ внутри /tmp/x/Games — сравнение по началу строки
        // сказало бы «внутри», и мы отправили бы в корзину чужую папку.
        #expect(!GameRemoval.isInside("/tmp/x/Games-прочее/a.exe", ourFolders: ["/tmp/x/Games"]))
        #expect(GameRemoval.isInside("/tmp/x/Games/a.exe", ourFolders: ["/tmp/x/Games"]))
        #expect(GameRemoval.isInside("/tmp/x/Games", ourFolders: ["/tmp/x/Games"]))
    }

    @Test("Деинсталлятор рядом с игрой — предпочитаем его")
    func uninstallerNextToGameWins() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("bottles/drive_c/Game")
        let game = folder.appendingPathComponent("game.exe")
        let unins = folder.appendingPathComponent("unins000.exe")
        try touch(game); try touch(unins)

        let plan = GameRemoval.plan(exePath: game.path,
                                    ourFolders: [root.appendingPathComponent("bottles").path])
        #expect(plan == .runUninstaller(uninstaller: unins.standardizedFileURL.path,
                                        game: game.standardizedFileURL.path))
    }

    @Test("Деинсталлятора нет — папка игры в корзину")
    func withoutUninstallerFolderGoesToTrash() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let folder = root.appendingPathComponent("bottles/drive_c/Portable")
        let game = folder.appendingPathComponent("game.exe")
        try touch(game)

        let plan = GameRemoval.plan(exePath: game.path,
                                    ourFolders: [root.appendingPathComponent("bottles").path])
        #expect(plan == .trashFolder(folder.standardizedFileURL.path))
    }

    @Test("Файла нет — только запись")
    func missingFileIsLibraryOnly() {
        #expect(GameRemoval.plan(exePath: "/нет/такого/файла.exe", ourFolders: ["/нет"])
                == .libraryOnly(reason: .fileMissing))
        #expect(GameRemoval.plan(exePath: "", ourFolders: ["/нет"])
                == .libraryOnly(reason: .fileMissing))
    }

    @Test("Пустой список наших папок — не удаляем ничего")
    func noOurFoldersMeansNothingIsOurs() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("Game/game.exe")
        try touch(game)
        // Настройки не заданы — считать своим ВСЁ было бы катастрофой.
        #expect(GameRemoval.plan(exePath: game.path, ourFolders: [])
                == .libraryOnly(reason: .outsideOurFolders))
        #expect(GameRemoval.plan(exePath: game.path, ourFolders: [""])
                == .libraryOnly(reason: .outsideOurFolders))
    }

    @Test("Деинсталлятор берётся ТОЛЬКО рядом, не из соседней папки")
    func uninstallerFromAnotherFolderIsIgnored() throws {
        let root = try makeTemp()
        defer { try? FileManager.default.removeItem(at: root) }
        let bottles = root.appendingPathComponent("bottles")
        let game = bottles.appendingPathComponent("GameA/game.exe")
        let alien = bottles.appendingPathComponent("GameB/unins000.exe")
        try touch(game); try touch(alien)

        let plan = GameRemoval.plan(exePath: game.path, ourFolders: [bottles.path])
        // Чужой деинсталлятор снёс бы ДРУГУЮ игру.
        #expect(plan == .trashFolder(game.deletingLastPathComponent().standardizedFileURL.path))
    }
}
