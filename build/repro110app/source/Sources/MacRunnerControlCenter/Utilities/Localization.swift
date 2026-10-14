import Foundation
import SwiftUI

/// Язык интерфейса, выбираемый ВНУТРИ приложения.
///
/// Системной локали недостаточно: человек может держать macOS на английском, а игры
/// и лаунчер хотеть по-русски. Поэтому выбор свой, живёт в настройках и переключается
/// на ходу, без перезапуска.
enum AppLanguage: String, CaseIterable, Identifiable {
    case system
    case en
    case ru
    case zhHans = "zh-Hans"
    case es
    case ptBR = "pt-BR"
    case de
    case fr
    case ja
    case ko
    case tr
    case pl
    case it

    var id: String { rawValue }

    /// Языки, у которых есть каталог `.lproj`. Порядок — как в списке меню.
    static var translated: [AppLanguage] {
        allCases.filter { $0 != .system }
    }

    /// Код каталога `.lproj`. Для `system` — первый язык системы, для которого
    /// у нас есть перевод; не нашлось — английский, он же ключ, то есть всегда целый.
    var localeCode: String {
        switch self {
        case .system:
            let available = Set(Self.translated.map(\.rawValue))
            for tag in Locale.preferredLanguages {
                if available.contains(tag) { return tag }
                if let base = tag.split(separator: "-").first.map(String.init),
                   available.contains(base) { return base }
                // Китайский приходит как zh-Hans-CN или zh-CN — упрощённый ловим по основе.
                if tag.hasPrefix("zh"), available.contains("zh-Hans") { return "zh-Hans" }
                if tag.hasPrefix("pt"), available.contains("pt-BR") { return "pt-BR" }
            }
            return "en"
        default:
            return rawValue
        }
    }

    /// Флаг есть только у настоящих языков. У «системного» флага нет и быть не может —
    /// вместо него символ SF, он рисуется тем же шрифтом, что и весь интерфейс,
    /// и не выбивается из ряда чужой манерой рисовки.
    var flag: String? {
        switch self {
        case .system: return nil
        case .en: return "🇬🇧"
        case .ru: return "🇷🇺"
        case .zhHans: return "🇨🇳"
        case .es: return "🇪🇸"
        case .ptBR: return "🇧🇷"
        case .de: return "🇩🇪"
        case .fr: return "🇫🇷"
        case .ja: return "🇯🇵"
        case .ko: return "🇰🇷"
        case .tr: return "🇹🇷"
        case .pl: return "🇵🇱"
        case .it: return "🇮🇹"
        }
    }

    var symbolName: String { "globe" }

    var shortLabel: String {
        switch self {
        case .system: return L("Auto")
        case .zhHans: return "中文"
        case .ptBR: return "PT"
        default: return rawValue.uppercased()
        }
    }

    /// Название языка НА НЁМ ЖЕ: человек, ищущий русский, ищет слово «Русский»,
    /// а не «Russian» на языке, которого он может не знать.
    var nativeName: String {
        switch self {
        case .system: return L("System language")
        case .en: return "English"
        case .ru: return "Русский"
        case .zhHans: return "简体中文"
        case .es: return "Español"
        case .ptBR: return "Português (Brasil)"
        case .de: return "Deutsch"
        case .fr: return "Français"
        case .ja: return "日本語"
        case .ko: return "한국어"
        case .tr: return "Türkçe"
        case .pl: return "Polski"
        case .it: return "Italiano"
        }
    }
}

/// Хранит выбор языка и отдаёт строки. Виды подписываются на неё, поэтому смена
/// языка перерисовывает интерфейс сразу.
final class Localization: ObservableObject {
    static let shared = Localization()

    private static let storageKey = "macrunner.language"

    @Published var language: AppLanguage {
        didSet {
            UserDefaults.standard.set(language.rawValue, forKey: Self.storageKey)
            bundle = Self.bundle(for: language)
        }
    }

    private var bundle: Bundle

    private init() {
        let stored = UserDefaults.standard.string(forKey: Self.storageKey) ?? AppLanguage.system.rawValue
        let initial = AppLanguage(rawValue: stored) ?? .system
        language = initial
        bundle = Self.bundle(for: initial)
    }

    /// Перевод по ключу. Ключ — английская фраза: так строка остаётся читаемой в коде,
    /// а пропущенный перевод виден сразу английским текстом, а не «missing_key_42».
    func callAsFunction(_ key: String) -> String {
        bundle.localizedString(forKey: key, value: key, table: nil)
    }

    /// Текст, собранный из переводов на ДРУГОМ языке, — на текущем.
    ///
    /// ★ Итог графики («DirectX 11 · 64-bit · Experimental, not verified») пишется в
    ///   библиотеку готовой строкой на языке, который был при запуске. Сменил человек язык —
    ///   на странице игры оставался старый (снято 23.09.2026: английский хвост в русском
    ///   интерфейсе). Каждая часть между разделителями ищется среди переводов всех языков;
    ///   незнакомая (DirectX 11, OpenGL) остаётся как есть.
    func relocalize(_ text: String, separator: String = " · ") -> String {
        Self.relocalize(text, separator: separator) { self($0) }
    }

    static func relocalize(_ text: String, separator: String = " · ", translate: (String) -> String) -> String {
        text.components(separatedBy: separator)
            .map { part in keyByTranslation[part].map(translate) ?? part }
            .joined(separator: separator)
    }

    /// Перевод -> английский ключ, по всем языкам. Английская таблица даёт и ключи сами.
    private static let keyByTranslation: [String: String] = {
        var map: [String: String] = [:]
        for path in Bundle.appResources.paths(forResourcesOfType: "lproj", inDirectory: nil) {
            let file = (path as NSString).appendingPathComponent("Localizable.strings")
            guard let table = NSDictionary(contentsOfFile: file) as? [String: String] else { continue }
            for (key, value) in table where map[value] == nil { map[value] = key }
        }
        return map
    }()

    private static func bundle(for language: AppLanguage) -> Bundle {
        guard let path = lprojPath(for: language.localeCode),
              let localized = Bundle(path: path)
        else { return .appResources }
        return localized
    }

    /// Путь к каталогу языка — с поправкой на то, как его переименовал SPM.
    ///
    /// ★ SPM при сборке приводит регион к нижнему регистру: `zh-Hans.lproj` в бандле
    ///   лежит как `zh-hans.lproj`, `pt-BR.lproj` как `pt-br.lproj`. А
    ///   `Bundle.path(forResource:ofType:)` ищет С УЧЁТОМ регистра и молча отдаёт nil —
    ///   язык откатывается на английский, и снаружи это выглядит как «перевода нет».
    ///   Поймано 10.09.2026: китайский и португальский оставались английскими,
    ///   остальные десять языков работали.
    static func lprojPath(for code: String, in bundle: Bundle = .appResources) -> String? {
        if let exact = bundle.path(forResource: code, ofType: "lproj") { return exact }
        let wanted = code.lowercased()
        return bundle.paths(forResourcesOfType: "lproj", inDirectory: nil).first { path in
            ((path as NSString).lastPathComponent as NSString).deletingPathExtension.lowercased() == wanted
        }
    }
}

/// Короткая запись для видов: `L("Library")`.
/// Не свойство `Localization.shared`, а функция — чтобы вызов был заметен глазом
/// и непереведённую строку было видно при чтении кода.
func L(_ key: String) -> String { Localization.shared(key) }
