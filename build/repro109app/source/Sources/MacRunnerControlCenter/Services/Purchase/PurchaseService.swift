import AppKit
import Foundation

struct PurchaseService {
    /// Страница тарифов. Все четыре тарифа продаются там, отдельной страницы
    /// «бессрочной» нет.
    static let pricingURL = URL(string: "https://macrunner.app/pricing")!

    /// ★ Раньше без `MACRUNNER_PURCHASE_URL` адрес был nil, и кнопка покупки
    ///   МОЛЧА ничего не делала — у человека, пришедшего платить. Переменная
    ///   осталась для проверок, но по умолчанию теперь настоящая страница цен.
    var lifetimeURL: URL = ProcessInfo.processInfo.environment["MACRUNNER_PURCHASE_URL"]
        .flatMap(URL.init(string:)) ?? PurchaseService.pricingURL

    /// ★ Пока лицензирование выключено (`ReleaseFlags`), покупать нечего, а страницы
    ///   `/pricing` на сайте нет. Сторож стоит ЗДЕСЬ, в единственной точке открытия
    ///   адреса, а не у кнопок: забытая кнопка на старом экране иначе вела бы в пустоту.
    @MainActor
    func openLifetimePurchase() {
        guard ReleaseFlags.licensingEnabled else { return }
        NSWorkspace.shared.open(lifetimeURL)
    }
}

#if canImport(StoreKit)
import StoreKit
@available(macOS 12.0, *)
struct StoreKitPurchasePlan {
    let productID = "app.macrunner.lifetime"
    func products() async throws -> [Product] { try await Product.products(for: [productID]) }
}
#endif
