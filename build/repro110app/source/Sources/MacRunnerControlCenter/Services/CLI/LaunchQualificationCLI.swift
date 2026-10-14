#if LAUNCH_QUALIFICATION
import AppKit
import Foundation

/// Compiled only into the private acceptance executable. Production GUI has no
/// extra root argument; this entry must refuse before creating models or storage.
enum LaunchQualificationCLI {
    @MainActor
    static func handleIfNeeded() {
        let arguments = CommandLine.arguments
        guard arguments.count > 1, ["--launch-qualification", "--launch-template-prepare"].contains(arguments[1]) else { return }
        let root = LaunchDataRoot.required()
        if arguments[1] == "--launch-template-prepare" {
            guard arguments.count == 3, arguments[2].hasPrefix(root.path + "/"), let engine = BundledEngine.current else { exit(2) }
            let start = ProcessInfo.processInfo.systemUptime
            do {
                let manifest = try Data(contentsOf: engine.root.appendingPathComponent("ENGINE.json"))
                let generation = BottleTemplate.generation(manifest: manifest)
                let seed = root.appendingPathComponent("BottleTemplates/\(generation)")
                let receipt = try BottleTemplate.validate(seed, generation: generation)
                let value: [String: Any] = ["status": "VERIFIED_NO_WINE", "generation": generation,
                    "seconds": ProcessInfo.processInfo.systemUptime - start, "payloadFiles": receipt.hashes.count]
                try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]).write(
                    to: URL(fileURLWithPath: arguments[2]), options: .atomic)
                exit(0)
            } catch { fputs("TEMPLATE_ADMISSION_REFUSED; Wine not started\n", stderr); exit(1) }
        }
        guard (4...5).contains(arguments.count), arguments[2].hasPrefix("/"), arguments[3].hasPrefix(root.path + "/"),
              let engine = BundledEngine.current, WarmBottleSessions.enabled(engine: engine) else {
            fputs("LAUNCH_QUALIFICATION_REFUSED: own engine, executable and result required\n", stderr)
            exit(2)
        }
        guard ProcessInfo.processInfo.environment["MACRUNNER_ACCEPTANCE_KEEP_INPUT_SOURCE"] == "1" else {
            fputs("LAUNCH_QUALIFICATION_REFUSED: input source preservation required\n", stderr)
            exit(2)
        }
        let output = URL(fileURLWithPath: arguments[3])
        let idle = arguments.count == 5 ? Double(arguments[4]) ?? -1 : 0
        guard idle >= 0, idle <= 610 else { exit(2) }
        let delegate = UpdateApplicationDelegate()
        NSApplication.shared.delegate = delegate
        delegate.qualificationTermination = {
            let bytes = try? JSONSerialization.data(withJSONObject: WarmBottleSessions.qualificationSnapshot(), options: [.sortedKeys])
            try? bytes?.write(to: root.appendingPathComponent("APP-TERMINATION.json"), options: .atomic)
        }
        var app = AppEntry.new(name: "LAUNCH qualification", exePath: arguments[2])
        app.graphicsAPI = "d3d11"
        app.env = ["MACRUNNER_LAUNCH_FRAMES": "3", "MACRUNNER_LAUNCH_MARK_FILE":
            "Z:" + root.appendingPathComponent("program.out").path.replacingOccurrences(of: "/", with: "\\")]
        if let delay = ProcessInfo.processInfo.environment["MACRUNNER_LAUNCH_PRE_D3D_MS"] { app.env?["MACRUNNER_LAUNCH_PRE_D3D_MS"] = delay }
        if let debug = ProcessInfo.processInfo.environment["MACRUNNER_LAUNCH_WINEDEBUG"] { app.env?["WINEDEBUG"] = debug }
        let model = RunAppViewModel(settings: .default)
        var ended = false
        model.onComplete = { result in
            guard let result else { WarmBottleSessions.closeAll(); exit(3) }
            do {
                try JSONEncoder.pretty.encode(result).write(to: output, options: .atomic)
            } catch { WarmBottleSessions.closeAll(); exit(3) }
            ended = true
        }
        model.run(app: app)
        let deadline = Date().addingTimeInterval(120)
        while !ended, Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if !ended { WarmBottleSessions.closeAll(); exit(4) }
        let started = ProcessInfo.processInfo.systemUptime
        let before = WarmBottleSessions.qualificationSnapshot()
        while ProcessInfo.processInfo.systemUptime - started < idle {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        let policy: [String: Any] = ["idleSeconds": ProcessInfo.processInfo.systemUptime - started,
            "sourceTTLSeconds": WarmBottleSessions.idleTimeout, "before": before,
            "after": WarmBottleSessions.qualificationSnapshot()]
        try? JSONSerialization.data(withJSONObject: policy, options: [.sortedKeys]).write(
            to: root.appendingPathComponent("WARM-IDLE.json"), options: .atomic)
        if model.lastLauncherResult?.status != "PASS" { WarmBottleSessions.closeAll(); exit(1) }
        // Actual AppKit termination invokes the same release delegate as the GUI.
        NSApplication.shared.terminate(nil)
        WarmBottleSessions.closeAll()
        exit(0)
    }
}
#endif
