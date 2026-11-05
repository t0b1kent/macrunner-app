import CryptoKit
import Darwin
import Foundation

/// A release catalogue binds proved cache namespaces to the final signed graphics bytes.
/// Its hashes are filled after signing; the application code is built from source on GitHub.
enum PSOCacheTransplant {
    private static let lock = NSLock()
    struct Compatibility: Decodable {
        let schema: Int
        let versions: [String: String]
        let binaries: [String: String]
    }
    private static let historicalVersions = [
        "9598ab010d5b-4e89a8cc-": "9598ab010d5b-de834a3d-",
        "9598ab010d5b-864097a5-": "9598ab010d5b-072b0e05-"
    ]
    private static let historicalBinaries = [
        "graphics/aarch64-unix/winemetal.so": "f8d176c7c1020a94ae96162739eed2a9be514a32d8b2df61292d267370b8bf08",
        "graphics/aarch64-windows/d3d12.dll": "bdc20b6bd1b97141d3331d9e203777771cc5d9d64221724fee957f6fc689e981"
    ]
    enum Failure: Error { case unsafeNode, invalidFormat, inventoryLimit, changedSource, changedCopy, copyFailed(Int32) }

    static func decodeCompatibility(_ data: Data) throws -> Compatibility {
        let value = try JSONDecoder().decode(Compatibility.self, from: data)
        guard value.schema == 1, !value.versions.isEmpty, value.versions.count <= 16,
              Set(value.binaries.keys) == Set(historicalBinaries.keys),
              value.binaries.values.allSatisfy({ $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil }),
              value.versions.allSatisfy({ source, target in
                  source != target && [source, target].allSatisfy {
                      $0.range(of: "^[0-9a-f]{12}-[0-9a-f]{8}-$", options: .regularExpression) != nil
                  }
              }) else { throw Failure.invalidFormat }
        return value
    }

    private static let compatibility: Compatibility = {
        guard let url = Bundle.module.url(forResource: "pso-cache-compatibility", withExtension: "json", subdirectory: "BottleCatalogues")
                ?? Bundle.module.url(forResource: "pso-cache-compatibility", withExtension: "json") else {
            return Compatibility(schema: 1, versions: historicalVersions, binaries: historicalBinaries)
        }
        // An invalid release catalogue disables migration. It must never broaden the approved set.
        return (try? decodeCompatibility(Data(contentsOf: url)))
            ?? Compatibility(schema: 1, versions: [:], binaries: [:])
    }()
    static var versions: [String: String] { compatibility.versions }

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
            for (name, expected) in compatibility.binaries {
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
