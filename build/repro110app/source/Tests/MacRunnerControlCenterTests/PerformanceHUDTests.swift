import Testing
@testable import MacRunnerControlCenter

/// Счётчик FPS: переключатель в настройках добавляет `MTL_HUD_ENABLED=1` в окружение
/// запуска, а переменные самой игры главнее переключателя.
struct PerformanceHUDTests {
    @Test func offAddsNothing() {
        #expect(PerformanceHUD.launchEnvironment(appEnvironment: [:], enabled: false).isEmpty)
        #expect(PerformanceHUD.launchEnvironment(appEnvironment: ["A": "1"], enabled: false) == ["A": "1"])
    }

    @Test func onAddsMetalHUD() {
        let env = PerformanceHUD.launchEnvironment(appEnvironment: ["A": "1"], enabled: true)
        #expect(env == ["A": "1", "MTL_HUD_ENABLED": "1"])
    }

    /// Выключил счётчик у одной игры — общий переключатель его не включит обратно.
    @Test func gameSettingWins() {
        let env = PerformanceHUD.launchEnvironment(appEnvironment: ["MTL_HUD_ENABLED": "0"], enabled: true)
        #expect(env["MTL_HUD_ENABLED"] == "0")
    }
}
