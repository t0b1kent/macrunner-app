import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Fake executables only; verifies both isolated setup transactions and failures.
struct SetupIdlePolicyTests {
    private func fixture() throws -> (URL, URL, BundledEngine, EngineLog) {
        let fm = FileManager.default
        let root = EnginePaths.base.appendingPathComponent("setup-idle-\(UUID())")
        let engineRoot = root.appendingPathComponent("engine")
        let prefix = root.appendingPathComponent("prefix")
        try fm.createDirectory(at: engineRoot.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        try Data(#"{"name":"setup-test","environment":{}}"#.utf8).write(to: engineRoot.appendingPathComponent("ENGINE.json"))
        let server = engineRoot.appendingPathComponent("wine/bin/wineserver")
        try Data("#!/bin/sh\nprintf 'server %s\\n' \"$*\" >> \"$WINEPREFIX/calls\"\nif [ \"$1\" = -p0 ]; then exit \"${SERVER_RC:-0}\"; fi\nexit 0\n".utf8).write(to: server)
        let wine = engineRoot.appendingPathComponent("wine/bin/wine")
        try Data("#!/bin/sh\nprintf 'wine %s\\n' \"$*\" >> \"$WINEPREFIX/calls\"\ncase \"$1\" in wineboot|*cmd.exe) printf REG > \"$WINEPREFIX/system.reg\"; exit \"${BOOT_RC:-0}\";; esac\nexit 0\n".utf8).write(to: wine)
        for path in [server,wine] { try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: path.path) }
        for arch in ["aarch64-windows","i386-windows","x86_64-windows"] {
            try fm.createDirectory(at: engineRoot.appendingPathComponent("wine/lib/wine/\(arch)"), withIntermediateDirectories: true)
        }
        try Data("codec".utf8).write(to: engineRoot.appendingPathComponent("wine/lib/wine/aarch64-windows/windowscodecs.dll"))
        let engine = try #require(BundledEngine.load(from: engineRoot))
        return (root,prefix,engine,try EngineLog(url: root.appendingPathComponent("engine.log")))
    }
    @Test func firstSetupAndUpdateUseZeroIdleButReadyLaunchDoesNot() throws {
        let (root,prefix,engine,log) = try fixture()
        defer { log.close(); try? FileManager.default.removeItem(at: root) }
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: ["WINEPREFIX":prefix.path], log: log)
        try setup.prepareIfNeeded()
        var calls = try String(contentsOf: prefix.appendingPathComponent("calls"), encoding: .utf8).split(separator:"\n")
        #expect(calls.filter { $0 == "server -p0" }.count == 2)
        #expect(calls.contains("wine C:\\windows\\system32\\cmd.exe /d /c exit 0"))
        #expect(!calls.contains("wine wineboot --init"))
        #expect(calls.filter { $0 == "server -w" }.count == 2)
        #expect(BottleSetup.isReady(engine: engine, prefix: prefix))
        let before = calls.count
        try setup.prepareIfNeeded()
        calls = try String(contentsOf: prefix.appendingPathComponent("calls"), encoding: .utf8).split(separator:"\n")
        #expect(calls.filter { $0 == "server -p0" }.count == 2)
        // Composes with0093: no setup work; WIC may register once or be cached.
        #expect(calls.count - before <= 1)
        #expect(calls.dropFirst(before).allSatisfy { $0.hasPrefix("wine C:\\windows\\system32\\regsvr32.exe") })
        try Data(#"{"engine":"old","engineRoot":"old","layers":[]}"#.utf8).write(to: prefix.appendingPathComponent(BottleSetup.markerName))
        try setup.prepareIfNeeded()
        calls = try String(contentsOf: prefix.appendingPathComponent("calls"), encoding: .utf8).split(separator:"\n")
        #expect(calls.filter { $0 == "server -p0" }.count == 4)
        #expect(calls.contains("wine wineboot -u"))
    }
    @Test func failedServerDoesNotStartWineOrStampReady() throws {
        let (root,prefix,engine,log) = try fixture()
        defer { log.close(); try? FileManager.default.removeItem(at: root) }
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: ["WINEPREFIX":prefix.path,"SERVER_RC":"9"], log: log)
        #expect(throws: BottleSetup.SetupError.self) { try setup.prepareIfNeeded() }
        let calls = try String(contentsOf: prefix.appendingPathComponent("calls"), encoding: .utf8)
        #expect(!calls.contains("wine "))
        #expect(!BottleSetup.isReady(engine: engine, prefix: prefix))
    }
    @Test func failedTemplateAndOrdinaryFallbackPreserveEvidenceWithoutPartialBottle() throws {
        let (root,prefix,original,log) = try fixture()
        defer { log.close(); try? FileManager.default.removeItem(at: root) }
        var engine = original
        engine.localNameOnlyWineboot = true
        let uniqueManifest = ["name": "negative-fallback-\(UUID().uuidString)"]
        try JSONSerialization.data(withJSONObject: uniqueManifest).write(to: engine.root.appendingPathComponent("ENGINE.json"))
        let setup = BottleSetup(engine: engine, prefix: prefix,
                                environment: ["WINEPREFIX":prefix.path,"BOOT_RC":"17"], log: log)
        #expect(throws: BottleSetup.SetupError.self) { try setup.prepareIfNeeded() }
        #expect(!FileManager.default.fileExists(atPath: prefix.path))
        #expect(!BottleSetup.isReady(engine: engine, prefix: prefix))
    }

    @Test func failedWinebootStillDrainsBeforeRejecting() throws {
        let (root,prefix,engine,log) = try fixture()
        defer { log.close(); try? FileManager.default.removeItem(at: root) }
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: ["WINEPREFIX":prefix.path,"BOOT_RC":"17"], log: log)
        #expect(throws: BottleSetup.SetupError.self) { try setup.prepareIfNeeded() }
        let calls = try String(contentsOf: prefix.appendingPathComponent("calls"), encoding: .utf8)
        #expect(calls.contains("server -w"))
        #expect(!calls.contains("wine reg "))
        #expect(!BottleSetup.isReady(engine: engine, prefix: prefix))
    }
}
