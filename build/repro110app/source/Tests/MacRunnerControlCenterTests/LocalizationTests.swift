import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Переводы уже выглядели рабочими и не применялись: файлы на месте, ключи сходятся,
/// а интерфейс английский. Поэтому проверяем не наличие файлов, а САМ ПОИСК —
/// через тот же `Localization.lprojPath`, которым пользуется приложение.
/// Тест с собственным способом поиска проверял бы не приложение, а себя.
struct LocalizationTests {

    @Test func everyLanguageResolvesItsBundle() {
        for lang in AppLanguage.translated {
            #expect(Localization.lprojPath(for: lang.localeCode) != nil,
                    "нет каталога \(lang.localeCode).lproj в Bundle.module")
        }
    }

    /// Ключ обязан ПЕРЕВЕСТИСЬ, а не вернуться английским: английский здесь негоден
    /// как признак успеха — он же значение по умолчанию при любой поломке.
    @Test func noLanguageSilentlyFallsBackToKey() {
        var broken: [String] = []
        for lang in AppLanguage.translated where lang != .en {
            guard let path = Localization.lprojPath(for: lang.localeCode),
                  let bundle = Bundle(path: path) else {
                broken.append("\(lang.rawValue): нет каталога")
                continue
            }
            let value = bundle.localizedString(forKey: "Library", value: "Library", table: nil)
            if value == "Library" { broken.append("\(lang.rawValue): вернул ключ") }
        }
        #expect(broken.isEmpty, "не переводят: \(broken.joined(separator: ", "))")
    }

    /// Ровно те два языка, что ломались: регион в имени каталога, который SPM
    /// переписал в нижний регистр.
    @Test func regionCodedLanguagesSurviveLowercasing() throws {
        let zh = try #require(Localization.lprojPath(for: "zh-Hans"))
        let pt = try #require(Localization.lprojPath(for: "pt-BR"))
        let zhValue = try #require(Bundle(path: zh)).localizedString(forKey: "Library", value: "Library", table: nil)
        let ptValue = try #require(Bundle(path: pt)).localizedString(forKey: "Library", value: "Library", table: nil)
        #expect(zhValue == "游戏库")
        #expect(ptValue == "Biblioteca")
    }

    /// Отрицательный контроль прибора: несуществующий язык обязан дать nil,
    /// иначе поиск без учёта регистра находил бы что попало.
    @Test func unknownLanguageResolvesToNothing() {
        #expect(Localization.lprojPath(for: "xx-Nope") == nil)
    }

    @Test func russianActuallyTranslates() throws {
        let path = try #require(Localization.lprojPath(for: "ru"))
        let value = try #require(Bundle(path: path)).localizedString(forKey: "Library", value: "Library", table: nil)
        #expect(value == "Библиотека")
    }

    // MARK: - Полнота наборов ключей

    /// Таблица языка — из СОБРАННОГО бандла, тем же поиском каталога, что у приложения.
    /// `NSDictionary` читает и текстовый `.strings`, и двоичный plist, в который его
    /// может превратить сборка.
    private func table(_ code: String) -> [String: String]? {
        guard let dir = Localization.lprojPath(for: code),
              let file = Bundle(path: dir)?.path(forResource: "Localizable", ofType: "strings"),
              let dict = NSDictionary(contentsOfFile: file) as? [String: String]
        else { return nil }
        return dict
    }

    /// ★★★ КАЖДЫЙ ЯЗЫК ОБЯЗАН ЗНАТЬ КАЖДЫЙ АНГЛИЙСКИЙ КЛЮЧ.
    ///   Раньше десять языков из двенадцати держали 52 ключа из 261: всё остальное
    ///   молча показывалось по-английски, а прежние проверки смотрели только на
    ///   слово «Library» — и были зелёными. Лишний ключ тоже отказ: это перевод
    ///   строки, которой в английском больше нет, то есть устаревший текст.
    @Test func everyLanguageHasExactlyTheEnglishKeys() throws {
        let en = try #require(table("en"), "не прочитан en.lproj/Localizable.strings")
        #expect(en.count > 100, "в английской таблице подозрительно мало ключей: \(en.count)")
        let english = Set(en.keys)
        var problems: [String] = []
        for lang in AppLanguage.translated where lang != .en {
            guard let other = table(lang.localeCode) else {
                problems.append("\(lang.rawValue): таблица не прочитана")
                continue
            }
            let keys = Set(other.keys)
            let missing = english.subtracting(keys).sorted()
            let extra = keys.subtracting(english).sorted()
            if !missing.isEmpty {
                problems.append("\(lang.rawValue): нет \(missing.count) — \(missing.prefix(5).joined(separator: " | "))")
            }
            if !extra.isEmpty {
                problems.append("\(lang.rawValue): лишних \(extra.count) — \(extra.prefix(5).joined(separator: " | "))")
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    /// Спецификаторы формата в переводе те же, что в ключе: потерянный `%@` роняет
    /// строку без подстановки, лишний `%d` читает мусор со стека. Порядок не
    /// сравниваем — позиционные `%1$@` законно переставляют аргументы.
    @Test func translationsKeepFormatSpecifiers() throws {
        let en = try #require(table("en"))
        let pattern = try NSRegularExpression(pattern: #"%(?:\d+\$)?[-+ 0#]*\d*(?:\.\d+)?(?:ll|l|h)?([@dDiuUxXoOfeEgGcCsSpaA%])"#)
        func specifiers(_ text: String) -> [String] {
            let range = NSRange(text.startIndex..<text.endIndex, in: text)
            return pattern.matches(in: text, range: range).compactMap { match in
                guard let whole = Range(match.range, in: text) else { return nil }
                // Позицию выбрасываем: сравниваем только «что подставляется».
                return String(text[whole]).replacingOccurrences(of: #"\d+\$"#, with: "", options: .regularExpression)
            }.sorted()
        }
        var problems: [String] = []
        for lang in AppLanguage.translated {
            guard let other = table(lang.localeCode) else { continue }
            for key in en.keys.sorted() {
                guard let value = other[key] else { continue }
                if specifiers(key) != specifiers(value) {
                    problems.append("\(lang.rawValue): «\(key)» → «\(value)»")
                }
            }
        }
        #expect(problems.isEmpty, "\(problems.joined(separator: "\n"))")
    }

    // MARK: - Текст, сохранённый на другом языке

    /// Итог графики пишется в библиотеку на языке запуска. Сменил язык — строка
    /// обязана перевестись; незнакомая часть (название API) остаётся как есть.
    @Test func savedGraphicsSummaryFollowsTheLanguage() throws {
        let ruPath = try #require(Localization.lprojPath(for: "ru"))
        let ru = try #require(Bundle(path: ruPath))
        let toRussian: (String) -> String = { ru.localizedString(forKey: $0, value: $0, table: nil) }
        let english = "DirectX 11 · 64-bit · Experimental, not verified"
        let russian = Localization.relocalize(english, translate: toRussian)
        #expect(russian.hasPrefix("DirectX 11 · "))
        #expect(russian.hasSuffix(toRussian("Experimental, not verified")))
        #expect(toRussian("Experimental, not verified") != "Experimental, not verified")
        // И обратно: русская строка из библиотеки -> английский интерфейс.
        #expect(Localization.relocalize(russian) { $0 } == english)
    }

    /// ★ Заметка к результату прогона показывается игроку на странице игры. Заметка без
    ///   английского ключа в таблицах останется английской на всех одиннадцати языках —
    ///   добавил результат в `graphics-profiles.json`, добавь и перевод.
    @Test func everyProfileNoteIsTranslatable() throws {
        let en = try #require(table("en"))
        let notes = GraphicsProfile.bundled.flatMap { $0.known ?? [] }.compactMap(\.note)
        #expect(!notes.isEmpty, "в профилях нет ни одной заметки — прибор ничего не проверил")
        let missing = notes.filter { en[$0] == nil }
        #expect(missing.isEmpty, "нет перевода: \(missing)")
    }
}
