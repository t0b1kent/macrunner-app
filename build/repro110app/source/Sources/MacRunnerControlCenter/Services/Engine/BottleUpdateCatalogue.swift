import CryptoKit
import Darwin
import Foundation

/// Prefix inputs, independent of the translator/release name. Unknown history
/// always uses the existing full preparation; it never creates a Ready marker.
struct BottleUpdateCatalogue: Codable, Equatable {
    struct File: Codable, Equatable {
        let source: String
        let sha256: String
    }

    let schema: Int
    let engine: String
    let engineRoot: String
    let layers: [String]
    let inputs: [String: String]
    let files: [String: File]
    /// Preserve exact manifest bytes: the engine stamp authenticates history,
    /// not a mutable, independently editable projection of its file inventory.
    var manifest: Data? = nil

    /// Digests come from the release inventory. These are change detectors for
    /// the files successfully installed from that release, not new DLL hashes.
    /// Ignore atime: loading a DLL is not a change to the installed generation.
    struct Identity: Codable, Equatable {
        let device: Int32
        let inode: UInt64
        let mode: UInt16
        let links: UInt16
        let size: Int64
        let modifiedSeconds: Int64
        let modifiedNanoseconds: Int64
        let changedSeconds: Int64
        let changedNanoseconds: Int64
        let bornSeconds: Int64
        let bornNanoseconds: Int64
        let flags: UInt32

        static func read(_ url: URL, directory: Bool = false) throws -> Self {
            var value = stat()
            let rc = url.path.withCString { Darwin.lstat($0, &value) }
            guard rc == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            guard (value.st_mode & S_IFMT) == (directory ? S_IFDIR : S_IFREG),
                  directory || value.st_nlink == 1 else { throw CocoaError(.fileReadCorruptFile) }
            return Self(device: value.st_dev, inode: value.st_ino, mode: value.st_mode,
                links: value.st_nlink, size: value.st_size,
                modifiedSeconds: Int64(value.st_mtimespec.tv_sec), modifiedNanoseconds: Int64(value.st_mtimespec.tv_nsec),
                changedSeconds: Int64(value.st_ctimespec.tv_sec), changedNanoseconds: Int64(value.st_ctimespec.tv_nsec),
                bornSeconds: Int64(value.st_birthtimespec.tv_sec), bornNanoseconds: Int64(value.st_birthtimespec.tv_nsec),
                flags: value.st_flags)
        }
    }

    struct Ownership: Codable, Equatable {
        let prefixRoot: String
        let files: [String: Identity]
    }
    var ownership: Ownership? = nil

    /// Call only after copying the trusted release, or after an accepted delta.
    /// Missing receipts on legacy bottles use full setup, never an SHA crawl.
    func recordingInstallation(prefix: URL) throws -> Self {
        var result = self
        result.ownership = Ownership(prefixRoot: prefix.resolvingSymlinksInPath().standardizedFileURL.path,
            files: try identities(prefix: prefix))
        return result
    }

    private func identities(prefix: URL) throws -> [String: Identity] {
        let root = prefix.resolvingSymlinksInPath().standardizedFileURL
        let rootPath = root.path
        var parents = Set<String>()
        var result: [String: Identity] = [:]
        for target in files.keys.sorted() {
            guard Self.safePath(target) else { throw CocoaError(.fileReadCorruptFile) }
            let url = root.appendingPathComponent(target)
            var parent = url.deletingLastPathComponent()
            var depth = 0
            // URL equality also compares the directory's trailing slash. A URL
            // constructed before mkdir may differ from its own child's parent.
            // Use the canonical path and bound the walk before reaching /.
            while parent.path != rootPath {
                depth += 1
                guard depth <= 128, parent.path != "/", parent.path.hasPrefix(rootPath + "/") else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                if parents.insert(parent.path).inserted { _ = try Identity.read(parent, directory: true) }
                parent.deleteLastPathComponent()
            }
            result[target] = try Identity.read(url)
        }
        return result
    }

    static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    static func digest(_ file: URL) throws -> String {
        digest(try Data(contentsOf: file, options: .mappedIfSafe))
    }

    private static func safePath(_ path: String) -> Bool {
        !path.isEmpty && !path.hasPrefix("/") && !path.contains("\\")
            && path.split(separator: "/", omittingEmptySubsequences: false)
                .allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
    }

    /// Build the last-writer map matching syncModules + default graphics. The
    /// immutable release manifest supplies package digests; only replacements
    /// need package-byte verification when staged. Prefix ownership is separate.
    static func make(manifest data: Data, engineRoot: String, prefix: URL,
                     graphics: GraphicsCatalog, layers: [String]) throws -> Self? {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let declared = object["files"] as? [String: String], !declared.isEmpty,
              let environment = object["environment"] as? [String: String],
              declared.allSatisfy({ safePath($0.key)
                  && $0.value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil })
        else { return nil }
        var files: [String: File] = [:]
        func place(_ source: String, _ target: String) {
            if let hash = declared[source] { files[target] = File(source: source, sha256: hash) }
        }
        for (arch, target) in [("aarch64-windows", "system32"), ("i386-windows", "syswow64")] {
            let base = "wine/lib/wine/\(arch)/"
            for source in declared.keys.sorted() where source.hasPrefix(base) {
                let name = String(source.dropFirst(base.count))
                guard !name.contains("/"), name != "ntdll.dll", !name.hasSuffix(".a") else { continue }
                place(source, "drive_c/windows/\(target)/\(name)")
            }
        }
        for (source, targets) in [
            ("wine/lib/wine/aarch64-windows/xtajit.dll", ["system32", "syswow64"]),
            ("wine/lib/wine/x86_64-windows/wow64cpu.dll", ["system32", "syswow64"]),
            ("wine/lib/wine/x86_64-windows/wow64.dll", ["syswow64"]),
            ("wine/lib/wine/x86_64-windows/wow64win.dll", ["syswow64"]),
        ] {
            for target in targets { place(source, "drive_c/windows/\(target)/\(URL(fileURLWithPath: source).lastPathComponent)") }
        }
        let winsxs = prefix.appendingPathComponent("drive_c/windows/winsxs")
        let dirs = try FileManager.default.contentsOfDirectory(at: winsxs,
            includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for (arch, lib) in [("amd64", "x86_64-windows"), ("x86", "i386-windows"), ("arm64", "aarch64-windows")] {
            let matching = dirs.filter { $0.lastPathComponent.hasPrefix("\(arch)_microsoft.windows.common-controls")
                && $0.lastPathComponent.contains("_6.") && !$0.lastPathComponent.hasSuffix(".manifest") }
            // Match syncCommonControls: full preparation creates missing arm64
            // and x86 manifests, but never invents an amd64 directory. ARM64EC
            // bottles legitimately have only arm64/x86 common-controls. Include
            // every existing amd64 directory, without requiring an unused one.
            // Missing generated architecture topology still requires full setup.
            guard arch == "amd64" || !matching.isEmpty else { return nil }
            for dir in matching {
                let type = try dir.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
                guard type.isDirectory == true, type.isSymbolicLink != true else { return nil }
                place("wine/lib/wine/\(lib)/comctl32_v6.dll",
                      "drive_c/windows/winsxs/\(dir.lastPathComponent)/comctl32.dll")
            }
        }
        for id in layers {
            guard let layer = graphics.layer(id) else { return nil }
            for (target, source) in graphics.placements(of: layer) {
                guard declared[source] != nil else { return nil }
                place(source, "drive_c/windows/\(target)")
            }
        }
        guard files["drive_c/windows/system32/windowscodecs.dll"] != nil,
              declared["wine/share/wine/wine.inf"] != nil else { return nil }
        // Deliberately conservative for 1.1.0: only xtajit64 is a proven
        // non-registration PE input. Other Wine or graphics changes use full.
        var inputs = declared.filter {
            ($0.key.hasPrefix("wine/") || $0.key.hasPrefix("graphics/"))
                && $0.key != "wine/lib/wine/aarch64-windows/xtajit64.dll"
                && !$0.key.hasSuffix(".a")
        }
        // Translator options affect process execution, not Wine prefix setup.
        // Keep Wine/graphics settings conservative; don't couple a generation
        // of the bottle to HB/FEX tuning or observers.
        let prefixEnvironment = environment.filter {
            !$0.key.hasPrefix("MACRUNNER_HB_") && !$0.key.hasPrefix("MACRUNNER_FEX_") && !$0.key.hasPrefix("FEX_")
        }
        inputs["@environment"] = digest(try JSONSerialization.data(withJSONObject: prefixEnvironment, options: .sortedKeys))
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        inputs["@graphics"] = digest(try encoder.encode(graphics.layers))
        return Self(schema: 1, engine: digest(data), engineRoot: engineRoot,
                    layers: layers, inputs: inputs, files: files, manifest: data)
    }

    /// Refuse missing/corrupt history before trusting any stored input or target.
    /// Regenerate its projection from the byte-exact previous release inventory.
    func restored(prefix: URL, package: URL) throws -> Self? {
        guard let manifest, Self.digest(manifest) == engine,
              let object = try JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              object["graphics"] != nil,
              var value = try Self.make(manifest: manifest, engineRoot: engineRoot,
                  prefix: prefix, graphics: GraphicsCatalog.load(manifest: object, engineRoot: package), layers: layers)
        else { return nil }
        value.ownership = ownership
        guard value == self else { return nil }
        return value
    }

    /// Compare the two release inventories without rereading package modules.
    /// The package belongs to the verified, immutable release; a changed file
    /// is checked against that inventory in apply(), before replacing anything.
    /// Check installed change detectors without opening unchanged modules.
    /// Unknown legacy ownership, symlinks and modified targets use full setup.
    func delta(from previous: Self, prefix: URL) throws -> [String]? {
        guard schema == 1, previous.schema == 1, engineRoot == previous.engineRoot,
              layers == previous.layers, inputs == previous.inputs,
              Set(files.keys) == Set(previous.files.keys),
              let ownership = previous.ownership,
              ownership.prefixRoot == prefix.resolvingSymlinksInPath().standardizedFileURL.path,
              Set(ownership.files.keys) == Set(previous.files.keys) else { return nil }
        let fm = FileManager.default
        for forbidden in ["system32/ntdll.dll", "syswow64/ntdll.dll"] {
            let path = prefix.appendingPathComponent("drive_c/windows/\(forbidden)").path
            if fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil { return nil }
        }
        guard let actual = try? previous.identities(prefix: prefix), actual == ownership.files else { return nil }
        return files.keys.filter { files[$0] != previous.files[$0] }.sorted()
    }

    /// Stage and verify all replacements before mutation; retain an exact copy
    /// until replacement succeeds. On failure restore the old generation.
    func apply(_ delta: [String], from previous: Self, prefix: URL, package: URL) throws {
        guard delta.allSatisfy({ files[$0] != nil && previous.files[$0] != nil }) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        if delta.isEmpty { return }
        let fm = FileManager.default
        let stage = prefix.appendingPathComponent(".macrunner-update-\(UUID().uuidString)")
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var committed: [String] = []
        var restored = true
        defer { if restored { try? fm.removeItem(at: stage) } }
        func renameFile(_ from: URL, _ to: URL) throws {
            let rc = from.path.withCString { a in to.path.withCString { b in Darwin.rename(a, b) } }
            if rc != 0 { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        }
        do {
            for (index, target) in delta.enumerated() {
                let destination = prefix.appendingPathComponent(target)
                guard try Self.digest(destination) == previous.files[target]!.sha256 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                try fm.copyItem(at: destination, to: stage.appendingPathComponent("old-\(index)"))
                let new = stage.appendingPathComponent("new-\(index)")
                try fm.copyItem(at: package.appendingPathComponent(files[target]!.source), to: new)
                guard try Self.digest(new) == files[target]!.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            }
            for (index, target) in delta.enumerated() {
                try renameFile(stage.appendingPathComponent("new-\(index)"), prefix.appendingPathComponent(target))
                committed.append(target)
                guard try Self.digest(prefix.appendingPathComponent(target)) == files[target]!.sha256 else {
                    throw CocoaError(.fileReadCorruptFile)
                }
            }
        } catch {
            for target in committed.reversed() {
                let index = delta.firstIndex(of: target)!
                do {
                    try renameFile(stage.appendingPathComponent("old-\(index)"), prefix.appendingPathComponent(target))
                    if try Self.digest(prefix.appendingPathComponent(target)) != previous.files[target]!.sha256 { restored = false }
                } catch { restored = false }
            }
            if !restored { throw CocoaError(.fileWriteUnknown) }
            throw error
        }
    }
}
