import SwiftUI
import WebKit

enum StoreAuthError: LocalizedError {
    case noCode
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noCode: return L("The store did not return a sign-in code")
        case .cancelled: return L("Sign-in cancelled")
        }
    }
}

/// Ход загрузки страницы входа.
///
/// ★ Нужен потому, что белый прямоугольник неотличим от поломки. 12.09.2026 окно
///   входа GOG выглядело сломанным, а зонд показал: страница грузится нормально
///   («Login ● GOG.com», состояние complete) — не хватало ровно того, чтобы окно
///   сказало «гружу».
enum StoreAuthProgress: Equatable {
    case loading(String)
    case ready(String)
    case failed(String)

    var isLoading: Bool { if case .loading = self { return true }; return false }
}

/// Окно входа в магазин.
///
/// ★★★ ПАРОЛЬ ЧЕРЕЗ НАС НЕ ПРОХОДИТ НИКОГДА. Мы показываем СОБСТВЕННУЮ страницу
///   магазина и ждём, когда он сам перебросит на условленный адрес возврата —
///   оттуда забираем одноразовый код. Своей формы для логина и пароля в приложении
///   нет и не будет: человек вводит их на странице магазина, как в браузере.
///
/// Так устроен вход у Heroic и у GameHub. Разница только в том, что они встраивают
/// свой веб-вид, а мы — тот же приём средствами системы.
struct StoreAuthWebView: NSViewRepresentable {
    /// Страница входа магазина.
    let startURL: URL
    /// Адрес возврата узнаём по началу строки: магазин допишет к нему свои параметры.
    let redirectPrefix: String
    /// Имя параметра, в котором приедет одноразовый код.
    let codeParameter: String
    let onCode: (String) -> Void
    let onFailure: (Error) -> Void
    /// Куда доехала загрузка. Без этого окно молчит и выглядит белым листом.
    let onProgress: (StoreAuthProgress) -> Void

    func makeNSView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        // Непостоянное хранилище: куки магазина не оседают в системе, а чужие
        // сюда не попадают. После закрытия окна от входа не остаётся следов.
        config.websiteDataStore = .nonPersistent()
        config.preferences.javaScriptCanOpenWindowsAutomatically = true
        let view = WKWebView(frame: .zero, configuration: config)
        view.navigationDelegate = context.coordinator
        // ★★★ БЕЗ ЭТОГО ВХОД ЧЕРЕЗ GOOGLE И ПРОЧИХ ПРОСТО НЕ РАБОТАЕТ.
        //   Измерено 12.09.2026: у GOG кнопки Google, Steam, Discord и Xbox — ссылки
        //   с `target="Login"`, то есть всплывающее окно. WKWebView без обработчика
        //   таких окон не делает НИЧЕГО, и снаружи это выглядит как зависание.
        view.uiDelegate = context.coordinator
        view.load(URLRequest(url: startURL))
        return view
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
        private let parent: StoreAuthWebView
        /// Ответ отдаём РОВНО ОДИН раз: магазин может дёрнуть переход повторно,
        /// и без замка обмен кода на токен пошёл бы дважды.
        private var finished = false

        init(_ parent: StoreAuthWebView) { self.parent = parent }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard !finished,
                  let url = navigationAction.request.url,
                  url.absoluteString.hasPrefix(parent.redirectPrefix)
            else {
                decisionHandler(.allow)
                return
            }

            let code = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first { $0.name == parent.codeParameter }?
                .value

            finished = true
            decisionHandler(.cancel)

            if let code, !code.isEmpty {
                parent.onCode(code)
            } else {
                parent.onFailure(StoreAuthError.noCode)
            }
        }

        /// Всплывающее окно. Отдельного окна мы не заводим — грузим в том же виде:
        /// человеку важно попасть на страницу входа, а не получить второе окно.
        /// Возврат `nil` обязателен: иначе WebKit ждёт от нас настоящий вид.
        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            if let url = navigationAction.request.url {
                webView.load(URLRequest(url: url))
            }
            return nil
        }

        func webView(
            _ webView: WKWebView,
            didStartProvisionalNavigation navigation: WKNavigation!
        ) {
            guard !finished else { return }
            parent.onProgress(.loading(webView.url?.host ?? ""))
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            guard !finished else { return }
            // Заголовок берём у самой страницы: он же служит доказательством, что
            // приехала именно страница магазина, а не пустой документ.
            webView.evaluateJavaScript("document.title") { value, _ in
                let title = (value as? String) ?? webView.url?.host ?? ""
                self.parent.onProgress(.ready(title))
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            guard !finished else { return }
            finished = true
            parent.onProgress(.failed(error.localizedDescription))
            parent.onFailure(error)
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            // Отменённый нами переход на адрес возврата приходит сюда же —
            // это не ошибка, код уже забран.
            guard !finished else { return }
            finished = true
            parent.onProgress(.failed(error.localizedDescription))
            parent.onFailure(error)
        }
    }
}
