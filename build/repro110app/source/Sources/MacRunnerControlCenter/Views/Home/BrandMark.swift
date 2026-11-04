import SwiftUI
import AppKit
import QuartzCore

/// Знак MacRunner: монограмма MR на почти чёрной плитке.
///
/// Цвета в интерфейсе нет — вместо него работает свет. Здесь это перламутр:
/// светлая полоса медленно едет поперёк букв.
///
/// ★★★ КАК ИМЕННО СДЕЛАН ПЕРЕЛИВ И ПОЧЕМУ НЕ ИНАЧЕ.
///   Первая попытка красила буквы градиентом через `foregroundStyle` и двигала его
///   точки внутри `withAnimation`. Так НЕ РАБОТАЕТ: заливка (`ShapeStyle`) в SwiftUI
///   не анимируется, значение просто перескакивает в конечное, и знак стоит намертво.
///   Измерено 12.09.2026: три снимка окна с промежутком 2,5 с оказались побайтно
///   одинаковыми.
///   Рабочий способ — двигать не заливку, а ГЕОМЕТРИЮ: полоса света едет внутри
///   квадрата знака, а маска по форме букв стоит на месте.
///
/// ★★★ ПОЛОСА ЕДЕТ В CORE ANIMATION, А НЕ В SWIFTUI (02.11.2026, владелец: «почини
///   приложение, чтобы не жрало процессор»).
///   Прежде полосу двигал `withAnimation(.repeatForever)` по `offset`. Такая анимация
///   SwiftUI считается В НАШЕМ процессе на каждом кадре экрана (120 Гц на ProMotion) и
///   не кончается никогда — даже когда окно в фоне: граф видов, раскладка, сдача слоёв
///   и пересчёт областей курсора всего окна шли без остановки: сборка 118 без игры держала
///   около 11 % ядра в среднем за 3 ч и до 34 % в моменте; в фоне на изолированных данных —
///   27–29 % и ~120 пробуждений в секунду, после правки — 0,1–0,2 % и 0,4
///   (artifacts/claude-lanes-20261102-appidle/runs/*/RESULT.json).
///   Теперь полоса — слой `CAGradientLayer` с маской по форме букв, а проход —
///   `CABasicAnimation`. Её ведёт сервер отрисовки системы: наш процесс между кадрами
///   спит. И едет она только пока окно действительно на виду и активно
///   (`appearsActive`, `occlusionState`); в фоне, свёрнутым и под игрой знак стоит.
///
/// ★ Ширина букв задана рамкой, а не отдана шрифту: подставится другой — и монограмма
///   съедет к краю. Ловилось на макете.
struct BrandMark: View {
    var size: CGFloat = 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appearsActive) private var appearsActive
    @Environment(\.displayScale) private var displayScale

    private var corner: CGFloat { size * 0.28 }

    var body: some View {
        ZStack {
            tile
            Self.letters(size: size).foregroundStyle(Color(white: 245.0 / 255.0))
            if !reduceMotion {
                BrandSheen(size: size, scale: displayScale, moving: appearsActive)
                    .frame(width: size, height: size)
                    .allowsHitTesting(false)
            }
            // ★ Обводка у НАШЕГО знака своя и светлее общей. Общее правило серого
            //   контура писалось ради ряда чужих значков внизу меню — чтобы ни один
            //   не пропал на фоне. Этого ряда в витрине игрока больше нет, а знак
            //   MacRunner остался один и должен читаться сам по себе.
            RoundedRectangle(cornerRadius: corner, style: .continuous)
                .strokeBorder(Theme.Palette.brandMarkBorder, lineWidth: Theme.Border.glyphTile)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }

    // MARK: - Части

    private var tile: some View {
        RoundedRectangle(cornerRadius: corner, style: .continuous)
            .fill(
                LinearGradient(
                    colors: [Color(white: 0.09), Color(white: 0.04), Color(white: 0.02)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .overlay(
                RoundedRectangle(cornerRadius: corner, style: .continuous)
                    .fill(
                        RadialGradient(
                            colors: [Color.white.opacity(0.10), Color.white.opacity(0)],
                            center: .center,
                            startRadius: 0,
                            endRadius: size * 0.62
                        )
                    )
            )
    }

    /// Буквы — одни и те же для знака и для маски полосы: маска рисуется из этого же вида
    /// (`ImageRenderer`), поэтому свет ложится ровно по буквам, какой бы шрифт ни подставился.
    static func letters(size: CGFloat) -> some View {
        Text("MR")
            .font(.system(size: size * 0.39, weight: .heavy, design: .default))
            .kerning(-size * 0.022)
            .frame(width: size * 0.54)
            .minimumScaleFactor(0.6)
            .lineLimit(1)
    }
}

/// Полоса света поверх букв. Геометрия прежняя: ширина 0,40 знака, наклон 14°,
/// проход от −0,9 до +0,9 знака за 7 с, линейно, без конца.
private struct BrandSheen: NSViewRepresentable {
    let size: CGFloat
    let scale: CGFloat
    let moving: Bool

    func makeNSView(context: Context) -> BrandSheenView { BrandSheenView() }

    func updateNSView(_ view: BrandSheenView, context: Context) {
        let size = size
        let scale = scale
        view.update(size: size, scale: scale, moving: moving) {
            let renderer = ImageRenderer(content: BrandMark.letters(size: size).frame(width: size, height: size))
            renderer.scale = scale
            renderer.isOpaque = false
            return renderer.cgImage
        }
    }
}

/// Вид-хозяин слоя: AppKit в его слои не вмешивается, SwiftUI его не перерисовывает.
///
/// ★ Анимация СНИМАЕТСЯ, а не ставится на паузу (`speed = 0`): снятая анимация не держит
///   сервер отрисовки, а модельное положение полосы — за левым краем, то есть знак стоит
///   чистыми буквами, как при «Уменьшить движение». Вернулось окно — проход начинается заново.
final class BrandSheenView: NSView {
    static let sweepKey = "macrunner.brand-sheen"
    static let sweepDuration: CFTimeInterval = 7

    private let container = CALayer()
    private let band = CAGradientLayer()
    private let shape = CALayer()
    private var size: CGFloat = 0
    private var scale: CGFloat = 0
    private var wantsMotion = false
    private var laidOut = CGRect.null
    private var occlusionObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Сначала свой слой, потом `wantsLayer` — так вид становится хозяином слоя.
        layer = CALayer()
        wantsLayer = true
        container.mask = shape
        container.addSublayer(band)
        layer?.addSublayer(container)
        let clear = NSColor.white.withAlphaComponent(0).cgColor
        band.colors = [clear, NSColor.white.cgColor, clear]
        band.startPoint = CGPoint(x: 0, y: 0.5)
        band.endPoint = CGPoint(x: 1, y: 0.5)
    }

    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        needsLayout = true
    }

    /// Едет ли полоса сейчас — для проверки (`BrandSheenViewTests`).
    var isSweeping: Bool { band.animation(forKey: Self.sweepKey) != nil }

    func update(size: CGFloat, scale: CGFloat, moving: Bool, letters: () -> CGImage?) {
        if size != self.size || scale != self.scale {
            self.size = size
            self.scale = scale
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.contents = letters()
            shape.contentsScale = scale
            band.contentsScale = scale
            CATransaction.commit()
            laidOut = .null
            needsLayout = true
        }
        wantsMotion = moving
        refreshMotion()
    }

    override func layout() {
        super.layout()
        guard bounds != laidOut else { return }
        laidOut = bounds
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        container.frame = bounds
        shape.frame = container.bounds
        band.bounds = CGRect(x: 0, y: 0, width: size * 0.40, height: size)
        band.position = CGPoint(x: bounds.midX - size * 0.9, y: bounds.midY)
        // Слой не перевёрнут (ось y вверх): поворот по часовой стрелке — отрицательный угол,
        // как `rotationEffect(.degrees(14))` у SwiftUI с осью y вниз.
        band.setAffineTransform(CGAffineTransform(rotationAngle: -14 * .pi / 180))
        CATransaction.commit()
        // Геометрия сменилась — проход строится заново под новые границы.
        band.removeAnimation(forKey: Self.sweepKey)
        refreshMotion()
    }

    /// Подписка живёт, пока вид в окне: ушёл из окна (`window == nil`) — снята здесь же,
    /// поэтому `deinit` не нужен.
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        if let window {
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main) { [weak self] _ in
                    Task { @MainActor in self?.refreshMotion() }
                }
        }
        refreshMotion()
    }

    private var shouldMove: Bool {
        guard wantsMotion, size > 0, !laidOut.isNull, let window else { return false }
        return window.occlusionState.contains(.visible) && !window.isMiniaturized
    }

    private func refreshMotion() {
        if shouldMove, !isSweeping {
            let sweep = CABasicAnimation(keyPath: "position.x")
            sweep.fromValue = laidOut.midX - size * 0.9
            sweep.toValue = laidOut.midX + size * 0.9
            sweep.duration = Self.sweepDuration
            sweep.repeatCount = .infinity
            sweep.timingFunction = CAMediaTimingFunction(name: .linear)
            band.add(sweep, forKey: Self.sweepKey)
        } else if !shouldMove, isSweeping {
            band.removeAnimation(forKey: Self.sweepKey)
        }
    }
}

#Preview {
    HStack(spacing: 16) {
        BrandMark(size: 16)
        BrandMark(size: 30)
        BrandMark(size: 64)
    }
    .padding(24)
    .background(Color.black)
}
