import Foundation

/// GOTHIC3 07.11.2026 — D3DX-A step 1 (stage2b/D3DX-A-WIRING-PLAN.md): find the DirectX redist a game ships next to
/// itself and name the `d3dx9_NN` cabinets that DXSETUP would install. Pure functions over the file system; nothing is
/// extracted or installed here (that is BottleSetup.applyGameRedist, a later patch of the series).
/// Cabinet names follow Microsoft's redist: `<Month><Year>_d3dx9_<NN>_<x86|x64>.cab` (e.g. `Nov2008_d3dx9_40_x86.cab`).
enum GameRedist {
    struct Cabinet: Sendable, Equatable {
        let url: URL
        /// The DLL the cabinet carries, e.g. `d3dx9_40.dll`.
        let dll: String
        /// 32 or 64.
        let bits: Int
    }

    /// Where game installers leave the redist: GOG `__redist/DirectX`, Steam `_CommonRedist/DirectX/<any>`,
    /// plain `redist/DirectX` and `DirectX`; searched in the exe's directory and up to `levels` parents.
    static let relativeDirs = ["__redist/DirectX", "_CommonRedist/DirectX", "redist/DirectX", "Redist/DirectX", "DirectX"]

    /// Parse a cabinet file name; nil for anything that is not a d3dx9 cabinet.
    static func parse(cabName name: String) -> (dll: String, bits: Int)? {
        let lower = name.lowercased()
        guard lower.hasSuffix(".cab"), let range = lower.range(of: "_d3dx9_") else { return nil }
        let tail = lower[range.upperBound...].dropLast(4) // "40_x86"
        let parts = tail.split(separator: "_")
        guard parts.count == 2, let number = Int(parts[0]), (24...43).contains(number) else { return nil }
        let bits: Int
        switch parts[1] {
        case "x86": bits = 32
        case "x64": bits = 64
        default: return nil
        }
        return (String(format: "d3dx9_%02d.dll", number), bits)
    }

    /// All d3dx9 cabinets reachable from the game's exe, deduplicated by (dll, bits); the first directory found wins
    /// (closest to the exe), within it the lexicographically last name (newest release of the same DLL never differs
    /// in content, but the choice stays deterministic).
    static func cabinets(near exe: URL, levels: Int = 2, fileManager: FileManager = .default) -> [Cabinet] {
        var base = exe.deletingLastPathComponent()
        var found: [String: Cabinet] = [:]
        for _ in 0...levels {
            for rel in relativeDirs {
                let dir = base.appendingPathComponent(rel)
                for url in cabinetFiles(in: dir, fileManager: fileManager) {
                    guard let (dll, bits) = parse(cabName: url.lastPathComponent) else { continue }
                    let key = "\(dll)#\(bits)"
                    if let old = found[key], old.url.deletingLastPathComponent() != url.deletingLastPathComponent() { continue }
                    if let old = found[key], old.url.lastPathComponent >= url.lastPathComponent { continue }
                    found[key] = Cabinet(url: url, dll: dll, bits: bits)
                }
            }
            let parent = base.deletingLastPathComponent()
            if parent.path == base.path { break }
            base = parent
        }
        return found.values.sorted { ($0.dll, $0.bits) < ($1.dll, $1.bits) }
    }

    /// Files of `dir` and, for Steam's `_CommonRedist/DirectX/<version>/`, of its direct subdirectories.
    private static func cabinetFiles(in dir: URL, fileManager: FileManager) -> [URL] {
        guard let items = try? fileManager.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        var out: [URL] = []
        for item in items.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            if (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                out += ((try? fileManager.contentsOfDirectory(at: item, includingPropertiesForKeys: nil)) ?? []).sorted { $0.lastPathComponent < $1.lastPathComponent }
            } else {
                out.append(item)
            }
        }
        return out
    }

    /// Which d3dx9 DLLs a game actually needs: names of d3dx9 imports in its local import closure.
    static func neededD3DX(importNames: [String]) -> Set<String> {
        Set(importNames.map { $0.lowercased() }.filter { $0.hasPrefix("d3dx9_") && $0.hasSuffix(".dll") })
    }
}
