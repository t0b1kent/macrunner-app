import SwiftUI

/// Состояние игры словами игрока — одно на плитку, полосу «Продолжить» и страницу игры.
///
/// ★★★ РЕДИЗАЙН 23.09.2026 (владелец: «главное простота, чтобы человек сразу знал,
///   куда нажать»). Раньше плитка говорила «READY», «Local • 1 m 1 s», а карточка —
///   «STATUS / LAST RUN / GRAPHICS» и «DirectX 11 · 64-bit · Experimental». Это язык
///   движка, а не игрока. Теперь состояние — одна короткая фраза, и она одинакова везде.
struct GameStatus {
    enum Tone { case neutral, running, good, warning }

    let text: String
    let tone: Tone

    func color(_ scheme: ColorScheme) -> Color {
        switch tone {
        case .neutral: return Theme.Palette.textSecondary(scheme)
        case .running: return Theme.Palette.textPrimary(scheme)
        case .good: return Color(red: 0.30, green: 0.72, blue: 0.45)
        case .warning: return Color(red: 0.93, green: 0.62, blue: 0.24)
        }
    }

    static func of(_ app: AppEntry, isRunning: Bool, progress: LaunchProgress?, fileMissing: Bool = false) -> GameStatus {
        if fileMissing { return GameStatus(text: L("File is gone"), tone: .warning) }
        if isRunning { return GameStatus(text: progress?.phase.title ?? L("Starting process"), tone: .running) }
        if RunFailure.isFailure(status: app.lastRunStatus), let headline = RunFailure.headline(status: app.lastRunStatus) {
            return GameStatus(text: headline, tone: .warning)
        }
        if app.lastRunStatus != nil {
            return GameStatus(text: String(format: L("Played %@"), relative(app.updatedAt)), tone: .neutral)
        }
        return GameStatus(text: L("Not played yet"), tone: .neutral)
    }

    /// «2 часа назад», «вчера» — на языке приложения, а не системы.
    static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.locale = Locale(identifier: Localization.shared.language.localeCode)
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    /// Последняя запись проверки, включая «не перепроверено» в новом выпуске.
    static func confirmed(_ app: AppEntry) -> GraphicsProfile.KnownResult? {
        GraphicsProfile.match(exe: URL(fileURLWithPath: app.exePath), in: GraphicsProfile.bundled)?
            .known?.last
    }
}

/// Что сказать человеку перед удалением — для ЛЮБОГО места, откуда удаляют.
///
/// ★★★ ОБЕЩАНИЕ ОКНА ОБЯЗАНО СОВПАДАТЬ С ТЕМ, ЧТО СЛУЧИТСЯ. Три исхода — три текста:
///   деинсталлятор игры, папка в Корзину, только запись в библиотеке.
enum RemovalText {
    static func title(_ plan: RemovalPlan, name: String) -> String {
        switch plan {
        case .runUninstaller: return String(format: L("Uninstall “%@”?"), name)
        case .trashFolder: return String(format: L("Delete “%@” and its files?"), name)
        case .libraryOnly: return String(format: L("Remove “%@” from the library?"), name)
        }
    }

    static func action(_ plan: RemovalPlan) -> String {
        switch plan {
        case .runUninstaller: return L("Uninstall")
        case .trashFolder: return L("Move to Trash")
        case .libraryOnly: return L("Remove")
        }
    }

    static func message(_ plan: RemovalPlan) -> String {
        switch plan {
        case .runUninstaller:
            return L("We will start the game’s own uninstaller. Follow its steps — it removes the files and the registry entries it made.")
        case .trashFolder(let folder):
            return String(format: L("The game folder goes to the Trash, so you can put it back: %@"), folder)
        case .libraryOnly(.outsideOurFolders):
            return L("The files stay where they are — MacRunner did not install this game, so it will not delete it.")
        case .libraryOnly(.fileMissing):
            return L("The file is already gone from disk. Only the library entry is left to remove.")
        }
    }
}

/// Главная кнопка «Играть» / «Стоп»: крупная, одна на экран, с понятным текстом.
struct PlayButton: View {
    @Environment(\.colorScheme) private var scheme
    let isRunning: Bool
    var large = false
    let action: () -> Void
    /// ★ Владелец, 25.09.2026 (новый вид): главная кнопка откликается на курсор — чуть растёт
    ///   и светится, чтобы было видно, что на неё можно нажать.
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: large ? 9 : 8) {
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: large ? 13 : 11, weight: .bold))
                Text(isRunning ? L("Stop") : L("Play"))
                    .font(.system(size: large ? 15 : 13, weight: .semibold))
            }
            .foregroundColor(Theme.Palette.onEmphasis(scheme))
            .padding(.vertical, large ? 13 : 8)
            .padding(.horizontal, large ? 26 : 18)
            .background(Capsule().fill(Theme.Palette.emphasis(scheme)))
            .contentShape(Capsule())
            .shadow(color: Theme.Palette.emphasis(scheme).opacity(hovering ? 0.28 : 0), radius: hovering ? 22 : 0, y: hovering ? 8 : 0)
            .scaleEffect(hovering ? 1.045 : 1)
        }
        .buttonStyle(.scalePress)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.35, dampingFraction: 0.6), value: hovering)
    }
}
