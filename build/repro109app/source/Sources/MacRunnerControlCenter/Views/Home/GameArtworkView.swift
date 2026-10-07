import AppKit
import SwiftUI

/// Keeps the complete official artwork visible. Wide catalogue art uses the same
/// image, softly blurred, behind its fitted foreground instead of cropping a banner.
struct GameArtworkView<Fallback: View>: View {
    let app: AppEntry
    @ViewBuilder let fallback: () -> Fallback
    @ObservedObject private var catalog = GameCatalog.shared
    @State private var image: NSImage?

    private var request: GameArtworkRequest { GameArtworkRequest(app: app, catalog: catalog.games) }

    var body: some View {
        GeometryReader { geometry in
            if let image {
                ZStack {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                        .blur(radius: 18)
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFit()
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
                .clipped()
            } else {
                fallback()
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
        .task(id: request) {
            image = nil
            let bytes = await GameArtworkService.shared.artwork(for: request)
            guard !Task.isCancelled, let bytes else { return }
            image = NSImage(data: bytes)
        }
    }
}

/// Плитка без обложки. Цвет даёт значок самого exe — размытый и увеличенный под ним,
/// как у программ; без значка — постоянный оттенок из имени, как у бесплатных игр.
///
/// ★ Владелец, 24.09.2026: «иконка странная какая-то с серым фоном». Серый градиент под
///   маленьким значком читался как недогруженная картинка.
struct ExeArtFallback: View {
    let app: AppEntry
    /// Сторона значка — доля ширины плитки.
    var iconScale: CGFloat = 0.46
    /// Сдвиг значка по вертикали — доля высоты (над подписью на постере).
    var iconOffset: CGFloat = 0

    @State private var icon: NSImage?

    var body: some View {
        GeometryReader { geometry in
            let width = geometry.size.width, height = geometry.size.height
            let side = width * iconScale
            ZStack {
                if let icon {
                    Color(white: 0.11)
                    Image(nsImage: icon)
                        .resizable()
                        .interpolation(.medium)
                        .scaledToFill()
                        .frame(width: width, height: height)
                        .scaleEffect(1.4)
                        .blur(radius: max(width * 0.16, 10))
                        .saturation(1.25)
                        .opacity(0.85)
                    Image(nsImage: icon)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(width: side, height: side)
                        .offset(y: height * iconOffset)
                        .shadow(color: .black.opacity(0.45), radius: max(width * 0.05, 4), y: 4)
                } else {
                    CatalogArt.gradient(for: app.name, brightness: 0.36)
                    Text(Self.initials(of: app.name))
                        .font(.system(size: side * 0.5, weight: .semibold))
                        .kerning(-0.5)
                        .foregroundColor(.white.opacity(0.88))
                        .offset(y: height * iconOffset)
                }
            }
            .frame(width: width, height: height)
            .clipped()
        }
        .task(id: app.exePath) {
            icon = nil
            guard !app.exePath.isEmpty else { return }
            let url = URL(fileURLWithPath: app.exePath)
            guard FileManager.default.fileExists(atPath: url.path),
                  let data = ExeIcon.cachedIcon(at: url) else { return }
            icon = NSImage(data: data)
        }
    }

    static func initials(of name: String) -> String {
        let letters = name.split(whereSeparator: { $0 == " " || $0 == "-" || $0 == "_" })
            .prefix(2).compactMap(\.first).map { String($0).uppercased() }
        return letters.isEmpty ? "·" : letters.joined()
    }
}
