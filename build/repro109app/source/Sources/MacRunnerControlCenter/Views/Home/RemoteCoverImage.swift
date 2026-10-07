import SwiftUI
import AppKit

/// Картинка из сети, которая кладётся на диск и больше не качается.
///
/// ★★★ ПОЧЕМУ НЕ `AsyncImage`: он держит картинку только в памяти процесса. Прокрутил
///   список туда-обратно — и каждая обложка скачана заново. На пятидесяти обложках это
///   полсотни лишних запросов за минуту листания. `CoverCache` в проекте уже умеет
///   класть файл на диск, им и пользуемся.
///
/// ★ Отказ загрузки НЕ показываем крестиком: обложка — украшение, и сломанная картинка
///   пугает сильнее, чем её отсутствие. Молча остаётся запасной вид.
struct RemoteCoverImage<Fallback: View>: View {
    let url: String
    let cacheID: String
    /// Отношение сторон рамки, в которую кладём картинку. Задано — и картинка сильно
    /// другой формы (полоса 700×100, квадрат 160×120 в рамке 16:9) не режется, а
    /// вписывается целиком поверх размытой себя же. Не задано — просто заливка.
    var frameAspect: CGFloat? = nil
    @ViewBuilder let fallback: () -> Fallback

    @State private var image: NSImage?
    @State private var failed = false

    var body: some View {
        Group {
            if let image {
                if let frameAspect, !Self.fillsWell(image, frameAspect) {
                    // ★ Слои — НАЛОЖЕНИЯ на рамку, а не ZStack: в ZStack размытая заливка
                    //   раздувала контейнер до своей ширины (полоса 7:1 -> в семь раз шире
                    //   рамки), и чёткая картинка вписывалась уже в раздутый размер —
                    //   то есть снова обрезалась (снято на Orbiter 2024, 23.09.2026).
                    Color.black
                        .overlay {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .blur(radius: 22)
                                .opacity(0.55)
                        }
                        .overlay {
                            Image(nsImage: image)
                                .resizable()
                                .aspectRatio(contentMode: .fit)
                        }
                        .clipped()
                } else {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                }
            } else {
                fallback()
            }
        }
        .task(id: url) { await load() }
    }

    /// Заливка теряет не больше ~четверти картинки — режем; больше — вписываем.
    /// 4:3 в рамке 16:10 режется (0,83), квадрат и полоса 7:1 — вписываются.
    static func fillsWell(_ image: NSImage, _ frameAspect: CGFloat) -> Bool {
        let size = image.size
        guard size.width > 0, size.height > 0, frameAspect > 0 else { return true }
        let ratio = (size.width / size.height) / frameAspect
        return ratio > 0.75 && ratio < 1.4
    }

    private func load() async {
        guard image == nil, !failed, let remote = URL(string: url),
              let scheme = remote.scheme?.lowercased(), scheme == "https" || scheme == "http"
        else { return }

        let cache = CoverCache()
        let id = "game/" + CoverCache.safeIdentifier(cacheID)
        if let local = cache.downloadedCover(for: remote, id: id),
           let picture = NSImage(contentsOf: local) {
            image = picture
            return
        }
        do {
            let local = try await cache.download(remote, id: id)
            if let picture = NSImage(contentsOf: local) { image = picture } else { failed = true }
        } catch {
            failed = true
        }
    }
}
