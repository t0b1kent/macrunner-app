import Foundation
import Testing
@testable import MacRunnerControlCenter

struct WICRegistrationTests {
    @Test func readyBottleKeepsRegistrationUntilCodecChangesAndRejectsFailure() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wic-registration-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let engineRoot = root.appendingPathComponent("engine")
        let prefix = root.appendingPathComponent("prefix")
        let wine = engineRoot.appendingPathComponent("wine/bin/wine")
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try Data(#"{"name":"wic-test","environment":{}}"#.utf8).write(to: engineRoot.appendingPathComponent("ENGINE.json"))
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$WINEPREFIX/calls\"\nexit \"${WIC_RC:-0}\"\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let engine = try #require(BundledEngine.load(from: engineRoot))
        try Data().write(to: prefix.appendingPathComponent("system.reg"))
        try Data().write(to: prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
        let marker: [String: Any] = ["engine": BottleSetup.engineStamp(engine), "engineRoot": BottleSetup.engineRootPath(engine), "layers": []]
        try JSONSerialization.data(withJSONObject: marker).write(to: prefix.appendingPathComponent(BottleSetup.markerName))
        let log = try EngineLog(url: root.appendingPathComponent("engine.log"))
        defer { log.close() }
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: ["WINEPREFIX": prefix.path], log: log)
        try setup.prepareIfNeeded()
        try setup.prepareIfNeeded()
        let calls = try String(contentsOf: prefix.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
        #expect(calls.count == 1)
        #expect(calls.allSatisfy { $0 == #"C:\windows\system32\regsvr32.exe /s C:\windows\system32\windowscodecs.dll"# })
        let failing = BottleSetup(engine: engine, prefix: prefix, environment: ["WINEPREFIX": prefix.path, "WIC_RC": "3"], log: log)
        // Replacing the codec must invalidate the previous successful stamp.
        try Data("changed codec".utf8).write(to: prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
        #expect(throws: BottleSetup.SetupError.self) { try failing.prepareIfNeeded() }
        #expect(throws: BottleSetup.SetupError.self) { try failing.prepareIfNeeded() }
        // Failure cannot stamp the new bytes as registered: a successful retry is required.
        try setup.prepareIfNeeded()
        try setup.prepareIfNeeded()
        let retried = try String(contentsOf: prefix.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
        #expect(retried.count == 4)
        try FileManager.default.removeItem(at: prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
        #expect(throws: BottleSetup.SetupError.self) { try setup.prepareIfNeeded() }
    }

    @Test func readyRegistrationRejectsStalePackagePathAndEngineStamp() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("wic-path-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let engineRoot = root.appendingPathComponent("engine")
        let prefix = root.appendingPathComponent("prefix")
        let wine = engineRoot.appendingPathComponent("wine/bin/wine")
        try FileManager.default.createDirectory(at: wine.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try Data(#"{"name":"wic-test","environment":{}}"#.utf8).write(to: engineRoot.appendingPathComponent("ENGINE.json"))
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$WINEPREFIX/calls\"\nexit 0\n".utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let engine = try #require(BundledEngine.load(from: engineRoot))
        try Data().write(to: prefix.appendingPathComponent("system.reg"))
        try Data("codec".utf8).write(to: prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
        let markerURL = prefix.appendingPathComponent(BottleSetup.markerName)
        var marker: [String: Any] = ["engine": BottleSetup.engineStamp(engine), "engineRoot": BottleSetup.engineRootPath(engine), "layers": []]
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
        let log = try EngineLog(url: root.appendingPathComponent("engine.log")); defer { log.close() }
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: ["WINEPREFIX": prefix.path], log: log)
        try setup.prepareIfNeeded()
        marker = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
        var registration = try #require(marker["wicRegistration"] as? [String: String])
        // Ready marker + stale COM package location reproduces the original relocation hazard.
        registration["engineRoot"] = root.appendingPathComponent("old-engine").path
        marker["wicRegistration"] = registration
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
        try setup.prepareIfNeeded()
        marker = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: markerURL)) as? [String: Any])
        registration = try #require(marker["wicRegistration"] as? [String: String])
        registration["engine"] = "old-engine-bytes"
        marker["wicRegistration"] = registration
        try JSONSerialization.data(withJSONObject: marker).write(to: markerURL)
        try setup.prepareIfNeeded()
        try setup.prepareIfNeeded()
        let calls = try String(contentsOf: prefix.appendingPathComponent("calls"), encoding: .utf8).split(separator: "\n")
        #expect(calls.count == 3)
    }

    /// Opt-in live check uses a lane-owned prefix prepared by the existing launcher.
    /// The caller owns the func slot, timeout, server drain and prefix disposal.
    @Test func livePNGThroughApplicationBottleSetup() throws {
        let env = ProcessInfo.processInfo.environment
        guard let enginePath = env["WIC_LIVE_ENGINE"], let prefixPath = env["WIC_LIVE_PREFIX"],
              let exePath = env["WIC_LIVE_EXE"], let logPath = env["WIC_LIVE_LOG"] else { return }
        let engine = try #require(BundledEngine.load(from: URL(fileURLWithPath: enginePath)))
        let prefix = URL(fileURLWithPath: prefixPath)
        let marker: [String: Any] = ["engine": BottleSetup.engineStamp(engine), "engineRoot": BottleSetup.engineRootPath(engine), "layers": []]
        try JSONSerialization.data(withJSONObject: marker).write(to: prefix.appendingPathComponent(BottleSetup.markerName))
        var child = env.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE"].contains($0.key) }
        child["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        child.merge(engine.environment(prefix: prefix, data: prefix.deletingLastPathComponent().appendingPathComponent("data"))) { _, new in new }
        child["WINEDEBUG"] = "-all,+loaddll"
        let log = try EngineLog(url: URL(fileURLWithPath: logPath))
        defer { log.close() }
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: child, log: log)
        let firstStart = ProcessInfo.processInfo.systemUptime
        try setup.prepareIfNeeded()
        log.note("launch: WIC first prepare ms=\((ProcessInfo.processInfo.systemUptime - firstStart) * 1000)")
        let result = try EngineProcess.run(engine.wine, [EngineLauncher.windowsPath(for: URL(fileURLWithPath: exePath), prefix: prefix)], environment: child, log: log)
        #expect(result.status == 0)
        let readyStart = ProcessInfo.processInfo.systemUptime
        try setup.prepareIfNeeded()
        log.note("launch: WIC unchanged prepare ms=\((ProcessInfo.processInfo.systemUptime - readyStart) * 1000)")
        let second = try EngineProcess.run(engine.wine, [EngineLauncher.windowsPath(for: URL(fileURLWithPath: exePath), prefix: prefix)], environment: child, log: log)
        #expect(second.status == 0)
        EngineProcess.waitForServer(engine: engine, environment: child, log: log)
        let output = try String(contentsOf: log.url, encoding: .utf8)
        #expect(output.contains("WIC PNG 1x1 RGBA=ff0000ff"))
        #expect(output.components(separatedBy: "WIC PNG 1x1 RGBA=ff0000ff").count - 1 == 2)
        #expect(output.components(separatedBy: "bottle: WIC registration refreshed engine=\(BottleSetup.engineRootPath(engine))").count - 1 == 1)
    }
}
