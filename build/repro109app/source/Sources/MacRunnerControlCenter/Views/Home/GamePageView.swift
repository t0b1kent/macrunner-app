import SwiftUI
import AppKit

/// Страница игры — в самом окне, а не отдельным листом.
///
/// ★★★ РЕДИЗАЙН 25.09.2026 (владелец: «3D-переходы, чтобы глаз радовался»; прототип одобрен).
///   Лист поднимался поверх окна и закрывал фон из игры. Теперь библиотека отступает вглубь,
///   а страница выплывает спереди: обложка разворачивается к зрителю, рядом крупное название,
///   состояние, большая «Играть» и короткие сведения. Всё техническое — по кнопке
///   «Технические подробности», как было на листе (`GameTechnicalDetails`).
struct GamePageView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    let app: AppEntry
    let isRunning: Bool
    var launchProgress: LaunchProgress? = nil
    let onRun: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onBack: () -> Void

    @State private var showDetails = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                Button(action: onBack) {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.left").font(.system(size: 11, weight: .bold))
                        Text(L("Library"))
                    }
                }
                .buttonStyle(.glassCapsule(height: 32))
                .keyboardShortcut(.escape, modifiers: [])
                .reveal(0.02)

                HStack(alignment: .top, spacing: 56) {
                    CoverStage(app: app, width: 232, restYaw: 12, entrance: true)
                        .padding(.top, 6)
                    info
                        .frame(maxWidth: 560, alignment: .leading)
                }
                .padding(.top, 30)
            }
            .padding(.horizontal, 48)
            .padding(.top, 6)
            .padding(.bottom, 48)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private var status: GameStatus {
        GameStatus.of(app, isRunning: isRunning, progress: launchProgress)
    }

    private var info: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let graphics = GraphicsLine.short(app, loc: loc) {
                Text(graphics.uppercased())
                    .font(.system(size: 11.5, weight: .semibold))
                    .kerning(1.8)
                    .foregroundColor(Theme.Palette.textSecondary(scheme))
                    .reveal(0.1)
            }
            Text(app.name)
                .font(.system(size: 58, weight: .regular, design: .serif))
                .kerning(-0.5)
                .foregroundColor(Theme.Palette.textPrimary(scheme))
                .lineLimit(3)
                .minimumScaleFactor(0.55)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 10)
                .reveal(0.14)

            HStack(spacing: Theme.Spacing.s) {
                StatusCapsule(status: status)
                if let confirmed = GameStatus.confirmed(app) {
                    // История наших прогонов: на какой сборке — в подсказке.
                    Text("\(confirmed.reached.title) · \(confirmed.date)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(Theme.Palette.textSecondary(scheme))
                        .padding(.horizontal, 10)
                        .frame(height: 24)
                        .glassCapsule()
                        .help(confirmed.displayEngine ?? confirmed.engine)
                }
            }
            .padding(.top, 18)
            .reveal(0.18)

            guidance.padding(.top, 12)

            actions
                .padding(.top, 26)
                .reveal(0.24)

            facts
                .padding(.top, 28)
                .reveal(0.3)
        }
    }

    /// Подсказка во время запуска и причина отказа — теми же словами, что на плитке.
    @ViewBuilder
    private var guidance: some View {
        if let progress = launchProgress {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                if let text = progress.guidance(at: context.date) {
                    Text(text)
                        .font(Theme.Font.body)
                        .foregroundColor(Theme.Palette.textSecondary(scheme))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if !isRunning, RunFailure.isFailure(status: app.lastRunStatus),
                  let detail = app.lastRunError, !detail.isEmpty {
            Text(detail)
                .font(Theme.Font.body)
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
                HStack(spacing: 7) {
                    Image(systemName: "folder").font(.system(size: 12.5))
                    Text(L("Game folder"))
                }
            }
            .buttonStyle(.glassCapsule)
            Menu {
                Button(L("Edit"), action: onEdit)
                Divider()
                Button(L("Remove") + "…", role: .destructive, action: onDelete)
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            // Стекло — снаружи меню: оформление внутри подписи меню macOS отбрасывает.
            .frame(width: 44, height: 44)
            .glassCapsule()
            .contentShape(Circle())
            .help(L("More"))
            .accessibilityLabel(L("More"))
        }
    }

    /// Коротко о главном — на стекле; всё остальное по кнопке «Технические подробности».
    private var facts: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            HStack(alignment: .top, spacing: Theme.Spacing.xl) {
                fact(L("STATUS"), status.text)
                if let graphics = GraphicsLine.short(app, loc: loc) { fact(L("GRAPHICS"), graphics) }
                if let ms = app.lastDurationMs { fact(L("LAST RUN"), GameTechnicalDetails.durationText(ms)) }
            }
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
            .popover(isPresented: $showDetails, arrowEdge: .bottom) { GameTechnicalDetails(app: app) }
        }
        .padding(.vertical, 18)
        .padding(.horizontal, 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glass(cornerRadius: 18)
    }

    private func fact(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label.uppercased())
                .font(.system(size: 10.5, weight: .semibold))
                .kerning(1.2)
                .foregroundColor(Theme.Palette.textTertiary(scheme))
            Text(value)
                .font(.system(size: 14.5, weight: .medium))
                .foregroundColor(Theme.Palette.textPrimary(scheme))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: 200, alignment: .leading)
    }
}
