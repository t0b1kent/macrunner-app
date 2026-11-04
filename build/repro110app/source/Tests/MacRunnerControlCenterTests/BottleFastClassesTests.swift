import Foundation
import Testing
@testable import MacRunnerControlCenter

/// BOTTLE-UPDATE 1.1.0 candidate: file classes R/B/O, prefix-environment allow-list, one-time adoption
/// of a legacy bottle, refusal reasons. Native fixtures only: no Wine, no application data root.
struct BottleFastClassesTests {
    private typealias C = BottleUpdateCatalogue

    private static let infText = """
    [version]
    signature="$CHICAGO$"

    [RegisterDllsSection]
    ;;some dlls have to be registered first
    11,,shell32.dll,1
    11,,windowscodecs.dll,1
    11,,urlmon.dll,1
    11,,mfh264enc.dll,1
    11,,msauddecmft.dll,1
    11,,msvproc.dll,1

    [Strings]
    x=y
    """

    private let targets: [String: String] = [  // prefix target -> package source
        "drive_c/windows/system32/windowscodecs.dll": "wine/lib/wine/aarch64-windows/windowscodecs.dll",
        "drive_c/windows/system32/kernelbase.dll": "wine/lib/wine/aarch64-windows/kernelbase.dll",
        "drive_c/windows/system32/d3d8.dll": "wine/lib/wine/aarch64-windows/d3d8.dll",
        "drive_c/windows/system32/setupapi.dll": "wine/lib/wine/aarch64-windows/setupapi.dll",
        "drive_c/windows/system32/mfh264enc.dll": "wine/lib/wine/aarch64-windows/mfh264enc.dll",
        "drive_c/windows/syswow64/mfh264enc.dll": "wine/lib/wine/i386-windows/mfh264enc.dll",
        "drive_c/windows/system32/msauddecmft.dll": "wine/lib/wine/aarch64-windows/msauddecmft.dll",
        "drive_c/windows/syswow64/msauddecmft.dll": "wine/lib/wine/i386-windows/msauddecmft.dll",
        "drive_c/windows/system32/msvproc.dll": "wine/lib/wine/aarch64-windows/msvproc.dll",
        "drive_c/windows/syswow64/msvproc.dll": "wine/lib/wine/i386-windows/msvproc.dll",
    ]

    private struct Fixture {
        let root: URL, package: URL, prefix: URL
        var old: C
        var next: C
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func manifest(_ files: [String: String], env: [String: String]) throws -> Data {
        let object: [String: Any] = ["files": files, "environment": env,
                                     "graphics": ["layers": [], "routes": []]]
        return try JSONSerialization.data(withJSONObject: object, options: .sortedKeys)
    }

    /// `change`: package-relative source -> new bytes (not given: unchanged).
    private func fixture(change: [String: String] = [:], env: [String: String] = ["WINEDEBUG": "-all"],
                         nextEnv: [String: String]? = nil, receipt: Bool = true,
                         registry: String = "WINE REGISTRY Version 2\n\n[Software\\\\Wine] 1\n\"x\"=\"y\"\n") throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bottle-classes-\(UUID().uuidString)")
        let package = root.appendingPathComponent("engine"), prefix = root.appendingPathComponent("prefix")
        var oldDeclared: [String: String] = [:], nextDeclared: [String: String] = [:]
        var oldFiles: [String: C.File] = [:], nextFiles: [String: C.File] = [:]
        func declare(_ source: String, old: String, new: String) {
            oldDeclared[source] = C.digest(Data(old.utf8)); nextDeclared[source] = C.digest(Data(new.utf8))
        }
        for (target, source) in targets {
            let before = "old-" + source, after = change[source] ?? before
            let destination = prefix.appendingPathComponent(target)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(before.utf8).write(to: destination)
            declare(source, old: before, new: after)
            oldFiles[target] = .init(source: source, sha256: oldDeclared[source]!)
            nextFiles[target] = .init(source: source, sha256: nextDeclared[source]!)
        }
        for extra in ["wine/lib/wine/aarch64-unix/ntdll.so", "wine/bin/wineserver", "wine/share/wine/wine.inf",
                      "fex/aarch64-windows/xtajit64.dll"] {
            declare(extra, old: "old-" + extra, new: change[extra] ?? "old-" + extra)
        }
        try Data(registry.utf8).write(to: prefix.appendingPathComponent("system.reg"))
        let inf = package.appendingPathComponent("wine/share/wine/wine.inf")
        try fm.createDirectory(at: inf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(Self.infText.utf8).write(to: inf)
        let inputs = ["@graphics": "same-layers"]
        var old = try C(schema: 1, engine: "old", engineRoot: package.path, layers: [], inputs: inputs, files: oldFiles,
                        manifest: manifest(oldDeclared, env: env))
        if receipt { old = try old.recordingInstallation(prefix: prefix) }
        let next = try C(schema: 1, engine: "new", engineRoot: package.path, layers: [], inputs: inputs, files: nextFiles,
                         manifest: manifest(nextDeclared, env: nextEnv ?? env))
        return Fixture(root: root, package: package, prefix: prefix, old: old, next: next)
    }

    private func decide(_ f: Fixture, classRule: Bool, trusted: Bool = false) throws -> C.Decision {
        try f.next.deltaDecision(from: f.old, prefix: f.prefix, package: f.package, classRule: classRule, trustedLegacy: trusted)
    }

    @Test func registeredModulesAreReadFromTheINF() {
        #expect(C.registeredModules(infText: Self.infText) == ["shell32.dll", "windowscodecs.dll", "urlmon.dll", "mfh264enc.dll", "msauddecmft.dll", "msvproc.dll"])
    }

    @Test(arguments: ["mfh264enc.dll", "msauddecmft.dll", "msvproc.dll"],
          [["aarch64-windows"], ["i386-windows"], ["aarch64-windows", "i386-windows"]])
    func independentRegistrarSelectsOnlyChangedViews(module: String, architectures: [String]) throws {
        let changes = Dictionary(uniqueKeysWithValues: architectures.map {
            ("wine/lib/wine/\($0)/\(module)", "updated-registrar")
        })
        let f = try fixture(change: changes); defer { f.remove() }
        guard case .delta(let delta) = try decide(f, classRule: true) else { Issue.record("selective update refused"); return }
        #expect(delta.count == architectures.count)
        let selected = try #require(try f.next.registrationSelection(from: f.old, package: f.package))
        #expect(selected["native"] == (architectures.contains("aarch64-windows") ? ["11,,\(module),1"] : []))
        #expect(selected["32"] == (architectures.contains("i386-windows") ? ["11,,\(module),1"] : []))
        #expect(try f.old.registrationReceipt(package: f.package) != f.next.registrationReceipt(package: f.package))
    }

    @Test(arguments: ["wine/lib/wine/aarch64-windows/kernelbase.dll", "wine/lib/wine/aarch64-windows/d3d8.dll"])
    func selectiveRegistrationRefusesUnreviewedCompanion(source: String) throws {
        let f = try fixture(change: ["wine/lib/wine/aarch64-windows/mfh264enc.dll": "new", source: "changed"])
        defer { f.remove() }
        guard case .refuse(let reason) = try decide(f, classRule: true) else { Issue.record("companion not refused"); return }
        #expect(reason == "unreviewed companion to selective registration: \(source)")
    }

    @Test func registrationProvidersAreExplicitInputs() {
        for name in ["mfplat.dll", "msdmo.dll", "atl100.dll", "combase.dll"] {
            #expect(C.fileClass("wine/lib/wine/aarch64-windows/\(name)", registered: []) == .registration)
        }
    }

    @Test func runtimeOnlyReplacementKeepsRegistrationReceipt() throws {
        let f = try fixture(change: ["fex/aarch64-windows/xtajit64.dll": "new-translator"],
                            nextEnv: ["WINEDEBUG": "-all", "MACRUNNER_FEX_LAZY_MXCSR": "2"])
        defer { f.remove() }
        let before = try #require(try f.old.registrationReceipt(package: f.package))
        let after = try #require(try f.next.registrationReceipt(package: f.package))
        #expect(before == after)
    }

    @Test(arguments: ["wine/share/wine/wine.inf", "wine/lib/wine/aarch64-windows/windowscodecs.dll",
                      "wine/lib/wine/aarch64-windows/setupapi.dll"])
    func registrationInputReplacementInvalidatesReceipt(source: String) throws {
        let f = try fixture(change: [source: "new-registration-input"])
        defer { f.remove() }
        let before = try #require(try f.old.registrationReceipt(package: f.package))
        let after = try #require(try f.next.registrationReceipt(package: f.package))
        #expect(before != after)
    }

    @Test func registrationReceiptTracksPrefixEnvironmentAndRequiresReadableINF() throws {
        let f = try fixture(nextEnv: ["WINEDEBUG": "-all", "WINEDLLOVERRIDES": "shell32=n,b"])
        defer { f.remove() }
        let before = try #require(try f.old.registrationReceipt(package: f.package))
        let after = try #require(try f.next.registrationReceipt(package: f.package))
        #expect(before != after)
        try FileManager.default.removeItem(at: f.package.appendingPathComponent("wine/share/wine/wine.inf"))
        #expect(try f.next.registrationReceipt(package: f.package) == nil)
    }

    @Test func classesFollowTheirDefinition() {
        let registered: Set<String> = ["windowscodecs.dll"]
        #expect(C.fileClass("wine/share/wine/wine.inf", registered: registered) == .registration)
        #expect(C.fileClass("wine/share/wine/nls/c_437.nls", registered: registered) == .registration)
        #expect(C.fileClass("wine/lib/wine/i386-windows/windowscodecs.dll", registered: registered) == .registration)
        #expect(C.fileClass("wine/lib/wine/aarch64-windows/setupapi.dll", registered: registered) == .registration)
        #expect(C.fileClass("wine/lib/wine/aarch64-windows/kernelbase.dll", registered: registered) == .runtimeBase)
        #expect(C.fileClass("wine/lib/wine/winctx-exact/i386-windows/ntdll.dll", registered: registered) == .runtimeBase)
        #expect(C.fileClass("wine/lib/wine/aarch64-unix/anything.so", registered: registered) == .runtimeBase)
        #expect(C.fileClass("wine/bin/wineserver", registered: registered) == .runtimeBase)
        #expect(C.fileClass("wine/lib/wine/aarch64-windows/d3d8.dll", registered: registered) == .other)
        #expect(C.fileClass("graphics/x86_64-windows/dxgi.dll", registered: registered) == .other)
    }

    @Test func r9RuleRefusesAnyWineChange_classRuleAllowsBaseAndOther() throws {
        let f = try fixture(change: ["wine/lib/wine/aarch64-windows/kernelbase.dll": "new-kernelbase",
                                     "wine/lib/wine/aarch64-windows/d3d8.dll": "new-d3d8",
                                     "wine/lib/wine/aarch64-unix/ntdll.so": "new-ntdll-so",
                                     "wine/bin/wineserver": "new-server"])
        defer { f.remove() }
        // r9 compares `inputs` (fixture inputs are equal, so give it the difference the real make() would see).
        var inputs = f.next.inputs; inputs["wine/bin/wineserver"] = "changed"
        let r9 = C(schema: 1, engine: f.next.engine, engineRoot: f.next.engineRoot, layers: [], inputs: inputs,
                   files: f.next.files, manifest: f.next.manifest)
        #expect(try r9.deltaDecision(from: f.old, prefix: f.prefix) == .refuse("inputs differ (rule r9)"))
        #expect(try decide(f, classRule: true) == .delta(["drive_c/windows/system32/d3d8.dll",
                                                         "drive_c/windows/system32/kernelbase.dll"]))
    }

    @Test(arguments: ["wine/share/wine/wine.inf", "wine/lib/wine/aarch64-windows/windowscodecs.dll",
                      "wine/lib/wine/aarch64-windows/setupapi.dll"])
    func changedRegistrationClassRefuses(source: String) throws {
        let f = try fixture(change: [source: "new-bytes"]); defer { f.remove() }
        guard case .refuse(let reason) = try decide(f, classRule: true) else { Issue.record("fast route not refused"); return }
        #expect(reason == "class R changed: \(source)")
    }

    @Test func prefixEnvironmentIsAnAllowList() throws {
        // runtime knobs (HB_/FEX_/VM_/SERVER_PRIORITY...) do not touch the prefix
        let base = ["WINEDEBUG": "-all", "MACRUNNER_GRAPHICS_BACKEND": "dxmt"]
        let runtime = base.merging(["MACRUNNER_VM_ARENA": "0", "MACRUNNER_SERVER_PRIORITY_MODE": "3",
                                    "MACRUNNER_FEX_DIV_FAST": "8", "MACRUNNER_WINCTX_EXACT": "0"]) { $1 }
        let f = try fixture(env: base, nextEnv: runtime); defer { f.remove() }
        #expect(try decide(f, classRule: true) == .delta([]))
        // The retired architecture marker has no setup/runtime reader in c14.
        let retired = base.merging(["MACRUNNER_PREFIX_SYSTEM32_ARCH": "x86_64-windows"]) { $1 }
        let h = try fixture(env: retired, nextEnv: base); defer { h.remove() }
        #expect(try decide(h, classRule: true) == .delta([]))
        // wine-visible keys do
        for (key, value) in [("WINEDLLOVERRIDES", "d3d9=b"), ("MACRUNNER_GRAPHICS_BACKEND", "wined3d")] {
            let g = try fixture(env: base, nextEnv: base.merging([key: value]) { $1 }); defer { g.remove() }
            guard case .refuse(let reason) = try decide(g, classRule: true) else { Issue.record("not refused: \(key)"); return }
            #expect(reason == "prefix environment changed: \(key)")
        }
    }

    @Test func legacyBottleIsAdoptedOnlyByTrustedCatalogueAndMatchingBytes() throws {
        let f = try fixture(change: ["wine/lib/wine/aarch64-windows/kernelbase.dll": "new-kernelbase"], receipt: false)
        defer { f.remove() }
        #expect(try decide(f, classRule: true, trusted: false) == .refuse("no installation receipt (legacy bottle)"))
        #expect(try decide(f, classRule: false, trusted: true) == .refuse("no installation receipt (legacy bottle)"))
        #expect(try decide(f, classRule: true, trusted: true) == .delta(["drive_c/windows/system32/kernelbase.dll"]))
    }

    @Test func legacyBottleWithForeignOrMissingTargetIsNotAdopted() throws {
        let f = try fixture(change: ["wine/lib/wine/aarch64-windows/kernelbase.dll": "new-kernelbase"], receipt: false)
        defer { f.remove() }
        let user = f.prefix.appendingPathComponent("drive_c/windows/system32/d3d8.dll")
        try Data("user-override".utf8).write(to: user)
        guard case .refuse(let reason) = try decide(f, classRule: true, trusted: true) else { Issue.record("adopted"); return }
        #expect(reason == "legacy bottle not adopted: drive_c/windows/system32/d3d8.dll differs from the previous release")
        try FileManager.default.removeItem(at: user)
        guard case .refuse(let missing) = try decide(f, classRule: true, trusted: true) else { Issue.record("adopted"); return }
        #expect(missing.hasPrefix("legacy bottle not adopted: target unreadable"))
    }

    @Test func changedTargetBytesBehindAValidReceiptStillRefuse() throws {
        let f = try fixture(change: ["wine/lib/wine/aarch64-windows/kernelbase.dll": "new-kernelbase"]); defer { f.remove() }
        try Data("tampered".utf8).write(to: f.prefix.appendingPathComponent("drive_c/windows/system32/d3d8.dll"))
        guard case .refuse(let reason) = try decide(f, classRule: true) else { Issue.record("not refused"); return }
        #expect(reason.hasPrefix("installed target changed since receipt: drive_c/windows/system32/d3d8.dll"))
    }

    @Test func theFastRouteIsOnUnlessSwitchedOffWithZero() {
        let key = "MACRUNNER_BOTTLE_FAST_CLASSES"
        #expect(C.fastRouteEnabled([:]) == true)                       // not set: ON (1.1.0 default)
        #expect(C.fastRouteEnabled([key: "1"]) == true)                // the candidate spelling keeps working
        #expect(C.fastRouteEnabled([key: "0"]) == false)               // the only way off
        for other in ["", "00", "off", "false", " 0", "2", "yes"] {
            #expect(C.fastRouteEnabled([key: other]) == true, "value \(other.debugDescription) must not switch the route off")
        }
        #expect(C.classRuleEnabled == C.fastRouteEnabled(ProcessInfo.processInfo.environment))
    }

    @Test func appliedClassDeltaMakesTheBottleEqualToThePackage() throws {
        let f = try fixture(change: ["wine/lib/wine/aarch64-windows/kernelbase.dll": "new-kernelbase",
                                     "wine/lib/wine/aarch64-windows/d3d8.dll": "new-d3d8"])
        defer { f.remove() }
        for (target, source) in targets {  // the package side of the fixture is a minimal engine tree
            let url = f.package.appendingPathComponent(source)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            let next = f.next.files[target]!.sha256
            let candidates = ["old-" + source, "new-kernelbase", "new-d3d8"]
            let text = try #require(candidates.first { C.digest(Data($0.utf8)) == next })
            try Data(text.utf8).write(to: url)
        }
        guard case .delta(let list) = try decide(f, classRule: true) else { Issue.record("refused"); return }
        try f.next.apply(list, from: f.old, prefix: f.prefix, package: f.package)
        for (target, file) in f.next.files {
            #expect(try C.digest(f.prefix.appendingPathComponent(target)) == file.sha256)
        }
    }

    @Test func updateTimestampIsComparedByNumberAndWrittenLikeWineboot() {
        #expect(BottleSetup.alignedTimestamp(existing: "1789035749\r\n", infMtime: 1789035749) == nil)
        #expect(BottleSetup.alignedTimestamp(existing: "1789035749\n", infMtime: 1789035749) == nil)
        #expect(BottleSetup.alignedTimestamp(existing: "1789035749\r\n", infMtime: 1789035750) == "1789035750\r\n")
        #expect(BottleSetup.alignedTimestamp(existing: "", infMtime: 5) == "5\r\n")
    }

    @Test func packagePathOfShell32MarksAnUnnormalisedBottle() {
        let root = "/fixture-mount/x/MacRunner.app/Contents/Resources/engine"
        let package = "Z:" + (root + "/wine/lib/wine/aarch64-windows/").replacingOccurrences(of: "/", with: "\\\\")
        let unnormalised = "[Software\\\\Classes\\\\CLSID\\\\{1}\\\\InprocServer32] 1\n@=\"\(package)shell32.dll\"\n"
        #expect(C.unnormalisedRegistration(systemRegistry: unnormalised, engineRoot: root) != nil)
        // other modules keep their package path in a normalised bottle (measured: quartz, mshtml, windowscodecs...)
        let others = "@=\"\(package)quartz.dll\"\n@=\"\(package)windowscodecs.dll\"\n"
        #expect(C.unnormalisedRegistration(systemRegistry: others, engineRoot: root) == nil)
        let updated = "@=\"C:\\\\windows\\\\system32\\\\shell32.dll\"\n"
        #expect(C.unnormalisedRegistration(systemRegistry: updated, engineRoot: root) == nil)
        // another engine root is not this bottle's package path
        #expect(C.unnormalisedRegistration(systemRegistry: unnormalised, engineRoot: "/Applications/MacRunner.app/Contents/Resources/engine") == nil)
    }

    @Test func fastRouteRefusesABottleThatNeverWentThroughUpdate() throws {
        let root = "/fixture-mount/x/MacRunner.app/Contents/Resources/engine"
        let package = "Z:" + (root + "/wine/lib/wine/aarch64-windows/").replacingOccurrences(of: "/", with: "\\\\")
        let line = "@=\"\(package)shell32.dll\"\n"
        let f = try fixture(registry: "WINE REGISTRY Version 2\n\n" + line)
        defer { f.remove() }
        let rooted = C(schema: 1, engine: f.next.engine, engineRoot: root, layers: [], inputs: f.next.inputs,
                       files: f.next.files, manifest: f.next.manifest)
        var old = f.old
        old = C(schema: 1, engine: old.engine, engineRoot: root, layers: [], inputs: old.inputs, files: old.files,
                manifest: old.manifest, ownership: old.ownership)
        guard case .refuse(let reason) = try rooted.deltaDecision(from: old, prefix: f.prefix, package: f.package, classRule: true) else {
            Issue.record("not refused"); return
        }
        #expect(reason.hasPrefix("registry still holds the package path of shell32.dll"))
    }

    private static let root = "/fixture-mount/x/MacRunner.app/Contents/Resources/engine"
    private static var package: String {
        "Z:" + (root + "/wine/lib/wine/").replacingOccurrences(of: "/", with: "\\\\")
    }

    @Test func shell32RegistrationIsRewrittenInBothArchitecturesAndOnlyThere() throws {
        let p = Self.package
        let text = "[A] 1\n@=\"\(p)aarch64-windows\\\\shell32.dll\"\n[B] 1\n\"LocalizedString\"=\"@\(p)i386-windows\\\\shell32.dll,-20\"\n"
            + "[C] 1\n@=\"\(p)aarch64-windows\\\\quartz.dll\"\n"
        let result = try #require(try C.normalisedRegistry(text, engineRoot: Self.root))
        #expect(result.replaced == 2)
        #expect(result.text.contains("@=\"C:\\\\windows\\\\system32\\\\shell32.dll\""))
        #expect(result.text.contains("\"@C:\\\\windows\\\\system32\\\\shell32.dll,-20\""))
        #expect(result.text.contains("\(p)aarch64-windows\\\\quartz.dll"))
        #expect(C.unnormalisedRegistration(systemRegistry: result.text, engineRoot: Self.root) == nil)
        #expect(try C.normalisedRegistry("[X] 1\n@=\"C:\\\\windows\\\\system32\\\\shell32.dll\"\n", engineRoot: Self.root) == nil)
    }

    @Test func aShell32ValueOfAnUnknownShapeIsNeverGuessedAt() {
        let p = Self.package
        // a package path that is not one of the two known directories
        let odd = "@=\"\(p)x86_64-windows\\\\shell32.dll\"\n"
        #expect(throws: C.NormalisationFailure.self) {
            _ = try C.normalisedRegistry(odd + "@=\"\(p)aarch64-windows\\\\shell32.dll\"\n", engineRoot: Self.root)
        }
    }

    @Test func registryRewriteGoesThroughANewFileAndKeepsMode() throws {
        let f = try fixture(registry: "WINE REGISTRY Version 2\n\n[A] 1\n@=\"\(Self.package)aarch64-windows\\\\shell32.dll\"\n")
        defer { f.remove() }
        let file = f.prefix.appendingPathComponent("system.reg")
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: file.path)
        let count = try C.normaliseRegistry(prefix: f.prefix, engineRoot: Self.root)
        #expect(count == 1)
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(text.contains("C:\\\\windows\\\\system32\\\\shell32.dll"))
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber)?.intValue == 0o640)
        #expect(!FileManager.default.fileExists(atPath: f.prefix.appendingPathComponent("system.reg.macrunner-new").path))
        #expect(try C.normaliseRegistry(prefix: f.prefix, engineRoot: Self.root) == 0)
    }

    @Test func normalisationStrategyDecidesWhetherAnUnnormalisedBottleMayGoFast() throws {
        let line = "@=\"\(Self.package)aarch64-windows\\\\shell32.dll\"\n"
        let f = try fixture(registry: "WINE REGISTRY Version 2\n\n" + line)
        defer { f.remove() }
        let rooted = C(schema: 1, engine: f.next.engine, engineRoot: Self.root, layers: [], inputs: f.next.inputs,
                       files: f.next.files, manifest: f.next.manifest)
        let old = C(schema: 1, engine: f.old.engine, engineRoot: Self.root, layers: [], inputs: f.old.inputs,
                    files: f.old.files, manifest: f.old.manifest, ownership: f.old.ownership)
        for strategy in [C.Normalisation.text, .regsvr32] {
            let decision = try rooted.deltaDecision(from: old, prefix: f.prefix, package: f.package, classRule: true, normalisation: strategy)
            #expect(decision == .delta([]), "\(strategy)")
        }
        guard case .refuse = try rooted.deltaDecision(from: old, prefix: f.prefix, package: f.package, classRule: true, normalisation: .refuse) else {
            Issue.record("refuse strategy did not refuse"); return
        }
    }

    // MARK: engine pairs approved by the release gate

    private static let from = String(repeating: "a", count: 64), to = String(repeating: "b", count: 64)

    private func pairFile(_ records: [[String: Any]], schema: Int = 1) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["schema": schema, "pairs": records], options: .sortedKeys)
    }

    private func record(from: String = from, to: String = to,
                        modes: [String: String] = ["drive_c/windows/system32/kernelbase.dll": "0644"],
                        digest: String? = nil) -> [String: Any] {
        let good = C.digest(Data(C.PairRecord.digestText(from: from, to: to, modes: modes).utf8))
        return ["from": from, "to": to, "modes": modes, "digest": digest ?? good]
    }

    @Test func anApprovedPairYieldsItsPermissionBits() throws {
        let data = try pairFile([record(from: String(repeating: "c", count: 64)), record()])
        guard case .approved(let found) = C.pairLookup(file: data, from: Self.from, to: Self.to) else {
            Issue.record("approved pair refused"); return
        }
        #expect(found.modes == ["drive_c/windows/system32/kernelbase.dll": 0o644])
    }

    @Test func aPairThatTheGateDidNotApproveIsRefusedWithItsReason() throws {
        let data = try pairFile([record()])
        for (from, to) in [(Self.to, Self.from), (Self.from, String(repeating: "d", count: 64)), (String(repeating: "e", count: 64), Self.to)] {
            guard case .refused(let reason) = C.pairLookup(file: data, from: from, to: to) else {
                Issue.record("unknown pair allowed"); return
            }
            #expect(reason.hasSuffix("was not approved by the release gate"))
        }
        // the engine fingerprint is part of the pair: the right `from` with another `to` is another pair
        #expect(C.pairLookup(file: try pairFile([]), from: Self.from, to: Self.to) == .refused("engine pair aaaaaaaa -> bbbbbbbb was not approved by the release gate"))
    }

    @Test func aMissingOrDamagedPairFileClosesTheRoute() throws {
        #expect(C.pairLookup(file: nil, from: Self.from, to: Self.to) == .refused("this release carries no engine-pair file"))
        for bad in [Data("not json".utf8), Data("[]".utf8), Data(#"{"schema":2,"pairs":[]}"#.utf8), Data(#"{"schema":1}"#.utf8)] {
            #expect(C.pairLookup(file: bad, from: Self.from, to: Self.to) == .refused("engine-pair file damaged"))
        }
    }

    @Test func aDamagedRecordIsNeverUsed() throws {
        let tampered = try pairFile([record(modes: ["drive_c/windows/system32/kernelbase.dll": "0755"],
                                            digest: C.digest(Data(C.PairRecord.digestText(from: Self.from, to: Self.to,
                                                modes: ["drive_c/windows/system32/kernelbase.dll": "0644"]).utf8)))])
        #expect(C.pairLookup(file: tampered, from: Self.from, to: Self.to) == .refused("engine-pair record damaged (digest)"))
        #expect(C.pairLookup(file: try pairFile([record(digest: "0")]), from: Self.from, to: Self.to) == .refused("engine-pair record damaged (digest)"))
        for modes in [["a/b": "zz"], ["../escape": "0644"], ["/abs": "0644"], ["a/b": "17777"]] {
            #expect(C.pairLookup(file: try pairFile([record(modes: modes)]), from: Self.from, to: Self.to)
                    == .refused("engine-pair record damaged (mode or path)"))
        }
        #expect(C.pairLookup(file: try pairFile([record(), record()]), from: Self.from, to: Self.to)
                == .refused("engine pair aaaaaaaa -> bbbbbbbb has more than one record"))
    }

    @Test func permissionBitsAreAppliedOnlyToTheirTargets() throws {
        let f = try fixture(change: ["wine/lib/wine/aarch64-windows/kernelbase.dll": "new-kernelbase"])
        defer { f.remove() }
        let target = "drive_c/windows/system32/kernelbase.dll", other = "drive_c/windows/system32/d3d8.dll"
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.prefix.appendingPathComponent(target).path)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.prefix.appendingPathComponent(other).path)
        let overrides: [String: mode_t] = [target: 0o644, "drive_c/windows/system32/absent.dll": 0o644]
        #expect(try f.next.applyModes(overrides, prefix: f.prefix) == [target])
        func mode(_ name: String) throws -> Int {
            (try FileManager.default.attributesOfItem(atPath: f.prefix.appendingPathComponent(name).path)[.posixPermissions] as? NSNumber)?.intValue ?? -1
        }
        #expect(try mode(target) == 0o644)
        #expect(try mode(other) == 0o755)
        #expect(try f.next.applyModes(overrides, prefix: f.prefix) == [])
    }

    @Test func theGateSwitchesAreNotReadFromTheEnvironment() {
        #expect(C.pairGateMode == false)
        #expect(C.pairFileOverride == nil)
        #expect(C.pairGateActual.isEmpty)
    }

    // MARK: - an old release whose ENGINE.json misdescribes one package file (1.0.8 r5: xtajit64.dll)

    private let misdescribed = "wine/lib/wine/aarch64-windows/kernelbase.dll"
    private let misdescribedTarget = "drive_c/windows/system32/kernelbase.dll"

    /// Legacy bottle (no receipt) in which the old app copied the package's REAL bytes, which are not the bytes the old
    /// inventory declares; `real` is what lies in the prefix.
    private func misdescribedFixture() throws -> (Fixture, real: String) {
        let f = try fixture(change: [misdescribed: "new-kernelbase"], receipt: false)
        let real = "real-kernelbase-bytes"
        try Data(real.utf8).write(to: f.prefix.appendingPathComponent(misdescribedTarget))
        return (f, real)
    }

    @Test func aLegacyBottleWithARealByteTheOldInventoryMisdescribesIsNotAdoptedWithoutTheCorrection() throws {
        let (f, _) = try misdescribedFixture(); defer { f.remove() }
        guard case .refuse(let reason) = try decide(f, classRule: true, trusted: true) else {
            Issue.record("adopted although the file differs from the old inventory"); return
        }
        #expect(reason.contains("legacy bottle not adopted") && reason.contains("kernelbase.dll"))
    }

    @Test func theCorrectionOfTheRecordMakesTheRealByteTheOldGenerationAndNothingElse() throws {
        let (f, real) = try misdescribedFixture(); defer { f.remove() }
        let corrected = f.old.correcting([misdescribed: C.digest(Data(real.utf8))])
        #expect(corrected.manifest == f.old.manifest && corrected.engine == f.old.engine)
        #expect(corrected.files[misdescribedTarget]?.sha256 == C.digest(Data(real.utf8)))
        for (target, file) in f.old.files where target != misdescribedTarget { #expect(corrected.files[target] == file) }
        let decision = try f.next.deltaDecision(from: corrected, prefix: f.prefix, package: f.package, classRule: true, trustedLegacy: true)
        #expect(decision == .delta([misdescribedTarget]))
        // the correction must be the real bytes: any other digest still refuses
        let wrong = f.old.correcting([misdescribed: C.digest(Data("other".utf8))])
        guard case .refuse = try f.next.deltaDecision(from: wrong, prefix: f.prefix, package: f.package, classRule: true, trustedLegacy: true) else {
            Issue.record("adopted with a wrong correction"); return
        }
        #expect(f.old.correcting([:]) == f.old)
    }

    @Test func aRecordWithCorrectionsVerifiesAndEveryChangeToThemBreaksTheDigest() throws {
        let sha = String(repeating: "ab", count: 32)
        let key = "wine/lib/wine/aarch64-windows/xtajit64.dll"
        func file(_ actual: [String: String], digestOf: [String: String]) throws -> Data {
            let modes = ["drive_c/windows/system32/xtajit64.dll": "0644"]
            let text = C.PairRecord.digestText(from: "f", to: "t", modes: modes, fromActual: digestOf)
            let record: [String: Any] = ["from": "f", "to": "t", "modes": modes, "fromActual": actual, "digest": C.digest(Data(text.utf8))]
            return try JSONSerialization.data(withJSONObject: ["schema": 1, "pairs": [record]])
        }
        guard case .approved(let record) = C.pairLookup(file: try file([key: sha], digestOf: [key: sha]), from: "f", to: "t") else {
            Issue.record("a record with a correction does not verify"); return
        }
        #expect(record.fromActual == [key: sha])
        // the digest covers the corrections: replaced value, added key, removed key
        for tampered in [[key: String(repeating: "cd", count: 32)], [key: sha, "x/y": sha], [:]] {
            #expect(C.pairLookup(file: try file(tampered, digestOf: [key: sha]), from: "f", to: "t") == .refused("engine-pair record damaged (digest)"))
        }
        // a correction that is not a digest or not a safe path is refused even when the digest was computed over it
        for bad in [[key: "not-a-digest"], ["../escape": sha], ["/abs": sha]] {
            #expect(C.pairLookup(file: try file(bad, digestOf: bad), from: "f", to: "t") == .refused("engine-pair record damaged (correction)"))
        }
        // a record without the field has the digest text it always had
        #expect(C.PairRecord.digestText(from: "f", to: "t", modes: ["a": "0644"]) == "from=f\nto=t\na=0644\n")
    }

    @Test func everyRecordOfTheShippedPairFileVerifiesAgainstItsOwnFingerprints() throws {
        // The file the gate writes into the release. Absent = route closed for everybody (allowed); present = valid.
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/MacRunnerControlCenter/Resources/BottleCatalogues/bottle-fast-pairs.json")
        guard let data = try? Data(contentsOf: url) else { return }
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let pairs = try #require(object["pairs"] as? [[String: Any]])
        for record in pairs {
            let from = try #require(record["from"] as? String), to = try #require(record["to"] as? String)
            guard case .approved = C.pairLookup(file: data, from: from, to: to) else {
                Issue.record("shipped record \(from.prefix(8)) -> \(to.prefix(8)) does not verify"); continue
            }
        }
        #expect(Set(pairs.map { "\($0["from"] as? String ?? "")>\($0["to"] as? String ?? "")" }).count == pairs.count)
    }
}
