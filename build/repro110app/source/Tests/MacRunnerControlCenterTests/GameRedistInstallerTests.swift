import Foundation
import Testing
@testable import MacRunnerControlCenter

/// D3DX-REDIST 17.11.2026 — the game's own DirectX redist is installed at game installation (unpacked installer payload),
/// and a game added as an installed folder finds the same game's earlier extraction. Real Microsoft cabinets come from
/// GAMEREDIST_REAL_CABS (read-only: symlinked into a fake installer tree); no network anywhere.
struct GameRedistInstallerTests {
    /// installer tree: <root>/<name>/__redist/DirectX/<cabs symlinked>, goggame-<id>.info, Game.exe
    static func tree(_ root: URL, name: String, id: String, cabs: Bool) throws -> URL {
        let fm = FileManager.default
        let dir = root.appendingPathComponent(name)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: dir.appendingPathComponent("goggame-\(id).info"))
        try Data("MZ".utf8).write(to: dir.appendingPathComponent("Game.exe"))
        if cabs, let real = RealCabinets.directory {
            let redist = dir.appendingPathComponent("__redist/DirectX")
            try fm.createDirectory(at: redist, withIntermediateDirectories: true)
            for n in try fm.contentsOfDirectory(atPath: real.path) where n.hasSuffix(".cab") {
                try fm.createSymbolicLink(at: redist.appendingPathComponent(n), withDestinationURL: real.appendingPathComponent(n))
            }
        }
        return dir
    }

    @Test func payloadWithoutRedistImportsNothing() throws {
        let root = try RealCabinets.tempDir("gri-none"); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.tree(root, name: "Game", id: "1", cabs: false)
        let r = GameRedist.installFromPayload(folder: dir, store: root.appendingPathComponent("store"))
        #expect(r.cabinetsSeen == 0 && r.installs.isEmpty)
    }

    @Test func fakeCabinetInInstallerTreeIsFoundButRejected() throws {
        let root = try RealCabinets.tempDir("gri-fake"); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.tree(root, name: "Game", id: "1", cabs: false)
        let redist = dir.appendingPathComponent("__redist/DirectX")
        try FileManager.default.createDirectory(at: redist, withIntermediateDirectories: true)
        try Data("MSCF not a cabinet".utf8).write(to: redist.appendingPathComponent("Nov2008_d3dx9_40_x86.cab"))
        let r = GameRedist.installFromPayload(folder: dir, store: root.appendingPathComponent("store"))
        #expect(r.cabinetsSeen == 1 && r.installs.isEmpty && r.rejected.count == 1)
        #expect(GameRedist.storedInstall(dll: "d3dx9_40.dll", bits: 32, store: root.appendingPathComponent("store")) == nil)
    }

    @Test func gogIdentityComesFromTheInfoFile() throws {
        let root = try RealCabinets.tempDir("gri-id"); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.tree(root, name: "Game", id: "1207658986", cabs: false)
        #expect(GameRedist.gogIdentities(near: dir.appendingPathComponent("Game.exe")) == ["goggame-1207658986.info"])
    }

    @Test(.enabled(if: RealCabinets.present)) func installerPayloadInstallsAllFortyReleases() throws {
        let root = try RealCabinets.tempDir("gri-real"); defer { try? FileManager.default.removeItem(at: root) }
        let dir = try Self.tree(root, name: "Gothic3", id: "1207658986", cabs: true)
        let store = root.appendingPathComponent("store")
        let r = GameRedist.installFromPayload(folder: dir, store: store)
        print("D3DX-REDIST payload import: cabinets=\(r.cabinetsSeen) installed=\(r.installs.count) x86=\(r.x86) x64=\(r.x64) rejected=\(r.rejected)")
        #expect(r.rejected.isEmpty)
        if RealCabinets.directory!.path.contains("Gothic3") { #expect(r.x86 == 20 && r.x64 == 20) }
        // The game now resolves without any cabinet next to it, even from another folder.
        let elsewhere = root.appendingPathComponent("Elsewhere/Gothic3.exe")
        let res = GameRedist.resolve(exe: elsewhere, bits: 32, store: store, importNames: ["d3dx9_40.dll"])
        #expect(res.missing.isEmpty && res.warnings.isEmpty)
        #expect(res.installs.first?.sha256 == "16fd909aeb68d0d1aca8529dc7f78880b97d6649d70ce8d03a2c858bc28e216b")
    }

    @Test(.enabled(if: RealCabinets.present)) func installedFolderAdoptsTheSameGamesEarlierExtraction() throws {
        let root = try RealCabinets.tempDir("gri-adopt"); defer { try? FileManager.default.removeItem(at: root) }
        let extracted = root.appendingPathComponent("Extracted")
        _ = try Self.tree(extracted, name: "Gothic3-1.75-gog", id: "42", cabs: true)
        _ = try Self.tree(extracted, name: "Other", id: "7", cabs: true)          // another game: must not be used
        let installed = try Self.tree(root.appendingPathComponent("Installed"), name: "Gothic3", id: "42", cabs: false)
        let store = root.appendingPathComponent("store")
        let res = GameRedist.resolve(exe: installed.appendingPathComponent("Game.exe"), bits: 32, store: store,
                                     importNames: ["d3dx9_40.dll"], knownRoots: [extracted])
        #expect(res.missing.isEmpty)
        #expect(res.installs.count == 1)
        #expect(res.notes.contains { $0.contains("adopted") })
    }

    @Test func differentGameDoesNotAdoptAndGetsTheInstallerWarning() throws {
        let root = try RealCabinets.tempDir("gri-other"); defer { try? FileManager.default.removeItem(at: root) }
        let extracted = root.appendingPathComponent("Extracted")
        _ = try Self.tree(extracted, name: "Other", id: "7", cabs: true)
        let installed = try Self.tree(root.appendingPathComponent("Installed"), name: "Gothic3", id: "42", cabs: false)
        let res = GameRedist.resolve(exe: installed.appendingPathComponent("Game.exe"), bits: 32, store: root.appendingPathComponent("store"),
                                     importNames: ["d3dx9_40.dll"], knownRoots: [extracted])
        #expect(res.missing == ["d3dx9_40.dll"] && res.installs.isEmpty)
        #expect(res.warnings.count == 1)
        #expect(res.warnings[0].contains("black") && res.warnings[0].contains("installer"))
    }
}
