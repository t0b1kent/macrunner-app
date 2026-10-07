import SwiftUI

/// Стекло, глубина и появление — общие для всех экранов нового вида (владелец, 25.09.2026:
/// «минимализм в стиле macOS, 3D-переходы, чтобы глаз радовался»; прототип одобрен словами «да, переноси»).

// MARK: - Стекло

/// Матовое стекло поверх фона из игры: размывает то, что под ним, и держит тонкую светлую кромку.
struct GlassSurface<S: InsettableShape>: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    let shape: S
    var highlighted = false

    func body(content: Content) -> some View {
        content
            .background(.ultraThinMaterial, in: shape)
            .background(shape.fill(Color.white.opacity(highlighted ? 0.08 : 0)))
            .overlay(shape.strokeBorder(Color.white.opacity(scheme == .dark ? (highlighted ? 0.24 : 0.1) : 0.55),
                                        lineWidth: 0.75))
    }
}

extension View {
    func glass(cornerRadius: CGFloat = Theme.Radius.large, highlighted: Bool = false) -> some View {
        modifier(GlassSurface(shape: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous),
                              highlighted: highlighted))
    }

    func glassCapsule(highlighted: Bool = false) -> some View {
        modifier(GlassSurface(shape: Capsule(), highlighted: highlighted))
    }
}

/// Кнопка-стекло в форме капсулы: при наведении стекло светлеет, кромка ярче, кнопка чуть поднимается.
struct GlassCapsuleButtonStyle: ButtonStyle {
    var height: CGFloat = 44

    func makeBody(configuration: Configuration) -> some View {
        GlassCapsuleLabel(configuration: configuration, height: height)
    }
}

private struct GlassCapsuleLabel: View {
    @Environment(\.colorScheme) private var scheme
    let configuration: ButtonStyleConfiguration
    let height: CGFloat
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: height >= 40 ? 14 : 13, weight: .medium))
            .foregroundColor(Theme.Palette.textPrimary(scheme))
            .padding(.horizontal, height >= 40 ? 20 : 14)
            .frame(height: height)
            .glassCapsule(highlighted: hovering)
            .contentShape(Capsule())
            .offset(y: hovering ? -1 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(Theme.Motion.gentle, value: hovering)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == GlassCapsuleButtonStyle {
    static var glassCapsule: GlassCapsuleButtonStyle { GlassCapsuleButtonStyle() }
    static func glassCapsule(height: CGFloat) -> GlassCapsuleButtonStyle { GlassCapsuleButtonStyle(height: height) }
}

// MARK: - Глубина между экранами

/// Экраны стоят в пространстве друг за другом. Уходящий вглубь уменьшается и расплывается,
/// приходящий «спереди» опускается на место с лёгким наклоном — как карточка, положенная на стол.
struct DepthEffect: ViewModifier {
    /// −1 — позади, 0 — на месте, +1 — перед зрителем.
    let position: Double

    func body(content: Content) -> some View {
        content
            .scaleEffect(1 + position * 0.04)
            .rotation3DEffect(.degrees(max(position, 0) * 6), axis: (x: 1, y: 0, z: 0),
                              anchor: .bottom, perspective: 0.6)
            .offset(y: max(position, 0) * 44)
            .blur(radius: abs(position) * 10)
            .opacity(1 - abs(position))
    }
}

extension AnyTransition {
    /// `forward` — идём вглубь (библиотека → игра, библиотека → каталог): новое приходит спереди,
    /// старое отступает назад. Обратно — наоборот.
    static func depth(forward: Bool, reduceMotion: Bool) -> AnyTransition {
        guard !reduceMotion else { return .opacity }
        return .asymmetric(
            insertion: .modifier(active: DepthEffect(position: forward ? 1 : -1), identity: DepthEffect(position: 0)),
            removal: .modifier(active: DepthEffect(position: forward ? -1 : 1), identity: DepthEffect(position: 0)))
    }
}

// MARK: - Появление

/// Элемент выплывает снизу с задержкой — экран собирается по частям, а не вспыхивает целиком.
struct RevealOnAppear: ViewModifier {
    let delay: Double
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    func body(content: Content) -> some View {
        content
            .opacity(shown ? 1 : 0)
            .offset(y: shown || reduceMotion ? 0 : 16)
            .onAppear {
                withAnimation(.spring(response: 0.7, dampingFraction: 0.86).delay(reduceMotion ? 0 : delay)) { shown = true }
            }
    }
}

extension View {
    func reveal(_ delay: Double) -> some View { modifier(RevealOnAppear(delay: delay)) }
}

// MARK: - Обложка на сцене

/// Обложка игры в пространстве: стоит повёрнутой, как коробка на полке, с отражением «на полу»;
/// под курсором наклоняется за ним, по ней скользит свет. `entrance` — при появлении
/// разворачивается к зрителю из глубины (страница игры).
struct CoverStage: View {
    let app: AppEntry
    var width: CGFloat = 180
    /// Поворот в покое вокруг вертикали: минус — повёрнута вправо, плюс — влево.
    var restYaw: Double = -16
    var entrance = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var tilt: CGSize = .zero
    @State private var pointer = UnitPoint(x: 0.5, y: 0.3)
    @State private var hovering = false
    @State private var arrived = false

    private var height: CGFloat { width * 1.5 }
    private let radius: CGFloat = 16

    var body: some View {
        let yaw = (arrived || !entrance || reduceMotion ? restYaw : -34) + Double(tilt.width) * 10
        let pitch = 3 - Double(tilt.height) * 8
        let lift: CGFloat = hovering ? 1.03 : (arrived || !entrance || reduceMotion ? 1 : 0.84)
        VStack(spacing: 10) {
            art
                .overlay(glare)
                .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.55), radius: 30, y: 24)
                .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .scaleEffect(lift)
                .onContinuousHover(coordinateSpace: .local) { phase in
                    switch phase {
                    case .active(let at):
                        hovering = true
                        let x = min(max(at.x / width, 0), 1), y = min(max(at.y / height, 0), 1)
                        pointer = UnitPoint(x: x, y: y)
                        withAnimation(.interpolatingSpring(stiffness: 170, damping: 20)) {
                            tilt = CGSize(width: x * 2 - 1, height: y * 2 - 1)
                        }
                    case .ended:
                        hovering = false
                        withAnimation(.spring(response: 0.7, dampingFraction: 0.72)) { tilt = .zero }
                    }
                }
            // Отражение: та же обложка вверх ногами, тает к низу.
            art
                .scaleEffect(x: 1, y: -1)
                .mask(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0)],
                                     startPoint: .top, endPoint: UnitPoint(x: 0.5, y: 0.34)))
                .rotation3DEffect(.degrees(yaw), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
                .rotation3DEffect(.degrees(-pitch), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
                .scaleEffect(lift)
                .frame(height: height * 0.34, alignment: .top)
                .clipped()
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
        .animation(Theme.Motion.gentle, value: hovering)
        .onAppear {
            guard entrance, !arrived else { return }
            withAnimation(.spring(response: 1.0, dampingFraction: 0.8).delay(0.08)) { arrived = true }
        }
    }

    private var art: some View {
        GameArtworkView(app: app) { ExeArtFallback(app: app, iconScale: 0.46) }
            .frame(width: width, height: height)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }

    private var glare: some View {
        RadialGradient(colors: [.white.opacity(0.24), .white.opacity(0.05), .white.opacity(0)],
                       center: pointer, startRadius: 0, endRadius: width * 1.1)
            .blendMode(.plusLighter)
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(false)
    }
}

// MARK: - Состояние капсулой

/// Состояние игры в капсуле с точкой цвета: зелёная — идёт, оранжевая — отказ.
struct StatusCapsule: View {
    @Environment(\.colorScheme) private var scheme
    let status: GameStatus

    var body: some View {
        let color = status.color(scheme)
        HStack(spacing: 6) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(status.text).lineLimit(1)
        }
        .font(.system(size: 12.5, weight: .medium))
        .foregroundColor(status.tone == .neutral ? Theme.Palette.textSecondary(scheme) : color)
        .padding(.horizontal, 10)
        .frame(height: 24)
        .background(Capsule().fill(color.opacity(status.tone == .neutral ? 0.1 : 0.14)))
    }
}

/// Коротко о графике: «DirectX 11 · 64 бита» — без хвоста «экспериментально, не проверено»:
/// он есть в технических подробностях, а в шапке только мешает.
enum GraphicsLine {
    static func short(_ app: AppEntry, loc: Localization = .shared) -> String? {
        guard let summary = app.lastGraphicsSummary, !summary.isEmpty else { return nil }
        let parts = loc.relocalize(summary).components(separatedBy: " · ")
        return parts.prefix(2).joined(separator: " · ")
    }
}

// MARK: - Листы (настройки, помощь)

/// Главная кнопка листа — светлая капсула, как «Играть»: при наведении чуть растёт и светится.
struct PrimaryCapsuleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryCapsuleLabel(configuration: configuration)
    }
}

private struct PrimaryCapsuleLabel: View {
    @Environment(\.colorScheme) private var scheme
    let configuration: ButtonStyleConfiguration
    @State private var hovering = false

    var body: some View {
        configuration.label
            .font(.system(size: 13.5, weight: .semibold))
            .foregroundColor(Theme.Palette.onEmphasis(scheme))
            .padding(.horizontal, 22)
            .frame(height: 34)
            .background(Capsule().fill(Theme.Palette.emphasis(scheme)))
            .contentShape(Capsule())
            .shadow(color: Theme.Palette.emphasis(scheme).opacity(hovering ? 0.25 : 0), radius: hovering ? 16 : 0, y: hovering ? 6 : 0)
            .scaleEffect(configuration.isPressed ? 0.97 : (hovering ? 1.04 : 1))
            .animation(.spring(response: 0.35, dampingFraction: 0.6), value: hovering)
            .animation(Theme.Motion.fast, value: configuration.isPressed)
            .onHover { hovering = $0 }
    }
}

extension ButtonStyle where Self == PrimaryCapsuleButtonStyle {
    static var primaryCapsule: PrimaryCapsuleButtonStyle { PrimaryCapsuleButtonStyle() }
}

/// Круглая стеклянная кнопка «закрыть» в углу листа.
struct SheetCloseButton: View {
    @Environment(\.colorScheme) private var scheme
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(hovering ? Theme.Palette.textPrimary(scheme) : Theme.Palette.textSecondary(scheme))
                .frame(width: 30, height: 30)
                .glassCapsule(highlighted: hovering)
                .rotationEffect(.degrees(hovering ? 90 : 0))
                .contentShape(Circle())
        }
        .buttonStyle(.scalePress)
        .onHover { hovering = $0 }
        .animation(.spring(response: 0.4, dampingFraction: 0.65), value: hovering)
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityLabel(L("Close"))
    }
}

/// Подложка листа: матовое стекло поверх окна, сверху слева — мягкий отсвет.
struct SheetBackdrop: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        ZStack {
            Rectangle().fill(.ultraThinMaterial)
            (scheme == .dark ? Color.black.opacity(0.38) : Color.white.opacity(0.35))
            RadialGradient(colors: [Color.white.opacity(scheme == .dark ? 0.07 : 0.3), .clear],
                           center: UnitPoint(x: 0.1, y: 0), startRadius: 0, endRadius: 420)
        }
        .ignoresSafeArea()
    }
}

/// Группа строк на стекле — как разделы в «Системных настройках» macOS.
struct SettingsGroup<Content: View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) { content() }
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(scheme == .dark ? 0.055 : 0.6)))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(Color.white.opacity(scheme == .dark ? 0.09 : 0.7), lineWidth: 0.75))
    }
}

/// Строка группы: значок, название (и пояснение), справа — управление.
struct SettingsRow<Control: View>: View {
    @Environment(\.colorScheme) private var scheme
    let icon: String
    /// Тон плитки значка: 1 — белая, 0 — чёрная (см. `SettingsIcon`).
    var shade: Double = 0.5
    let title: String
    var subtitle: String? = nil
    @ViewBuilder let control: () -> Control

    var body: some View {
        HStack(spacing: 14) {
            SettingsIcon(symbol: icon, shade: shade)
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.system(size: 13.5, weight: .semibold))
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                    .lineLimit(1)
                    .fixedSize()
                if let subtitle {
                    Text(subtitle)
                        .font(.system(size: 11.5))
                        .foregroundColor(Theme.Palette.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: Theme.Spacing.l)
            control()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }
}

/// Линия между строками группы — от текста, а не от края: так делит macOS.
struct SettingsDivider: View {
    var body: some View {
        Rectangle().fill(Color.white.opacity(0.08)).frame(height: 0.75).padding(.leading, 58)
    }
}

/// Значок строки: плитка своего тона — от белой через серые до почти чёрной, символ на ней
/// тёмный или светлый.
///
/// ★ Владелец, 25.09.2026: «цветные значки ты зря добавил, надо в том же стиле… белый, серый,
///   чёрный и цвета между ними». Плитки как в «Системных настройках», но в чёрно-серебряной
///   гамме приложения: у каждой строки свой оттенок, а не свой цвет.
struct SettingsIcon: View {
    let symbol: String
    /// 1 — белая плитка, 0 — чёрная.
    var shade: Double = 0.5
    var side: CGFloat = 28

    var body: some View {
        let light = shade > 0.55
        RoundedRectangle(cornerRadius: side * 0.29, style: .continuous)
            .fill(LinearGradient(colors: [Color(white: min(shade + 0.1, 1)), Color(white: shade)],
                                 startPoint: .top, endPoint: .bottom))
            .overlay(RoundedRectangle(cornerRadius: side * 0.29, style: .continuous)
                .strokeBorder(Color.white.opacity(light ? 0.5 : 0.16), lineWidth: 0.75))
            .overlay(Image(systemName: symbol)
                .font(.system(size: side * 0.46, weight: .semibold))
                .foregroundColor(light ? Color(white: 0.08) : Color(white: 0.96)))
            .frame(width: side, height: side)
            .shadow(color: .black.opacity(0.3), radius: 4, y: 2)
            .accessibilityHidden(true)
    }
}
