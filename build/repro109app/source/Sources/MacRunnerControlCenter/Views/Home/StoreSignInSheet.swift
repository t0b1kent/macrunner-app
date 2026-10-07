import SwiftUI

/// Окно входа в магазин: сверху подпись, дальше страница самого магазина.
///
/// Никакой своей формы для логина и пароля здесь нет и не будет — человек вводит их
/// на странице магазина. Мы получаем только одноразовый код и сразу меняем его на токен.
struct StoreSignInSheet: View {
    @Environment(\.colorScheme) private var scheme
    @ObservedObject private var loc = Localization.shared

    let store: GameStore
    let onFinished: () -> Void
    let onClose: () -> Void

    @State private var failure: String?
    @State private var exchanging = false
    @State private var progress: StoreAuthProgress = .loading("")

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().background(Theme.Palette.separator(scheme))

            ZStack {
                if let url = authorizeURL {
                    StoreAuthWebView(
                        startURL: url,
                        redirectPrefix: GOGAuth.redirectPrefix,
                        codeParameter: GOGAuth.codeParameter,
                        onCode: exchange,
                        onFailure: { failure = $0.localizedDescription },
                        onProgress: { progress = $0 }
                    )
                } else {
                    unsupported
                }

                // ★ Показ загрузки — ТОЛЬКО когда есть что грузить. Без этой проверки
                //   у магазинов без входа крутилка висела вечно поверх объяснения:
                //   веб-вида нет, значит никто и никогда не сообщит, что загрузка кончилась.
                //   Поймано 12.09.2026 на Epic, Steam, Battle.net и itch.io разом.
                if authorizeURL != nil, progress.isLoading {
                    Theme.Palette.bgPrimary(scheme)
                    VStack(spacing: Theme.Spacing.m) {
                        ProgressView().controlSize(.large)
                        Text(L("Loading the store’s sign-in page…"))
                            .font(Theme.Font.body)
                            .foregroundColor(Theme.Palette.textSecondary(scheme))
                    }
                }

                if exchanging {
                    Color.black.opacity(0.55)
                    VStack(spacing: Theme.Spacing.m) {
                        ProgressView().controlSize(.large)
                        Text(L("Finishing sign-in…"))
                            .font(Theme.Font.body)
                            .foregroundColor(.white)
                    }
                }
            }

            // Нижняя строка состояния: видно, что именно загрузилось. Это же
            // доказательство, что приехала страница магазина, а не пустой документ.
            HStack(spacing: Theme.Spacing.s) {
                Text(failure ?? statusText)
                    .font(Theme.Font.caption)
                    .foregroundColor(failure == nil
                        ? Theme.Palette.textTertiary(scheme)
                        : Theme.Palette.textSecondary(scheme))
                    .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.Spacing.l)
            .padding(.vertical, Theme.Spacing.s)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.Palette.bgSecondary(scheme))
        }
        .frame(width: 720, height: 640)
        .background(Theme.Palette.bgPrimary(scheme))
        // ★★★ ВЫДЕЛЕНИЕ СТАВИМ НА КАЖДОМ ЛИСТЕ ОТДЕЛЬНО, А НЕ ТОЛЬКО В КОРНЕ.
        //   Измерено 12.09.2026: модификатор в корне `ContentView` в листы
        //   (`.sheet`) НЕ ПРОНИКАЕТ — лист поднимается в своём окне, и текст
        //   в нём остаётся невыделяемым. Сборка при этом была свежая, символы
        //   в двоичном на месте: сломан был не код, а моё допущение о наследовании.
        .textSelection(.enabled)
    }

    private var header: some View {
        HStack(spacing: Theme.Spacing.m) {
            StoreBadge(store: store).frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 1) {
                Text(String(format: L("Sign in to %@"), store.title))
                    .font(Theme.Font.heading)
                    .foregroundColor(Theme.Palette.textPrimary(scheme))
                Text(L("You sign in on the store’s own page. We never see your password."))
                    .font(Theme.Font.caption)
                    .foregroundColor(Theme.Palette.textTertiary(scheme))
            }
            Spacer(minLength: 0)
            Button(L("Cancel"), action: onClose)
                .buttonStyle(.minimalGhost)
                .keyboardShortcut(.cancelAction)
        }
        .padding(Theme.Spacing.l)
    }

    private var unsupported: some View {
        VStack(spacing: Theme.Spacing.m) {
            Image(systemName: "hourglass")
                .font(.system(size: 26, weight: .light))
                .foregroundColor(Theme.Palette.textTertiary(scheme))
            Text(L("Sign-in for this store is not ready yet"))
                .font(Theme.Font.heading)
                .foregroundColor(Theme.Palette.textPrimary(scheme))
            Text(L("Epic, Steam, Battle.net and itch.io are next."))
                .font(Theme.Font.body)
                .foregroundColor(Theme.Palette.textSecondary(scheme))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Palette.bgPrimary(scheme))
    }

    private var authorizeURL: URL? {
        store == .gog ? GOGAuth.authorizeURL : nil
    }

    private var statusText: String {
        // Нечего грузить — и строка состояния не должна утверждать обратное.
        guard authorizeURL != nil else { return L("GOG is connected first; the rest follow.") }
        switch progress {
        case .loading(let host): return host.isEmpty ? L("Loading…") : host
        case .ready(let title): return title
        case .failed(let text): return text
        }
    }

    /// Код живёт считанные секунды, поэтому меняем его сразу, не закрывая окна.
    private func exchange(code: String) {
        exchanging = true
        Task { @MainActor in
            do {
                _ = try await GOGAuthService().exchange(code: code)
                StoreConnections.shared.refresh()
                exchanging = false
                onFinished()
            } catch {
                exchanging = false
                failure = error.localizedDescription
            }
        }
    }
}
