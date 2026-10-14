import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Tiny native fixtures, no Wine process and no real application data root.
struct BottleUpdateCatalogueTests {
    private typealias Catalogue = BottleUpdateCatalogue
    private struct Fixture {
        let root: URL
        let package: URL
        let prefix: URL
        let old: Catalogue
        let next: Catalogue
        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func fixture(twoChanges: Bool = false) throws -> Fixture {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("bottle-delta-\(UUID().uuidString)")
        let package = root.appendingPathComponent("engine")
        let prefix = root.appendingPathComponent("prefix")
        let placements = [
            "drive_c/windows/system32/xtajit64.dll": "wine/lib/wine/aarch64-windows/xtajit64.dll",
            "drive_c/windows/system32/windowscodecs.dll": "wine/lib/wine/aarch64-windows/windowscodecs.dll",
        ].merging(twoChanges ? ["drive_c/windows/syswow64/xtajit.dll": "wine/lib/wine/aarch64-windows/xtajit.dll"] : [:]) { a, _ in a }
        var old: [String: Catalogue.File] = [:], next: [String: Catalogue.File] = [:]
        for (target, source) in placements {
            let before = Data((source.contains("xtajit") ? "translator-old" : "codec").utf8)
            let after = Data((source.contains("xtajit") ? "translator-new" : "codec").utf8)
            let destination = prefix.appendingPathComponent(target), original = package.appendingPathComponent(source)
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try before.write(to: destination); try after.write(to: original)
            old[target] = .init(source: source, sha256: Catalogue.digest(before))
            next[target] = .init(source: source, sha256: Catalogue.digest(after))
        }
        let inf = package.appendingPathComponent("wine/share/wine/wine.inf")
        try fm.createDirectory(at: inf.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("same-INF".utf8).write(to: inf)
        let inputs = ["wine/share/wine/wine.inf": try Catalogue.digest(inf), "@graphics": "same-layers"]
        return Fixture(root: root, package: package, prefix: prefix,
            old: try Catalogue(schema: 1, engine: "old", engineRoot: package.path, layers: [], inputs: inputs, files: old)
                .recordingInstallation(prefix: prefix),
            next: .init(schema: 1, engine: "new", engineRoot: package.path, layers: [], inputs: inputs, files: next))
    }

    private func copy(_ value: Catalogue, root: String? = nil, inputs: [String: String]? = nil,
                       files: [String: Catalogue.File]? = nil) -> Catalogue {
        .init(schema: value.schema, engine: value.engine, engineRoot: root ?? value.engineRoot,
             layers: value.layers, inputs: inputs ?? value.inputs, files: files ?? value.files, manifest: value.manifest,
             ownership: value.ownership)
    }

    private func commonControlsCatalogue(_ f: Fixture, architectures: [String]) throws -> Catalogue? {
        let fm = FileManager.default
        var declared = Dictionary(uniqueKeysWithValues: f.old.files.values.map { ($0.source, $0.sha256) })
        declared["wine/share/wine/wine.inf"] = try Catalogue.digest(f.package.appendingPathComponent("wine/share/wine/wine.inf"))
        for (arch, lib) in [("amd64", "x86_64-windows"), ("x86", "i386-windows"), ("arm64", "aarch64-windows")] {
            let source = "wine/lib/wine/\(lib)/comctl32_v6.dll"
            let bytes = Data("common-controls-\(arch)".utf8)
            declared[source] = Catalogue.digest(bytes)
            let original = f.package.appendingPathComponent(source)
            try fm.createDirectory(at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
            try bytes.write(to: original)
            if arch != "amd64" {
                let target = arch == "arm64" ? "system32" : "syswow64"
                let base = f.prefix.appendingPathComponent("drive_c/windows/\(target)/comctl32_v6.dll")
                try fm.createDirectory(at: base.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: base)
            }
            if architectures.contains(arch) {
                let file = f.prefix.appendingPathComponent("drive_c/windows/winsxs/\(arch)_microsoft.windows.common-controls_fixture_6.0/comctl32.dll")
                try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try bytes.write(to: file)
            }
        }
        let object: [String: Any] = ["files": declared, "environment": ["WINEARCH": "arm64"],
                                    "graphics": ["layers": [], "routes": []]]
        return try Catalogue.make(manifest: JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
            engineRoot: f.package.path, prefix: f.prefix, graphics: GraphicsCatalog(layers: [], routes: []), layers: [])
    }

    @Test(arguments: [false, true]) func catalogueMatchesFullCommonControlsTopology(amd64Present: Bool) throws {
        let f = try fixture(); defer { f.remove() }
        let arches = ["x86", "arm64"] + (amd64Present ? ["amd64"] : [])
        let catalogue = try #require(try commonControlsCatalogue(f, architectures: arches))
        let controls = catalogue.files.keys.filter { $0.contains("/winsxs/") }
        #expect(controls.count == arches.count)
        #expect(controls.contains { $0.contains("/amd64_") } == amd64Present)
        let installed = try catalogue.recordingInstallation(prefix: f.prefix)
        #expect(try catalogue.delta(from: installed, prefix: f.prefix) == [])
        #expect(try catalogue.restored(prefix: f.prefix, package: f.package) == catalogue)
    }

    @Test(arguments: ["x86", "arm64"]) func missingGeneratedCommonControlsRequiresFull(architecture: String) throws {
        let f = try fixture(); defer { f.remove() }
        let arches = ["x86", "arm64"].filter { $0 != architecture }
        #expect(try commonControlsCatalogue(f, architectures: arches) == nil)
    }

    @Test func commonControlsSymlinkRequiresFull() throws {
        let f = try fixture(); defer { f.remove() }
        let catalogue = try #require(try commonControlsCatalogue(f, architectures: ["x86", "arm64"]))
        let original = f.prefix.appendingPathComponent("drive_c/windows/winsxs/arm64_microsoft.windows.common-controls_fixture_6.0")
        let elsewhere = f.root.appendingPathComponent("arm64-controls")
        try FileManager.default.moveItem(at: original, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: original, withDestinationURL: elsewhere)
        #expect(try catalogue.restored(prefix: f.prefix, package: f.package) == nil)
    }

    @Test func onlyChangedTranslatorIsReplacedAndUnchangedCodecSurvives() throws {
        let f = try fixture(); defer { f.remove() }
        let delta = try #require(try f.next.delta(from: f.old, prefix: f.prefix))
        #expect(delta == ["drive_c/windows/system32/xtajit64.dll"])
        try f.next.apply(delta, from: f.old, prefix: f.prefix, package: f.package)
        for (target, file) in f.next.files { #expect(try Catalogue.digest(f.prefix.appendingPathComponent(target)) == file.sha256) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: f.prefix.path).allSatisfy { !$0.hasPrefix(".macrunner-update-") })
    }

    @Test func identicalInputsAndFilesNeedNoReplacement() throws {
        let f = try fixture(); defer { f.remove() }
        let same = copy(f.next, files: f.old.files)
        // Planning must use the inventories even when package modules cannot
        // be opened. Mutable prefix bytes remain independently verified.
        try FileManager.default.removeItem(at: f.package)
        #expect(try same.delta(from: f.old, prefix: f.prefix) == [])
    }

    @Test func changedINFClosesFastRoute() throws {
        let f = try fixture(); defer { f.remove() }
        var inputs = f.next.inputs; inputs["wine/share/wine/wine.inf"] = "changed"
        #expect(try copy(f.next, inputs: inputs).delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func changedGraphicsClosesFastRoute() throws {
        let f = try fixture(); defer { f.remove() }
        var inputs = f.next.inputs; inputs["@graphics"] = "changed"
        #expect(try copy(f.next, inputs: inputs).delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func corruptUnchangedSystemModuleClosesFastRoute() throws {
        let f = try fixture(); defer { f.remove() }
        try Data("corrupt".utf8).write(to: f.prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
        #expect(try f.next.delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func missingInstallationReceiptRequiresFull() throws {
        let f = try fixture(); defer { f.remove() }
        var unknown = f.old; unknown.ownership = nil
        #expect(try f.next.delta(from: unknown, prefix: f.prefix) == nil)
    }

    @Test func incompleteInstallationReceiptRequiresFull() throws {
        let f = try fixture(); defer { f.remove() }
        var damaged = f.old
        damaged.ownership = .init(prefixRoot: f.prefix.path, files: [:])
        #expect(try f.next.delta(from: damaged, prefix: f.prefix) == nil)
    }

    @Test func unchangedModuleContentsAreNeverOpened() throws {
        let f = try fixture(); defer { f.remove() }
        let target = f.prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: target.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: target.path) }
        // Establish the fixture's known installed identity after chmod. Real
        // application receipts are captured only after its successful copies.
        let installed = try f.old.recordingInstallation(prefix: f.prefix)
        #expect(throws: (any Error).self) { _ = try Catalogue.digest(target) }
        #expect(try f.next.delta(from: installed, prefix: f.prefix) == ["drive_c/windows/system32/xtajit64.dll"])
        #expect(try f.old.delta(from: installed, prefix: f.prefix) == [])
    }

    @Test func sameSizeWriteWithRestoredMtimeRequiresFull() throws {
        let f = try fixture(); defer { f.remove() }
        let target = f.prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll")
        let attrs = try FileManager.default.attributesOfItem(atPath: target.path)
        let previous = try #require(attrs[.modificationDate] as? Date)
        try Data("CODEC".utf8).write(to: target)
        try FileManager.default.setAttributes([.modificationDate: previous], ofItemAtPath: target.path)
        #expect(try f.next.delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func identicalReplacementInodeRequiresFull() throws {
        let f = try fixture(); defer { f.remove() }
        let target = f.prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll")
        try Data("codec".utf8).write(to: target, options: .atomic)
        #expect(try f.next.delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func parentSymlinkRequiresFull() throws {
        let f = try fixture(); defer { f.remove() }
        let parent = f.prefix.appendingPathComponent("drive_c/windows/system32")
        let elsewhere = f.root.appendingPathComponent("foreign-system32")
        try FileManager.default.moveItem(at: parent, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: parent, withDestinationURL: elsewhere)
        #expect(try f.next.delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func copiedReceiptAtAnotherPhysicalPrefixRequiresFull() throws {
        let f = try fixture(); defer { f.remove() }
        let other = f.root.appendingPathComponent("other-prefix")
        try FileManager.default.copyItem(at: f.prefix, to: other)
        #expect(try f.next.delta(from: f.old, prefix: other) == nil)
    }

    @Test(arguments: [false, true]) func ancestorWalkIgnoresDirectoryURLSpelling(directoryHint: Bool) throws {
        let f = try fixture(); defer { f.remove() }
        let spelling = URL(fileURLWithPath: f.prefix.path, isDirectory: directoryHint)
        let installed = try f.old.recordingInstallation(prefix: spelling)
        #expect(try f.next.delta(from: installed, prefix: spelling) == ["drive_c/windows/system32/xtajit64.dll"])
    }

    @Test func prefixURLConstructedBeforeMkdirDoesNotWalkPastRoot() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bottle-before-mkdir-\(UUID().uuidString)")
        let spelling = URL(fileURLWithPath: root.path, isDirectory: false)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let bytes = Data("fixture".utf8)
        try bytes.write(to: root.appendingPathComponent("module.dll"))
        let value = Catalogue(schema: 1, engine: "fixture", engineRoot: root.path, layers: [], inputs: [:],
            files: ["module.dll": .init(source: "fixture", sha256: Catalogue.digest(bytes))])
        let installed = try value.recordingInstallation(prefix: spelling)
        #expect(try value.delta(from: installed, prefix: spelling) == [])
    }

    @Test func userDLLOverOwnedTargetClosesFastRoute() throws {
        let f = try fixture(); defer { f.remove() }
        try Data("user-supplied-DLL".utf8).write(to: f.prefix.appendingPathComponent("drive_c/windows/system32/xtajit64.dll"))
        #expect(try f.next.delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func symlinkOverOwnedTargetClosesFastRoute() throws {
        let f = try fixture(); defer { f.remove() }
        let target = f.prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll")
        try FileManager.default.removeItem(at: target)
        try FileManager.default.createSymbolicLink(at: target, withDestinationURL: f.package.appendingPathComponent(f.next.files["drive_c/windows/system32/windowscodecs.dll"]!.source))
        #expect(try f.next.delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func changedPackageBytesWithStaleManifestFailBeforeReplacement() throws {
        let f = try fixture(); defer { f.remove() }
        let delta = try #require(try f.next.delta(from: f.old, prefix: f.prefix))
        try Data("wrong-new-bytes".utf8).write(to: f.package.appendingPathComponent("wine/lib/wine/aarch64-windows/xtajit64.dll"))
        #expect(throws: (any Error).self) { try f.next.apply(delta, from: f.old, prefix: f.prefix, package: f.package) }
        for (target, file) in f.old.files { #expect(try Catalogue.digest(f.prefix.appendingPathComponent(target)) == file.sha256) }
    }

    @Test func changedInventoryPlanningDoesNotReadPackageModules() throws {
        let f = try fixture(); defer { f.remove() }
        try FileManager.default.removeItem(at: f.package)
        #expect(try f.next.delta(from: f.old, prefix: f.prefix) == ["drive_c/windows/system32/xtajit64.dll"])
    }

    @Test func unchangedInventoryStillRejectsMutablePrefixCorruption() throws {
        let f = try fixture(); defer { f.remove() }
        let same = copy(f.next, files: f.old.files)
        try FileManager.default.removeItem(at: f.package)
        try Data("foreign-codec".utf8).write(to: f.prefix.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
        #expect(try same.delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func danglingNtdllCannotSurviveFastPreparation() throws {
        let f = try fixture(); defer { f.remove() }
        let target = f.prefix.appendingPathComponent("drive_c/windows/system32/ntdll.dll")
        try FileManager.default.createSymbolicLink(atPath: target.path, withDestinationPath: "absent-target")
        #expect(try f.next.delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func relocationClosesFastRoute() throws {
        let f = try fixture(); defer { f.remove() }
        #expect(try copy(f.next, root: "different-root").delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func removedModuleClosesFastRoute() throws {
        let f = try fixture(); defer { f.remove() }
        var files = f.next.files; files.removeValue(forKey: "drive_c/windows/system32/windowscodecs.dll")
        #expect(try copy(f.next, files: files).delta(from: f.old, prefix: f.prefix) == nil)
    }

    @Test func stageFailurePreservesEveryOldFile() throws {
        let f = try fixture(twoChanges: true); defer { f.remove() }
        let delta = try #require(try f.next.delta(from: f.old, prefix: f.prefix))
        try FileManager.default.removeItem(at: f.package.appendingPathComponent("wine/lib/wine/aarch64-windows/xtajit.dll"))
        #expect(throws: (any Error).self) { try f.next.apply(delta, from: f.old, prefix: f.prefix, package: f.package) }
        for (target, file) in f.old.files { #expect(try Catalogue.digest(f.prefix.appendingPathComponent(target)) == file.sha256) }
    }

    @Test func replacementFailureRollsBackEarlierReplacement() throws {
        let f = try fixture(twoChanges: true); defer { f.remove() }
        let delta = try #require(try f.next.delta(from: f.old, prefix: f.prefix))
        let locked = f.prefix.appendingPathComponent("drive_c/windows/syswow64")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: locked.path) }
        #expect(throws: (any Error).self) { try f.next.apply(delta, from: f.old, prefix: f.prefix, package: f.package) }
        for (target, file) in f.old.files { #expect(try Catalogue.digest(f.prefix.appendingPathComponent(target)) == file.sha256) }
    }

    @Test func catalogueSeparatesTranslatorTuningFromWineArchitecture() throws {
        let f = try fixture(); defer { f.remove() }
        for arch in ["x86", "arm64"] {
            try FileManager.default.createDirectory(at: f.prefix.appendingPathComponent(
                "drive_c/windows/winsxs/\(arch)_microsoft.windows.common-controls_fixture_6.0"), withIntermediateDirectories: true)
        }
        var declared = Dictionary(uniqueKeysWithValues: f.next.files.values.map { ($0.source, $0.sha256) })
        declared["wine/share/wine/wine.inf"] = try Catalogue.digest(f.package.appendingPathComponent("wine/share/wine/wine.inf"))
        func make(_ environment: [String: String]) throws -> Catalogue? {
            let object: [String: Any] = ["files": declared, "environment": environment,
                                       "graphics": ["layers": [], "routes": []]]
            return try Catalogue.make(manifest: JSONSerialization.data(withJSONObject: object, options: .sortedKeys),
                engineRoot: f.package.path, prefix: f.prefix, graphics: GraphicsCatalog(layers: [], routes: []), layers: [])
        }
        let a = try #require(try make(["WINEARCH": "arm64"]))
        let tuned = try #require(try make(["WINEARCH": "arm64", "MACRUNNER_FEX_DIV_FAST": "1", "MACRUNNER_HB_X87_FAST64": "0"]))
        let arch = try #require(try make(["WINEARCH": "win64"]))
        #expect(a.inputs == tuned.inputs)
        #expect(a.inputs != arch.inputs)
        #expect(a.engine != tuned.engine)
        #expect(try a.restored(prefix: f.prefix, package: f.package) == a)
        var corrupt = a
        corrupt.manifest = Data("corrupt inventory".utf8)
        #expect(try corrupt.restored(prefix: f.prefix, package: f.package) == nil)
        var missing = a
        missing.manifest = nil
        #expect(try missing.restored(prefix: f.prefix, package: f.package) == nil)
        var inputs = a.inputs
        inputs["wine/share/wine/wine.inf"] = "forged projection"
        #expect(try copy(a, inputs: inputs).restored(prefix: f.prefix, package: f.package) == nil)
    }
}
