import Foundation

/// Откуда берётся обложка для игры, добавленной ВРУЧНУЮ.
///
/// Источник отдаёт только АДРЕС картинки, а качает её кеш. Так сделано намеренно:
/// нам не надо ни хранить чужие изображения у себя, ни отдавать их со своего сервера —
/// приложение забирает файл прямо с раздачи первоисточника.
protocol CoverArtSource {
    /// `nil` — обложки нет, и это обычный случай, а не ошибка.
    func artworkURL(title: String) async -> URL?
}

/// Наш посредник — источник по умолчанию, от человека НИЧЕГО не требует.
///
/// ★ Почему не зашить ключ SteamGridDB прямо в приложение: его вынимают из двоичного
///   за минуту, квота тогда одна на всех пользователей, и первоисточник справедливо
///   закроет её при первом же всплеске. Ключ живёт на сервере и не уезжает к людям.
///
/// ★ Почему сервер отдаёт АДРЕС, а не картинку: обложки на SteamGridDB выкладывает
///   сообщество, и раздавать их копии со своего сервера — вопрос прав. Мы храним только
///   соответствие «название -> адрес», то есть несколько десятков байт на игру.
///   Заодно это дёшево: одна и та же игра ищется один раз на всех.
struct MacRunnerCoverAPI: CoverArtSource {
    private struct Answer: Decodable {
        let url: URL?
    }

    var endpoint = URL(string: "https://api.macrunner.app/v1/cover")!
    var session: URLSession = .shared
    var timeout: TimeInterval = 12

    func artworkURL(title: String) async -> URL? {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard var components = URLComponents(url: endpoint, resolvingAgainstBaseURL: false) else { return nil }
        components.queryItems = [URLQueryItem(name: "title", value: trimmed)]
        guard let url = components.url else { return nil }

        var request = URLRequest(url: url)
        request.timeoutInterval = timeout
        do {
            let (data, response) = try await session.data(for: request)
            if let http = response as? HTTPURLResponse, !(200...299).contains(http.statusCode) { return nil }
            return try JSONDecoder().decode(Answer.self, from: data).url
        } catch {
            // Сеть, таймаут, наш сервер лежит — библиотека от этого страдать не должна.
            return nil
        }
    }
}
