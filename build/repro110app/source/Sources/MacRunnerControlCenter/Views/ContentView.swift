import SwiftUI

struct ContentView: View {
    @StateObject private var settingsVM = SettingsViewModel()
    @State private var showOnboarding = false

    var body: some View {
        // ★★★ РЕЖИМ РАЗРАБОТЧИКА УБРАН ИЗ ДОСЯГАЕМОСТИ (решение владельца, 12.09.2026):
        //   «зачем он? если люди попросят — сделаем». Панель и её 21 раздел НЕ удалены,
        //   файлы на месте — убран только вход. Вернуть = вернуть эту ветку обратно.
        HomeView()
            .environmentObject(settingsVM)
        // ★★★ ВЫДЕЛЕНИЕ ТЕКСТА — НА ВЕСЬ ИНТЕРФЕЙС, ОДНОЙ СТРОКОЙ.
        //   В SwiftUI `Text` по умолчанию НЕ выделяется, и это выглядит как поломка:
        //   человек ведёт мышью, а ничего не подсвечивается. Включается наследуемым
        //   модификатором, поэтому ставим его один раз в корне, а не по одному месту —
        //   иначе следующий добавленный экран опять окажется невыделяемым.
        //
        //   Текст внутри кнопок остаётся невыделяемым сам собой (нажатие важнее),
        //   так что плитки и полки от этого не ломаются.
        .textSelection(.enabled)
        .frame(minWidth: 1024, minHeight: 700)
        .sheet(isPresented: $showOnboarding) {
            OnboardingView(isPresented: $showOnboarding)
                .environmentObject(settingsVM)
        }
        .onAppear {
            // Встроенный движок (выпускная сборка) корня репозитория не требует —
            // спрашивать игрока про папку, которой у него нет, нельзя. Зато бутылку под
            // новый движок готовим сразу, в фоне, а не когда человек нажмёт «Играть».
            if let engine = BundledEngine.current {
                EngineLauncher.prepareBottleInBackground(engine: engine)
                return
            }
            let settings = ConfigStore.shared.loadSettings()
            if settings.macRunnerRoot.isEmpty || !FileManager.default.fileExists(atPath: settings.macRunnerRoot) {
                showOnboarding = true
            }
        }
    }
}

struct DeveloperDashboardView: View {
    @Environment(\.colorScheme) private var scheme
    @Binding var developerMode: Bool
    @State private var selected: DeveloperPane = .library

    var body: some View {
        HStack(spacing: 0) {
            DeveloperSidebarView(selected: $selected, developerMode: $developerMode)
            Divider().background(Theme.Palette.separator(scheme))
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Theme.Palette.bgPrimary(scheme))
    }

    @ViewBuilder
    private var detail: some View {
        DeveloperPaneContainer(title: selected.title, symbol: selected.symbol) {
            paneContent
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        switch selected {
        case .library: AppLibraryView()
        case .runPanel: RunPanelView()
        case .stores: StoresPane()
        case .programs: ProgramsPane()
        case .bottles: BottleManagerView()
        case .d3d: D3DArtifactsView()
        case .queue: TaskQueueView()
        case .blocks: IntegrationBlocksView()
        case .doctor: DoctorView()
        case .logs: LiveLogView()
        case .processes: WineProcessView()
        case .performance: PerformanceView()
        case .compatDB: CompatibilityDBView()
        case .corpus: CorpusView()
        case .trial: LocalTrialWizardView()
        case .packaging: AppPackagingView()
        case .debugBundle: DebugBundleView()
        case .releases: ReleaseManagerView()
        case .worlds: ControlCenterWorldsView()
        case .help: HelpCenterView()
        case .settings: SettingsView()
        }
    }
}
