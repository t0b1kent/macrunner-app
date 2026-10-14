import Foundation

/// Каталог бесплатных игр для Windows.
///
/// ★★★ ПРАВИЛО ИСТОЧНИКА — ТОЛЬКО НАПРЯМУЮ (решение владельца, 12.09.2026):
///   «только те, где напрямую можно скачать, а не через посредников».
///
///   Это не про вкус. Порталы загрузок (Softonic, CNET, FileHippo и им подобные)
///   заворачивают чужой установщик в свою оболочку и подкладывают рекламное ПО.
///   Отправить туда человека — значит своими руками привести ему мусор в систему.
///   Мы ведём к автору или не ведём никуда, и хост загрузки показываем на экране,
///   чтобы это можно было проверить глазами, а не принимать на слово.
enum GameKind: String, Codable {
    case freeware, demo, opensource, remake, mod

    var title: String {
        switch self {
        case .freeware: return L("Freeware")
        case .demo: return L("Demo")
        case .opensource: return L("Open source")
        case .remake: return L("Remake")
        case .mod: return L("Mod")
        }
    }
}

/// Откуда качаем. Других значений быть не может — см. правило источника.
enum GameHostKind: String, Codable {
    case official, github, itch
}

struct GameDownload: Codable, Equatable {
    let url: String
    let hostKind: GameHostKind
    let sizeMB: Double?
    /// Код ответа, полученный при сборке каталога. Не украшение: ссылка, которую
    /// никто не проверял, ломается молча и превращает кнопку в обман.
    let verifiedStatus: Int
    /// Устойчивая страница загрузки у официальных сайтов: найдена и проверена
    /// отдельным проходом 12.09.2026 — у всех 21 из 21. Проверка была двойной:
    /// код ответа И наличие на странице ровно того файла, что стоит в `url`.
    let landingURLRaw: String?
    let landingStatus: Int?

    /// Имя хоста показываем человеку — это и есть доказательство «напрямую».
    var host: String { URL(string: url)?.host ?? "" }

    /// ★★★ ВЕДЁМ НА СТРАНИЦУ ВЫПУСКОВ, А НЕ НА ФАЙЛ (решение владельца, 12.09.2026):
    ///   «может просто вести на страницу релизов, а человек уже сам выбирает».
    ///
    ///   Прямая ссылка на файл несёт номер версии и ПРОТУХАЕТ: в каталоге прибиты
    ///   `doomretro 6.3`, `inter-doom 9.0`, `BAR v1.2988.0`. Страница выпусков не
    ///   протухает никогда и обслуживания не требует — ровно поэтому двадцать игр
    ///   с itch у нас уже вечнозелёные.
    ///
    ///   Порядок источников: записанная страница -> выведенная для github -> сам файл.
    ///   Записанная идёт первой, потому что она НАЙДЕНА И ПРОВЕРЕНА человеком-проходом,
    ///   а выведенная — угадана по правилу. Правило хорошо там, где данных нет.
    var landingURL: String {
        if let page = landingURLRaw, !page.isEmpty { return page }
        guard hostKind == .github,
              let u = URL(string: url),
              u.host?.hasSuffix("github.com") == true else { return url }
        let parts = u.path.split(separator: "/")
        guard parts.count >= 2 else { return url }
        return "https://github.com/\(parts[0])/\(parts[1])/releases"
    }

    /// Ведёт ли кнопка на СТРАНИЦУ, а не прямо на файл. От этого зависит подпись
    /// кнопки: «открыть страницу» и «скачать» — разные обещания.
    var landingIsPage: Bool {
        landingURLRaw?.isEmpty == false || hostKind != .official
    }

    enum CodingKeys: String, CodingKey {
        case url
        case hostKind = "host_kind"
        case sizeMB = "size_mb"
        case verifiedStatus = "verified_status"
        case landingURLRaw = "landing_url"
        case landingStatus = "landing_status"
    }
}

/// Обложка игры — со страницы самого автора.
///
/// ★ ИЗМЕРЕНО на 49 обложках: 44 из них ШИРОКИЕ (медиана отношения 1,33), а шесть —
///   вовсе полосы шире 2,2 (`orbiter` 700×100, `nehrim` 1920×500). Поэтому в списке
///   плитка широкая, а не квадратная: банер, втиснутый в квадрат, превращается в кашу.
struct GameCover: Codable, Equatable {
    let url: String
    let width: Int
    let height: Int
    let source: String

    var aspect: CGFloat {
        height > 0 ? CGFloat(width) / CGFloat(height) : 1
    }
}

struct FreeGame: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let author: String
    let kind: GameKind
    /// Движок. Для нас важнее жанра: совместимость закрывается ДВИЖКАМИ —
    /// первая игра на движке даётся тяжело, остальные на нём почти даром.
    let engine: String
    let bitness: String
    let summaryEN: String
    let summaryRU: String
    let download: GameDownload
    let macNative: Bool
    let notesEN: String?
    let notesRU: String?
    /// ★ Без этого поля в `CodingKeys` Swift МОЛЧА выбрасывает обложку из JSON,
    ///   и на экране остаются монограммы при готовых данных. Поймано лейном 12.09.2026.
    let cover: GameCover?

    var summary: String {
        Localization.shared.language.localeCode.hasPrefix("ru") ? summaryRU : summaryEN
    }

    var notes: String? {
        Localization.shared.language.localeCode.hasPrefix("ru") ? (notesRU ?? notesEN) : (notesEN ?? notesRU)
    }

    /// Пойдёт ли игра на сегодняшнем движке.
    ///
    /// ★ Ответ берётся из `EngineCapabilities`, а НЕ зашит здесь: когда 32 бита
    ///   заработают, метки и предупреждения исчезнут сами, без правок в видах.
    ///   Одно место вместо россыпи по экранам — иначе снятое ограничение
    ///   продолжает жить в текстах, которые никто не помнит.
    var runsToday: Bool {
        bitness != "x86-32" || EngineCapabilities.i386Supported
    }

    var monogram: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == ":" })
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? "?" : String(joined.prefix(2))
    }

    enum CodingKeys: String, CodingKey {
        case id, name, author, kind, engine, bitness, download, cover
        case summaryEN = "summary_en"
        case summaryRU = "summary_ru"
        case macNative = "mac_native"
        case notesEN = "notes_en"
        case notesRU = "notes_ru"
    }
}

@MainActor
final class GameCatalog: ObservableObject {
    static let shared = GameCatalog()

    @Published private(set) var games: [FreeGame] = []
    @Published private(set) var loadFailure: String?

    private init() { load() }

    func load() {
        guard let url = Bundle.appResources.url(forResource: "games-catalog", withExtension: "json") else {
            loadFailure = "games-catalog.json нет в бандле"
            FileHandle.standardError.write(Data("MacRunner: \(loadFailure!)\n".utf8))
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(CatalogFile.self, from: data)
            // ★ Сторож на своё же правило: игра с родной сборкой под Mac в каталоге
            //   быть не должна. Если такая просочилась — не показываем, а не
            //   «наверное сойдёт». Молчаливое исключение тут дороже строгости.
            games = decoded.games.filter { !$0.macNative }
            loadFailure = nil
        } catch {
            loadFailure = "games-catalog.json не разобран: \(error)"
            FileHandle.standardError.write(Data("MacRunner: \(loadFailure!)\n".utf8))
        }
    }

    func search(_ query: String) -> [FreeGame] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return games }
        return games.compactMap { game -> (FreeGame, Int)? in
            let name = game.name.lowercased()
            if name.hasPrefix(q) { return (game, 0) }
            if name.contains(q) { return (game, 1) }
            if game.author.lowercased().contains(q) { return (game, 2) }
            if game.engine.lowercased().contains(q) { return (game, 3) }
            if game.summaryEN.lowercased().contains(q)
                || game.summaryRU.lowercased().contains(q) { return (game, 4) }
            return nil
        }
        .sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }
        .map(\.0)
    }

    private struct CatalogFile: Codable {
        let version: Int
        let games: [FreeGame]
    }
}
