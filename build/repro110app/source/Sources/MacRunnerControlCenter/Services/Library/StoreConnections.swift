import Foundation
import SwiftUI

/// Какие магазины подключены.
///
/// ★ Истина — НАЛИЧИЕ ТОКЕНА в связке ключей, а не галочка в настройках. Иначе после
///   чистки ключей или выхода из аккаунта интерфейс продолжал бы показывать
///   «подключено», а библиотека не грузилась бы — и разбираться пришлось бы вслепую.
///
/// ★ И отдельно честность: у магазинов, где вход ещё не сделан, кнопка не должна
///   притворяться рабочей. `isImplemented` отделяет «не вошёл» от «мы ещё не умеем».
@MainActor
final class StoreConnections: ObservableObject {
    static let shared = StoreConnections()

    @Published private(set) var connected: Set<GameStore> = []

    /// Магазины, для которых вход доведён до конца. Остальные видны в панели,
    /// но нажатие честно говорит, что подключения пока нет.
    static let implemented: Set<GameStore> = [.gog]

    private init() { refresh() }

    func isImplemented(_ store: GameStore) -> Bool { Self.implemented.contains(store) }

    func refresh() {
        var found: Set<GameStore> = []
        if GOGTokenStore().hasTokens { found.insert(.gog) }
        connected = found
    }

    func disconnect(_ store: GameStore) {
        switch store {
        case .gog: try? GOGTokenStore().delete()
        default: break
        }
        refresh()
    }
}
