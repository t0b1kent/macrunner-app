import Foundation
import Testing
@testable import MacRunnerControlCenter

/// GOTHIC3 07.11.2026 — 0004: the game's Microsoft d3dx9 is the LAST step of every bottle preparation.
/// Fake engine tree, no Wine: the "ready" route of prepareIfNeeded runs no Wine process at all.
struct GameRedistBottleTests {
    struct Fixture {
        let root: URL
        let engine: BundledEngine
        let prefix: URL
        let store: URL
        let log: EngineLog
        let native: Data
        var install: GameRedist.Install {
            GameRedist.Install(dll: "d3dx9_40.dll", bits: 32, sha256: GameRedist.sha256(native),
                               version: "9.24.950.2656", cabinet: "Nov2008_d3dx9_40_x86.cab")
        }
        var target: URL { prefix.appendingPathComponent("drive_c/windows/syswow64/d3dx9_40.dll") }
        func setup() -> BottleSetup {
            var setup = BottleSetup(engine: engine, prefix: prefix, environment: ["WINEPREFIX": prefix.path], log: log)
            setup.redistStore = store
            return setup
        }
        func marker() throws -> [String: Any] {
            try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: prefix.appendingPathComponent(BottleSetup.markerName))) as? [String: Any])
        }
        /// A bottle that prepareIfNeeded considers ready for this engine: no Wine runs on that route.
        func markReady(extra: [String: Any] = [:]) throws {
            let codec = try BottleUpdateCatalogue.digest(prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
            var marker: [String: Any] = ["engine": BottleSetup.engineStamp(engine), "engineRoot": BottleSetup.engineRootPath(engine),
                                         "engineName": engine.name, "layers": [String](),
                                         "wicRegistration": ["engine": BottleSetup.engineStamp(engine),
                                                             "engineRoot": BottleSetup.engineRootPath(engine), "codec": codec]]
            for (k, v) in extra { marker[k] = v }
            try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys])
                .write(to: prefix.appendingPathComponent(BottleSetup.markerName))
        }
        func cleanUp() { log.close(); try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("redist-bottle-\(UUID().uuidString)")
        let engineRoot = root.appendingPathComponent("engine")
        try write(Data(#"{"name":"redist-fixture","environment":{},"graphics":{"layers":[{"id":"test-d3d9","title":"t","modules":{"graphics/i386-windows":["d3d9.dll"]}}],"routes":[{"api":"d3d9","arch":"x86","layer":"test-d3d9","status":"experimental"}]}}"#.utf8),
                  engineRoot.appendingPathComponent("ENGINE.json"))
        try write(Data("layer d3d9".utf8), engineRoot.appendingPathComponent("graphics/i386-windows/d3d9.dll"))
        let wine = engineRoot.appendingPathComponent("wine/bin/wine")
        // Records every Wine call: the ready route must run none; a layer switch runs exactly the WIC registration.
        try write(Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(root.path)/wine-calls.txt\"\nexit 0\n".utf8), wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let lib = engineRoot.appendingPathComponent("wine/lib/wine")
        for (arch, names) in [("aarch64-windows", ["kernel32.dll", "windowscodecs.dll", "d3dx9_40.dll"]),
                              ("i386-windows", ["kernel32.dll", "d3dx9_40.dll"]),
                              ("x86_64-windows", ["wow64cpu.dll"])] {
            for name in names { try write(Data("wine-builtin \(arch)/\(name)".utf8), lib.appendingPathComponent("\(arch)/\(name)")) }
        }
        let prefix = root.appendingPathComponent("prefix")
        try write(Data("WINE REGISTRY".utf8), prefix.appendingPathComponent("system.reg"))
        let engine = try #require(BundledEngine.load(from: engineRoot))
        let log = try EngineLog(url: root.appendingPathComponent("engine.log"))
        let native = try GameRedist.extract(RealCabinets.cabinet("Nov2008_d3dx9_40_x86.cab"))
        let store = root.appendingPathComponent("store")
        try GameRedist.store(native, in: store)
        let f = Fixture(root: root, engine: engine, prefix: prefix, store: store, log: log, native: native)
        try f.setup().syncModules() // as the full route does: Wine's builtin d3dx9_40 in syswow64
        return f
    }

    private func builtin(_ f: Fixture) throws -> Bool {
        try Data(contentsOf: f.target) == Data("wine-builtin i386-windows/d3dx9_40.dll".utf8)
    }

    /// The measured trap, then the cure: a full preparation (syncModules) copies Wine's builtin over the native
    /// d3dx9; the next preparation — even one without the game (background update on app start) — puts it back.
    @Test(.enabled(if: RealCabinets.present)) func everyPreparationPutsTheNativeD3DXBackLast() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        try f.markReady()
        #expect(try builtin(f))
        try f.setup().prepareIfNeeded(gameRedist: [f.install])
        #expect(try Data(contentsOf: f.target) == f.native)
        let recorded = BottleSetup.recordedRedist(prefix: f.prefix)
        #expect(recorded == [f.install])

        try f.setup().syncModules() // the trap: what create()/full route does on an engine change
        #expect(try builtin(f))
        try f.setup().prepareIfNeeded() // no game: e.g. the background bottle update
        #expect(try Data(contentsOf: f.target) == f.native)
        #expect(!FileManager.default.fileExists(atPath: f.root.appendingPathComponent("wine-calls.txt").path), "the ready route ran Wine")
        let text = try String(contentsOf: f.log.url, encoding: .utf8)
        #expect(text.contains("redist: d3dx9_40.dll 32-bit 9.24.950.2656 installed"))
    }

    /// Idempotence: a second preparation touches neither the file (same inode) nor the marker (same bytes).
    @Test(.enabled(if: RealCabinets.present)) func repeatedPreparationChangesNothing() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        try f.markReady()
        try f.setup().prepareIfNeeded(gameRedist: [f.install])
        let inode = try FileManager.default.attributesOfItem(atPath: f.target.path)[.systemFileNumber] as? Int
        let marker = try Data(contentsOf: f.prefix.appendingPathComponent(BottleSetup.markerName))
        #expect(try f.setup().applyGameRedist([f.install]).isEmpty)
        try f.setup().prepareIfNeeded(gameRedist: [f.install])
        try f.setup().prepareIfNeeded()
        #expect(try FileManager.default.attributesOfItem(atPath: f.target.path)[.systemFileNumber] as? Int == inode)
        #expect(try Data(contentsOf: f.prefix.appendingPathComponent(BottleSetup.markerName)) == marker)
    }

    /// Rewrites of the marker by other steps keep the redist record: a layer switch (switchTo → writeMarker, no Wine)
    /// must not make the bottle forget what to put back after the next full route.
    @Test(.enabled(if: RealCabinets.present)) func markerRewriteKeepsTheRecord() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        try f.markReady()
        try f.setup().prepareIfNeeded(gameRedist: [f.install])
        let layer = try #require(f.engine.graphics.layer("test-d3d9"))
        try f.setup().prepareIfNeeded(requiredLayer: layer) // another game: layer switch rewrites the marker
        let calls = (try? String(contentsOf: f.root.appendingPathComponent("wine-calls.txt"), encoding: .utf8)) ?? ""
        #expect(calls.split(separator: "\n").count == 1 && calls.contains("regsvr32"), "\(calls)")
        #expect(try f.marker()["layers"] as? [String] == ["test-d3d9"])
        #expect(BottleSetup.recordedRedist(prefix: f.prefix) == [f.install])
        try f.setup().syncModules()
        try f.setup().prepareIfNeeded()
        #expect(try Data(contentsOf: f.target) == f.native)
    }

    /// The installation receipt follows the file we placed, so the fast route of the next engine update does not
    /// call it "installed target changed since receipt".
    @Test(.enabled(if: RealCabinets.present)) func receiptIdentityFollowsThePlacedFile() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        let target = "drive_c/windows/syswow64/d3dx9_40.dll"
        let identity = try BottleUpdateCatalogue.Identity.read(f.target)
        let receipt = BottleUpdateCatalogue(schema: 1, engine: "e", engineRoot: "r", layers: [], inputs: [:],
            files: [target: .init(source: "wine/lib/wine/i386-windows/d3dx9_40.dll", sha256: "builtin")],
            ownership: .init(prefixRoot: f.prefix.resolvingSymlinksInPath().path, files: [target: identity]))
        try f.markReady(extra: ["updateInputs": try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))])
        try f.setup().prepareIfNeeded(gameRedist: [f.install])
        let stored = try JSONDecoder().decode(BottleUpdateCatalogue.self,
            from: JSONSerialization.data(withJSONObject: try #require(try f.marker()["updateInputs"])))
        #expect(stored.ownership?.files[target] == (try BottleUpdateCatalogue.Identity.read(f.target)))
        #expect(stored.ownership?.files[target] != identity)
        #expect(stored.files == receipt.files, "package inventory is not rewritten, only the change detector")
    }

    /// Only pinned Microsoft releases from the validated store: anything else never reaches the bottle.
    @Test(.enabled(if: RealCabinets.present)) func unpinnedOrMissingSourceIsNotInstalled() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        try f.markReady()
        let forged = GameRedist.Install(dll: "d3dx9_40.dll", bits: 32, sha256: String(repeating: "0", count: 64),
                                        version: "9.24.950.2656", cabinet: "forged.cab")
        try write(Data("forged".utf8), GameRedist.storedFile(forged.sha256, in: f.store))
        #expect(try f.setup().applyGameRedist([forged]).isEmpty)
        #expect(try builtin(f))
        // Pinned, but the store lost it: nothing installed, nothing recorded.
        try FileManager.default.removeItem(at: GameRedist.storedFile(f.install.sha256, in: f.store))
        #expect(try f.setup().applyGameRedist([f.install]).isEmpty)
        #expect(try builtin(f))
        #expect(BottleSetup.recordedRedist(prefix: f.prefix).isEmpty)
    }

    /// A game that needs no redist leaves a bottle without the record exactly as it was.
    @Test(.enabled(if: RealCabinets.present)) func bottleWithoutRedistIsUntouched() throws {
        let f = try fixture()
        defer { f.cleanUp() }
        try f.markReady()
        let marker = try Data(contentsOf: f.prefix.appendingPathComponent(BottleSetup.markerName))
        try f.setup().prepareIfNeeded()
        #expect(try builtin(f))
        #expect(try Data(contentsOf: f.prefix.appendingPathComponent(BottleSetup.markerName)) == marker)
    }

    /// Wiring guard (negative hand of the order rule): in prepareIfNeeded the redist step comes after the last
    /// marker/receipt write and after the layer switch. Moving it earlier would let a later step undo it.
    @Test func redistIsTheLastStepOfPrepareIfNeeded() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacRunnerControlCenter/Services/Engine/BottleSetup.swift")
        let text = try String(contentsOf: source, encoding: .utf8)
        let start = try #require(text.range(of: "func prepareIfNeeded("))
        let end = try #require(text.range(of: "private var defaultLayerIDs", range: start.upperBound..<text.endIndex))
        let body = String(text[start.upperBound..<end.lowerBound])
        let redist = try #require(body.range(of: "try applyGameRedist(gameRedist)"))
        for step in ["try switchTo(", "try create(", "updateByDifference(", "recordingInstallation(", "try writeMarker(", "refreshWICRegistration()"] {
            let last = try #require(body.range(of: step, options: .backwards), "\(step) not found in prepareIfNeeded")
            #expect(last.lowerBound < redist.lowerBound, "\(step) runs after the redist step")
        }
    }
}
