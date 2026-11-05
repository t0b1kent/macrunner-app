import Foundation
import Testing
@testable import MacRunnerControlCenter

@Suite struct PSOCacheTransplantTests {
    private func fixture() throws -> (URL, URL, URL) {
        let environment = ProcessInfo.processInfo.environment
        let parent = environment["MACRUNNER_TEST_WORKSPACE_ROOT"].map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.temporaryDirectory
        let root = parent.appendingPathComponent("pso-transplant-\(UUID())")
        let source = root.appendingPathComponent("9598ab010d5b-4e89a8cc-27.0.1-Apple_M1_Pro")
        let target = root.appendingPathComponent("9598ab010d5b-de834a3d-27.0.1-Apple_M1_Pro")
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try Data([77, 82, 80, 83, 79, 49, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0]).write(to: source.appendingPathComponent("manifest.bin"))
        try (Data("MRPKIDX6".utf8) + Data(repeating: 0, count: 8)).write(to: source.appendingPathComponent("pack.idx"))
        try Data("warm pipeline bytes".utf8).write(to: source.appendingPathComponent("pack.bin"))
        return (root, source, target)
    }

    @Test func approvedMappingClonesEveryByteAndPreservesSource() throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        let before = try PSOCacheTransplant.inventory(source)
        let candidates = try PSOCacheTransplant.candidates(in: root)
        #expect(candidates.count == 1)
        #expect(candidates.first?.1 == target)
        #expect(try PSOCacheTransplant.transplant(source: source, target: target))
        #expect(try PSOCacheTransplant.inventory(target) == before)
        #expect(try PSOCacheTransplant.inventory(source) == before)
        #expect(try PSOCacheTransplant.candidates(in: root).isEmpty)
    }

    @Test func existingTargetIsPreserved() throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        try Data("new cache".utf8).write(to: target.appendingPathComponent("preserve"))
        #expect(try !PSOCacheTransplant.transplant(source: source, target: target))
        #expect(try String(contentsOf: target.appendingPathComponent("preserve"), encoding: .utf8) == "new cache")
    }

    @Test func malformedPackNeverPublishesDestination() throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try Data("bad".utf8).write(to: source.appendingPathComponent("pack.idx"))
        #expect(throws: PSOCacheTransplant.Failure.self) { try PSOCacheTransplant.transplant(source: source, target: target) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func linkedCacheContentNeverLeavesTheNamespace() throws {
        let (root, source, target) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: source.appendingPathComponent("external"), withDestinationURL: root)
        #expect(throws: PSOCacheTransplant.Failure.self) { try PSOCacheTransplant.transplant(source: source, target: target) }
        #expect(!FileManager.default.fileExists(atPath: target.path))
    }

    @Test func unprovedFingerprintHasNoMigrationCandidate() throws {
        let (root, source, _) = try fixture()
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.moveItem(at: source, to: root.appendingPathComponent("different-4e89a8cc-27.0.1-Apple_M1_Pro"))
        #expect(try PSOCacheTransplant.candidates(in: root).isEmpty)
    }
}
