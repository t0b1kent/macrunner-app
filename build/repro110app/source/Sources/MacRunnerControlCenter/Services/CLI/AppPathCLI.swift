import AppKit
import Foundation

/// Acceptance entry inside the shipped executable. All launches still pass
/// through the library's RunAppViewModel, GraphicsSelector and EngineLauncher.
enum AppPathCLI {
    struct AcceptanceArguments: Equatable {
        var guest: [String] = []
        var environment: [String: String] = [:]
        var probe = false
    }

    enum ArgumentError: Error {
        case invalidEnvironment
    }

    /// Ephemeral acceptance options never enter the saved library entry.
    /// Split at the first '=' so paths and configuration strings stay byte-exact.
    static func acceptanceArguments(_ arguments: [String]) throws -> AcceptanceArguments {
        var parsed = AcceptanceArguments()
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if argument == "--" {
                parsed.guest += arguments.dropFirst(index + 1)
                break
            } else if argument == "--acceptance-probe" {
                parsed.probe = true
            } else if argument == "--acceptance-env" {
                index += 1
                guard index < arguments.count,
                      let separator = arguments[index].firstIndex(of: "=") else {
                    throw ArgumentError.invalidEnvironment
                }
                let key = String(arguments[index][..<separator])
                let value = String(arguments[index][arguments[index].index(after: separator)...])
                guard key.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil,
                      !value.contains("\0") else { throw ArgumentError.invalidEnvironment }
                parsed.environment[key] = value
            } else {
                parsed.guest.append(argument)
            }
            index += 1
        }
        return parsed
    }

    static func isolatedPaths(environment: [String: String], forbiddenBase: URL) -> [String: String]? {
        guard let raw = environment["MACRUNNER_APP_DATA_ROOT"], raw.hasPrefix("/") else { return nil }
        let base = URL(fileURLWithPath: raw, isDirectory: true).standardizedFileURL.resolvingSymlinksInPath()
        let forbidden = forbiddenBase.standardizedFileURL.resolvingSymlinksInPath().path
        guard base.path != forbidden, !base.path.hasPrefix(forbidden + "/") else { return nil }
        return ["data_root": base.path,
                "bottle": base.appendingPathComponent("Bottles/Default").path,
                "runs": base.appendingPathComponent("Runs").path]
    }

    @MainActor
    static func handleIfNeeded() {
        let args = CommandLine.arguments
        guard args.count > 1, ["--run-app-entry", "--run-app-entry-paths"].contains(args[1]) else {
            if args.contains("--acceptance-env") {
                fputs("APP_PATH_REFUSED: --acceptance-env requires --run-app-entry and an explicit isolated data root.\n", stderr)
                exit(2)
            }
            return
        }
        // This check precedes engine loading, settings, EnginePaths and Wine.
        let forbidden = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        guard let paths = isolatedPaths(environment: ProcessInfo.processInfo.environment, forbiddenBase: forbidden) else {
            fputs("APP_PATH_REFUSED: explicitly set MACRUNNER_APP_DATA_ROOT outside Library/Application Support before using this entry.\n", stderr)
            exit(2)
        }
        guard EnginePaths.base.resolvingSymlinksInPath().standardizedFileURL.path == paths["data_root"],
              EnginePaths.defaultBottle.resolvingSymlinksInPath().standardizedFileURL.path == paths["bottle"],
              EnginePaths.runs.resolvingSymlinksInPath().standardizedFileURL.path == paths["runs"] else {
            fputs("APP_PATH_REFUSED: resolved engine paths do not match the isolated data root.\n", stderr)
            exit(2)
        }
        if args[1] == "--run-app-entry-paths" {
            if let data = try? JSONSerialization.data(withJSONObject: paths, options: [.sortedKeys]),
               let text = String(data: data, encoding: .utf8) { print(text); exit(0) }
            exit(2)
        }
        guard args.count >= 5, let seconds = Double(args[3]), seconds > 0, seconds <= 400,
              args[2].hasPrefix("/"), args[4].hasPrefix("/"), BundledEngine.current != nil else {
            fputs("--run-app-entry <absolute-exe> <seconds:1...400> <absolute-result.json> requires a bundled engine and MACRUNNER_APP_DATA_ROOT\n", stderr)
            exit(2)
        }
        let accepted: AcceptanceArguments
        do { accepted = try acceptanceArguments(Array(args.dropFirst(5))) }
        catch {
            fputs("APP_PATH_REFUSED: --acceptance-env requires NAME=VALUE with a valid environment variable name.\n", stderr)
            exit(2)
        }
        let resultURL = URL(fileURLWithPath: args[4])
        let model = RunAppViewModel(settings: .default)
        var app = AppEntry.new(name: URL(fileURLWithPath: args[2]).deletingPathExtension().lastPathComponent, exePath: args[2])
        app.args = accepted.guest
        app.env = accepted.environment
        // A seconds-long gate deliberately exits quickly. It still uses every
        // product preparation/selection/launch step; only its lifetime expectation differs.
        if accepted.probe {
            app.tags = ["acceptance-probe"]
        }
        // Timer is acceptance-only. Normal player launches remain unbounded.
        model.onComplete = { result in
            var result = result ?? LauncherResult(status: "FAIL", error: "App path completed without a result")
            result.envOverrides = accepted.environment.keys.sorted()
            result.acceptanceEnvironment = accepted.environment
            do {
                try FileManager.default.createDirectory(at: resultURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try JSONEncoder.pretty.encode(result).write(to: resultURL, options: .atomic)
                print("APP_PATH_RESULT status=\(result.status ?? "unknown") run=\(model.jsonOutputPath)")
                exit(result.status == "UNSUPPORTED" ? 3 : ["FAIL", "CRASH", "EARLY_EXIT"].contains(result.status ?? "") ? 1 : 0)
            } catch {
                fputs("App path result write failed: \(error.localizedDescription)\n", stderr)
                exit(2)
            }
        }
        NSApplication.shared.setActivationPolicy(.accessory)
        DispatchQueue.main.async {
            model.run(app: app)
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { model.cancel() }
        }
        NSApplication.shared.run()
        withExtendedLifetime(model) {}
        exit(2)
    }
}
