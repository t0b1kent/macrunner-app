import Foundation
import Testing
@testable import MacRunnerControlCenter

/// GOTHIC3 07.11.2026 — 0006: launcher wiring. The route asks (ENGINE.json `routes[].redist`), the launcher resolves
/// the game's own cabinet, the bottle gets the file as its last step, and only the program gets the load order.
/// Fake engine whose `wine` records every call with its WINEDLLOVERRIDES; nothing of Wine really runs.
struct GameRedistLaunchTests {
    struct Rig {
        let root: URL
        let engine: BundledEngine
        let prefix: URL
        let store: URL
        let exe: URL
        var calls: [String] { ((try? String(contentsOf: root.appendingPathComponent("wine-calls.txt"), encoding: .utf8)) ?? "")
            .split(separator: "\n").map(String.init) }
        var syswow64D3DX: Data? { try? Data(contentsOf: prefix.appendingPathComponent("drive_c/windows/syswow64/d3dx9_40.dll")) }
        func plan() -> GraphicsPlan { GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: exe), engine: engine) }
        func run() throws -> LauncherResult {
            let launcher = EngineLauncher(engine: engine, prefix: prefix)
            launcher.redistStore = store
            let runs = root.appendingPathComponent("run-\(UUID().uuidString)")
            return launcher.run(exe: exe, arguments: [], workdir: nil, extraEnvironment: [:], runDirectory: runs, graphics: plan())
        }
        func receipt(of result: LauncherResult) throws -> [String: Any] {
            let path = try #require(result.stderrPath)
            let url = URL(fileURLWithPath: path).deletingLastPathComponent().appendingPathComponent("launch-receipt.json")
            return try #require(try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        }
        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// `redist`: the JSON of the route's `redist` field, nil — absent (1.1.0 schema). `cabinet`: ship the real one.
    private func rig(redist: String?, cabinet: Bool) throws -> Rig {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("redist-launch-\(UUID().uuidString)")
        let engineRoot = root.appendingPathComponent("engine")
        let route = #"{"api":"d3d9","arch":"x86","layer":"pe32-d3d9-test","status":"experimental""#
            + (redist.map { #","redist":\#($0)"# } ?? "") + "}"
        let manifest = #"{"name":"redist-launch","environment":{},"graphics":{"layers":[{"id":"pe32-d3d9-test","title":"t","modules":{"wine/lib/wine/i386-windows":["d3d9.dll","wined3d.dll"]},"environment":{"WINE_D3D_CONFIG":"renderer=gl","WINEDLLOVERRIDES":"d3d9=b;wined3d=b"}}],"routes":["#
            + route + #"],"architectures":[{"arch":"x86","status":"experimental"}]}}"#
        try write(Data(manifest.utf8), engineRoot.appendingPathComponent("ENGINE.json"))
        let calls = root.appendingPathComponent("wine-calls.txt").path
        for tool in ["wine", "wineserver"] {
            let url = engineRoot.appendingPathComponent("wine/bin/\(tool)")
            try write(Data("#!/bin/sh\nprintf '%s | %s\\n' \"$*\" \"$WINEDLLOVERRIDES\" >> \"\(calls)\"\nexit 0\n".utf8), url)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
        let lib = engineRoot.appendingPathComponent("wine/lib/wine")
        for (arch, names) in [("aarch64-windows", ["kernel32.dll", "windowscodecs.dll"]),
                              ("i386-windows", ["kernel32.dll", "d3dx9_40.dll", "d3d9.dll", "wined3d.dll"]),
                              ("x86_64-windows", ["wow64cpu.dll"])] {
            for name in names { try write(Data("wine-builtin \(arch)/\(name)".utf8), lib.appendingPathComponent("\(arch)/\(name)")) }
        }
        let engine = try #require(BundledEngine.load(from: engineRoot))
        // A bottle that is ready for this engine (no Wine on the preparation route except WIC after a layer switch).
        let prefix = root.appendingPathComponent("prefix")
        try write(Data("WINE REGISTRY".utf8), prefix.appendingPathComponent("system.reg"))
        let log = try EngineLog(url: root.appendingPathComponent("setup.log"))
        try BottleSetup(engine: engine, prefix: prefix, environment: [:], log: log).syncModules()
        log.close()
        let codec = try BottleUpdateCatalogue.digest(prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
        let marker: [String: Any] = ["engine": BottleSetup.engineStamp(engine), "engineRoot": BottleSetup.engineRootPath(engine),
                                     "layers": [String](), "wicRegistration": ["engine": BottleSetup.engineStamp(engine),
                                     "engineRoot": BottleSetup.engineRootPath(engine), "codec": codec]]
        try JSONSerialization.data(withJSONObject: marker).write(to: prefix.appendingPathComponent(BottleSetup.markerName))
        // Gothic 3 layout: exe → Engine.dll → d3d9 + d3dx9_40 (D3DXCreateEffect).
        let game = root.appendingPathComponent("Gothic 3")
        try write(FakePE.make(machine: 0x014c, imports: ["d3d9.dll", "d3dx9_40.dll"],
                              functions: ["d3d9.dll": ["Direct3DCreate9"], "d3dx9_40.dll": ["D3DXCreateEffect"]]),
                  game.appendingPathComponent("Engine.dll"))
        let exe = game.appendingPathComponent("Gothic3.exe")
        try write(FakePE.make(machine: 0x014c, imports: ["kernel32.dll", "Engine.dll"]), exe)
        if cabinet {
            let redist = game.appendingPathComponent("__redist/DirectX")
            try FileManager.default.createDirectory(at: redist, withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: #require(RealCabinets.directory).appendingPathComponent("Nov2008_d3dx9_40_x86.cab"),
                                             to: redist.appendingPathComponent("Nov2008_d3dx9_40_x86.cab"))
        }
        return Rig(root: root, engine: engine, prefix: prefix, store: root.appendingPathComponent("store"), exe: exe)
    }

    @Test func routePolicyIsData() throws {
        let rig = try rig(redist: #"["d3dx9"]"#, cabinet: false)
        defer { rig.cleanUp() }
        var plan = rig.plan()
        #expect(plan.route?.redist == ["d3dx9"])
        #expect(!EngineLauncher.resolveRedist(exe: rig.exe, plan: plan, store: rig.store, appEnvironment: [:]).warnings.isEmpty)
        let off = EngineLauncher.resolveRedist(exe: rig.exe, plan: plan, store: rig.store, appEnvironment: ["MACRUNNER_GAME_REDIST": "0"])
        #expect(off.installs.isEmpty && off.warnings.isEmpty && off.notes == ["redist: switched off by MACRUNNER_GAME_REDIST=0"])
        plan.route = GraphicsRoute(api: .d3d9, arch: .x86, layer: "pe32-d3d9-test", status: .experimental, evidence: nil)
        #expect(EngineLauncher.resolveRedist(exe: rig.exe, plan: plan, store: rig.store, appEnvironment: [:]) == GameRedist.Resolution())
        plan.arch = .arm64
        plan.route?.redist = ["d3dx9"]
        #expect(EngineLauncher.resolveRedist(exe: rig.exe, plan: plan, store: rig.store, appEnvironment: [:]) == GameRedist.Resolution())
    }

    @Test func warmSignatureCarriesTheRedistSet() throws {
        let rig = try rig(redist: nil, cabinet: false)
        defer { rig.cleanUp() }
        let a = GameRedist.Install(dll: "d3dx9_40.dll", bits: 32, sha256: "aa", version: "v", cabinet: "c")
        let none = try WarmBottleSessions.signature(engine: rig.engine, environment: [:], layer: nil)
        let one = try WarmBottleSessions.signature(engine: rig.engine, environment: [:], layer: nil, gameRedist: [a])
        #expect(none != one)
        #expect(one == (try WarmBottleSessions.signature(engine: rig.engine, environment: [:], layer: nil, gameRedist: [a])))
    }

    /// The whole chain on Gothic's layout: file in syswow64 (Microsoft bytes), load order only in the game's process.
    @Test(.enabled(if: RealCabinets.present)) func gothicLaunchGetsNativeD3DXAndItsLoadOrder() throws {
        let rig = try rig(redist: #"["d3dx9"]"#, cabinet: true)
        defer { rig.cleanUp() }
        let result = try rig.run()
        #expect(result.status == "PASS")
        #expect(!(result.graphicsWarnings ?? []).contains { $0.contains("DirectX file") }, "\(result.graphicsWarnings ?? [])")
        #expect(GameRedist.sha256(try #require(rig.syswow64D3DX)) == "16fd909aeb68d0d1aca8529dc7f78880b97d6649d70ce8d03a2c858bc28e216b")
        let game = try #require(rig.calls.first { $0.contains("Gothic3.exe") })
        #expect(game.hasSuffix("| d3d9=b;wined3d=b;d3dx9_40=n,b"), "\(game)")
        // Scope: every other Wine process (here: the WIC registration of the preparation) has no d3dx9 order.
        // (wineserver -w waits with the program's environment; the server loads no DLLs.)
        let others = rig.calls.filter { !$0.contains("Gothic3.exe") && !$0.hasPrefix("-") }
        #expect(!others.isEmpty)
        for call in others { #expect(!call.contains("d3dx9"), "\(call)") }
        #expect((try rig.receipt(of: result))["gameRedist"] as? [String] ==
                ["drive_c/windows/syswow64/d3dx9_40.dll@16fd909aeb68d0d1aca8529dc7f78880b97d6649d70ce8d03a2c858bc28e216b"])
        #expect(BottleSetup.recordedRedist(prefix: rig.prefix).map(\.dll) == ["d3dx9_40.dll"])
    }

    /// Scope: after Gothic put Microsoft's d3dx9_40 into the bottle, ANOTHER program of the same bottle gets Wine's
    /// builtin order for it (measured: without an order the native file would load for everybody).
    @Test(.enabled(if: RealCabinets.present)) func anotherProgramOfTheBottleKeepsTheBuiltin() throws {
        let rig = try rig(redist: #"["d3dx9"]"#, cabinet: true)
        defer { rig.cleanUp() }
        #expect(try rig.run().status == "PASS")
        let other = rig.root.appendingPathComponent("Other/other.exe")
        try FileManager.default.createDirectory(at: other.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FakePE.make(machine: 0x014c, imports: ["d3d9.dll"], functions: ["d3d9.dll": ["Direct3DCreate9"]]).write(to: other)
        let launcher = EngineLauncher(engine: rig.engine, prefix: rig.prefix)
        launcher.redistStore = rig.store
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: other), engine: rig.engine)
        let result = launcher.run(exe: other, arguments: [], workdir: nil, extraEnvironment: [:],
                                  runDirectory: rig.root.appendingPathComponent("run-other"), graphics: plan)
        #expect(result.status == "PASS")
        let call = try #require(rig.calls.first { $0.contains("other.exe") })
        #expect(call.hasSuffix("| d3d9=b;wined3d=b;d3dx9_40=b"), "\(call)")
        #expect(GameRedist.sha256(try #require(rig.syswow64D3DX)) == "16fd909aeb68d0d1aca8529dc7f78880b97d6649d70ce8d03a2c858bc28e216b")
    }

    /// No cabinet next to the game: the player is told (game details show the summary), nothing is guessed.
    @Test func missingCabinetWarnsThePlayer() throws {
        let rig = try rig(redist: #"["d3dx9"]"#, cabinet: false)
        defer { rig.cleanUp() }
        let result = try rig.run()
        #expect(result.status == "PASS")
        let warning = try #require(result.graphicsWarnings?.first { $0.contains("DirectX files") })
        #expect(warning.contains("d3dx9_40.dll"))
        #expect(result.graphicsSummary?.hasSuffix(" · " + warning) == true)
        #expect(try #require(rig.syswow64D3DX) == Data("wine-builtin i386-windows/d3dx9_40.dll".utf8))
        let game = try #require(rig.calls.first { $0.contains("Gothic3.exe") })
        #expect(!game.contains("d3dx9"))
    }

    /// Control hand: a package without `redist` on the route (1.1.0) changes nothing — even with the cabinet there.
    @Test(.enabled(if: RealCabinets.present)) func routeWithoutRedistKeepsTheOldBehaviour() throws {
        let rig = try rig(redist: nil, cabinet: true)
        defer { rig.cleanUp() }
        let result = try rig.run()
        #expect(result.status == "PASS")
        #expect(!(result.graphicsWarnings ?? []).contains { $0.contains("DirectX file") })
        #expect(try #require(rig.syswow64D3DX) == Data("wine-builtin i386-windows/d3dx9_40.dll".utf8))
        let game = try #require(rig.calls.first { $0.contains("Gothic3.exe") })
        #expect(game.hasSuffix("| d3d9=b;wined3d=b"), "\(game)")
        #expect(!FileManager.default.fileExists(atPath: rig.store.path))
    }
}
