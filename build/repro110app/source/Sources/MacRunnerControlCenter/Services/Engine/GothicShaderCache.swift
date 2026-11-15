import Darwin
import Foundation

/// Preserve Wine-compiled Gothic caches before a verified Microsoft rebuild.
/// No Wine process, compiler, game data download, or deletion is involved.
enum GothicShaderCache {
    static let maximumBytes = 40 * 1024 * 1024
    static let explanation = "Gothic 3 builds its shader cache on first launch (about 6 minutes). Press OK in the game's window to start."
    private static let lock = NSLock()

    struct Stamp: Equatable {
        let isCache: Bool
        let vkd3d: Int
        let microsoft: Int
        var needsRebuild: Bool { isCache && vkd3d > 0 }
    }

    struct Result {
        var note: String
        var notice: String? = nil
        var preserved: URL? = nil
    }

    static func stamp(_ data: Data) -> Stamp {
        guard data.count <= maximumBytes, data.starts(with: Data("GENOMESC".utf8)) else {
            return Stamp(isCache: false, vkd3d: 0, microsoft: 0)
        }
        func count(_ text: String) -> Int {
            let needle = Data(text.utf8)
            var start = data.startIndex, found = 0
            while start < data.endIndex, let range = data.range(of: needle, in: start..<data.endIndex) {
                found += 1
                start = range.upperBound
            }
            return found
        }
        return Stamp(isCache: true, vkd3d: count("vkd3d-shader"), microsoft: count("Microsoft (R) HLSL Shader Compiler"))
    }

    /// Wine uses the last matching override, including names grouped with commas.
    static func usesMicrosoft(_ overrides: String) -> Bool {
        var order: [String] = []
        for entry in overrides.split(separator: ";") {
            let parts = entry.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { continue }
            if GameRedist.overrideNames(String(parts[0]) + "=x").contains("d3dx9_40") {
                order = parts[1].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            }
        }
        return order == ["n", "b"]
    }

    private static func child(_ name: String, in directory: URL) throws -> URL? {
        let matches = try FileManager.default.contentsOfDirectory(at: directory.resolvingSymlinksInPath(), includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.caseInsensitiveCompare(name) == .orderedSame }
        // Case-sensitive volumes can hold two names that Windows considers equal.
        guard matches.count <= 1 else { throw CocoaError(.fileReadInvalidFileName) }
        return matches.first
    }

    static func cacheURL(prefix: URL, user: String) throws -> URL? {
        let users = prefix.appendingPathComponent("drive_c/users")
        guard FileManager.default.fileExists(atPath: users.path) else { return nil }
        let entries = try FileManager.default.contentsOfDirectory(at: users, includingPropertiesForKeys: [.isDirectoryKey])
            .filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
            .filter { !["public", "default", "default user", "all users"].contains($0.lastPathComponent.lowercased()) }
        let matching = entries.filter { $0.lastPathComponent.caseInsensitiveCompare(user) == .orderedSame }
        let selected = matching.count == 1 ? matching.first : (entries.count == 1 ? entries.first : nil)
        guard let selected, let documents = try child("Documents", in: selected),
              let gothic = try child("Gothic3", in: documents) else { return nil }
        return try child("Shader.Cache", in: gothic)
    }

    static func prepare(executable: URL, prefix: URL, layer: String?, environment: [String: String],
                        isBusy: () -> Bool, now: Date = Date()) -> Result {
        guard executable.lastPathComponent.caseInsensitiveCompare("Gothic3.exe") == .orderedSame,
              layer == "hbdx9-d3d9-x86" else { return Result(note: "NOT_ENABLED: another game or graphics route") }
        guard usesMicrosoft(environment["WINEDLLOVERRIDES"] ?? "") else {
            return Result(note: "NOT_ENABLED: d3dx9_40=n,b is required for a Microsoft rebuild")
        }
        lock.lock(); defer { lock.unlock() }
        guard !isBusy() else { return Result(note: "NOT_ENABLED: bottle may be running") }
        do {
            let game = executable.deletingLastPathComponent()
            guard let compiler = try child("d3dx9_40.dll", in: game),
                  let expected = GameRedist.microsoftReleases["d3dx9_40.dll#32"]?.sha256,
                  try BottleUpdateCatalogue.digest(compiler) == expected else {
                return Result(note: "NOT_ENABLED: no pinned Microsoft d3dx9_40 beside Gothic3.exe")
            }
            guard let cache = try cacheURL(prefix: prefix, user: environment["USER"] ?? NSUserName()) else {
                return Result(note: "EMPTY: no Gothic shader cache", notice: explanation)
            }
            let attributes = try FileManager.default.attributesOfItem(atPath: cache.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? NSNumber, size.intValue <= maximumBytes else {
                return Result(note: "NOT_ENABLED: shader cache is not a bounded regular file")
            }
            let file = try FileHandle(forReadingFrom: cache)
            defer { try? file.close() }
            let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
            let stamp = stamp(data)
            guard stamp.needsRebuild else {
                return Result(note: "PRESENT: shader cache unchanged; GENOMESC=\(stamp.isCache) vkd3d=\(stamp.vkd3d) microsoft=\(stamp.microsoft)")
            }
            guard !isBusy(), try BottleUpdateCatalogue.digest(cache) == GameRedist.sha256(data) else {
                return Result(note: "NOT_ENABLED: bottle or shader cache changed during inspection")
            }
            let format = DateFormatter()
            format.locale = Locale(identifier: "en_US_POSIX")
            format.timeZone = TimeZone(secondsFromGMT: 0)
            format.dateFormat = "yyyyMMdd-HHmmss"
            let name = cache.lastPathComponent + ".vkd3d-" + format.string(from: now)
            for suffix in 0..<100 {
                let destination = cache.deletingLastPathComponent().appendingPathComponent(name + (suffix == 0 ? "" : "-\(suffix)"))
                if renameatx_np(AT_FDCWD, cache.path, AT_FDCWD, destination.path, UInt32(RENAME_EXCL)) == 0 {
                    return Result(note: "PRESERVED: \(destination.lastPathComponent) sha256=\(GameRedist.sha256(data)) vkd3d=\(stamp.vkd3d) microsoft=\(stamp.microsoft)",
                                  notice: explanation, preserved: destination)
                }
                guard errno == EEXIST else { throw CocoaError(.fileWriteUnknown) }
            }
            return Result(note: "FAILED: shader cache backup name limit; original retained")
        } catch {
            return Result(note: "FAILED: shader cache inspection/preservation; original retained (\(error.localizedDescription))")
        }
    }
}
