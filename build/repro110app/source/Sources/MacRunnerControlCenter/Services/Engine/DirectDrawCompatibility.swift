import CryptoKit
import Foundation

enum DirectDrawCompatibility {
    private static let knownGames: Set<String> = ["mm6.exe", "mm7.exe", "mm7-rel.exe", "mm8.exe"]
    private static let modernAPIs: Set<GraphicsAPI> = [.d3d8, .d3d9, .d3d10, .d3d11, .d3d12, .d3d12RT]
    private static let deploymentLock = NSLock()

    private struct Record: Codable {
        let sha256: String
        var enabled: Set<String> = []
        var managed: Set<String> = []
    }

    static func payload(in engineRoot: URL) -> URL {
        engineRoot.appendingPathComponent("graphics/i386-windows/cnc-ddraw", isDirectory: true)
    }

    static func isAvailable(in engineRoot: URL) -> Bool {
        FileManager.default.isReadableFile(atPath: payload(in: engineRoot).appendingPathComponent("ddraw.dll").path)
    }

    static func recommends(executableName: String, imports: PEImports) -> Bool {
        guard GuestArch(machine: imports.machine) == .x86 else { return false }
        let modules = (imports.imports + imports.delayImports).map { $0.lowercased() }
        guard !modules.contains(where: {
            $0 == "dxgi.dll" || GraphicsProbe.api(forDLL: $0).map(modernAPIs.contains) == true
        }) else { return false }
        return knownGames.contains(executableName.lowercased()) || modules.contains("ddraw.dll")
    }

    static func supports(_ detection: GraphicsDetection) -> Bool {
        detection.arch == .x86 && !detection.dxgiOnly && !detection.evidence.contains {
            $0.strength >= .delayImport && modernAPIs.contains($0.api)
        }
    }

    private static func marker(for exe: URL) -> URL {
        exe.deletingLastPathComponent().appendingPathComponent(".macrunner-cnc-ddraw.json")
    }

    static func hasManagedOverride(for exe: URL) -> Bool {
        record(for: exe)?.managed.contains(exe.lastPathComponent.lowercased()) == true
    }

    private static func record(for exe: URL) -> Record? {
        guard let data = try? Data(contentsOf: marker(for: exe)) else { return nil }
        return try? JSONDecoder().decode(Record.self, from: data)
    }

    private static func digest(of url: URL) throws -> String {
        try SHA256.hash(data: Data(contentsOf: url, options: .mappedIfSafe))
            .map { String(format: "%02x", $0) }.joined()
    }

    enum Deployment: Equatable {
        case enabled, disabled, unmanaged, unchanged
    }

    /// Returns which registry action belongs to this launch. Assets that the player
    /// can customize remain in place when the managed DLL is disabled.
    static func deploy(exe: URL, payload: URL, enabled: Bool) throws -> Deployment {
        deploymentLock.lock()
        defer { deploymentLock.unlock() }

        let files = FileManager.default
        let directory = exe.deletingLastPathComponent()
        let items = try files.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey])
        let existing = items.first { $0.lastPathComponent.lowercased() == "ddraw.dll" }
        let savedRecord = record(for: exe)
        let name = exe.lastPathComponent.lowercased()
        let managed = savedRecord?.managed.contains(name) == true
        let bundledDLL = payload.appendingPathComponent("ddraw.dll")

        if let existing {
            let isRegularFile = try existing.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true
            guard var record = savedRecord, isRegularFile, (try? digest(of: existing)) == record.sha256 else {
                return managed ? .disabled : .unmanaged
            }
            if enabled {
                if record.enabled.insert(name).inserted {
                    record.managed.insert(name)
                    try writeRecord(record, for: exe)
                }
                return .enabled
            }
            guard managed else { return .unmanaged }
            record.enabled.remove(name)
            if record.enabled.isEmpty {
                try files.removeItem(at: existing)
            }
            // Retain the list of managed EXEs for cleanup in other bottles too.
            try writeRecord(record, for: exe)
            return .disabled
        }

        guard enabled else { return managed ? .disabled : .unchanged }
        for asset in ["ddraw.ini", "Shaders"] where !items.contains(where: {
            $0.lastPathComponent.caseInsensitiveCompare(asset) == .orderedSame
        }) {
            try files.copyItem(at: payload.appendingPathComponent(asset), to: directory.appendingPathComponent(asset))
        }
        let destination = directory.appendingPathComponent("ddraw.dll")
        let hash = try digest(of: bundledDLL)
        let record = Record(sha256: hash, enabled: (savedRecord?.enabled ?? []).union([name]),
                            managed: (savedRecord?.managed ?? []).union([name]))
        // Write the receipt first. If copying fails, the next launch can safely retry.
        try writeRecord(record, for: exe)
        try files.copyItem(at: bundledDLL, to: destination)
        return .enabled
    }

    private static func writeRecord(_ record: Record, for exe: URL) throws {
        try JSONEncoder().encode(record).write(to: marker(for: exe), options: .atomic)
    }

    /// Replace the DirectDraw load order for this launch and its children.
    static func withNativeDirectDrawOverride(_ overrides: String?) -> String {
        guard let remaining = withoutDirectDrawOverride(overrides), !remaining.isEmpty else { return "ddraw=n,b" }
        return remaining + ";ddraw=n,b"
    }

    /// Keep other DLL rules, including rules grouped with DirectDraw.
    static func withoutDirectDrawOverride(_ overrides: String?) -> String? {
        overrides.map {
            $0.split(separator: ";").compactMap { entry -> String? in
                guard let equals = entry.firstIndex(of: "=") else { return String(entry) }
                let names = entry[..<equals].split(separator: ",").filter {
                    let name = $0.trimmingCharacters(in: .whitespaces).lowercased()
                    return !["ddraw", "ddraw.dll", "*ddraw", "*ddraw.dll"].contains(name)
                }
                return names.isEmpty ? nil : names.joined(separator: ",") + entry[equals...]
            }.joined(separator: ";")
        }
    }
}
