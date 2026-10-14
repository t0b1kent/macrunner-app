import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Native filesystem and fake loaders only; no Wine, window or game process.
@Suite(.serialized)
struct WarmProfileIntegrationTests {
    private func fixture(initialModeset: Bool = false) throws -> (URL, URL, BundledEngine, EngineLog) {
        let fm = FileManager.default
        let root = EnginePaths.base.appendingPathComponent("warm-profile-\(UUID())")
        let engineRoot = root.appendingPathComponent("engine")
        let prefix = root.appendingPathComponent("prefix")
        try fm.createDirectory(at: engineRoot.appendingPathComponent("wine/bin"), withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": root.lastPathComponent, "environment": [String: String](),
                                     "capabilities": ["winebootLocalNameOnly": true]]
        try JSONSerialization.data(withJSONObject: manifest).write(to: engineRoot.appendingPathComponent("ENGINE.json"))
        let wine = engineRoot.appendingPathComponent("wine/bin/wine")
        try Data("#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$WINEPREFIX/fake-calls\"\nexit 0\n".utf8).write(to: wine)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)
        let engine = try #require(BundledEngine.load(from: engineRoot))
        try fm.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try fm.createDirectory(at: prefix.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        try Data("WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Cryptography]\n\"MachineGuid\"=\"profile-fixture\"\n".utf8)
            .write(to: prefix.appendingPathComponent("system.reg"))
        try Data(BottleSetup.modesetRegistry("", enabled: initialModeset).utf8).write(to: prefix.appendingPathComponent("user.reg"))
        try Data("WINE REGISTRY Version 2\n".utf8).write(to: prefix.appendingPathComponent("userdef.reg"))
        let codec = Data("fixture-codec".utf8)
        try codec.write(to: prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
        let stamp = BottleSetup.engineStamp(engine), location = BottleSetup.engineRootPath(engine)
        let marker: [String: Any] = ["engine": stamp, "engineRoot": location, "layers": [String](),
            "wicRegistration": ["engine": stamp, "engineRoot": location, "codec": BottleTemplate.digest(codec)]]
        try JSONSerialization.data(withJSONObject: marker).write(to: prefix.appendingPathComponent(BottleSetup.markerName))
        try fm.createDirectory(at: root.appendingPathComponent("game"), withIntermediateDirectories: true)
        try Data("fixture-media".utf8).write(to: root.appendingPathComponent("game/DATA.MPQ"))
        return (root, prefix, engine, try EngineLog(url: root.appendingPathComponent("engine.log")))
    }

    private func expectProfile(prefix: URL, game: URL, modeset: Bool) throws {
        let fm = FileManager.default
        let user = try String(contentsOf: prefix.appendingPathComponent("user.reg"), encoding: .utf8)
        #expect(user.contains("\"EmulateModeset\"=\"\(modeset ? "Y" : "N")\""))
        let system = try String(contentsOf: prefix.appendingPathComponent("system.reg"), encoding: .utf8)
        #expect(system.contains("\"r:\"=\"cdrom\""))
        let drive = prefix.appendingPathComponent("dosdevices/r:")
        let target = try fm.destinationOfSymbolicLink(atPath: drive.path)
        #expect(target.hasPrefix("../media-cd/"))
        let media = drive.appendingPathComponent("DATA.MPQ").resolvingSymlinksInPath()
        #expect(media == game.appendingPathComponent("DATA.MPQ").resolvingSymlinksInPath())
        #expect(try Data(contentsOf: media) == Data("fixture-media".utf8))
        #expect(try fm.destinationOfSymbolicLink(atPath: prefix.appendingPathComponent("dosdevices/c:").path) == "../drive_c")
    }

    @Test func profilesAndManualOverridesCannotReplaceBundledLibrarySelection() throws {
        let (root, prefix, _, log) = try fixture()
        defer { log.close(); try? FileManager.default.removeItem(at: root) }
        let engineRoot = root.appendingPathComponent("engine")
        let packaged: [String: String] = [
            "DYLD_LIBRARY_PATH": "${ENGINE}/wine/lib/wine/aarch64-unix",
            "DYLD_FALLBACK_LIBRARY_PATH": "${ENGINE}/wine/lib/wine/aarch64-unix:/usr/lib",
            "LD_LIBRARY_PATH": "${ENGINE}/wine/lib/wine/aarch64-unix",
            "WINEDLLPATH": "${ENGINE}/fex:${ENGINE}/graphics",
            "WINESYSTEMDLLPATH": "${ENGINE}/graphics/x86_64-windows",
            "WINELOADER": "${ENGINE}/wine/bin/wine",
            "WINESERVER": "${ENGINE}/wine/bin/wineserver",
            "MACRUNNER_WINE_BIN": "${ENGINE}/wine/bin/wine",
            "MACRUNNER_WINE_DIST": "${ENGINE}/wine",
            "MACRUNNER_FEX_OVERLAY": "${ENGINE}/fex",
            "MACRUNNER_DXMT_ROOT": "${ENGINE}/graphics/x86_64-windows",
            "GST_PLUGIN_PATH": "",
            "GST_PLUGIN_PATH_1_0": "",
            "GST_PLUGIN_SYSTEM_PATH": "${ENGINE}/media/gstreamer-1.0",
            "GST_PLUGIN_SYSTEM_PATH_1_0": "${ENGINE}/media/gstreamer-1.0",
            "GST_PLUGIN_SCANNER": "${ENGINE}/media/bin/gst-plugin-scanner",
            "GST_PLUGIN_SCANNER_1_0": "${ENGINE}/media/bin/gst-plugin-scanner"
        ]
        let manifest: [String: Any] = ["name": root.lastPathComponent, "environment": packaged]
        try JSONSerialization.data(withJSONObject: manifest).write(to: engineRoot.appendingPathComponent("ENGINE.json"))
        let engine = try #require(BundledEngine.load(from: engineRoot))
        let launcher = EngineLauncher(engine: engine, prefix: prefix)
        let expected = engine.environment(prefix: prefix, data: EnginePaths.data(for: engine))
        let profile = ["DYLD_LIBRARY_PATH": "/opt/homebrew/lib", "DYLD_FALLBACK_LIBRARY_PATH": "/usr/local/lib",
                       "DYLD_INSERT_LIBRARIES": "/opt/homebrew/lib/injected.dylib", "DXMT_CONFIG": "profile-value"]
        let manual = ["DYLD_LIBRARY_PATH": "", "LD_LIBRARY_PATH": "/opt/homebrew/lib", "LD_PRELOAD": "external.so",
                      "DYLD_ROOT_PATH": "/external-root", "FEX_X87REDUCEDPRECISION": "1", "EMPTY_SETTING": ""]
        var overrides = profile.merging(manual) { _, own in own }
        for key in packaged.keys where key != "DYLD_LIBRARY_PATH" {
            overrides[key] = "/opt/homebrew/external"
        }
        let actual = launcher.makeEnvironment(extra: overrides)
        for key in packaged.keys { #expect(actual[key] == expected[key]) }
        for key in ["DYLD_INSERT_LIBRARIES", "DYLD_ROOT_PATH", "LD_PRELOAD"] { #expect(actual[key] == nil) }
        #expect(actual["DXMT_CONFIG"] == "profile-value")
        #expect(actual["FEX_X87REDUCEDPRECISION"] == "1")
        #expect(actual["EMPTY_SETTING"] == "")
        #expect(actual["WINEPREFIX"] == prefix.path)
        #expect(launcher.makeEnvironment(extra: [:]) == launcher.makeEnvironment(extra: overrides.filter {
            $0.key.hasPrefix("DYLD_") || $0.key.hasPrefix("LD_") || packaged.keys.contains($0.key)
        }))
    }

    @Test(arguments: [true, false])
    func readyProfileIsAppliedBeforeWarmAdmission(modeset: Bool) throws {
        let (root, prefix, engine, log) = try fixture(initialModeset: !modeset)
        defer { log.close(); try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game")
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: ["WINEPREFIX": prefix.path], log: log)
        var admissions = 0
        try setup.prepareIfNeeded(emulateModeset: modeset, cdromDataFilename: "DATA.MPQ", gameDirectory: game,
                                  allowTemplate: false, beforeRegistration: {
            try expectProfile(prefix: prefix, game: game, modeset: modeset)
            #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent("fake-calls").path))
            admissions += 1
        })
        #expect(admissions == 1)
        #expect(setup.isReady)
    }

    @Test(arguments: [true, false])
    func clonedProfileSurvivesPublishBeforeBootstrapAndSeedStaysNeutral(modeset: Bool) throws {
        let (root, prefix, engine, log) = try fixture(initialModeset: !modeset)
        let fm = FileManager.default
        let generation = BottleTemplate.generation(manifest: try Data(contentsOf: engine.root.appendingPathComponent("ENGINE.json")))
        let seed = EnginePaths.base.appendingPathComponent("BottleTemplates/" + generation)
        defer { log.close(); try? fm.removeItem(at: root); try? fm.removeItem(at: seed) }
        try fm.createDirectory(at: seed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.moveItem(at: prefix, to: seed)
        let values = BottleTemplate.substitutions(engine: engine.root, prefix: prefix, data: EnginePaths.data(for: engine), home: "")
        try BottleTemplate.seal(seed, generation: generation, values: values)
        let neutral = try BottleTemplate.inventory(seed)
        let game = root.appendingPathComponent("game")
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: ["WINEPREFIX": prefix.path], log: log)
        var admissions = 0
        try setup.prepareIfNeeded(emulateModeset: modeset, cdromDataFilename: "DATA.MPQ", gameDirectory: game,
                                  beforeRegistration: {
            // Bootstrap sees the published path, not .clone-UUID links. Ready
            // remains false until this callback and the fake --ready complete.
            #expect(!setup.isReady)
            try expectProfile(prefix: prefix, game: game, modeset: modeset)
            admissions += 1
        })
        #expect(admissions == 1)
        #expect(setup.isReady)
        #expect(try BottleTemplate.inventory(seed) == neutral)
        #expect(!fm.fileExists(atPath: seed.appendingPathComponent("media-cd").path))
        try expectProfile(prefix: prefix, game: game, modeset: modeset)
    }

    @Test func profileChangesInvalidateReuseButNonMediaDirectoryDoesNot() throws {
        let (root, _, engine, log) = try fixture()
        defer { log.close(); try? FileManager.default.removeItem(at: root) }
        let plain = try WarmBottleSessions.signature(engine: engine, environment: [:], layer: nil)
        #expect(plain != (try WarmBottleSessions.signature(engine: engine, environment: [:], layer: nil, emulateModeset: false)))
        let enabled = try WarmBottleSessions.signature(engine: engine, environment: [:], layer: nil, emulateModeset: true)
        #expect(enabled != (try WarmBottleSessions.signature(engine: engine, environment: [:], layer: nil, emulateModeset: false)))
        let game = root.appendingPathComponent("game")
        let media = try WarmBottleSessions.signature(engine: engine, environment: [:], layer: nil,
                                                     cdromDataFilename: "DATA.MPQ", gameDirectory: game)
        #expect(media != (try WarmBottleSessions.signature(engine: engine, environment: [:], layer: nil,
                    cdromDataFilename: "DATA.MPQ", gameDirectory: root.appendingPathComponent("other-game"))))
        #expect(plain == (try WarmBottleSessions.signature(engine: engine, environment: ["WINEDEBUG": "+service"],
                                                      layer: nil, gameDirectory: game)))
    }

    @Test(arguments: ["missing.MPQ", "../DATA.MPQ"])
    func invalidMediaRefusesBeforeAdmissionOrWine(filename: String) throws {
        let (root, prefix, engine, log) = try fixture()
        defer { log.close(); try? FileManager.default.removeItem(at: root) }
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: ["WINEPREFIX": prefix.path], log: log)
        var admissions = 0
        #expect(throws: BottleSetup.SetupError.self) {
            try setup.prepareIfNeeded(cdromDataFilename: filename, gameDirectory: root.appendingPathComponent("game"),
                                      beforeRegistration: { admissions += 1 })
        }
        #expect(admissions == 0)
        #expect(!FileManager.default.fileExists(atPath: prefix.appendingPathComponent("fake-calls").path))
    }
}
