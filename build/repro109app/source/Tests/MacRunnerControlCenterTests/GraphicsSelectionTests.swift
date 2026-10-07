import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Синтетический PE: заголовки, одна секция с таблицами импорта, отложенного импорта и строками.
enum FakePE {
    /// `functions` — имена функций по DLL обычного импорта (таблица имён импорта).
    static func make(machine: UInt16 = 0x8664, imports: [String] = [], delayImports: [String] = [],
                     functions: [String: [String]] = [:],
                     utf16Strings: [String] = [], asciiStrings: [String] = [], oldDelayFormat: Bool = false) -> Data {
        let pe32Plus = machine != 0x014c
        let imageBase: UInt64 = pe32Plus ? 0x1_4000_0000 : 0x40_0000
        let optionalSize = pe32Plus ? 240 : 224
        let sectionRVA: UInt32 = 0x1000, sectionFile: UInt32 = 0x400

        // Раскладка секции: [дескрипторы импорта][дескрипторы отложенного][имена DLL][hint/name][таблицы имён].
        let importTableSize = (imports.count + 1) * 20
        let delayTableSize = (delayImports.count + 1) * 32
        var blob = Data(count: importTableSize + delayTableSize)
        func put(_ data: Data) -> UInt32 {
            let rva = sectionRVA + UInt32(blob.count)
            blob.append(data)
            return rva
        }
        let nameRVAs = (imports + delayImports).map { put(Data($0.utf8) + Data([0])) }
        var lookupRVAs: [UInt32] = []
        for dll in imports {
            let names = functions[dll] ?? []
            let entries = names.map { put(Data([0, 0]) + Data($0.utf8) + Data([0, 0])) }
            if entries.isEmpty { lookupRVAs.append(0); continue }
            var table = Data()
            for rva in entries { table.append(pe32Plus ? le64(UInt64(rva)) : le32(rva)) }
            table.append(Data(count: pe32Plus ? 8 : 4))
            lookupRVAs.append(put(table))
        }
        for (i, _) in imports.enumerated() {
            blob.replaceSubrange((i * 20)..<(i * 20 + 20),
                                 with: le32(lookupRVAs[i]) + le32(0) + le32(0) + le32(nameRVAs[i]) + le32(0))
        }
        for i in 0..<delayImports.count {
            let rva = nameRVAs[imports.count + i]
            let field = oldDelayFormat ? UInt32(truncatingIfNeeded: imageBase + UInt64(rva)) : rva
            let at = importTableSize + i * 32
            blob.replaceSubrange(at..<(at + 8), with: le32(oldDelayFormat ? 0 : 1) + le32(field))
        }
        for text in asciiStrings { _ = put(Data(text.utf8) + Data([0])) }
        for text in utf16Strings { _ = put(Data(text.utf8.flatMap { [$0, 0] }) + Data([0, 0])) }
        let section = blob

        var file = Data(count: 0x40)
        file[0] = 0x4D; file[1] = 0x5A
        file.replaceSubrange(0x3C..<0x40, with: le32(0x40))
        file.append(Data("PE".utf8) + Data([0, 0]))
        file.append(le16(machine) + le16(1) + le32(0) + le32(0) + le32(0) + le16(UInt16(optionalSize)) + le16(0x22))
        var optional = Data(count: optionalSize)
        optional.replaceSubrange(0..<2, with: le16(pe32Plus ? 0x20b : 0x10b))
        if pe32Plus {
            optional.replaceSubrange(24..<32, with: le64(imageBase))
            optional.replaceSubrange(108..<112, with: le32(16))
        } else {
            optional.replaceSubrange(28..<32, with: le32(UInt32(imageBase)))
            optional.replaceSubrange(92..<96, with: le32(16))
        }
        let dirs = pe32Plus ? 112 : 96
        if !imports.isEmpty {
            optional.replaceSubrange((dirs + 8)..<(dirs + 16), with: le32(sectionRVA) + le32(UInt32(importTableSize)))
        }
        if !delayImports.isEmpty {
            optional.replaceSubrange((dirs + 13 * 8)..<(dirs + 13 * 8 + 8),
                                     with: le32(sectionRVA + UInt32(importTableSize)) + le32(UInt32(delayTableSize)))
        }
        file.append(optional)
        var header = Data(".rdata".utf8); header.append(Data(count: 2))
        header.append(le32(UInt32(section.count)) + le32(sectionRVA) + le32(UInt32(section.count)) + le32(sectionFile))
        header.append(Data(count: 16))
        file.append(header)
        file.append(Data(count: Int(sectionFile) - file.count))
        file.append(section)
        return file
    }

    private static func le16(_ v: UInt16) -> Data { Data([UInt8(v & 0xff), UInt8(v >> 8)]) }
    private static func le32(_ v: UInt32) -> Data { Data((0..<4).map { UInt8((v >> (8 * $0)) & 0xff) }) }
    private static func le64(_ v: UInt64) -> Data { Data((0..<8).map { UInt8((v >> (8 * UInt64($0))) & 0xff) }) }
}

struct GraphicsSelectionTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("graphics-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ data: Data, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
    }

    /// Движок с матрицей как у выпускного пакета: DX11/10 x64 через слой DXMT, DX12 нет,
    /// 32 бита недоступны. `dropModule` — сделать слой неполным.
    private func engine(dropModule: String? = nil, extraLayer: Bool = false,
                        layerEnvironment: [String: String] = [:]) throws -> BundledEngine {
        let root = try tempDir()
        var layers: [[String: Any]] = [[
            "id": "dxmt", "title": "DXMT",
            "modules": ["graphics/x86_64-windows": ["d3d11.dll", "dxgi.dll", "winemetal.dll"]],
            "unix": ["graphics/aarch64-unix/winemetal.so"],
            "environment": layerEnvironment,
        ]]
        if extraLayer {
            layers.append(["id": "other", "title": "Other D3D11",
                           "modules": ["graphics-other/x86_64-windows": ["d3d11.dll", "dxgi.dll"]]])
            for name in ["d3d11.dll", "dxgi.dll"] {
                try write(Data("other/\(name)".utf8), root.appendingPathComponent("graphics-other/x86_64-windows/\(name)"))
            }
        }
        let routes: [[String: Any]] = [
            ["api": "d3d11", "arch": "x86_64", "layer": "dxmt", "status": "experimental", "evidence": "test"],
            ["api": "d3d10", "arch": "x86_64", "layer": "dxmt", "status": "experimental"],
            ["api": "d3d12", "arch": "x86_64", "status": "unavailable", "evidence": "no d3d12"],
            ["api": "d3d12-rt", "arch": "x86_64", "status": "deferred"],
            ["api": "d3d9", "arch": "x86_64", "layer": "other", "status": "fixtures", "evidence": "fixture"],
        ]
        let manifest: [String: Any] = [
            "name": "test-engine", "environment": ["WINEDEBUG": "-all"],
            "graphics": ["layers": layers, "routes": routes, "architectures": [
                ["arch": "x86_64", "status": "experimental"],
                ["arch": "x86", "status": "unavailable", "evidence": "needs Apple permission"],
            ]],
        ]
        try write(try JSONSerialization.data(withJSONObject: manifest), root.appendingPathComponent("ENGINE.json"))
        let wine = root.appendingPathComponent("wine/bin/wine")
        try write(Data("#!/bin/sh\n".utf8), wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        for name in ["d3d11.dll", "dxgi.dll", "winemetal.dll"] where name != dropModule {
            try write(Data("dxmt/\(name)".utf8), root.appendingPathComponent("graphics/x86_64-windows/\(name)"))
        }
        try write(Data("so".utf8), root.appendingPathComponent("graphics/aarch64-unix/winemetal.so"))
        for arch in ["aarch64-windows", "i386-windows"] {
            try write(Data("wine/\(arch)/d3d11".utf8), root.appendingPathComponent("wine/lib/wine/\(arch)/d3d11.dll"))
        }
        return try #require(BundledEngine.load(from: root))
    }

    private func exe(_ pe: Data, name: String = "game.exe", in dir: URL? = nil) throws -> URL {
        let url = (try dir ?? tempDir()).appendingPathComponent(name)
        try write(pe, url)
        return url
    }

    // MARK: - Чтение PE

    @Test func readsImportsAndDelayImportsOfPE32Plus() throws {
        let url = try exe(FakePE.make(imports: ["KERNEL32.dll", "d3d11.dll"], delayImports: ["d3d12.dll"]))
        let pe = try PEImportReader.read(url)
        #expect(pe.machine == 0x8664)
        #expect(pe.imports == ["kernel32.dll", "d3d11.dll"])
        #expect(pe.delayImports == ["d3d12.dll"])
    }

    @Test func readsOldVC6DelayFormatOfPE32() throws {
        let url = try exe(FakePE.make(machine: 0x014c, imports: ["d3d9.dll"], delayImports: ["ddraw.dll"], oldDelayFormat: true))
        let pe = try PEImportReader.read(url)
        #expect(pe.machine == 0x014c)
        #expect(pe.delayImports == ["ddraw.dll"])
    }

    @Test func findsDynamicallyLoadedNamesInUTF16() throws {
        let url = try exe(FakePE.make(imports: ["kernel32.dll"], utf16Strings: ["D3D12.DLL"]))
        let detection = GraphicsProbe.detect(exe: url, profiles: [])
        #expect(detection.candidates == [.d3d12: .stringReference])
    }

    @Test func d3d9ImportedOnlyForPerfMarkersIsNotEvidence() throws {
        let url = try exe(FakePE.make(imports: ["kernel32.dll", "d3d9.dll"],
                                      functions: ["d3d9.dll": ["D3DPERF_BeginEvent", "D3DPERF_EndEvent"]]))
        let pe = try PEImportReader.read(url)
        #expect(pe.functions["d3d9.dll"] == ["D3DPERF_BeginEvent", "D3DPERF_EndEvent"])
        let detection = GraphicsProbe.detect(exe: url, profiles: [])
        #expect(detection.candidates[.d3d9] != .importTable)
        #expect(detection.notes.contains { $0.contains("helper functions") })
    }

    @Test func d3dxMathImportIsNotD3D9Evidence() throws {
        let url = try exe(FakePE.make(imports: ["d3d11.dll", "d3dx9_42.dll"],
                                      functions: ["d3d11.dll": ["D3D11CreateDeviceAndSwapChain"],
                                                  "d3dx9_42.dll": ["D3DXVec3TransformCoord", "D3DXMatrixMultiply"]]))
        let detection = GraphicsProbe.detect(exe: url, profiles: [])
        #expect(detection.candidates[.d3d11] == .importTable)
        #expect(detection.candidates[.d3d9] != .importTable)
    }

    @Test func realD3D9RenderingImportStillCounts() throws {
        let url = try exe(FakePE.make(machine: 0x014c, imports: ["d3d9.dll"],
                                      functions: ["d3d9.dll": ["Direct3DCreate9", "D3DPERF_BeginEvent"]]))
        #expect(GraphicsProbe.detect(exe: url, profiles: []).candidates[.d3d9] == .importTable)
    }

    // MARK: - Выбор маршрута

    @Test func severalAPIsMentionedOnlyAsStringsStayUnknown() throws {
        let engine = try engine()
        let url = try exe(FakePE.make(imports: ["kernel32.dll"], asciiStrings: ["d3d11.dll", "vulkan-1.dll", "opengl32.dll"]))
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: url, profiles: []), engine: engine)
        #expect(plan.decision == .launch)
        #expect(plan.api == nil)
        #expect(plan.warnings.contains { $0.contains("Vulkan") && $0.contains("DirectX 11") })
    }

    @Test func d3d11GameGetsTheDXMTLayer() throws {
        let engine = try engine()
        let detection = GraphicsProbe.detect(exe: try exe(FakePE.make(imports: ["d3d11.dll", "dxgi.dll"])), profiles: [])
        let plan = GraphicsSelector.plan(detection: detection, engine: engine)
        #expect(plan.decision == .launch)
        #expect(plan.api == .d3d11 && plan.arch == .x86_64)
        #expect(plan.layer?.id == "dxmt")
        #expect(!plan.warnings.isEmpty)   // экспериментальный маршрут назван, текст — на языке системы
    }

    @Test func d3d12GameIsRefusedNotDowngraded() throws {
        let engine = try engine()
        let detection = GraphicsProbe.detect(exe: try exe(FakePE.make(imports: ["d3d12.dll", "dxgi.dll"])), profiles: [])
        let plan = GraphicsSelector.plan(detection: detection, engine: engine)
        #expect(plan.api == .d3d12)
        guard case .refuse(let reason) = plan.decision else { Issue.record("D3D12 must be refused"); return }
        #expect(reason.contains("DirectX 12"))
        #expect(plan.layer == nil)
    }

    @Test func staticD3D11WithDelayedD3D12LaunchesAndWarns() throws {
        let engine = try engine()
        let detection = GraphicsProbe.detect(exe: try exe(FakePE.make(imports: ["d3d11.dll"], delayImports: ["d3d12.dll"])), profiles: [])
        let plan = GraphicsSelector.plan(detection: detection, engine: engine)
        #expect(plan.decision == .launch && plan.api == .d3d11)
        #expect(plan.warnings.contains { $0.contains("DirectX 12") })
    }

    @Test func unknownAPIStaysUnknown() throws {
        let engine = try engine()
        let detection = GraphicsProbe.detect(exe: try exe(FakePE.make(imports: ["kernel32.dll", "user32.dll"])), profiles: [])
        let plan = GraphicsSelector.plan(detection: detection, engine: engine)
        #expect(plan.decision == .launch)
        #expect(plan.api == nil && plan.layer == nil)
        #expect(!plan.warnings.isEmpty)
    }

    @Test func dxgiOnlyIsNotGuessedAsD3D11() throws {
        let engine = try engine()
        let detection = GraphicsProbe.detect(exe: try exe(FakePE.make(imports: ["dxgi.dll"])), profiles: [])
        #expect(detection.dxgiOnly)
        let plan = GraphicsSelector.plan(detection: detection, engine: engine)
        #expect(plan.api == nil)
        #expect(plan.warnings.contains { $0.contains("DXGI") })
    }

    @Test func thirtyTwoBitIsRefusedEvenWithoutGraphics() throws {
        let engine = try engine()
        let detection = GraphicsProbe.detect(exe: try exe(FakePE.make(machine: 0x014c, imports: ["kernel32.dll"])), profiles: [])
        let plan = GraphicsSelector.plan(detection: detection, engine: engine)
        #expect(plan.arch == .x86)
        guard case .refuse(let reason) = plan.decision else { Issue.record("32-bit must be refused"); return }
        #expect(reason.contains("needs Apple permission"))
    }

    @Test func raytracingIsNeverAutoSelected() throws {
        let engine = try engine()
        var detection = GraphicsProbe.detect(exe: try exe(FakePE.make(imports: ["d3d11.dll"])), profiles: [])
        detection.evidence.append(.init(api: .d3d12RT, strength: .profile, source: "test"))
        let plan = GraphicsSelector.plan(detection: detection, engine: engine)
        #expect(plan.api == .d3d11)
    }

    @Test func manualOverrideIsHonouredAndStillChecked() throws {
        let engine = try engine()
        let detection = GraphicsProbe.detect(exe: try exe(FakePE.make(imports: ["d3d11.dll"])), profiles: [])
        let plan = GraphicsSelector.plan(detection: detection, engine: engine, override: .d3d12)
        #expect(plan.overridden && plan.api == .d3d12)
        #expect(plan.decision != .launch)
    }

    @Test func incompleteLayerIsRefused() throws {
        let engine = try engine(dropModule: "winemetal.dll")
        #expect(engine.incompleteLayers["dxmt"] == ["graphics/x86_64-windows/winemetal.dll"])
        let detection = GraphicsProbe.detect(exe: try exe(FakePE.make(imports: ["d3d11.dll"])), profiles: [])
        let plan = GraphicsSelector.plan(detection: detection, engine: engine)
        guard case .refuse(let reason) = plan.decision else { Issue.record("incomplete layer must be refused"); return }
        #expect(reason.contains("winemetal.dll"))
    }

    @Test func launcherProfileNeedsItsGameNextToIt() throws {
        let profile = GraphicsProfile(id: "er", name: "ER", exe: ["start_protected_game.exe", "eldenring.exe"],
                                      siblings: ["eldenring.exe"], apis: [.d3d12], renderArgs: nil, evidence: "test")
        let lone = try exe(FakePE.make(imports: ["kernel32.dll"]), name: "start_protected_game.exe")
        #expect(GraphicsProbe.detect(exe: lone, profiles: [profile]).profile == nil)
        let dir = try tempDir()
        _ = try exe(FakePE.make(imports: ["d3d12.dll"]), name: "eldenring.exe", in: dir)
        let launcher = try exe(FakePE.make(imports: ["kernel32.dll"]), name: "start_protected_game.exe", in: dir)
        let detection = GraphicsProbe.detect(exe: launcher, profiles: [profile])
        #expect(detection.profile?.id == "er")
        #expect(detection.candidates[.d3d12] == .profile)
    }

    @Test func onlyExactBundledHollowKnightProfileGetsStartupOptimization() throws {
        let engine = try engine()
        let key = "MACRUNNER_HB_MAPSCAN_SKIP"
        for name in ["Hollow Knight.exe", "hollow_knight.exe"] {
            let game = try exe(FakePE.make(imports: ["d3d11.dll"]), name: name)
            let detection = GraphicsProbe.detect(exe: game)
            let plan = GraphicsSelector.plan(detection: detection, engine: engine)
            #expect(detection.profile?.id == "hollow-knight")
            #expect(plan.decision == .launch && plan.layer?.id == "dxmt")
            #expect(plan.environment == [key: "1"])
        }
        for name in ["game.exe", "Not Hollow Knight.exe", "Hollow Knight.exe.bak", "AbzuGame.exe"] {
            let game = try exe(FakePE.make(imports: ["d3d11.dll"]), name: name)
            let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: game), engine: engine)
            #expect(plan.decision == .launch && plan.layer?.id == "dxmt")
            #expect(plan.environment[key] == nil)
        }
    }

    @Test func modifiedExternalProfileCannotSupplyProcessEnvironment() throws {
        let engine = try engine()
        var profile = try #require(GraphicsProfile.bundled.first { $0.id == "hollow-knight" })
        profile.environment = ["MACRUNNER_HB_MAPSCAN_SKIP": "1", "UNTRUSTED_SETTING": "1"]
        let game = try exe(FakePE.make(imports: ["d3d11.dll"]), name: "Hollow Knight.exe")
        let detection = GraphicsProbe.detect(exe: game, profiles: [profile])
        #expect(detection.profile != nil)
        let plan = GraphicsSelector.plan(detection: detection, engine: engine)
        #expect(plan.decision == .launch)
        #expect(plan.environment.isEmpty)
    }

    @Test func selectedLayerEnvironmentTakesPriorityOverGameProfile() throws {
        let key = "MACRUNNER_HB_MAPSCAN_SKIP"
        let engine = try engine(layerEnvironment: [key: "0", "LAYER_SETTING": "1"])
        let game = try exe(FakePE.make(imports: ["d3d11.dll"]), name: "Hollow Knight.exe")
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: game), engine: engine)
        #expect(plan.decision == .launch && plan.layer?.id == "dxmt")
        #expect(plan.environment == [key: "0", "LAYER_SETTING": "1"])
    }

    @Test func gameProfileEnvironmentDoesNotBypassRouteRefusal() throws {
        let engine = try engine()
        let game = try exe(FakePE.make(imports: ["d3d11.dll"]), name: "Hollow Knight.exe")
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: game), engine: engine,
                                         override: .d3d12)
        #expect(plan.decision != .launch && plan.overridden && plan.api == .d3d12)
        #expect(plan.environment.isEmpty)
    }

    @Test func unityPlayerIsExaminedForTheRenderer() throws {
        let dir = try tempDir()
        let game = try exe(FakePE.make(imports: ["kernel32.dll"]), name: "Hero.exe", in: dir)
        _ = try exe(FakePE.make(imports: ["d3d11.dll"]), name: "UnityPlayer.dll", in: dir)
        let detection = GraphicsProbe.detect(exe: game, profiles: [])
        #expect(detection.candidates[.d3d11] == .importTable)
        #expect(detection.evidence.contains { $0.source.hasPrefix("UnityPlayer.dll") })
    }

    // MARK: - Бутылка: слои

    private func readyBottle(_ engine: BundledEngine, layers: [String]) throws -> (BottleSetup, URL) {
        let prefix = try tempDir()
        try write(Data("WINE REGISTRY".utf8), prefix.appendingPathComponent("system.reg"))
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: ["TMPDIR": try tempDir().path],
                                log: try EngineLog(url: prefix.appendingPathComponent("log")))
        for id in layers { try setup.install(try #require(engine.graphics.layer(id))) }
        let marker: [String: Any] = ["engine": setup.engineStamp, "engineRoot": setup.engineRootPath, "layers": layers]
        try write(try JSONSerialization.data(withJSONObject: marker), prefix.appendingPathComponent(BottleSetup.markerName))
        return (setup, prefix)
    }

    @Test func switchingLayersReplacesTheWholeSetAndRestoresWine() throws {
        let engine = try engine(extraLayer: true)
        #expect(engine.graphics.conflicts(try #require(engine.graphics.layer("dxmt")), try #require(engine.graphics.layer("other"))))
        let (setup, prefix) = try readyBottle(engine, layers: ["dxmt"])
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        #expect(try String(contentsOf: system32.appendingPathComponent("winemetal.dll"), encoding: .utf8) == "dxmt/winemetal.dll")

        try setup.prepareIfNeeded(requiredLayer: engine.graphics.layer("other"))
        #expect(setup.installedLayers == ["other"])
        #expect(setup.isReady)
        #expect(try String(contentsOf: system32.appendingPathComponent("d3d11.dll"), encoding: .utf8) == "other/d3d11.dll")
        // winemetal есть только у DXMT: у Wine такого модуля нет — не должен остаться чужим хвостом.
        #expect(!FileManager.default.fileExists(atPath: system32.appendingPathComponent("winemetal.dll").path))
    }

    @Test func noSwitchUnderARunningGame() throws {
        let engine = try engine(extraLayer: true)
        let (setup, prefix) = try readyBottle(engine, layers: ["dxmt"])
        BottleSetup.beginRun(prefix: prefix)
        defer { BottleSetup.endRun(prefix: prefix) }
        #expect(throws: BottleSetup.SetupError.self) {
            try setup.prepareIfNeeded(requiredLayer: engine.graphics.layer("other"))
        }
        #expect(setup.installedLayers == ["dxmt"])
    }

    // MARK: - Журнал: чья графика загрузилась

    @Test func logRecordsGraphicsModuleProvenance() throws {
        let log = try EngineLog(url: try tempDir().appendingPathComponent("engine.log"))
        log.append(Data(#"00d8:trace:loaddll:build_module Loaded L"Z:\\Engine\\graphics\\x86_64-windows\\dxgi.dll" at 000000014D560000: builtin"#.utf8 + [0x0A]))
        log.append(Data(#"00d8:trace:loaddll:build_module Loaded L"C:\\windows\\system32\\wined3d.dll" at 00006FFFFD1D0000: builtin"#.utf8 + [0x0A]))
        log.append(Data(#"00d8:trace:loaddll:build_module Loaded L"C:\\windows\\system32\\kernel32.dll" at 00006FFFFFD80000: builtin"#.utf8 + [0x0A]))
        log.close()
        #expect(log.graphicsModules.map(\.name) == ["dxgi.dll", "wined3d.dll"])
        #expect(log.graphicsModules.first?.path == #"Z:\Engine\graphics\x86_64-windows\dxgi.dll"#)
        #expect(log.graphicsModules.first?.kind == "builtin")
    }

    @Test func wineServerSocketPathFollowsWine() throws {
        let prefix = try tempDir()
        let path = try #require(WineServerProbe.socketPath(prefix: prefix, environment: ["TMPDIR": "/private/tmp"]))
        #expect(path.hasPrefix("/private/tmp/.wine-\(getuid())/server-"))
        #expect(path.hasSuffix("/socket"))
        #expect(!WineServerProbe.isAlive(prefix: prefix, environment: ["TMPDIR": "/private/tmp"]))
    }
}

/// Разбор настоящих файлов (только чтение, без запуска). Список путей — в
/// `MACRUNNER_GRAPHICS_PROBE_FILES` через «:»; без него тест не выполняется.
struct GraphicsProbeRealFilesTests {
    static let files = (ProcessInfo.processInfo.environment["MACRUNNER_GRAPHICS_PROBE_FILES"] ?? "")
        .split(separator: ":").map(String.init)

    @Test(.enabled(if: !files.isEmpty)) func reportRealFiles() throws {
        for path in Self.files {
            let started = Date()
            let profiles = ProcessInfo.processInfo.environment["MACRUNNER_GRAPHICS_PROBE_NO_PROFILES"] == "1"
                ? [] : GraphicsProfile.bundled
            let detection = GraphicsProbe.detect(exe: URL(fileURLWithPath: path), profiles: profiles)
            let apis = detection.candidates.sorted { $0.key > $1.key }.map { "\($0.key.rawValue)=\($0.value)" }
            print("PROBE \(URL(fileURLWithPath: path).lastPathComponent) arch=\(detection.arch?.rawValue ?? "?") "
                  + "apis=\(apis) dxgiOnly=\(detection.dxgiOnly) profile=\(detection.profile?.id ?? "-") "
                  + "ms=\(Int(Date().timeIntervalSince(started) * 1000)) notes=\(detection.notes)")
        }
    }
}

/// Правила выбора, найденные на настоящих играх 23.09.
struct GraphicsSelectionRealCasesTests {
    private func engineAndExe(_ pe: Data) throws -> (BundledEngine, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("real-cases-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": "t", "environment": [:], "graphics": [
            "layers": [["id": "dxmt", "title": "DXMT", "modules": [:]]],
            "routes": [
                ["api": "d3d11", "arch": "x86_64", "layer": "dxmt", "status": "experimental"],
                ["api": "opengl", "arch": "x86_64", "layer": "wine", "status": "experimental"],
                ["api": "d3d9", "arch": "x86_64", "status": "unavailable"],
                ["api": "d3d12", "arch": "x86_64", "status": "unavailable"],
            ]]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: root.appendingPathComponent("ENGINE.json"))
        let wine = root.appendingPathComponent("wine/bin/wine")
        try Data("#!/bin/sh\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let exe = root.appendingPathComponent("game.exe")
        try pe.write(to: exe)
        return (try #require(BundledEngine.load(from: root)), exe)
    }

    /// Unity/UE4: статически и opengl32, и d3d11 — рисуют через D3D11.
    @Test func unityStyleImportsPreferD3D11OverOpenGL() throws {
        let (engine, exe) = try engineAndExe(FakePE.make(imports: ["opengl32.dll", "d3d11.dll"], delayImports: ["d3d12.dll"]))
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: exe, profiles: []), engine: engine)
        #expect(plan.api == .d3d11)
        #expect(plan.decision == .launch)
    }

    /// GZDoom (Hedon): импорт d3d9, рисует через OpenGL — не отказ, а запуск с предупреждением.
    @Test func unavailableImportDoesNotBlockAnAvailableAlternative() throws {
        let (engine, exe) = try engineAndExe(FakePE.make(imports: ["d3d9.dll"], asciiStrings: ["opengl32.dll"]))
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: exe, profiles: []), engine: engine)
        #expect(plan.decision == .launch)
        #expect(plan.api == .opengl)
        #expect(plan.warnings.contains { $0.contains("DirectX 9") })
    }

    /// Только DX12 — по-прежнему отказ, а не запуск «через DX11».
    @Test func d3d12OnlyIsStillRefused() throws {
        let (engine, exe) = try engineAndExe(FakePE.make(imports: ["d3d12.dll", "dxgi.dll"]))
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: exe, profiles: []), engine: engine)
        #expect(plan.decision != .launch)
    }

    /// Профиль с двумя рендерами и ключами: выбирается доступный, с его ключом запуска.
    @Test func profileRenderSwitchIsUsedForTheAvailableAPI() throws {
        let (engine, exe) = try engineAndExe(FakePE.make(imports: ["kernel32.dll"]))
        let profile = GraphicsProfile(id: "c", name: "C", exe: ["game.exe"], siblings: nil, apis: [.d3d9, .d3d11],
                                      renderArgs: ["d3d9": ["-dx9"], "d3d11": ["-dx11"]], evidence: "test")
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: exe, profiles: [profile]), engine: engine)
        #expect(plan.api == .d3d11)
        #expect(plan.extraArguments == ["-dx11"])
    }

    @Test func bundledProfilesDecodeAndNameTheirEvidence() {
        let profiles = GraphicsProfile.bundled
        #expect(profiles.count >= 10)
        #expect(profiles.allSatisfy { !$0.evidence.isEmpty && ($0.known ?? []).allSatisfy { !$0.evidence.isEmpty } })
        #expect(GraphicsProfile.match(exe: URL(fileURLWithPath: "/g/Hollow Knight.exe"), in: profiles)?.id == "hollow-knight")
    }
}
