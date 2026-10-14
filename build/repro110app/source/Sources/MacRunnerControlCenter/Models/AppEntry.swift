import Foundation

struct AppEntry: Codable, Sendable, Identifiable, Hashable {
    var id: UUID
    var name: String
    var exePath: String
    var arch: String?
    var args: [String]?
    var env: [String: String]?
    var workdir: String?
    var d3dBackend: String
    var timeout: Int?
    var tags: [String]?
    var createdAt: Date
    var updatedAt: Date
    var lastRunStatus: String?
    var lastDurationMs: Int?
    var notes: String?
    /// Причина последнего отказа — текст САМОГО движка («file missing or unreadable»,
    /// последняя строка stderr), без перевода. Заголовок на языке человека строится
    /// из `lastRunStatus` при показе (`RunFailure.headline`), а здесь — улика.
    /// ★ Значение по умолчанию обязательно: старые записи библиотеки этого поля
    ///   не знают, и без него разбор JSON сломал бы всю библиотеку разом.
    var lastRunError: String? = nil
    /// Графика: nil — «Авто» (по файлам игры и профилю), иначе API, заданный вручную
    /// (`GraphicsAPI.rawValue`) — настройка разработчика и профиля, игроку DLL не нужны.
    var graphicsAPI: String? = nil
    /// Итог выбора графики последнего запуска («DirectX 11 · 64-bit · …») — для карточки.
    var lastGraphicsSummary: String? = nil

    static func new(name: String, exePath: String) -> AppEntry {
        AppEntry(
            id: UUID(),
            name: name,
            exePath: exePath,
            arch: nil,
            args: [],
            env: [:],
            workdir: nil,
            d3dBackend: "none",
            timeout: 45,
            tags: [],
            createdAt: Date(),
            updatedAt: Date(),
            lastRunStatus: nil,
            lastDurationMs: nil,
            notes: nil
        )
    }
}
