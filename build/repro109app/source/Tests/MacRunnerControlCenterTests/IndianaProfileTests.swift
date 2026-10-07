import Foundation
import Testing
@testable import MacRunnerControlCenter

struct IndianaProfileTests {
    @Test func profileHasFunctionalSettingsWithoutCaptureOrHUD() throws {
        let profile = try #require(GraphicsProfile.bundled.first { $0.id == "indiana-jones-great-circle" })
        #expect(profile.exe == ["TheGreatCircle.exe"])
        #expect(profile.apis == [.vulkan])
        #expect(profile.environment?["MVK_CONFIG_ENABLE_EXPERIMENTAL_RAY_TRACING"] == "1")
        #expect(profile.environment?["MACRUNNER_MVK_SPARSE_FULL_BACKING"] == "1")
        for key in ["WINEDEBUG", "MTL_HUD_ENABLED", "MACRUNNER_MVK_RT_NULL_GUARD",
                    "MACRUNNER_MVK_DYNSTRIDE_ROUND", "MACRUNNER_MVK_CB_ENCODER_STATUS",
                    "MACRUNNER_MVK_VERTEX_TRACE", "MACRUNNER_MVK_CAS64_CAPTURE_DIR"] {
            #expect(profile.environment?[key] == nil)
        }
    }

    @Test func vulkanPathsFollowRelocatedEngineAndMissingDriverRefuses() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("Indiana relocated \(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let layer = GraphicsLayer(id: "moltenvk", title: "MoltenVK", modules: [:],
                                  unix: ["vulkan/libMoltenVK.dylib", "vulkan/MoltenVK_icd.json"],
                                  environment: ["CX_ACTIVE_GRAPHICS_BACKEND": "wined3d",
                                                "CX_LIBVULKAN": "${ENGINE}/vulkan/libMoltenVK.dylib",
                                                "VK_ICD_FILENAMES": "${ENGINE}/vulkan/MoltenVK_icd.json"])
        var engine = BundledEngine(root: root, name: "fixture", environmentTemplate: [:])
        engine.graphics = GraphicsCatalog(layers: [layer], routes: [
            GraphicsRoute(api: .vulkan, arch: .x86_64, layer: layer.id, status: .experimental, evidence: "fixture")
        ])
        let profile = try #require(GraphicsProfile.bundled.first { $0.id == "indiana-jones-great-circle" })
        var detection = GraphicsDetection()
        detection.arch = .x86_64
        detection.evidence = [.init(api: .vulkan, strength: .profile, source: "bundled profile")]
        detection.profile = profile
        let plan = GraphicsSelector.plan(detection: detection, engine: engine)
        #expect(plan.decision == .launch)
        #expect(plan.environment["CX_LIBVULKAN"] == root.path + "/vulkan/libMoltenVK.dylib")
        #expect(plan.environment["VK_ICD_FILENAMES"] == root.path + "/vulkan/MoltenVK_icd.json")
        #expect(plan.environment["FEX_HOSTFEATURES"] == "enablecrypto")
        engine.incompleteLayers[layer.id] = ["vulkan/libMoltenVK.dylib"]
        let missing = GraphicsSelector.plan(detection: detection, engine: engine)
        if case .refuse = missing.decision {} else { Issue.record("Missing MoltenVK must refuse launch") }
        #expect(missing.environment.isEmpty)
    }

    @Test func perGameHUDSurvivesLibraryRoundTrip() throws {
        var app = AppEntry.new(name: "Indiana Jones", exePath: "/game/TheGreatCircle.exe")
        app.env = ["MTL_HUD_ENABLED": "0", "CUSTOM": "preserved"]
        let restored = try JSONDecoder().decode(AppEntry.self, from: JSONEncoder().encode(app))
        #expect(PerformanceHUD.launchEnvironment(appEnvironment: restored.env ?? [:], enabled: true)
            == ["MTL_HUD_ENABLED": "0", "CUSTOM": "preserved"])
        app.env?["MTL_HUD_ENABLED"] = "1"
        #expect(PerformanceHUD.launchEnvironment(appEnvironment: app.env ?? [:], enabled: false)["MTL_HUD_ENABLED"] == "1")
    }
}
