import SwiftUI
import AppKit

/// Ответы на простые вопросы — то, что человек спрашивает в первые пять минут.
///
/// ★★★ ПРАВИЛО ЭТОГО ОКНА: ни одного обещания, которого мы не держим. Соблазн
///   написать «работают все игры» велик, но человек проверит это за час и больше
///   не поверит ничему. Поэтому здесь ровно то, что есть сегодня, включая то,
///   что НЕ работает.
struct HelpSheet: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    let onClose: () -> Void

    /// Один на всё приложение; меняется здесь одной строкой.
    /// ★ Домен — `macrunner.app` (задание 15.09.2026). До этого здесь стоял `macrunner.dev`,
    ///   и туда же вели «Сайт» в боковой панели и кнопка покупки.
    static let siteURL = "https://macrunner.app"
    /// Исходный код приложения (владелец, 23.09.2026). Тоже одна строка на всё приложение:
    /// настройки, «Помощь», меню Help и окно «О программе» берут адрес отсюда.
    static let sourceURL = "https://github.com/t0b1kent/macrunner-app"
    /// Как поддержать проект (владелец, 23.09.2026: «ссылкой на страницу на сайте»).
    /// Адреса кошельков живут на странице, а не в приложении: сменился кошелёк —
    /// правится страница, и старые версии приложения не показывают устаревший адрес.
    static let supportURL = "https://macrunner.app/support/"

    static func open(_ address: String) {
        if let url = URL(string: address) { NSWorkspace.shared.open(url) }
    }

    /// ★ Новый вид (25.09.2026) — как у настроек: стекло, крупный заголовок, ответы карточками.
    var body: some View {
        VStack(spacing: 0) {
            header

            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Self.questions, id: \.q) { item in
                        entry(question: L(item.q), answer: L(item.a))
                    }
                    // Честная матрица графики — после простых ответов: она для тех, кому
                    // интересно, почему конкретная игра пока не идёт.
                    if let engine = BundledEngine.current {
                        GraphicsSupportView(engine: engine)
                    }
                }
                .padding(.horizontal, 24)
                .padding(.top, 6)
                .padding(.bottom, 18)
            }
            .scrollIndicators(.never)
            // Ответы растворяются у краёв прокрутки, а не срезаются линией.
            .mask(LinearGradient(stops: [.init(color: .clear, location: 0),
                                         .init(color: .black, location: 0.03),
                                         .init(color: .black, location: 0.93),
                                         .init(color: .clear, location: 1)],
                                 startPoint: .top, endPoint: .bottom))

            footer
        }
        .frame(width: 600, height: 600)
        .background(SheetBackdrop())
        .presentationBackground(.clear)
        // ★★★ ВЫДЕЛЕНИЕ СТАВИМ НА КАЖДОМ ЛИСТЕ ОТДЕЛЬНО, А НЕ ТОЛЬКО В КОРНЕ.
        //   Измерено 12.09.2026: модификатор в корне `ContentView` в листы
        //   (`.sheet`) НЕ ПРОНИКАЕТ — лист поднимается в своём окне, и текст
        //   в нём остаётся невыделяемым. Сборка при этом была свежая, символы
        //   в двоичном на месте: сломан был не код, а моё допущение о наследовании.
        .textSelection(.enabled)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            SettingsIcon(symbol: "questionmark", shade: 0.95, side: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Questions and answers"))
                    .font(.system(size: 30, weight: .regular, design: .serif))
                    .kerning(-0.3)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                Text("MacRunner \(appVersion)")
                    .font(.system(size: 12))
                    .foregroundColor(Theme.Palette.textTertiary(scheme))
            }
            Spacer()
            SheetCloseButton(action: onClose)
        }
        .padding(.horizontal, 28)
        .padding(.top, 26)
        .padding(.bottom, 18)
    }

    private var footer: some View {
        HStack(spacing: Theme.Spacing.s) {
            Spacer()
            Button {
                if let url = URL(string: Self.siteURL) { NSWorkspace.shared.open(url) }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "globe").font(.system(size: 11, weight: .medium))
                    Text(L("Open the site"))
                }
            }
            .buttonStyle(.glassCapsule(height: 34))
            GitHubButton(height: 34)
            Button(L("Done"), action: onClose)
                .buttonStyle(.primaryCapsule)
                .keyboardShortcut(.return, modifiers: [])
                .padding(.leading, 4)
        }
        .padding(.horizontal, 24)
        .padding(.top, 16)
        .padding(.bottom, 22)
    }

    private func entry(question: String, answer: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(question)
                .font(.system(size: 14, weight: .semibold))
                .foregroundColor(Theme.Palette.textPrimary(scheme))
            Text(answer)
                .font(.system(size: 13))
                .foregroundColor(Theme.Palette.textSecondary(scheme))
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .fill(Color.white.opacity(scheme == .dark ? 0.055 : 0.6)))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
            .strokeBorder(Color.white.opacity(scheme == .dark ? 0.09 : 0.7), lineWidth: 0.75))
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }

    /// Ключи переводятся как обычно через `L`, поэтому лежат отдельным списком.
    private static let questions: [(q: String, a: String)] = [
        ("Do I need Rosetta?",
         "No. The bundled engine translates Intel programs without Rosetta."),
        ("How do I add a game?",
         "Press “Add game” and pick the .exe — the installer or the game itself. We work out which it is."),
        ("Which games work?",
         "Compatibility varies by game. The graphics support above describes this release, but does not guarantee that every game will run."),
        ("Why don’t games with anti-cheat run?",
         "Their protection needs a Windows kernel driver, and macOS has no place to load one. This is not something we can work around."),
        ("Where do games get installed?",
         "Games can be stored in MacRunner’s folders or added from elsewhere. Deleting a game in MacRunner’s folders runs its uninstaller or moves its folder to Trash. Files elsewhere are left in place."),
        ("A game does not start — what now?",
         "Tell us the name through the site. A failure with a name attached is what turns into a fix; a failure without one disappears."),
        // ★ Ответ берётся из `EngineCapabilities`: заработают 32 бита — текст
        //   поменяется сам, а не останется враньём в окне «Вопросы».
        ("Do 32-bit games work?",
         EngineCapabilities.i386Supported
            ? "Yes. Both 32-bit and 64-bit Windows programs run."
            : "Not in this release. The bundled engine supports 64-bit Windows programs; compatibility varies by game."),
        // ★ Ранний доступ бесплатный (решение владельца, 15.09.2026, см. `ReleaseFlags`).
        //   Ключ НОВЫЙ, а не переписанный платный: у старого ключа был смысл «платно»,
        //   и перевод, отставший от смены смысла, врал бы на одиннадцати языках.
        ("Is it free?",
         "Yes. MacRunner is free during early access.")
    ]
}

/// Кнопка «GitHub» — рядом с сайтом в настройках и в «Помощи». Название площадки
/// не переводится; что за ней, говорит подсказка.
struct GitHubButton: View {
    @ObservedObject private var loc = Localization.shared
    /// Высота стеклянной капсулы: в строке настроек ниже, в подвале «Помощи» — как соседние кнопки.
    var height: CGFloat = 30

    var body: some View {
        Button { HelpSheet.open(HelpSheet.sourceURL) } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left.forwardslash.chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                Text("GitHub")
            }
        }
        .buttonStyle(.glassCapsule(height: height))
        .lineLimit(1)
        .fixedSize()
        .help(L("Source code on GitHub"))
        .accessibilityLabel(L("Source code on GitHub"))
    }
}
