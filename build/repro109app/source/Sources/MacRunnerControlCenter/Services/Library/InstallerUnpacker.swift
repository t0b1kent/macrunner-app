import Foundation

/// Установщики Inno Setup (почти все GOG) — распаковка БЕЗ запуска, через innoextract.
///
/// ★ Владелец, 24.09.2026: сценарий «выбрал установщик → играешь» упирался в 32 бита — установщики GOG
///   32-битные, а движок 32-битный код пока не исполняет (macOS не даёт ARM64-процессу нижние 4 ГБ).
///   innoextract читает данные установщика сам: 20 из 20 установщиков GOG на Flash открылись, Crysis 3
///   Remastered (5 частей .bin, 18 ГБ) распаковался за 1 мин 53 с. Корень распаковки = папка игры;
///   `goggame-*.info` в нём называет главный exe.
enum InstallerUnpacker {
    struct Probe: Equatable, Sendable {
        let title: String
        let languages: [String]
        /// Верхняя оценка: сумма размеров всех файлов, кроме временных.
        let totalBytes: Int64
        /// Признаки репака (см. `repackSigns`): распаковщики во временной папке установщика и архивы FreeArc
        /// рядом с ним. Пусто — обычный установщик.
        var repackSigns: [String] = []
        var isRepack: Bool { !repackSigns.isEmpty }
    }

    enum Failure: LocalizedError, Equatable {
        case toolMissing
        case notSupported(String)
        case noSpace(needed: Int64, free: Int64)
        case failed(String)
        case cancelled

        var errorDescription: String? {
            switch self {
            case .toolMissing: return L("The unpacking tool is missing from MacRunner.")
            case .notSupported(let detail): return detail
            case .noSpace(let needed, let free):
                return String(format: L("Not enough free space: %@ needed, %@ free."),
                              ByteCountFormatter.string(fromByteCount: needed, countStyle: .file),
                              ByteCountFormatter.string(fromByteCount: free, countStyle: .file))
            case .failed(let detail): return detail
            case .cancelled: return L("Unpacking was stopped.")
            }
        }
    }

    // MARK: - Где инструмент

    /// В пакете — `Resources/tools/innoextract/innoextract` (скрипт упаковки копирует `Vendor/innoextract`);
    /// при разработке — сама `Vendor/innoextract` рядом с исходниками; последний запасной — Homebrew.
    static func toolURL() -> URL? {
        var candidates: [URL] = []
        if let res = Bundle.main.resourceURL {
            candidates.append(res.appendingPathComponent("tools/innoextract/innoextract"))
        }
        var src = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { src.deleteLastPathComponent() }   // …/Services/Library/файл → app/macr-control-center
        candidates.append(src.appendingPathComponent("Vendor/innoextract/innoextract"))
        candidates.append(URL(fileURLWithPath: "/opt/homebrew/bin/innoextract"))
        return candidates.first { FileManager.default.isExecutableFile(atPath: $0.path) }
    }

    // MARK: - Разбор вывода (чистые функции, под тестами)

    /// `Listing "Title" - setup data version …` / `Inspecting "Title" …` → Title.
    static func parseTitle(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            guard s.hasPrefix("Listing \"") || s.hasPrefix("Inspecting \"") || s.hasPrefix("Extracting \""),
                  let open = s.firstIndex(of: "\"") else { continue }
            let rest = s[s.index(after: open)...]
            guard let close = rest.range(of: "\" - ") ?? rest.range(of: "\"", options: .backwards) else { continue }
            let title = String(rest[..<close.lowerBound]).trimmingCharacters(in: .whitespaces)
            if !title.isEmpty { return title }
        }
        return nil
    }

    /// Строки ` - en-US` из `--list-languages`.
    static func parseLanguages(_ text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { line in
            let s = line.trimmingCharacters(in: .whitespaces)
            guard s.hasPrefix("- ") else { return nil }
            let code = String(s.dropFirst(2)).trimmingCharacters(in: .whitespaces)
            return code.isEmpty || code.contains(" ") ? nil : code
        }
    }

    /// Сумма размеров из `--list --list-sizes`: ` - "путь" [en-US] (2.7 MiB)`. Временные (`[temp]`) не считаются.
    static func parseTotalBytes(_ text: String) -> Int64 {
        var total: Int64 = 0
        for line in text.split(whereSeparator: \.isNewline) {
            let s = String(line)
            guard s.trimmingCharacters(in: .whitespaces).hasPrefix("- \""), !s.contains("[temp]") else { continue }
            guard let open = s.range(of: " (", options: .backwards),
                  let close = s[open.upperBound...].firstIndex(of: ")") else { continue }
            total += parseSize(String(s[open.upperBound..<close])) ?? 0
        }
        return total
    }

    /// `2.7 MiB`, `868 KiB`, `178 B`, `1.2 GiB`.
    static func parseSize(_ text: String) -> Int64? {
        let parts = text.split(separator: " ")
        guard parts.count == 2, let value = Double(parts[0]) else { return nil }
        let unit: Double
        switch parts[1] {
        case "B": unit = 1
        case "KiB": unit = 1024
        case "MiB": unit = 1024 * 1024
        case "GiB": unit = 1024 * 1024 * 1024
        case "TiB": unit = 1024 * 1024 * 1024 * 1024
        default: return nil
        }
        return Int64((value * unit).rounded())
    }

    /// Последний процент из куска вывода `--progress=1` (`[====>   ]  17.6%   128 MiB/s`).
    static func parseProgress(_ chunk: String) -> Double? {
        var last: Double?
        var search = chunk[...]
        while let pct = search.firstIndex(of: "%") {
            var start = pct
            while start > search.startIndex {
                let prev = search.index(before: start)
                guard search[prev].isNumber || search[prev] == "." else { break }
                start = prev
            }
            if start < pct, let v = Double(search[start..<pct]), v >= 0, v <= 100 { last = v / 100 }
            search = search[search.index(after: pct)...]
        }
        return last
    }

    /// Язык распаковки: язык интерфейса, если он есть в установщике, иначе английский, иначе без выбора
    /// (innoextract распакует всё; у GOG файлы без языка — `[neutral]` — идут в любом случае).
    static func chooseLanguage(available: [String], interface: String) -> String? {
        guard available.count > 1 else { return nil }
        let want = interface.lowercased()
        if let exact = available.first(where: { $0.lowercased() == want }) { return exact }
        let base = String(want.prefix(while: { $0 != "-" && $0 != "_" }))
        if let match = available.first(where: { $0.lowercased().hasPrefix(base + "-") || $0.lowercased() == base }) {
            return match
        }
        return available.first { $0.lowercased().hasPrefix("en") }
    }

    /// Имя папки игры: без символов, недопустимых в путях Windows/macOS, и без точек/пробелов по краям.
    static func folderName(for title: String) -> String {
        let bad = CharacterSet(charactersIn: "<>:\"/\\|?*").union(.controlCharacters)
        let cleaned = title.unicodeScalars.map { bad.contains($0) ? " " : String($0) }.joined()
        let collapsed = cleaned.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        let trimmed = collapsed.trimmingCharacters(in: CharacterSet(charactersIn: " ."))
        return trimmed.isEmpty ? "Game" : String(trimmed.prefix(120))
    }

    /// Свободная папка `<база>/<имя>`, при занятости — `<имя> (2)`, `(3)` …
    static func destination(base: URL, title: String) -> URL {
        let name = folderName(for: title)
        var candidate = base.appendingPathComponent(name, isDirectory: true)
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = base.appendingPathComponent("\(name) (\(n))", isDirectory: true)
            n += 1
        }
        return candidate
    }

    // MARK: - Папка для игр

    static let folderDefaultsKey = "macrunner.unpackFolder"

    /// Последняя выбранная папка; по умолчанию `~/Games`.
    static var baseFolder: URL {
        get {
            if let path = UserDefaults.standard.string(forKey: folderDefaultsKey), !path.isEmpty {
                return URL(fileURLWithPath: path, isDirectory: true)
            }
            return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Games", isDirectory: true)
        }
        set { UserDefaults.standard.set(newValue.path, forKey: folderDefaultsKey) }
    }

    static func freeBytes(at folder: URL) -> Int64? {
        var probe = folder
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey,
                                                         .volumeAvailableCapacityKey])
        if let important = values?.volumeAvailableCapacityForImportantUsage, important > 0 { return important }
        return values?.volumeAvailableCapacity.map(Int64.init)
    }

    // MARK: - Запуск инструмента

    /// Проверка установщика: название, языки, объём, признаки репака. Ошибка — «это не Inno Setup / не поддерживается».
    /// Список берётся ВМЕСТЕ с временными файлами: по ним видно распаковщики репака (в объём они не входят).
    static func probe(_ installer: URL) async throws -> Probe {
        guard let tool = toolURL() else { throw Failure.toolMissing }
        let languages = try await run(tool, ["--list-languages", installer.path])
        let listing = try await run(tool, ["--list", "--list-sizes", installer.path])
        guard let title = parseTitle(listing) ?? parseTitle(languages) else {
            throw Failure.notSupported(L("This installer cannot be unpacked without running it."))
        }
        let total = parseTotalBytes(listing)
        let signs = repackSigns(helpers: parseRepackHelpers(listing),
                                archives: freeArcArchives(near: installer), payloadBytes: total)
        return Probe(title: title, languages: parseLanguages(languages), totalBytes: total, repackSigns: signs)
    }

    // MARK: - Репаки

    /// ★ Владелец, 24.09.2026: «чтобы не только GOG, но и репаки разные». Репак — это оболочка Inno Setup,
    ///   а сама игра лежит РЯДОМ в архивах FreeArc (`ArC\x01` в начале файла; у dixen18 — `Data01.dxn`),
    ///   сжатых lolz/srep/precomp/xtool. Разжимают их программы из временной папки установщика (ISDone.dll,
    ///   unarc.dll, cls-lolz …) — 32-битные, а lolz ещё и закрытый. innoextract достаёт только оболочку
    ///   (у LIMBO от dixen18 это одна иконка на 108 КБ), поэтому распаковку мы НЕ предлагаем, а честно
    ///   говорим почему. Обычные установщики с частями `.bin` (GOG, диск 1С с GTA VC) начинаются с
    ///   `idska32` и сюда не попадают.
    static let repackHelperNames: Set<String> = ["isdone.dll", "unarc.dll", "arc.ini", "cls.ini",
                                                  "facompress.dll", "facompress_mt.dll"]
    static let repackHelperPrefixes = ["cls-", "srep", "precomp", "xtool", "lolz", "razor"]

    /// Распаковщики репака среди временных файлов (`[temp]`) из `--list`; имена как в установщике.
    static func parseRepackHelpers(_ listing: String) -> [String] {
        var found: [String] = []
        for line in listing.split(whereSeparator: \.isNewline) where line.contains("[temp]") {
            guard let open = line.firstIndex(of: "\"") else { continue }
            let rest = line[line.index(after: open)...]
            guard let close = rest.firstIndex(of: "\"") else { continue }
            let name = String(rest[..<close].split(separator: "/").last ?? "")
            let lower = name.lowercased()
            let xtool = lower.hasPrefix("xt") && lower.hasSuffix(".exe")
                && lower.dropFirst(2).dropLast(4).allSatisfy(\.isNumber) && lower.count > 6   // xt66.exe
            if (repackHelperNames.contains(lower) || repackHelperPrefixes.contains(where: lower.hasPrefix) || xtool),
               !found.contains(name) {
                found.append(name)
            }
        }
        return found
    }

    /// Архивы FreeArc в папке установщика (по первым байтам `ArC\x01`, расширение у репаков любое).
    static func freeArcArchives(near installer: URL) -> [String] {
        let folder = installer.deletingLastPathComponent()
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []).sorted()
        var found: [String] = []
        for name in names.prefix(500) where !name.hasPrefix(".") && name != installer.lastPathComponent {
            guard let handle = try? FileHandle(forReadingFrom: folder.appendingPathComponent(name)) else { continue }
            let head = (try? handle.read(upToCount: 4)) ?? nil
            try? handle.close()
            if head == Data([0x41, 0x72, 0x43, 0x01]) { found.append(name) }
        }
        return found
    }

    /// Итог: архивы FreeArc рядом — репак. Распаковщики без архивов рядом — репак, только если сама оболочка
    /// почти пустая (архивы бывают в подпапке); если игра лежит в самом установщике, innoextract её достанет.
    /// Порядок — для показа человеку: сначала архивы, потом главные распаковщики, потом остальное.
    static func repackSigns(helpers: [String], archives: [String], payloadBytes: Int64) -> [String] {
        guard !archives.isEmpty || (!helpers.isEmpty && payloadBytes < 64 * 1024 * 1024) else { return [] }
        let order = ["isdone", "unarc", "cls-lolz", "lolz", "cls-srep", "srep", "precomp", "xtool", "xt"]
        func rank(_ name: String) -> Int {
            order.firstIndex { name.lowercased().hasPrefix($0) } ?? order.count
        }
        let ranked = helpers.enumerated().sorted { (rank($0.element), $0.offset) < (rank($1.element), $1.offset) }
        return archives + ranked.map(\.element)
    }

    private static func run(_ tool: URL, _ args: [String]) async throws -> String {
        try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = tool
            process.arguments = args
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            let out = Pipe()
            process.standardOutput = out
            process.standardError = out
            try process.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            let text = String(decoding: data, as: UTF8.self)
            guard process.terminationStatus == 0 else {
                throw Failure.notSupported(L("This installer cannot be unpacked without running it.")
                                           + "\n" + text.split(whereSeparator: \.isNewline).suffix(2).joined(separator: "\n"))
            }
            return text
        }.value
    }

    /// Остановка распаковки: держит процесс, пока он идёт.
    final class Handle: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private(set) var cancelled = false

        func attach(_ p: Process) { lock.lock(); process = p; lock.unlock() }
        func cancel() {
            lock.lock(); cancelled = true; let p = process; lock.unlock()
            if let p, p.isRunning { p.terminate() }
        }
    }

    /// Распаковка в `destination` (создаётся). `progress` — от 0 до 1, из вывода инструмента.
    /// При ошибке или остановке недораспакованная папка удаляется: она создана здесь и только что.
    static func unpack(_ installer: URL, to destination: URL, language: String?, handle: Handle,
                       progress: @escaping @Sendable (Double) -> Void) async throws {
        guard let tool = toolURL() else { throw Failure.toolMissing }
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        var args = ["--progress=1", "--exclude-temp", "-d", destination.path]
        if let language { args += ["--language", language] }
        args.append(installer.path)
        let finalArgs = args
        let result: (Int32, String) = try await Task.detached(priority: .userInitiated) {
            let process = Process()
            process.executableURL = tool
            process.arguments = finalArgs
            process.environment = ["PATH": "/usr/bin:/bin", "LANG": "en_US.UTF-8"]
            let out = Pipe()
            let err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let tail = TailBuffer()
            out.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                guard !data.isEmpty else { return }
                let chunk = String(decoding: data, as: UTF8.self)
                tail.append(chunk)
                if let p = parseProgress(chunk) { progress(p) }
            }
            err.fileHandleForReading.readabilityHandler = { h in
                let data = h.availableData
                if !data.isEmpty { tail.append(String(decoding: data, as: UTF8.self)) }
            }
            handle.attach(process)
            try process.run()
            process.waitUntilExit()
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
            return (process.terminationStatus, tail.text)
        }.value
        if handle.cancelled || result.0 != 0 {
            try? FileManager.default.removeItem(at: destination)
            if handle.cancelled { throw Failure.cancelled }
            let lines = result.1.replacingOccurrences(of: "\r", with: "\n")
                .split(whereSeparator: \.isNewline).map(String.init)
                .filter { !$0.contains("%") }
            throw Failure.failed(lines.suffix(3).joined(separator: "\n"))
        }
        progress(1)
    }

    private final class TailBuffer: @unchecked Sendable {
        private let lock = NSLock()
        private var buffer = ""
        func append(_ s: String) {
            lock.lock()
            buffer += s
            if buffer.count > 16_000 { buffer = String(buffer.suffix(8_000)) }
            lock.unlock()
        }
        var text: String { lock.lock(); defer { lock.unlock() }; return buffer }
    }

    // MARK: - Что добавить в библиотеку

    /// Игры из распакованной папки. GOG: задачи запуска из `goggame-*.info` (главная — рекомендуемая,
    /// DLC без своих задач пропускаются). Иначе — программы (`ExeInspector`), самая крупная рекомендуемая.
    static func foundGames(in folder: URL) -> [FoundGame] {
        var games: [FoundGame] = []
        let files = (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? []
        for file in files.sorted() where file.hasPrefix("goggame-") && file.hasSuffix(".info") {
            guard let data = try? Data(contentsOf: folder.appendingPathComponent(file)),
                  let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tasks = object["playTasks"] as? [[String: Any]] else { continue }
            let title = (object["name"] as? String) ?? folder.lastPathComponent
            let gameTasks = tasks.filter {
                ($0["type"] as? String) == "FileTask" && ["game", "launcher"].contains(($0["category"] as? String)?.lowercased() ?? "")
            }
            for task in gameTasks {
                guard let path = task["path"] as? String else { continue }
                let rel = path.replacingOccurrences(of: "\\", with: "/")
                let url = folder.appendingPathComponent(rel)
                guard FileManager.default.fileExists(atPath: url.path), url.pathExtension.lowercased() == "exe",
                      !games.contains(where: { $0.url == url }) else { continue }
                let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
                let primary = (task["isPrimary"] as? Bool) == true
                let name = primary || gameTasks.count == 1 ? title : ((task["name"] as? String) ?? title)
                games.append(FoundGame(url: url, name: name, size: size, suggested: primary))
            }
        }
        if !games.isEmpty {
            if !games.contains(where: \.suggested) {
                games[0] = FoundGame(url: games[0].url, name: games[0].name, size: games[0].size, suggested: true)
            }
            return games.sorted { ($0.suggested ? 0 : 1) < ($1.suggested ? 0 : 1) }
        }
        return scanExecutables(in: folder)
    }

    private static func scanExecutables(in folder: URL) -> [FoundGame] {
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                                                          options: [.skipsHiddenFiles, .skipsPackageDescendants]) else { return [] }
        let skipDirs: Set<String> = ["__redist", "redist", "_commonredist", "directx", "vcredist", "tmp", "__support", "support"]
        var found: [(URL, Int64)] = []
        for case let url as URL in walker {
            if walker.level > 5 || skipDirs.contains(url.lastPathComponent.lowercased()) {
                if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true { walker.skipDescendants() }
                continue
            }
            guard url.pathExtension.lowercased() == "exe",
                  let verdict = try? ExeInspector.inspect(at: url), verdict.kind == .application else { continue }
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(Int64.init) ?? 0
            found.append((url, size))
        }
        let biggest = found.map(\.1).max()
        return found
            .map { FoundGame(url: $0.0, name: GameTitle.resolve(exe: $0.0), size: $0.1, suggested: $0.1 == biggest) }
            .sorted { ($0.suggested ? 0 : 1, -$0.size) < ($1.suggested ? 0 : 1, -$1.size) }
    }
}
