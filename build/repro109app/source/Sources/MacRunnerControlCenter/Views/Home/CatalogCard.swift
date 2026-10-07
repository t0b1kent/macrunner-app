import SwiftUI

/// Карточка витрины — одна на бесплатные игры и программы.
///
/// ★ РЕДИЗАЙН 23.09.2026 (владелец: «программы переделай в тот же стиль»). Сверху
///   картинка во всю ширину, поверх неё плашка, ниже название и две строки описания.
///   Одна карточка на обе витрины — чтобы они не разъехались при следующей правке.
struct CatalogCard<Art: View, Badge: View>: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let subtitle: String
    let artAspect: CGFloat
    /// Серая карточка — то, что сегодня не запустится (32-битные игры).
    var dimmed = false
    /// Фон окна, пока карточка под курсором: обложка игры или сияние цвета значка.
    var backdrop: BackdropSource? = nil
    let onOpen: () -> Void
    @ViewBuilder let art: () -> Art
    @ViewBuilder let badge: () -> Badge

    @State private var hovering = false
    private let shape = RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)

    var body: some View {
        Button(action: onOpen) {
            VStack(alignment: .leading, spacing: 0) {
                Color.clear
                    .aspectRatio(artAspect, contentMode: .fit)
                    .overlay { art().scaleEffect(hovering ? 1.06 : 1) }   // картинка плавно приближается
                    .clipped()
                    // ★ То, что сегодня не пойдёт, гасим — это видно раньше,
                    //   чем человек прочтёт подпись.
                    .saturation(dimmed ? 0 : 1)
                    .opacity(dimmed ? 0.5 : 1)
                    .overlay(alignment: .topLeading) { badge().padding(10) }

                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Theme.Palette.textPrimary(scheme))
                        .lineLimit(1)
                    Text(subtitle)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                        .lineLimit(2, reservesSpace: true)
                }
                .padding(Theme.Spacing.m)
            }
            // ★ Новый вид (25.09.2026): карточка — стекло над фоном из игры, а не серая плашка.
            .background(.ultraThinMaterial)
            .clipShape(shape)
            .overlay(shape.strokeBorder(Color.white.opacity(hovering ? 0.26 : (scheme == .dark ? 0.1 : 0.5)),
                                        lineWidth: hovering ? 1 : 0.75))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .tiltHover()                                   // объём: наклон за курсором, блик, подъём с тенью
        .onHover { hovering = $0 }
        .backdrop(backdrop, whileHovering: hovering)
        .animation(Theme.Motion.gentle, value: hovering)
        .accessibilityLabel(title)
    }
}

/// Сетка витрины: одна на обе, чтобы шаг карточек совпадал.
enum CatalogGrid {
    static let columns = [GridItem(.adaptive(minimum: 210, maximum: 300),
                                   spacing: Theme.Spacing.l, alignment: .top)]
}

/// Плашка поверх картинки. Тёмная подложка — чтобы читалась на любой обложке;
/// `inverted` — светлая, для главного ответа («есть родная версия для Mac»).
struct CatalogBadge: View {
    @Environment(\.colorScheme) private var scheme
    let text: String
    var icon: String? = nil
    var inverted = false

    var body: some View {
        HStack(spacing: 4) {
            if let icon {
                Image(systemName: icon).font(.system(size: 9.5, weight: .semibold))
            }
            Text(text).font(.system(size: 10.5, weight: .semibold))
        }
        .foregroundColor(inverted ? Theme.Palette.onEmphasis(scheme) : .white.opacity(0.95))
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(inverted ? Theme.Palette.emphasis(scheme) : Color.black.opacity(0.55)))
        .overlay(Capsule().strokeBorder(Color.white.opacity(inverted ? 0 : 0.18), lineWidth: 0.5))
        .fixedSize()
    }
}

/// Подложка без картинки: у каждой записи свой цвет, один и тот же между запусками.
enum CatalogArt {
    /// `hashValue` у строки свой в каждом запуске — цвет плясал бы. Нужен постоянный.
    static func hue(for id: String) -> Double {
        let hash = id.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0x7fff_ffff }
        return Double(hash % 360) / 360
    }

    static func gradient(for id: String, brightness: Double = 0.42) -> LinearGradient {
        let hue = hue(for: id)
        return LinearGradient(
            colors: [Color(hue: hue, saturation: 0.42, brightness: brightness),
                     Color(hue: (hue + 0.07).truncatingRemainder(dividingBy: 1), saturation: 0.5,
                           brightness: brightness * 0.43)],
            startPoint: .topLeading, endPoint: .bottomTrailing)
    }
}
