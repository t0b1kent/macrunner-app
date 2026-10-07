import Foundation

/// Каталог программ: что человек может поставить, кроме игр.
///
/// ★★★ ГЛАВНОЕ ПРАВИЛО КАТАЛОГА: если у программы ЕСТЬ родная версия для macOS —
///   мы ведём человека ТУДА, а не запускаем её через трансляцию. Родная всегда
///   быстрее и не тратит наш транслятор ни на что. Windows-установщик показываем
///   только когда родной версии нет.
///
///   Это не украшение, а смысл всего раздела: у конкурентов (Whisky, Heroic,
///   GameHub) раздела программ нет вовсе, и человек сам решает, где что искать.
enum ProgramCategory: String, Codable, CaseIterable, Identifiable {
    case microsoft, dev, graphics, cad, media, office, utility, games

    var id: String { rawValue }

    var title: String {
        switch self {
        case .microsoft: return L("Microsoft")
        case .dev: return L("Development")
        case .graphics: return L("Graphics")
        case .cad: return L("CAD & Engineering")
        case .media: return L("Media")
        case .office: return L("Office")
        case .utility: return L("Utilities")
        case .games: return L("Game platforms")
        }
    }

    /// Знак берём системный: рисовать 8 своих значков ради подписи категории —
    /// работа без выгоды, а SF Symbols уже согласованы с системой.
    var icon: String {
        switch self {
        case .microsoft: return "square.grid.2x2"
        case .dev: return "chevron.left.forwardslash.chevron.right"
        case .graphics: return "paintbrush"
        case .cad: return "ruler"
        case .media: return "play.rectangle"
        case .office: return "doc.text"
        case .utility: return "wrench.and.screwdriver"
        case .games: return "gamecontroller"
        }
    }
}

/// Насколько родная версия для macOS заменяет Windows-версию.
///
/// ★★★ РАДИ ЭТОГО РАЗЛИЧЕНИЯ И ПЕРЕПИСАН КАТАЛОГ (12.09.2026). Прежнее правило
///   «есть на Mac -> прячем» было слишком грубым и убивало самый ценный случай.
///   Образец — AutoCAD: версия для Mac существует, но это ДРУГОЙ продукт, без
///   ObjectARX и .NET-API, то есть без всей экосистемы сторонних надстроек.
///   Человеку с отраслевым плагином она не замена ничему, и правильный ответ —
///   поставить Windows-версию через нас.
///
///   Тот же разрыв у Excel (надстройки VBA), у Revit и у отраслевого софта.
///   Поэтому решение принимает человек, а фильтр только убирает случаи, где
///   выбора нет: родная полноценна, и гнать её через трансляцию незачем.
enum MacEquivalence: String, Codable {
    /// Родная версия равноценна. Такие в списке не показываем.
    case full
    /// Родная есть, но чего-то важного в ней НЕТ. Показываем и объясняем чего.
    case reduced
    /// Родной версии нет вовсе.
    case none
}

/// Где взять родную версию для macOS.
struct MacAvailability: Codable, Equatable {
    enum Kind: String, Codable {
        case appstore, official, homebrew
    }

    let kind: Kind
    let url: String
    /// Идентификатор в Mac App Store — только при `kind == .appstore`.
    let appstoreID: String?
    /// Имя пакета Homebrew — только при `kind == .homebrew`.
    let cask: String?
    let noteEN: String?
    let noteRU: String?

    var note: String? {
        Localization.shared.language.localeCode.hasPrefix("ru") ? (noteRU ?? noteEN) : (noteEN ?? noteRU)
    }

    var destination: String {
        switch kind {
        case .appstore: return L("Mac App Store")
        case .homebrew: return L("Official site")
        case .official: return L("Official site")
        }
    }

    enum CodingKeys: String, CodingKey {
        case kind, url, cask
        case appstoreID = "appstore_id"
        case noteEN = "note_en"
        case noteRU = "note_ru"
    }
}

/// Откуда брать установщик Windows.
struct WindowsAvailability: Codable, Equatable {
    /// Идентификатор пакета в winget. `nil` — значит пакета там нет и ставить
    /// придётся с сайта; молчать об этом нельзя, иначе кнопка обманет.
    let winget: String?
    let url: String?
}

struct Program: Codable, Identifiable, Equatable {
    let id: String
    let name: String
    let publisher: String
    let category: ProgramCategory
    let summaryEN: String
    let summaryRU: String
    let mac: MacAvailability?
    let windows: WindowsAvailability
    /// Чем родная версия отличается от Windows-версии. Поле НЕОБЯЗАТЕЛЬНОЕ:
    /// пока каталог не размечен, считаем по старому правилу — есть родная,
    /// значит полноценная. Разметка это уточняет, а не ломает.
    let macEquivalenceRaw: String?
    /// Чего именно не хватает в родной версии. Показывается на карточке.
    let macMissingEN: String?
    let macMissingRU: String?

    var summary: String {
        Localization.shared.language.localeCode.hasPrefix("ru") ? summaryRU : summaryEN
    }

    var macEquivalence: MacEquivalence {
        if let raw = macEquivalenceRaw, let v = MacEquivalence(rawValue: raw) { return v }
        return mac == nil ? .none : .full
    }

    /// Есть родная И она равноценна — вот тогда Windows-путь не предлагаем первым.
    var hasNativeMac: Bool { mac != nil }

    /// Стоит ли вообще показывать. Прячем ТОЛЬКО равноценные: там выбора нет.
    var worthShowing: Bool { macEquivalence != .full }

    /// Чего не хватает в родной версии — по-русски или по-английски.
    var macMissing: String? {
        Localization.shared.language.localeCode.hasPrefix("ru")
            ? (macMissingRU ?? macMissingEN) : (macMissingEN ?? macMissingRU)
    }

    /// Буквенная метка для плитки. Фирменных значков у нас нет и быть не может:
    /// это чужие товарные знаки, а качать их из сети ради витрины — лишняя
    /// зависимость и лишний отказ. Монограмма читается на 44 точках, в отличие
    /// от уменьшенного логотипа.
    var monogram: String {
        let words = name.split(whereSeparator: { $0 == " " || $0 == "-" })
        let letters = words.prefix(2).compactMap { $0.first.map(String.init) }
        let joined = letters.joined().uppercased()
        return joined.isEmpty ? "?" : String(joined.prefix(2))
    }

    enum CodingKeys: String, CodingKey {
        case id, name, publisher, category, mac, windows
        case summaryEN = "summary_en"
        case summaryRU = "summary_ru"
        case macEquivalenceRaw = "mac_equivalence"
        case macMissingEN = "mac_missing_en"
        case macMissingRU = "mac_missing_ru"
    }
}

/// Загрузка каталога из ресурса приложения.
///
/// ★ Отказ НЕ глушится. Пустой каталог с молчаливым `[]` выглядел бы как «программ
///   нет», хотя на деле это «файл не приехал в бандл» — ровно тот класс ошибки,
///   на котором в этом проекте уже терялись часы.
@MainActor
final class ProgramCatalog: ObservableObject {
    static let shared = ProgramCatalog()

    /// Что показываем: только программы БЕЗ родной версии для macOS.
    @Published private(set) var programs: [Program] = []
    /// Весь разобранный каталог, включая отсеянные. Нужен, чтобы на запрос
    /// «Photoshop» ответить «есть родной, вот он», а не «ничего не найдено».
    @Published private(set) var allPrograms: [Program] = []
    /// Почему каталог пуст. `nil` — значит загрузился.
    @Published private(set) var loadFailure: String?

    private init() { load() }

    func load() {
        guard let url = Bundle.appResources.url(forResource: "programs-catalog", withExtension: "json") else {
            loadFailure = "programs-catalog.json нет в бандле"
            FileHandle.standardError.write(Data("MacRunner: \(loadFailure!)\n".utf8))
            return
        }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(CatalogFile.self, from: data)
            // ★★★ ПОКАЗЫВАЕМ ТОЛЬКО ТО, РАДИ ЧЕГО МЫ СУЩЕСТВУЕМ (решение владельца,
            //   12.09.2026). У программы есть родная версия для Mac — ей не место в
            //   списке: человек поставит её из App Store или с сайта и без нас, а
            //   список из 72 строк, где 58 нам не нужны, только прячет нужные 14.
            //
            //   ★ ПОПРАВКА 12.09.2026, по замечанию владельца: отсеиваем НЕ всё, у
            //   чего есть родная версия, а только РАВНОЦЕННУЮ. AutoCAD для Mac
            //   существует, но без ObjectARX и .NET-API — сторонние надстройки там
            //   не работают, и Windows-версия через нас для такого человека
            //   единственный путь. Прятать её значило бы решать за него.
            //
            //   Записи с равноценной родной версией НЕ удалены из файла —
            //   они отсеиваются здесь и ещё пригодятся поиску.
            allPrograms = decoded.programs
            programs = decoded.programs.filter(\.worthShowing)
            loadFailure = nil
        } catch {
            loadFailure = "programs-catalog.json не разобран: \(error)"
            FileHandle.standardError.write(Data("MacRunner: \(loadFailure!)\n".utf8))
        }
    }

    func programs(in category: ProgramCategory) -> [Program] {
        programs.filter { $0.category == category }
    }

    /// Поиск по названию, издателю и описанию. Совпадение в НАЧАЛЕ названия
    /// поднимаем наверх: человек, набравший «auto», ждёт AutoCAD первым,
    /// а не программу, у которой это слово где-то в описании.
    func search(_ query: String) -> [Program] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return programs }
        return programs.compactMap { program -> (Program, Int)? in
            let name = program.name.lowercased()
            if name.hasPrefix(q) { return (program, 0) }
            if name.contains(q) { return (program, 1) }
            if program.publisher.lowercased().contains(q) { return (program, 2) }
            if program.summaryEN.lowercased().contains(q)
                || program.summaryRU.lowercased().contains(q) { return (program, 3) }
            if program.id.lowercased().contains(q) { return (program, 4) }
            return nil
        }
        .sorted { ($0.1, $0.0.name) < ($1.1, $1.0.name) }
        .map(\.0)
    }

    private struct CatalogFile: Codable {
        let version: Int
        let programs: [Program]
    }
}
