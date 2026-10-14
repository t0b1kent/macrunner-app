import AppKit
import Carbon

/// A launch owns a retained input source until every process in its bottle exits.
/// Re-select on Wine activation/input-source notification because macOS can
/// remember an independent source for each document/window.
@MainActor
final class GameKeyboardLayout {
    static let defaultsKey = "macrunner.gameASCIIKeyboard"
    static var enabled: Bool {
        if ProcessInfo.processInfo.environment["MACRUNNER_ACCEPTANCE_KEEP_INPUT_SOURCE"] == "1" { return false }
        return UserDefaults.standard.object(forKey: defaultsKey) as? Bool ?? true
    }
    private let previous: TISInputSource
    private let ascii: TISInputSource
    private let engineRoot: String
    private let loaderRoot: String?
    private var workspaceObserver: NSObjectProtocol?
    private var inputObserver: NSObjectProtocol?
    private var finished = false
    private var selecting = false
    private let logURL: URL?

    init?(engine: BundledEngine, logURL: URL? = nil) {
        guard Self.enabled,
              let previous = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(),
              let ascii = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return nil }
        self.previous = previous
        self.ascii = ascii
        self.logURL = logURL
        engineRoot = engine.root.resolvingSymlinksInPath().path + "/"
        loaderRoot = Bundle.main.resourceURL?.appendingPathComponent("wine-loader").resolvingSymlinksInPath().path
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.enforceForGameWindow() }
            }
        inputObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String), object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.enforceForGameWindow() }
            }
        selectASCII()
        record("begin", status: noErr)
    }

    private func selectASCII() {
        guard !finished, !selecting else { return }
        guard let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue(), !CFEqual(current, ascii) else { return }
        selecting = true
        let result = TISSelectInputSource(ascii)
        selecting = false
        record("selectASCII", status: result)
    }

    private func enforceForGameWindow() {
        guard !finished, let app = NSWorkspace.shared.frontmostApplication,
              let executable = app.executableURL?.resolvingSymlinksInPath().path else { return }
        let loader = loaderRoot.map { executable.hasPrefix($0 + "/") } ?? false
        guard executable.hasPrefix(engineRoot) || loader else { return }
        // Let the document's remembered input source settle after activation.
        selectASCII()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            guard let self, !self.finished,
                  NSWorkspace.shared.frontmostApplication?.processIdentifier == app.processIdentifier else { return }
            self.selectASCII()
        }
    }

    /// Shared exit path for normal completion, cancellation, and a Wine crash.
    func finish() {
        guard !finished else { return }
        finished = true
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let inputObserver { DistributedNotificationCenter.default().removeObserver(inputObserver) }
        workspaceObserver = nil
        inputObserver = nil
        let result = TISSelectInputSource(previous)
        record("restore", status: result)
    }

    private func record(_ event: String, status: OSStatus) {
        guard let logURL else { return }
        func identifier(_ source: TISInputSource) -> String {
            guard let raw = TISGetInputSourceProperty(source, kTISPropertyInputSourceID) else { return "unknown" }
            return Unmanaged<CFString>.fromOpaque(raw).takeUnretainedValue() as String
        }
        let current = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue()
        let row: [String: Any] = ["event": event, "status": status,
            "utc": ISO8601DateFormatter().string(from: Date()), "systemUptime": ProcessInfo.processInfo.systemUptime,
            "previous": identifier(previous), "ascii": identifier(ascii),
            "current": current.map(identifier) ?? "unknown"]
        guard var bytes = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return }
        bytes.append(10)
        try? FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: logURL.path) { FileManager.default.createFile(atPath: logURL.path, contents: nil) }
        if let file = try? FileHandle(forWritingTo: logURL) {
            defer { try? file.close() }
            _ = try? file.seekToEnd()
            try? file.write(contentsOf: bytes)
        }
    }
}
