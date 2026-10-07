import Foundation

/// Что поставил установщик: программы, появившиеся в бутылке за время его работы.
///
/// ★★★ ПОЧЕМУ СРАВНЕНИЕ «ДО/ПОСЛЕ», А НЕ ЯРЛЫКИ. Ярлыки `.lnk` кладут не все
///   установщики (репаки и архивные — никогда), а разбор `.lnk` ради пути к файлу —
///   отдельный формат. Новый `.exe` на диске C есть у любого установщика.
///   Отбор — тем же разбором, что у кнопки «Добавить игру» (`ExeVerdict`):
///   деинсталляторы, рантаймы и отчёты о падении в список не попадают.
struct FoundGame: Identifiable, Hashable {
    let url: URL
    let name: String
    let size: Int64
    /// Самый крупный исполняемый файл в своей папке установки — скорее всего сама игра.
    let suggested: Bool
    var id: String { url.path }
}

enum InstalledGameScanner {
    /// Все `.exe` на диске C бутылки, кроме `C:\windows`. Ссылки в каталоги
    /// (Documents, Desktop пользователя смотрят в домашнюю папку Mac) не обходятся.
    static func snapshot(prefix: URL) -> Set<String> {
        let driveC = prefix.appendingPathComponent("drive_c", isDirectory: true)
        let windows = driveC.appendingPathComponent("windows").path
        guard let walker = FileManager.default.enumerator(
            at: driveC, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        var found = Set<String>()
        for case let url as URL in walker {
            if url.path == windows || walker.level > 8 {
                walker.skipDescendants()
                continue
            }
            guard url.pathExtension.lowercased() == "exe",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else { continue }
            found.insert(url.path)
        }
        return found
    }

    /// Программы, которых не было до установки, без уже добавленных в библиотеку.
    static func newGames(prefix: URL, before: Set<String>, known: Set<String>) -> [FoundGame] {
        let candidates = snapshot(prefix: prefix).subtracting(before).subtracting(known)
        var games: [(url: URL, size: Int64, root: String)] = []
        for path in candidates {
            let url = URL(fileURLWithPath: path)
            guard let verdict = try? ExeInspector.inspect(at: url), verdict.kind == .application else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            games.append((url, size, installRoot(of: url, prefix: prefix)))
        }
        var biggest: [String: Int64] = [:]
        for game in games { biggest[game.root] = max(biggest[game.root] ?? 0, game.size) }
        return games
            .map { FoundGame(url: $0.url, name: displayName(for: $0.url), size: $0.size,
                             suggested: $0.size == biggest[$0.root]) }
            .sorted { ($0.suggested ? 0 : 1, -$0.size) < ($1.suggested ? 0 : 1, -$1.size) }
    }

    /// Папка установки: первый каталог под `Program Files*`, под `users/<имя>/AppData/…`
    /// или прямо под `C:\` (репаки ставят в `C:\Games\…`).
    static func installRoot(of url: URL, prefix: URL) -> String {
        let driveC = prefix.appendingPathComponent("drive_c").path + "/"
        let parts = url.path.hasPrefix(driveC)
            ? url.path.dropFirst(driveC.count).split(separator: "/").map(String.init) : []
        guard parts.count > 1 else { return url.deletingLastPathComponent().path }
        var depth = 1
        if parts[0].lowercased().hasPrefix("program files") || parts[0].lowercased() == "games" { depth = 2 }
        if parts[0].lowercased() == "users" { depth = min(parts.count - 1, 5) }
        return driveC + parts.prefix(min(depth, parts.count - 1)).joined(separator: "/")
    }

    /// Имя для плитки: папка игры, а не `Game.exe`. Служебные имена папок
    /// (`bin`, `x64`, `Binaries` …) пропускаем вверх.
    static func displayName(for url: URL) -> String {
        let generic: Set<String> = ["bin", "bin64", "bin32", "binaries", "win64", "win32", "x64", "x86",
                                    "game", "system", "retail", "shipping", "release", "app"]
        var dir = url.deletingLastPathComponent()
        for _ in 0..<4 where generic.contains(dir.lastPathComponent.lowercased()) {
            dir = dir.deletingLastPathComponent()
        }
        let name = dir.lastPathComponent
        let ignoredParents: Set<String> = ["drive_c", "program files", "program files (x86)", "games"]
        return ignoredParents.contains(name.lowercased()) ? url.deletingPathExtension().lastPathComponent : name
    }
}
