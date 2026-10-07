import SwiftUI

/// Переключатель языка — в настройках.
///
/// ★ РЕДИЗАЙН 23.09.2026: переехал из шапки в настройки, поэтому показывает ПОЛНОЕ
///   название («🇷🇺 Русский», «Язык системы»), а не значок. Прежняя подпись на
///   `borderlessButton` теряла текст и оставляла один флаг — системный выпадающий
///   список рисует подпись целиком.
struct LanguagePicker: View {
    @ObservedObject private var loc = Localization.shared

    var body: some View {
        Picker("", selection: $loc.language) {
            ForEach(AppLanguage.allCases) { lang in
                Text(lang.flag.map { "\($0)  \(lang.nativeName)" } ?? lang.nativeName).tag(lang)
            }
        }
        .labelsHidden()
        .pickerStyle(.menu)
        .fixedSize()
        .help(L("Interface language"))
    }
}
