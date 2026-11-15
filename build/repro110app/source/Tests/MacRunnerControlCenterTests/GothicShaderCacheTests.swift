import Foundation
import Testing
@testable import MacRunnerControlCenter

struct GothicShaderCacheTests {
    private let wine = Data("GENOMESC\0vkd3d-shader 1.18 (Wine bundled)\0".utf8)
    private let microsoft = Data("GENOMESC\0Microsoft (R) HLSL Shader Compiler 9.24.950.2656\0".utf8)

    @Test func detectorKeepsUnknownAndMicrosoftCaches() {
        #expect(GothicShaderCache.stamp(wine).needsRebuild)
        #expect(!GothicShaderCache.stamp(microsoft).needsRebuild)
        #expect(GothicShaderCache.stamp(wine + microsoft).microsoft == 1)
        #expect(GothicShaderCache.stamp(wine + microsoft).needsRebuild)
        #expect(!GothicShaderCache.stamp(Data("wronghdr vkd3d-shader".utf8)).needsRebuild)
        #expect(!GothicShaderCache.stamp(Data("GENOMESC unknown compiler".utf8)).needsRebuild)
        #expect(!GothicShaderCache.stamp(Data()).isCache)
    }

    @Test func nativeOverrideMustBeEffectiveAndExact() {
        #expect(GothicShaderCache.usesMicrosoft("d3d9=n,b;d3dx9_40=n,b"))
        #expect(GothicShaderCache.usesMicrosoft("*D3DX9_40.DLL,d3dx9_41 = N, B"))
        #expect(!GothicShaderCache.usesMicrosoft("d3dx9_40=n,b;d3dx9_40=b"))
        #expect(!GothicShaderCache.usesMicrosoft("d3dx9_40=b,n"))
        #expect(!GothicShaderCache.usesMicrosoft("d3dx9_40="))
        #expect(!GothicShaderCache.usesMicrosoft("d3dx9_41=n,b"))
    }

    @Test func documentLookupFollowsBottleUserAndCase() throws {
        let root = try RealCabinets.tempDir("gothic-cache-path")
        defer { try? FileManager.default.removeItem(at: root) }
        let documents = root.appendingPathComponent("isolated-documents")
        let cache = documents.appendingPathComponent("gOtHiC3/sHaDeR.cAcHe")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        try wine.write(to: cache)
        let user = root.appendingPathComponent("drive_c/users/player")
        try FileManager.default.createDirectory(at: user, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: user.appendingPathComponent("dOcUmEnTs"), withDestinationURL: documents)
        #expect(try GothicShaderCache.cacheURL(prefix: root, user: "PLAYER")?.resolvingSymlinksInPath() == cache.resolvingSymlinksInPath())
        try FileManager.default.createDirectory(at: root.appendingPathComponent("drive_c/users/other"), withIntermediateDirectories: true)
        #expect(try GothicShaderCache.cacheURL(prefix: root, user: "unknown") == nil)
    }

    private static let fixtures = ProcessInfo.processInfo.environment["GOTHIC_SHADER_CACHE_FIXTURES"]
        .map { URL(fileURLWithPath: $0) }

    /// Local copied samples and pinned Microsoft DLL stay outside the repository.
    /// This exercises the production rename, never Wine or a live Documents folder.
    @Test(.enabled(if: fixtures != nil)) func copiedRealCachesAndRenamePolicy() throws {
        let fixtures = try #require(Self.fixtures)
        let root = try RealCabinets.tempDir("gothic-cache-dry-run")
        defer { try? FileManager.default.removeItem(at: root) }
        let game = root.appendingPathComponent("game")
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: fixtures.appendingPathComponent("d3dx9_40.dll"), to: game.appendingPathComponent("d3dx9_40.dll"))
        let compilerHash = try BottleUpdateCatalogue.digest(game.appendingPathComponent("d3dx9_40.dll"))
        #expect(compilerHash == GameRedist.microsoftReleases["d3dx9_40.dll#32"]?.sha256)
        let old = try Data(contentsOf: fixtures.appendingPathComponent("Shader.Cache.vkd3d"))
        let native = try Data(contentsOf: fixtures.appendingPathComponent("Shader.Cache.microsoft"))
        #expect(GothicShaderCache.stamp(old).vkd3d > 0)
        #expect(GothicShaderCache.stamp(native).vkd3d == 0)
        #expect(GothicShaderCache.stamp(native).microsoft > 0)
        let prefix = root.appendingPathComponent("prefix")
        let cache = prefix.appendingPathComponent("drive_c/users/player/Documents/Gothic3/Shader.Cache")
        try FileManager.default.createDirectory(at: cache.deletingLastPathComponent(), withIntermediateDirectories: true)
        let exe = game.appendingPathComponent("Gothic3.exe")
        func prepare(_ overrides: String = "d3dx9_40=n,b", layer: String = "hbdx9-d3d9-x86", busy: Bool = false) -> GothicShaderCache.Result {
            GothicShaderCache.prepare(executable: exe, prefix: prefix, layer: layer,
                                      environment: ["WINEDLLOVERRIDES": overrides, "USER": "player"],
                                      isBusy: { busy }, now: Date(timeIntervalSince1970: 0))
        }
        try old.write(to: cache)
        #expect(prepare("d3dx9_40=b").preserved == nil)
        #expect(prepare(layer: "wine-pe32-d3d9-gl").preserved == nil)
        #expect(prepare(busy: true).preserved == nil)
        #expect(try Data(contentsOf: cache) == old)
        let first = prepare()
        let preserved = try #require(first.preserved)
        #expect(preserved.lastPathComponent == "Shader.Cache.vkd3d-19700101-000000")
        #expect(try Data(contentsOf: preserved) == old)
        #expect(!FileManager.default.fileExists(atPath: cache.path))
        #expect(first.notice == GothicShaderCache.explanation)
        #expect(prepare().preserved == nil)
        try native.write(to: cache)
        #expect(prepare().preserved == nil)
        #expect(try Data(contentsOf: cache) == native)
        try old.write(to: cache)
        let second = try #require(prepare().preserved)
        #expect(second.lastPathComponent == "Shader.Cache.vkd3d-19700101-000000-1")
        #expect(try Data(contentsOf: preserved) == old)
        #expect(try Data(contentsOf: second) == old)
        try old.write(to: cache)
        try Data("untrusted DLL".utf8).write(to: game.appendingPathComponent("d3dx9_40.dll"))
        #expect(prepare().preserved == nil)
        #expect(try Data(contentsOf: cache) == old)
        // The actual byte fixtures used by this test remain immutable.
        #expect(try Data(contentsOf: fixtures.appendingPathComponent("Shader.Cache.vkd3d")) == old)
        #expect(try Data(contentsOf: fixtures.appendingPathComponent("Shader.Cache.microsoft")) == native)
    }
}
