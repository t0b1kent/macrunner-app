import SwiftUI

/// Значок магазина: фирменная плитка и официальный контур знака.
///
/// Контуры берутся из `StoreBrandPaths` — они сгенерированы из Simple Icons (CC0),
/// то есть это настоящие формы знаков, а не мои перерисовки «по памяти о форме».
/// Прежние самодельные глифы на 22 пикселях превращались в грязь: двухстрочное
/// «gog/com» и буква «a» со стрелкой были нечитаемы.
///
/// ★ У Amazon официального контура нет: владелец знака попросил Simple Icons его
///   удалить. Поэтому для него остаётся своя стрелка-улыбка — узнаваемая часть
///   знака, нарисованная нами, а не копия чужого вектора.
struct StoreBadge: View {
    let store: GameStore

    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height)
            ZStack {
                tile(side: side)
                glyph(side: side)
            }
            .frame(width: side, height: side)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityLabel(store.title)
    }

    // MARK: - Плитка

    @ViewBuilder
    private func tile(side: CGFloat) -> some View {
        switch store {
        case .gog:
            // У GOG знак живёт на белом круге — так он и выглядит у них самих.
            Circle()
                .fill(.white)
                .overlay(Circle().strokeBorder(borderColor, lineWidth: 1))
        default:
            RoundedRectangle(cornerRadius: side * 0.23, style: .continuous)
                .fill(tileColor)
                .overlay(
                    RoundedRectangle(cornerRadius: side * 0.23, style: .continuous)
                        .strokeBorder(borderColor, lineWidth: 1)
                )
        }
    }

    /// Обводка одна на все значки и живёт в `Theme`. Здесь выбора нет намеренно:
    /// как только он появился, половина ряда осталась без видимой границы.
    private var borderColor: Color { Theme.Palette.glyphTileBorder }

    private func glyph(side: CGFloat) -> some View {
        StoreGlyphShape(store: store)
            .fill(glyphColor)
            .frame(width: side * glyphScale, height: side * glyphScale)
    }

    // MARK: - Цвета

    /// Доля плитки, которую занимает знак. Контуры Simple Icons заполняют сетку
    /// 24×24 от края до края, поэтому поля задаём здесь, иначе знак упрётся в углы.
    private var glyphScale: CGFloat {
        store == .gog ? 0.64 : 0.58
    }

    private var tileColor: Color {
        switch store {
        case .epic: return Color(red: 0.06, green: 0.06, blue: 0.07)
        case .steam: return Color(red: 0.09, green: 0.10, blue: 0.13)
        case .battlenet: return Color(red: 0.04, green: 0.09, blue: 0.18)
        case .itch: return Color(red: 0.98, green: 0.36, blue: 0.36)
        case .gog: return .white
        }
    }

    private var glyphColor: Color {
        switch store {
        case .gog: return Color(red: 0.53, green: 0.20, blue: 0.54)
        // Battle.net узнаётся по своему синему; белый завиток на тёмном читался бы
        // как что угодно.
        case .battlenet: return Color(red: 0.0, green: 0.68, blue: 1.0)
        default: return .white
        }
    }

}

#Preview {
    HStack(spacing: 14) {
        ForEach(GameStore.allCases) { store in
            StoreBadge(store: store).frame(width: 30, height: 30)
        }
    }
    .padding(24)
    .background(Color.black)
}
