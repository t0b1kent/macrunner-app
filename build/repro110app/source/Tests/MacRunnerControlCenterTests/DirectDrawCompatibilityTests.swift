import Foundation
import Testing
@testable import MacRunnerControlCenter

struct DirectDrawCompatibilityTests {
    @Test func selectsOnlyLegacy32BitPrograms() {
        let legacy = PEImports(machine: 0x014c, imports: [], delayImports: ["DDRAW.dll"])
        #expect(DirectDrawCompatibility.recommends(executableName: "game.exe", imports: legacy))
        let noImports = PEImports(machine: 0x014c, imports: [], delayImports: [])
        for name in ["mm6.exe", "MM7.exe", "MM7-Rel.exe", "mm8.exe"] {
            #expect(DirectDrawCompatibility.recommends(executableName: name, imports: noImports))
        }
        #expect(!DirectDrawCompatibility.recommends(executableName: "game.exe", imports: noImports))
        for modernDLL in ["d3d8.dll", "D3D9.dll", "d3d10core.dll", "d3d11.dll", "d3d12.dll", "dxgi.dll"] {
            let mixed = PEImports(machine: 0x014c, imports: ["ddraw.dll"], delayImports: [modernDLL])
            #expect(!DirectDrawCompatibility.recommends(executableName: "MM7-Rel.exe", imports: mixed))
        }
        let modern = PEImports(machine: 0x8664, imports: ["ddraw.dll"], delayImports: [])
        #expect(!DirectDrawCompatibility.recommends(executableName: "MM7.exe", imports: modern))
        let goth = GraphicsDetection(arch: .x86, evidence: [
            .init(api: .d3d9, strength: .importTable, source: "Engine.dll")
        ])
        #expect(!DirectDrawCompatibility.supports(goth))
    }

    @Test func managesOnlyItsOwnDLLAndPreservesPlayerSettings() throws {
        let files = FileManager.default
        let root = files.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? files.removeItem(at: root) }
        let payload = root.appendingPathComponent("payload")
        let game = root.appendingPathComponent("game")
        try files.createDirectory(at: payload.appendingPathComponent("Shaders"), withIntermediateDirectories: true)
        try files.createDirectory(at: game, withIntermediateDirectories: true)
        try Data("official dll".utf8).write(to: payload.appendingPathComponent("ddraw.dll"))
        try Data("official ini".utf8).write(to: payload.appendingPathComponent("ddraw.ini"))
        let exe = game.appendingPathComponent("MM7-Rel.exe")
        let peer = game.appendingPathComponent("MM7.exe")
        let ini = game.appendingPathComponent("ddraw.ini")
        let dll = game.appendingPathComponent("ddraw.dll")
        let custom = Data("custom value".utf8)
        try custom.write(to: ini)
        let staged = try DirectDrawCompatibility.deploy(exe: exe, payload: payload, enabled: true)
        #expect(staged == .enabled)
        #expect(files.fileExists(atPath: game.appendingPathComponent("Shaders").path))
        #expect(try Data(contentsOf: ini) == custom)
        let peerDisabled = try DirectDrawCompatibility.deploy(exe: peer, payload: payload, enabled: false)
        #expect(peerDisabled == .unmanaged)
        #expect(files.fileExists(atPath: dll.path))
        let peerEnabled = try DirectDrawCompatibility.deploy(exe: peer, payload: payload, enabled: true)
        #expect(peerEnabled == .enabled)
        let disabled = try DirectDrawCompatibility.deploy(exe: exe, payload: payload, enabled: false)
        #expect(disabled == .disabled)
        #expect(files.fileExists(atPath: dll.path))
        let lastDisabled = try DirectDrawCompatibility.deploy(exe: peer, payload: payload, enabled: false)
        #expect(lastDisabled == .disabled)
        #expect(!files.fileExists(atPath: dll.path))
        #expect(try Data(contentsOf: ini) == custom)
        try custom.write(to: dll)
        let customDLL = try DirectDrawCompatibility.deploy(exe: exe, payload: payload, enabled: true)
        #expect(customDLL == .disabled)
        #expect(try Data(contentsOf: dll) == custom)

        let manual = root.appendingPathComponent("manual")
        try files.createDirectory(at: manual, withIntermediateDirectories: true)
        let customLibrary = manual.appendingPathComponent("DDRAW.DLL")
        try custom.write(to: customLibrary)
        let manualDLL = try DirectDrawCompatibility.deploy(exe: manual.appendingPathComponent("mm8.exe"),
                                                          payload: payload, enabled: true)
        #expect(manualDLL == .unmanaged)
        #expect(try Data(contentsOf: customLibrary) == custom)
        #expect(!files.fileExists(atPath: manual.appendingPathComponent("ddraw.ini").path))
    }

    @Test func removesOnlyConflictingEnvironmentOverride() {
        #expect(DirectDrawCompatibility.withoutDirectDrawOverride("d3d9=b;*ddraw.dll,winemetal=n,b;ddraw=b;winedbg.exe=d")
                == "d3d9=b;winemetal=n,b;winedbg.exe=d")
        #expect(DirectDrawCompatibility.withoutDirectDrawOverride(nil) == nil)
    }

    @Test func setsNativeDirectDrawForTheLaunchAndKeepsOtherRules() {
        let mixed = "d3d9=b;*DDraw.dll,winemetal=n,b;ddraw=b;winedbg.exe=d"
        let expected = "d3d9=b;winemetal=n,b;winedbg.exe=d;ddraw=n,b"
        #expect(DirectDrawCompatibility.withNativeDirectDrawOverride(mixed) == expected)
        #expect(DirectDrawCompatibility.withNativeDirectDrawOverride(expected) == expected)
        #expect(DirectDrawCompatibility.withNativeDirectDrawOverride("ddraw=b") == "ddraw=n,b")
        #expect(DirectDrawCompatibility.withNativeDirectDrawOverride(nil) == "ddraw=n,b")
    }
}
