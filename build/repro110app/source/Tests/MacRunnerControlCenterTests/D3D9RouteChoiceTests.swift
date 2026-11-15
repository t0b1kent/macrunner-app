import Foundation
import Testing
@testable import MacRunnerControlCenter

/// GOTHIC3 07.11.2026 — 0007: two working renderers for 32-bit D3D9 (wined3d → OpenGL, HyperBridge DX9). Which one
/// a game gets is ENGINE.json data: both layers declared, `routes[d3d9,x86].layer` names one, `redist` asks for the
/// game's D3DX on the route — the app has no code path of its own for either renderer.
/// Synthetic engine (no Wine; its `wine` only records calls).
struct D3D9RouteChoiceTests {
    static let gdi = #"{"id":"wine-pe32-gdi","title":"GDI","modules":{"wine/lib/wine/i386-windows":["ddraw.dll","d3d8.dll","d3d9.dll","wined3d.dll"]},"environment":{"WINE_D3D_CONFIG":"renderer=gdi,csmt=disabled","WINEDLLOVERRIDES":"winedbg.exe=d;ddraw=b;d3d8=b;d3d9=b;wined3d=b"}}"#
    static let gl = #"{"id":"wine-pe32-d3d9-gl","title":"GL","modules":{"wine/lib/wine/i386-windows":["d3d9.dll","wined3d.dll","opengl32.dll"]},"unix":["wine/lib/wine/aarch64-unix/opengl32.so"],"environment":{"WINE_D3D_CONFIG":"renderer=gl","WINEDLLOVERRIDES":"winedbg.exe=d;ddraw=b;d3d8=b;d3d9=b;wined3d=b"}}"#
    static let h9 = #"{"id":"hbdx9-d3d9-x86","title":"HyperBridge DX9","modules":{"graphics/i386-windows":["d3d9.dll","hbdx9.dll"]},"unix":["graphics/aarch64-unix/hbdx9.so"],"environment":{"WINEDLLOVERRIDES":"d3d9=n,b;d3d11,dxgi,d3d10core,winemetal=n,b"}}"#

    /// The whole catalogue; `choice` is the ONLY difference between the two packages.
    static func manifest(choice: String) -> String {
        #"{"name":"route-choice","environment":{},"graphics":{"layers":["# + [gdi, gl, h9].joined(separator: ",")
            + #"],"routes":[{"api":"ddraw","arch":"x86","layer":"wine-pe32-gdi","status":"experimental"},{"api":"d3d8","arch":"x86","layer":"wine-pe32-gdi","status":"experimental"},{"api":"d3d9","arch":"x86","layer":""#
            + choice + #"","status":"experimental","redist":["d3dx9"]}],"architectures":[{"arch":"x86","status":"experimental"}]}}"#
    }

    struct Rig {
        let root: URL, engine: BundledEngine, prefix: URL, exe: URL, log: EngineLog
        func file(_ rel: String) -> Data? { try? Data(contentsOf: prefix.appendingPathComponent("drive_c/windows/" + rel)) }
        func setup() -> BottleSetup { BottleSetup(engine: engine, prefix: prefix, environment: [:], log: log) }
        func cleanUp() { log.close(); try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func rig(choice: String) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("route-choice-\(UUID().uuidString)")
        let engineRoot = root.appendingPathComponent("engine")
        try write(Self.manifest(choice: choice), engineRoot.appendingPathComponent("ENGINE.json"))
        for tool in ["wine", "wineserver"] {
            let url = engineRoot.appendingPathComponent("wine/bin/\(tool)")
            try write("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"\(root.path)/calls.txt\"\nexit 0\n", url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let lib = engineRoot.appendingPathComponent("wine/lib/wine")
        for (arch, names) in [("aarch64-windows", ["kernel32.dll", "windowscodecs.dll"]),
                              ("i386-windows", ["kernel32.dll", "ddraw.dll", "d3d8.dll", "d3d9.dll", "wined3d.dll", "opengl32.dll"]),
                              ("x86_64-windows", ["wow64cpu.dll"])] {
            for name in names { try write("wine \(arch)/\(name)", lib.appendingPathComponent("\(arch)/\(name)")) }
        }
        try write("wine opengl32.so", lib.appendingPathComponent("aarch64-unix/opengl32.so"))
        try write("hbdx9 d3d9 shim", engineRoot.appendingPathComponent("graphics/i386-windows/d3d9.dll"))
        try write("hbdx9 helper", engineRoot.appendingPathComponent("graphics/i386-windows/hbdx9.dll"))
        try write("hbdx9 core", engineRoot.appendingPathComponent("graphics/aarch64-unix/hbdx9.so"))
        let engine = try #require(BundledEngine.load(from: engineRoot))
        let prefix = root.appendingPathComponent("prefix")
        try write("WINE REGISTRY", prefix.appendingPathComponent("system.reg"))
        let log = try EngineLog(url: root.appendingPathComponent("engine.log"))
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: [:], log: log)
        try setup.syncModules()
        try setup.install(try #require(engine.graphics.layer("wine-pe32-gdi")))
        let codec = try BottleUpdateCatalogue.digest(prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
        let marker: [String: Any] = ["engine": BottleSetup.engineStamp(engine), "engineRoot": BottleSetup.engineRootPath(engine),
                                     "layers": ["wine-pe32-gdi"], "wicRegistration": ["engine": BottleSetup.engineStamp(engine),
                                     "engineRoot": BottleSetup.engineRootPath(engine), "codec": codec]]
        try JSONSerialization.data(withJSONObject: marker).write(to: prefix.appendingPathComponent(BottleSetup.markerName))
        let game = root.appendingPathComponent("Gothic 3")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try FakePE.make(machine: 0x014c, imports: ["d3d9.dll", "d3dx9_40.dll"],
                        functions: ["d3d9.dll": ["Direct3DCreate9"], "d3dx9_40.dll": ["D3DXCreateEffect"]])
            .write(to: game.appendingPathComponent("Engine.dll"))
        let exe = game.appendingPathComponent("Gothic3.exe")
        try FakePE.make(machine: 0x014c, imports: ["kernel32.dll", "Engine.dll"]).write(to: exe)
        return Rig(root: root, engine: engine, prefix: prefix, exe: exe, log: log)
    }

    /// Gothic's layout (renderer in Engine.dll, GraphicsProbe fallback of 0001) → D3D9 → the layer the package names.
    @Test(arguments: ["wine-pe32-d3d9-gl", "hbdx9-d3d9-x86"])
    func gothicGoesWhereThePackageSays(choice: String) throws {
        let rig = try rig(choice: choice)
        defer { rig.cleanUp() }
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: rig.exe, profiles: []), engine: rig.engine)
        #expect(plan.decision == .launch)
        #expect(plan.api == .d3d9)
        #expect(plan.candidates == [.d3d9: .importTable])
        #expect(plan.layer?.id == choice)
        #expect(plan.route?.redist == ["d3dx9"])
        #expect(rig.engine.incompleteLayers.isEmpty)
        if choice == "hbdx9-d3d9-x86" {
            #expect(plan.environment["WINE_D3D_CONFIG"] == nil)
            #expect(plan.environment["WINEDLLOVERRIDES"]?.hasPrefix("d3d9=n,b") == true)
        } else {
            #expect(plan.environment["WINE_D3D_CONFIG"] == "renderer=gl")
        }
        // DirectDraw / D3D8 keep GDI whatever the D3D9 choice is.
        let ddraw = rig.root.appendingPathComponent("Gothic 3/heroes.exe")
        try FakePE.make(machine: 0x014c, imports: ["ddraw.dll"]).write(to: ddraw)
        #expect(GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: ddraw, profiles: []), engine: rig.engine).layer?.id == "wine-pe32-gdi")
    }

    /// The bottle swaps the chosen layer in and GDI back out, completely (HBDX9's own helper DLL leaves with it), and the
    /// game's Microsoft D3DX stays through every swap — for either choice.
    @Test(.enabled(if: RealCabinets.present), arguments: ["wine-pe32-d3d9-gl", "hbdx9-d3d9-x86"])
    func layerSwapsKeepTheGameRedist(choice: String) throws {
        let rig = try rig(choice: choice)
        defer { rig.cleanUp() }
        let store = rig.root.appendingPathComponent("store")
        let native = try GameRedist.extract(RealCabinets.cabinet("Nov2008_d3dx9_40_x86.cab"))
        try GameRedist.store(native, in: store)
        let install = GameRedist.Install(dll: "d3dx9_40.dll", bits: 32, sha256: GameRedist.sha256(native),
                                         version: "9.24.950.2656", cabinet: "Nov2008_d3dx9_40_x86.cab")
        var setup = rig.setup()
        setup.redistStore = store
        let chosen = try #require(rig.engine.graphics.layer(choice))
        let gdi = try #require(rig.engine.graphics.layer("wine-pe32-gdi"))
        try setup.prepareIfNeeded(requiredLayer: chosen, gameRedist: [install])
        #expect(rig.file("syswow64/d3dx9_40.dll") == native)
        if choice == "hbdx9-d3d9-x86" {
            #expect(rig.file("syswow64/d3d9.dll") == Data("hbdx9 d3d9 shim".utf8))
            #expect(rig.file("syswow64/hbdx9.dll") == Data("hbdx9 helper".utf8))
        } else {
            #expect(rig.file("syswow64/d3d9.dll") == Data("wine i386-windows/d3d9.dll".utf8))
        }
        try setup.prepareIfNeeded(requiredLayer: gdi) // a DirectDraw game next
        #expect(rig.file("syswow64/d3d9.dll") == Data("wine i386-windows/d3d9.dll".utf8))
        #expect(rig.file("syswow64/hbdx9.dll") == nil)
        #expect(rig.file("syswow64/d3dx9_40.dll") == native)
        try setup.prepareIfNeeded(requiredLayer: chosen)
        #expect(rig.file("syswow64/d3dx9_40.dll") == native)
        #expect(BottleSetup.recordedRedist(prefix: rig.prefix) == [install])
    }

    /// Switching the renderer is ONE field of the package: the two manifests differ only in the route's layer.
    @Test func switchingIsOneField() {
        let a = Self.manifest(choice: "wine-pe32-d3d9-gl"), b = Self.manifest(choice: "hbdx9-d3d9-x86")
        #expect(a.replacingOccurrences(of: #""layer":"wine-pe32-d3d9-gl","status""#, with: #""layer":"hbdx9-d3d9-x86","status""#) == b)
    }
}
