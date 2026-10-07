import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Readiness checks on tiny fake bundles only; no Wine or real prefix is used.
struct BottleRelocationTests {
    private struct Fixture {
        let root: URL
        let engine: BundledEngine
        let prefix: URL
        let log: EngineLog

        func setup(for engine: BundledEngine? = nil) -> BottleSetup {
            BottleSetup(engine: engine ?? self.engine, prefix: prefix, environment: [:], log: log)
        }

        func markReady(includeRoot: Bool = true) throws {
            let original = setup()
            var marker: [String: Any] = ["engine": original.engineStamp, "layers": [String]()]
            if includeRoot { marker["engineRoot"] = original.engineRootPath }
            try JSONSerialization.data(withJSONObject: marker)
                .write(to: prefix.appendingPathComponent(BottleSetup.markerName))
        }

        func cleanUp() {
            log.close()
            try? FileManager.default.removeItem(at: root)
        }
    }

    private func fixture() throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bottle-relocation-\(UUID().uuidString)")
        let engineRoot = root.appendingPathComponent("original-engine")
        let wine = engineRoot.appendingPathComponent("wine/bin/wine")
        try fm.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        // Executable only to satisfy bundle validation. None of these tests launches it.
        try Data("#!/bin/sh\nexit 97\n".utf8).write(to: wine)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        try Data(#"{"name":"relocation-fixture","environment":{}}"#.utf8)
            .write(to: engineRoot.appendingPathComponent("ENGINE.json"))
        let prefix = root.appendingPathComponent("prefix")
        try fm.createDirectory(at: prefix, withIntermediateDirectories: true)
        try Data("WINE REGISTRY".utf8).write(to: prefix.appendingPathComponent("system.reg"))
        return Fixture(root: root, engine: try #require(BundledEngine.load(from: engineRoot)),
                       prefix: prefix, log: try EngineLog(url: root.appendingPathComponent("test.log")))
    }

    @Test func unchangedEngineAndLocationRemainReady() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try fixture.markReady()
        #expect(fixture.setup().isReady)
    }

    @Test func legacyMarkerWithoutRootRequiresRefresh() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try fixture.markReady(includeRoot: false)
        #expect(!fixture.setup().isReady)
    }

    @Test func identicalEngineAtNewLocationRequiresRefresh() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try fixture.markReady()
        let relocated = fixture.root.appendingPathComponent("installed-engine")
        try FileManager.default.copyItem(at: fixture.engine.root, to: relocated)
        let movedEngine = try #require(BundledEngine.load(from: relocated))
        let oldSetup = fixture.setup()
        let movedSetup = fixture.setup(for: movedEngine)
        #expect(oldSetup.engineStamp == movedSetup.engineStamp)
        #expect(oldSetup.isReady)
        #expect(!movedSetup.isReady)
    }

    @Test func symlinkAliasOfSameEngineRemainsReady() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try fixture.markReady()
        let alias = fixture.root.appendingPathComponent("engine-alias")
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.engine.root)
        let aliasEngine = try #require(BundledEngine.load(from: alias))
        #expect(fixture.setup(for: aliasEngine).engineRootPath == fixture.setup().engineRootPath)
        #expect(fixture.setup(for: aliasEngine).isReady)
    }

    @Test func changedEngineAtSameLocationStillRequiresRefresh() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try fixture.markReady()
        try Data(#"{"name":"updated-fixture","environment":{}}"#.utf8)
            .write(to: fixture.engine.root.appendingPathComponent("ENGINE.json"))
        #expect(!fixture.setup().isReady)
    }
}
