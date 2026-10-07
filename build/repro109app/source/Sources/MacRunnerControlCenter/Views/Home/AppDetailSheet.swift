import SwiftUI

/// Страница игры.
///
/// ★★★ РЕДИЗАЙН 23.09.2026 (владелец: «простота, чтобы человек сразу знал, куда нажать»).
///   Раньше первым на листе стояли путь к exe, «STATUS / LAST RUN / GRAPHICS» и строка
///   движка «DirectX 11 · 64-bit · Experimental», а «Run» был мелкой кнопкой в углу.
///   Теперь сверху — обложка, название, состояние одной фразой и большая «Играть».
///   Всё техническое осталось, но свёрнуто в «Технические подробности»: оно нужно
///   для разбора отказа, а не для того, чтобы поиграть.
struct AppDetailSheet: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    let app: AppEntry
    let isRunning: Bool
    var launchProgress: LaunchProgress? = nil
    let onRun: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onClose: () -> Void

    @State private var showDetails = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                cover
                VStack(alignment: .leading, spacing: Theme.Spacing.m) {
                    Text(app.name)
                        .font(.system(size: 26, weight: .semibold))
                        .kerning(-0.5)
                        .foregroundColor(Theme.Palette.textPrimary(scheme))
                        .lineLimit(2)
                    statusLine
                    runningGuidance
                    failureBlock
                    Spacer(minLength: Theme.Spacing.m)
                    actions
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            }
            // Высота листа постоянна: подсказка при запуске и причина отказа появляются
            // и исчезают, а рост листа на macOS сдвигает содержимое (см. `details`).
            .frame(height: 240)
            .padding(Theme.Spacing.xl)
            .overlay(alignment: .topTrailing) { closeButton.padding(Theme.Spacing.l) }

            Divider().background(Theme.Palette.separator(scheme))
            details
        }
        .frame(width: 640)
        .background(Theme.Palette.bgPrimary(scheme))
        // ★★★ ВЫДЕЛЕНИЕ СТАВИМ НА КАЖДОМ ЛИСТЕ ОТДЕЛЬНО: модификатор в корне `ContentView`
        //   в листы не проникает (измерено 12.09.2026).
        .textSelection(.enabled)
    }

    // MARK: - Верх

    private var cover: some View {
        GameArtworkView(app: app) {
            ExeArtFallback(app: app, iconScale: 0.46)
        }
        .frame(width: 160, height: 240)
        .clipShape(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .stroke(Theme.Palette.border(scheme), lineWidth: 0.5))
    }

    private var statusLine: some View {
        let status = GameStatus.of(app, isRunning: isRunning, progress: launchProgress)
        return HStack(spacing: Theme.Spacing.s) {
            Text(status.text)
                .font(Theme.Font.body)
                .foregroundColor(status.color(scheme))
                .lineLimit(2)
            if let confirmed = GameStatus.confirmed(app) {
                // История наших прогонов: на какой сборке — в подробностях.
                Text("\(confirmed.reached.title) · \(confirmed.date)")
                    .font(Theme.Font.caption)
                    .foregroundColor(GameStatus(text: "", tone: .good).color(scheme))
                    .padding(.vertical, 3)
                    .padding(.horizontal, 9)
                    .background(Capsule().stroke(GameStatus(text: "", tone: .good).color(scheme).opacity(0.5), lineWidth: 0.75))
                    .help(confirmed.displayEngine ?? confirmed.engine)
            }
        }
    }

    @ViewBuilder
    private var runningGuidance: some View {
        if let progress = launchProgress {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let guidance = progress.guidance(at: context.date) {
                    Text(guidance)
                        .font(Theme.Font.caption)
                        .foregroundColor(Theme.Palette.textSecondary(scheme))
                        .lineLimit(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    /// Почему не запустилась — заголовком на языке человека; дословная улика движка — ниже,
    /// мелко: по ней ищут поломку и пишут в поддержку, поэтому она не переводится.
    @ViewBuilder
    private var failureBlock: some View {
        if !isRunning, RunFailure.isFailure(status: app.lastRunStatus),
           let detail = app.lastRunError, !detail.isEmpty {
            Text(detail)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
                .lineLimit(3)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var actions: some View {
        HStack(spacing: Theme.Spacing.m) {
            PlayButton(isRunning: isRunning, large: true, action: onRun)
                .keyboardShortcut(.return, modifiers: [])
            Button {
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app.exePath)])
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "folder").font(.system(size: 12))
                    Text(L("Game folder"))
                }
            }
            .buttonStyle(.minimalSecondary)
            Menu {
                Button(L("Edit"), action: onEdit)
                Divider()
                Button(L("Remove") + "…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(Theme.Palette.textSecondary(scheme))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help(L("More"))
            .accessibilityLabel(L("More"))
        }
    }

    private var closeButton: some View {
        Button(action: onClose) {
            Image(systemName: "xmark")
                .font(.system(size: 11, weight: .medium))
                .foregroundColor(Theme.Palette.textSecondary(scheme))
                .frame(width: 28, height: 28)
                .background(Circle().stroke(Theme.Palette.border(scheme), lineWidth: 0.5))
        }
        .buttonStyle(.scalePress)
        .keyboardShortcut(.escape, modifiers: [])
        .accessibilityLabel(L("Close"))
    }

    // MARK: - Технические подробности

    /// ★★★ ВСПЛЫВАЮЩЕЕ ОКНО, А НЕ РАСКРЫВАЮЩИЙСЯ БЛОК (23.09.2026). Раскрытие внутри листа
    ///   меняет его высоту, а macOS растит лист от центра и НЕ передвигает содержимое:
    ///   название уезжало за верхний край, снизу оставалась пустая полоса (снято на экране).
    ///   Всплывающее окно измеряется один раз при показе — лист своего размера не меняет.
    private var details: some View {
        HStack {
            Button { showDetails.toggle() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle").font(.system(size: 12))
                    Text(L("Technical details"))
                }
                .font(Theme.Font.bodyEmph)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .popover(isPresented: $showDetails, arrowEdge: .top) { GameTechnicalDetails(app: app) }
            Spacer()
        }
        .padding(.horizontal, Theme.Spacing.xl)
        .padding(.vertical, Theme.Spacing.l)
    }
}

/// Технические подробности игры — одни для листа и для страницы игры в окне.
struct GameTechnicalDetails: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    let app: AppEntry

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.m) {
            detailRow(L("File"), app.exePath, mono: true)
            if BundledEngine.current != nil {
                detailRow(L("GRAPHICS"), [app.graphicsAPI.flatMap(GraphicsAPI.init(rawValue:))?.title ?? L("Auto"),
                                           app.lastGraphicsSummary.map { loc.relocalize($0) }].compactMap { $0 }.joined(separator: " — "))
            }
            if let ms = app.lastDurationMs {
                detailRow(L("LAST RUN"), Self.durationText(ms))
            }
            if let known = GraphicsProfile.match(exe: URL(fileURLWithPath: app.exePath), in: GraphicsProfile.bundled)?.known,
               !known.isEmpty {
                detailRow(L("EARLIER RESULTS"), known.map {
                    "\($0.date) · \($0.reached.title) — " + [$0.displayEngine ?? $0.engine, $0.note.map(L)].compactMap { $0 }.joined(separator: ", ")
                }.joined(separator: "\n"))
            }
            if RunFailure.isFailure(status: app.lastRunStatus), let headline = RunFailure.headline(status: app.lastRunStatus) {
                detailRow(L("WHY IT DID NOT RUN"), [headline, app.lastRunError].compactMap { $0 }.joined(separator: "\n"), mono: true)
            }
            if let notes = app.notes, !notes.isEmpty {
                detailRow(L("NOTES"), notes)
            }
        }
        .padding(Theme.Spacing.l)
        .frame(width: 480, alignment: .leading)
        // Всплывающее окно — отдельное окно: выделение листа сюда не проникает, а системная
        // подложка у неактивного окна светлая — наш светлый текст на ней не читался (снято).
        .textSelection(.enabled)
        .presentationBackground(Theme.Palette.bgElevated(scheme))
    }

    private func detailRow(_ label: String, _ value: String, mono: Bool = false) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(Theme.Font.monoCaption)
                .foregroundColor(Theme.Palette.textTertiary(scheme))
                .kerning(1)
            Text(value)
                .font(mono ? Theme.Font.mono : Theme.Font.body)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
                .lineLimit(12)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    static func durationText(_ ms: Int) -> String {
        if ms < 1000 { return String(format: L("%d ms"), ms) }
        let s = Double(ms) / 1000.0
        if s < 60 { return String(format: L("%.1f s"), s) }
        return String(format: L("%d m %d s"), Int(s) / 60, Int(s) % 60)
    }
}
