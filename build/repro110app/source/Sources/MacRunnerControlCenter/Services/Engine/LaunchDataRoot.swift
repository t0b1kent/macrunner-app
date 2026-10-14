import Foundation

/// Candidate qualification must never initialize the owner's real library as a
/// side effect of a missing argument. This check runs before CLI/model creation.
enum LaunchDataRoot {
    enum Failure: Error { case explicitRootRequired, unsafeRoot }
    private static func canonicalRoot(_ root: URL) -> URL {
        var parent = root.standardizedFileURL
        var suffix: [String] = []
        while !FileManager.default.fileExists(atPath: parent.path), parent.path != "/" {
            suffix.insert(parent.lastPathComponent, at: 0)
            parent.deleteLastPathComponent()
        }
        parent = parent.resolvingSymlinksInPath()
        for name in suffix { parent.appendPathComponent(name, isDirectory: true) }
        return parent
    }
    static func resolve(environment: [String: String],
                        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        guard let path = environment["MACRUNNER_APP_DATA_ROOT"], path.hasPrefix("/"), path != "/" else {
            throw Failure.explicitRootRequired
        }
        let requested = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let owner = homeDirectory.appendingPathComponent("Library/Application Support/MacRunnerControlCenter").standardizedFileURL
        let parent = canonicalRoot(requested)
        let protected = canonicalRoot(owner).path
        // Normalize both sides: the owner's library or any of its ancestors may
        // itself be a symlink after a data relocation. Lexical spelling remains
        // protected as well, including a not-yet-created child directory.
        guard requested.path != owner.path, !requested.path.hasPrefix(owner.path + "/"),
              parent.path != "/", parent.path != protected, !parent.path.hasPrefix(protected + "/") else {
            throw Failure.unsafeRoot
        }
        return parent
    }
    static func required() -> URL {
        do { return try resolve(environment: ProcessInfo.processInfo.environment) }
        catch {
            fputs("LAUNCH_DATA_ROOT_REFUSED: explicit isolated data root required; Wine not started\n", stderr)
            exit(2)
        }
    }
}
