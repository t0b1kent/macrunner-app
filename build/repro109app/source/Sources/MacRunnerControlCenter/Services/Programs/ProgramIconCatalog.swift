import Foundation
import SwiftUI

/// Откуда взять значок программы.
///
/// ★★★ ИСТОЧНИКОВ ДВА, И ЭТО ИЗМЕРЕНО, А НЕ ПРИДУМАНО.
///   Simple Icons (CC0, лежит у нас) покрывает 55 записей из 256 — но почти все они
///   у программ, которые мы ПРЯЧЕМ (Blender, VLC, GIMP: у них есть родная версия
///   для Mac). Из 216 показываемых набор закрыл лишь 26, то есть 12 %.
///
///   Причина названа их же владельцами: знаков Microsoft и Adobe в Simple Icons НЕТ
///   вовсе — те потребовали удаления. А это 45 наших записей, и самых узнаваемых.
///
///   Поэтому второй источник — значок с сайта самого производителя. Мы его НЕ
///   распространяем: ссылка лежит в каталоге, картинку берёт и кеширует приложение,
///   как это делает браузер.
enum ProgramIconSource: Equatable {
    /// Фирменный контур из Simple Icons: рисуется вектором, работает без сети.
    case bundled(slug: String, hex: String, dark: Bool)
    /// Значок с сайта производителя: качается один раз и кладётся на диск.
    case web(url: String)
}

@MainActor
final class ProgramIconCatalog: ObservableObject {
    static let shared = ProgramIconCatalog()

    private var bundled: [String: BundledIcon] = [:]
    private var web: [String: WebIcon] = [:]
    /// Ссылки, которые достались слишком многим программам сразу.
    ///
    /// ★★★ ИЗМЕРЕНО 12.09.2026: 40 плиток из 178 получали ОДИН ИЗ ТРЁХ значков —
    ///   19 раз подряд знак learn.microsoft.com (PowerToys, Process Explorer,
    ///   Autoruns, DebugView…), 11 раз microsoft.com, 10 раз autodesk.com.
    ///
    ///   Девятнадцать одинаковых логотипов в столбик НЕ РАЗЛИЧАЮТ НИЧЕГО — это
    ///   хуже монограмм, где «PT», «PE» и «AR» хотя бы разные. Издатель при этом
    ///   и так написан в строке текстом, так что бренд не теряется.
    private var overused: Set<String> = []
    /// Порог выбран ПО ЗАМЕРУ распределения, а не на глаз. Оно двугорбое:
    ///   1 программа × 87 ссылок,  2 × 14,  3 × 5,  4 × 1   — нормально
    ///   ───────────────── обрыв ─────────────────
    ///   11 × 1,  13 × 1,  19 × 1                          — вот это и не различает
    /// Порог 3 выбрасывал ещё и четвёрку Piriform (CCleaner, Defraggler, Recuva,
    /// Speccy) — четыре плитки зря: четыре программы одного издателя под общим
    /// знаком человек различает по названию без труда.
    private static let overuseLimit = 5
    /// Почему значков нет. `nil` — всё загрузилось.
    @Published private(set) var loadNote: String?

    private init() { load() }

    func source(for programID: String) -> ProgramIconSource? {
        // ★★★ ПОРЯДОК: СНАЧАЛА НАСТОЯЩИЙ ЗНАЧОК, ПОТОМ СИЛУЭТ.
        //   Simple Icons даёт ОДНОЦВЕТНЫЙ силуэт: у VLC оранжевый конус без белого,
        //   у Steam плоский знак. Рядом с настоящими цветными значками это выглядит
        //   сломанным — владелец сказал 12.09.2026: «как будто белый убран, и не у всех».
        //   Силуэт остаётся ТОЛЬКО как запасной, когда сайтового значка нет.
        if let w = web[programID], !overused.contains(w.url) { return .web(url: w.url) }
        return bundledSource(for: programID)
    }

    /// Только силуэт, в обход правила «сначала сайтовый значок».
    ///
    /// ★★★ ЗАЧЕМ ОТДЕЛЬНЫЙ ДОСТУП: сайтовый значок — ЧУЖАЯ ссылка, и она протухает.
    ///   Измерено 12.09.2026: у 25 программ есть ОБА источника, и при живой ссылке
    ///   показывается сайтовый. Если он умрёт, вид обязан опуститься на силуэт,
    ///   а не сразу на буквы — силуэт лежит в бандле, он рядом и он не протухает.
    ///   Через `source(for:)` его не достать: там web выигрывает всегда.
    func bundledSource(for programID: String) -> ProgramIconSource? {
        guard let b = bundled[programID] else { return nil }
        return .bundled(slug: b.slug, hex: b.hex, dark: b.dark ?? false)
    }

    private func load() {
        // Набор Simple Icons — обязателен: он в бандле, и его отсутствие это поломка.
        if let url = Bundle.appResources.url(forResource: "program-icons", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(BundledFile.self, from: data) {
            bundled = file.icons
        } else {
            loadNote = "program-icons.json не прочитан"
            FileHandle.standardError.write(Data("MacRunner: \(loadNote!)\n".utf8))
        }

        // ★ Набор с сайтов производителей НЕОБЯЗАТЕЛЕН: его собирает отдельный
        //   проход, и пока его нет, витрина просто показывает монограммы.
        //   Молчать об отсутствии можно — это не поломка, а неполнота.
        if let url = Bundle.appResources.url(forResource: "program-icons-web", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let file = try? JSONDecoder().decode(WebFile.self, from: data) {
            web = file.icons
            var uses: [String: Int] = [:]
            for icon in file.icons.values { uses[icon.url, default: 0] += 1 }
            overused = Set(uses.filter { $0.value > Self.overuseLimit }.keys)
        }
    }

    private struct BundledIcon: Codable { let slug: String; let hex: String; let dark: Bool? }
    private struct BundledFile: Codable { let icons: [String: BundledIcon] }
    private struct WebIcon: Codable { let url: String }
    private struct WebFile: Codable { let icons: [String: WebIcon] }
}

extension ProgramIconSource {
    /// Цвет фирменного знака.
    ///
    /// ★ Тёмный знак на нашем чёрном фоне не виден вовсе. Для помеченных `dark`
    ///   берём не фирменный цвет, а светлый — иначе значок есть, а на экране пусто.
    var tint: Color {
        guard case .bundled(_, let hex, let dark) = self else { return .white }
        if dark { return Color(white: 0.88) }
        var value: UInt64 = 0
        Scanner(string: hex).scanHexInt64(&value)
        return Color(red: Double((value >> 16) & 0xFF) / 255,
                     green: Double((value >> 8) & 0xFF) / 255,
                     blue: Double(value & 0xFF) / 255)
    }
}
