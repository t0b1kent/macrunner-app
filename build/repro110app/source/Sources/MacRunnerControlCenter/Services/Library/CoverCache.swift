import AppKit
import CryptoKit
import Foundation

struct CoverCacheEntry: Codable, Equatable {
    var provider: String
    var id: String
    var path: String
    var sizeBytes: Int64
    var updatedAt: Date
}

struct CoverCacheReport: Codable, Equatable {
    var root: String
    var totalSizeBytes: Int64
    var limitBytes: Int64
    var entries: [CoverCacheEntry]
}

struct CoverCache {
    /// Под этим именем лежат обложки, добытые из SteamGridDB. Отдельный провайдер нужен,
    /// чтобы их подхватывали `cachedCover` и чистка по объёму наравне с магазинными.
    static let gridDBProvider = "steamgriddb"

    var root: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("MacRunner/covers", isDirectory: true)
    var limitBytes: Int64 = 500 * 1024 * 1024

    /// Источники обложек по умолчанию — сперва наш посредник, от человека он ничего
    /// не требует; прямое обращение к SteamGridDB остаётся запасным, для своей квоты
    /// и для случая, когда наш сервер недоступен.
    static func defaultSources() -> [CoverArtSource] {
        [MacRunnerCoverAPI(), SteamGridDBService()]
    }

    /// Обложка для игры, добавленной ВРУЧНУЮ, — по порядку убывания качества:
    /// уже скачанная -> первый ответивший источник -> нарисованная заглушка.
    ///
    /// ★ Заглушка остаётся ПОСЛЕДНИМ рубежом, а не первым: раньше она была единственным
    ///   ответом, и библиотека выглядела набором безымянных плиток.
    ///
    /// ★ Заглушка не считается окончательной: она ложится под провайдером магазина, а
    ///   настоящая обложка — под `steamgriddb`. Значит следующий заход снова сходит в сеть
    ///   и заменит её, когда связь появится.
    func resolvedCover(
        provider: String,
        id: String,
        title: String,
        sources: [CoverArtSource] = CoverCache.defaultSources()
    ) async -> URL {
        if let cached = cachedCover(provider: Self.gridDBProvider, id: id) { return cached }
        if let cached = cachedCover(provider: provider, id: id) { return cached }

        for source in sources {
            guard let remote = await source.artworkURL(title: title) else { continue }
            if let saved = try? await download(remote, id: id) { return saved }
        }

        return (try? localCover(provider: provider, id: id, title: title))
            ?? root.appendingPathComponent(provider, isDirectory: true)
                .appendingPathComponent("\(Self.safeIdentifier(id)).png")
    }

    /// Картинка качается ПРЯМО с раздачи первоисточника и ложится под провайдером
    /// `steamgriddb`, чтобы её подхватывали `cachedCover` и чистка по объёму наравне
    /// с магазинными. Через наш сервер идут только названия и адреса, но не изображения.
    func download(_ remote: URL, id: String, session: URLSession = .shared) async throws -> URL {
        let (data, response) = try await session.data(from: remote)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw CocoaError(.fileReadUnknown)
        }
        let destination = downloadDestination(for: remote, id: id)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: destination, options: .atomic)
        try evictIfNeeded()
        return destination
    }

    /// Куда `download` кладёт картинку. Одна функция на запись и на поиск.
    func downloadDestination(for remote: URL, id: String) -> URL {
        let ext = remote.pathExtension.isEmpty ? "png" : remote.pathExtension.lowercased()
        return root.appendingPathComponent(Self.gridDBProvider, isDirectory: true)
            .appendingPathComponent("\(Self.safeIdentifier(id)).\(ext)")
    }

    /// Уже скачанная `download` картинка, если есть.
    ///
    /// ★★★ ПОИСК ОБЯЗАН ИДТИ ТЕМ ЖЕ ПУТЁМ, ЧТО ЗАПИСЬ. Витрина искала обложку в
    ///   `game/<id>.jpg|png`, а `download` клал её в `steamgriddb/game-<id>.<расширение>`:
    ///   кэш не срабатывал НИ РАЗУ, и 52 обложки игр плюс иконки программ качались
    ///   заново при каждом открытии (найдено 23.09.2026: 116 файлов лежат, не читается ни один).
    func downloadedCover(for remote: URL, id: String) -> URL? {
        let url = downloadDestination(for: remote, id: id)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    func localCover(provider: String, id: String, title: String) throws -> URL {
        let directory = root.appendingPathComponent(provider, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent("\(safe(id)).png")
        if !FileManager.default.fileExists(atPath: url.path) {
            try generatedCoverPNG(title: title).write(to: url)
        }
        try evictIfNeeded()
        return url
    }

    func cachedCover(provider: String, id: String, preferredExtensions: [String] = ["jpg", "png"]) -> URL? {
        let directory = root.appendingPathComponent(provider, isDirectory: true)
        for ext in preferredExtensions {
            let url = directory.appendingPathComponent("\(safe(id)).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    func report() -> CoverCacheReport {
        let entries = scanEntries()
        return CoverCacheReport(root: root.path, totalSizeBytes: entries.reduce(0) { $0 + $1.sizeBytes }, limitBytes: limitBytes, entries: entries)
    }

    func evictIfNeeded() throws {
        var entries = scanEntries()
        var total = entries.reduce(0) { $0 + $1.sizeBytes }
        guard total > limitBytes else { return }
        entries.sort { $0.updatedAt < $1.updatedAt }
        for entry in entries where total > limitBytes {
            try? FileManager.default.removeItem(atPath: entry.path)
            total -= entry.sizeBytes
        }
    }

    private func scanEntries() -> [CoverCacheEntry] {
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]) else { return [] }
        return enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { return nil }
            let provider = url.deletingLastPathComponent().lastPathComponent
            return CoverCacheEntry(provider: provider, id: url.deletingPathExtension().lastPathComponent, path: url.path, sizeBytes: Int64(values?.fileSize ?? 0), updatedAt: values?.contentModificationDate ?? .distantPast)
        }
    }

    private func generatedCoverPNG(title: String) throws -> Data {
        let image = NSImage(size: NSSize(width: 300, height: 450))
        image.lockFocus()
        NSColor(calibratedRed: 0.12, green: 0.15, blue: 0.18, alpha: 1).setFill()
        NSRect(x: 0, y: 0, width: 300, height: 450).fill()
        let digest = SHA256.hash(data: Data(title.utf8))
        let firstByte = Array(digest).first ?? 128
        let accent = CGFloat(firstByte) / 255.0
        NSColor(calibratedHue: accent, saturation: 0.62, brightness: 0.88, alpha: 1).setFill()
        NSBezierPath(roundedRect: NSRect(x: 28, y: 38, width: 244, height: 374), xRadius: 28, yRadius: 28).fill()
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.boldSystemFont(ofSize: 24),
            .foregroundColor: NSColor.white
        ]
        let text = title.isEmpty ? "MacRunner" : title
        let rect = NSRect(x: 42, y: 190, width: 216, height: 90)
        text.draw(in: rect, withAttributes: attrs)
        image.unlockFocus()
        guard let tiff = image.tiffRepresentation,
              let bitmap = NSBitmapImageRep(data: tiff),
              let png = bitmap.representation(using: .png, properties: [:])
        else { throw CocoaError(.fileWriteUnknown) }
        return png
    }

    /// Одно правило имени файла на весь кеш: и для магазинных обложек, и для SteamGridDB.
    /// Разъедься они — `cachedCover` перестал бы находить уже скачанное и качал заново.
    static func safeIdentifier(_ text: String) -> String {
        text.map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? String($0) : "-" }.joined()
    }

    private func safe(_ text: String) -> String { Self.safeIdentifier(text) }
}
