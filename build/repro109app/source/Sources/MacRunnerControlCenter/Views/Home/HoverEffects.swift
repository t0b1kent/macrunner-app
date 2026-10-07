import SwiftUI

/// Объём при наведении — один на все карточки (владелец, 25.09.2026: «3D красоты, прикольчики при наведении,
/// и в бесплатных играх, и в программах; непонятно, навёл или нет»).
///
/// Карточка наклоняется за курсором, как стекло в руке: сторона под курсором уходит вглубь (знаки проверены
/// отрисовкой через ImageRenderer). По поверхности за курсором скользит свет — он ДОБАВЛЯЕТСЯ к картинке
/// (`plusLighter`), а не закрашивает её. Карточка приподнимается, под ней появляется тень.
struct TiltHover: ViewModifier {
    var cornerRadius: CGFloat = Theme.Radius.large
    var maxTiltX: Double = 7
    var maxTiltY: Double = 9
    var lift: CGFloat = 4

    @State private var size: CGSize = .zero
    @State private var tilt: CGSize = .zero
    @State private var pointer = UnitPoint(x: 0.5, y: 0.3)
    @State private var hovering = false

    func body(content: Content) -> some View {
        content
            .overlay {
                RadialGradient(colors: [.white.opacity(0.16), .white.opacity(0.05), .white.opacity(0)],
                               center: pointer, startRadius: 0, endRadius: max(size.width, 120) * 0.95)
                    .blendMode(.plusLighter)
                    .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                    .opacity(hovering ? 1 : 0)
                    .allowsHitTesting(false)
            }
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { size = g.size }
                    .onChange(of: g.size) { _, s in size = s }
            })
            .shadow(color: .black.opacity(hovering ? 0.45 : 0), radius: hovering ? 20 : 0, y: hovering ? 12 : 0)
            .rotation3DEffect(.degrees(Double(-tilt.height) * maxTiltX), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
            .rotation3DEffect(.degrees(Double(tilt.width) * maxTiltY), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
            .offset(y: hovering ? -lift : 0)
            .animation(Theme.Motion.gentle, value: hovering)
            .onContinuousHover(coordinateSpace: .local) { phase in
                switch phase {
                case .active(let at):
                    hovering = true
                    guard size.width > 0, size.height > 0 else { return }
                    let x = min(max(at.x / size.width, 0), 1), y = min(max(at.y / size.height, 0), 1)
                    pointer = UnitPoint(x: x, y: y)
                    withAnimation(.interpolatingSpring(stiffness: 170, damping: 20)) {
                        tilt = CGSize(width: x * 2 - 1, height: y * 2 - 1)
                    }
                case .ended:
                    hovering = false
                    withAnimation(.spring(response: 0.6, dampingFraction: 0.72)) { tilt = .zero }
                }
            }
    }
}

extension View {
    func tiltHover(cornerRadius: CGFloat = Theme.Radius.large, maxTiltX: Double = 7, maxTiltY: Double = 9, lift: CGFloat = 4) -> some View {
        modifier(TiltHover(cornerRadius: cornerRadius, maxTiltX: maxTiltX, maxTiltY: maxTiltY, lift: lift))
    }
}

/// Чип-переключатель с явным наведением: подложка светлеет, рамка ярче, чип чуть приподнимается.
struct HoverChip: View {
    @Environment(\.colorScheme) private var scheme
    let title: String
    let icon: String
    let active: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .medium))
                Text(title).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            .foregroundColor(active ? Theme.Palette.onEmphasis(scheme)
                             : (hovering ? Theme.Palette.textPrimary(scheme) : Theme.Palette.textSecondary(scheme)))
            .padding(.vertical, 7)
            .padding(.horizontal, 12)
            // ★ Новый вид (25.09.2026): неактивный чип — стекло над фоном из игры, активный — светлая капсула.
            .background(
                ZStack {
                    if active {
                        Capsule().fill(Theme.Palette.emphasis(scheme))
                    } else {
                        Capsule().fill(.ultraThinMaterial)
                        Capsule().fill(Color.white.opacity(hovering ? 0.1 : 0.03))
                    }
                }
            )
            .overlay(
                Capsule().stroke(active ? .clear : Color.white.opacity(hovering ? 0.26 : (scheme == .dark ? 0.1 : 0.5)),
                                 lineWidth: hovering && !active ? 1 : 0.75)
            )
            .offset(y: hovering && !active ? -1.5 : 0)
            .fixedSize(horizontal: true, vertical: false)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(Theme.Motion.gentle, value: hovering)
        .animation(Theme.Motion.gentle, value: active)
    }
}
