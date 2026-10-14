import SwiftUI

/// Витрина программ.
///
/// Устроена вокруг одного вопроса: «есть ли у этой программы родная версия для Mac».
/// Ответ виден НА ПЛИТКЕ, до всякого нажатия, потому что от него зависит всё
/// остальное — скорость, стабильность и нужен ли тут вообще наш транслятор.
struct ProgramsView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    @ObservedObject private var catalog = ProgramCatalog.shared

    /// Строка поиска общая с библиотекой: у человека одно поле ввода, а не два.
    let search: String
    @Binding var category: ProgramCategory?
    /// Крупный заголовок раздела над витриной (новый вид); `nil` — прежняя полоса категорий.
    var title: String? = nil
    var subtitle: String? = nil
    let onOpen: (Program) -> Void

    // ★★★ ЖИВОЙ ПОИСК ПО ВСЕМУ winget. Наш список — 198 программ, а в каталоге
    //   winget 14 840. Без этого «найти любую программу» упиралось бы в длину
    //   нашего списка, и человек решил бы, что её нет.
    //
    //   Указатель (8 МБ) качается ОДИН раз и только по запросу человека — не на
    //   запуске: тянуть мегабайты у того, кто просто открыл приложение, нечестно.
    @State private var wingetHits: [WingetHit] = []
    @State private var wingetBusy = false
    @State private var wingetError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
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
                .padding(.horizontal, 48)
                .padding(.top, 6)
                .reveal(0.04)
            }
            if catalog.loadFailure == nil {
                categoryBar
                if title == nil { Divider().background(Theme.Palette.separator(scheme)) }
            }
            content
        }
        .task(id: search) { await lookUpWinget() }
    }

    /// Ищем во всём каталоге winget то, чего нет у нас.
    ///
    /// ★ Задержка не для красоты: без неё каждая набранная буква запускала бы
    ///   свой запрос, и ответы приходили бы вперемешку. `task(id:)` снимает
    ///   прошлую попытку сам, поэтому достаточно подождать до начала работы.
    private func lookUpWinget() async {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard q.count >= 2 else {
            wingetHits = []; wingetError = nil; wingetBusy = false
            return
        }
        try? await Task.sleep(nanoseconds: 350_000_000)
        if Task.isCancelled { return }

        wingetBusy = true
        wingetError = nil
        do {
            if await !WingetIndex.shared.isReady() {
                try await WingetIndex.shared.prepare()
            }
            if Task.isCancelled { return }
            let hits = try await WingetIndex.shared.search(q, limit: 40)
            // Того, что уже есть в нашем списке, второй раз не показываем.
            let ours = Set(catalog.allPrograms.compactMap { $0.windows.winget?.lowercased() })
            wingetHits = hits.filter { !ours.contains($0.packageID.lowercased()) }
        } catch {
            wingetHits = []
            wingetError = error.localizedDescription
        }
        wingetBusy = false
    }

    /// Из попадания winget делаем обычную запись программы — тогда окно у неё
    /// то же самое, и установщик найдётся тем же путём. Описания и раздела у
    /// источника нет, и выдумывать их мы не будем.
    private func program(from hit: WingetHit) -> Program {
        Program(
            id: "winget:" + hit.packageID,
            name: hit.name,
            publisher: hit.publisher,
            category: .utility,
            summaryEN: hit.latestVersion.map { "Version \($0)" } ?? "",
            summaryRU: hit.latestVersion.map { "Версия \($0)" } ?? "",
            mac: nil,
            windows: WindowsAvailability(winget: hit.packageID, url: nil),
            macEquivalenceRaw: "none",
            macMissingEN: nil,
            macMissingRU: nil
        )
    }

    // MARK: - Категории

    private var categoryBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Theme.Spacing.s) {
                chip(title: L("All"), icon: "square.grid.3x3", active: category == nil) {
                    category = nil
                }
                ForEach(ProgramCategory.allCases) { cat in
                    // Пустую категорию не показываем: кнопка, ведущая в пустоту,
                    // читается как поломка каталога.
                    if !catalog.programs(in: cat).isEmpty {
                        chip(title: cat.title, icon: cat.icon, active: category == cat) {
                            category = (category == cat) ? nil : cat
                        }
                    }
                }
            }
            .padding(.horizontal, title == nil ? Theme.Spacing.xxl : 48)
            .padding(.vertical, Theme.Spacing.m)
        }
    }

    /// Чип с явным наведением (подложка светлеет, рамка ярче, чип приподнимается) — см. `HoverChip`.
    private func chip(title: String, icon: String, active: Bool, action: @escaping () -> Void) -> some View {
        HoverChip(title: title, icon: icon, active: active, action: action)
    }

    // MARK: - Содержимое

    private var shown: [Program] {
        let base = catalog.search(search)
        guard let category else { return base }
        return base.filter { $0.category == category }
    }

    @ViewBuilder
    private var content: some View {
        if let failure = catalog.loadFailure {
            // ★ Говорим ПРИЧИНУ. «Программ нет» здесь было бы враньём: они есть,
            //   это файл каталога не доехал.
            VStack(spacing: Theme.Spacing.m) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(Theme.Palette.textTertiary(scheme))
                Text(L("The programs catalogue did not load"))
                    .font(Theme.Font.heading)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                Text(failure)
                    .font(Theme.Font.monoCaption)
                    .foregroundColor(Theme.Palette.textTertiary(scheme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if shown.isEmpty, wingetHits.isEmpty, !wingetBusy {
            VStack(spacing: Theme.Spacing.m) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 26, weight: .light))
                    .foregroundColor(Theme.Palette.textTertiary(scheme))
                Text(L("No matches"))
                    .font(Theme.Font.heading)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                Text(L("Nothing in the catalogue matches this search."))
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.Palette.textSecondary(scheme))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    if !shown.isEmpty {
                        LazyVGrid(columns: CatalogGrid.columns, alignment: .leading, spacing: Theme.Spacing.l) {
                            ForEach(shown) { program in
                                ProgramCard(program: program) { onOpen(program) }
                            }
                        }
                    }
                    wingetSection
                }
                .padding(.horizontal, title == nil ? Theme.Spacing.xxl : 48)
                .padding(.top, title == nil ? Theme.Spacing.xl : Theme.Spacing.s)
                .padding(.bottom, Theme.Spacing.xl)
            }
            .scrollIndicators(.never)
        }
    }

    @ViewBuilder
    private var wingetSection: some View {
        if wingetBusy || !wingetHits.isEmpty || wingetError != nil {
            VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                HStack(spacing: 7) {
                    Text(L("ALSO IN THE WINGET CATALOGUE"))
                        .font(.system(size: 10, weight: .bold))
                        .kerning(1.2)
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                    if wingetBusy { ProgressView().controlSize(.small) }
                    Spacer(minLength: 0)
                }

                if let wingetError {
                    // ★ Причину показываем. Пустое место под заголовком человек
                    //   читает как «ничего нет», а на деле это отказ поиска.
                    Text(wingetError)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                } else if !wingetHits.isEmpty {
                    LazyVGrid(columns: CatalogGrid.columns, alignment: .leading, spacing: Theme.Spacing.l) {
                        ForEach(wingetHits) { hit in
                            let p = program(from: hit)
                            ProgramCard(program: p) { onOpen(p) }
                        }
                    }
                } else if wingetBusy {
                    Text(L("Preparing the winget catalogue on first use — about 8 MB."))
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                }
            }
        }
    }

}

/// Карточка программы — в стиле карточки игры (владелец, 23.09.2026: «программы
/// переделай в тот же стиль»). Обложек у программ нет, есть значок: он стоит крупно
/// посередине, а подложка — размытый он же, поэтому цвет у каждой карточки свой.
/// Метка платформы — поверх, как плашка у игр: это ГЛАВНЫЙ ответ, он виден первым.
struct ProgramCard: View {
    @ObservedObject private var loc = Localization.shared
    let program: Program
    let onOpen: () -> Void

    var body: some View {
        CatalogCard(title: program.name, subtitle: subtitle, artAspect: 2.0,
                    backdrop: .glow(forProgram: program.id, icon: ProgramIconCatalog.shared.source(for: program.id)),
                    onOpen: onOpen) {
            ProgramArt(program: program, iconSide: 56)
        } badge: {
            PlatformBadge(equivalence: program.macEquivalence)
        }
    }

    private var subtitle: String {
        program.summary.isEmpty ? program.publisher : "\(program.publisher) · \(program.summary)"
    }
}

/// Значок программы крупно на подложке из его же цветов.
struct ProgramArt: View {
    let program: Program
    var iconSide: CGFloat = 56

    @ObservedObject private var icons = ProgramIconCatalog.shared

    var body: some View {
        ZStack {
            if icons.source(for: program.id) != nil {
                // Фон нейтральный: цвет даёт сам значок. Случайный оттенок под ним
                // смешивался с цветом значка в бурое (снято 23.09.2026).
                Color(white: 0.11)
                // Размытый увеличенный знак без плитки — синяя подложка у Word,
                // красная у PowerPoint.
                ProgramIconView(programID: program.id, monogram: program.monogram, side: iconSide, bare: true)
                    .scaleEffect(3.6)
                    .blur(radius: 34)
                    .opacity(0.9)
            } else {
                // Значка нет — у монограммы свой постоянный цвет, как у игр без обложки.
                CatalogArt.gradient(for: program.id, brightness: 0.36)
            }
            ProgramIconView(programID: program.id, monogram: program.monogram, side: iconSide)
                .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
        }
    }
}

/// Метка платформы — ТРИ состояния, а не два.
///
/// ★ Двух не хватало: «есть для Mac» и «нет для Mac» ставят в один ряд Blender
///   (родной равноценен) и AutoCAD (родной есть, но без надстроек). Для человека
///   с отраслевым плагином это противоположные случаи, и метка обязана их
///   различать — иначе она врёт ровно там, где важнее всего.
struct PlatformBadge: View {
    @ObservedObject private var loc = Localization.shared
    let equivalence: MacEquivalence

    /// Стоит поверх картинки, поэтому подложка тёмная; «есть родная для Mac» — светлая:
    /// это главный ответ, и он обязан выделяться.
    var body: some View {
        CatalogBadge(text: title, icon: icon, inverted: equivalence == .full)
    }

    private var icon: String {
        switch equivalence {
        case .full: return "applelogo"
        case .reduced: return "exclamationmark.triangle"
        case .none: return "pc"
        }
    }

    private var title: String {
        switch equivalence {
        case .full: return L("Mac")
        case .reduced: return L("Mac is limited")
        case .none: return L("Windows")
        }
    }
}
