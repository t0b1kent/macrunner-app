import Foundation
import Testing
@testable import MacRunnerControlCenter

struct OnboardingTests {
    @Test @MainActor func defaultSettingsValid() {
        let s = AppSettings.default
        // Корень по умолчанию — из MACRUNNER_ROOT, иначе пуст: онбординг спросит папку,
        // а выпускной сборке со встроенным движком он не нужен.
        #expect(s.macRunnerRoot == (ProcessInfo.processInfo.environment["MACRUNNER_ROOT"] ?? ""))
    }

    @Test @MainActor func settingsPersistAfterOnboardingSimulation() {
        let store = ConfigStore.shared
        let original = store.loadSettings()
        let test = AppSettings(
            macRunnerRoot: "/tmp/onboarding-test",
            defaultTimeout: 60,
            defaultD3DBackend: "metal",
            keepArtifactsDefault: true,
            doctorTimeout: 90,
            integrationTimeout: 120,
            artifactsDirectory: "/tmp/artifacts",
            bottlesDirectory: "~/tmp/bottles",
            enableDebugLogs: false,
            enableMockMode: true
        )
        store.saveSettings(test)
        let loaded = store.loadSettings()
        #expect(loaded.defaultD3DBackend == "metal")
        store.saveSettings(original)
    }
}
