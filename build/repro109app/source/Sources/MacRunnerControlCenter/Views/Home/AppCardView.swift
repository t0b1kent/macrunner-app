import SwiftUI

/// Плитка 2:3 с настоящей обложкой игры. Для программ и при отсутствии обложки
/// остаётся значок самого exe на фоне из него же, размытого (`ExeArtFallback`).
struct AppCardView: View {
    @Environment(\.colorScheme) private var scheme
    let app: AppEntry
    let isRunning: Bool
    var launchProgress: LaunchProgress? = nil
    let onRun: () -> Void
    let onOpenDetail: () -> Void
    /// Фон окна, пока плитка под курсором (новый вид, 25.09.2026).
    var backdrop: BackdropSource? = nil

    @ObservedObject private var loc = Localization.shared
    @State private var hovering = false
    @State private var sheen: CGFloat = -1
    /// Где курсор над плиткой: −1…1 по ширине и высоте. Ведёт наклон, глубину обложки и блик.
    /// ★ Владелец, 25.09.2026: «3D красоты, прикольчики при наведении».
    @State private var tilt: CGSize = .zero
    @State private var pointer = UnitPoint(x: 0.5, y: 0.3)
    /// ★ Файла на диске может не быть: игру удалили, внешний диск отключили,
    ///   бутылку почистили. Библиотека обязана это ПОКАЗЫВАТЬ, а не молчать —
    ///   иначе человек жмёт «играть» и получает невнятный отказ.
    ///   Измерено 12.09.2026: 4 записи из 5 указывали на исчезнувшие файлы.
    @State private var fileMissing = false

    private let posterWidth: CGFloat = 190
    private var posterHeight: CGFloat { posterWidth * 3 / 2 }

    var body: some View {
        Button(action: onOpenDetail) {
            VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                poster
                    .background(alignment: .top) { ambientGlow }
                caption
            }
            .frame(width: posterWidth, alignment: .leading)
        }
        .buttonStyle(.plain)
        .animation(Theme.Motion.gentle, value: hovering)
        .onHover { entering in
            hovering = entering
            if entering { runSheen() }
        }
        .backdrop(backdrop, whileHovering: hovering)
        .task(id: app.exePath) { checkFile() }
    }

    // MARK: - Постер

    private var poster: some View {
        ZStack(alignment: .bottomLeading) {
            GameArtworkView(app: app) {
                ExeArtFallback(app: app, iconScale: 0.46, iconOffset: -0.06)
            }
            // Глубина: обложка чуть крупнее и едет навстречу наклону — картинка «плавает» под стеклом.
            .scaleEffect(hovering ? 1.07 : 1)
            .offset(x: -tilt.width * 7, y: -tilt.height * 7)
            veil
            sheenLayer
            glare
            statusPill
            runOverlay

            Text(app.name)
                .font(.system(size: 14, weight: .bold))
                .kerning(-0.3)
                .foregroundColor(.white)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 13)
                .padding(.bottom, 12)
        }
        .frame(width: posterWidth, height: posterHeight)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
                .stroke(
                    hovering ? Theme.Palette.border(scheme).opacity(1) : Theme.Palette.border(scheme).opacity(0.5),
                    lineWidth: 0.75
                )
        )
        .shadow(color: .black.opacity(hovering ? 0.6 : 0), radius: hovering ? 22 : 0, y: hovering ? 12 : 0)
        // Плитка наклоняется за курсором, как стекло в руке: сторона под курсором уходит вглубь.
        // Знаки проверены отрисовкой (ImageRenderer): сторона под курсором уходит вглубь, как на сайте.
        .rotation3DEffect(.degrees(Double(-tilt.height) * 9), axis: (x: 1, y: 0, z: 0), perspective: 0.5)
        .rotation3DEffect(.degrees(Double(tilt.width) * 11), axis: (x: 0, y: 1, z: 0), perspective: 0.5)
        .offset(y: hovering ? -5 : 0)
        .onContinuousHover(coordinateSpace: .local) { phase in
            switch phase {
            case .active(let at):
                let x = min(max(at.x / posterWidth, 0), 1), y = min(max(at.y / posterHeight, 0), 1)
                pointer = UnitPoint(x: x, y: y)
                withAnimation(.interpolatingSpring(stiffness: 170, damping: 20)) {
                    tilt = CGSize(width: x * 2 - 1, height: y * 2 - 1)
                }
            case .ended:
                withAnimation(.spring(response: 0.6, dampingFraction: 0.72)) { tilt = .zero }
            }
        }
    }

    /// Свет за курсором по поверхности плитки — добавляется к обложке (`plusLighter`), а не закрашивает её.
    private var glare: some View {
        RadialGradient(colors: [.white.opacity(0.2), .white.opacity(0.06), .white.opacity(0)],
                       center: pointer, startRadius: 0, endRadius: posterWidth * 0.95)
            .blendMode(.plusLighter)
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// Свечение обложки под плиткой: её же размытые цвета разливаются по фону, как свет от экрана.
    @ViewBuilder
    private var ambientGlow: some View {
        if hovering {
            GameArtworkView(app: app) {
                ExeArtFallback(app: app, iconScale: 0.46, iconOffset: -0.06)
            }
            .frame(width: posterWidth, height: posterHeight)
            .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
            .blur(radius: 30)
            .opacity(0.55)
            .scaleEffect(0.94)
            .offset(x: tilt.width * 8, y: 20)
            .transition(.opacity)
            .allowsHitTesting(false)
        }
    }

    private var veil: some View {
        LinearGradient(
            stops: [
                .init(color: .black.opacity(0.92), location: 0.0),
                .init(color: .black.opacity(0.45), location: 0.4),
                .init(color: .black.opacity(0.04), location: 0.75)
            ],
            startPoint: .bottom,
            endPoint: .top
        )
    }

    /// Блик по наведению. Едет СМЕЩЕНИЕМ, а не сдвигом точек градиента: заливка
    /// (`ShapeStyle`) в SwiftUI не анимируется и просто перескакивает в конечное
    /// значение — тот же изъян был у знака, измерен снимками окна 12.09.2026.
    ///
    /// ★★★ ПОЧЕМУ ЭТО НЕ ПРОСТО БЕЛАЯ ПОЛОСА (владелец, 12.09.2026: «палка какая-то
    ///   идёт»). Прежний блик рисовал белый прямоугольник в пол-плитки ПОВЕРХ
    ///   картинки — оттого и читался как палка. Свет ведёт себя иначе, и разница
    ///   держится на трёх вещах:
    ///
    ///   1. `plusLighter` — свет ДОБАВЛЯЕТСЯ к тому, что под ним, а не закрашивает.
    ///      Это главное: белая краска поверх обложки выглядит наклейкой, добавленный
    ///      свет — бликом на самой обложке.
    ///   2. Две полосы вместо одной: широкий мягкий ореол и тонкая яркая сердцевина.
    ///      У настоящего блика края незаметны, а середина резкая.
    ///   3. Замедление к концу (`easeOut`): равномерное движение читается как
    ///      механическое, затухающее — как скольжение света.
    /// ★★★★ ПОПРАВКА ВТОРАЯ (владелец: «опять палка из стороны в сторону»).
    ///   Первая попытка убрала резкие края, но ОСТАВИЛА яркую тонкую сердцевину —
    ///   и читалась именно она, как прочерченная линия. Сердцевина убрана совсем.
    ///
    ///   Решает не форма градиента, а РАЗМЫТИЕ: у размытой полосы края не
    ///   «сглажены», их физически нет, и глазу не за что зацепиться. Плюс полоса
    ///   шире самой плитки — тогда её собственные концы НИКОГДА не попадают в кадр,
    ///   а видна только середина, которая переливается.
    private var sheenLayer: some View {
        Color.clear
            .frame(width: posterWidth, height: posterHeight)
            .overlay(
                Rectangle()
                    .fill(
                        LinearGradient(
                            stops: [
                                .init(color: .white.opacity(0),     location: 0.00),
                                .init(color: .white.opacity(0.015), location: 0.22),
                                .init(color: .white.opacity(0.05),  location: 0.40),
                                .init(color: .white.opacity(0.075), location: 0.50),
                                .init(color: .white.opacity(0.05),  location: 0.60),
                                .init(color: .white.opacity(0.015), location: 0.78),
                                .init(color: .white.opacity(0),     location: 1.00)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                    // Шире и выше плитки: собственные края полосы остаются за кадром.
                    .frame(width: posterWidth * 1.45, height: posterHeight * 1.9)
                    .rotationEffect(.degrees(14))
                    .blur(radius: 28)
                    .offset(x: sheen * posterWidth * 1.7)
                    .blendMode(.plusLighter)
            )
            .opacity(hovering ? 1 : 0)
            .allowsHitTesting(false)
    }

    /// ★ Плашка только когда ЕСТЬ что сказать: игра идёт, файла нет, запуск не удался.
    ///   «READY» на каждой плитке закрывал логотип на обложке и не значил ничего.
    @ViewBuilder
    private var statusPill: some View {
        if let statusLabel {
        VStack {
            HStack {
                Text(statusLabel)
                    .font(.system(size: 10, weight: .bold))
                    .kerning(0.5)
                    .foregroundColor(.white.opacity(0.92))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 8)
                    .background(
                        Capsule().fill(.black.opacity(0.55))
                            .overlay(Capsule().stroke(.white.opacity(0.18), lineWidth: 0.5))
                    )
                    .help(failureText ?? "")
                Spacer(minLength: 0)
            }
            Spacer(minLength: 0)
        }
        .padding(11)
        }
    }

    /// Запуск — ПОЛУПРОЗРАЧНЫЙ ЗНАК по центру, без слов.
    ///
    /// ★ Слов тут быть не должно: «Launch» надо читать и переводить на 12 языков,
    ///   а треугольник понимает кто угодно. Прозрачность важна не для красоты —
    ///   сквозь неё видно саму плитку, и знак не закрывает игру, к которой ведёт.
    @ViewBuilder
    private var runOverlay: some View {
        if fileMissing {
            // Кнопки пуска нет вовсе: нажимать некуда, и лучше сказать это словами.
            VStack(spacing: 6) {
                Image(systemName: "questionmark.folder")
                    .font(.system(size: 22, weight: .light))
                    .foregroundColor(.white.opacity(0.85))
                Text(L("File is gone"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.white.opacity(0.85))
            }
            .padding(.vertical, 10)
            .padding(.horizontal, 14)
            .background(Capsule().fill(.black.opacity(0.45)))
            .opacity(hovering ? 1 : 0)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .allowsHitTesting(false)
        } else {
            launchButton
        }
    }

    private var launchButton: some View {
        Button(action: onRun) {
            ZStack {
                Circle()
                    .fill(.black.opacity(0.34))
                    .background(.ultraThinMaterial, in: Circle())
                Circle()
                    .strokeBorder(.white.opacity(0.55), lineWidth: 1)
                Image(systemName: isRunning ? "stop.fill" : "play.fill")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundColor(.white)
                    // Треугольник тяжелее слева: без сдвига он выглядит смещённым.
                    .offset(x: isRunning ? 0 : 2)
            }
            .frame(width: 58, height: 58)
        }
        .buttonStyle(.scalePress)
        .opacity(hovering ? 1 : 0)
        .scaleEffect(hovering ? 1 : 0.9)
        .allowsHitTesting(hovering)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .help(isRunning ? L("Stop") : L("Launch"))
    }

    // MARK: - Подпись под постером

    /// Под постером — одна фраза состояния («Играли 2 часа назад», «Не запускалась»).
    private var caption: some View {
        let status = GameStatus.of(app, isRunning: isRunning, progress: launchProgress, fileMissing: fileMissing)
        return Text(status.text)
            .font(Theme.Font.caption)
            .foregroundColor(status.color(scheme))
            .lineLimit(1)
            .padding(.horizontal, 2)
            // Подпись узкая и режет причину — целиком она во всплывающей подсказке.
            .help(launchProgress?.guidance(at: Date()) ?? failureText ?? "")
    }

    // MARK: - Подписи

    private var statusLabel: String? {
        if fileMissing { return L("NO FILE") }
        if isRunning { return launchProgress?.phase.title ?? L("Starting process") }
        if RunFailure.isFailure(status: app.lastRunStatus) { return L("FAILED") }
        return nil
    }

    /// ★★★ «FAILED» БЕЗ ПРИЧИНЫ НЕЛЬЗЯ ОСПОРИТЬ И НЕЛЬЗЯ ПОЧИНИТЬ.
    ///   Метка говорила только, что не вышло; почему — оставалось в last-run.json,
    ///   куда игрок не заглянет. Теперь причина стоит в подписи под постером.
    private var failureHeadline: String? {
        guard !isRunning, !fileMissing, RunFailure.isFailure(status: app.lastRunStatus) else { return nil }
        return RunFailure.headline(status: app.lastRunStatus)
    }

    /// Заголовок и дословная улика движка — для подсказки.
    private var failureText: String? {
        guard let headline = failureHeadline else { return nil }
        guard let detail = app.lastRunError, !detail.isEmpty else { return headline }
        return headline + "\n" + detail
    }

    /// Значок самого `.exe` рисует `ExeArtFallback` (он же — фон без обложки); здесь только
    /// проверка, что файл на месте.
    private func checkFile() {
        guard !app.exePath.isEmpty else { fileMissing = true; return }
        fileMissing = !FileManager.default.fileExists(atPath: app.exePath)
    }

    private func runSheen() {
        sheen = -1
        // ★ Медленнее и мягче: 1,15 с читались как проезд предмета. На двух
        //   секундах с плавным входом и выходом это уже перелив, а не движение.
        withAnimation(.easeInOut(duration: 2.0)) { sheen = 1.2 }
    }
}
