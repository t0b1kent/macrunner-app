import Foundation
import Testing
@testable import MacRunnerControlCenter

/// GOTHIC3 07.11.2026 — 0005: `d3dx9_NN=n,b` for the game that shipped the DLL, nothing for anyone else.
struct GameRedistOverridesTests {
    private let d3dx40 = GameRedist.Install(dll: "d3dx9_40.dll", bits: 32, sha256: "s", version: "v", cabinet: "c")
    private let d3dx43 = GameRedist.Install(dll: "d3dx9_43.dll", bits: 32, sha256: "t", version: "v", cabinet: "c")
    /// Layer strings of the two D3D9 x86 routes the engine package can choose (GL proposal, HyperBridge DX9 test).
    private let glLayer = "winedbg.exe=d;ddraw=b;d3d8=b;d3d9=b;wined3d=b;d3d11,dxgi,d3d10core,winemetal=n,b"
    private let hbdx9Layer = "d3d9=n,b;d3d11,dxgi,d3d10core,winemetal=n,b"

    @Test func appendsNativeOrderForEveryInstalledDLL() {
        #expect(GameRedist.mergeOverrides(glLayer, installs: [d3dx40]) == glLayer + ";d3dx9_40=n,b")
        #expect(GameRedist.mergeOverrides(hbdx9Layer, installs: [d3dx43, d3dx40]) == hbdx9Layer + ";d3dx9_40=n,b;d3dx9_43=n,b")
        #expect(GameRedist.mergeOverrides(nil, installs: [d3dx40]) == "d3dx9_40=n,b")
        #expect(GameRedist.mergeOverrides("", installs: [d3dx40]) == "d3dx9_40=n,b")
        #expect(GameRedist.mergeOverrides("ddraw=b;", installs: [d3dx40]) == "ddraw=b;d3dx9_40=n,b")
    }

    /// Nothing installed → the environment is exactly what it was (scope: other games are not touched).
    @Test func noInstallLeavesTheValueAlone() {
        #expect(GameRedist.mergeOverrides(glLayer, installs: []) == glLayer)
        #expect(GameRedist.mergeOverrides(nil, installs: []) == nil)
    }

    /// The game record's own setting for that DLL wins, in any spelling Wine accepts.
    @Test func explicitSettingWins() {
        for manual in ["d3dx9_40=b", "D3DX9_40.DLL=b", "*d3dx9_40=b", "xinput1_3,d3dx9_40=n"] {
            #expect(GameRedist.mergeOverrides(manual, installs: [d3dx40]) == manual, "\(manual)")
        }
        #expect(GameRedist.overrideNames(glLayer) == ["winedbg.exe", "ddraw", "d3d8", "d3d9", "wined3d", "d3d11", "dxgi", "d3d10core", "winemetal"])
    }

    /// Scope (measured 07.11: the native file in syswow64 loads even without an override): the owner of the cabinet
    /// gets native, every other program of the bottle gets Wine's builtin back, a manual setting still wins.
    @Test func otherProgramsOfTheBottleKeepTheBuiltin() {
        #expect(GameRedist.scopedOverrides(glLayer, own: [], present: [d3dx40]) == glLayer + ";d3dx9_40=b")
        #expect(GameRedist.scopedOverrides(glLayer, own: [d3dx40], present: [d3dx40]) == glLayer + ";d3dx9_40=n,b")
        #expect(GameRedist.scopedOverrides(nil, own: [d3dx43], present: [d3dx40, d3dx43]) == "d3dx9_43=n,b;d3dx9_40=b")
        #expect(GameRedist.scopedOverrides("d3dx9_40=n", own: [], present: [d3dx40]) == "d3dx9_40=n")
        #expect(GameRedist.scopedOverrides(glLayer, own: [], present: []) == glLayer)
        #expect(GameRedist.scopedOverrides(nil, own: [], present: []) == nil)
    }

    /// Every layer of the package keeps all its own entries (merging only ever appends).
    @Test func layerEntriesSurvive() {
        for layer in [glLayer, hbdx9Layer] {
            let merged = GameRedist.mergeOverrides(layer, installs: [d3dx40]) ?? ""
            #expect(merged.hasPrefix(layer))
            #expect(GameRedist.overrideNames(merged) == GameRedist.overrideNames(layer).union(["d3dx9_40"]))
        }
    }
}
