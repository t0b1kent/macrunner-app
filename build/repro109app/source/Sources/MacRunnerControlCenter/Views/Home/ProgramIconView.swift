import SwiftUI

/// Плитка программы: фирменный знак, значок с сайта или монограмма.
///
/// Порядок жёсткий и не случайный: сперва вектор (всегда чёткий и работает без сети),
/// потом картинка с сайта производителя, и лишь затем буквы. Монограмма — не позор,
/// а честный ответ «фирменного знака у нас нет»; подставлять вместо него знак
/// ИЗДАТЕЛЯ мы отказались намеренно: логотип Autodesk на строке Civil 3D врёт.
struct ProgramIconView: View {
    @Environment(\.colorScheme) private var scheme
    let programID: String
    let monogram: String
    var side: CGFloat = 40
    /// Только знак, без плитки и рамки — для цветной подложки карточки: тёмная
    /// плитка в размытии гасила цвета значка до бурого.
    var bare = false

    @ObservedObject private var catalog = ProgramIconCatalog.shared

    @ViewBuilder
    var body: some View {
        if bare {
            glyph.frame(width: side, height: side)
        } else {
            tile
        }
    }

    private var tile: some View {
        RoundedRectangle(cornerRadius: side * 0.25, style: .continuous)
            .fill(Theme.Palette.bgTertiary(scheme))
            .overlay { glyph }
            .clipShape(RoundedRectangle(cornerRadius: side * 0.25, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: side * 0.25, style: .continuous)
                    .strokeBorder(Theme.Palette.glyphTileBorder, lineWidth: Theme.Border.glyphTile)
            )
            .frame(width: side, height: side)
    }

    @ViewBuilder
    private var glyph: some View {
        switch catalog.source(for: programID) {
        case .bundled(let slug, let hex, let dark):
            silhouette(slug: slug, hex: hex, dark: dark)
        case .web(let url):
            // ★★★ ЗАПАСНОЙ ВАРИАНТ — СИЛУЭТ, А НЕ БУКВЫ.
            //   Сайтовый значок живёт по чужой ссылке и однажды протухнет. У 25
            //   программ рядом лежит готовый силуэт из бандла, и падать сразу на
            //   монограмму, имея его под рукой, — терять качество на ровном месте.
            //   Цепочка: сайт -> силуэт -> буквы.
            RemoteCoverImage(url: url, cacheID: "program-" + programID) { webFallback }
                .padding(side * 0.14)
        case .none:
            letters
        }
    }

    /// Чем заменяем сайтовый значок, когда он не загрузился.
    @ViewBuilder
    private var webFallback: some View {
        if case .bundled(let slug, let hex, let dark) = catalog.bundledSource(for: programID) {
            silhouette(slug: slug, hex: hex, dark: dark)
        } else {
            letters
        }
    }

    /// Вектор из Simple Icons. Не загрузился разбор пути — остаются буквы.
    @ViewBuilder
    private func silhouette(slug: String, hex: String, dark: Bool) -> some View {
        if let data = SVGIconLoader.pathData(slug: slug) {
            SVGIconShape(pathData: data)
                .fill(ProgramIconSource.bundled(slug: slug, hex: hex, dark: dark).tint)
                .padding(side * 0.22)
        } else {
            letters
        }
    }

    private var letters: some View {
        Text(monogram)
            .font(.system(size: side * 0.37, weight: .semibold))
            .foregroundColor(Theme.Palette.textSecondary(scheme))
    }
}
