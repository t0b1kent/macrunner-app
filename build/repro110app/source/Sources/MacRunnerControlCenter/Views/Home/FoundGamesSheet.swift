import SwiftUI

/// После установщика: что он поставил, и что из этого положить в библиотеку.
///
/// ★ Предлагаем, а не кладём сами: у игры бывает несколько `.exe` (сама игра,
///   редактор, лаунчер), и какой из них нужен человеку — решать ему. Отмечен
///   заранее самый крупный файл в каждой папке установки: обычно это игра.
struct FoundGamesSheet: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared

    let installerName: String
    let games: [FoundGame]
    let onAdd: ([FoundGame]) -> Void
    let onCancel: () -> Void

    @State private var selected: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().background(Theme.Palette.separator(scheme))
            VStack(alignment: .leading, spacing: Theme.Spacing.l) {
                Text(L("Choose what to add to your library."))
                    .font(Theme.Font.body)
                    .foregroundColor(Theme.Palette.textSecondary(scheme))
                ScrollView {
                    VStack(alignment: .leading, spacing: Theme.Spacing.s) {
                        ForEach(games) { game in row(game) }
                    }
                }
                .frame(maxHeight: 320)
                HStack(spacing: Theme.Spacing.m) {
                    Button(L("Add to library")) {
                        onAdd(games.filter { selected.contains($0.id) })
                    }
                    .buttonStyle(.minimalPrimary)
                    .disabled(selected.isEmpty)
                    .keyboardShortcut(.defaultAction)
                    Button(L("Not now"), action: onCancel)
                        .buttonStyle(.minimalSecondary)
                }
            }
            .padding(Theme.Spacing.xl)
        }
        .frame(width: 560)
        .background(Theme.Palette.bgPrimary(scheme))
        .onAppear { selected = Set(games.filter(\.suggested).map(\.id)) }
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            Image(systemName: "checkmark.seal")
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Theme.Palette.textSecondary(scheme))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 1) {
                Text(L("Installation finished"))
                    .font(Theme.Font.heading)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                Text(installerName)
                    .font(Theme.Font.monoCaption)
                    .foregroundColor(Theme.Palette.textTertiary(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
            Button(L("Cancel"), action: onCancel)
                .buttonStyle(.minimalGhost)
                .keyboardShortcut(.cancelAction)
        }
        .padding(Theme.Spacing.l)
    }

    private func row(_ game: FoundGame) -> some View {
        let isOn = Binding(
            get: { selected.contains(game.id) },
            set: { if $0 { selected.insert(game.id) } else { selected.remove(game.id) } }
        )
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(game.name)
                        .font(Theme.Font.bodyEmph)
                        .foregroundColor(Theme.Palette.textPrimary(scheme))
                    Text(ByteCountFormatter.string(fromByteCount: game.size, countStyle: .file))
                        .font(Theme.Font.monoCaption)
                        .foregroundColor(Theme.Palette.textTertiary(scheme))
                }
                Text(game.url.lastPathComponent)
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Palette.textSecondary(scheme))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(game.url.path)
            }
        }
        .toggleStyle(.checkbox)
        .padding(Theme.Spacing.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: Theme.Radius.large, style: .continuous)
            .fill(Theme.Palette.bgSecondary(scheme)))
    }
}
