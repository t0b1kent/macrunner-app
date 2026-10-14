import CryptoKit
import Darwin
import Foundation

/// A cache of a stopped, newly created prefix, never an installed user's bottle.
/// The manifest binds Wine, graphics and prefix format; physical installation paths
/// are deliberately absent from the key and are rebound before any Wine command.
enum BottleTemplate {
    static let schema = 1
    static let receiptName = ".macrunner-template.json"
    static let localVerificationName = ".macrunner-template.local.json"
    static let hives = ["system.reg", "user.reg", "userdef.reg"]
    enum Failure: Error { case invalidTemplate, invalidInventory, unresolvedPath, invalidMachineGuid, unsafeLink, interruptedClone, invalidBootstrap }

    struct Receipt: Codable {
        let schema: Int
        let generation: String
        let layers: [String]
        let codec: String
        let hashes: [String: String]
    }
    private struct LocalVerification: Codable {
        let receiptDigest: String
        let metadata: [String: [Int64]]
    }

    /// Local kernel identities are deliberately not portable. A moved/imported
    /// file, byte change, mtime restoration or replacement invalidates this fast
    /// path through inode/ctime. Full SHA is then required once, before reuse.
    static func metadata(_ root: URL) throws -> [String: [Int64]] {
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            throw Failure.invalidTemplate
        }
        var output: [String: [Int64]] = [:]
        for case let file as URL in walker {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if [receiptName, localVerificationName].contains(relative) { continue }
            var info = stat()
            guard lstat(file.path, &info) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
            let type = info.st_mode & mode_t(S_IFMT)
            if type == mode_t(S_IFREG) || type == mode_t(S_IFLNK) {
                output[relative] = [Int64(info.st_dev), Int64(info.st_ino), Int64(info.st_mode), info.st_size,
                    Int64(info.st_mtimespec.tv_sec), Int64(info.st_mtimespec.tv_nsec),
                    Int64(info.st_ctimespec.tv_sec), Int64(info.st_ctimespec.tv_nsec)]
            }
        }
        return output
    }

    private static func recordVerification(_ root: URL, receiptBytes: Data) throws {
        let record = LocalVerification(receiptDigest: digest(receiptBytes), metadata: try metadata(root))
        try JSONEncoder().encode(record).write(to: root.appendingPathComponent(localVerificationName), options: .atomic)
    }

    static func digest(_ bytes: Data) -> String {
        SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
    }

    static func generation(manifest: Data) -> String {
        digest(Data("MacRunner-prefix-template-\(schema)\n".utf8) + manifest)
    }

    static func substitutions(engine: URL, prefix: URL, data: URL, home: String) -> [String: String] {
        ["@@MR_ENGINE@@": engine.path, "@@MR_PREFIX@@": prefix.path,
         "@@MR_DATA@@": data.path, "@@MR_HOME@@": home]
    }

    /// Wine registry strings escape Windows paths separately from Unix paths.
    static func relocate(_ text: String, values: [String: String], sealing: Bool) -> String {
        var output = text
        let pairs = values.sorted { $0.value.count == $1.value.count ? $0.key < $1.key : $0.value.count > $1.value.count }
        for (token, path) in pairs where path.hasPrefix("/") && path.count > 1 {
            let windows = "Z:" + path.replacingOccurrences(of: "/", with: "\\")
            let escaped = windows.replacingOccurrences(of: "\\", with: "\\\\")
            if sealing {
                output = output.replacingOccurrences(of: escaped, with: token + "_WIN")
                output = output.replacingOccurrences(of: path, with: token)
            } else {
                output = output.replacingOccurrences(of: token + "_WIN", with: escaped)
                output = output.replacingOccurrences(of: token, with: path)
            }
        }
        return output
    }

    static func inventory(_ root: URL) throws -> [String: String] {
        let fm = FileManager.default
        guard let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else {
            throw Failure.invalidTemplate
        }
        var hashes: [String: String] = [:]
        for case let file as URL in walker {
            let relative = String(file.path.dropFirst(root.path.count + 1))
            if [receiptName, localVerificationName].contains(relative) { continue }
            let flags = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if flags.isSymbolicLink == true {
                let target = try fm.destinationOfSymbolicLink(atPath: file.path)
                let standard = file.deletingLastPathComponent().appendingPathComponent(target).standardizedFileURL.path
                guard relative == "dosdevices/z:" && target == "/"
                    || (!target.hasPrefix("/") && standard.hasPrefix(root.path + "/")) else {
                    throw Failure.unsafeLink
                }
                hashes[relative] = "link:" + target
            } else if flags.isRegularFile == true {
                hashes[relative] = digest(try Data(contentsOf: file, options: .mappedIfSafe))
            }
        }
        return hashes
    }

    static func validate(_ root: URL, generation: String) throws -> Receipt {
        let bytes = try Data(contentsOf: root.appendingPathComponent(receiptName))
        let receipt = try JSONDecoder().decode(Receipt.self, from: bytes)
        guard receipt.schema == schema, receipt.generation == generation,
              hives.allSatisfy({ receipt.hashes[$0] != nil }),
              receipt.hashes["drive_c/windows/system32/windowscodecs.dll"] == receipt.codec else { throw Failure.invalidTemplate }
        if let local = try? JSONDecoder().decode(LocalVerification.self,
            from: Data(contentsOf: root.appendingPathComponent(localVerificationName))),
           local.receiptDigest == digest(bytes), Set(local.metadata.keys) == Set(receipt.hashes.keys),
           try metadata(root) == local.metadata { return receipt }
        guard try inventory(root) == receipt.hashes else { throw Failure.invalidInventory }
        try recordVerification(root, receiptBytes: bytes)
        return receipt
    }

    /// Remove host drive aliases and profile links; the current host boot recreates
    /// them. Keep the guest account selected by ProfileImagePath, not Unix passwd.
    static func seal(_ root: URL, generation: String, values: [String: String]) throws {
        let fm = FileManager.default
        let marker = root.appendingPathComponent(BottleSetup.markerName)
        guard let object = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any],
              let layers = object["layers"] as? [String],
              let wic = object["wicRegistration"] as? [String: String], let codec = wic["codec"] else {
            throw Failure.invalidTemplate
        }
        if let walker = fm.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let file as URL in walker {
                if try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                    let relative = String(file.path.dropFirst(root.path.count + 1))
                    let target = try fm.destinationOfSymbolicLink(atPath: file.path)
                    if relative.hasPrefix("dosdevices/") && !["dosdevices/c:", "dosdevices/z:"].contains(relative)
                        || target.hasPrefix("/") && relative != "dosdevices/z:" {
                        try fm.removeItem(at: file)
                    }
                }
            }
        }
        for name in hives {
            let file = root.appendingPathComponent(name)
            let text = try String(contentsOf: file, encoding: .utf8)
            try Data(relocate(text, values: values, sealing: true).utf8).write(to: file, options: .atomic)
        }
        try fm.removeItem(at: marker)
        let receipt = Receipt(schema: schema, generation: generation, layers: layers, codec: codec, hashes: try inventory(root))
        let bytes = try JSONEncoder().encode(receipt)
        try bytes.write(to: root.appendingPathComponent(receiptName), options: .atomic)
        try recordVerification(root, receiptBytes: bytes)
    }

    static func unseal(_ root: URL, receipt: Receipt, values: [String: String], engineStamp: String, engineRoot: String) throws {
        for name in hives {
            let file = root.appendingPathComponent(name)
            var text = relocate(try String(contentsOf: file, encoding: .utf8), values: values, sealing: false)
            guard !text.contains("@@MR_") else { throw Failure.unresolvedPath }
            if name == "system.reg" {
                let pattern = #"(?m)^"MachineGuid"="[^"\r\n]*""#
                let regex = try NSRegularExpression(pattern: pattern)
                let range = NSRange(text.startIndex..., in: text)
                guard regex.numberOfMatches(in: text, range: range) == 1 else { throw Failure.invalidMachineGuid }
                text = regex.stringByReplacingMatches(in: text, range: range,
                    withTemplate: "\"MachineGuid\"=\"\(UUID().uuidString.lowercased())\"")
            }
            try Data(text.utf8).write(to: file, options: .atomic)
        }
        let marker: [String: Any] = ["engine": engineStamp, "engineRoot": engineRoot, "layers": receipt.layers,
            "wicRegistration": ["engine": engineStamp, "engineRoot": engineRoot, "codec": receipt.codec],
            "templateGeneration": receipt.generation, "bootstrapPending": true]
        try JSONSerialization.data(withJSONObject: marker, options: [.sortedKeys]).write(
            to: root.appendingPathComponent(BottleSetup.markerName), options: .atomic)
        try FileManager.default.removeItem(at: root.appendingPathComponent(receiptName))
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(localVerificationName).path) {
            try FileManager.default.removeItem(at: root.appendingPathComponent(localVerificationName))
        }
    }

    /// Dependencies are closures so disk-full, interrupted-copy and failed-bootstrap
    /// controls execute the same transaction as the product without launching Wine.
    static func transaction(destination: URL, clone: (URL) throws -> Void,
                            prepare: (URL) throws -> Void, bootstrap: () throws -> Void,
                            stop: () throws -> Void, quarantine: (URL) throws -> Void,
                            onFailure: (Error) -> Void = { _ in }, fallback: () throws -> Void) throws -> Bool {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: destination.path) else { throw Failure.invalidTemplate }
        let staged = destination.deletingLastPathComponent().appendingPathComponent(".clone-\(UUID().uuidString)")
        var published = false
        do {
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            try clone(staged)
            try prepare(staged)
            // Publication is a single rename. Until bootstrap succeeds the marker
            // says pending and isReady must be false, including after an App crash.
            try fm.moveItem(at: staged, to: destination)
            published = true
            try bootstrap()
            let marker = destination.appendingPathComponent(BottleSetup.markerName)
            guard var object = try JSONSerialization.jsonObject(with: Data(contentsOf: marker)) as? [String: Any] else {
                throw Failure.invalidBootstrap
            }
            object.removeValue(forKey: "bootstrapPending")
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: marker, options: .atomic)
            return true
        } catch {
            onFailure(error)
            // Never remove or rename a namespace until owned stop/drain completed.
            if published { try stop(); try quarantine(destination) }
            if fm.fileExists(atPath: staged.path) { try quarantine(staged) }
            try fallback()
            return false
        }
    }
}
