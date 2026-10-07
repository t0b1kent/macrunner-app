import SwiftUI
import AppKit

@main
struct MacRunnerControlCenterApp: App {
    @NSApplicationDelegateAdaptor(UpdateApplicationDelegate.self) private var updateDelegate
    init() {
        AppPathCLI.handleIfNeeded()
        _ = ControlCenterCLI.handleIfNeeded()
        SparkleBootstrap.startIfAvailable()
    }

    var body: some Scene {
        // ★ Заголовок окна задан ЯВНО. Без него окно брало имя исполняемого файла
        //   и показывало игроку служебное «MacRunnerControlCenter».
        WindowGroup("MacRunner") {
            ContentView()
                .frame(minWidth: 1024, minHeight: 700)
        }
        .windowResizability(.contentSize)
        // ★ Новый вид (25.09.2026): без полосы заголовка — стекло боковой панели и фон из игры идут
        //   до верхнего края, кнопки окна стоят прямо на стекле (место под них оставлено в `HomeSidebar`).
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 800)
        .commands { MacRunnerCommands() }
    }
}

/// Меню приложения: «О программе», проверка обновлений, справка.
///
/// ★ Подписка на `Localization` здесь нужна так же, как в видах: язык меняется
///   на ходу, и без неё пункты меню остались бы на языке запуска.
struct MacRunnerCommands: Commands {
    @ObservedObject private var loc = Localization.shared

    var body: some Commands {
        CommandGroup(replacing: .appInfo) {
            Button(L("About MacRunner")) { Self.showAbout() }
        }

        CommandGroup(after: .appInfo) {
            // ★ Без адреса ленты (`SUFeedURL`) пункт ПОГАШЕН, а не скрыт: человек
            //   видит, что обновления существуют, но в этой сборке не настроены.
            Button(L("Check for Updates…")) { SparkleBootstrap.checkForUpdates() }
                .disabled(!SparkleBootstrap.isConfigured)
        }

        CommandGroup(replacing: .help) {
            Button(L("MacRunner Help")) { HelpSheet.open(HelpSheet.siteURL) }
            Button(L("Source code on GitHub")) { HelpSheet.open(HelpSheet.sourceURL) }
            Button(L("Support the project")) { HelpSheet.open(HelpSheet.supportURL) }
        }
    }

    /// Стандартное окно «О программе», но с НАШИМ именем: без подстановки AppKit
    /// взял бы имя процесса, а при запуске не из бандла это «MacRunnerControlCenter».
    @MainActor
    static func showAbout() {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "dev"
        let build = info?["CFBundleVersion"] as? String ?? ""
        var options: [NSApplication.AboutPanelOptionKey: Any] = [
            .applicationName: "MacRunner",
            .applicationVersion: version,
            // Ключ «Copyright» у AppKit есть, но константой в Swift не выведен.
            NSApplication.AboutPanelOptionKey(rawValue: "Copyright"): "© 2026 Ravilov Timur"
        ]
        if !build.isEmpty { options[.version] = build }
        options[.credits] = aboutLinks()
        NSApplication.shared.activate(ignoringOtherApps: true)
        NSApplication.shared.orderFrontStandardAboutPanel(options: options)
    }

    /// Сайт и исходный код — ссылками под версией в окне «О программе».
    @MainActor
    private static func aboutLinks() -> NSAttributedString {
        let centered = NSMutableParagraphStyle()
        centered.alignment = .center
        let base: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
            .foregroundColor: NSColor.secondaryLabelColor,
            .paragraphStyle: centered
        ]
        let text = NSMutableAttributedString()
        func link(_ title: String, _ address: String) {
            var attributes = base
            attributes[.link] = URL(string: address)
            text.append(NSAttributedString(string: title, attributes: attributes))
        }
        link("macrunner.app", HelpSheet.siteURL)
        text.append(NSAttributedString(string: "  ·  ", attributes: base))
        link("GitHub", HelpSheet.sourceURL)
        return text
    }
}
