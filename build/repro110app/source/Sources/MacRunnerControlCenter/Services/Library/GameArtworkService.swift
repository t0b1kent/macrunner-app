import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Artwork identity only: launch settings and the library database are never changed.
struct GameArtworkRequest: Hashable, Sendable {
    let name: String
    let executablePath: String
    let steamID: String?
    let catalogURL: URL?

    init(app: AppEntry, catalog: [FreeGame]) {
        name = app.name
        executablePath = app.exePath
        steamID = app.env?["SteamAppId"] ?? app.env?["SteamGameId"]
        let identities = Set([Self.normalized(app.name),
                              Self.normalized(URL(fileURLWithPath: app.exePath).deletingPathExtension().lastPathComponent)])
        catalogURL = catalog.first {
            identities.contains(Self.normalized($0.name)) || identities.contains(Self.normalized($0.id))
        }?.cover.flatMap { URL(string: $0.url) }
    }

    static func normalized(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }.map(String.init).joined()
    }

    /// Exact identities verified against Steam's official store pages. No fuzzy
    /// title search: an unknown program must keep its own icon, not another game's art.
    var knownSteamID: String? {
        let identities = [name, URL(fileURLWithPath: executablePath).deletingPathExtension().lastPathComponent]
        let known = [
            "hollowknight": "367520",
            // Проверено 24.09.2026: store.steampowered.com/api/appdetails?appids=373420.
            "divinityoriginalsinenhancededition": "373420",
            "eldenring": "1245620",
            "factorio": "427520",
            "slaythespire": "646570",
            "skyrimse": "489830",
            "theelderscrollsvskyrimspecialedition": "489830"
        ]
        return identities.compactMap { known[Self.normalized($0)] }.first
    }
}

/// Disk reads, decoding, downloads and cache maintenance run off the main actor.
/// Only real, decodable artwork is cached; network failure leaves the exe icon visible.
actor GameArtworkService {
    static let shared = GameArtworkService()

    private let root: URL
    private let session: URLSession
    private var active: [GameArtworkRequest: Task<Data?, Never>] = [:]
    private var retryAfter: [GameArtworkRequest: Date] = [:]
    private let maxDownloadBytes = 8 * 1024 * 1024
    private let cacheLimitBytes = 100 * 1024 * 1024

    init(root: URL? = nil, session: URLSession? = nil) {
        self.root = root ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MacRunner/game-artwork-v1", isDirectory: true)
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 12
            configuration.timeoutIntervalForResource = 20
            configuration.httpMaximumConnectionsPerHost = 2
            self.session = URLSession(configuration: configuration)
        }
    }

    func artwork(for request: GameArtworkRequest) async -> Data? {
        if let task = active[request] { return await task.value }
        if let date = retryAfter[request], date > Date() { return nil }
        let task = Task { await self.load(request) }
        active[request] = task
        let result = await task.value
        active[request] = nil
        if result == nil { retryAfter[request] = Date().addingTimeInterval(300) }
        return result
    }

    private enum Source {
        case direct(URL)
        /// Обложка GOG по номеру игры из `goggame-*.info`: адрес картинки знает только API,
        /// поэтому в кеше ключ — номер, а не адрес (иначе каждый запуск спрашивал бы API).
        case gogBoxArt(String)

        var cacheKey: String {
            switch self {
            case .direct(let url): return url.absoluteString
            case .gogBoxArt(let id): return "gog-boxart:" + id
            }
        }
    }

    private func load(_ request: GameArtworkRequest) async -> Data? {
        for source in sources(for: request) {
            let digest = SHA256.hash(data: Data(source.cacheKey.utf8))
                .map { String(format: "%02x", $0) }.joined()
            let cached = root.appendingPathComponent(digest + ".png")
            if let bytes = imageFile(cached) { return bytes }
            let remote: URL
            switch source {
            case .direct(let url): remote = url
            case .gogBoxArt(let id):
                guard let url = await gogBoxArt(id) else { continue }
                remote = url
            }
            guard remote.scheme?.lowercased() == "https" else { continue }
            do {
                var urlRequest = URLRequest(url: remote)
                urlRequest.setValue("MacRunner/1.0", forHTTPHeaderField: "User-Agent")
                let (temporary, response) = try await session.download(for: urlRequest)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
                      http.url?.scheme?.lowercased() == "https",
                      http.mimeType?.hasPrefix("image/") == true,
                      let original = imageFile(temporary), let bytes = thumbnail(original)
                else { continue }
                try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
                try? bytes.write(to: cached, options: .atomic)
                trimCache()
                return bytes
            } catch {
                // Covers are optional. No modal error, generated artwork or launch delay.
                continue
            }
        }
        return nil
    }

    private func sources(for request: GameArtworkRequest) -> [Source] {
        // Exact title identity avoids using a launcher's generic Steam test ID as a cover.
        let appID = request.knownSteamID ?? validSteamID(request.steamID)
            ?? localSteamID(nextTo: request.executablePath)
        var sources: [Source] = []
        if let appID {
            for filename in ["library_600x900_2x.jpg", "library_600x900.jpg"] {
                if let url = URL(string: "https://shared.akamai.steamstatic.com/store_item_assets/steam/apps/\(appID)/\(filename)") {
                    sources.append(.direct(url))
                }
            }
        }
        if let catalog = request.catalogURL { sources.append(.direct(catalog)) }
        // Установка GOG сама называет свой номер игры — это точная личность, не поиск по имени.
        if !request.executablePath.isEmpty,
           let gog = GameTitle.gogInstall(for: URL(fileURLWithPath: request.executablePath)), gog.isGame {
            sources.append(.gogBoxArt(gog.gameID))
        }
        return sources
    }

    /// `api.gog.com/v2/games/<id>` → `_links.boxArtImage.href` (вертикальная обложка).
    /// Берём только https с `gog-statics.com`: адрес пришёл из сети, доверять ему вслепую нельзя.
    private func gogBoxArt(_ id: String) async -> URL? {
        guard let api = URL(string: "https://api.gog.com/v2/games/\(id)") else { return nil }
        var urlRequest = URLRequest(url: api)
        urlRequest.setValue("MacRunner/1.0", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await session.data(for: urlRequest),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              data.count <= 2 * 1024 * 1024,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let links = object["_links"] as? [String: Any],
              let box = links["boxArtImage"] as? [String: Any],
              let href = box["href"] as? String,
              let url = URL(string: href), url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host == "gog-statics.com" || host.hasSuffix(".gog-statics.com")
        else { return nil }
        return url
    }

    private func validSteamID(_ raw: String?) -> String? {
        guard let value = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty, value.count <= 10, value.allSatisfy({ $0.isASCII && $0.isNumber }),
              let number = UInt64(value), number > 0 else { return nil }
        return String(number)
    }

    private func localSteamID(nextTo executable: String) -> String? {
        guard !executable.isEmpty else { return nil }
        var directory = URL(fileURLWithPath: executable).deletingLastPathComponent()
        let nested: Set<String> = ["bin", "bin64", "bin32", "x64", "x86", "win64", "win32", "game", "binaries"]
        for _ in 0..<3 {
            let file = directory.appendingPathComponent("steam_appid.txt")
            if let handle = try? FileHandle(forReadingFrom: file) {
                defer { try? handle.close() }
                if let data = try? handle.read(upToCount: 64),
                   let id = validSteamID(String(data: data, encoding: .utf8)) { return id }
            }
            guard nested.contains(directory.lastPathComponent.lowercased()) else { break }
            directory.deleteLastPathComponent()
        }
        return nil
    }

    private func imageFile(_ url: URL) -> Data? {
        guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
              values.isRegularFile == true, let size = values.fileSize,
              size > 0, size <= maxDownloadBytes,
              let data = try? Data(contentsOf: url),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        return data
    }

    private func thumbnail(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int,
              width >= 120, height >= 120, width <= 12000, height <= 12000,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 900,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, UTType.png.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }

    private func trimCache() {
        let keys: Set<URLResourceKey> = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.filter { $0.pathExtension == "png" }.compactMap { url -> (URL, Int, Date)? in
            guard let values = try? url.resourceValues(forKeys: keys) else { return nil }
            return (url, values.fileSize ?? 0, values.contentModificationDate ?? .distantPast)
        }.sorted { $0.2 < $1.2 }
        var size = entries.reduce(0) { $0 + $1.1 }
        for entry in entries where size > cacheLimitBytes {
            if (try? FileManager.default.removeItem(at: entry.0)) != nil { size -= entry.1 }
        }
    }
}
