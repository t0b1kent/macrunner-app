import SwiftUI
import AppKit

/// Витрина бесплатных игр.
///
/// ★★★ РЕДИЗАЙН 23.09.2026 (владелец: «а это можно красивее сделать?»). Было три
///   столбца узких строк: обложка 68×40, название обрезано на двенадцатом знаке
///   («Internationa…», «Dwarf Fortress (c…»), подпись «движок · описание» обрезана
///   тоже, плашка отъедала треть строки. Теперь — карточки как в магазине: обложка
///   во всю ширину, название целиком, две строки описания, плашка поверх обложки.
///
/// ★ Что осталось из прежних правил и почему:
///   • 32-битные сегодня не пойдут — они отдельным блоком В КОНЦЕ, серые, с плашкой
///     «32 бита», и сказано это ДО скачивания;
///   • хост загрузки и движок — в окне игры: это доказательство «напрямую от автора»
///     и наш рабочий признак совместимости, а не то, по чему игрок выбирает игру.
struct GamesShelf: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    @ObservedObject private var catalog = GameCatalog.shared

    let search: String
    /// Крупный заголовок раздела над витриной (новый вид); `nil` — без заголовка.
    var title: String? = nil
    var subtitle: String? = nil
    let onOpen: (FreeGame) -> Void

    /// Игра в большой карточке сверху — первая, что запустится сегодня и у которой есть обложка.
    /// Она же — фон раздела, пока курсор ни на чём не стоит.
    static func featured(in games: [FreeGame]) -> FreeGame? {
        games.first { $0.runsToday && $0.cover != nil }
    }

    var body: some View {
        let found = catalog.search(search)
        if let failure = catalog.loadFailure {
            CatalogFailureView(failure: failure, title: L("The games catalogue did not load"))
        } else if found.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                header.padding(.horizontal, 48).padding(.top, 6)
                CatalogEmptyView(text: L("Nothing in the catalogue matches this search."))
            }
        } else {
            // Большая карточка — только без поиска: в результатах поиска все равны.
            let featured = search.trimmingCharacters(in: .whitespaces).isEmpty ? Self.featured(in: found) : nil
            let ready = found.filter { $0.runsToday && $0.id != featured?.id }
            let later = found.filter { !$0.runsToday }
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xxl) {
                    header
                    if let featured { FeaturedGameCard(game: featured) { onOpen(featured) } }
                    if !ready.isEmpty { grid(ready) }
                    if !later.isEmpty {
                        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(L("Not running yet"))
                                    .font(Theme.Font.heading)
                                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                                Text(L("These are 32-bit builds. They will not run yet — 32-bit needs a permission from Apple we do not have."))
                                    .font(Theme.Font.caption)
                                    .foregroundColor(Theme.Palette.textTertiary(scheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            grid(later)
                        }
                    }
                }
                .padding(.horizontal, 48)
                .padding(.top, 6)
                .padding(.bottom, Theme.Spacing.xxxl)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder
    private var header: some View {
        if let title {
            VStack(alignment: .leading, spacing: 8) {
                Text(title)
                    .font(.system(size: 50, weight: .regular, design: .serif))
                    .kerning(-0.4)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 14.5))
                        .foregroundColor(Theme.Palette.textSecondary(scheme))
                }
            }
            .reveal(0.04)
        }
    }

    private func grid(_ games: [FreeGame]) -> some View {
        LazyVGrid(columns: CatalogGrid.columns, alignment: .leading, spacing: Theme.Spacing.l) {
            ForEach(games) { game in
                GameCard(game: game) { onOpen(game) }
            }
        }
    }
}

/// Карточка игры: обложка 16:10, плашка вида поверх неё, название и две строки описания.
struct GameCard: View {
    @ObservedObject private var loc = Localization.shared
    let game: FreeGame
    let onOpen: () -> Void

    static let coverAspect: CGFloat = 16.0 / 10.0

    var body: some View {
        CatalogCard(title: game.name, subtitle: game.summary, artAspect: Self.coverAspect,
                    dimmed: !game.runsToday,
                    backdrop: game.cover.map { .cover(url: $0.url, cacheID: game.id) },
                    onOpen: onOpen) {
            GameCoverArt(game: game, frameAspect: Self.coverAspect, monogramSize: 30)
        } badge: {
            // Вид игры («Бесплатная», «Ремейк»…) или «32 бита».
            CatalogBadge(text: game.runsToday ? game.kind.title : L("32-bit"))
        }
    }
}

/// Большая карточка сверху витрины: обложка во всю ширину, поверх — вид игры, крупное название,
/// описание и кнопка. Наклоняется за курсором слабее обычных — она большая.
struct FeaturedGameCard: View {
    @ObservedObject private var loc = Localization.shared
    let game: FreeGame
    let onOpen: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: onOpen) {
            ZStack(alignment: .bottomLeading) {
                // Картинка — наложением на пустую рамку: заливка не раздувает карточку (см. `RemoteCoverImage`).
                Color.clear
                    .overlay { GameCoverArt(game: game, frameAspect: 3.2, monogramSize: 64).scaleEffect(hovering ? 1.04 : 1) }
                    .clipped()
                LinearGradient(stops: [.init(color: .black.opacity(0.84), location: 0),
                                       .init(color: .black.opacity(0.35), location: 0.5),
                                       .init(color: .black.opacity(0), location: 0.78)],
                               startPoint: .leading, endPoint: .trailing)
                VStack(alignment: .leading, spacing: 8) {
                    Text(game.kind.title.uppercased())
                        .font(.system(size: 11.5, weight: .semibold))
                        .kerning(1.8)
                        .foregroundColor(.white.opacity(0.72))
                    Text(game.name)
                        .font(.system(size: 44, weight: .regular, design: .serif))
                        .foregroundColor(.white)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                    Text("\(game.summary) · \(game.author)")
                        .font(.system(size: 14))
                        .foregroundColor(.white.opacity(0.72))
                        .lineLimit(2)
                    HStack(spacing: 7) {
                        Text(L("Open"))
                        Image(systemName: "arrow.right").font(.system(size: 11, weight: .bold))
                    }
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(.black)
                    .padding(.horizontal, 20)
                    .frame(height: 40)
                    .background(Capsule().fill(Color.white))
                    .scaleEffect(hovering ? 1.04 : 1)
                    .padding(.top, 8)
                }
                .frame(maxWidth: 440, alignment: .leading)
                .padding(34)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 290)
            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous)
                .strokeBorder(Color.white.opacity(hovering ? 0.24 : 0.1), lineWidth: 0.75))
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .tiltHover(cornerRadius: 22, maxTiltX: 2.5, maxTiltY: 3.5, lift: 3)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.gentle, value: hovering)
        .backdrop(game.cover.map { .cover(url: $0.url, cacheID: game.id) }, whileHovering: hovering)
        .accessibilityLabel(game.name)
        .reveal(0.1)
    }
}

/// Обложка игры в рамке заданной формы. Нет обложки или не загрузилась — цветная
/// подложка с буквами названия: у каждой игры свой цвет, он не меняется между запусками.
struct GameCoverArt: View {
    let game: FreeGame
    let frameAspect: CGFloat
    var monogramSize: CGFloat = 30

    var body: some View {
        ZStack {
            placeholder
            if let cover = game.cover {
                RemoteCoverImage(url: cover.url, cacheID: game.id, frameAspect: frameAspect) { Color.clear }
            }
        }
    }

    private var placeholder: some View {
        CatalogArt.gradient(for: game.id)
            .overlay(
                Text(game.monogram)
                    .font(.system(size: monogramSize, weight: .bold, design: .rounded))
                    .foregroundColor(.white.opacity(0.82))
            )
    }
}

/// Окно игры: обложка, что это, откуда качается и пойдёт ли сегодня.
struct GameDetailSheet: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    let game: FreeGame
    let onClose: () -> Void

    private static let width: CGFloat = 560
    private static let bannerHeight: CGFloat = 230

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            banner

            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(game.name)
                        .font(.system(size: 24, weight: .semibold))
                        .kerning(-0.4)
                        .foregroundColor(Theme.Palette.textPrimary(scheme))
                        .lineLimit(2)
                    Text("\(game.author) · \(game.kind.title)")
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                }

                Text(game.summary)
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.Palette.textSecondary(scheme))
                    .fixedSize(horizontal: false, vertical: true)

                Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.l, verticalSpacing: 6) {
                    factRow(L("Engine"), game.engine)
                    factRow(L("Architecture"), game.bitness)
                    // Хост — доказательство «напрямую от автора»: показываем как есть.
                    factRow(L("Downloads from"), game.download.host, mono: true)
                    if let mb = game.download.sizeMB {
                        factRow(L("Size"), String(format: "%.0f MB", mb))
                    }
                }

                if !game.runsToday {
                    // ★ Предупреждаем ДО скачивания. Узнать про стену после 700 МБ —
                    //   худший способ узнать.
                    HStack(alignment: .top, spacing: Theme.Spacing.s) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 12))
                            .foregroundColor(GameStatus(text: "", tone: .warning).color(scheme))
                        Text(L("This is a 32-bit build. It will not run yet — 32-bit needs a permission from Apple we do not have."))
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.Palette.textSecondary(scheme))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(Theme.Spacing.m)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                        .fill(GameStatus(text: "", tone: .warning).color(scheme).opacity(0.1)))
                }

                if let notes = game.notes, !notes.isEmpty {
                    Text(notes)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

                Button {
                    guard let url = URL(string: game.download.landingURL),
                          let s = url.scheme?.lowercased(), s == "https" || s == "http" else { return }
                    NSWorkspace.shared.open(url)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right.square").font(.system(size: 11, weight: .bold))
                        // Обещание кнопки должно совпадать с тем, что случится:
                        // страница — «открыть», прямой файл — «скачать».
                        Text(game.download.landingIsPage
                             ? L("Open the download page") : L("Download from the author"))
                    }
                }
                .buttonStyle(.minimalPrimary)
                .padding(.top, Theme.Spacing.xs)

                // ★ Подсказку «берите win64» убрали намеренно (владелец, 12.09.2026:
                //   «я то разберусь с 32 бита, так что не надо говорить, какой брать»).
                //   Совет, опирающийся на ВРЕМЕННОЕ ограничение движка, становится
                //   враньём в тот день, когда ограничение снимут, — а править его
                //   тогда никто не вспомнит. Что умеет движок, записано в одном
                //   месте: `EngineCapabilities`.
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: Self.width)
        .background(Theme.Palette.bgPrimary(scheme))
        // ★★★ ВЫДЕЛЕНИЕ СТАВИМ НА КАЖДОМ ЛИСТЕ ОТДЕЛЬНО, А НЕ ТОЛЬКО В КОРНЕ.
        //   Измерено 12.09.2026: модификатор в корне `ContentView` в листы
        //   (`.sheet`) НЕ ПРОНИКАЕТ — лист поднимается в своём окне, и текст
        //   в нём остаётся невыделяемым.
        .textSelection(.enabled)
    }

    /// Обложка во всю ширину окна. Форма у обложек разная (160×120 и 1920×500),
    /// поэтому чужая форма вписывается целиком поверх размытой себя же.
    private var banner: some View {
        GameCoverArt(game: game, frameAspect: Self.width / Self.bannerHeight, monogramSize: 56)
            .frame(width: Self.width, height: Self.bannerHeight)
            .clipped()
            .saturation(game.runsToday ? 1 : 0)
            .overlay(alignment: .bottom) {
                // Низ обложки растворяется в окне — без жёсткой границы.
                LinearGradient(colors: [.clear, Theme.Palette.bgPrimary(scheme)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 70)
            }
            .overlay(alignment: .topTrailing) {
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundColor(.white)
                        .frame(width: 28, height: 28)
                        .background(Circle().fill(Color.black.opacity(0.5)))
                        .overlay(Circle().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                }
                .buttonStyle(.scalePress)
                .keyboardShortcut(.cancelAction)
                .accessibilityLabel(L("Close"))
                .padding(Theme.Spacing.l)
            }
    }

    private func factRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        GridRow {
            Text(label)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.Palette.textTertiary(scheme))
            Text(value)
                .font(mono ? Theme.Font.mono : Theme.Font.body)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
        }
    }
}

// MARK: - Общие пустые состояния

struct CatalogFailureView: View {
    @Environment(\.colorScheme) private var scheme
    let failure: String
    let title: String

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Theme.Palette.textTertiary(scheme))
            Text(title)
                .font(Theme.Font.heading)
                .foregroundColor(Theme.Palette.textPrimary(scheme))
            Text(failure)
                .font(Theme.Font.monoCaption)
                .foregroundColor(Theme.Palette.textTertiary(scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct CatalogEmptyView: View {
    @Environment(\.colorScheme) private var scheme
    let text: String

    var body: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Theme.Palette.textTertiary(scheme))
            Text(text)
                .font(Theme.Font.body)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
