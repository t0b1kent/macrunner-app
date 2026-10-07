import Foundation

/// Обложки для игр, поставленных ВРУЧНУЮ.
///
/// У игр из магазинов картинка приходит вместе с библиотекой: Epic отдаёт keyImages,
/// GOG свои изображения, Steam складывает их по предсказуемому адресу (этим занят
/// `SteamCoverFetcher`). А у локально добавленной игры магазина нет вовсе, и брать
/// обложку неоткуда — до сих пор `CoverCache` рисовал заглушку с названием.
///
/// SteamGridDB — общественная база обложек с открытым API. На ней держатся Heroic,
/// Playnite и Steam ROM Manager, то есть путь проверенный.
///
/// ★ ЭТО ЗАПАСНОЙ ПУТЬ, А НЕ ОСНОВНОЙ. По умолчанию обложки идут через `MacRunnerCoverAPI`,
///   где ключ лежит на нашем сервере и от человека ничего не требуется. Прямое обращение
///   нужно двум случаям: своя квота у того, кто не хочет ходить через нас, и работа,
///   когда наш сервер недоступен.
///
/// ★ Служба НИКОГДА не роняет библиотеку: нет ключа, нет сети, нет совпадения —
///   возвращается `nil`, и вызывающий откатывается на следующий источник.
struct SteamGridDBService: CoverArtSource {
    /// Найденная игра в базе.
    struct Game: Decodable, Equatable {
        let id: Int
        let name: String
    }

    /// Одно изображение обложки.
    struct Artwork: Decodable, Equatable {
        let id: Int
        let url: URL
        let thumb: URL?
        let width: Int?
        let height: Int?
    }

    enum Failure: Error, LocalizedError {
        case noAPIKey
        case badStatus(Int)
        case malformedResponse

        var errorDescription: String? {
            switch self {
            case .noAPIKey: return "Ключ SteamGridDB не задан"
            case .badStatus(let code): return "SteamGridDB ответил кодом \(code)"
            case .malformedResponse: return "SteamGridDB вернул неразбираемый ответ"
            }
        }
    }

    private struct Envelope<T: Decodable>: Decodable {
        let success: Bool
        let data: T?
        let errors: [String]?
    }

    var baseURL = URL(string: "https://www.steamgriddb.com/api/v2")!
    var keyStore = SteamGridDBKeyStore()
    var session: URLSession = .shared
    /// Портрет 600×900 — та же пропорция 2:3, в которой библиотека рисует плитки.
    var preferredDimensions = "600x900"

    // MARK: - Публичное

    /// Адрес лучшей обложки по названию. `nil` — взять неоткуда, и это обычный случай.
    func artworkURL(title: String) async -> URL? {
        do {
            guard let game = try await searchFirst(title: title) else { return nil }
            return pickBest(try await grids(gameID: game.id))?.url
        } catch {
            return nil
        }
    }

    /// Первое совпадение по названию. Автодополнение сортирует по релевантности,
    /// поэтому берём голову списка, а не перебираем всё.
    func searchFirst(title: String) async throws -> Game? {
        try await search(title: title).first
    }

    func search(title: String) async throws -> [Game] {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        // Название идёт СЕГМЕНТОМ пути, а не параметром запроса, поэтому кодируем
        // именно как сегмент: иначе «Hollow Knight: Silksong» разъедет на двоеточии.
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? trimmed
        let url = baseURL.appendingPathComponent("search/autocomplete").appendingPathComponent(encoded)
        let envelope: Envelope<[Game]> = try await get(url)
        return envelope.data ?? []
    }

    func grids(gameID: Int) async throws -> [Artwork] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("grids/game/\(gameID)"),
            resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "dimensions", value: preferredDimensions),
            // Анимированные обложки в плитке дают лишнюю работу и мигание — берём статические.
            URLQueryItem(name: "types", value: "static")
        ]
        guard let url = components?.url else { throw Failure.malformedResponse }
        let envelope: Envelope<[Artwork]> = try await get(url)
        return envelope.data ?? []
    }

    // MARK: - Внутреннее

    /// Из нескольких обложек берём ту, что ближе всего к нужной пропорции 2:3.
    /// Размеры в ответе бывают пустыми — такие не отбрасываем, ставим в конец.
    func pickBest(_ artworks: [Artwork]) -> Artwork? {
        let target = 900.0 / 600.0
        return artworks.min { lhs, rhs in
            ratioDistance(lhs, target: target) < ratioDistance(rhs, target: target)
        }
    }

    func ratioDistance(_ artwork: Artwork, target: Double) -> Double {
        guard let width = artwork.width, let height = artwork.height, width > 0 else { return .greatestFiniteMagnitude }
        return abs(Double(height) / Double(width) - target)
    }

    private func get<T: Decodable>(_ url: URL) async throws -> Envelope<T> {
        guard let key = keyStore.loadAPIKey(), !key.isEmpty else { throw Failure.noAPIKey }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        request.timeoutInterval = 15
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw Failure.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(Envelope<T>.self, from: data)
        } catch {
            throw Failure.malformedResponse
        }
    }

}
