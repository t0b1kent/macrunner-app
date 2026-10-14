import CryptoKit
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

    @Test func interruptedPreparationCannotExposeReadyMarker() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try fixture.markReady()
        try Data("unfinished".utf8).write(to: fixture.prefix.appendingPathComponent(BottleSetup.updatingName))
        #expect(!fixture.setup().isReady)
    }

    @Test func busyUpdateRefusesBeforeWritingPendingOrMarker() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try fixture.markReady()
        let markerURL = fixture.prefix.appendingPathComponent(BottleSetup.markerName)
        let before = try Data(contentsOf: markerURL)
        try Data(#"{"name":"updated-fixture","environment":{}}"#.utf8)
            .write(to: fixture.engine.root.appendingPathComponent("ENGINE.json"))
        BottleSetup.beginRun(prefix: fixture.prefix)
        defer { BottleSetup.endRun(prefix: fixture.prefix) }
        #expect(throws: (any Error).self) { try fixture.setup().prepareIfNeeded() }
        #expect(try Data(contentsOf: markerURL) == before)
        #expect(!FileManager.default.fileExists(atPath: fixture.prefix.appendingPathComponent(BottleSetup.updatingName).path))
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

    @Test func cachedWICStillStartsOwnedSessionOnEachPreparation() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try fixture.markReady()
        let codec = fixture.prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll")
        try FileManager.default.createDirectory(at: codec.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("test codec".utf8)
        try bytes.write(to: codec)
        let marker = fixture.prefix.appendingPathComponent(BottleSetup.markerName)
        var data = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
        let setup = fixture.setup()
        data["wicRegistration"] = ["engine": setup.engineStamp, "engineRoot": setup.engineRootPath,
                                   "codec": SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()]
        try JSONSerialization.data(withJSONObject: data).write(to: marker)
        let before = try Data(contentsOf: marker)
        var starts = 0
        for _ in 0..<2 {
            try setup.prepareIfNeeded(beforeRegistration: {
                #expect(setup.isReady)
                let actualCodec = try Data(contentsOf: codec)
                #expect(actualCodec == bytes)
                starts += 1
            })
        }
        #expect(starts == 2)
        #expect(try Data(contentsOf: marker) == before)
        // The fixture loader exits97: success also proves cached WIC did not run it.
    }

    @Test func missingCodecNeverStartsOwnedSession() throws {
        let fixture = try fixture()
        defer { fixture.cleanUp() }
        try fixture.markReady()
        var started = false
        var rejected = false
        do { try fixture.setup().prepareIfNeeded(beforeRegistration: { started = true }) }
        catch { rejected = true }
        #expect(rejected)
        #expect(!started)
    }
}
