import AppKit
import CoreImage
import SwiftUI

/// Фон окна из самой игры.
///
/// ★★★ Владелец, 25.09.2026: «почему фон такой? я думал будет хотя бы как у игры». Плоский серый
///   фон стеклу не даёт ничего: матовой панели нечего размывать. Теперь за всем окном — размытая
///   обложка игры: той, что под курсором, открытой или той, что в шапке раздела. У программ
///   обложек нет — фон светится цветом их значка. Смена — медленное перетекание, а не щелчок.
///
/// ★ Размытие делается ОДИН раз при загрузке (Core Image, картинка шириной 320 точек), а не на
///   каждом кадре: `.blur` на окне в 1280 точек пересчитывался бы при каждой анимации над ним.
enum BackdropSource: Hashable, Sendable {
    case artwork(GameArtworkRequest)
    case cover(url: String, cacheID: String)
    /// Сияние цветов значков: один цвет — программа под курсором, несколько — переливы раздела.
    case colors([GlowColor])
    case neutral

    /// Сияние цвета значка программы — для плитки под курсором.
    static func glow(forProgram programID: String, icon: ProgramIconSource?) -> BackdropSource {
        GlowColor.forProgram(programID, icon: icon).map { .colors([$0]) } ?? .neutral
    }
}

/// Откуда взять цвет сияния: готовый фирменный цвет или значок, по которому цвет считается.
enum GlowColor: Hashable, Sendable {
    case rgb(Double, Double, Double)
    case icon(url: String, cacheID: String)

    /// Знак из набора — его фирменный цвет (тёмные, как чёрный 7-Zip, — серебристый); значок
    /// с сайта — главный цвет самой картинки.
    ///
    /// ★ Значков с сайта БОЛЬШИНСТВО (Word, Excel, Krita…): пока их цвет не считался, фон у почти
    ///   всех программ оставался серым (снято 25.09.2026).
    static func forProgram(_ programID: String, icon: ProgramIconSource?) -> GlowColor? {
        switch icon {
        case .bundled(_, let hex, let dark)?:
            if dark { return .rgb(0.62, 0.65, 0.72) }
            var value: UInt64 = 0
            guard Scanner(string: hex).scanHexInt64(&value) else { return nil }
            return .rgb(Double((value >> 16) & 0xFF) / 255, Double((value >> 8) & 0xFF) / 255, Double(value & 0xFF) / 255)
        case .web(let url)?:
            // Тот же ключ, что у значка на плитке (`ProgramIconView`): файл уже на диске.
            return .icon(url: url, cacheID: "program-" + programID)
        case nil:
            return nil
        }
    }
}

struct RGB: Hashable, Sendable {
    let r: Double, g: Double, b: Double
    var color: Color { Color(red: r, green: g, blue: b) }

    /// Тот же оттенок, но светлый: тёмно-синий знак Audacity иначе не светился бы вовсе.
    var lifted: RGB {
        let top = max(r, g, b)
        guard top > 0.001 else { return RGB(r: 0.62, g: 0.65, b: 0.72) }
        let k = 0.92 / top
        return RGB(r: min(r * k, 1), g: min(g * k, 1), b: min(b * k, 1))
    }
}

/// Что рисовать за окном: размытую картинку или сияние цветов.
enum BackdropContent {
    case image(CGImage)
    case colors([RGB])
    case none
}

/// Что сейчас под курсором. Плитки сообщают о себе сами (`backdrop(_:whileHovering:)`); ничего нет —
/// окно показывает фон раздела.
@MainActor
final class BackdropModel: ObservableObject {
    @Published private(set) var hovered: BackdropSource?

    func enter(_ source: BackdropSource) { if hovered != source { hovered = source } }
    func leave(_ source: BackdropSource) { if hovered == source { hovered = nil } }
    func reset() { if hovered != nil { hovered = nil } }
}

private struct BackdropModelKey: EnvironmentKey {
    static let defaultValue: BackdropModel? = nil
}

extension EnvironmentValues {
    /// Необязательный: витрина программ живёт и в режиме разработчика, где фона из игры нет.
    var backdropModel: BackdropModel? {
        get { self[BackdropModelKey.self] }
        set { self[BackdropModelKey.self] = newValue }
    }
}

extension View {
    /// Плитка под курсором — фон окна становится её картинкой.
    ///
    /// ★ Следим за ТЕМ ЖЕ состоянием наведения, по которому плитка приподнимается, а не вешаем
    ///   второй `onHover`: два обработчика наведения на одном виде друг другу мешают, и фон
    ///   не менялся, хотя плитка под курсором поднималась (снято 25.09.2026).
    func backdrop(_ source: BackdropSource?, whileHovering hovering: Bool) -> some View {
        modifier(BackdropHover(source: source, hovering: hovering))
    }
}

private struct BackdropHover: ViewModifier {
    @Environment(\.backdropModel) private var model
    let source: BackdropSource?
    let hovering: Bool

    func body(content: Content) -> some View {
        content
            .onChange(of: hovering) { _, inside in
                guard let model, let source else { return }
                if inside { model.enter(source) } else { model.leave(source) }
            }
            .onDisappear {
                if let model, let source { model.leave(source) }
            }
    }
}

/// Размытые картинки фона — готовятся один раз и держатся в памяти.
actor BackdropImages {
    static let shared = BackdropImages()

    private var cache: [BackdropSource: BackdropContent] = [:]
    private let context = CIContext(options: [.cacheIntermediates: false])

    func content(for source: BackdropSource) async -> BackdropContent {
        if let hit = cache[source] { return hit }
        let result: BackdropContent
        switch source {
        case .artwork(let request):
            let data = await GameArtworkService.shared.artwork(for: request)
            result = data.flatMap(blurred).map(BackdropContent.image) ?? .none
        case .cover(let url, let cacheID):
            let data = await Self.coverData(url: url, cacheID: cacheID)
            result = data.flatMap(blurred).map(BackdropContent.image) ?? .none
        case .colors(let wanted):
            var colors: [RGB] = []
            for item in wanted {
                switch item {
                case .rgb(let r, let g, let b):
                    colors.append(RGB(r: r, g: g, b: b).lifted)
                case .icon(let url, let cacheID):
                    let data = await Self.coverData(url: url, cacheID: cacheID)
                    if let color = data.flatMap(dominantColor) { colors.append(color) }
                }
            }
            result = colors.isEmpty ? .none : .colors(colors)
        case .neutral:
            return .none
        }
        if cache.count > 64 { cache.removeAll() }
        cache[source] = result
        return result
    }

    /// Главный цвет значка: средний по НАСЫЩЕННЫМ точкам, а не по всем. У Word это синий, у
    /// Excel — зелёный; простое среднее тянуло к серому из-за белого листа и прозрачного поля.
    private func dominantColor(_ data: Data) -> RGB? {
        guard let input = CIImage(data: data), input.extent.width > 0, input.extent.height > 0 else { return nil }
        let side = 24
        let scaled = input.transformed(by: CGAffineTransform(scaleX: CGFloat(side) / input.extent.width,
                                                             y: CGFloat(side) / input.extent.height))
        var pixels = [UInt8](repeating: 0, count: side * side * 4)
        context.render(scaled, toBitmap: &pixels, rowBytes: side * 4,
                       bounds: CGRect(x: scaled.extent.minX, y: scaled.extent.minY, width: CGFloat(side), height: CGFloat(side)),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var sum = (r: 0.0, g: 0.0, b: 0.0, w: 0.0)
        for i in stride(from: 0, to: pixels.count, by: 4) {
            let a = Double(pixels[i + 3]) / 255
            guard a > 0.5 else { continue }
            let r = Double(pixels[i]) / 255 / a, g = Double(pixels[i + 1]) / 255 / a, b = Double(pixels[i + 2]) / 255 / a
            let top = max(r, g, b), bottom = min(r, g, b)
            guard top > 0.15 else { continue }
            let saturation = (top - bottom) / top
            let w = saturation * saturation * a
            sum = (sum.r + r * w, sum.g + g * w, sum.b + b * w, sum.w + w)
        }
        // Значок без цвета (серый, чёрно-белый) — серебристое сияние.
        guard sum.w > 0.6 else { return RGB(r: 0.62, g: 0.65, b: 0.72) }
        return RGB(r: sum.r / sum.w, g: sum.g / sum.w, b: sum.b / sum.w).lifted
    }

    /// Та же дисковая копия, что у плитки каталога (`RemoteCoverImage`): второй раз не качаем.
    private static func coverData(url: String, cacheID: String) async -> Data? {
        guard let remote = URL(string: url), let scheme = remote.scheme?.lowercased(),
              scheme == "https" || scheme == "http" else { return nil }
        let cache = CoverCache()
        let id = "game/" + CoverCache.safeIdentifier(cacheID)
        if let local = cache.downloadedCover(for: remote, id: id) { return try? Data(contentsOf: local) }
        guard let local = try? await cache.download(remote, id: id) else { return nil }
        return try? Data(contentsOf: local)
    }

    private func blurred(_ data: Data) -> CGImage? {
        guard let input = CIImage(data: data), input.extent.width > 1, input.extent.height > 1 else { return nil }
        let scale = 320 / input.extent.width
        let small = input.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = small.extent
        let output = small
            .applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: 1.35])
            .clampedToExtent()
            .applyingGaussianBlur(sigma: 9)
            .cropped(to: extent)
        return context.createCGImage(output, from: extent)
    }
}

/// Сам фон: картинка или сияние, поверх — затемнение, чтобы текст читался на любой обложке.
struct ArtBackdropView: View {
    let source: BackdropSource
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var layer = Layer(id: .neutral, content: .none)

    struct Layer {
        let id: BackdropSource
        let content: BackdropContent
    }

    var body: some View {
        ZStack {
            (scheme == .dark ? Color(white: 0.05) : Color(white: 0.95))
            content(layer)
                .id(layer.id)
                .transition(.opacity)
            scrim
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: source) {
            // Курсор переезжает с плитки на плитку — фон раздела «между» ними не показываем.
            try? await Task.sleep(nanoseconds: 90_000_000)
            guard !Task.isCancelled else { return }
            let content = await BackdropImages.shared.content(for: source)
            guard !Task.isCancelled, source != layer.id else { return }
            withAnimation(.easeInOut(duration: reduceMotion ? 0.2 : 0.9)) {
                layer = Layer(id: source, content: content)
            }
        }
    }

    @ViewBuilder
    private func content(_ layer: Layer) -> some View {
        switch layer.content {
        case .image(let image):
            Color.clear
                .overlay {
                    Image(decorative: image, scale: 1)
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .scaleEffect(1.08)
                }
                .clipped()
                .colorMultiply(Color(white: scheme == .dark ? 0.66 : 1))
                .opacity(scheme == .dark ? 1 : 0.55)
        case .colors(let colors):
            aurora(colors, strength: 1)
        case .none:
            aurora([RGB(r: 0.6, g: 0.63, b: 0.75)], strength: 0.5)
        }
    }

    /// Пятна света по углам окна. Один цвет — два пятна; несколько — до четырёх, каждое своего
    /// цвета, и они перетекают друг в друга, как северное сияние.
    private func aurora(_ colors: [RGB], strength: Double) -> some View {
        // Один цвет — пятно справа сверху и отсвет слева снизу. Несколько — два пятна рядом
        // по верху окна (там фон виден лучше всего), третье справа, четвёртое слева внизу.
        let spots: [(center: UnitPoint, radius: CGFloat, alpha: Double)] = colors.count > 1
            ? [(UnitPoint(x: 0.86, y: 0.04), 700, 0.72),
               (UnitPoint(x: 0.34, y: 0.0), 620, 0.62),
               (UnitPoint(x: 1.0, y: 0.62), 560, 0.52),
               (UnitPoint(x: 0.14, y: 1.0), 560, 0.45)]
            : [(UnitPoint(x: 0.76, y: 0.08), 780, 0.78),
               (UnitPoint(x: 0.14, y: 0.98), 640, 0.5)]
        let count = colors.count > 1 ? min(4, max(3, colors.count)) : 2
        let k = (scheme == .dark ? 1.0 : 0.6) * strength
        return ZStack {
            ForEach(0..<count, id: \.self) { i in
                let color = colors[i % colors.count].color
                RadialGradient(colors: [color.opacity(spots[i].alpha * k), color.opacity(0)],
                               center: spots[i].center, startRadius: 0, endRadius: spots[i].radius)
            }
        }
    }

    /// Слева и снизу темнее: там текст и сетка; справа сверху картинка видна лучше всего.
    @ViewBuilder
    private var scrim: some View {
        let tone: Color = scheme == .dark ? .black : .white
        let k = scheme == .dark ? 1.0 : 1.15
        ZStack {
            LinearGradient(stops: [.init(color: tone.opacity(0.58 * k), location: 0),
                                   .init(color: tone.opacity(0.22 * k), location: 0.55),
                                   .init(color: tone.opacity(0.38 * k), location: 1)],
                           startPoint: .leading, endPoint: .trailing)
            LinearGradient(stops: [.init(color: tone.opacity(0), location: 0.4),
                                   .init(color: tone.opacity(0.72 * k), location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
    }
}
