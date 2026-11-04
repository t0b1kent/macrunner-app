import Foundation
@testable import MacRunnerControlCenter

/// Корень репозитория для тестов — от расположения этого файла, а не зашитым личным
/// путём: `AppSettings.defaultRoot` с 23.09.2026 пуст (код уходит в открытый репозиторий).
enum TestRoot {
    static let path: String = {
        if let root = ProcessInfo.processInfo.environment["MACRUNNER_TEST_WORKSPACE_ROOT"], !root.isEmpty {
            return root
        }
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }   // файл → Tests/… → app → корень
        return url.path
    }()

    static var settings: AppSettings {
        var settings = AppSettings.default
        settings.macRunnerRoot = path
        settings.artifactsDirectory = path + "/artifacts"
        settings.bottlesDirectory = path + "/bottles"
        return settings
    }
}
