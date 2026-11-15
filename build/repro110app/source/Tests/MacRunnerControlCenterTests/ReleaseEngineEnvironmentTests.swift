import Foundation
import Testing
@testable import MacRunnerControlCenter

@Suite struct ReleaseEngineEnvironmentTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APP32_ENGINE_ROOT"] != nil))
    func explicitSilenceCoversPreparationAndCannotBeUndoneByTheGame() throws {
        let root = try #require(ProcessInfo.processInfo.environment["APP32_ENGINE_ROOT"])
        let engine = try #require(BundledEngine.load(from: URL(fileURLWithPath: root)))
        let prefix = FileManager.default.temporaryDirectory.appendingPathComponent("silent-environment-\(UUID().uuidString)")
        let launcher = EngineLauncher(engine: engine, prefix: prefix)
        let requested = ["MACRUNNER_AUDIO_SILENT_OUTPUT": "1"]
        #expect(launcher.makeEnvironment(extra: [:], inherited: requested)["MACRUNNER_AUDIO_SILENT_OUTPUT"] == "1")
        #expect(launcher.makeEnvironment(extra: ["MACRUNNER_AUDIO_SILENT_OUTPUT": "0"], inherited: requested)["MACRUNNER_AUDIO_SILENT_OUTPUT"] == "1")
        #expect(launcher.makeEnvironment(extra: [:], inherited: [:])["MACRUNNER_AUDIO_SILENT_OUTPUT"] == engine.environmentTemplate["MACRUNNER_AUDIO_SILENT_OUTPUT"])
        #expect(launcher.makeEnvironment(extra: ["MACRUNNER_AUDIO_SILENT_OUTPUT": "1"], inherited: [:])["MACRUNNER_AUDIO_SILENT_OUTPUT"] == "1")
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["APP32_ENGINE_ROOT"] != nil))
    func eldenRingUsesAcceptedEngineCPUSettings() throws {
        let root = try #require(ProcessInfo.processInfo.environment["APP32_ENGINE_ROOT"])
        let engine = try #require(BundledEngine.load(from: URL(fileURLWithPath: root)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("release-er-profile-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("eldenring.exe")
        try FakePE.make(machine: 0x8664, imports: ["d3d12.dll"]).write(to: executable)
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: executable), engine: engine)
        #expect(plan.decision == .launch)
        #expect(plan.api == .d3d12)
        let actual = EngineLauncher(engine: engine, prefix: directory.appendingPathComponent("prefix"))
            .makeEnvironment(extra: plan.environment)
        for key in ["MACRUNNER_FEX_WRITABLE_VALIDATION", "MACRUNNER_FEX_RANGE_CACHE",
                    "MACRUNNER_FEX_CODEBUF_MAX", "MACRUNNER_FEX_MONO_BP_PRECISE"] {
            #expect(actual[key] == engine.environmentTemplate[key], "Stale game profile overrides accepted ENGINE: \(key)")
        }
    }
}
