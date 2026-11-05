import CryptoKit
import Darwin
import Foundation

/// The c31/c32 DXIL corpus and both PSO controls proved these two namespaces
/// interchangeable. A different graphics binary needs a new equivalence proof.
enum PSOCacheTransplant {
    private static let lock = NSLock()
    static let versions = [
        "9598ab010d5b-4e89a8cc-": "9598ab010d5b-de834a3d-",
        "9598ab010d5b-864097a5-": "9598ab010d5b-072b0e05-"
    ]
    private static let binaries = [
        "graphics/aarch64-unix/winemetal.so": "f8d176c7c1020a94ae96162739eed2a9be514a32d8b2df61292d267370b8bf08",
        "graphics/aarch64-windows/d3d12.dll": "bdc20b6bd1b97141d3331d9e203777771cc5d9d64221724fee957f6fc689e981"
    ]
    enum Failure: Error { case unsafeNode, invalidFormat, inventoryLimit, changedSource, changedCopy, copyFailed(Int32) }

    static func digest(_ file: URL) throws -> String {
        let data = try Data(contentsOf: file, options: .mappedIfSafe)
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func cacheDirectory(environment: [String: String], executable: String) -> URL? {
        let count = confstr(_CS_DARWIN_USER_CACHE_DIR, nil, 0)
        guard count > 1, count < 16384 else { return nil }
        var buffer = [CChar](repeating: 0, count: count)
        guard confstr(_CS_DARWIN_USER_CACHE_DIR, &buffer, count) == count else { return nil }
        let relative = environment["MACRUNNER_DX12_PSO_CACHE_DIR"] ?? "dxmt/\(executable)/pso"
        let parts = relative.split(separator: "/", omittingEmptySubsequences: false)
        guard !relative.isEmpty, !relative.hasPrefix("/"), !relative.contains("\\"),
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { return nil }
        return URL(fileURLWithPath: String(cString: buffer), isDirectory: true)
            .resolvingSymlinksInPath().appendingPathComponent(relative)
    }

    /// Run before the first game process. Cache failure leaves the normal cold path available.
    static func prepare(engine: BundledEngine, executable: URL, environment: [String: String]) -> String {
        guard executable.lastPathComponent.lowercased() == "eldenring.exe",
              environment["MACRUNNER_DX12_PSO_CACHE"] == "1",
              let directory = cacheDirectory(environment: environment, executable: executable.lastPathComponent)
        else { return "NOT_ENABLED" }
        lock.lock()
        defer { lock.unlock() }
        do {
            let candidates = try candidates(in: directory)
            guard !candidates.isEmpty else { return "EMPTY: no approved warm source awaiting migration" }
            for (name, expected) in binaries {
                let file = engine.root.appendingPathComponent(name)
                guard try digest(file) == expected else { return "NOT_ENABLED: graphics binary has no PSO equivalence proof" }
            }
            var migrated = 0
            for (source, target) in candidates {
                if try transplant(source: source, target: target) { migrated += 1 }
            }
            return "PRESENT: transplanted=\(migrated)"
        } catch CocoaError.fileReadNoSuchFile { return "EMPTY: no previous PSO cache" }
        catch { return "FAILED: \(error)" }
    }

    static func candidates(in directory: URL) throws -> [(URL, URL)] {
        let fm = FileManager.default
        guard !directory.resolvingSymlinksInPath().path.isEmpty,
              directory.standardizedFileURL.path == directory.resolvingSymlinksInPath().path else { throw Failure.unsafeNode }
        return try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
            .sorted { $0.lastPathComponent < $1.lastPathComponent }.compactMap { source in
                guard let pair = versions.first(where: { source.lastPathComponent.hasPrefix($0.key) }) else { return nil }
                let suffix = String(source.lastPathComponent.dropFirst(pair.key.count))
                guard !suffix.isEmpty, suffix.count <= 128,
                      suffix.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil else { return nil }
                let target = directory.appendingPathComponent(pair.value + suffix)
                guard !fm.fileExists(atPath: target.path) else { return nil }
                return (source, target)
            }
    }

    /// Hash all bytes before and after the APFS clone. A concurrent writer closes the migration.
    static func inventory(_ root: URL) throws -> [String: String] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey, .fileSizeKey]
        let rootValues = try root.resourceValues(forKeys: Set(keys))
        guard rootValues.isDirectory == true, rootValues.isSymbolicLink != true,
              let nodes = fm.enumerator(atPath: root.path) else { throw Failure.unsafeNode }
        var result: [String: String] = [:]
        var bytes: Int64 = 0
        for case let relative as String in nodes {
            let file = root.appendingPathComponent(relative)
            let values = try file.resourceValues(forKeys: Set(keys))
            guard values.isSymbolicLink != true else { throw Failure.unsafeNode }
            if values.isDirectory == true { continue }
            guard values.isRegularFile == true else { throw Failure.unsafeNode }
            bytes += Int64(values.fileSize ?? 0)
            guard result.count < 65536, bytes <= 16 * 1024 * 1024 * 1024 else { throw Failure.inventoryLimit }
            result[relative] = try digest(file)
        }
        return result
    }

    @discardableResult
    static func transplant(source: URL, target: URL) throws -> Bool {
        let fm = FileManager.default
        guard source.deletingLastPathComponent() == target.deletingLastPathComponent() else { throw Failure.unsafeNode }
        guard !fm.fileExists(atPath: target.path) else { return false }
        let before = try inventory(source)
        let manifest = try Data(contentsOf: source.appendingPathComponent("manifest.bin"))
        let index = try Data(contentsOf: source.appendingPathComponent("pack.idx"))
        guard manifest.count >= 16, manifest.prefix(8) == Data([77, 82, 80, 83, 79, 49, 0, 0]),
              manifest[8..<12] == Data([1, 0, 0, 0]), index.count >= 16,
              index.prefix(8) == Data("MRPKIDX6".utf8), (index.count - 16) % 360 == 0 else { throw Failure.invalidFormat }
        let temporary = target.deletingLastPathComponent().appendingPathComponent(".macrunner-pso-\(UUID().uuidString)")
        defer { if fm.fileExists(atPath: temporary.path) { try? fm.removeItem(at: temporary) } }
        let flags = copyfile_flags_t(COPYFILE_ALL | COPYFILE_RECURSIVE | COPYFILE_CLONE | COPYFILE_NOFOLLOW)
        guard copyfile(source.path, temporary.path, nil, flags) == 0 else { throw Failure.copyFailed(errno) }
        let copied = try inventory(temporary)
        guard try inventory(source) == before else { throw Failure.changedSource }
        guard copied == before else { throw Failure.changedCopy }
        // moveItem refuses an existing destination, including one created by another process.
        try fm.moveItem(at: temporary, to: target)
        return true
    }
}
