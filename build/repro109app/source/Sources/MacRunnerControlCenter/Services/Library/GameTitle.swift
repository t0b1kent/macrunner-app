import Foundation

/// Имя игры для библиотеки — вместо имени файла.
///
/// ★ Владелец, 24.09.2026: добавил Divinity, а на плитке «EoCApp» на сером. Имя файла
///   часто ничего не говорит (`EoCApp.exe`, `javaw.exe`, `Game-Win64-Shipping.exe`), а по
///   нему же ищется обложка — и не находится. Порядок — от точного к догадке:
///   1. `goggame-<id>.info` установки GOG: название и номер игры из самого магазина;
///   2. известный графический профиль (`graphics-profiles.json`);
///   3. папка игры, если exe лежит в служебной (`Shipping`, `Binaries/Win64` …);
///   4. имя файла — как раньше.
enum GameTitle {
    struct GOGInstall: Equatable, Sendable {
        let gameID: String
        let title: String
        /// Задача запуска — игра или её запускатель, а не редактор/справка.
        let isGame: Bool
    }

    static func resolve(exe: URL, profiles: [GraphicsProfile] = GraphicsProfile.bundled) -> String {
        improved(exe: exe, profiles: profiles) ?? exe.deletingPathExtension().lastPathComponent
    }

    /// Имя лучше имени файла или `nil`, если ничего лучше нет.
    static func improved(exe: URL, profiles: [GraphicsProfile] = GraphicsProfile.bundled) -> String? {
        if let gog = gogInstall(for: exe) { return gog.title }
        if let profile = GraphicsProfile.match(exe: exe, in: profiles) { return profile.name }
        return folderTitle(for: exe)
    }

    /// Запись — имя, выставленное автоматически по имени файла (человек его не менял).
    static func isFileStem(_ name: String, exePath: String) -> Bool {
        !exePath.isEmpty && name == URL(fileURLWithPath: exePath).deletingPathExtension().lastPathComponent
    }

    // MARK: - GOG

    /// Ищет `goggame-*.info` в папке exe и до трёх папок выше. Засчитывается, только если
    /// сам этот exe указан в задачах запуска: случайный файл из `__redist` игрой не назовём.
    static func gogInstall(for exe: URL) -> GOGInstall? {
        let target = exe.standardizedFileURL.pathComponents
        var directory = exe.deletingLastPathComponent().standardizedFileURL
        for _ in 0..<4 {
            let base = directory.pathComponents
            guard base.count > 1, target.count > base.count else { return nil }
            let relative = target.dropFirst(base.count).joined(separator: "/").lowercased()
            let files = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
            for file in files.sorted() where file.hasPrefix("goggame-") && file.hasSuffix(".info") {
                if let found = parseGOGInfo(at: directory.appendingPathComponent(file), exeRelativePath: relative) {
                    return found
                }
            }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    static func parseGOGInfo(at url: URL, exeRelativePath: String) -> GOGInstall? {
        guard let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize, size < 1_000_000,
              let data = try? Data(contentsOf: url),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let title = (object["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty,
              let gameID = object["gameId"] as? String, !gameID.isEmpty, gameID.count <= 20,
              gameID.allSatisfy({ $0.isASCII && $0.isNumber }),
              let tasks = object["playTasks"] as? [[String: Any]] else { return nil }
        let wanted = normalizedTaskPath(exeRelativePath)
        guard let task = tasks.first(where: { ($0["path"] as? String).map(normalizedTaskPath) == wanted }) else { return nil }
        let category = (task["category"] as? String)?.lowercased()
        let isGame = category == "game" || category == "launcher"
        if isGame { return GOGInstall(gameID: gameID, title: title, isGame: true) }
        // Редактор, настройка языка и т. п.: имя самой задачи рядом с названием игры.
        let taskName = (task["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let named = taskName.isEmpty || taskName == title ? title : title + " – " + taskName
        return GOGInstall(gameID: gameID, title: named, isGame: false)
    }

    private static func normalizedTaskPath(_ path: String) -> String {
        path.replacingOccurrences(of: "\\", with: "/")
            .split(separator: "/").filter { $0 != "." }.joined(separator: "/").lowercased()
    }

    // MARK: - Папка

    /// Папка игры — только когда exe лежит в служебной папке: для одиночного файла из
    /// «Загрузок» имя папки было бы враньём.
    static func folderTitle(for exe: URL) -> String? {
        let generic: Set<String> = ["bin", "bin64", "bin32", "binaries", "win64", "win32", "x64", "x86",
                                    "game", "system", "retail", "shipping", "release", "app"]
        var directory = exe.deletingLastPathComponent()
        var climbed = 0
        while climbed < 4, generic.contains(directory.lastPathComponent.lowercased()) {
            directory.deleteLastPathComponent()
            climbed += 1
        }
        guard climbed > 0 else { return nil }
        let ignored: Set<String> = ["", "/", "drive_c", "program files", "program files (x86)", "games", "volumes",
                                    "users", "downloads", "desktop", "documents", "applications"]
        guard !ignored.contains(directory.lastPathComponent.lowercased()) else { return nil }
        return cleanedFolderName(directory.lastPathComponent)
    }

    /// `Divinity-Original-Sin-EE-2.0.119.430` → `Divinity Original Sin EE`: разделители —
    /// в пробелы (только если пробелов нет), номер версии в хвосте — прочь.
    static func cleanedFolderName(_ raw: String) -> String? {
        var words = raw.contains(" ")
            ? raw.split(separator: " ").map(String.init)
            : raw.split(whereSeparator: { $0 == "-" || $0 == "_" }).map(String.init)
        func isVersion(_ word: String) -> Bool {
            let body = word.lowercased().hasPrefix("v") ? String(word.dropFirst()) : word
            return !body.isEmpty && body.contains(".")
                && body.allSatisfy { $0.isASCII && ($0.isNumber || $0 == ".") }
        }
        while words.count > 1, let last = words.last, isVersion(last) { words.removeLast() }
        let title = words.joined(separator: " ").trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
