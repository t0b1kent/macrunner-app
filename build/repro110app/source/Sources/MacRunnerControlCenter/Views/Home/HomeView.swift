import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Витрина игрока.
///
/// ★★★ ПРАВИЛО ЭТОГО ЭКРАНА: человек пришёл ЗАПУСТИТЬ ИГРУ. Всё, что не ведёт
///   к этому за один шаг, здесь не живёт. Магазины, программы, загрузки, отчёты
///   и трассы убраны совсем: режим разработчика снят с входа 12.09.2026, его
///   файлы целы, но добраться до него из приложения нельзя.
///
///   Добавление игры — ОДНО действие: выбрал `.exe`, и он в библиотеке. Анкета
///   с разрядностью, доводами и переменными игроку не нужна: нужные поля мы
///   подставим сами.
///
/// ★★★ РЕДИЗАЙН 23.09.2026 (владелец: «простота, чтобы человек сразу знал, куда нажать
///   и запустил легко; минимализм»). Экран держится на трёх вещах: полоса «Продолжить» с
///   большой кнопкой «Играть», сетка обложек с одной фразой состояния и клетка «Добавить
///   игру». Вкладки «Игры/Программы» ушли из библиотеки: бесплатные игры — свой раздел,
///   программы спрятаны, пока не запускаются. Язык — в настройках, а не в шапке.
struct HomeView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    @EnvironmentObject var settingsVM: SettingsViewModel
    @StateObject private var vm = AppLibraryViewModel()

    @State private var showHelp = false
    @State private var detailApp: AppEntry?
    @State private var editingApp: AppEntry?
    @State private var runningIDs = Set<UUID>()
    @State private var section: HomeSection = .library
    @State private var addFailure: String?
    /// Что выбрали кнопкой «Добавить игру» и что мы об этом думаем.
    /// Показываем ДО того, как что-то сделали: установщик и игру надо запускать
    /// по-разному, а ошибиться распознавание может.
    @State private var pendingExe: PendingExe?
    @State private var detailGame: FreeGame?
    @State private var detailProgram: Program?
    @State private var programCategory: ProgramCategory?
    @ObservedObject private var programs = ProgramCatalog.shared
    @State private var showSettings = false
    /// Удаление ждёт подтверждения: что именно случится, решено заранее (`RemovalPlan`).
    @State private var pendingRemoval: PendingRemoval?
    @ObservedObject private var gameCatalog = GameCatalog.shared
    /// Отказ удаления, названный по имени. Молча проглотить его нельзя: человек
    /// нажал «удалить», игра осталась, и без объяснения это выглядит поломкой.
    @State private var removalFailure: String?
    /// Отказ ЗАПУСКА, не связанный с самой игрой: например, нет движка.
    /// Такой отказ нельзя класть на плитку — игра тут ни при чём.
    @State private var launchFailure: String?
    /// Файл тащат над библиотекой — подсвечиваем место, куда его можно бросить.
    @State private var dropTargeted = false
    /// Запущенные игры. Без этого «Стоп» на плитке был только значком: `runApp`
    /// для идущей игры просто выходил.
    @State private var activeRuns: [UUID: RunAppViewModel] = [:]
    @State private var launchProgress: [UUID: LaunchProgress] = [:]
    /// Идёт установщик (встроенный движок). В библиотеку он не кладётся: туда
    /// пойдёт то, что он установил (`FoundGamesSheet`).
    @State private var installRun: InstallRun?
    @State private var unpackRun: UnpackRun?
    @State private var unpackProgress: Double = 0
    @State private var foundGames: FoundGamesOffer?
    @ObservedObject private var updates = UpdateCenter.shared
    /// Фон окна из игры под курсором (новый вид, 25.09.2026).
    @StateObject private var backdrop = BackdropModel()
    /// Куда идём: вглубь (библиотека → игра → каталоги) или обратно — от этого зависит,
    /// откуда выплывает новый экран и куда отступает старый.
    @State private var forward = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // Постеры 2:3 — шаг сетки под ширину плитки 190, как в витринах магазинов.
    private let columns = [GridItem(.adaptive(minimum: 190, maximum: 210), spacing: Theme.Spacing.l, alignment: .top)]

    /// ★★★ НОВЫЙ ВИД 25.09.2026 (владелец выбрал «минимализм в стиле macOS», прототип одобрен:
    ///   «да, переноси»). За всем окном — фон из игры (`ArtBackdropView`), панель слева и кнопки —
    ///   матовое стекло, заголовка окна нет. Экраны стоят в пространстве: при переходе старый
    ///   отступает вглубь, новый выплывает спереди (`AnyTransition.depth`). Страница игры — в самом
    ///   окне, а не листом поверх него.
    var body: some View {
        ZStack {
            ArtBackdropView(source: backdrop.hovered ?? restingBackdrop)
                .ignoresSafeArea()

            HStack(spacing: 0) {
                HomeSidebar(
                    section: sectionBinding,
                    libraryCount: vm.apps.count,
                    freeCount: gameCatalog.games.count,
                    programCount: programs.search("").count,
                    onSettings: { showSettings = true },
                    onHelp: { showHelp = true }
                )

                VStack(spacing: 0) {
                    topBar
                        .padding(.leading, 48)
                        .padding(.trailing, 28)
                        .padding(.top, 28)
                        .padding(.bottom, 10)

                    ZStack {
                        page
                            .id(pageKey)
                            .transition(.depth(forward: forward, reduceMotion: reduceMotion))
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .frame(maxWidth: .infinity)
                // ★★★ ПЕРЕТАСКИВАНИЕ ФАЙЛА — ТОТ ЖЕ ПУТЬ, ЧТО У КНОПКИ «ДОБАВИТЬ ИГРУ».
                //   Пустая библиотека давно ОБЕЩАЛА «перетащите приложение», а
                //   приёмника не было вовсе: файл отскакивал обратно без слова.
                //   Брошенный файл идёт в `addFile` — тот же разбор, тот же лист.
                // Поиск общий для разделов; в библиотеке поле может быть скрыто, и старый
                // запрос из каталога фильтровал бы её невидимо.
                .onChange(of: section) { _, _ in vm.search = "" }
                .onDrop(of: [.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
                .overlay(dropHighlight)
                .overlay(alignment: .bottom) {
                    VStack(spacing: 0) {
                        updateBanner
                        launchBanner
                        installBanner
                        unpackBanner
                    }
                }
            }
            .ignoresSafeArea()
        }
        .environment(\.backdropModel, backdrop)
        #if DEBUG
        // Проверка вида без мыши (только отладочная сборка): MACRUNNER_UI_PREVIEW=discover|programs|game.
        .onAppear {
            switch ProcessInfo.processInfo.environment["MACRUNNER_UI_PREVIEW"] {
            case "discover": section = .discover
            case "programs": section = .programs
            case "game": DispatchQueue.main.asyncAfter(deadline: .now() + 2.5) { if let app = continueApp { openGame(app) } }
            case "discover-hover":
                section = .discover
                if let game = gameCatalog.games.first(where: { $0.name == "OpenApoc" }), let cover = game.cover {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { backdrop.enter(.cover(url: cover.url, cacheID: game.id)) }
                }
            case "settings": DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showSettings = true }
            case "help": DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { showHelp = true }
            case "programs-hover":
                section = .programs
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    backdrop.enter(.glow(forProgram: "microsoft.word", icon: ProgramIconCatalog.shared.source(for: "microsoft.word")))
                }
            default: break
            }
        }
        #endif
        .sheet(item: $editingApp) { app in
            AddAppView(app: app, onSave: {
                vm.update($0)
                editingApp = nil
            })
        }
        .alert(L("Could not delete the game"),
               isPresented: Binding(get: { removalFailure != nil },
                                    set: { if !$0 { removalFailure = nil } })) {
            Button(L("OK"), role: .cancel) { removalFailure = nil }
        } message: {
            Text(removalFailure ?? "")
        }
        .sheet(item: $pendingExe) { pending in
            AddExeSheet(
                url: pending.url,
                verdict: pending.verdict,
                onInstall: {
                    pendingExe = nil
                    // Встроенный движок знает свою бутылку — установленное найдём сами.
                    if BundledEngine.current != nil {
                        runInstaller(url: pending.url, name: pending.name)
                        return
                    }
                    // Сценарий разработчика: установщик добавляем в библиотеку и сразу
                    // запускаем, а установленное человек добавит сам.
                    let entry = AppEntry.new(name: pending.name, exePath: pending.url.path)
                    vm.add(entry)
                    runApp(entry)
                },
                onAddAsGame: {
                    vm.add(AppEntry.new(name: pending.name, exePath: pending.url.path))
                    pendingExe = nil
                },
                onCancel: { pendingExe = nil },
                onUnpack: { probe, base in
                    pendingExe = nil
                    startUnpack(installer: pending.url, probe: probe, base: base)
                }
            )
        }
        .sheet(item: $foundGames) { offer in
            FoundGamesSheet(
                installerName: offer.installer,
                games: offer.games,
                onAdd: { chosen in
                    for game in chosen {
                        var entry = AppEntry.new(name: game.name, exePath: game.url.path)
                        entry.workdir = game.url.deletingLastPathComponent().path
                        vm.add(entry)
                    }
                    foundGames = nil
                },
                onCancel: { foundGames = nil }
            )
        }
        .sheet(isPresented: $showSettings) {
            MinimalSettingsSheet(onClose: { showSettings = false })
                .environmentObject(settingsVM)
        }
        .confirmationDialog(
            pendingRemoval.map { RemovalText.title($0.plan, name: $0.app.name) } ?? "",
            isPresented: Binding(get: { pendingRemoval != nil }, set: { if !$0 { pendingRemoval = nil } }),
            titleVisibility: .visible,
            presenting: pendingRemoval
        ) { removal in
            Button(RemovalText.action(removal.plan), role: .destructive) { remove(removal.app, plan: removal.plan) }
            Button(L("Cancel"), role: .cancel) {}
        } message: { removal in
            Text(RemovalText.message(removal.plan))
        }
        .sheet(item: $detailGame) { game in
            GameDetailSheet(game: game, onClose: { detailGame = nil })
        }
        .sheet(item: $detailProgram) { program in
            ProgramDetailSheet(program: program, onClose: { detailProgram = nil })
        }
        .sheet(isPresented: $showHelp) {
            HelpSheet(onClose: { showHelp = false })
        }
        .alert(L("Could not start the game"),
               isPresented: Binding(get: { launchFailure != nil },
                                    set: { if !$0 { launchFailure = nil } })) {
            Button(L("OK"), role: .cancel) { launchFailure = nil }
        } message: {
            Text(launchFailure ?? "")
        }
        .alert(L("Could not add this file"), isPresented: Binding(
            get: { addFailure != nil },
            set: { if !$0 { addFailure = nil } }
        )) {
            Button(L("OK"), role: .cancel) { addFailure = nil }
        } message: {
            Text(addFailure ?? "")
        }
    }

    // MARK: - Верхняя строка

    /// Над содержимым — только поиск и «Добавить игру». Название раздела крупно стоит в самом
    /// разделе (новый вид), а у библиотеки вместо него — шапка «Продолжить».
    private var topBar: some View {
        HStack(spacing: Theme.Spacing.m) {
            if section == .licence {
                Text(section.title)
                    .font(Theme.Font.title)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
            }
            // Поиск нужен, когда есть что искать: в каталоге всегда, в своей библиотеке —
            // когда игр больше, чем помещается на экране.
            if detailApp == nil,
               section == .discover || section == .programs || (section == .library && vm.apps.count > 8) {
                searchField.frame(width: 280)
            }
            Spacer(minLength: 0)
            if section == .library, detailApp == nil {
                Button(action: addGame) {
                    HStack(spacing: 7) {
                        Image(systemName: "plus").font(.system(size: 11.5, weight: .bold))
                        Text(L("Add game"))
                    }
                }
                .buttonStyle(.glassCapsule(height: 34))
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        .frame(height: 34)
    }

    private var searchField: some View {
        HStack(spacing: Theme.Spacing.s) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 12, weight: .regular))
                .foregroundColor(Theme.Palette.textTertiary(scheme))
            TextField(L("Search"), text: $vm.search)
                .textFieldStyle(.plain)
                .font(Theme.Font.body)
                .foregroundColor(Theme.Palette.textPrimary(scheme))
            if !vm.search.isEmpty {
                Button { vm.search = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                }
                .buttonStyle(.plain)
                .accessibilityLabel(L("Clear search"))
            }
        }
        .padding(.horizontal, 14)
        .frame(height: 34)
        .glassCapsule()
    }

    // MARK: - Экраны

    @ViewBuilder
    private var page: some View {
        if section == .library, let opened = detailApp {
            // Запись берём свежую: после правки имя и путь на странице должны быть новыми.
            let app = vm.apps.first { $0.id == opened.id } ?? opened
            GamePageView(
                app: app,
                isRunning: runningIDs.contains(app.id),
                launchProgress: launchProgress[app.id],
                onRun: { runApp(app) },
                onEdit: { editingApp = app },
                // Подтверждение — одно на всё приложение, с честным текстом исхода.
                onDelete: { requestRemoval(app) },
                onBack: closeGame
            )
        } else {
            switch section {
            case .library: installedContent
            case .discover: GamesShelf(search: vm.search, title: L("Free games"), subtitle: sectionSubtitle,
                                       onOpen: { detailGame = $0 })
            case .programs: ProgramsView(search: vm.search, category: $programCategory,
                                         title: L("Programs"), subtitle: sectionSubtitle,
                                         onOpen: { detailProgram = $0 })
            case .licence: LicenceView()
            }
        }
    }

    /// Смена ключа и есть смена экрана: по нему SwiftUI запускает переход с глубиной.
    private var pageKey: String {
        detailApp.map { "game-" + $0.id.uuidString } ?? section.rawValue
    }

    /// Фон раздела, пока курсор ни на чём: обложка открытой игры или игры из шапки, обложка
    /// большой карточки бесплатных игр; у программ — нейтральное сияние.
    private var restingBackdrop: BackdropSource {
        switch section {
        case .library:
            guard let app = detailApp ?? continueApp else { return .neutral }
            return .artwork(GameArtworkRequest(app: app, catalog: gameCatalog.games))
        case .discover:
            guard let game = GamesShelf.featured(in: gameCatalog.games), let cover = game.cover else { return .neutral }
            return .cover(url: cover.url, cacheID: game.id)
        case .programs:
            // ★ Владелец, 25.09.2026: «а с разделом программ что — фон где норм?». Без наведения
            //   раздел светится переливами цветов первых программ в списке (Word синий, Excel
            //   зелёный, PowerPoint оранжевый…); сменил категорию — сменились и цвета.
            let shown = programs.search(vm.search).filter { programCategory == nil || $0.category == programCategory }
            var colors: [GlowColor] = []
            for program in shown.prefix(16) {
                guard let color = GlowColor.forProgram(program.id, icon: ProgramIconCatalog.shared.source(for: program.id)),
                      !colors.contains(color) else { continue }
                colors.append(color)
                if colors.count == 4 { break }
            }
            return colors.isEmpty ? .neutral : .colors(colors)
        case .licence:
            return .neutral
        }
    }

    // MARK: - Переходы

    private var sectionBinding: Binding<HomeSection> {
        Binding(get: { section }, set: { navigate(to: $0) })
    }

    /// Порядок экранов в глубину: библиотека ближе всех, страница игры за ней, дальше каталоги.
    private static func depth(_ section: HomeSection) -> Double {
        switch section {
        case .library: return 0
        case .discover: return 1
        case .programs: return 2
        case .licence: return 3
        }
    }

    private var pageSpring: Animation { .spring(response: 0.62, dampingFraction: 0.86) }

    /// ★★★ НАПРАВЛЕНИЕ СТАВИМ ОТДЕЛЬНЫМ ОБНОВЛЕНИЕМ, ДО СМЕНЫ ЭКРАНА. Уходящий экран берёт
    ///   переход из последнего обновления, в котором он ещё был; поменяй направление и экран
    ///   в одном обновлении — старый ушёл бы по прежнему направлению, навстречу новому.
    private func navigate(to target: HomeSection) {
        guard target != section || detailApp != nil else { return }
        let from = detailApp != nil ? 0.5 : Self.depth(section)
        forward = Self.depth(target) > from
        backdrop.reset()
        DispatchQueue.main.async {
            withAnimation(pageSpring) {
                section = target
                detailApp = nil
            }
        }
    }

    private func openGame(_ app: AppEntry) {
        forward = true
        backdrop.reset()
        DispatchQueue.main.async {
            withAnimation(pageSpring) {
                section = .library
                detailApp = app
            }
        }
    }

    private func closeGame() {
        guard detailApp != nil else { return }
        forward = false
        backdrop.reset()
        DispatchQueue.main.async {
            withAnimation(pageSpring) { detailApp = nil }
        }
    }

    // MARK: - Библиотека

    @ViewBuilder
    private var installedContent: some View {
        if vm.apps.isEmpty {
            EmptyLibraryView(onAdd: addGame)
        } else if vm.filteredApps.isEmpty {
            noMatchesView
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.xl) {
                    if vm.search.isEmpty { continueHero }
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(L("Library"))
                            .font(.system(size: 22, weight: .semibold))
                            .kerning(-0.3)
                            .foregroundColor(Theme.Palette.textPrimary(scheme))
                        Text(libraryCountLabel)
                            .font(.system(size: 13))
                            .foregroundColor(Theme.Palette.textTertiary(scheme))
                        Spacer(minLength: 0)
                    }
                    .reveal(0.22)
                    LazyVGrid(columns: columns, alignment: .leading, spacing: Theme.Spacing.xl) {
                        ForEach(vm.filteredApps) { app in
                            AppCardView(
                                app: app,
                                isRunning: runningIDs.contains(app.id),
                                launchProgress: launchProgress[app.id],
                                onRun: { runApp(app) },
                                onOpenDetail: { openGame(app) },
                                // Под курсором плитка — фон окна становится её обложкой.
                                backdrop: .artwork(GameArtworkRequest(app: app, catalog: gameCatalog.games))
                            )
                            // Плитки мягко выплывают и чуть увеличиваются, въезжая в окно при прокрутке.
                            .scrollTransition(.animated(.spring(response: 0.5, dampingFraction: 0.85))) { content, phase in
                                content
                                    .opacity(phase.isIdentity ? 1 : 0.35)
                                    .scaleEffect(phase.isIdentity ? 1 : 0.93)
                                    .offset(y: phase.value * 18)
                            }
                            .contextMenu {
                                Button(runningIDs.contains(app.id) ? L("Stop") : L("Play")) { runApp(app) }
                                Button(L("Show in Finder")) { showInFinder(app) }
                                Button(L("Edit")) { editingApp = app }
                                Divider()
                                Button(L("Remove") + "…", role: .destructive) { requestRemoval(app) }
                            }
                        }
                        if vm.search.isEmpty { addTile }
                    }
                    .reveal(0.28)
                }
                .padding(.horizontal, 48)
                .padding(.top, 4)
                .padding(.bottom, Theme.Spacing.xxl)
            }
        }
    }

    // MARK: - Продолжить

    /// Игра для шапки «Продолжить»: идущая сейчас, иначе последняя сыгранная, иначе
    /// последняя добавленная — чтобы у нового человека кнопка «Играть» была сразу.
    private var continueApp: AppEntry? {
        if let running = vm.apps.first(where: { runningIDs.contains($0.id) }) { return running }
        if let played = vm.apps.filter({ $0.lastRunStatus != nil }).max(by: { $0.updatedAt < $1.updatedAt }) {
            return played
        }
        return vm.apps.max(by: { $0.createdAt < $1.createdAt })
    }

    /// Шапка библиотеки: крупное название игры, состояние, большая «Играть» и обложка в пространстве
    /// с отражением. Фон окна в это время — её же обложка.
    @ViewBuilder
    private var continueHero: some View {
        if let app = continueApp {
            let running = runningIDs.contains(app.id)
            let status = GameStatus.of(app, isRunning: running, progress: launchProgress[app.id])
            HStack(alignment: .center, spacing: Theme.Spacing.xxl) {
                VStack(alignment: .leading, spacing: 0) {
                    Text((app.lastRunStatus == nil && !running ? L("Recently added") : L("Continue")).uppercased())
                        .font(.system(size: 11.5, weight: .semibold))
                        .kerning(1.8)
                        .foregroundColor(Theme.Palette.textSecondary(scheme))
                        .reveal(0.04)
                    Text(app.name)
                        .font(.system(size: 66, weight: .regular, design: .serif))
                        .kerning(-0.5)
                        .foregroundColor(Theme.Palette.textPrimary(scheme))
                        .lineLimit(2)
                        .minimumScaleFactor(0.5)
                        .padding(.top, 8)
                        .reveal(0.09)
                    HStack(spacing: Theme.Spacing.m) {
                        StatusCapsule(status: status)
                        if let graphics = GraphicsLine.short(app, loc: loc) {
                            Text(graphics)
                                .font(.system(size: 13))
                                .foregroundColor(Theme.Palette.textSecondary(scheme))
                                .lineLimit(1)
                        }
                    }
                    .padding(.top, 16)
                    .reveal(0.14)
                    HStack(spacing: Theme.Spacing.m) {
                        PlayButton(isRunning: running, large: true) { runApp(app) }
                        Button(L("Game page")) { openGame(app) }
                            .buttonStyle(.glassCapsule)
                    }
                    .padding(.top, 28)
                    .reveal(0.2)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Button { openGame(app) } label: {
                    CoverStage(app: app, width: 172, restYaw: -16)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(app.name)
                .padding(.trailing, 40)
                .reveal(0.12)
            }
            .padding(.top, 8)
        }
    }

    /// Последняя клетка сетки — «Добавить игру»: куда нажать, видно без поиска кнопки.
    private var addTile: some View {
        AddGameTile(action: addGame)
    }

    private func showInFinder(_ app: AppEntry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.exePath)])
    }

    struct PendingRemoval: Identifiable {
        let app: AppEntry
        let plan: RemovalPlan
        var id: UUID { app.id }
    }

    /// Что случится при удалении, решаем в момент нажатия и показываем словами.
    private func requestRemoval(_ app: AppEntry) {
        pendingRemoval = PendingRemoval(app: app, plan: GameRemoval.plan(exePath: app.exePath, ourFolders: ourFolders))
    }

    private var noMatchesView: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 28, weight: .light))
                .foregroundColor(Theme.Palette.textTertiary(scheme))
            Text(L("No matches"))
                .font(Theme.Font.heading)
                .foregroundColor(Theme.Palette.textPrimary(scheme))
            Text(String(format: L("Nothing in your library matches “%@”."), vm.search))
                .font(Theme.Font.body)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
            Button(L("Clear search")) { vm.search = "" }
                .buttonStyle(.minimalGhost)
                .padding(.top, Theme.Spacing.s)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sectionSubtitle: String {
        switch section {
        case .library: return libraryCountLabel
        case .discover:
            let total = gameCatalog.games.count
            guard !isSearching else { return foundLabel(gameCatalog.search(vm.search).count, of: total) }
            return String(format: L("%d free games, direct from the authors"), total)
        case .programs:
            let total = programs.search("").count
            let shown = programs.search(vm.search).filter { programCategory == nil || $0.category == programCategory }.count
            guard !isSearching, programCategory == nil else { return foundLabel(shown, of: total) }
            return String(format: L("%d Windows programs"), total)
        case .licence: return L("Plan, device and renewal")
        }
    }

    private var libraryCountLabel: String {
        let total = vm.apps.count
        if total == 0 { return L("Nothing here yet") }
        if vm.search.isEmpty {
            return total == 1 ? L("1 game") : String(format: L("%d games"), total)
        }
        return foundLabel(vm.filteredApps.count, of: total)
    }

    private var isSearching: Bool { !vm.search.trimmingCharacters(in: .whitespaces).isEmpty }

    /// ★ «Найдено 1 из 52», а не «1 free games» (владелец, 23.09.2026). Фраза «%d free games»
    ///   одна на любое число, а число 1 требует единственного — в русском и польском форм
    ///   вовсе три. «Найдено N из M» от числа не зависит ни в одном из двенадцати языков
    ///   и заодно говорит, из скольких искали.
    private func foundLabel(_ found: Int, of total: Int) -> String {
        String(format: L("Found %d of %d"), found, total)
    }

    // MARK: - Добавление

    /// Выбрал файл — игра в библиотеке. Больше ничего не спрашиваем.
    ///
    /// ★ Имя берём из файла, а не просим ввести: `Witcher3.exe` -> «Witcher3».
    ///   Переименовать можно потом, а на входе лишний вопрос только мешает.
    private func addGame() {
        let panel = NSOpenPanel()
        panel.title = L("Choose a Windows game or program")
        panel.prompt = L("Add")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        // Тип по расширению: у `.exe` нет собственного UTType на macOS, поэтому
        // объявляем его сами, иначе панель не даст выбрать ни одного файла.
        if let exe = UTType(filenameExtension: "exe") {
            panel.allowedContentTypes = [exe]
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        addFile(url)
    }

    /// Добавление ОДНОГО файла — общее для кнопки и для перетаскивания.
    private func addFile(_ url: URL) {
        switch url.pathExtension.lowercased() {
        case "exe":
            break
        case "msi":
            // ★ Честный отказ, а не «добавили и упало»: сценарий запуска разбирает
            //   только PE, а .msi — это база Windows Installer, и запуск дал бы
            //   INVALID_EXE уже после того, как файл лёг в библиотеку.
            addFailure = String(format: L("“%@” is a Windows Installer package (.msi). MacRunner cannot run .msi files yet — use the game’s .exe installer."), url.lastPathComponent)
            return
        default:
            addFailure = String(format: L("“%@” is not a Windows .exe file."), url.lastPathComponent)
            return
        }
        section = .library

        // Название игры, а не имя файла: `EoCApp` → «Divinity: Original Sin - Enhanced Edition».
        let name = GameTitle.resolve(exe: url)

        // ★★★ РАЗБИРАЕМ ФАЙЛ, А НЕ СПРАШИВАЕМ. Внутри `.exe` есть подписи сборщиков
        //   установщиков, манифест и строки версии — по ним видно, что это. Спрашивать
        //   «установщик или игра?» бессмысленно: большинство не знает ответа.
        //
        //   Разбор проверен на 32 настоящих файлах. Отказ разбора НЕ мешает добавить:
        //   не смогли понять — добавляем как игру, это прежнее поведение.
        do {
            let verdict = try ExeInspector.inspect(at: url)
            pendingExe = PendingExe(url: url, name: name, verdict: verdict)
        } catch {
            vm.add(AppEntry.new(name: name, exePath: url.path))
        }
    }

    /// Приём перетащенного файла. Берём ПЕРВЫЙ: лист решения показывается по
    /// одному файлу, а молча добавить остальные без разбора значило бы обойти его.
    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        guard section == .library,
              let provider = providers.first(where: { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) })
        else { return false }
        provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
            let url: URL?
            if let data = item as? Data {
                url = URL(dataRepresentation: data, relativeTo: nil)
            } else {
                url = item as? URL
            }
            guard let url, url.isFileURL else { return }
            DispatchQueue.main.async { addFile(url) }
        }
        return true
    }

    @ViewBuilder
    private var dropHighlight: some View {
        if dropTargeted, section == .library {
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .strokeBorder(Theme.Palette.textSecondary(scheme),
                              style: StrokeStyle(lineWidth: 1, dash: [6, 4]))
                .background(
                    RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                        .fill(Theme.Palette.bgSecondary(scheme).opacity(0.6))
                )
                .overlay(
                    VStack(spacing: Theme.Spacing.s) {
                        Image(systemName: "arrow.down.doc")
                            .font(.system(size: 28, weight: .light))
                        Text(L("Drop the .exe to add it"))
                            .font(Theme.Font.heading)
                    }
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                )
                .padding(Theme.Spacing.l)
                .allowsHitTesting(false)
        }
    }

    /// Выбранный файл вместе с вердиктом — ждёт слова человека.
    struct PendingExe: Identifiable {
        let url: URL
        let name: String
        let verdict: ExeVerdict
        var id: String { url.path }
    }

    /// Папки, куда ставим МЫ. Пока это одна — каталог бутылок из настроек.
    ///
    /// ★ Пустую строку сюда пропускать нельзя: `GameRemoval` считает своим то,
    ///   что лежит внутри перечисленного, а пустой путь совпал бы со всем сразу.
    ///   Сторож стоит и в самой службе, но лучше не подавать ей мусор.
    private var ourFolders: [String] {
        let bottles = (settingsVM.settings.bottlesDirectory as NSString).expandingTildeInPath
        var folders = bottles.isEmpty ? [] : [bottles]
        // Бутылки встроенного движка — тоже наши: установленное туда удаляется вместе с игрой.
        if BundledEngine.current != nil { folders.append(EnginePaths.bottles.path) }
        return folders
    }

    /// Удаление игры: сначала диск, потом запись.
    ///
    /// ★★★ ПОРЯДОК ВАЖЕН. Сначала выполняем план, и только если он прошёл —
    ///   убираем запись. Наоборот было бы хуже всего: запись исчезла, файлы
    ///   остались, и человек больше не может ни запустить игру, ни удалить её
    ///   из приложения — путь к ней потерян вместе с записью.
    private func remove(_ app: AppEntry, plan: RemovalPlan) {
        guard !UpdateSafetyGate.shared.isUpdating else {
            removalFailure = L("Finish or cancel the update before starting a program.")
            return
        }
        do {
            if let uninstaller = try GameRemoval.execute(plan) {
                // Деинсталлятор — обычная программа Windows, и запускается тем же
                // путём, что игра. Записи ждать нечего: он работает своим окном,
                // а закончит ли человек — нам не сообщат.
                let entry = AppEntry.new(name: (uninstaller as NSString).lastPathComponent,
                                         exePath: uninstaller)
                RunAppViewModel(settings: settingsVM.settings).run(app: entry)
            }
            vm.delete(app)
            if detailApp?.id == app.id { closeGame() }
        } catch {
            // ★ Причину показываем дословно и запись НЕ трогаем: не удалось убрать
            //   файлы — значит игра осталась, и в библиотеке она должна остаться тоже.
            removalFailure = error.localizedDescription
        }
    }

    private func runApp(_ app: AppEntry) {
        // Та же кнопка у идущей игры — «Стоп».
        if runningIDs.contains(app.id) {
            activeRuns[app.id]?.cancel()
            return
        }
        guard !UpdateSafetyGate.shared.isUpdating else {
            launchFailure = L("Finish or cancel the update before starting a program.")
            return
        }

        // ★ Движок проверяем ДО лицензии: без него не запустится ничего, и отправлять
        //   человека покупать лицензию к неработающей установке было бы издевательством.
        //   В запись игры отказ НЕ пишем — игра тут ни при чём.
        guard !RunFailure.engineMissing(settings: settingsVM.settings) else {
            launchFailure = RunFailure.engineMissingMessage
            return
        }

        // ★ Мягкое правило: уже запускавшаяся игра идёт всегда, новая — по лицензии.
        //   Проверка ЗДЕСЬ, в единственном месте запуска, а не в видах: разложить
        //   её по плиткам значит однажды забыть одну.
        // ★★ Пока лицензирование выключено (`ReleaseFlags`, ранний доступ бесплатный),
        //    проверки нет вовсе: ни одна игра не упирается в лицензию и никого не
        //    отправляют в раздел, которого нет в боковой панели.
        //    Путь деинсталлятора (`remove`) лицензию не спрашивал и раньше — он идёт
        //    мимо `runApp`, прямо через `RunAppViewModel`.
        let hasRunBefore = app.lastRunStatus != nil
        if ReleaseFlags.licensingEnabled,
           !LicenceStore.shared.state.allowsLaunch(hasRunBefore: hasRunBefore) {
            section = .licence
            return
        }
        runningIDs.insert(app.id)
        let runner = RunAppViewModel(settings: settingsVM.settings)
        let libraryVM = vm
        activeRuns[app.id] = runner
        runner.onProgress = { progress in launchProgress[app.id] = progress }
        runner.onComplete = { result in
            Task { @MainActor in
                var updated = app
                // A user stop says nothing about whether a game window rendered.
                updated.lastRunStatus = result?.status
                updated.lastDurationMs = result?.durationMs
                updated.lastGraphicsSummary = result?.graphicsSummary ?? updated.lastGraphicsSummary
                // Причину храним только у отказа: у удачного прогона старая улика
                // врала бы о прошлом.
                updated.lastRunError = RunFailure.isFailure(status: result?.status)
                    ? RunFailure.detail(from: result) : nil
                updated.updatedAt = Date()
                libraryVM.update(updated)
                runningIDs.remove(app.id)
                activeRuns[app.id] = nil
                launchProgress[app.id] = nil
                // Открытый лист карточки показывает ТОТ ЖЕ итог, что плитка.
                if detailApp?.id == app.id { detailApp = updated }
            }
        }
        runner.run(app: app)
    }

    // MARK: - Установка (встроенный движок)

    struct InstallRun {
        let name: String
        let runner: RunAppViewModel
    }

    struct UnpackRun {
        let title: String
        let handle: InstallerUnpacker.Handle
    }

    /// Распаковка установщика Inno Setup без запуска (innoextract), затем — предложение найденных игр.
    private func startUnpack(installer: URL, probe: InstallerUnpacker.Probe, base: URL) {
        guard unpackRun == nil, installRun == nil else {
            launchFailure = L("Another installer is still running. Finish it first.")
            return
        }
        do {
            try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        } catch {
            addFailure = String(format: L("Unpacking failed: %@"), error.localizedDescription)
            return
        }
        let destination = InstallerUnpacker.destination(base: base, title: probe.title)
        let language = InstallerUnpacker.chooseLanguage(available: probe.languages,
                                                        interface: Localization.shared.language.localeCode)
        let handle = InstallerUnpacker.Handle()
        unpackProgress = 0
        unpackRun = UnpackRun(title: probe.title, handle: handle)
        Task { @MainActor in
            do {
                try await InstallerUnpacker.unpack(installer, to: destination, language: language, handle: handle) { value in
                    Task { @MainActor in unpackProgress = value }
                }
                let found = await Task.detached { InstallerUnpacker.foundGames(in: destination) }.value
                    .filter { found in !vm.apps.contains { $0.exePath == found.url.path } }
                unpackRun = nil
                if found.isEmpty {
                    addFailure = String(format: L("Unpacked to %@, but no game was found there. Add its .exe with “Add game”."),
                                        (destination.path as NSString).abbreviatingWithTildeInPath)
                } else {
                    foundGames = FoundGamesOffer(installer: probe.title, games: found)
                }
            } catch InstallerUnpacker.Failure.cancelled {
                unpackRun = nil
            } catch {
                unpackRun = nil
                addFailure = String(format: L("Unpacking failed: %@"), error.localizedDescription)
            }
        }
    }

    struct FoundGamesOffer: Identifiable {
        let id = UUID()
        let installer: String
        let games: [FoundGame]
    }

    /// Запуск установщика в бутылке и поиск того, что он поставил.
    /// Снимок диска C берётся ДО запуска: новое после — это и есть установленное.
    private func runInstaller(url: URL, name: String) {
        guard !UpdateSafetyGate.shared.isUpdating else {
            launchFailure = L("Finish or cancel the update before starting a program.")
            return
        }
        guard installRun == nil else {
            launchFailure = L("Another installer is still running. Finish it first.")
            return
        }
        let prefix = EnginePaths.defaultBottle
        let runner = RunAppViewModel(settings: settingsVM.settings)
        installRun = InstallRun(name: name, runner: runner)
        let known = Set(vm.apps.map(\.exePath))
        Task { @MainActor in
            let before = await Task.detached { InstalledGameScanner.snapshot(prefix: prefix) }.value
            runner.onComplete = { result in
                Task { @MainActor in
                    let found = await Task.detached {
                        InstalledGameScanner.newGames(prefix: prefix, before: before, known: known)
                    }.value
                    installRun = nil
                    if !found.isEmpty {
                        foundGames = FoundGamesOffer(installer: name, games: found)
                    } else if let status = result?.status, RunFailure.isFailure(status: status),
                              let headline = RunFailure.headline(status: status) {
                        launchFailure = [headline, RunFailure.detail(from: result)].compactMap { $0 }.joined(separator: "\n")
                    } else if result?.status != "STOPPED" {
                        addFailure = L("The installer finished, but no new programs appeared. If the game is installed, add its .exe with “Add game”.")
                    }
                }
            }
            runner.run(app: AppEntry.new(name: name, exePath: url.path))
        }
    }

    /// Скачанное обновление ждёт установки. Под идущей игрой кнопка погашена: установка
    /// заменяет бандл, из которого игра работает (`UpdateCenter`).
    @ViewBuilder
    private var updateBanner: some View {
        if let version = updates.readyVersion {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
            let busy = !runningIDs.isEmpty || installRun != nil || unpackRun != nil || updates.isBusy
            HStack(spacing: Theme.Spacing.m) {
                Image(systemName: "arrow.down.circle")
                    .foregroundColor(Theme.Palette.textSecondary(scheme))
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("Update %@ is ready."), version))
                        .font(Theme.Font.bodyEmph)
                        .foregroundColor(Theme.Palette.textPrimary(scheme))
                    if busy {
                        Text(L("Close running programs, then choose Restart to update."))
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.Palette.textSecondary(scheme))
                    }
                }
                Spacer(minLength: 0)
                Button(L("Restart to update")) { updates.installNow() }
                    .buttonStyle(.minimalPrimary)
                    .disabled(busy)
            }
            .padding(Theme.Spacing.l)
            .glass(cornerRadius: Theme.Radius.large)
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.top, Theme.Spacing.l)
            }
        }
    }

    @ViewBuilder
    private var launchBanner: some View {
        ForEach(vm.apps.filter { launchProgress[$0.id] != nil }) { app in
            if let progress = launchProgress[app.id] {
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    HStack(spacing: Theme.Spacing.m) {
                        if progress.phase == .active {
                            Image(systemName: "app.badge")
                                .foregroundColor(Theme.Palette.textSecondary(scheme))
                        } else {
                            ProgressView().controlSize(.small)
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(app.name + " · " + progress.phase.title)
                                .font(Theme.Font.bodyEmph)
                                .foregroundColor(Theme.Palette.textPrimary(scheme))
                            if let guidance = progress.guidance(at: context.date) {
                                Text(guidance)
                                    .font(Theme.Font.caption)
                                    .foregroundColor(Theme.Palette.textSecondary(scheme))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        Spacer(minLength: 0)
                        Text(String(format: L("%d m %d s"),
                                    Int(max(0, context.date.timeIntervalSince(progress.startedAt))) / 60,
                                    Int(max(0, context.date.timeIntervalSince(progress.startedAt))) % 60))
                            .font(Theme.Font.monoCaption)
                            .foregroundColor(Theme.Palette.textSecondary(scheme))
                            .monospacedDigit()
                        Button(L("Stop")) { activeRuns[app.id]?.cancel() }
                            .buttonStyle(.minimalSecondary)
                            .disabled(progress.phase == .stopping)
                    }
                    .padding(Theme.Spacing.l)
                    .glass(cornerRadius: Theme.Radius.large)
                    .padding(.horizontal, Theme.Spacing.l)
                    .padding(.bottom, Theme.Spacing.l)
                }
            }
        }
    }

    @ViewBuilder
    private var installBanner: some View {
        if let run = installRun {
            HStack(spacing: Theme.Spacing.m) {
                ProgressView().controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("Installing %@"), run.name))
                        .font(Theme.Font.bodyEmph)
                        .foregroundColor(Theme.Palette.textPrimary(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(L("Finish the installation in the installer window. The installed game will be offered here."))
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textSecondary(scheme))
                }
                Spacer(minLength: 0)
                Button(L("Stop")) { run.runner.cancel() }
                    .buttonStyle(.minimalSecondary)
            }
            .padding(Theme.Spacing.l)
            .glass(cornerRadius: Theme.Radius.large)
            .padding(Theme.Spacing.l)
        }
    }

    @ViewBuilder
    private var unpackBanner: some View {
        if let run = unpackRun {
            HStack(spacing: Theme.Spacing.m) {
                ProgressView(value: unpackProgress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                VStack(alignment: .leading, spacing: 2) {
                    Text(String(format: L("Unpacking %@"), run.title))
                        .font(Theme.Font.bodyEmph)
                        .foregroundColor(Theme.Palette.textPrimary(scheme))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Text(String(format: L("%d%% — the game will be offered here when it is done."), Int(unpackProgress * 100)))
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textSecondary(scheme))
                }
                Spacer(minLength: 0)
                Button(L("Stop")) { run.handle.cancel() }
                    .buttonStyle(.minimalSecondary)
            }
            .padding(Theme.Spacing.l)
            .glass(cornerRadius: Theme.Radius.large)
            .padding(Theme.Spacing.l)
        }
    }
}

/// Плитка «Добавить игру»: при наведении пунктир бежит по кругу, плюс поворачивается, фон чуть светлеет.
private struct AddGameTile: View {
    @Environment(\.colorScheme) private var scheme
    let action: () -> Void
    @State private var hovering = false
    @State private var dashPhase: CGFloat = 0

    var body: some View {
        Button(action: action) {
            VStack(spacing: 10) {
                Image(systemName: "plus")
                    .font(.system(size: 24, weight: .light))
                    .rotationEffect(.degrees(hovering ? 90 : 0))
                    .scaleEffect(hovering ? 1.12 : 1)
                Text(L("Add game"))
                    .font(Theme.Font.bodyEmph)
            }
            .foregroundColor(hovering ? Theme.Palette.textPrimary(scheme) : Theme.Palette.textSecondary(scheme))
            .frame(width: 190, height: 285)
            .background(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .fill(Theme.Palette.textPrimary(scheme).opacity(hovering ? 0.04 : 0))
            )
            .overlay(
                RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                    .strokeBorder(hovering ? Theme.Palette.textSecondary(scheme) : Theme.Palette.border(scheme),
                                  style: StrokeStyle(lineWidth: 1, dash: [6, 5], dashPhase: dashPhase))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.scalePress)
        .animation(Theme.Motion.gentle, value: hovering)
        .onHover { entering in
            hovering = entering
            if entering {
                withAnimation(.linear(duration: 1.2).repeatForever(autoreverses: false)) { dashPhase -= 22 }
            } else {
                withAnimation(.easeOut(duration: 0.3)) { dashPhase = 0 }
            }
        }
        .help(L("Drop a Windows .exe here, or browse to add one."))
    }
}
