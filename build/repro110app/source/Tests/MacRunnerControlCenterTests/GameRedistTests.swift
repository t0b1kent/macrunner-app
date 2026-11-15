import Foundation
import Testing
@testable import MacRunnerControlCenter

/// GOTHIC3 07.11.2026 — D3DX-A step 1: redist discovery (no extraction, no Wine).
struct GameRedistTests {
    private func tree(_ files: [String]) throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("redist-\(UUID().uuidString)")
        for rel in files {
            let url = root.appendingPathComponent(rel)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([0x4d, 0x53, 0x43, 0x46]).write(to: url)
        }
        return root
    }

    @Test func parsesMicrosoftCabinetNames() {
        #expect(GameRedist.parse(cabName: "Nov2008_d3dx9_40_x86.cab")! == ("d3dx9_40.dll", 32))
        #expect(GameRedist.parse(cabName: "JUN2010_D3DX9_43_X64.CAB")! == ("d3dx9_43.dll", 64))
        #expect(GameRedist.parse(cabName: "Nov2008_d3dx10_40_x86.cab") == nil)
        #expect(GameRedist.parse(cabName: "Nov2008_XACT_x86.cab") == nil)
        #expect(GameRedist.parse(cabName: "Nov2008_d3dx9_40_arm.cab") == nil)
        #expect(GameRedist.parse(cabName: "Nov2008_d3dx9_99_x86.cab") == nil)
    }

    /// GOG layout of Gothic 3: <game>/__redist/DirectX/*.cab next to Gothic3.exe.
    @Test func findsGogRedistNextToExe() throws {
        let root = try tree(["Gothic3.exe", "__redist/DirectX/Nov2008_d3dx9_40_x86.cab", "__redist/DirectX/Nov2008_d3dx9_40_x64.cab",
                             "__redist/DirectX/Aug2005_d3dx9_27_x86.cab", "__redist/DirectX/DXSETUP.exe", "__redist/DirectX/Nov2008_XACT_x86.cab"])
        let cabs = GameRedist.cabinets(near: root.appendingPathComponent("Gothic3.exe"))
        #expect(cabs.map { "\($0.dll)/\($0.bits)" } == ["d3dx9_27.dll/32", "d3dx9_40.dll/32", "d3dx9_40.dll/64"])
    }

    /// Steam layout: _CommonRedist/DirectX/Jun2010/*.cab two levels above a bin/ exe.
    @Test func findsSteamRedistTwoLevelsUp() throws {
        let root = try tree(["Game/bin/win32/game.exe", "Game/_CommonRedist/DirectX/Jun2010/Jun2010_d3dx9_43_x86.cab"])
        let cabs = GameRedist.cabinets(near: root.appendingPathComponent("Game/bin/win32/game.exe"))
        #expect(cabs.count == 1 && cabs[0].dll == "d3dx9_43.dll" && cabs[0].bits == 32)
        #expect(GameRedist.cabinets(near: root.appendingPathComponent("Game/bin/win32/game.exe"), levels: 1).isEmpty)
    }

    /// The installed GOG copy has no __redist (the installer ran DXSETUP itself): nothing is found, nothing is guessed.
    @Test func installedCopyWithoutRedistFindsNothing() throws {
        let root = try tree(["Gothic3.exe", "Engine.dll", "Data/x.rra"])
        #expect(GameRedist.cabinets(near: root.appendingPathComponent("Gothic3.exe")).isEmpty)
    }

    @Test func neededD3DXComesFromImports() {
        #expect(GameRedist.neededD3DX(importNames: ["KERNEL32.dll", "d3d9.dll", "D3DX9_40.dll"]) == ["d3dx9_40.dll"])
        #expect(GameRedist.neededD3DX(importNames: ["d3d9.dll"]).isEmpty)
    }
}
