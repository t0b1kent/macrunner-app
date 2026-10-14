import Foundation

struct AppSettings: Codable, Sendable {
    var macRunnerRoot: String
    var defaultTimeout: Int
    var defaultD3DBackend: String
    var keepArtifactsDefault: Bool
    var doctorTimeout: Int
    var integrationTimeout: Int
    var artifactsDirectory: String
    var bottlesDirectory: String
    var enableDebugLogs: Bool
    var enableMockMode: Bool
    var anthropicModelOverride: String? = nil
    var steamID64: String? = nil
    var languageOverride: String? = nil
    var updateChannel: String? = nil
    var hudHotkey: String? = nil
    var telemetryOptIn: Bool? = nil
    var communityFixSharingOptIn: Bool? = nil

    /// Корень репозитория — только для сборки разработчика; берётся из
    /// `MACRUNNER_ROOT`, иначе пуст и онбординг спросит папку. Выпускной сборке он
    /// не нужен вовсе (`BundledEngine`). Личный путь в исходнике держать нельзя:
    /// код уходит в открытый репозиторий.
    static let defaultRoot = ProcessInfo.processInfo.environment["MACRUNNER_ROOT"] ?? ""

    static let `default` = AppSettings(
        macRunnerRoot: defaultRoot,
        defaultTimeout: 45,
        defaultD3DBackend: "none",
        keepArtifactsDefault: false,
        doctorTimeout: 120,
        integrationTimeout: 300,
        artifactsDirectory: defaultRoot.isEmpty ? "" : "\(defaultRoot)/artifacts",
        bottlesDirectory: defaultRoot.isEmpty ? "" : "\(defaultRoot)/bottles",
        enableDebugLogs: false,
        enableMockMode: false
    )
}
