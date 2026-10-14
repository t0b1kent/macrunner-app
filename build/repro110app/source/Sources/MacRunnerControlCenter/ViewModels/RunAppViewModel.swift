import SwiftUI

/// Progress records work we actually observed, not whether the game rendered a frame.
enum LaunchPhase: Int, Sendable {
    case checking, preparing, starting, active, stopping

    var title: String {
        switch self {
        case .checking: return L("Checking game")
        case .preparing: return L("Preparing environment")
        case .starting: return L("Starting process")
        case .active: return L("Process active")
        case .stopping: return L("Stopping")
        }
    }
}

struct LaunchProgress: Equatable, Sendable {
    private(set) var phase: LaunchPhase = .checking
    let startedAt: Date
    private(set) var phaseStartedAt: Date

    init(now: Date = Date()) {
        startedAt = now
        phaseStartedAt = now
    }

    /// Late callbacks must never replace Stopping or move a launch backwards.
    mutating func advance(to next: LaunchPhase, now: Date = Date()) -> Bool {
        guard next.rawValue > phase.rawValue else { return false }
        phase = next
        phaseStartedAt = now
        return true
    }

    func guidance(at now: Date) -> String? {
        switch phase {
        case .preparing:
            return L("The first launch may take longer while the environment is prepared.")
        case .active where now.timeIntervalSince(phaseStartedAt) >= 30:
            return L("If no game window appears or it stays black, stop and report this launch.")
        case .active:
            return L("The process is active. A game window or rendered frames have not been confirmed.")
        default:
            return nil
        }
    }
}

@MainActor
final class RunAppViewModel: ObservableObject {
    @Published var settings: AppSettings
    @Published var runner = CommandRunner()
    @Published var lastLauncherResult: LauncherResult?
    @Published var jsonOutputPath: String = ""
    @Published private(set) var launchProgress: LaunchProgress?
    var onComplete: ((LauncherResult?) -> Void)?
    var onProgress: ((LaunchProgress?) -> Void)?
    private var runID = UUID()
    private var keyboardLayout: GameKeyboardLayout?

    init(settings: AppSettings) {
        self.settings = settings
    }

    /// Запуск встроенным движком (выпускная сборка); nil — сценарий разработчика.
    private var launcher: EngineLauncher?

    func run(app: AppEntry) {
        guard let activity = UpdateSafetyGate.shared.beginActivity() else {
            let result = LauncherResult(status: "FAIL", error: L("Finish or cancel the update before starting a program."))
            lastLauncherResult = result
            onComplete?(result)
            return
        }
        runID = UUID()
        let currentRun = runID
        launchProgress = LaunchProgress()
        onProgress?(launchProgress)
        if let engine = BundledEngine.current {
            runBundled(app: app, engine: engine, activity: activity, runID: currentRun)
            return
        }
        let root = settings.macRunnerRoot
        let script = "\(root)/scripts/run-windows-app.sh"
        let exe = app.exePath
        var args: [String] = [exe]
        if let to = app.timeout {
            args += ["--timeout", "\(to)"]
        }
        if let wd = app.workdir {
            args += ["--workdir", wd]
        }
        if let appArgs = app.args, !appArgs.isEmpty {
            args += ["--args", appArgs.joined(separator: " ")]
        }
        let backend = app.d3dBackend
        if backend != "none" {
            args += ["--d3d-backend", backend]
        }
        if settings.keepArtifactsDefault {
            args += ["--d3d-keep-artifacts"]
        }
        if settings.enableDebugLogs {
            args += ["--debug"]
        }

        let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
        let artifactsDir = "\(root)/artifacts/control-center/\(stamp)"
        let jsonPath = "\(artifactsDir)/last-run.json"
        args += ["--json", jsonPath]
        jsonOutputPath = jsonPath

        var env = EngineEnv(settings: settings).processEnvironment()
        if let appEnv = app.env {
            for key in appEnv.keys.sorted() {
                guard let value = appEnv[key] else { continue }
                args += ["--env", "\(key)=\(value)"]
                env[key] = value
            }
        }

        let launcherTimeout = app.timeout ?? settings.defaultTimeout
        let runnerTimeout = TimeInterval(launcherTimeout + 90)
        advance(to: .starting, runID: currentRun)
        runner.run(command: script, arguments: args, workingDirectory: root, environment: env, timeout: runnerTimeout)
        if runner.isRunning { advance(to: .active, runID: currentRun) }

        Task {
            defer { UpdateSafetyGate.shared.endActivity(activity) }
            while runner.isRunning {
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
            await MainActor.run {
                self.loadResult()
                if self.lastLauncherResult == nil, let cmdResult = self.runner.lastResult {
                    self.lastLauncherResult = LauncherResult(
                        status: cmdResult.status == .success ? "PASS" : "FAIL",
                        rc: cmdResult.exitCode,
                        durationMs: cmdResult.durationMs,
                        error: cmdResult.stderr.isEmpty ? nil : cmdResult.stderr
                    )
                }
                if let result = self.lastLauncherResult {
                    CompatibilityStore.shared.update(from: app, result: result)
                }
                self.finishProgress(runID: currentRun)
                self.onComplete?(self.lastLauncherResult)
            }
        }
    }

    /// Встроенный движок: без сценария, без лимита времени (`timeout` записи — для
    /// замеров разработчика, игроку он закрыл бы игру посреди партии).
    private func runBundled(app: AppEntry, engine: BundledEngine, activity: UUID, runID: UUID) {
        let launcher = EngineLauncher(engine: engine)
        self.launcher = launcher
        let runDirectory = EnginePaths.newRunDirectory()
        jsonOutputPath = runDirectory.appendingPathComponent("last-run.json").path
        runner.isRunning = true

        let exe = URL(fileURLWithPath: app.exePath)
        let arguments = app.args ?? []
        let workdir = app.workdir.map { URL(fileURLWithPath: $0, isDirectory: true) }
        // Счётчик FPS (Metal HUD) из настроек; переменные самой игры главнее.
        let extra = PerformanceHUD.launchEnvironment(appEnvironment: app.env ?? [:])
        let override = app.graphicsAPI.flatMap(GraphicsAPI.init(rawValue:))
        Task.detached(priority: .userInitiated) {
            defer { UpdateSafetyGate.shared.endActivity(activity) }
            // Графику подбираем по файлам игры до запуска: разбор читает только заголовки
            // и до 96 МБ строк, но на больших играх это заметно — не на главном потоке.
            let detection = GraphicsProbe.detect(exe: exe)
            let plan = GraphicsSelector.plan(detection: detection, engine: engine, override: override)
            if case .launch = plan.decision {
                await MainActor.run { self.keyboardLayout = GameKeyboardLayout(engine: engine, logURL: runDirectory.appendingPathComponent("keyboard-layout.jsonl")) }
            }
            let result = launcher.run(exe: exe, arguments: arguments, workdir: workdir,
                                      extraEnvironment: extra, runDirectory: runDirectory, graphics: plan,
                                      minimumProcessLifetime: detection.profile != nil && !(app.tags ?? []).contains("acceptance-probe") ? 10 : nil,
                                      onProgress: { phase in
                Task { @MainActor in self.advance(to: phase, runID: runID) }
            })
            await MainActor.run {
                self.keyboardLayout?.finish()
                self.keyboardLayout = nil
                self.runner.isRunning = false
                self.lastLauncherResult = result
                CompatibilityStore.shared.update(from: app, result: result)
                self.finishProgress(runID: runID)
                self.onComplete?(result)
            }
        }
    }

    func cancel() {
        advance(to: .stopping, runID: runID)
        launcher?.stop()
        runner.cancel()
    }

    private func advance(to phase: LaunchPhase, runID: UUID) {
        guard self.runID == runID, var progress = launchProgress,
              progress.advance(to: phase) else { return }
        launchProgress = progress
        onProgress?(progress)
    }

    private func finishProgress(runID: UUID) {
        guard self.runID == runID else { return }
        launchProgress = nil
        onProgress?(nil)
    }

    private func loadResult() {
        guard !jsonOutputPath.isEmpty,
              let data = try? Data(contentsOf: URL(fileURLWithPath: jsonOutputPath)) else { return }
        do {
            lastLauncherResult = try JSONDecoder().decode(LauncherResult.self, from: data)
        } catch {
            lastLauncherResult = nil
        }
    }
}
