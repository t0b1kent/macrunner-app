import Foundation

/// Вход в GOG: обмен одноразового кода на токены, обновление и хранение.
///
/// ★ Постоянные ниже — ОТКРЫТЫЕ опознаватели настольного клиента GOG. Они лежат
///   в исходниках `gogdl` (на нём стоит Heroic) и одинаковы у всех свободных
///   клиентов: без них GOG просто не примет запрос. Это не чужая тайна и не наш
///   секрет — тайной является только токен пользователя, и он уходит в связку ключей.
enum GOGAuth {
    static let clientID = "46899977096215655"
    static let clientSecret = "9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9"
    static let redirectURI = "https://embed.gog.com/on_login_success?origin=client"

    /// Страница входа самого GOG. Логин и пароль человек вводит ТАМ, не у нас.
    static var authorizeURL: URL {
        var c = URLComponents(string: "https://auth.gog.com/auth")!
        c.queryItems = [
            .init(name: "client_id", value: clientID),
            .init(name: "redirect_uri", value: redirectURI),
            .init(name: "response_type", value: "code"),
            .init(name: "layout", value: "client2")
        ]
        return c.url!
    }

    /// Возврат узнаём по этому началу, код приезжает в параметре `code`.
    static let redirectPrefix = "https://embed.gog.com/on_login_success"
    static let codeParameter = "code"
}

/// Токены GOG. Храним вместе со временем получения: сервер отдаёт срок жизни
/// в секундах ОТ МОМЕНТА ВЫДАЧИ, и без отметки времени срок посчитать нечем.
struct GOGTokens: Codable, Equatable {
    var accessToken: String
    var refreshToken: String
    var expiresIn: Int
    var userID: String?
    var obtainedAt: Date

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case refreshToken = "refresh_token"
        case expiresIn = "expires_in"
        case userID = "user_id"
        case obtainedAt
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        refreshToken = try c.decode(String.self, forKey: .refreshToken)
        expiresIn = try c.decodeIfPresent(Int.self, forKey: .expiresIn) ?? 3600
        userID = try c.decodeIfPresent(String.self, forKey: .userID)
        // Свежий ответ сервера отметки времени не несёт — ставим своё.
        obtainedAt = try c.decodeIfPresent(Date.self, forKey: .obtainedAt) ?? Date()
    }

    /// Запас в минуту: токен, истекающий через секунду, считаем истёкшим.
    var isExpired: Bool {
        Date() >= obtainedAt.addingTimeInterval(TimeInterval(expiresIn) - 60)
    }
}

/// Токены в связке ключей. В файле настроек им не место: токен — это доступ к аккаунту.
struct GOGTokenStore {
    static let service = "app.macrunner.gog"
    private let account = "tokens"

    func save(_ tokens: GOGTokens) throws {
        let data = try JSONEncoder().encode(tokens)
        let text = String(decoding: data, as: UTF8.self)
        try KeychainSecretStore(service: Self.service).save(text, account: account)
    }

    func load() -> GOGTokens? {
        guard let text = KeychainSecretStore(service: Self.service).load(account: account),
              let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(GOGTokens.self, from: data)
    }

    func delete() throws {
        try KeychainSecretStore(service: Self.service).delete(account: account)
    }

    var hasTokens: Bool { load() != nil }
}

enum GOGAuthFailure: Error, LocalizedError {
    case badStatus(Int)
    case malformed

    var errorDescription: String? {
        switch self {
        case .badStatus(let code): return "GOG ответил кодом \(code)"
        case .malformed: return "GOG вернул неразбираемый ответ"
        }
    }
}

struct GOGAuthService {
    var session: URLSession = .shared
    var store = GOGTokenStore()

    /// Одноразовый код -> токены. Код живёт секунды, поэтому меняем сразу же.
    func exchange(code: String) async throws -> GOGTokens {
        let tokens = try await request(query: [
            .init(name: "client_id", value: GOGAuth.clientID),
            .init(name: "client_secret", value: GOGAuth.clientSecret),
            .init(name: "grant_type", value: "authorization_code"),
            .init(name: "redirect_uri", value: GOGAuth.redirectURI),
            .init(name: "code", value: code)
        ])
        try store.save(tokens)
        return tokens
    }

    /// Токен доступа живёт около часа, поэтому обновляем по токену обновления.
    func refreshIfNeeded() async throws -> GOGTokens? {
        guard let current = store.load() else { return nil }
        guard current.isExpired else { return current }
        let tokens = try await request(query: [
            .init(name: "client_id", value: GOGAuth.clientID),
            .init(name: "client_secret", value: GOGAuth.clientSecret),
            .init(name: "grant_type", value: "refresh_token"),
            .init(name: "refresh_token", value: current.refreshToken)
        ])
        try store.save(tokens)
        return tokens
    }

    private func request(query: [URLQueryItem]) async throws -> GOGTokens {
        var c = URLComponents(string: "https://auth.gog.com/token")!
        c.queryItems = query
        guard let url = c.url else { throw GOGAuthFailure.malformed }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) {
            throw GOGAuthFailure.badStatus(http.statusCode)
        }
        do {
            return try JSONDecoder().decode(GOGTokens.self, from: data)
        } catch {
            throw GOGAuthFailure.malformed
        }
    }
}
