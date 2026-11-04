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
        if case .delta(let list) = try deltaDecision(from: previous, prefix: prefix) { return list }
        return nil
    }

    /// Outcome of the fast-route decision. A refusal always carries the reason that goes to the log.
    enum Decision: Equatable {
        case delta([String])
        case refuse(String)
    }

    /// Default (class rule OFF): exactly the r9 rule. Class rule ON
    /// (`MACRUNNER_BOTTLE_FAST_CLASSES=1`, 1.1.0 candidate): file classes R/B/O, a prefix
    /// environment allow-list, and one-time adoption of a legacy bottle (no receipt) by SHA-256 of
    /// every target against the trusted previous catalogue.
    func deltaDecision(from previous: Self, prefix: URL, package: URL? = nil,
                       classRule: Bool = false, trustedLegacy: Bool = false,
                       normalisation: Normalisation = .refuse) throws -> Decision {
        guard schema == 1, previous.schema == 1 else { return .refuse("catalogue schema") }
        guard engineRoot == previous.engineRoot else { return .refuse("engine root changed") }
        guard layers == previous.layers else { return .refuse("default graphics layers changed") }
        if classRule {
            if let reason = classRefusal(from: previous, package: package) { return .refuse(reason) }
        } else if inputs != previous.inputs {
            return .refuse("inputs differ (rule r9)")
        }
        guard Set(files.keys) == Set(previous.files.keys) else { return .refuse("set of copied targets changed") }
        let root = prefix.resolvingSymlinksInPath().standardizedFileURL.path
        // A bottle that never went through `wineboot -u` still holds the package path of shell32.dll in
        // system.reg. `.refuse` keeps r10 behaviour (full route once); `.text` and `.regsvr32` let the fast
        // route repair that one group itself (BottleSetup does it after the files are in place).
        if classRule, normalisation == .refuse,
           let reason = Self.unnormalisedRegistration(prefix: prefix, engineRoot: engineRoot) {
            return .refuse(reason)
        }
        var receipt = previous.ownership
        if receipt == nil {
            guard classRule, trustedLegacy else { return .refuse("no installation receipt (legacy bottle)") }
            switch previous.adoptingLegacy(prefix: prefix) {
            case .success(let adopted): receipt = adopted
            case .failure(let failure): return .refuse("legacy bottle not adopted: \(failure.reason)")
            }
        }
        guard let ownership = receipt else { return .refuse("no installation receipt") }
        guard ownership.prefixRoot == root else { return .refuse("prefix moved since receipt") }
        guard Set(ownership.files.keys) == Set(previous.files.keys) else { return .refuse("receipt incomplete") }
        let fm = FileManager.default
        for forbidden in ["system32/ntdll.dll", "syswow64/ntdll.dll"] {
            let path = prefix.appendingPathComponent("drive_c/windows/\(forbidden)").path
            if fm.fileExists(atPath: path) || (try? fm.destinationOfSymbolicLink(atPath: path)) != nil {
                return .refuse("ntdll copy present in prefix")
            }
        }
        guard let actual = try? previous.identities(prefix: prefix) else { return .refuse("installed target unreadable or not regular") }
        guard actual == ownership.files else {
            let moved = ownership.files.keys.filter { actual[$0] != ownership.files[$0] }.sorted()
            return .refuse("installed target changed since receipt: \(moved.first ?? "?") (+\(max(0, moved.count - 1)))")
        }
        return .delta(files.keys.filter { files[$0] != previous.files[$0] }.sorted())
    }

    // MARK: - Fast route switch (1.1.0: ON by default)

    /// The fast route is ON unless `MACRUNNER_BOTTLE_FAST_CLASSES=0`. Any other value, or none, leaves it on
    /// (`=1` is the 1.1.0-candidate spelling and keeps working). Switched off, the update takes the full route and
    /// the log says why. ON does not weaken anything: the route is still closed unless the pair file of the release
    /// carries a valid record for exactly this (from, to) engine pair.
    static func fastRouteEnabled(_ environment: [String: String]) -> Bool {
        environment["MACRUNNER_BOTTLE_FAST_CLASSES"] != "0"
    }

    static var classRuleEnabled: Bool { fastRouteEnabled(ProcessInfo.processInfo.environment) }

    /// R: forms the content of the bottle during `wineboot -u` (wine.inf, share/wine data, the modules
    /// wine.inf registers, images the INF run starts). B: runtime base (changes how processes behave,
    /// not what the INF writes; proven per release by the full-vs-fast pair). O: everything else.
    enum FileClass: String { case registration = "R", runtimeBase = "B", other = "O" }

    static let executorModules: Set<String> = [
        "rundll32.exe", "setupapi.dll", "wineboot.exe", "regsvr32.exe", "services.exe", "rpcss.exe",
        "winedevice.exe", "mountmgr.sys", "plugplay.exe", "svchost.exe",
        "advapi32.dll", "kernel32.dll", "ole32.dll", "oleaut32.dll", "rpcrt4.dll",
        // Shared registrar implementations, including the dynamically loaded
        // ATL resource registrar (winecrt0/register.c). Changes require enrollment.
        "mfplat.dll", "msdmo.dll", "atl100.dll", "combase.dll",
    ]
    static let baseModules: Set<String> = [
        "kernelbase.dll", "user32.dll", "ntdll.dll", "ntdll.so", "win32u.dll", "gdi32.dll",
        "wineserver", "wine", "xtajit.dll", "xtajit64.dll", "xtajit.so", "xtajit64.so",
        "wow64.dll", "wow64cpu.dll", "wow64win.dll", "libwow64fex.so", "libarm64ecfex.so",
    ]

    /// Names in `[RegisterDllsSection]` of wine.inf: `N,,module,flags`.
    static func registeredModules(infText: String) -> Set<String> {
        var result = Set<String>(), inSection = false
        for line in infText.components(separatedBy: .newlines) {
            if line.hasPrefix("[") { inSection = line.hasPrefix("[RegisterDllsSection"); continue }
            guard inSection else { continue }
            let fields = line.split(separator: ",", omittingEmptySubsequences: false)
            if fields.count >= 3, Int(fields[0].trimmingCharacters(in: .whitespaces)) != nil, fields[1].isEmpty {
                result.insert(fields[2].trimmingCharacters(in: .whitespaces))
            }
        }
        return result
    }

    static func fileClass(_ key: String, registered: Set<String>) -> FileClass {
        let name = key.split(separator: "/").last.map(String.init) ?? key
        if key.hasPrefix("wine/share/wine/") { return .registration }
        if registered.contains(name) || executorModules.contains(name) { return .registration }
        if baseModules.contains(name) || key.hasPrefix("wine/bin/") || key.hasPrefix("wine/lib/wine/aarch64-unix/") {
            return .runtimeBase
        }
        return .other
    }

    /// Environment keys that can change what the update writes into the prefix. Everything else
    /// (HB_/FEX_/VM_/SERVER_/WINCTX_/SETCTX_... runtime knobs) is ignored. Allow-list: a new knob
    /// is runtime by default, and the full-vs-fast pair of the release is what proves that.
    static func prefixEnvironment(_ environment: [String: String]) -> [String: String] {
        let exact: Set<String> = ["MACRUNNER_GRAPHICS_BACKEND", "MACRUNNER_DXMT_ROOT",
                                  "MACRUNNER_WINE_BIN", "MACRUNNER_WINE_DIST"]
        return environment.filter { $0.key.hasPrefix("WINE") || exact.contains($0.key) }
    }

    private func manifestSections() -> (files: [String: String], environment: [String: String])? {
        guard let manifest, let object = try? JSONSerialization.jsonObject(with: manifest) as? [String: Any],
              let declared = object["files"] as? [String: String],
              let environment = object["environment"] as? [String: String] else { return nil }
        return (declared, environment)
    }

    /// Unlike installation identity, this attests a completed INF pass AFTER
    /// both architecture module sets were staged, followed by native WIC.
    /// Runtime-only engine changes do not invalidate those registrations.
    struct RegistrationReceipt: Codable, Equatable {
        let schema: Int
        let engineRoot: String
        let inputs: String
    }

    func registrationReceipt(package: URL) throws -> RegistrationReceipt? {
        guard let sections = manifestSections(),
              let inf = try? String(contentsOf: package.appendingPathComponent("wine/share/wine/wine.inf"),
                                    encoding: .utf8) else { return nil }
        let registered = Self.registeredModules(infText: inf)
        let registrationFiles = sections.files.filter {
            ($0.key.hasPrefix("wine/") || $0.key.hasPrefix("graphics/"))
                && !$0.key.hasSuffix(".a") && Self.fileClass($0.key, registered: registered) == .registration
        }
        let value: [String: Any] = ["files": registrationFiles,
            "environment": Self.prefixEnvironment(sections.environment), "layers": layers,
            "graphics": inputs["@graphics"] ?? ""]
        let data = try JSONSerialization.data(withJSONObject: value, options: .sortedKeys)
        // v2 requires observed successful DLL callbacks and EXE exit codes in
        // both views. A wineboot exit code (v1 draft) cannot certify this.
        // v3 also binds shared MFT/DMO/ATL registration providers. A v2 receipt
        // does not attest those inputs and is enrolled once before selective use.
        return RegistrationReceipt(schema: 3, engineRoot: engineRoot, inputs: Self.digest(data))
    }

    /// Source-audited, disjoint CLSID/MFT registrations. Provider changes remain
    /// a full-route decision; the exact release-pair gate is still mandatory.
    static let independentRegistrars: Set<String> = ["mfh264enc.dll", "msauddecmft.dll", "msvproc.dll"]

    private static func selectiveRegistrationSource(_ key: String) -> Bool {
        let parts = key.split(separator: "/").map(String.init)
        return parts.count == 5 && Array(parts.prefix(3)) == ["wine", "lib", "wine"]
            && ["aarch64-windows", "i386-windows"].contains(parts[3])
            && independentRegistrars.contains(parts[4])
    }

    /// Original INF rows in their original order, selected by the actual staged
    /// destination/view. An unused package copy must not register another view.
    func registrationSelection(from previous: Self, package: URL) throws -> [String: [String]]? {
        guard classRefusal(from: previous, package: package) == nil else { return nil }
        let text = try String(contentsOf: package.appendingPathComponent("wine/share/wine/wine.inf"), encoding: .utf8)
        var rows: [(String, String)] = [], inSection = false, seen = Set<String>()
        for raw in text.components(separatedBy: .newlines) {
            let line = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.hasPrefix("[") { inSection = line == "[RegisterDllsSection]"; continue }
            guard inSection, !line.isEmpty, !line.hasPrefix(";") else { continue }
            let fields = line.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) }
            guard fields.count >= 4 else { return nil }
            guard Self.independentRegistrars.contains(fields[2]) else { continue }
            guard fields.count == 4, fields[0] == "11", fields[1].isEmpty, fields[3] == "1",
                  seen.insert(fields[2]).inserted else { return nil }
            rows.append((fields[2], line))
        }
        var selected: [String: [String]] = [:]
        for (view, directory) in [("native", "system32"), ("32", "syswow64")] {
            let changed = files.keys.filter { $0.hasPrefix("drive_c/windows/\(directory)/") && files[$0] != previous.files[$0]
                && Self.independentRegistrars.contains(URL(fileURLWithPath: $0).lastPathComponent) }
            let names = Set(changed.map { URL(fileURLWithPath: $0).lastPathComponent })
            guard names.isSubset(of: seen) else { return nil }
            selected[view] = rows.filter { names.contains($0.0) }.map { $0.1 }
        }
        return selected
    }

    /// nil = the class rule allows the route; otherwise the reason it does not.
    func classRefusal(from previous: Self, package: URL?) -> String? {
        guard let now = manifestSections(), let before = previous.manifestSections() else {
            return "release inventory unavailable"
        }
        guard let package, let inf = try? String(contentsOf: package.appendingPathComponent("wine/share/wine/wine.inf"),
                                                  encoding: .utf8) else { return "wine.inf unreadable" }
        let registered = Self.registeredModules(infText: inf)
        let relevant: (String) -> Bool = { ($0.hasPrefix("wine/") || $0.hasPrefix("graphics/")) && !$0.hasSuffix(".a") }
        let changed = Set(now.files.keys).union(before.files.keys)
            .filter { relevant($0) && now.files[$0] != before.files[$0] }.sorted()
        if let hit = changed.first(where: { Self.fileClass($0, registered: registered) == .registration
            && (!Self.selectiveRegistrationSource($0) || now.files[$0] == nil || before.files[$0] == nil) }) {
            return "class R changed: \(hit)"
        }
        // Do not infer independence for an unrelated simultaneous provider
        // replacement, including runtime implementations of registry APIs.
        if changed.contains(where: Self.selectiveRegistrationSource),
           let hit = Set(now.files.keys).union(before.files.keys).sorted().first(where: {
               now.files[$0] != before.files[$0] && !Self.selectiveRegistrationSource($0)
           }) {
            return "unreviewed companion to selective registration: \(hit)"
        }
        let envNow = Self.prefixEnvironment(now.environment), envBefore = Self.prefixEnvironment(before.environment)
        if envNow != envBefore {
            let keys = Set(envNow.keys).union(envBefore.keys).filter { envNow[$0] != envBefore[$0] }.sorted()
            return "prefix environment changed: \(keys.joined(separator: ","))"
        }
        if inputs["@graphics"] != previous.inputs["@graphics"] { return "graphics layer definitions changed" }
        return nil
    }

    /// `wineboot -u` rewrites the registration of shell32.dll from the package path (what a bottle that
    /// never went through an update holds: the first INF ran while system32 still had placeholders) to
    /// `C:\windows\system32\shell32.dll`. Measured on the 1.0.9 -> 1.1.0 c12 pair (BOTTLE-UPDATE
    /// 14.10.2026): 76 system.reg values, nothing else outside generated ids. A fast update that skips
    /// `-u` would leave them behind, so such a bottle takes the full route once.
    /// nil = nothing to normalise; otherwise the reason.
    static func unnormalisedRegistration(systemRegistry: String, engineRoot: String) -> String? {
        let escaped = "Z:" + engineRoot.replacingOccurrences(of: "/", with: "\\\\")
        for line in systemRegistry.split(separator: "\n", omittingEmptySubsequences: true)
        where line.contains("shell32.dll") && line.contains(escaped) {
            return "registry still holds the package path of shell32.dll (bottle has not been through wineboot -u)"
        }
        return nil
    }

    static func unnormalisedRegistration(prefix: URL, engineRoot: String) -> String? {
        guard let data = try? Data(contentsOf: prefix.appendingPathComponent("system.reg"), options: .mappedIfSafe),
              let text = String(data: data, encoding: .utf8) else { return "system.reg unreadable" }
        return unnormalisedRegistration(systemRegistry: text, engineRoot: engineRoot)
    }

    /// How the fast route treats the shell32 registration of a bottle that never went through `wineboot -u`.
    /// `MACRUNNER_BOTTLE_FAST_NORMALISE`: unset/`text` = rewrite the one group in system.reg (no Wine);
    /// `refuse` = r10 (full route once); `regsvr32` = register shell32.dll with Wine (reference arm).
    enum Normalisation: String {
        case refuse, text, regsvr32
        static var current: Normalisation {
            Normalisation(rawValue: ProcessInfo.processInfo.environment["MACRUNNER_BOTTLE_FAST_NORMALISE"] ?? "text") ?? .refuse
        }
    }

    struct NormalisationFailure: Error { let reason: String }

    /// The text `wineboot -u` leaves in system.reg for shell32.dll: every value that names the package copy
    /// (`Z:\\<engine root>\\wine\\lib\\wine\\{aarch64,i386}-windows\\shell32.dll`, with or without a `,-N` resource
    /// suffix) names `C:\\windows\\system32\\shell32.dll` instead (measured: 76 values, nothing else outside generated ids).
    /// nil when there is nothing to rewrite. Throws when, after the rewrite, ANY package-path mention of shell32.dll is left
    /// (a value of a shape this rule does not know is never guessed at).
    static func normalisedRegistry(_ text: String, engineRoot: String) throws -> (text: String, replaced: Int)? {
        let escapedRoot = "Z:" + engineRoot.replacingOccurrences(of: "/", with: "\\\\")
        let sep = "\\\\"
        let target = "C:" + sep + "windows" + sep + "system32" + sep + "shell32.dll"
        var result = text, replaced = 0
        for arch in ["aarch64-windows", "i386-windows"] {
            let needle = escapedRoot + sep + "wine" + sep + "lib" + sep + "wine" + sep + arch + sep + "shell32.dll"
            let count = result.components(separatedBy: needle).count - 1
            if count > 0 { result = result.replacingOccurrences(of: needle, with: target); replaced += count }
        }
        if replaced == 0 { return nil }
        if let leftover = unnormalisedRegistration(systemRegistry: result, engineRoot: engineRoot) {
            throw NormalisationFailure(reason: "shell32.dll value of an unknown shape remains (\(leftover))")
        }
        return (result, replaced)
    }

    /// Rewrites system.reg of a STOPPED bottle: new file next to it, then rename over it (same mode).
    /// Returns the number of values rewritten (0 = nothing to do).
    static func normaliseRegistry(prefix: URL, engineRoot: String) throws -> Int {
        let file = prefix.appendingPathComponent("system.reg")
        let data = try Data(contentsOf: file)
        guard let text = String(data: data, encoding: .utf8) else { throw NormalisationFailure(reason: "system.reg is not UTF-8") }
        guard let (updated, replaced) = try normalisedRegistry(text, engineRoot: engineRoot) else { return 0 }
        var info = stat()
        guard stat(file.path, &info) == 0 else { throw NormalisationFailure(reason: "system.reg unreadable") }
        let temporary = prefix.appendingPathComponent("system.reg.macrunner-new")
        try Data(updated.utf8).write(to: temporary, options: [])
        guard chmod(temporary.path, info.st_mode & 0o7777) == 0,
              rename(temporary.path, file.path) == 0 else {
            try? FileManager.default.removeItem(at: temporary)
            throw NormalisationFailure(reason: "system.reg replacement failed (errno \(errno))")
        }
        return replaced
    }

    // MARK: - Engine pairs approved by the release gate (closed by default)

    /// Gate/test switches. NO environment variable and no setting reads them: only the acceptance driver in the
    /// test target can set them, so a shipped app cannot be talked out of the pair file.
    static var pairFileOverride: URL? = nil
    static var pairGateMode = false
    /// Gate mode only (no record is in force there): the previous release's corrections that the gate measured.
    static var pairGateActual: [String: String] = [:]

    /// One engine pair that the release gate has proven: the fast route from engine `from` to engine `to` (both are
    /// ENGINE.json stamps) gives a bottle equal to the full route's in content, registry (minus generated ids) and
    /// permission bits, on a fresh bottle, on one that went through an update, and on one made by the app.
    /// `modes` are the permission bits that the full route leaves on package copies. `wineboot -u` re-creates the
    /// modules its own processes have mapped through a delayed rename of a temporary file, which Wine creates 0644
    /// whatever the package mode was; which modules those are depends on dynamic loading in the INF processes, so the
    /// gate measures them (full result against fast result) and the fast route sets exactly those modes.
    ///
    /// `fromActual` (usually empty): package files of the PREVIOUS release whose bytes differ from what its ENGINE.json
    /// declares (key = ENGINE.json `files` key, value = SHA-256 of the bytes the old app really copied into bottles).
    /// The gate measures it from the old package itself; the old release cannot be rebuilt, so its inventory is corrected
    /// here, inside the digest, and only for the adoption of legacy bottles. A record without the field behaves as before.
    struct PairRecord: Equatable {
        let from: String
        let to: String
        let modes: [String: mode_t]
        var fromActual: [String: String] = [:]

        /// Text that the digest covers (the same lines are produced by the gate): sorted, no JSON canonicalisation.
        /// Corrections follow the modes as `~<key>=<sha256>` lines; none = the text of an uncorrected record, unchanged.
        static func digestText(from: String, to: String, modes: [String: String], fromActual: [String: String] = [:]) -> String {
            var text = "from=\(from)\nto=\(to)\n"
            for key in modes.keys.sorted() { text += "\(key)=\(modes[key]!)\n" }
            for key in fromActual.keys.sorted() { text += "~\(key)=\(fromActual[key]!)\n" }
            return text
        }
    }

    enum PairLookup: Equatable {
        case approved(PairRecord)
        case refused(String)
    }

    /// The only way the fast route learns that a pair is allowed. Absent file, damaged file, no record for exactly
    /// this (from, to), two records, a record whose digest does not match, a mode that is not octal or a path that
    /// escapes the bottle: all refuse, with the reason that goes to the log.
    static func pairLookup(file: Data?, from: String, to: String) -> PairLookup {
        guard let file else { return .refused("this release carries no engine-pair file") }
        guard let object = try? JSONSerialization.jsonObject(with: file) as? [String: Any],
              object["schema"] as? Int == 1, let pairs = object["pairs"] as? [[String: Any]] else {
            return .refused("engine-pair file damaged")
        }
        let matching = pairs.filter { $0["from"] as? String == from && $0["to"] as? String == to }
        guard !matching.isEmpty else {
            return .refused("engine pair \(from.prefix(8)) -> \(to.prefix(8)) was not approved by the release gate")
        }
        guard matching.count == 1, let record = matching.first else {
            return .refused("engine pair \(from.prefix(8)) -> \(to.prefix(8)) has more than one record")
        }
        var actual: [String: String] = [:]
        if let raw = record["fromActual"] {
            guard let value = raw as? [String: String] else { return .refused("engine-pair record damaged (correction)") }
            actual = value
        }
        guard let digest = record["digest"] as? String, let modes = record["modes"] as? [String: String],
              digest == Self.digest(Data(PairRecord.digestText(from: from, to: to, modes: modes, fromActual: actual).utf8)) else {
            return .refused("engine-pair record damaged (digest)")
        }
        for (key, value) in actual {
            guard safePath(key), value.range(of: #"^[0-9a-f]{64}$"#, options: .regularExpression) != nil else {
                return .refused("engine-pair record damaged (correction)")
            }
        }
        var parsed: [String: mode_t] = [:]
        for (target, text) in modes {
            guard safePath(target), let value = mode_t(text, radix: 8), value <= 0o7777 else {
                return .refused("engine-pair record damaged (mode or path)")
            }
            parsed[target] = value
        }
        return .approved(PairRecord(from: from, to: to, modes: parsed, fromActual: actual))
    }

    /// The previous catalogue with the real bytes of the package files that its inventory misdescribes. Targets are
    /// matched by their package `source`; everything else (including the manifest bytes that authenticate the stamp) stays.
    func correcting(_ actual: [String: String]) -> Self {
        guard !actual.isEmpty else { return self }
        var corrected = files
        for (target, file) in files {
            if let sha = actual[file.source] { corrected[target] = File(source: file.source, sha256: sha) }
        }
        return Self(schema: schema, engine: engine, engineRoot: engineRoot, layers: layers, inputs: inputs,
                    files: corrected, manifest: manifest, ownership: ownership)
    }

    /// Sets the overridden modes; returns the targets changed. A target that is missing is an error.
    @discardableResult
    func applyModes(_ overrides: [String: mode_t], prefix: URL) throws -> [String] {
        var changed: [String] = []
        for target in overrides.keys.sorted() where files[target] != nil {
            let url = prefix.appendingPathComponent(target)
            var info = stat()
            guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else { throw CocoaError(.fileNoSuchFile) }
            let want = overrides[target]!
            if info.st_mode & 0o7777 == want { continue }
            guard chmod(url.path, want) == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
            changed.append(target)
        }
        return changed
    }

    struct AdoptionFailure: Error { let reason: String }

    /// One-time receipt for a bottle made by a release that did not write one (1.0.9). Trust is
    /// SHA-256 of every target against THIS (trusted, bundled) catalogue, measured around a stat
    /// identity read, so the receipt describes exactly the bytes that were hashed.
    func adoptingLegacy(prefix: URL) -> Result<Ownership, AdoptionFailure> {
        do {
            let before = try identities(prefix: prefix)
            let root = prefix.resolvingSymlinksInPath().standardizedFileURL
            let targets = files.keys.sorted()
            // Pure reads: spread the 600 MB of hashing over the cores. Results land by index, so the
            // outcome (and the first reported mismatch) does not depend on scheduling.
            var digests = [String?](repeating: nil, count: targets.count)
            let lock = NSLock()
            DispatchQueue.concurrentPerform(iterations: targets.count) { index in
                let value = try? Self.digest(root.appendingPathComponent(targets[index]))
                lock.lock(); digests[index] = value; lock.unlock()
            }
            for (index, target) in targets.enumerated() {
                guard let actual = digests[index] else { return .failure(.init(reason: "\(target) unreadable")) }
                guard actual == files[target]!.sha256 else {
                    return .failure(.init(reason: "\(target) differs from the previous release"))
                }
            }
            guard try identities(prefix: prefix) == before else { return .failure(.init(reason: "target changed while verified")) }
            return .success(Ownership(prefixRoot: root.path, files: before))
        } catch {
            return .failure(.init(reason: "target unreadable (\(type(of: error)))"))
        }
    }

    /// Only Wine may have changed these targets: the caller verified ownership
    /// before setup and drained its own server afterwards. Preserve unchanged
    /// files by identity; verify and restore only setup's additions/replacements.
    /// This must never be used to adopt a foreign or unverified bottle.
    func repairSetupChanges(from before: Self, prefix: URL, package: URL) throws -> [String] {
        guard before.engine == engine, before.files == files,
              let ownership = before.ownership,
              ownership.prefixRoot == prefix.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw CocoaError(.fileReadCorruptFile)
        }
        let fm = FileManager.default
        var repaired: [String] = []
        for target in files.keys.sorted() {
            let destination = prefix.appendingPathComponent(target)
            if let identity = try? Identity.read(destination), identity == ownership.files[target] { continue }
            let file = files[target]!
            if (try? Self.digest(destination)) == file.sha256 { continue }
            let source = package.appendingPathComponent(file.source)
            guard try Self.digest(source) == file.sha256 else { throw CocoaError(.fileReadCorruptFile) }
            let staged = destination.deletingLastPathComponent().appendingPathComponent(".macrunner-repair-\(UUID().uuidString)")
            try fm.copyItem(at: source, to: staged)
            defer { try? fm.removeItem(at: staged) }
            guard try Self.digest(staged) == file.sha256,
                  rename(staged.path, destination.path) == 0 else { throw CocoaError(.fileWriteUnknown) }
            repaired.append(target)
        }
        return repaired
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
