import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Встроенный движок: всё, что проверяется без запуска Wine.
struct BundledEngineTests {
    private func tempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("bundled-engine-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func write(_ text: String, _ url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    /// Поддельный пакет: ENGINE.json, исполняемый wine и модули по архитектурам.
    private func fakeEngine(graphics: [String]) throws -> BundledEngine {
        let root = try tempDir()
        try write(#"{"name":"test-engine","environment":{"WINEDLLPATH":"${ENGINE}/fex:${DATA}/x"}}"#,
                  root.appendingPathComponent("ENGINE.json"))
        let wine = root.appendingPathComponent("wine/bin/wine")
        try write("#!/bin/sh\n", wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let lib = root.appendingPathComponent("wine/lib/wine")
        for (arch, names) in [("aarch64-windows", ["kernel32.dll", "ntdll.dll", "xtajit.dll", "comctl32_v6.dll", "d3d11.dll"]),
                              ("i386-windows", ["kernel32.dll", "ntdll.dll", "comctl32_v6.dll"]),
                              ("x86_64-windows", ["wow64cpu.dll", "wow64.dll", "wow64win.dll", "comctl32_v6.dll"])] {
            for name in names { try write("\(arch)/\(name)", lib.appendingPathComponent("\(arch)/\(name)")) }
        }
        for name in graphics {
            try write("dxmt/\(name)", root.appendingPathComponent("graphics/x86_64-windows/\(name)"))
        }
        return try #require(BundledEngine.load(from: root))
    }

    @Test func environmentSubstitutesEngineAndData() throws {
        let engine = try fakeEngine(graphics: [])
        let env = engine.environment(prefix: URL(fileURLWithPath: "/p"), data: URL(fileURLWithPath: "/d"))
        #expect(env["WINEDLLPATH"] == "\(engine.root.path)/fex:/d/x")
        #expect(env["WINEPREFIX"] == "/p")
        #expect(engine.name == "test-engine")
    }

    @Test func windowsPathUsesDriveCInsideBottle() {
        let prefix = URL(fileURLWithPath: "/tmp/bottle")
        let inside = URL(fileURLWithPath: "/tmp/bottle/drive_c/Games/Hero/game.exe")
        let outside = URL(fileURLWithPath: "/fixture-mount/Games/Hero/game.exe")
        #expect(EngineLauncher.windowsPath(for: inside, prefix: prefix) == "C:\\Games\\Hero\\game.exe")
        #expect(EngineLauncher.windowsPath(for: outside, prefix: prefix) == "Z:\\fixture-mount\\Games\\Hero\\game.exe")
    }

    @Test func logFindsCrashAcrossChunksAndHidesDiagnostics() throws {
        let log = try EngineLog(url: try tempDir().appendingPathComponent("engine.log"))
        log.append(Data("macrunner-hb-модуль: pid=1 base=0x1\nwine: Unhandled page fa".utf8))
        log.append(Data("ult on read access to 0000000000000040 at address 0000000141A05550\n".utf8))
        log.append(Data("0024:err:module:import_dll Library d3dx9_43.dll not found\n".utf8))
        log.close()
        #expect(log.crashMessage == "wine: Unhandled page fault on read access to 0000000000000040 at address 0000000141A05550")
        let tail = try #require(log.meaningfulTail())
        #expect(!tail.contains("macrunner-hb"))
        #expect(tail.contains("err:module:import_dll"))
    }

    @Test func logKeepsEngineRefusalWithoutCrash() throws {
        let log = try EngineLog(url: try tempDir().appendingPathComponent("engine.log"))
        log.append(Data("wine: created the configuration directory '/x'\nwine: failed to open L\"C:\\\\a.exe\": c0000135\n".utf8))
        log.close()
        #expect(log.crashMessage == nil)
        #expect(log.engineMessage == "wine: failed to open L\"C:\\\\a.exe\": c0000135")
    }

    @Test func syncFillsSyswow64AndInstallsGraphicsSet() throws {
        let engine = try fakeEngine(graphics: ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"])
        let prefix = try tempDir()
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32")
        // Как после wineboot: в system32 лежит d3d11 самого Wine и копия ntdll.
        try write("wine-arm64-d3d11", system32.appendingPathComponent("d3d11.dll"))
        try write("stale", system32.appendingPathComponent("ntdll.dll"))
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: [:],
                                log: try EngineLog(url: prefix.appendingPathComponent("log")))
        try setup.syncModules()
        // Пакет схемы 1 (без матрицы): слой берётся из каталога graphics/x86_64-windows.
        try setup.install(try #require(engine.graphics.layers.first))

        let fm = FileManager.default
        let syswow64 = prefix.appendingPathComponent("drive_c/windows/syswow64")
        #expect(fm.fileExists(atPath: syswow64.appendingPathComponent("kernel32.dll").path))
        #expect(!fm.fileExists(atPath: system32.appendingPathComponent("ntdll.dll").path))
        #expect(!fm.fileExists(atPath: syswow64.appendingPathComponent("ntdll.dll").path))
        #expect(try String(contentsOf: system32.appendingPathComponent("d3d11.dll"), encoding: .utf8) == "dxmt/d3d11.dll")
        #expect(fm.fileExists(atPath: syswow64.appendingPathComponent("wow64cpu.dll").path))
        #expect(fm.fileExists(atPath: syswow64.appendingPathComponent("xtajit.dll").path))
        #expect(fm.fileExists(atPath: prefix.appendingPathComponent("drive_c/windows/temp").path))
    }

    @Test func schemaOnePackageGetsHonestDefaultMatrix() throws {
        let engine = try fakeEngine(graphics: ["dxgi.dll", "winemetal.dll"])
        #expect(engine.graphics.layers.map(\.id) == ["legacy-graphics"])
        #expect(engine.graphics.route(api: .d3d11, arch: .x86_64)?.status == .experimental)
        #expect(engine.graphics.route(api: .d3d12, arch: .x86_64) == nil)
        #expect(engine.graphics.route(api: .d3d11, arch: .x86) == nil)
    }

    @Test func foundGameNamesSkipGenericFolders() {
        #expect(InstalledGameScanner.displayName(for: URL(fileURLWithPath: "/b/drive_c/GOG Games/Divinity Original Sin/Shipping/EoCApp.exe")) == "Divinity Original Sin")
        #expect(InstalledGameScanner.displayName(for: URL(fileURLWithPath: "/b/drive_c/Games/Hero/bin/x64/hero.exe")) == "Hero")
        #expect(InstalledGameScanner.displayName(for: URL(fileURLWithPath: "/b/drive_c/Program Files/tool.exe")) == "tool")
    }

    @Test func installRootGroupsByGameFolder() {
        let prefix = URL(fileURLWithPath: "/b")
        let a = InstalledGameScanner.installRoot(of: URL(fileURLWithPath: "/b/drive_c/Program Files (x86)/Hero/bin/hero.exe"), prefix: prefix)
        let b = InstalledGameScanner.installRoot(of: URL(fileURLWithPath: "/b/drive_c/Program Files (x86)/Hero/editor.exe"), prefix: prefix)
        #expect(a == b)
        #expect(a == "/b/drive_c/Program Files (x86)/Hero")
    }
}

/// Процесс движка пишет в журнал сам, мимо приложения.
struct EngineLogDirectOutputTests {
    @Test func childOutputGoesStraightToTheFileAndIsScanned() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("enginelog-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = try EngineLog(url: dir.appendingPathComponent("engine.log"))
        log.note("before")
        let outcome = try EngineProcess.run(URL(fileURLWithPath: "/bin/sh"),
            ["-c", "echo 'wine: Unhandled page fault on read access to 0000000000000040 at address 0000000141A05550'; echo tail-line >&2"],
            environment: ["PATH": "/usr/bin:/bin"], log: log)
        log.close()
        #expect(outcome.status == 0)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.contains("[macrunner-app] +") && text.contains("s before"))
        #expect(text.contains("tail-line"))
        #expect(log.crashMessage?.hasPrefix("wine: Unhandled page fault") == true)
    }
}

/// Раскладка запуска по этапам: чтобы «почему долго» мерить числами.
struct EngineLaunchTimelineTests {
    @Test func milestonesComeFromTheEngineLog() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = try EngineLog(url: dir.appendingPathComponent("engine.log"))
        log.mark("bottleReady")
        log.append(Data(#"macrunner-createwnd: pid=1 n=7 класс=L"IME" имя=L"Default IME" style=8c000000 ex=00000000 parent=0x0 menu=0x0 inst=0x0"#.utf8 + [0x0A]))
        log.append(Data(#"macrunner-createwnd: pid=1 n=1 класс=L"OleMainThreadWndClass" имя=L"" style=00000000 ex=00000000 parent=0x0 menu=0x0 inst=0x0"#.utf8 + [0x0A]))
        log.append(Data(#"00d8:trace:loaddll:build_module Loaded L"C:\\windows\\system32\\d3d11.dll" at 000000014B030000: native"#.utf8 + [0x0A]))
        log.append(Data(#"macrunner-createwnd: pid=1 n=2 класс=L"UnityWndClass" имя=L"" style=00cf0000 ex=00000000 parent=0x0 menu=0x0 inst=0x14cee0000"#.utf8 + [0x0A]))
        log.note("done")
        log.close()
        #expect(log.milestones["bottleReady"] != nil)
        #expect(log.milestones["graphicsLoaded"] != nil)
        #expect(log.milestones["gameWindow"] != nil)
        let text = try String(contentsOf: log.url, encoding: .utf8)
        #expect(text.contains("[macrunner-app] +"))
    }

    @Test func serviceWindowsAloneAreNotTheGameWindow() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("timeline-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let log = try EngineLog(url: dir.appendingPathComponent("engine.log"))
        log.append(Data(##"macrunner-createwnd: pid=1 n=3 класс=L"#32769" имя=L"" style=96000000 ex=00000000 parent=0x0 menu=0x0 inst=0x0"##.utf8 + [0x0A]))
        log.append(Data(#"macrunner-createwnd: pid=1 n=4 класс=L"__wine_clipboard_manager" имя=L"" style=00000000 ex=00000000 parent=0x0 menu=0x0 inst=0x0"#.utf8 + [0x0A]))
        log.close()
        #expect(log.milestones["gameWindow"] == nil)
    }
}
