import SwiftUI
import AppKit

/// Разделы витрины игрока.
///
/// ★★★ ОН ОДИН, И ЭТО НАМЕРЕННО (решение владельца, 12.09.2026).
///   Было пять строк плюс список магазинов — и каждая требовала решения до
///   того, как человек вообще что-то запустил. Разобрали по одной:
///
///     «Добавить игру»  — ДЕЙСТВИЕ, ему место на кнопке, а не в меню
///     «Загрузки»       — показывать нечего, пока ничего не качается
///     «Программы»      — витрина не про них
///     магазины         — обещали вход, за которым пока ничего нет
///     «Настройки»      — язык в шапке, движок настроен, менять нечего
///
///   Остались библиотека и два выхода наружу: сайт и ответы на вопросы.
///
/// ★★★ РЕДИЗАЙН 23.09.2026. Бесплатные игры переехали из вкладки внутри библиотеки
///   в свой раздел: библиотека — это ТВОИ игры, а каталог — что можно взять.
///   Настройки вернулись — в них язык, обновления и папки.
///
/// ★ «Программы» (Microsoft 365, AutoCAD…) я при редизайне убрал сам — и зря: владелец
///   спросил, куда делся раздел (23.09.2026). Вернул отдельной строкой, как «Бесплатные игры».
enum HomeSection: String, CaseIterable, Identifiable {
    case library
    case discover
    case programs
    /// ★ Раздел с постоянным состоянием, в отличие от убранных: у лицензии есть
    ///   что показывать всегда — тариф, привязанное устройство, срок.
    case licence

    var id: String { rawValue }

    /// Разделы, которые игрок ВИДИТ. `allCases` не годится: «Лицензия» живёт в коде,
    /// но пока лицензирование выключено (`ReleaseFlags`), показывать её нечего.
    static var visible: [HomeSection] {
        allCases.filter { $0 != .licence || ReleaseFlags.licensingEnabled }
    }

    var title: String {
        switch self {
        case .library: return L("Library")
        case .discover: return L("Free games")
        case .programs: return L("Programs")
        case .licence: return L("Licence")
        }
    }

    var icon: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .discover: return "sparkles"
        case .programs: return "macwindow"
        case .licence: return "key"
        }
    }
}

struct HomeSidebar: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    @Binding var section: HomeSection
    var libraryCount: Int
    /// Сколько всего в каталогах — справа от раздела, как в боковых панелях macOS.
    var freeCount: Int = 0
    var programCount: Int = 0
    /// ★ Настроек у игрока больше НЕТ (решение владельца, 12.09.2026): язык
    ///   выбирается в шапке, а движок настроен и менять в нём нечего. Осталось
    ///   ровно два внешних действия — сайт и ответы на вопросы.
    var onSettings: () -> Void
    var onHelp: () -> Void

    /// ★ Владелец, 25.09.2026: «на Settings наводишь — непонятно, навёл или нет». Строка под курсором
    ///   подсвечивается плашкой и становится ярче; выделение раздела плавно переезжает между пунктами.
    @Namespace private var selectionSpace
    @State private var hovered: String?

    /// ★★★ НОВЫЙ ВИД 25.09.2026: панель — матовое стекло во всю высоту окна, как у Музыки и Finder.
    ///   Заголовка окна нет (`hiddenTitleBar`), кнопки окна стоят прямо на стекле — сверху для них
    ///   оставлено место. Сквозь стекло просвечивает фон из игры.
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                BrandMark(size: 28)
                Text("MacRunner")
                    .font(.system(size: 15.5, weight: .semibold))
                    .kerning(-0.2)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
            }
            .padding(.horizontal, 10)
            .padding(.top, 50)

            VStack(spacing: 4) {
                ForEach(HomeSection.visible) { item in
                    sectionRow(item)
                }
            }
            .padding(.top, 26)

            Spacer(minLength: 0)

            VStack(spacing: 2) {
                footerRow(icon: "gearshape", title: L("Settings"), action: onSettings)
                footerRow(icon: "questionmark.circle", title: L("Help"), action: onHelp)
            }
            .padding(.bottom, Theme.Spacing.l)
        }
        .padding(.horizontal, Theme.Spacing.m)
        .frame(width: 232)
        .frame(maxHeight: .infinity)
        .background(.ultraThinMaterial)
        .overlay(alignment: .trailing) {
            Rectangle().fill(Color.white.opacity(scheme == .dark ? 0.07 : 0.4)).frame(width: 0.75)
        }
    }

    /// Нижние строки — не разделы витрины, а выход наружу, поэтому они тише:
    /// никогда не подсвечиваются и набраны мельче.
    private func footerRow(icon: String, title: String, action: @escaping () -> Void) -> some View {
        let key = "footer." + icon, over = hovered == key
        return Button(action: action) {
            HStack(spacing: 11) {
                Image(systemName: icon)
                    .font(.system(size: 13, weight: .medium))
                    .frame(width: 18)
                    .rotationEffect(.degrees(over && icon == "gearshape" ? 60 : 0))   // шестерёнка чуть поворачивается
                    .scaleEffect(over ? 1.12 : 1)
                Text(title)
                    .font(.system(size: 13, weight: .medium))
                Spacer(minLength: 0)
            }
            .foregroundColor(over ? Theme.Palette.textPrimary(scheme) : Theme.Palette.textSecondary(scheme))
            .padding(.vertical, 8)
            .padding(.horizontal, 11)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(over ? 0.07 : 0))
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? key : (hovered == key ? nil : hovered) }
        .animation(Theme.Motion.gentle, value: over)
    }

    private func count(for item: HomeSection) -> Int {
        switch item {
        case .library: return libraryCount
        case .discover: return freeCount
        case .programs: return programCount
        case .licence: return 0
        }
    }

    private func sectionRow(_ item: HomeSection) -> some View {
        let active = section == item
        let key = "section." + String(describing: item), over = hovered == key
        let number = count(for: item)
        return Button {
            withAnimation(.spring(response: 0.5, dampingFraction: 0.78)) { section = item }
        } label: {
            HStack(spacing: 12) {
                Image(systemName: item.icon)
                    .font(.system(size: 13.5, weight: .medium))
                    .frame(width: 18)
                    .scaleEffect(over && !active ? 1.12 : 1)
                Text(item.title)
                    .font(.system(size: 14, weight: active ? .semibold : .medium))
                    .lineLimit(1)
                Spacer(minLength: 0)
                if number > 0 {
                    Text("\(number)")
                        .font(.system(size: 11.5, weight: .medium))
                        .monospacedDigit()
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                }
            }
            .foregroundColor(active || over ? Theme.Palette.textPrimary(scheme) : Theme.Palette.textSecondary(scheme))
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background {
                ZStack {
                    // Подсветка под курсором — мягче, чем выделение раздела.
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(Color.white.opacity(over && !active ? 0.06 : 0))
                    if active {
                        // Выделение раздела — стеклянная плашка; при смене раздела переезжает пружинкой.
                        RoundedRectangle(cornerRadius: 11, style: .continuous)
                            .fill(Color.white.opacity(scheme == .dark ? 0.13 : 0.6))
                            .overlay(RoundedRectangle(cornerRadius: 11, style: .continuous)
                                .strokeBorder(Color.white.opacity(scheme == .dark ? 0.1 : 0.7), lineWidth: 0.75))
                            .shadow(color: .black.opacity(scheme == .dark ? 0.25 : 0.08), radius: 10, y: 5)
                            .matchedGeometryEffect(id: "selection", in: selectionSpace)
                    }
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in hovered = inside ? key : (hovered == key ? nil : hovered) }
        .animation(Theme.Motion.gentle, value: over)
    }
}
