import SwiftUI
import AppKit

/// Окно программы: две дороги, и порядок между ними НЕ произвольный.
///
/// ★★★ Если родная версия для macOS есть — она идёт ПЕРВОЙ и крупной кнопкой.
///   Гнать Photoshop через трансляцию, когда рядом лежит родной, — это вред,
///   а не услуга. Наш транслятор существует для того, чего на Mac НЕТ.
struct ProgramDetailSheet: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared

    let program: Program
    let onClose: () -> Void

    /// Что известно про установщик Windows прямо сейчас.
    enum Lookup: Equatable {
        case idle
        case looking
        case found(WingetInstaller)
        case failed(String)
    }

    @State private var lookup: Lookup = .idle

    private static let width: CGFloat = 540

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                    // ★ ПОРЯДОК БЛОКОВ — ЭТО И ЕСТЬ СОВЕТ. Родная равноценна —
                    //   она первая. Родная урезана — ПЕРВЫМ идёт Windows, потому
                    //   что ради надстроек человек и пришёл. Родной нет — вопроса
                    //   не стоит вовсе.
                    switch program.macEquivalence {
                    case .full:
                        if let mac = program.mac { macBlock(mac) }
                        windowsBlock(secondary: true)
                    case .reduced:
                        windowsBlock(secondary: false)
                        if let mac = program.mac { macBlock(mac) }
                    case .none:
                        noMacBlock
                        windowsBlock(secondary: false)
                    }
                }
                .padding(Theme.Spacing.xl)
            }
        }
        // ★ Высота ПОСТОЯННАЯ: сведения об установщике приходят уже после открытия,
        //   а растущий лист macOS раздвигает от центра и не двигает содержимое —
        //   верх уезжает за край (поймано на странице игры 23.09.2026).
        .frame(width: Self.width, height: 580)
        .background(Theme.Palette.bgPrimary(scheme))
        // ★★★ ВЫДЕЛЕНИЕ СТАВИМ НА КАЖДОМ ЛИСТЕ ОТДЕЛЬНО, А НЕ ТОЛЬКО В КОРНЕ.
        //   Измерено 12.09.2026: модификатор в корне `ContentView` в листы
        //   (`.sheet`) НЕ ПРОНИКАЕТ — лист поднимается в своём окне, и текст
        //   в нём остаётся невыделяемым. Сборка при этом была свежая, символы
        //   в двоичном на месте: сломан был не код, а моё допущение о наследовании.
        .textSelection(.enabled)
        .task(id: program.id) { await resolveInstaller() }
    }

    /// Ищем настоящий установщик по каталогу winget. Делаем это СРАЗУ при открытии:
    /// человеку нужен ответ «что именно скачается», а не кнопка-загадка.
    private func resolveInstaller() async {
        guard let packageID = program.windows.winget else { return }
        lookup = .looking
        do {
            let found = try await WingetResolver.shared.bestInstaller(for: packageID)
            lookup = .found(found)
        } catch {
            lookup = .failed(error.localizedDescription)
        }
    }

    // MARK: - Шапка

    /// Сверху значок крупно на подложке из его цветов — как обложка у игры; метка
    /// платформы в углу, крестик в другом. Ниже название и издатель.
    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            ProgramArt(program: program, iconSide: 76)
                .frame(width: Self.width, height: 150)
                .clipped()
                .overlay(alignment: .bottom) {
                    // Низ растворяется в окне — без жёсткой границы.
                    LinearGradient(colors: [.clear, Theme.Palette.bgPrimary(scheme)],
                                   startPoint: .top, endPoint: .bottom)
                        .frame(height: 50)
                }
                .overlay(alignment: .topLeading) {
                    PlatformBadge(equivalence: program.macEquivalence).padding(Theme.Spacing.l)
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

            VStack(alignment: .leading, spacing: 4) {
                Text(program.name)
                    .font(.system(size: 24, weight: .semibold))
                    .kerning(-0.4)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                    .lineLimit(2)
                // Издатель и раздел; если они совпадают («Microsoft · Microsoft») — один раз.
                Text(program.publisher == program.category.title
                     ? program.publisher : "\(program.publisher) · \(program.category.title)")
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Palette.textTertiary(scheme))
            }
            .padding(.horizontal, Theme.Spacing.xl)
            .padding(.bottom, Theme.Spacing.xs)
        }
    }

    // MARK: - Родная версия

    private func macBlock(_ mac: MacAvailability) -> some View {
        let limited = program.macEquivalence == .reduced
        return block(
            icon: limited ? "exclamationmark.triangle" : "applelogo",
            title: limited ? L("The macOS version is not the same product")
                           : L("There is a native macOS version"),
            // ★ При урезанной версии говорим ЧЕГО НЕТ, а не общие слова.
            //   «Есть для Mac» без этого уточнения увело бы человека туда,
            //   где его плагин просто не запустится.
            subtitle: limited
                ? (program.macMissing ?? L("Some Windows features are missing there."))
                : (mac.note ?? L("Native builds run at full speed — no translation involved.")),
            emphasised: !limited
        ) {
            // Урезанная родная — кнопка второстепенная: главный путь у неё выше.
            actionButton(secondary: limited,
                         icon: mac.kind == .appstore ? "bag" : "arrow.up.right.square",
                         title: String(format: L("Open in %@"), mac.destination)) { open(mac.url) }


            if let cask = mac.cask {
                // Команду Homebrew показываем ТЕКСТОМ и даём скопировать. Выполнять
                // её за человека мы не будем: это установка в его систему, и решение
                // об этом принимает он, а не мы.
                HStack(spacing: 6) {
                    Text("brew install --cask \(cask)")
                        .font(Theme.Font.mono)
                        .foregroundColor(Theme.Palette.textSecondary(scheme))
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString("brew install --cask \(cask)", forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc").font(.system(size: 11))
                    }
                    .buttonStyle(.plain)
                    .help(L("Copy"))
                }
                .padding(.top, 2)
            }
        }
    }

    private var noMacBlock: some View {
        block(
            icon: "xmark.circle",
            title: L("No native macOS version"),
            subtitle: L("This is exactly what MacRunner is for: the Windows build runs here."),
            emphasised: false
        ) { EmptyView() }
    }

    // MARK: - Версия для Windows

    private func windowsBlock(secondary: Bool) -> some View {
        block(
            icon: "pc",
            title: secondary ? L("Windows version (through MacRunner)") : L("Windows version"),
            subtitle: secondary
                ? L("Only worth it if you need something the Mac build lacks.")
                : L("Download the installer, then add it here and we will run it."),
            emphasised: !secondary
        ) {
            switch lookup {
            case .idle, .failed:
                // Прямого установщика нет или не нашли — ведём на официальную
                // страницу. Кнопка говорит ровно то, что сделает.
                if let url = program.windows.url {
                    actionButton(secondary: secondary, icon: "arrow.up.right.square",
                                 title: L("Open the download page")) { open(url) }
                }
                if program.windows.winget == nil {
                    Text(L("Not in the winget catalogue — install it from the site."))
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                }
                if case .failed(let reason) = lookup {
                    // ★ Причину НЕ глушим. «Кнопка ведёт на сайт» без объяснения
                    //   выглядит как задумка, хотя на деле это отказ поиска.
                    Text(reason)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }

            case .looking:
                HStack(spacing: 7) {
                    ProgressView().controlSize(.small)
                    Text(L("Looking up the installer…"))
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                }

            case .found(let installer):
                actionButton(secondary: secondary, icon: "arrow.down.circle",
                             title: String(format: L("Download %@ %@"), program.name, installer.version)) {
                    open(installer.url.absoluteString)
                }

                // Что именно скачается — видно ДО нажатия: разрядность важна
                // (arm64-сборки Windows мы не запускаем), а имя хоста показывает,
                // что файл идёт с сайта издателя, а не от нас.
                HStack(spacing: 6) {
                    Image(systemName: "checkmark.seal")
                        .font(.system(size: 10))
                    Text("\(installer.architecture) · \(installer.url.host ?? "")")
                        .font(Theme.Font.monoCaption)
                }
                .foregroundColor(Theme.Palette.textTertiary(scheme))
                .padding(.top, 2)
            }
        }
    }

    // MARK: - Общий блок

    private func block<Content: View>(
        icon: String,
        title: String,
        subtitle: String,
        emphasised: Bool,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            HStack(alignment: .top, spacing: Theme.Spacing.m) {
                Image(systemName: icon)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(emphasised
                        ? Theme.Palette.textPrimary(scheme)
                        : Theme.Palette.textTertiary(scheme))
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(Theme.Font.heading)
                        .foregroundColor(Theme.Palette.textPrimary(scheme))
                    Text(subtitle)
                        .font(Theme.Font.body)
                        .foregroundColor(Theme.Palette.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                content()
            }
            .padding(.leading, 32)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Theme.Spacing.l)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .fill(Theme.Palette.bgSecondary(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .stroke(Theme.Palette.border(scheme), lineWidth: 0.5)
        )
    }


    /// ★★★ СТИЛЬ КНОПКИ ПРИМЕНЯЕМ ТОЛЬКО ЧЕРЕЗ `.buttonStyle`, НИКОГДА ручным
    ///   вызовом `makeBody`. Обёртка со стиранием типа, которая так делала,
    ///   стоила нечитаемой кнопки: `@Environment(\.colorScheme)` внутри стиля
    ///   подставляется ТОЛЬКО когда стиль применён системой. При ручном вызове
    ///   он остаётся `.light`, и текст красился почти чёрным по чёрному фону.
    ///   Поймано владельцем на глаз 12.09.2026: «ничего не видно что написано».
    @ViewBuilder
    private func actionButton(secondary: Bool, icon: String, title: String,
                              action: @escaping () -> Void) -> some View {
        let label = HStack(spacing: 6) {
            Image(systemName: icon).font(.system(size: 11, weight: .bold))
            Text(title)
        }
        if secondary {
            Button(action: action) { label }.buttonStyle(.minimalSecondary)
        } else {
            Button(action: action) { label }.buttonStyle(.minimalPrimary)
        }
    }

    /// Открываем ТОЛЬКО http(s) и только то, что пришло из нашего каталога.
    private func open(_ string: String) {
        guard let url = URL(string: string),
              let scheme = url.scheme?.lowercased(),
              scheme == "https" || scheme == "http"
        else { return }
        NSWorkspace.shared.open(url)
    }
}
