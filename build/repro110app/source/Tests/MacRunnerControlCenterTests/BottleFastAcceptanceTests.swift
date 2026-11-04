import Foundation
import Testing
@testable import MacRunnerControlCenter

/// BOTTLE-UPDATE acceptance driver. NOT a unit test: it does nothing unless BOTTLE_ACCEPT_PREFIX is set.
/// It runs the production `BottleSetup.prepareIfNeeded()` (the call `prepareBottleInBackground` makes) on
/// an explicit engine and bottle, inside an explicit data root, and writes a result with the elapsed time.
/// Every path must live under `/bottle-update-20261014/`; anything else is refused before any process starts.
struct BottleFastAcceptanceTests {
    static let enabled = ProcessInfo.processInfo.environment["BOTTLE_ACCEPT_PREFIX"] != nil

    @Test(.enabled(if: BottleFastAcceptanceTests.enabled && ProcessInfo.processInfo.environment["BOTTLE_ACCEPT_HELPER_NEGATIVES"] != "1"))
    func prepareExplicitBottle() throws {
        let env = ProcessInfo.processInfo.environment
        let required = "/bottle-update-20261014/"
        let engineRoot = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_ENGINE"]), isDirectory: true)
        let prefix = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_PREFIX"]), isDirectory: true)
        let out = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_OUT"]), isDirectory: true)
        for path in [engineRoot.path, prefix.path, out.path, EnginePaths.base.path] {
            try #require(path.contains(required), "path outside the lane directory: \(path)")
        }
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let engine = try #require(BundledEngine.load(from: engineRoot))
        // Gate switches: only this driver can set them (no environment variable is read by the app itself).
        if let pairs = env["BOTTLE_ACCEPT_PAIR_FILE"] { BottleUpdateCatalogue.pairFileOverride = URL(fileURLWithPath: pairs) }
        BottleUpdateCatalogue.pairGateMode = env["BOTTLE_ACCEPT_PAIR_GATE"] == "1"
        if let path = env["BOTTLE_ACCEPT_FROM_ACTUAL"], let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let table = try? JSONSerialization.jsonObject(with: data) as? [String: String] {
            BottleUpdateCatalogue.pairGateActual = table
        }
        defer {
            BottleUpdateCatalogue.pairFileOverride = nil; BottleUpdateCatalogue.pairGateMode = false
            BottleUpdateCatalogue.pairGateActual = [:]
        }
        // Same environment as EngineLauncher.makeEnvironment(extra: [:]) without GameActivity.remember,
        // which would write the prefix path into the test runner's UserDefaults in the owner's home.
        let inherited = ProcessInfo.processInfo.environment
        var environment: [String: String] = [:]
        for key in ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"] {
            if let value = inherited[key] { environment[key] = value }
        }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment.merge(engine.environment(prefix: prefix, data: EnginePaths.data(for: engine))) { _, new in new }
        environment["WINEPREFIX"] = prefix.path
        // Diagnostic-only admission: keep the product manifest and its stamps
        // unchanged while counting actual registration entries on a private arm.
        if let debug = env["BOTTLE_ACCEPT_REGISTRATION_TRACE"] {
            try #require(debug == "1")
            environment["WINEDEBUG"] = "-all,trace+setupapi,warn+setupapi,trace+regsvr32"
        }
        try #require((environment["HOME"] ?? "").contains(required), "HOME is not the lane's private home")
        let log = try EngineLog(url: out.appendingPathComponent("engine.log"))
        if let source = env["BOTTLE_ACCEPT_REBIND_SOURCE"] {
            try BottleSingleFileFixture.rebindClone(prefix: prefix, source: URL(fileURLWithPath: source), out: out)
        }
        if let oldModule = env["BOTTLE_ACCEPT_SINGLE_OLD_MODULE"] {
            try BottleSingleFileFixture.prepare(engine: engine, prefix: prefix, out: out,
                                                oldModule: URL(fileURLWithPath: oldModule))
        }
        let setup = BottleSetup(engine: engine, prefix: prefix, environment: environment, log: log)
        let readyBefore = BottleSetup.isReady(engine: engine, prefix: prefix)
        let began = DispatchTime.now().uptimeNanoseconds
        var failure = ""
        do { try setup.prepareIfNeeded() } catch { failure = String(describing: error) }
        let elapsed = Double(DispatchTime.now().uptimeNanoseconds - began) / 1e6
        let milestones = log.snapshotTimeline()
        log.close()
        let result: [String: Any] = ["milestones": milestones,"elapsed_ms": elapsed, "ready_before": readyBefore,
            "ready_after": BottleSetup.isReady(engine: engine, prefix: prefix), "failure": failure,
            "classRule": BottleUpdateCatalogue.classRuleEnabled, "engine": engine.name]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("result.json"), options: .atomic)
        #expect(failure.isEmpty)
    }

    /// Exercise the shipped registration helper's failures on a cloned, enrolled bottle.
    @Test(.enabled(if: BottleFastAcceptanceTests.enabled && ProcessInfo.processInfo.environment["BOTTLE_ACCEPT_HELPER_NEGATIVES"] == "1"))
    func checkedRegistrationFailures() throws {
        let env = ProcessInfo.processInfo.environment
        let prefix = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_PREFIX"]))
        let out = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_OUT"]))
        let root = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_ENGINE"]))
        let helpers = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_HELPER_DIR"]))
        for url in [prefix, out, root] { try #require(url.path.contains("/c15/bottle-update-20261014/")) }
        try #require(helpers.path.hasSuffix("/c15/bottle-probes"))
        let engine = try #require(BundledEngine.load(from: root))
        var environment = env.filter { ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "LC_CTYPE", "__CF_USER_TEXT_ENCODING"].contains($0.key) }
        environment["PATH"] = "/usr/bin:/bin:/usr/sbin:/sbin"
        environment.merge(engine.environment(prefix: prefix, data: EnginePaths.data(for: engine))) { _, new in new }
        environment["WINEPREFIX"] = prefix.path
        environment["WINEDEBUG"] = "-all"
        try #require((environment["HOME"] ?? "").contains("/bottle-update-20261014/"))
        let marker = prefix.appendingPathComponent(".macrunner-bottle.json")
        let markerBefore = try Data(contentsOf: marker)
        let log = try EngineLog(url: out.appendingPathComponent("helper-controls.log"))
        defer { log.close() }
        func win(_ url: URL) -> String { "Z:" + url.path.replacingOccurrences(of: "/", with: "\\") }
        let cases: [(String, String, Int32)] = [
            ("positive", "11,,windowscodecs.dll,1", 0),
            ("missing-dll", "11,,macrunner-intentionally-absent.dll,1", 10),
            ("invalid-flags", "11,,windowscodecs.dll,0", 10),
            ("exe-failure", "11,,cmd.exe,1,10,/c exit 7", 10)
        ]
        var rows: [[String: Any]] = []
        for view in ["native", "32"] {
            for (name, registration, expected) in cases {
                let inf = out.appendingPathComponent("control-\(view)-\(name).inf")
                try ("[Version]\nSignature=\"$Windows NT$\"\n[RegisterDllsSection]\n" + registration + "\n")
                    .write(to: inf, atomically: true, encoding: .utf8)
                let server = try EngineProcess.run(engine.wineserver, ["-p0"], environment: environment, log: log)
                try #require(server.status == 0 && !server.signaled)
                let result = try EngineProcess.run(engine.wine,
                    [helpers.appendingPathComponent("macrunner-bottle-register-\(view).exe").path,
                     win(inf), win(helpers.appendingPathComponent("checked-registration.inf"))],
                    environment: environment, log: log)
                EngineProcess.waitForServer(engine: engine, environment: environment, log: log)
                rows.append(["view": view, "case": name, "expected": expected, "status": result.status, "signaled": result.signaled])
                #expect(result.status == expected && !result.signaled)
            }
        }
        #expect(try Data(contentsOf: marker) == markerBefore)
        try JSONSerialization.data(withJSONObject: rows, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("helper-controls.json"), options: .atomic)
    }

    /// Diagnostic: only `syncModules()` (file copies, no Wine process) on an explicit bottle.
    @Test(.enabled(if: BottleFastAcceptanceTests.enabled && ProcessInfo.processInfo.environment["BOTTLE_ACCEPT_SYNC_ONLY"] == "1"))
    func syncModulesOnly() throws {
        let env = ProcessInfo.processInfo.environment
        let required = "/bottle-update-20261014/"
        let engineRoot = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_ENGINE"]), isDirectory: true)
        let prefix = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_PREFIX"]), isDirectory: true)
        let out = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_OUT"]), isDirectory: true)
        for path in [engineRoot.path, prefix.path, out.path] { try #require(path.contains(required)) }
        let engine = try #require(BundledEngine.load(from: engineRoot))
        let log = try EngineLog(url: out.appendingPathComponent("sync-only.log"))
        try BottleSetup(engine: engine, prefix: prefix, environment: [:], log: log).syncModules()
        log.close()
    }

    /// Negative controls on the REAL pair of inventories (1.0.9 r1 and the 1.1.0 composition), no Wine, no prefix write.
    @Test(.enabled(if: BottleFastAcceptanceTests.enabled && ProcessInfo.processInfo.environment["BOTTLE_ACCEPT_NEGATIVE"] == "1"))
    func negativeControlsOnTheRealPair() throws {
        let env = ProcessInfo.processInfo.environment
        let required = "/bottle-update-20261014/"
        let out = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_OUT"]), isDirectory: true)
        let newEngine = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_ENGINE"]), isDirectory: true)
        let oldManifest = URL(fileURLWithPath: try #require(env["BOTTLE_ACCEPT_OLD_MANIFEST"]))
        for path in [out.path, newEngine.path] { try #require(path.contains(required)) }
        let oldData = try Data(contentsOf: oldManifest)
        let newData = try Data(contentsOf: newEngine.appendingPathComponent("ENGINE.json"))

        func catalogue(_ data: Data) throws -> BottleUpdateCatalogue {
            BottleUpdateCatalogue(schema: 1, engine: BottleUpdateCatalogue.digest(data), engineRoot: newEngine.path, layers: [],
                                  inputs: ["@graphics": "same"], files: [:], manifest: data)
        }
        func mutated(_ mutate: (inout [String: Any]) -> Void) throws -> BottleUpdateCatalogue {
            var object = try #require(JSONSerialization.jsonObject(with: newData) as? [String: Any])
            mutate(&object)
            return try catalogue(JSONSerialization.data(withJSONObject: object, options: .sortedKeys))
        }
        func files(_ object: inout [String: Any], _ change: (inout [String: String]) -> Void) {
            var files = object["files"] as! [String: String]; change(&files); object["files"] = files
        }
        func environment(_ object: inout [String: Any], _ change: (inout [String: String]) -> Void) {
            var env = object["environment"] as! [String: String]; change(&env); object["environment"] = env
        }
        let old = try catalogue(oldData)
        var report: [String: String] = [:]
        func record(_ name: String, _ candidate: BottleUpdateCatalogue) {
            report[name] = candidate.classRefusal(from: old, package: newEngine) ?? "ALLOWED"
        }
        record("1 real pair (13 changed targets, B and O classes only, 9 runtime knobs)", try catalogue(newData))
        record("2 wine.inf changed (class R)", try mutated { files(&$0) { $0["wine/share/wine/wine.inf"] = String(repeating: "0", count: 64) } })
        record("3 windowscodecs.dll changed (registered module, class R)", try mutated { files(&$0) {
            $0["wine/lib/wine/aarch64-windows/windowscodecs.dll"] = String(repeating: "1", count: 64) } })
        record("4 setupapi.dll changed (INF executor, class R)", try mutated { files(&$0) {
            $0["wine/lib/wine/i386-windows/setupapi.dll"] = String(repeating: "2", count: 64) } })
        record("5 nls table changed (CopyFiles data, class R)", try mutated { files(&$0) {
            $0["wine/share/wine/nls/c_437.nls"] = String(repeating: "3", count: 64) } })
        record("6 WINEDLLOVERRIDES changed (prefix environment)", try mutated { environment(&$0) { $0["WINEDLLOVERRIDES"] = "d3d9=b" } })
        record("7 MACRUNNER_GRAPHICS_BACKEND changed", try mutated { environment(&$0) { $0["MACRUNNER_GRAPHICS_BACKEND"] = "wined3d" } })
        record("8 runtime knob MACRUNNER_VM_ARENA flipped (must stay allowed)", try mutated { environment(&$0) { $0["MACRUNNER_VM_ARENA"] = "1" } })
        record("9 kernelbase.dll changed again (class B, must stay allowed)", try mutated { files(&$0) {
            $0["wine/lib/wine/aarch64-windows/kernelbase.dll"] = String(repeating: "4", count: 64) } })
        var probes: [String: String] = [:]
        for item in (env["BOTTLE_ACCEPT_PROBES"] ?? "").split(separator: ";") {
            let parts = item.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            probes[parts[0]] = BottleUpdateCatalogue.unnormalisedRegistration(
                prefix: URL(fileURLWithPath: parts[1], isDirectory: true), engineRoot: newEngine.path) ?? "NORMALISED (fast route allowed)"
        }
        let result: [String: Any] = ["class_rule_decisions": report, "registry_probe": probes]
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: out.appendingPathComponent("negative-controls.json"), options: .atomic)
    }
}
