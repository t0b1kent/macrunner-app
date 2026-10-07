import AppKit
import SwiftUI

/// Настройки игрока — только то, что человеку может понадобиться.
///
/// ★★★ РЕДИЗАЙН 23.09.2026. Язык переехал сюда из шапки (глобус «Auto» рядом с «Добавить
///   игру» читался загадкой). Путей репозитория, лимитов времени и журналов отладки здесь
///   нет: это настройки разработчика, игроку они не нужны. Зато есть то, что нужно:
///   обновления, папка с установленными играми и сохранениями (диск C:) и журналы
///   запусков — их просит поддержка, когда что-то не работает.
struct MinimalSettingsSheet: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    @EnvironmentObject var settingsVM: SettingsViewModel
    @AppStorage(PerformanceHUD.defaultsKey) private var metalHUD = false
    @AppStorage(GameKeyboardLayout.defaultsKey) private var asciiKeyboard = true
    let onClose: () -> Void

    /// ★ Новый вид (владелец, 25.09.2026: «тут тоже сделай красивее, современно»). Лист — матовое
    ///   стекло над окном; строки собраны в группы с цветными значками, как в «Системных
    ///   настройках» macOS; кнопки — стеклянные капсулы, «Готово» — светлая, как «Играть».
    var body: some View {
        VStack(spacing: 0) {
            header
            VStack(spacing: 14) {
                SettingsGroup {
                    SettingsRow(icon: "globe", shade: 0.95, title: L("Language")) {
                        LanguagePicker()
                    }
                    SettingsDivider()
                    SettingsRow(icon: "arrow.down", shade: 0.78, title: L("Updates")) {
                        Button(L("Check for Updates…")) { SparkleBootstrap.checkForUpdates() }
                            .buttonStyle(.glassCapsule(height: 30))
                            .lineLimit(1)
                            .fixedSize()
                            .disabled(!SparkleBootstrap.isConfigured)
                    }
                }
                if BundledEngine.current != nil {
                    SettingsGroup {
                        SettingsRow(icon: "speedometer", shade: 0.6, title: L("FPS counter"),
                                    subtitle: L("Apple’s Metal HUD over the game: FPS and frame time. Takes effect the next time a game starts.")) {
                            Toggle("", isOn: $metalHUD)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .accessibilityLabel(L("FPS counter"))
                        }
                        SettingsDivider()
                        SettingsRow(icon: "keyboard", shade: 0.5, title: L("Latin keyboard during games"),
                                    subtitle: L("Use a Latin layout while the game runs, then restore your previous input source.")) {
                            Toggle("", isOn: $asciiKeyboard)
                                .toggleStyle(.switch)
                                .labelsHidden()
                                .accessibilityLabel(L("Latin keyboard during games"))
                        }
                        SettingsDivider()
                        SettingsRow(icon: "internaldrive", shade: 0.4, title: L("Windows environment")) {
                            // Две кнопки в строку, а на длинных языках (немецкий, французский) —
                            // одна под другой: текст на кнопке не должен переноситься.
                            ViewThatFits(in: .horizontal) {
                                HStack(spacing: Theme.Spacing.s) { windowsButtons }
                                VStack(alignment: .trailing, spacing: Theme.Spacing.s) { windowsButtons }
                            }
                        }
                    }
                }
                SettingsGroup {
                    // Поддержка добровольная и ничего не открывает — поэтому это ссылка на
                    // страницу «как помочь», а не кнопка оплаты.
                    SettingsRow(icon: "heart.fill", shade: 0.24, title: L("Support the project")) {
                        Button(L("How to help")) { HelpSheet.open(HelpSheet.supportURL) }
                            .buttonStyle(.glassCapsule(height: 30))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    SettingsDivider()
                    SettingsRow(icon: "info", shade: 0.12, title: L("About")) {
                        // Сайт и исходный код — в строку, на длинных языках одна под другой.
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: Theme.Spacing.s) { aboutButtons }
                            VStack(alignment: .trailing, spacing: Theme.Spacing.s) { aboutButtons }
                        }
                    }
                }
            }
            .padding(.horizontal, 24)
            footer
        }
        .frame(width: 620)
        .background(SheetBackdrop())
        .presentationBackground(.clear)
        .textSelection(.enabled)
    }

    @ViewBuilder
    private var aboutButtons: some View {
        Button(L("Open the site")) { HelpSheet.open(HelpSheet.siteURL) }
            .buttonStyle(.glassCapsule(height: 30))
            .lineLimit(1)
            .fixedSize()
        GitHubButton()
    }

    @ViewBuilder
    private var windowsButtons: some View {
        Button(L("Open drive C:")) { open(EnginePaths.defaultBottle.appendingPathComponent("drive_c")) }
            .buttonStyle(.glassCapsule(height: 30))
            .lineLimit(1)
            .fixedSize()
        Button(L("Open logs folder")) { open(EnginePaths.runs) }
            .buttonStyle(.glassCapsule(height: 30))
            .lineLimit(1)
            .fixedSize()
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            BrandMark(size: 44)
            VStack(alignment: .leading, spacing: 2) {
                Text(L("Settings"))
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
        .padding(.bottom, 20)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L("Done"), action: onClose)
                .buttonStyle(.primaryCapsule)
                .keyboardShortcut(.return, modifiers: [])
        }
        .padding(.horizontal, 24)
        .padding(.top, 20)
        .padding(.bottom, 22)
    }

    /// Открыть папку; если её ещё нет (игр не ставили, не запускали) — ближайшую
    /// существующую. Создавать здесь ничего нельзя: бутылку создаёт первый запуск.
    private func open(_ url: URL) {
        var target = url
        while !FileManager.default.fileExists(atPath: target.path), target.pathComponents.count > 1 {
            target.deleteLastPathComponent()
        }
        NSWorkspace.shared.open(target)
    }

    private var appVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev"
    }
}
