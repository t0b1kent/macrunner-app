import Foundation

/// Счётчик FPS — системный Metal Performance HUD от Apple поверх игры.
///
/// ★ Владелец, 23.09.2026: «стандартную галочку, чтобы включать Apple HUD для проверки
///   FPS». Свой счётчик не рисуем: у Apple он уже есть и включается переменной окружения
///   `MTL_HUD_ENABLED=1` при старте процесса — так же это сделано в CrossOver и Whisky.
///
/// ★ Действует со СЛЕДУЮЩЕГО запуска: переменную Metal читает один раз, когда процесс
///   создаёт устройство. Переключение во время игры ничего не меняет — это сказано
///   в подписи переключателя.
///
/// Границы: HUD рисуется на слое Metal. Игры через DXMT (DirectX 10/11) идут через Metal
/// и его показывают; путь OpenGL — на усмотрение системы, это не проверено.
enum PerformanceHUD {
    static let defaultsKey = "macrunner.metalHUD"

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: defaultsKey) }

    /// Окружение запуска: переключатель + собственные переменные записи игры.
    /// Переменные игры ГЛАВНЕЕ: `MTL_HUD_ENABLED=0` у одной игры выключает счётчик
    /// только для неё, даже когда общий переключатель включён.
    static func launchEnvironment(appEnvironment: [String: String], enabled: Bool = isEnabled) -> [String: String] {
        let hud: [String: String] = enabled ? ["MTL_HUD_ENABLED": "1"] : [:]
        return hud.merging(appEnvironment) { _, own in own }
    }
}
