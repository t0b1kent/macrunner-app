import Foundation
import Testing
@testable import MacRunnerControlCenter

struct APP32RoutingTests {
    @Test func acceptanceEnvironmentIsEphemeralAndRemovedFromGuestArguments() throws {
        let options = try AppPathCLI.acceptanceArguments([
            "--acceptance-probe", "--gate", "--acceptance-env", "X87T_IN=Z:\\input path",
            "--acceptance-env", "FEX_X87REDUCEDPRECISION=1", "--acceptance-env", "FEX_X87REDUCEDPRECISION=0",
            "--acceptance-env", "APP32_EMPTY=", "--acceptance-env", "APP32_EQUALS=a=b", "guest"])
        #expect(options.guest == ["--gate", "guest"])
        #expect(options.probe)
        #expect(options.environment == ["X87T_IN": "Z:\\input path", "FEX_X87REDUCEDPRECISION": "0", "APP32_EMPTY": "", "APP32_EQUALS": "a=b"])
        #expect(try AppPathCLI.acceptanceArguments([]).environment.isEmpty)
        #expect(throws: AppPathCLI.ArgumentError.self) { try AppPathCLI.acceptanceArguments(["--acceptance-env"]) }
        #expect(throws: AppPathCLI.ArgumentError.self) { try AppPathCLI.acceptanceArguments(["--acceptance-env", "9INVALID=1"]) }
        #expect(throws: AppPathCLI.ArgumentError.self) { try AppPathCLI.acceptanceArguments(["--acceptance-env", "NO_EQUALS"]) }
        #expect(try AppPathCLI.acceptanceArguments(["--", "--acceptance-env", "GUEST=1"]).guest == ["--acceptance-env", "GUEST=1"])
    }
    @Test func appEntryRequiresAnExplicitIsolatedRootBeforeIO() {
        let forbidden = URL(fileURLWithPath: "/owner/Library/Application Support")
        #expect(AppPathCLI.isolatedPaths(environment: [:], forbiddenBase: forbidden) == nil)
        #expect(AppPathCLI.isolatedPaths(environment: ["MACRUNNER_APP_DATA_ROOT": "relative"], forbiddenBase: forbidden) == nil)
        #expect(AppPathCLI.isolatedPaths(environment: ["MACRUNNER_APP_DATA_ROOT": "/owner/Library/Application Support/MacRunnerControlCenter"], forbiddenBase: forbidden) == nil)
        let valid = AppPathCLI.isolatedPaths(environment: ["MACRUNNER_APP_DATA_ROOT": "/app32-test-private"], forbiddenBase: forbidden)
        #expect(valid?["bottle"] == "/app32-test-private/Bottles/Default")
        #expect(valid?["runs"] == "/app32-test-private/Runs")
    }
    @Test func earlyGameExitDoesNotMasqueradeAsMenuAcceptance() {
        #expect(EngineLauncher.exitedTooSoon(elapsed: 6.835, minimum: 10))
        #expect(EngineLauncher.exitedTooSoon(elapsed: 9.999, minimum: 10))
        #expect(!EngineLauncher.exitedTooSoon(elapsed: 10, minimum: 10))
        #expect(!EngineLauncher.exitedTooSoon(elapsed: 0.01, minimum: nil))
    }
    @Test func mediaProfilePreservesOtherDriveTypesAndIsIdempotent() {
        let original = "WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\Drives] 1\n\"c:\"=\"hd\"\n\"r:\"=\"hd\"\n\n[Software\\\\Elsewhere]\n\"r:\"=\"retain\"\n"
        let updated = BottleSetup.cdromRegistry(original, drive: "r:")
        #expect(updated.contains("\"c:\"=\"hd\""))
        #expect(updated.contains("\"r:\"=\"cdrom\""))
        #expect(updated.contains("[Software\\\\Elsewhere]\n\"r:\"=\"retain\""))
        #expect(!updated.contains("\"r:\"=\"hd\""))
        #expect(BottleSetup.cdromRegistry(updated, drive: "r:") == updated)
    }
    @Test func modesetProfileUsesWineGlobalKeyAndPreservesRegistry() {
        let fresh = BottleSetup.modesetRegistry("", enabled: true)
        #expect(fresh.hasPrefix("WINE REGISTRY Version 2"))
        #expect(fresh.contains("[Software\\\\Wine\\\\X11 Driver]\n\"EmulateModeset\"=\"Y\""))
        let original = "WINE REGISTRY Version 2\n\n[Software\\\\Wine\\\\X11 Driver] 123\n\"EmulateModeset\"=\"N\"\n\"Retain\"=\"yes\"\n\n[Software\\\\Unrelated]\n\"EmulateModeset\"=\"user-setting\"\n"
        let changed = BottleSetup.modesetRegistry(original, enabled: true)
        #expect(changed.contains("\"Retain\"=\"yes\""))
        #expect(changed.contains("[Software\\\\Unrelated]\n\"EmulateModeset\"=\"user-setting\""))
        #expect(!changed.contains("\"EmulateModeset\"=\"N\""))
        #expect(BottleSetup.modesetRegistry(changed, enabled: true) == changed)
        #expect(BottleSetup.modesetRegistry(changed, enabled: false).contains("\"EmulateModeset\"=\"N\""))
    }
    @Test func pe32ImportDynamicAndProfileUsePackagedRoute() throws {
        let root = try #require(ProcessInfo.processInfo.environment["APP32_ENGINE_ROOT"])
        let engine = try #require(BundledEngine.load(from: URL(fileURLWithPath: root)))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("APP32-routing-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let cases: [(String, Data, GraphicsDetection.Strength)] = [
            ("import.exe", FakePE.make(machine: 0x14c, imports: ["ddraw.dll"]), .importTable),
            ("delay.exe", FakePE.make(machine: 0x14c, delayImports: ["ddraw.dll"]), .delayImport),
            ("dynamic.exe", FakePE.make(machine: 0x14c, asciiStrings: ["DDRAW.DLL"]), .stringReference),
            ("wide.exe", FakePE.make(machine: 0x14c, utf16Strings: ["ddraw.dll"]), .stringReference),
            ("Heroes3.exe", FakePE.make(machine: 0x14c), .profile),
            ("Diablo.exe", FakePE.make(machine: 0x14c), .profile),
        ]
        for (name, bytes, strength) in cases {
            let executable = directory.appendingPathComponent(name)
            try bytes.write(to: executable)
            let detection = GraphicsProbe.detect(exe: executable)
            #expect(detection.candidates[.ddraw] == strength)
            let plan = GraphicsSelector.plan(detection: detection, engine: engine)
            #expect(plan.decision == .launch)
            #expect(plan.arch == .x86)
            #expect(plan.api == .ddraw)
            #expect(plan.route?.layer == "wine-pe32-gdi")
            #expect(plan.environment["WINE_D3D_CONFIG"] == "renderer=gdi,csmt=disabled")
            #expect(plan.environment["WINEDLLOVERRIDES"]?.contains("ddraw=b") == true)
            if strength == .profile { #expect(plan.emulateModeset == true) }
            #expect(plan.cdromDataFilename == (name == "Diablo.exe" ? "DIABDAT.MPQ" : nil))
        }
        // Every exposed <=9 sibling must name the same complete builtin set.
        for api in [GraphicsAPI.ddraw, .d3d8, .d3d9] {
            #expect(engine.graphics.route(api: api, arch: .x86)?.layer == "wine-pe32-gdi")
        }
        #expect(engine.incompleteLayers["wine-pe32-gdi"] == nil)
        // Exact old catalogue control is tested by the application entry too.
        var old = engine
        old.graphics.architectures = [.init(arch: .x86, status: .unavailable, evidence: "old catalog")]
        let refused = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: directory.appendingPathComponent("Heroes3.exe")), engine: old)
        if case .refuse = refused.decision {} else { Issue.record("Old x86 catalogue did not refuse") }
    }
}
