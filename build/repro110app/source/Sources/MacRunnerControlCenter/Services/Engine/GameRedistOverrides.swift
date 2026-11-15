import Foundation

/// GOTHIC3 07.11.2026 — 0005: Microsoft's d3dx9 for THIS game only: `d3dx9_NN=n,b` for the game that shipped it,
/// `d3dx9_NN=b` for every other program of the bottle.
///
/// ★ MEASURED 07.11 (app path, Gothic-layout probe, runs/2b-gl-control-redist-off-*): with a real Microsoft
///   d3dx9_40 in syswow64 and NO override at all, this Wine loads the NATIVE file (wine_builtin=0, effects 9/9).
///   So the file alone would hand Microsoft's DLL to every game of the bottle; the scope needs both halves:
///   native order for the owner of the cabinet, builtin order for everybody else (exactly what they had before
///   any game put its redist into the bottle).
/// ★ Why the process environment, not the registry: it is scoped to the program and its children, needs no offline
///   registry edit, and the warm session signature (WarmBottleSessions.signature hashes the environment) already
///   keeps a session of another game from being reused for this one.
extension GameRedist {
    /// Names a WINEDLLOVERRIDES value already speaks about (lowercased, without `.dll` and a leading `*`).
    static func overrideNames(_ value: String) -> Set<String> {
        var names = Set<String>()
        for entry in value.split(separator: ";") {
            guard let equals = entry.firstIndex(of: "=") else { continue }
            for raw in entry[..<equals].split(separator: ",") {
                var name = raw.trimmingCharacters(in: .whitespaces).lowercased()
                if name.hasPrefix("*") { name.removeFirst() }
                if name.hasSuffix(".dll") { name.removeLast(4) }
                if !name.isEmpty { names.insert(name) }
            }
        }
        return names
    }

    /// `existing` plus `d3dx9_NN=n,b` for every installed redist DLL that `existing` does not already name.
    /// A name the game record (or the layer) sets explicitly wins: the manual setting is the owner's choice.
    static func mergeOverrides(_ existing: String?, installs: [Install]) -> String? {
        let present = overrideNames(existing ?? "")
        let added = Set(installs.map(\.overrideName)).subtracting(present).sorted()
        guard !added.isEmpty else { return existing }
        let ours = added.map { "\($0)=n,b" }.joined(separator: ";")
        guard let existing, !existing.isEmpty else { return ours }
        return existing.hasSuffix(";") ? existing + ours : existing + ";" + ours
    }

    /// The whole scope for one program: its own redist → `n,b` (mergeOverrides); redist that OTHER games put into the
    /// bottle (`present`, BottleSetup.recordedRedist) → `b`. A name `existing` already speaks about is left to it.
    static func scopedOverrides(_ existing: String?, own: [Install], present: [Install]) -> String? {
        let merged = mergeOverrides(existing, installs: own)
        let spoken = overrideNames(merged ?? "")
        let others = Set(present.map(\.overrideName)).subtracting(spoken).sorted()
        guard !others.isEmpty else { return merged }
        let builtin = others.map { "\($0)=b" }.joined(separator: ";")
        guard let merged, !merged.isEmpty else { return builtin }
        return merged.hasSuffix(";") ? merged + builtin : merged + ";" + builtin
    }
}
