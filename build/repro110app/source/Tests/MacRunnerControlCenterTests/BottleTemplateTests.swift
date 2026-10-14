import Darwin
import Foundation
import Testing
@testable import MacRunnerControlCenter

@Suite(.serialized)
struct BottleTemplateTests {
    private func directory() throws -> URL {
        let root = EnginePaths.base.appendingPathComponent("launch-template-test-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    private func seed(under root: URL, profile: String = "guest-profile") throws -> URL {
        let fm = FileManager.default
        let source = root.appendingPathComponent("seed")
        try fm.createDirectory(at: source.appendingPathComponent("drive_c/windows/system32"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("drive_c/users/\(profile)"), withIntermediateDirectories: true)
        try fm.createDirectory(at: source.appendingPathComponent("dosdevices"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("dosdevices/c:").path, withDestinationPath: "../drive_c")
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("dosdevices/z:").path, withDestinationPath: "/")
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("dosdevices/d:").path, withDestinationPath: root.path)
        try fm.createSymbolicLink(atPath: source.appendingPathComponent("drive_c/users/\(profile)/Desktop").path, withDestinationPath: root.path + "/old-home/Desktop")
        let codec = Data("codec-payload".utf8)
        try codec.write(to: source.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
        let values = BottleTemplate.substitutions(engine: root.appendingPathComponent("old-engine"), prefix: source,
            data: root.appendingPathComponent("old-data"), home: root.path + "/old-home")
        let text = "WINE REGISTRY Version 2\n\n[Software\\\\Microsoft\\\\Cryptography]\n\"MachineGuid\"=\"old-guid\"\n\"ProfileImagePath\"=\"C:\\\\users\\\\\(profile)\"\n" + values.sorted(by: { $0.key < $1.key }).map { "\"\($0.key)\"=\"\($0.value)\"\n" }.joined()
        for hive in BottleTemplate.hives { try Data(text.utf8).write(to: source.appendingPathComponent(hive)) }
        let marker: [String: Any] = ["layers": ["dxmt-x64"], "wicRegistration": ["codec": BottleTemplate.digest(codec)]]
        try JSONSerialization.data(withJSONObject: marker).write(to: source.appendingPathComponent(BottleSetup.markerName))
        try Data("1789035749\n".utf8).write(to: source.appendingPathComponent(".update-timestamp"))
        try BottleTemplate.seal(source, generation: "generation-A", values: values)
        return source
    }

    @Test func generationChangesWithWineOrCompositionButNotLocation() {
        let a = Data(#"{"name":"Wine11-A","files":{"dll":"aaa"}}"#.utf8)
        let b = Data(#"{"name":"Wine11-B","files":{"dll":"aaa"}}"#.utf8)
        let c = Data(#"{"name":"Wine11-A","files":{"dll":"bbb"}}"#.utf8)
        #expect(BottleTemplate.generation(manifest: a) == BottleTemplate.generation(manifest: a))
        #expect(BottleTemplate.generation(manifest: a) != BottleTemplate.generation(manifest: b))
        #expect(BottleTemplate.generation(manifest: a) != BottleTemplate.generation(manifest: c))
    }

    @Test(arguments: ["guest-profile", "another-profile"])
    func relocationHasNoSourceRootAndWritableHivesAreIndependent(profile: String) throws {
        let fm = FileManager.default
        let root = try directory()
        let source = try seed(under: root, profile: profile)
        let receipt = try BottleTemplate.validate(source, generation: "generation-A")
        #expect(!fm.fileExists(atPath: source.appendingPathComponent(BottleSetup.markerName).path))
        let destination = root.appendingPathComponent("another-machine/another-data/bottle")
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        #expect(clonefile(source.path, destination.path, 0) == 0)
        let afterRoot = root.appendingPathComponent("another-machine")
        let values = BottleTemplate.substitutions(engine: afterRoot.appendingPathComponent("new-engine"), prefix: destination,
            data: afterRoot.appendingPathComponent("new-data"), home: afterRoot.path + "/new-home")
        try BottleTemplate.unseal(destination, receipt: receipt, values: values, engineStamp: "new-stamp", engineRoot: values["@@MR_ENGINE@@"]!)
        let old = try Data(contentsOf: source.appendingPathComponent("system.reg"))
        let text = try String(contentsOf: destination.appendingPathComponent("system.reg"), encoding: .utf8)
        #expect(!text.contains("old-guid"))
        #expect(!text.contains("old-home"))
        #expect(!text.contains("old-engine"))
        #expect(!text.contains("old-data"))
        #expect(!text.contains("@@MR_"))
        #expect(text.contains("new-home"))
        #expect(text.contains(profile))
        let sourceHive = try fm.attributesOfItem(atPath: source.appendingPathComponent("system.reg").path)
        let targetHive = try fm.attributesOfItem(atPath: destination.appendingPathComponent("system.reg").path)
        #expect(sourceHive[.systemFileNumber] as? UInt64 != targetHive[.systemFileNumber] as? UInt64)
        let unchanged = try Data(contentsOf: source.appendingPathComponent("system.reg"))
        #expect(old == unchanged)
        #expect(!fm.fileExists(atPath: destination.appendingPathComponent("dosdevices/d:").path))
        #expect(!fm.fileExists(atPath: destination.appendingPathComponent("drive_c/users/\(profile)/Desktop").path))
        let marker = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent(BottleSetup.markerName))) as? [String: Any])
        #expect(marker["bootstrapPending"] as? Bool == true)
        #expect(marker["engineRoot"] as? String == values["@@MR_ENGINE@@"])
    }

    @Test func corruptAndWrongGenerationSeedsAreRejected() throws {
        let root = try directory()
        let source = try seed(under: root)
        #expect(throws: BottleTemplate.Failure.self) { try BottleTemplate.validate(source, generation: "generation-B") }
        try Data("corrupt".utf8).write(to: source.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll"))
        #expect(throws: BottleTemplate.Failure.self) { try BottleTemplate.validate(source, generation: "generation-A") }
    }

    @Test func localVerificationRejectsSameSizeCorruptionWithRestoredMtimeAndMovedSeed() throws {
        let fm = FileManager.default
        let root = try directory()
        let source = try seed(under: root)
        let codec = source.appendingPathComponent("drive_c/windows/system32/windowscodecs.dll")
        let date = Date(timeIntervalSince1970: 1000)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: codec.path)
        _ = try BottleTemplate.validate(source, generation: "generation-A")
        let before = try BottleTemplate.metadata(source)
        try Data("Codec-payload".utf8).write(to: codec)
        try fm.setAttributes([.modificationDate: date], ofItemAtPath: codec.path)
        let after = try BottleTemplate.metadata(source)
        let key = "drive_c/windows/system32/windowscodecs.dll"
        #expect(before[key]?[3] == after[key]?[3])
        #expect(before[key]?[4] == after[key]?[4])
        #expect(before[key]?[6] != after[key]?[6] || before[key]?[7] != after[key]?[7])
        #expect(throws: BottleTemplate.Failure.self) { try BottleTemplate.validate(source, generation: "generation-A") }
        let cleanRoot = try directory()
        let clean = try seed(under: cleanRoot)
        let imported = root.appendingPathComponent("imported")
        #expect(clonefile(clean.path, imported.path, 0) == 0)
        #expect(try BottleTemplate.metadata(clean) != BottleTemplate.metadata(imported))
        _ = try BottleTemplate.validate(imported, generation: "generation-A")
        _ = try BottleTemplate.validate(imported, generation: "generation-A")
    }

    @Test func firstBottleWithMissingParentClonesAndBecomesReadyOnlyAfterBootstrap() throws {
        let fm = FileManager.default
        let root = try directory()
        let source = try seed(under: root)
        let receipt = try BottleTemplate.validate(source, generation: "generation-A")
        let destination = root.appendingPathComponent("new-data/Bottles/First")
        var bootstrap = false
        var fallback = false
        let cloned = try BottleTemplate.transaction(destination: destination, clone: { staged in
            guard clonefile(source.path, staged.path, 0) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }, prepare: { staged in
            let values = BottleTemplate.substitutions(engine: root.appendingPathComponent("engine"), prefix: destination,
                data: root.appendingPathComponent("data"), home: root.path + "/home")
            try BottleTemplate.unseal(staged, receipt: receipt, values: values, engineStamp: "current", engineRoot: "new-engine")
        }, bootstrap: {
            bootstrap = true
            let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent(BottleSetup.markerName))) as? [String: Any])
            #expect(object["bootstrapPending"] as? Bool == true)
        }, stop: {}, quarantine: { _ in }, fallback: { fallback = true })
        #expect(cloned && bootstrap && !fallback)
        let object = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: destination.appendingPathComponent(BottleSetup.markerName))) as? [String: Any])
        #expect(object["bootstrapPending"] == nil)
    }

    @Test func registryWindowsAndUnixPathsRoundTrip() {
        let values = ["@@MR_HOME@@": "/profiles/source home", "@@MR_ENGINE@@": "/profiles/source home/Engine"]
        let text = #""dll"="Z:\\profiles\\source home\\Engine\\wine" "home"="/profiles/source home""#
        let sealed = BottleTemplate.relocate(text, values: values, sealing: true)
        #expect(!sealed.contains("source home"))
        let moved = BottleTemplate.relocate(sealed, values: ["@@MR_HOME@@": "/different/user", "@@MR_ENGINE@@": "/new/Engine"], sealing: false)
        #expect(moved.contains(#"Z:\\new\\Engine\\wine"#))
        #expect(moved.contains("/different/user"))
    }

    @Test(arguments: ["missing", "corrupt", "space", "interrupted", "bootstrap"])
    func failureUsesOrdinaryCreationAndNeverLeavesFalseReady(arm: String) throws {
        let fm = FileManager.default
        let root = try directory()
        let source = try seed(under: root)
        let destination = root.appendingPathComponent("final")
        var events: [String] = []
        var failedTree: URL?
        let result = try BottleTemplate.transaction(destination: destination, clone: { staged in
            events.append("clone")
            if arm == "missing" { throw CocoaError(.fileNoSuchFile) }
            if arm == "corrupt" {
                try Data("bad".utf8).write(to: source.appendingPathComponent("system.reg"))
                _ = try BottleTemplate.validate(source, generation: "generation-A")
            }
            if arm == "space" { throw NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC)) }
            try fm.copyItem(at: source, to: staged)
            if arm == "interrupted" { throw BottleTemplate.Failure.interruptedClone }
        }, prepare: { staged in
            events.append("prepare")
            try Data(#"{"bootstrapPending":true}"#.utf8).write(to: staged.appendingPathComponent(BottleSetup.markerName))
        }, bootstrap: {
            events.append("bootstrap")
            if arm == "bootstrap" { throw BottleTemplate.Failure.invalidBootstrap }
        }, stop: { events.append("stop") }, quarantine: { item in
            events.append("quarantine")
            let failed = root.appendingPathComponent("failed-\(UUID())")
            try fm.moveItem(at: item, to: failed)
            failedTree = failed
        }, fallback: {
            events.append("fallback")
            #expect(!fm.fileExists(atPath: destination.path))
            try fm.createDirectory(at: destination, withIntermediateDirectories: false)
            try Data("ordinary-prefix".utf8).write(to: destination.appendingPathComponent("system.reg"))
        })
        #expect(result == false)
        #expect(events.filter { $0 == "fallback" }.count == 1)
        #expect(events.last == "fallback")
        #expect(!fm.fileExists(atPath: destination.appendingPathComponent(BottleSetup.markerName).path))
        let remaining = try fm.contentsOfDirectory(atPath: root.path)
        #expect(!remaining.contains { $0.hasPrefix(".clone-") })
        if arm == "bootstrap" {
            #expect(events.suffix(3) == ["stop", "quarantine", "fallback"])
            #expect(failedTree != nil)
        }
        if arm == "interrupted" { #expect(failedTree != nil) }
    }

    @Test func failedScopedStopRefusesFallbackAndPreservesEvidence() throws {
        let fm = FileManager.default
        let root = try directory()
        let destination = root.appendingPathComponent("final")
        var fallback = false
        #expect(throws: BottleTemplate.Failure.self) {
            try BottleTemplate.transaction(destination: destination, clone: { staged in
                try fm.createDirectory(at: staged, withIntermediateDirectories: false)
                try Data(#"{"bootstrapPending":true}"#.utf8).write(to: staged.appendingPathComponent(BottleSetup.markerName))
            }, prepare: { _ in }, bootstrap: { throw BottleTemplate.Failure.invalidBootstrap },
            stop: { throw BottleTemplate.Failure.invalidBootstrap }, quarantine: { _ in }, fallback: { fallback = true })
        }
        #expect(!fallback)
        #expect(fm.fileExists(atPath: destination.path))
        let data = try Data(contentsOf: destination.appendingPathComponent(BottleSetup.markerName))
        #expect(String(decoding: data, as: UTF8.self).contains("bootstrapPending"))
    }

    @Test func cancelledBootstrapCleansPublishedCloneWithoutRestartingOrdinaryCreation() throws {
        let root = try directory()
        let destination = root.appendingPathComponent("final")
        var stopped = false
        var ordinaryStarted = false
        func checkCancellation() throws { throw WarmSessionState.Failure.closed }
        #expect(throws: WarmSessionState.Failure.self) {
            try BottleTemplate.transaction(destination: destination, clone: { staged in
                try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            }, prepare: { _ in }, bootstrap: { throw WarmSessionState.Failure.closed },
            stop: { stopped = true }, quarantine: { path in
                try FileManager.default.moveItem(at: path, to: root.appendingPathComponent("failed"))
            }, fallback: {
                // The backend's cancellation check runs before ordinary creation.
                try checkCancellation()
                ordinaryStarted = true
            })
        }
        #expect(stopped)
        #expect(!ordinaryStarted)
        #expect(!FileManager.default.fileExists(atPath: destination.path))
    }

    @Test func pendingMarkerIsNeverReadyAndExistingBottleIsPreserved() throws {
        let fm = FileManager.default
        let root = try directory()
        let destination = root.appendingPathComponent("final")
        try fm.createDirectory(at: destination, withIntermediateDirectories: false)
        let engine = BundledEngine(root: root, name: "test", environmentTemplate: [:])
        let marker: [String: Any] = ["engine": BottleSetup.engineStamp(engine), "engineRoot": BottleSetup.engineRootPath(engine), "bootstrapPending": true]
        try JSONSerialization.data(withJSONObject: marker).write(to: destination.appendingPathComponent(BottleSetup.markerName))
        try Data("existing".utf8).write(to: destination.appendingPathComponent("system.reg"))
        #expect(!BottleSetup.isReady(engine: engine, prefix: destination))
        #expect(throws: BottleTemplate.Failure.self) {
            try BottleTemplate.transaction(destination: destination, clone: { _ in }, prepare: { _ in }, bootstrap: {}, stop: {}, quarantine: { _ in }, fallback: {})
        }
        let data = try Data(contentsOf: destination.appendingPathComponent("system.reg"))
        #expect(data == Data("existing".utf8))
    }

    @Test func candidateWarmDefaultPreservesExplicitOptOutAndEnvironmentOverride() {
        #expect(WarmBottleSessions.requested(override: nil, storedPreference: nil))
        #expect(!WarmBottleSessions.requested(override: nil, storedPreference: false))
        #expect(WarmBottleSessions.requested(override: "1", storedPreference: false))
        #expect(!WarmBottleSessions.requested(override: "0", storedPreference: true))
        #expect(!WarmBottleSessions.requested(override: "invalid", storedPreference: true))
    }

    @Test func rootRequiresAbsoluteExplicitPathAndRejectsOwnerLibrary() throws {
        #expect(throws: LaunchDataRoot.Failure.self) { try LaunchDataRoot.resolve(environment: [:]) }
        #expect(throws: LaunchDataRoot.Failure.self) { try LaunchDataRoot.resolve(environment: ["MACRUNNER_APP_DATA_ROOT":"relative"]) }
        let protected = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacRunnerControlCenter").path
        #expect(throws: LaunchDataRoot.Failure.self) { try LaunchDataRoot.resolve(environment: ["MACRUNNER_APP_DATA_ROOT":protected]) }
        let root = try directory()
        let resolved = try LaunchDataRoot.resolve(environment: ["MACRUNNER_APP_DATA_ROOT":root.path + "/fresh"])
        #expect(resolved.path.hasSuffix("/fresh"))
        #expect(!FileManager.default.fileExists(atPath: resolved.path))
    }

    @Test func rootRejectsRelocatedOwnerLibraryAndAllAliases() throws {
        let fm = FileManager.default
        let root = try directory()
        let home = root.appendingPathComponent("fixture-home")
        let owner = home.appendingPathComponent("Library/Application Support/MacRunnerControlCenter")
        let relocated = root.appendingPathComponent("relocated-library")
        let alias = root.appendingPathComponent("second-alias")
        try fm.createDirectory(at: owner.deletingLastPathComponent(), withIntermediateDirectories: true)
        try fm.createDirectory(at: relocated, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: owner, withDestinationURL: relocated)
        try fm.createSymbolicLink(at: alias, withDestinationURL: relocated)
        for path in [owner.path, relocated.path, alias.path] {
            for suffix in ["", "/not-created"] {
                #expect(throws: LaunchDataRoot.Failure.self) {
                    try LaunchDataRoot.resolve(environment: ["MACRUNNER_APP_DATA_ROOT": path + suffix], homeDirectory: home)
                }
            }
        }
        // A similar prefix is an independent directory, not a child of owner.
        let safe = relocated.path + "-other/new"
        let resolved = try LaunchDataRoot.resolve(environment: ["MACRUNNER_APP_DATA_ROOT": safe], homeDirectory: home)
        #expect(resolved.path == safe)
        #expect(!fm.fileExists(atPath: resolved.path))
        #expect(!fm.fileExists(atPath: relocated.appendingPathComponent("not-created").path))
    }
}
