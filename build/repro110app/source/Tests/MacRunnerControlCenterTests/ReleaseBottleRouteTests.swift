import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Opt-in real Wine gate. Its small executable imports D3D12 but creates no GPU
/// device and starts no game. All paths are restricted to the candidate gate.
@Suite(.serialized) struct ReleaseBottleRouteTests {
    @Test(.enabled(if: ProcessInfo.processInfo.environment["RELEASE_BOTTLE_GATE"] == "1"))
    func fullPreparationAndExistingUpdate() throws {
        let env = ProcessInfo.processInfo.environment
        let root = URL(fileURLWithPath: try #require(env["RELEASE_BOTTLE_OUT"]))
        let prefix = URL(fileURLWithPath: try #require(env["RELEASE_BOTTLE_PREFIX"]))
        let exe = URL(fileURLWithPath: try #require(env["RELEASE_BOTTLE_PROBE"]))
        let enginePath = try #require(env["APP32_ENGINE_ROOT"])
        let engine = try #require(BundledEngine.load(from: URL(fileURLWithPath: enginePath)))
        for path in [root.path, prefix.path, exe.path, EnginePaths.base.path] {
            try #require(path.contains("/c17/release-bottle-20261022/"))
        }
        let plan = GraphicsSelector.plan(detection: GraphicsProbe.detect(exe: exe), engine: engine)
        try #require(plan.decision == .launch && plan.api == .d3d12)
        let layer = try #require(plan.layer)
        let marker = prefix.appendingPathComponent(BottleSetup.markerName)
        try #require(!FileManager.default.fileExists(atPath: marker.path))
        let launcher = EngineLauncher(engine: engine, prefix: prefix)
        defer { WarmBottleSessions.closeAll() }
        for phase in ["full", "update"] {
            if phase == "update" {
                // Existing registered bottle from a previous generation/app
                // without the current per-file registration receipt.
                var old = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any])
                old["engine"] = String(repeating: "0", count: 64)
                old.removeValue(forKey: "registrationInputs")
                try JSONSerialization.data(withJSONObject: old, options: [.sortedKeys]).write(to: marker)
            }
            try #require(!BottleSetup.isReady(engine: engine, prefix: prefix))
            let run = root.appendingPathComponent(phase)
            try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
            let result = launcher.run(exe: exe, arguments: [], workdir: root, extraEnvironment: ["WINEDEBUG": "-all"],
                                      runDirectory: run, graphics: plan)
            WarmBottleSessions.closeAll()
            try JSONEncoder().encode(result).write(to: run.appendingPathComponent("RESULT.json"))
            #expect(result.rc == 0, "\(phase): \(result.error ?? result.status ?? "unknown")")
            #expect(BottleSetup.isReady(engine: engine, prefix: prefix))
            for (arch, names) in layer.modules {
                let destination = arch.hasSuffix("i386-windows") ? "syswow64" : "system32"
                for name in names {
                    let source = engine.root.appendingPathComponent(arch).appendingPathComponent(name)
                    let installed = prefix.appendingPathComponent("drive_c/windows/\(destination)/\(name)")
                    #expect(try Data(contentsOf: installed) == Data(contentsOf: source), "\(phase): wrong layer \(name)")
                }
            }
            // Several Wine processes share stderr; writes can split a UTF-8
            // character. Keep the original bytes and decode the probe's ASCII row.
            let log = String(decoding: try Data(contentsOf: run.appendingPathComponent("engine.log")), as: UTF8.self)
            #expect(log.contains("ROUTE_PROBE d3d12=1 vulkan=0 error=126"))
        }
    }
}
