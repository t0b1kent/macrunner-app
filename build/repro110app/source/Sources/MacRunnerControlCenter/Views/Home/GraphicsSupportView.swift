import SwiftUI

/// Что встроенный движок умеет в графике — честно, по матрице пакета.
///
/// ★ Ничего не вычисляем и не округляем: клетка показывает статус маршрута из ENGINE.json,
///   подсказка — его доказательство или причину отказа. «Экспериментально» не прячем за
///   «работает»: человек должен видеть то же, что видим мы.
struct GraphicsSupportView: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    let engine: BundledEngine

    private let rows: [GraphicsAPI] = [.d3d9, .d3d10, .d3d11, .d3d12, .d3d12RT, .opengl, .vulkan]
    private let columns: [GuestArch] = [.x86_64, .x86]

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.s) {
            Text(L("Graphics support"))
                .font(Theme.Font.bodyEmph)
                .foregroundColor(Theme.Palette.textPrimary(scheme))
            Text(L("The game chooses its graphics API; MacRunner picks the matching engine parts automatically."))
                .font(Theme.Font.caption)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
                .fixedSize(horizontal: false, vertical: true)
            Grid(alignment: .leading, horizontalSpacing: Theme.Spacing.m, verticalSpacing: 6) {
                GridRow {
                    Text("")
                    ForEach(columns, id: \.self) { arch in
                        Text(arch.title)
                            .font(Theme.Font.monoCaption)
                            .foregroundColor(Theme.Palette.textTertiary(scheme))
                            .help(engine.graphics.architecture(arch)?.evidence ?? "")
                    }
                }
                ForEach(rows, id: \.self) { api in
                    GridRow {
                        Text(api.title)
                            .font(Theme.Font.caption)
                            .foregroundColor(Theme.Palette.textPrimary(scheme))
                        ForEach(columns, id: \.self) { arch in cell(api: api, arch: arch) }
                    }
                }
            }
            Text(String(format: L("Engine: %@"), "FEX + Wine + DXMT"))
                .font(Theme.Font.monoCaption)
                .foregroundColor(Theme.Palette.textTertiary(scheme))
        }
        .padding(Theme.Spacing.l)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .fill(Theme.Palette.bgSecondary(scheme)))
    }

    /// Разрядность недоступна — недоступно всё в столбце, с её причиной.
    private func status(api: GraphicsAPI, arch: GuestArch) -> (RouteStatus, String?) {
        if let support = engine.graphics.architecture(arch), !support.status.canLaunch {
            return (support.status, support.evidence)
        }
        guard let route = engine.graphics.route(api: api, arch: arch) else { return (.unavailable, nil) }
        if engine.incompleteLayers[route.layer ?? ""] != nil { return (.unavailable, L("The engine package is incomplete.")) }
        return (route.status, route.evidence)
    }

    private func cell(api: GraphicsAPI, arch: GuestArch) -> some View {
        let (status, evidence) = status(api: api, arch: arch)
        return HStack(spacing: 5) {
            Circle().fill(color(status)).frame(width: 7, height: 7)
            Text(status.title)
                .font(Theme.Font.caption)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
        }
        .help(evidence ?? "")
    }

    private func color(_ status: RouteStatus) -> Color {
        switch status {
        case .verified: return .green
        case .fixtures: return .teal
        case .experimental: return .orange
        case .unavailable, .deferred: return Theme.Palette.textTertiary(scheme)
        }
    }
}
