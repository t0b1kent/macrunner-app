import Foundation
import Testing
@testable import MacRunnerControlCenter

/// GOTHIC3 07.11.2026 — 0003: extraction and validation of Microsoft d3dx9 from the game's own cabinets.
/// Real-cabinet tests require an explicit GAMEREDIST_REAL_CABS directory.
/// Microsoft cabinets are local test inputs and are not part of the repository.
enum RealCabinets {
    static let directory = ProcessInfo.processInfo.environment["GAMEREDIST_REAL_CABS"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    static var present: Bool {
        guard let directory else { return false }
        return FileManager.default.fileExists(atPath: directory.appendingPathComponent("Nov2008_d3dx9_40_x86.cab").path)
    }
    static func cabinet(_ name: String) -> GameRedist.Cabinet {
        let parsed = GameRedist.parse(cabName: name)!
        return GameRedist.Cabinet(url: directory!.appendingPathComponent(name), dll: parsed.dll, bits: parsed.bits)
    }
    static func tempDir(_ label: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }
}

struct GameRedistPackageTests {
    @Test func pinnedTableIsTheWholeClosedSet() {
        #expect(GameRedist.microsoftReleases.count == 40)
        for number in 24...43 {
            for bits in [32, 64] {
                let key = String(format: "d3dx9_%02d.dll#%d", number, bits)
                let entry = GameRedist.microsoftReleases[key]
                #expect(entry != nil, "\(key)")
                #expect(entry?.sha256.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil, "\(key)")
            }
        }
    }

    @Test func installTargetsFollowDXSETUP() {
        let x86 = GameRedist.Install(dll: "d3dx9_40.dll", bits: 32, sha256: "a", version: "v", cabinet: "c")
        let x64 = GameRedist.Install(dll: "d3dx9_40.dll", bits: 64, sha256: "a", version: "v", cabinet: "c")
        #expect(x86.target == "drive_c/windows/syswow64/d3dx9_40.dll")
        #expect(x64.target == "drive_c/windows/system32/d3dx9_40.dll")
        #expect(x86.overrideName == "d3dx9_40")
    }

    /// A synthetic DLL is a PE, but it has no Microsoft version resource: rejected before any signature work.
    @Test func syntheticDLLIsRejected() {
        var pe = FakePE.make(machine: 0x014c, imports: ["kernel32.dll"])
        pe[0x40 + 22] |= 0x00; pe[0x40 + 23] |= 0x20 // IMAGE_FILE_DLL
        #expect(throws: GameRedist.Rejection.self) { _ = try GameRedist.validate(pe, dll: "d3dx9_40.dll", bits: 32) }
        do { _ = try GameRedist.validate(pe, dll: "d3dx9_40.dll", bits: 32) } catch let r as GameRedist.Rejection {
            guard case .versionResource = r else { Issue.record("expected versionResource, got \(r)"); return }
        } catch { Issue.record("\(error)") }
        #expect(throws: GameRedist.Rejection.self) { _ = try GameRedist.validate(Data("not a pe".utf8), dll: "d3dx9_40.dll", bits: 32) }
    }

    @Test func notACabinetIsAnExtractionError() throws {
        let dir = try RealCabinets.tempDir("redist-bad")
        let url = dir.appendingPathComponent("Nov2008_d3dx9_40_x86.cab")
        try Data("MSCF but not really".utf8).write(to: url)
        let cabinet = GameRedist.Cabinet(url: url, dll: "d3dx9_40.dll", bits: 32)
        #expect(throws: GameRedist.Rejection.self) { _ = try GameRedist.extract(cabinet) }
    }

    // MARK: - Real Microsoft cabinets

    @Test(.enabled(if: RealCabinets.present)) func gothicCabinetValidates() throws {
        let data = try GameRedist.extract(RealCabinets.cabinet("Nov2008_d3dx9_40_x86.cab"))
        #expect(GameRedist.sha256(data) == "16fd909aeb68d0d1aca8529dc7f78880b97d6649d70ce8d03a2c858bc28e216b")
        #expect(try GameRedist.validate(data, dll: "d3dx9_40.dll", bits: 32) == "9.24.950.2656")
        let signature = try Authenticode.verify(data)
        #expect(signature.signerOrganization == "Microsoft Corporation")
        #expect(signature.signerCommonName == "Microsoft Corporation")
    }

    /// Bulk, not one-by-one: every d3dx9 cabinet of the redist extracts, verifies and matches the pinned table.
    @Test(.enabled(if: RealCabinets.present)) func everyRedistCabinetValidates() throws {
        let names = try FileManager.default.contentsOfDirectory(atPath: #require(RealCabinets.directory).path)
            .filter { GameRedist.parse(cabName: $0) != nil }.sorted()
        #expect(names.count == 40)
        var failures: [String] = []
        for name in names {
            let cabinet = RealCabinets.cabinet(name)
            do {
                let data = try GameRedist.extract(cabinet)
                let version = try GameRedist.validate(data, dll: cabinet.dll, bits: cabinet.bits)
                if version != GameRedist.microsoftReleases["\(cabinet.dll)#\(cabinet.bits)"]?.version { failures.append("\(name): \(version)") }
            } catch { failures.append("\(name): \(error)") }
        }
        #expect(failures.isEmpty, "\(failures.joined(separator: "\n"))")
    }

    /// Negative hands on the real file: each tampering must be caught by the check that owns it.
    @Test(.enabled(if: RealCabinets.present)) func tamperedCopiesAreRejected() throws {
        let original = try GameRedist.extract(RealCabinets.cabinet("Nov2008_d3dx9_40_x86.cab"))
        // 1. One byte of code changed: the image no longer matches its signature.
        var code = original
        code[0x2000] ^= 0xFF
        #expect(throws: Authenticode.Failure.imageDigestMismatch) { _ = try Authenticode.verify(code) }
        #expect(throws: GameRedist.Rejection.self) { _ = try GameRedist.validate(code, dll: "d3dx9_40.dll", bits: 32) }
        // 2. Inside the signature itself, each layer separately (positions found by DER patterns, first occurrence
        //    = the signer's own; the counter-signature comes later in the unauthenticated attributes).
        let sha1DigestInfo: [UInt8] = [0x2B, 0x0E, 0x03, 0x02, 0x1A, 0x05, 0x00, 0x04, 0x14]
        let messageDigestAttribute: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x04, 0x31, 0x16, 0x04, 0x14]
        let contentTypeAttribute: [UInt8] = [0x06, 0x09, 0x2A, 0x86, 0x48, 0x86, 0xF7, 0x0D, 0x01, 0x09, 0x03,
                                             0x31, 0x0C, 0x06, 0x0A, 0x2B, 0x06, 0x01, 0x04, 0x01, 0x82, 0x37, 0x02, 0x01]
        // 2a. The image digest in the signed content: the file no longer matches the content.
        var content = original
        content[try #require(Self.index(of: sha1DigestInfo, in: original))] ^= 0x01
        #expect(throws: Authenticode.Failure.imageDigestMismatch) { _ = try Authenticode.verify(content) }
        // 2b. The messageDigest attribute: attributes no longer match the content.
        var attribute = original
        attribute[try #require(Self.index(of: messageDigestAttribute, in: original))] ^= 0x01
        #expect(throws: Authenticode.Failure.contentDigestMismatch) { _ = try Authenticode.verify(attribute) }
        // 2c. Another authenticated attribute (contentType value): only the RSA signature can notice.
        var signed = original
        signed[try #require(Self.index(of: contentTypeAttribute, in: original))] ^= 0x01
        #expect(throws: Authenticode.Failure.badSignature) { _ = try Authenticode.verify(signed) }
        #expect(throws: GameRedist.Rejection.self) { _ = try GameRedist.validate(signed, dll: "d3dx9_40.dll", bits: 32) }
        // 3. A real Microsoft x86 DLL offered as the x64 one: wrong machine.
        #expect(throws: GameRedist.Rejection.architecture("machine 0x014c for a 64-bit cabinet")) {
            _ = try GameRedist.validate(original, dll: "d3dx9_40.dll", bits: 64)
        }
        // 4. Genuine, signed, Microsoft — but not the release it claims to be: the pin refuses it.
        do {
            _ = try GameRedist.validate(original, dll: "d3dx9_41.dll", bits: 32)
            Issue.record("d3dx9_40 bytes accepted as d3dx9_41")
        } catch let rejection as GameRedist.Rejection {
            guard case .unknownRelease = rejection else { Issue.record("\(rejection)"); return }
        }
    }

    /// Offset just AFTER the first occurrence of `pattern` (the byte to flip).
    /// Searched only inside the certificate table (security directory of a PE32 file).
    static func index(of pattern: [UInt8], in data: Data) -> Int? {
        let b = [UInt8](data)
        func u32(_ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        let table = u32(u32(0x3C) + 24 + 96 + 32)
        guard table > 0, b.count > table + pattern.count else { return nil }
        for i in table...(b.count - pattern.count) where b[i] == pattern[0] && Array(b[i..<(i + pattern.count)]) == pattern {
            return i + pattern.count
        }
        return nil
    }

    // MARK: - One launch

    private func gothicGame(withRedist: Bool, fakeCabinet: Bool = false) throws -> URL {
        let dir = try RealCabinets.tempDir("redist-game")
        try FakePE.make(machine: 0x014c, imports: ["d3d9.dll", "d3dx9_40.dll"],
                        functions: ["d3d9.dll": ["Direct3DCreate9"], "d3dx9_40.dll": ["D3DXCreateEffect"]])
            .write(to: dir.appendingPathComponent("Engine.dll"))
        let exe = dir.appendingPathComponent("Gothic3.exe")
        try FakePE.make(machine: 0x014c, imports: ["kernel32.dll", "Engine.dll"]).write(to: exe)
        if withRedist {
            let redist = dir.appendingPathComponent("__redist/DirectX")
            try FileManager.default.createDirectory(at: redist, withIntermediateDirectories: true)
            let target = redist.appendingPathComponent("Nov2008_d3dx9_40_x86.cab")
            if fakeCabinet {
                try Data("not a cabinet".utf8).write(to: target)
            } else {
                try FileManager.default.copyItem(at: #require(RealCabinets.directory).appendingPathComponent("Nov2008_d3dx9_40_x86.cab"), to: target)
            }
        }
        return exe
    }

    @Test func gameWithoutRedistGetsAWarningAndNoInstall() throws {
        let store = try RealCabinets.tempDir("redist-store")
        let resolution = GameRedist.resolve(exe: try gothicGame(withRedist: false), bits: 32, store: store)
        #expect(resolution.installs.isEmpty)
        #expect(resolution.warnings.count == 1)
        #expect(resolution.warnings.first?.contains("d3dx9_40.dll") == true)
        #expect(resolution.notes.contains { $0.contains("no Microsoft cabinet") })
    }

    @Test func gameWithoutD3DXNeedsNothing() throws {
        let dir = try RealCabinets.tempDir("redist-none")
        let exe = dir.appendingPathComponent("game.exe")
        try FakePE.make(machine: 0x014c, imports: ["d3d9.dll"]).write(to: exe)
        let resolution = GameRedist.resolve(exe: exe, bits: 32, store: try RealCabinets.tempDir("redist-store"))
        #expect(resolution == GameRedist.Resolution())
    }

    @Test func brokenCabinetIsAWarningNotAnInstall() throws {
        let store = try RealCabinets.tempDir("redist-store")
        let resolution = GameRedist.resolve(exe: try gothicGame(withRedist: true, fakeCabinet: true), bits: 32, store: store)
        #expect(resolution.installs.isEmpty)
        #expect(resolution.warnings.count == 1)
        #expect(resolution.notes.contains { $0.contains("rejected") })
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: store.path)) ?? []).filter { $0.hasSuffix(".dll") }.isEmpty)
    }

    @Test(.enabled(if: RealCabinets.present)) func gothicLayoutResolvesFromItsOwnCabinet() throws {
        let store = try RealCabinets.tempDir("redist-store")
        let exe = try gothicGame(withRedist: true)
        let first = GameRedist.resolve(exe: exe, bits: 32, store: store)
        #expect(first.warnings.isEmpty)
        #expect(first.installs == [GameRedist.Install(dll: "d3dx9_40.dll", bits: 32,
            sha256: "16fd909aeb68d0d1aca8529dc7f78880b97d6649d70ce8d03a2c858bc28e216b", version: "9.24.950.2656",
            cabinet: "Nov2008_d3dx9_40_x86.cab")])
        #expect(GameRedist.storedCopy(dll: "d3dx9_40.dll", bits: 32, in: store) != nil)
        // The 64-bit view of the same game needs the x64 cabinet, which this layout does not ship.
        #expect(GameRedist.resolve(exe: exe, bits: 64, store: store).installs.isEmpty)
        // Second launch reuses the validated copy (no extraction: a missing tool would fail otherwise).
        let again = GameRedist.resolve(exe: exe, bits: 32, store: store, tool: URL(fileURLWithPath: "/nonexistent/bsdtar"))
        #expect(again.installs == first.installs)
        // A corrupted stored copy is not reused: the tool is needed again (and here it is missing → warning).
        try Data("corrupt".utf8).write(to: GameRedist.storedFile(first.installs[0].sha256, in: store))
        let corrupted = GameRedist.resolve(exe: exe, bits: 32, store: store, tool: URL(fileURLWithPath: "/nonexistent/bsdtar"))
        #expect(corrupted.installs.isEmpty)
        #expect(corrupted.warnings.count == 1)
    }
}
