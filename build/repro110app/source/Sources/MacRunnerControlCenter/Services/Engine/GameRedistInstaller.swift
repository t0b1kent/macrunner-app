import Foundation

/// D3DX-REDIST 17.11.2026 — install the game's own DirectX redist AT GAME INSTALLATION, as its installer does on Windows.
/// Nothing is downloaded: the cabinets come from the installer's payload (GOG `__redist/DirectX`, Steam `_CommonRedist`,
/// `redist/DirectX`, `DirectX`). Every DLL goes through the existing `GameRedist.install` (PE shape, Microsoft version
/// resource, Authenticode, pinned SHA-256) into the app's validated store — outside any bottle, so it survives
/// reinstalling the bottle; the bottle copy and the `n,b` order for THIS game are made at launch (applyGameRedist).
extension GameRedist {
    struct PayloadImport: Sendable, Equatable {
        var installs: [Install] = []
        var rejected: [String] = []
        var cabinetsSeen = 0
        var x86: Int { installs.filter { $0.bits == 32 }.count }
        var x64: Int { installs.filter { $0.bits == 64 }.count }
    }

    /// Cabinets inside an installer payload / game folder itself (the folder's own redist directories only).
    static func payloadCabinets(in folder: URL, fileManager: FileManager = .default) -> [Cabinet] {
        cabinets(near: folder.appendingPathComponent("_"), levels: 0, fileManager: fileManager)
    }

    /// Import every d3dx9 cabinet of the payload into `store`. A bad cabinet is reported, never installed.
    static func installFromPayload(folder: URL, store: URL, tool: URL = bsdtar) -> PayloadImport {
        var result = PayloadImport()
        for cabinet in payloadCabinets(in: folder) {
            result.cabinetsSeen += 1
            do { result.installs.append(try install(from: cabinet, store: store, tool: tool)) }
            catch { result.rejected.append("\(cabinet.url.lastPathComponent): \(error)") }
        }
        return result
    }

    /// GOG identity of a game folder: the `goggame-<id>.info` names next to the exe (and one/two levels up).
    static func gogIdentities(near exe: URL, fileManager: FileManager = .default) -> Set<String> {
        var base = exe.deletingLastPathComponent()
        var ids = Set<String>()
        for _ in 0...2 {
            for name in (try? fileManager.contentsOfDirectory(atPath: base.path)) ?? []
            where name.hasPrefix("goggame-") && name.hasSuffix(".info") { ids.insert(name.lowercased()) }
            let parent = base.deletingLastPathComponent()
            if parent.path == base.path { break }
            base = parent
        }
        return ids
    }

    /// A game added as an already-installed folder has no `__redist` next to it. Look for the SAME game (same GOG id) in
    /// the places the app itself unpacked installers to (`roots`, each root and its direct children) and import its
    /// cabinets. Returns what was imported; empty when nothing matches.
    @discardableResult
    static func adoptKnownCabinets(for exe: URL, roots: [URL], store: URL, tool: URL = bsdtar,
                                   fileManager: FileManager = .default) -> PayloadImport {
        let ids = gogIdentities(near: exe, fileManager: fileManager)
        var total = PayloadImport()
        guard !ids.isEmpty else { return total }
        let gameFolder = exe.deletingLastPathComponent().standardizedFileURL.path
        for root in roots {
            let children = ((try? fileManager.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []) + [root]
            for dir in children.sorted(by: { $0.path < $1.path }) where dir.standardizedFileURL.path != gameFolder {
                let names = Set(((try? fileManager.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
                guard !ids.isDisjoint(with: names) else { continue }
                let part = installFromPayload(folder: dir, store: store, tool: tool)
                total.installs += part.installs
                total.rejected += part.rejected
                total.cabinetsSeen += part.cabinetsSeen
            }
        }
        return total
    }

    /// Where the missing-redist warning points: the installer, not a manual folder copy.
    static func missingWarning(dll: String) -> String {
        String(format: L("This game uses Direct3D effects (%@), but the DirectX files from its installer are missing, so the 3D picture will be black. Add the game from its installer (Add game, then choose the installer) so MacRunner can install them."), dll)
    }
}
