import Foundation
import Testing
@testable import MacRunnerControlCenter

/// GOTHIC3 07.11.2026: the renderer lives in the game's OWN DLL that the exe imports statically
/// (Gothic3.exe -> Engine.dll -> d3d9.dll + d3dx9_40.dll). Before the fallback the probe returned no
/// candidates at all (owner's run 06.11: «Graphics API not determined», graphicsRoute "unknown x86").
struct GothicProbeFallbackTests {
    private func dir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gothic-probe-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func put(_ pe: Data, _ name: String, in dir: URL) throws -> URL {
        let url = dir.appendingPathComponent(name)
        try pe.write(to: url)
        return url
    }

    /// Gothic 3 layout: exe -> Engine.dll -> d3d9 (+ d3dx9_40 for effects), other game DLLs without graphics.
    private func gothicLayout(machine: UInt16 = 0x014c) throws -> URL {
        let d = try dir()
        try put(FakePE.make(machine: machine, imports: ["d3d9.dll", "d3dx9_40.dll", "kernel32.dll"],
                            functions: ["d3d9.dll": ["Direct3DCreate9"], "d3dx9_40.dll": ["D3DXCreateEffect"]]),
                "Engine.dll", in: d)
        try put(FakePE.make(machine: machine, imports: ["kernel32.dll", "sharedbase.dll"]), "Game.dll", in: d)
        try put(FakePE.make(machine: machine, imports: ["kernel32.dll"]), "SharedBase.dll", in: d)
        return try put(FakePE.make(machine: machine, imports: ["kernel32.dll", "Engine.dll", "Game.dll"]), "Gothic3.exe", in: d)
    }

    @Test func gameModuleImportedByTheExeNamesTheRenderer() throws {
        let detection = GraphicsProbe.detect(exe: try gothicLayout(), profiles: [])
        #expect(detection.arch == .x86)
        #expect(detection.candidates == [.d3d9: .importTable])
        #expect(detection.notes.contains("game module Engine.dll"))
        #expect(detection.evidence.contains { $0.source == "Engine.dll: d3d9.dll (via Gothic3.exe)" })
    }

    /// The exe's own evidence always wins: the fallback does not add a second API.
    @Test func fallbackRunsOnlyWithoutAnyOtherEvidence() throws {
        let d = try dir()
        try put(FakePE.make(imports: ["d3d9.dll"], functions: ["d3d9.dll": ["Direct3DCreate9"]]), "helper.dll", in: d)
        let exe = try put(FakePE.make(imports: ["d3d11.dll", "helper.dll"]), "game.exe", in: d)
        let detection = GraphicsProbe.detect(exe: exe, profiles: [])
        #expect(detection.candidates == [.d3d11: .importTable])
        #expect(!detection.notes.contains { $0.hasPrefix("game module") })
    }

    /// Import tables only: profiler markers and bare strings (fmodex/binkw32 name d3d9 as text) are not evidence.
    @Test func fallbackIgnoresServiceImportsAndStrings() throws {
        let d = try dir()
        try put(FakePE.make(machine: 0x014c, imports: ["d3d9.dll"], functions: ["d3d9.dll": ["D3DPERF_BeginEvent"]],
                            asciiStrings: ["opengl32.dll", "d3d9.dll"]), "Engine.dll", in: d)
        let exe = try put(FakePE.make(machine: 0x014c, imports: ["Engine.dll"]), "game.exe", in: d)
        #expect(GraphicsProbe.detect(exe: exe, profiles: []).candidates.isEmpty)
    }

    /// Depth 2 and local files only: a renderer three hops away, or a DLL that is not next to the exe, is not followed.
    @Test func fallbackStaysLocalAndShallow() throws {
        let d = try dir()
        try put(FakePE.make(machine: 0x014c, imports: ["c.dll"]), "b.dll", in: d)
        try put(FakePE.make(machine: 0x014c, imports: ["d3d9.dll"], functions: ["d3d9.dll": ["Direct3DCreate9"]]), "c.dll", in: d)
        try put(FakePE.make(machine: 0x014c, imports: ["b.dll"]), "a.dll", in: d)
        let deep = try put(FakePE.make(machine: 0x014c, imports: ["a.dll", "notpresent.dll"]), "game.exe", in: d)
        #expect(GraphicsProbe.detect(exe: deep, profiles: []).candidates.isEmpty)
        #expect(GraphicsProbe.localImportClosure(of: deep).map(\.lastPathComponent) == ["a.dll", "b.dll"])
    }

    /// Release catalogue (APP32_ENGINE_ROOT = an engine root whose ENGINE.json carries the proposal): d3d9 x86 goes to
    /// the layer the PACKAGE names (0007: wined3d -> OpenGL or HyperBridge DX9 — data, not app code), ddraw/d3d8 stay
    /// on GDI, the D3DX load order is never part of a layer (it is the launcher's, per game, 0005/0006).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APP32_ENGINE_ROOT"] != nil))
    func gothicLayoutUsesTheOpenGLLayer() throws {
        let root = try #require(ProcessInfo.processInfo.environment["APP32_ENGINE_ROOT"])
        let engine = try #require(BundledEngine.load(from: URL(fileURLWithPath: root)))
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: try gothicLayout()), engine: engine)
        #expect(plan.decision == .launch)
        #expect(plan.arch == .x86)
        #expect(plan.api == .d3d9)
        let chosen = try #require(engine.graphics.route(api: .d3d9, arch: .x86)?.layer)
        #expect(plan.route?.layer == chosen)
        #expect(plan.layer?.id == chosen)
        #expect(chosen != "wine-pe32-gdi")
        let overrides = plan.environment["WINEDLLOVERRIDES"] ?? ""
        #expect(overrides.contains("d3d9="))
        #expect(!overrides.lowercased().contains("d3dx9"), "D3DX is per game (launcher), never part of a layer")
        #expect(engine.incompleteLayers[chosen] == nil)
        let layer = try #require(plan.layer)
        if layer.modules.values.contains(where: { $0.contains("wined3d.dll") }) {
            // wined3d route: the OpenGL renderer, Wine's own i386 builtins.
            #expect(plan.environment["WINE_D3D_CONFIG"] == "renderer=gl")
            #expect(overrides.contains("d3d9=b") && overrides.contains("wined3d=b"))
            #expect(engine.graphics.placements(of: layer).values.allSatisfy { $0.hasPrefix("wine/lib/wine/i386-windows/") })
        } else {
            // HyperBridge DX9: its own i386 d3d9.dll (native order) and a native unix core; no wined3d at all.
            #expect(overrides.contains("d3d9=n,b"))
            #expect(plan.environment["WINE_D3D_CONFIG"] == nil)
            #expect(engine.graphics.placements(of: layer)["syswow64/d3d9.dll"] == "graphics/i386-windows/d3d9.dll")
            #expect(!(layer.unix ?? []).isEmpty)
        }
        for api in [GraphicsAPI.ddraw, .d3d8] {
            #expect(engine.graphics.route(api: api, arch: .x86)?.layer == "wine-pe32-gdi")
        }
        let gdi = try #require(engine.graphics.layer("wine-pe32-gdi"))
        // Both D3D9 renderers claim syswow64/d3d9.dll like GDI: the bottle swaps them by route (BottleSetup.switchTo),
        // and the default set of a new bottle (first non-conflicting) stays GDI + DXMT.
        #expect(engine.graphics.conflicts(gdi, layer))
        var defaults: [GraphicsLayer] = []
        for candidate in engine.graphics.layers where engine.incompleteLayers[candidate.id] == nil {
            if !defaults.contains(where: { engine.graphics.conflicts($0, candidate) }) { defaults.append(candidate) }
        }
        #expect(!defaults.map(\.id).contains(chosen))
        #expect(defaults.map(\.id).contains("wine-pe32-gdi"))
    }

    /// Proposal B only (enabled when the catalogue routes d3d9 x86_64 to a layer): 64-bit D3D9 via wined3d -> GL.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["APP32_ENGINE_ROOT"] != nil))
    func sixtyFourBitD3D9ProposalRoute() throws {
        let root = try #require(ProcessInfo.processInfo.environment["APP32_ENGINE_ROOT"])
        let engine = try #require(BundledEngine.load(from: URL(fileURLWithPath: root)))
        guard engine.graphics.route(api: .d3d9, arch: .x86_64)?.layer != nil else { return }
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: try gothicLayout(machine: 0x8664)), engine: engine)
        #expect(plan.decision == .launch)
        #expect(plan.api == .d3d9)
        #expect(plan.layer?.id == "wine-pe64-d3d9-gl")
        #expect(plan.environment["WINE_D3D_CONFIG"] == "renderer=gl")
        let layer = try #require(plan.layer)
        #expect(engine.incompleteLayers[layer.id] == nil)
        #expect(engine.graphics.placements(of: layer).values.allSatisfy { $0.hasPrefix("wine/lib/wine/aarch64-windows/") })
        for other in engine.graphics.layers where other.id.hasPrefix("dxmt-") {
            #expect(!engine.graphics.conflicts(layer, other), "\(other.id)")
        }
    }
}
