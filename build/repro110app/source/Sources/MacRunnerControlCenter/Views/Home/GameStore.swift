import SwiftUI

/// Магазин игр.
///
/// ★ 12.09.2026 магазины УБРАНЫ из витрины игрока и живут в режиме разработчика.
///   Причина простая: пока список купленного не тянется ни из одного магазина,
///   строка «Войти» обещает человеку то, чего за ней нет. Витрина игрока —
///   библиотека и настройки, всё остальное показываем, когда оно работает.
///
/// Значок — в РОДНЫХ цветах: во всём интерфейсе цвета нет, и знаки остаются
/// единственным цветным пятном, поэтому и различаются с одного взгляда.
enum GameStore: String, CaseIterable, Identifiable {
    // ★ Amazon убран 12.09.2026 по решению владельца: у Amazon Games каталог —
    //   это раздача Prime Gaming, несколько игр в месяц по подписке, и связи с ним
    //   у нас всё равно нет. Место в панели он занимал, пользы не давал.
    case epic, gog, steam, battlenet, itch

    var id: String { rawValue }

    var title: String {
        switch self {
        case .epic: return "Epic Games"
        case .gog: return "GOG"
        case .steam: return "Steam"
        case .battlenet: return "Battle.net"
        case .itch: return "itch.io"
        }
    }

    /// Вход устроен по-разному, и это НЕ наша прихоть, а устройство магазинов.
    enum SignInKind {
        /// Вход на сайте магазина, токен у нас, игры запускаются из нашего окна.
        /// Так у Epic и GOG — и так же сделано у Heroic и Mythic.
        case tokenInOurWindow
        /// Защита требует работающий клиент магазина; его и открываем.
        /// Steam иначе не даёт запустить игру, обойти это нечем.
        case ownClient
    }

    var signInKind: SignInKind {
        switch self {
        case .epic, .gog, .itch: return .tokenInOurWindow
        case .steam, .battlenet: return .ownClient
        }
    }
}
