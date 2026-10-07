import SwiftUI

/// Магазины — панель режима разработчика.
///
/// ★ Здесь, а не в витрине игрока, потому что работает пока один GOG, и то
///   только вход. Строка «Войти», за которой не появляется ни одной игры,
///   обманывает — а обманывать мы не будем даже мелочью.
///
/// Каждой строке честно приписано, ЧЕМ она кончится: у Epic/GOG/itch — токен
/// и игры в нашем окне, у Steam/Battle.net — их собственный клиент, потому что
/// защита иначе не даёт запустить игру. Это устройство магазинов, не наш выбор.
struct StoresPane: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared
    @ObservedObject private var connections = StoreConnections.shared
    @State private var signingIn: GameStore?

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.Spacing.l) {
            Text(L("Sign in happens on the store’s own page. We keep only a token."))
                .font(Theme.Font.body)
                .foregroundColor(Theme.Palette.textSecondary(scheme))

            VStack(spacing: Theme.Spacing.s) {
                ForEach(GameStore.allCases) { store in
                    row(store)
                }
            }

            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .sheet(item: $signingIn) { store in
            StoreSignInSheet(
                store: store,
                onFinished: { signingIn = nil },
                onClose: { signingIn = nil }
            )
        }
    }

    private func row(_ store: GameStore) -> some View {
        let connected = connections.connected.contains(store)
        return HStack(spacing: Theme.Spacing.m) {
            StoreBadge(store: store)
                .frame(width: 26, height: 26)
                .opacity(connected ? 1 : 0.55)
                .saturation(connected ? 1 : 0.3)

            VStack(alignment: .leading, spacing: 2) {
                Text(store.title)
                    .font(Theme.Font.bodyEmph)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                Text(kindNote(store))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Palette.textTertiary(scheme))
            }

            Spacer(minLength: Theme.Spacing.s)

            if connected {
                Text(L("Connected"))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Palette.textSecondary(scheme))
                Button(L("Disconnect")) { connections.disconnect(store) }
                    .buttonStyle(.minimalGhost)
            } else {
                Button(L("Sign in")) { signingIn = store }
                    .buttonStyle(.minimalSecondary)
            }
        }
        .padding(Theme.Spacing.m)
        .background(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .fill(Theme.Palette.bgSecondary(scheme))
        )
        .overlay(
            RoundedRectangle(cornerRadius: Theme.Radius.medium, style: .continuous)
                .stroke(Theme.Palette.border(scheme), lineWidth: 0.5)
        )
    }

    private func kindNote(_ store: GameStore) -> String {
        switch store.signInKind {
        case .tokenInOurWindow: return L("Token only — games run in our window")
        case .ownClient: return L("Needs the store’s own client running")
        }
    }
}

/// Программы — панель режима разработчика.
struct ProgramsPane: View {
    @ObservedObject private var loc = Localization.shared
    @State private var category: ProgramCategory?
    @State private var search = ""
    @State private var detail: Program?

    var body: some View {
        ProgramsView(search: search, category: $category, onOpen: { detail = $0 })
            .sheet(item: $detail) { program in
                ProgramDetailSheet(program: program, onClose: { detail = nil })
            }
    }
}
