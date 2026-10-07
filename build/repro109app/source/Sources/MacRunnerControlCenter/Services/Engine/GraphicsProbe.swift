import Foundation

/// Какой графический API вызывает игра — по самому файлу, без запуска.
///
/// ★★★ ИМПОРТ — НЕ ДОКАЗАТЕЛЬСТВО, А УЛИКА РАЗНОЙ СИЛЫ. Лаунчер не импортирует ничего
///   графического; игра с несколькими рендерами грузит нужный через `LoadLibrary` или
///   отложенный импорт; Unity и Unreal держат рендер не в exe. Поэтому здесь собираются
///   улики с их силой, а не вердикт, и «не нашли» остаётся «неизвестно» — не DX11 по
///   умолчанию.
struct GraphicsDetection: Sendable, Equatable {
    enum Strength: Int, Comparable, Sendable {
        case stringReference = 1   // имя DLL строкой в файле — возможно, грузится динамически
        case delayImport = 2       // объявлен, но грузится при первом вызове (может не понадобиться)
        case importTable = 3       // грузится при старте процесса
        case profile = 4           // профиль игры с доказательством

        static func < (a: Strength, b: Strength) -> Bool { a.rawValue < b.rawValue }
    }

    struct Evidence: Sendable, Equatable {
        let api: GraphicsAPI
        let strength: Strength
        /// Файл, в котором найдено, и что именно (`d3d12.dll`).
        let source: String
    }

    var arch: GuestArch?
    var evidence: [Evidence] = []
    /// Только DXGI без d3d1x — версия Direct3D не определена.
    var dxgiOnly = false
    var profile: GraphicsProfile?
    var notes: [String] = []

    /// API со сильнейшей уликой для каждого.
    var candidates: [GraphicsAPI: Strength] {
        var result: [GraphicsAPI: Strength] = [:]
        for item in evidence { result[item.api] = max(result[item.api] ?? item.strength, item.strength) }
        return result
    }
}

enum GraphicsProbe {
    /// Имя DLL → API. `dxgi.dll` отдельно: он общий для D3D10/11/12.
    static func api(forDLL name: String) -> GraphicsAPI? {
        let dll = name.lowercased()
        switch dll {
        case "d3d8.dll": return .d3d8
        case "d3d9.dll": return .d3d9
        case "d3d10.dll", "d3d10_1.dll", "d3d10core.dll": return .d3d10
        case "d3d11.dll": return .d3d11
        case "d3d12.dll": return .d3d12
        case "ddraw.dll": return .ddraw
        case "opengl32.dll": return .opengl
        case "vulkan-1.dll": return .vulkan
        default:
            if dll.hasPrefix("d3dx9_") { return .d3d9 }
            if dll.hasPrefix("d3dx10") { return .d3d10 }
            if dll.hasPrefix("d3dx11") { return .d3d11 }
            return nil
        }
    }

    static let scannedNames = ["d3d8.dll", "d3d9.dll", "d3d10.dll", "d3d10_1.dll", "d3d11.dll", "d3d12.dll",
                               "ddraw.dll", "opengl32.dll", "vulkan-1.dll"]

    /// Разбор exe и модулей движка рядом с ним (UnityPlayer.dll, `*-Shipping.exe` Unreal).
    static func detect(exe: URL, profiles: [GraphicsProfile] = GraphicsProfile.bundled) -> GraphicsDetection {
        var detection = GraphicsDetection()
        if let profile = GraphicsProfile.match(exe: exe, in: profiles) {
            detection.profile = profile
            for api in profile.apis {
                detection.evidence.append(.init(api: api, strength: .profile, source: "profile \(profile.id)"))
            }
        }
        var files = [exe]
        files += engineModules(near: exe)
        var sawDXGI = false
        for (index, file) in files.enumerated() {
            guard let pe = try? PEImportReader.read(file) else {
                if index == 0 { detection.notes.append("not a readable PE file") }
                continue
            }
            if index == 0 { detection.arch = GuestArch(machine: pe.machine) }
            let label = file.lastPathComponent
            for dll in pe.imports {
                if dll == "dxgi.dll" { sawDXGI = true }
                if isServiceOnlyImport(dll, functions: pe.functions[dll]) {
                    detection.notes.append("\(label): \(dll) imported only for helper functions (not rendering)")
                    continue
                }
                if let api = api(forDLL: dll) {
                    detection.evidence.append(.init(api: api, strength: .importTable, source: "\(label): \(dll)"))
                }
            }
            for dll in pe.delayImports {
                if dll == "dxgi.dll" { sawDXGI = true }
                if isServiceOnlyImport(dll, functions: pe.functions[dll]) { continue }
                if let api = api(forDLL: dll) {
                    detection.evidence.append(.init(api: api, strength: .delayImport, source: "\(label): \(dll) (delay)"))
                }
            }
            for dll in (try? StringScan.find(scannedNames, in: file)) ?? [] {
                if let api = api(forDLL: dll) {
                    detection.evidence.append(.init(api: api, strength: .stringReference, source: "\(label): \"\(dll)\""))
                }
            }
            if index > 0 { detection.notes.append("engine module \(label)") }
        }
        let direct3D: Set<GraphicsAPI> = [.d3d10, .d3d11, .d3d12]
        detection.dxgiOnly = sawDXGI && !detection.evidence.contains { direct3D.contains($0.api) }
        return detection
    }

    /// ★ Импорт ради служебных функций — не рендер. Игры на DX11 берут из `d3d9.dll`
    ///   маркеры профилировщика (`D3DPERF_*`), а из `d3dx9_*.dll` — математику. Замер 23.09:
    ///   SkyrimSE.exe импортирует `D3D11CreateDeviceAndSwapChain` и вместе с ним семь функций
    ///   `D3DXVec3*`/`D3DXMatrix*`/`D3DXPlane*` из d3dx9_42 — без этого правила DX9 шёл
    ///   уликой того же уровня, что DX11.
    static func isServiceOnlyImport(_ dll: String, functions: [String]?) -> Bool {
        guard let functions, !functions.isEmpty else { return false }
        if dll == "d3d9.dll" { return functions.allSatisfy { $0.hasPrefix("D3DPERF_") } }
        if dll.hasPrefix("d3dx9_") || dll.hasPrefix("d3dx10") || dll.hasPrefix("d3dx11") {
            let math = ["D3DXVec", "D3DXMatrix", "D3DXPlane", "D3DXQuaternion", "D3DXColor", "D3DXFloat", "D3DXSH"]
            return functions.allSatisfy { name in math.contains { name.hasPrefix($0) } }
        }
        return false
    }

    /// Модули, где у популярных движков живёт рендер.
    static func engineModules(near exe: URL) -> [URL] {
        let fm = FileManager.default
        let dir = exe.deletingLastPathComponent()
        var found: [URL] = []
        let unity = dir.appendingPathComponent("UnityPlayer.dll")
        if fm.fileExists(atPath: unity.path) { found.append(unity) }
        // Unreal: <Game>.exe в корне — лаунчер, игра в <Game>/Binaries/Win64/<Game>-Win64-Shipping.exe.
        if let children = try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.isDirectoryKey]) {
            for child in children where (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                let binaries = child.appendingPathComponent("Binaries/Win64")
                let shipping = ((try? fm.contentsOfDirectory(at: binaries, includingPropertiesForKeys: nil)) ?? [])
                    .filter { $0.lastPathComponent.lowercased().hasSuffix("-shipping.exe") }
                found += shipping.prefix(2)
            }
        }
        return Array(found.prefix(4))
    }
}

// MARK: - Профили игр

/// Профиль игры: API, подтверждённый нашими прогонами. Без доказательства записи нет.
struct GraphicsProfile: Codable, Sendable, Equatable {
    let id: String
    let name: String
    /// Имена exe без учёта регистра (игра и её лаунчер).
    let exe: [String]
    /// Файлы, которые обязаны лежать рядом: общее имя лаунчера (`start_protected_game.exe`
    /// у EasyAntiCheat) без них совпало бы с любой игрой.
    let siblings: [String]?
    let apis: [GraphicsAPI]
    /// Ключи запуска, переключающие рендер, по API (`"d3d11": ["-dx11"]`) — только если
    /// игра их документирует.
    let renderArgs: [String: [String]]?
    let evidence: String
    /// Настройки запуска из доверенного профиля приложения; не из файлов самой игры.
    /// Выбранный графический слой и ручные настройки имеют больший приоритет.
    var environment: [String: String]? = nil
    /// Global fullscreen mode emulation, read by win32u on macOS too
    /// (the Wine setting retains its historical X11 Driver registry key).
    var emulateModeset: Bool? = nil
    /// Trusted media recipe: expose this adjacent data file on a Wine CD-ROM drive.
    var cdromDataFilename: String? = nil
    /// Что уже получалось у этой игры в наших прогонах — со сборкой движка и доказательством.
    /// ★ Это история, а не обещание: сборка из записи может не совпадать со встроенной.
    var known: [KnownResult]? = nil

    struct KnownResult: Codable, Sendable, Equatable {
        enum Reached: String, Codable, Sendable {
            case gameplay, menu, window, fixture, blocked, notRechecked

            var title: String {
                switch self {
                case .gameplay: return L("Gameplay confirmed")
                case .menu: return L("Reached the menu")
                case .window: return L("Window opened")
                case .fixture: return L("Test scene passed")
                case .blocked: return L("Blocked")
                case .notRechecked: return L("Not rechecked for this release")
                }
            }
        }
        let date: String
        let reached: Reached
        /// Сборка движка словами проекта («FEX 9aba4f22 + DXMT D3D11»).
        let engine: String
        /// Понятные названия компонентов для карточки; идентификаторы остаются в диагностике.
        var displayEngine: String? = nil
        let note: String?
        let evidence: String
    }

    static let bundled: [GraphicsProfile] = {
        ["graphics-profiles"].flatMap { name -> [GraphicsProfile] in
            guard let url = Bundle.appResources.url(forResource: name, withExtension: "json"),
                  let data = try? Data(contentsOf: url),
                  let file = try? JSONDecoder().decode(ProfileFile.self, from: data) else { return [] }
            return file.profiles
        }
    }()

    static func match(exe: URL, in profiles: [GraphicsProfile]) -> GraphicsProfile? {
        let name = exe.lastPathComponent.lowercased()
        let dir = exe.deletingLastPathComponent()
        let present = Set(((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).map { $0.lowercased() })
        return profiles.first { profile in
            profile.exe.contains { $0.lowercased() == name }
                && (profile.siblings ?? []).allSatisfy { present.contains($0.lowercased()) }
        }
    }

    private struct ProfileFile: Codable {
        let schema: Int
        let profiles: [GraphicsProfile]
    }
}

// MARK: - Чтение PE

struct PEImports: Sendable, Equatable {
    let machine: UInt16
    let imports: [String]
    let delayImports: [String]
    /// Имена функций для графических DLL (обычный и отложенный импорт): по ним видно,
    /// рисует ли игра через DLL или берёт одну служебную функцию.
    var functions: [String: [String]] = [:]
}

enum PEImportReader {
    enum Failure: Error { case notPE, truncated }

    /// Таблицы импорта и отложенного импорта. Читает только заголовки и нужные участки.
    static func read(_ url: URL) throws -> PEImports {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        func bytes(_ offset: UInt64, _ count: Int) throws -> Data {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        }
        let dos = try bytes(0, 64)
        guard dos.count == 64, dos.prefix(2) == Data("MZ".utf8) else { throw Failure.notPE }
        let peOffset = UInt64(dos.u32(0x3C))
        let coff = try bytes(peOffset, 24)
        guard coff.count == 24, coff.prefix(4) == Data([0x50, 0x45, 0, 0]) else { throw Failure.notPE }
        let machine = coff.u16(4)
        let sectionCount = Int(coff.u16(6))
        let optionalSize = Int(coff.u16(20))
        let optional = try bytes(peOffset + 24, optionalSize)
        guard optional.count == optionalSize, optionalSize >= 96 else { throw Failure.truncated }
        let pe32Plus = optional.u16(0) == 0x20b
        let imageBase: UInt64 = pe32Plus ? optional.u64(24) : UInt64(optional.u32(28))
        let dirCountOffset = pe32Plus ? 108 : 92
        let dirOffset = pe32Plus ? 112 : 96
        let dirCount = optional.count >= dirCountOffset + 4 ? Int(optional.u32(dirCountOffset)) : 0
        func directory(_ index: Int) -> (rva: UInt32, size: UInt32)? {
            let at = dirOffset + index * 8
            guard index < dirCount, optional.count >= at + 8 else { return nil }
            let rva = optional.u32(at), size = optional.u32(at + 4)
            return rva == 0 ? nil : (rva, size)
        }

        let sectionData = try bytes(peOffset + 24 + UInt64(optionalSize), sectionCount * 40)
        var sections: [(va: UInt32, size: UInt32, raw: UInt32)] = []
        for i in 0..<min(sectionCount, sectionData.count / 40) {
            let s = i * 40
            sections.append((sectionData.u32(s + 12), max(sectionData.u32(s + 8), sectionData.u32(s + 16)),
                             sectionData.u32(s + 20)))
        }
        func offset(_ rva: UInt32) -> UInt64? {
            for s in sections where rva >= s.va && rva < s.va &+ s.size {
                return UInt64(rva - s.va) + UInt64(s.raw)
            }
            return nil
        }
        func name(_ rva: UInt32) throws -> String? {
            guard let at = offset(rva) else { return nil }
            let raw = try bytes(at, 256)
            let end = raw.firstIndex(of: 0) ?? raw.endIndex
            let text = String(decoding: raw[raw.startIndex..<end], as: UTF8.self)
            return text.isEmpty ? nil : text.lowercased()
        }

        /// Имена функций по таблице имён импорта (ординалы пропускаются).
        func functionNames(_ tableRVA: UInt32) throws -> [String] {
            guard tableRVA != 0, let at = offset(tableRVA) else { return [] }
            let width = pe32Plus ? 8 : 4
            let thunks = try bytes(at, width * 256)
            var names: [String] = []
            var i = 0
            while i + width <= thunks.count {
                let value = pe32Plus ? thunks.u64(i) : UInt64(thunks.u32(i))
                if value == 0 { break }
                let ordinal = pe32Plus ? value & (1 << 63) != 0 : value & (1 << 31) != 0
                if !ordinal, let text = try rawName(UInt32(truncatingIfNeeded: value) &+ 2) { names.append(text) }
                i += width
            }
            return names
        }
        func rawName(_ rva: UInt32) throws -> String? {
            guard let at = offset(rva) else { return nil }
            let raw = try bytes(at, 128)
            let end = raw.firstIndex(of: 0) ?? raw.endIndex
            let text = String(decoding: raw[raw.startIndex..<end], as: UTF8.self)
            return text.isEmpty ? nil : text
        }
        var functions: [String: [String]] = [:]

        var imports: [String] = []
        if let dir = directory(1), let at = offset(dir.rva) {
            let table = try bytes(at, 20 * 1024)
            var i = 0
            while i + 20 <= table.count {
                let nameRVA = table.u32(i + 12)
                if nameRVA == 0 { break }
                if let dll = try name(nameRVA) {
                    imports.append(dll)
                    if GraphicsProbe.api(forDLL: dll) != nil {
                        let lookup = table.u32(i) != 0 ? table.u32(i) : table.u32(i + 16)
                        functions[dll, default: []] += try functionNames(lookup)
                    }
                }
                i += 20
            }
        }
        var delayed: [String] = []
        if let dir = directory(13), let at = offset(dir.rva) {
            let table = try bytes(at, 32 * 512)
            var i = 0
            while i + 32 <= table.count {
                let attributes = table.u32(i)
                var nameField = table.u32(i + 4)
                if nameField == 0 { break }
                // Старый формат (VC6, Attributes без бита 1): в поле адрес VA, а не RVA.
                if attributes & 1 == 0, UInt64(nameField) > imageBase {
                    nameField = UInt32(truncatingIfNeeded: UInt64(nameField) - imageBase)
                }
                if let dll = try name(nameField) {
                    delayed.append(dll)
                    if GraphicsProbe.api(forDLL: dll) != nil {
                        var table = table.u32(i + 16)
                        if attributes & 1 == 0, UInt64(table) > imageBase {
                            table = UInt32(truncatingIfNeeded: UInt64(table) - imageBase)
                        }
                        functions[dll, default: []] += try functionNames(table)
                    }
                }
                i += 32
            }
        }
        return PEImports(machine: machine, imports: imports, delayImports: delayed, functions: functions)
    }
}

/// Поиск имён DLL строками (ASCII и UTF-16LE, без учёта регистра) — для `LoadLibrary`.
/// Читает кусками с нахлёстом и не дальше 96 МБ: имена лежат в данных, а не в хвостовых
/// ресурсах-архивах.
enum StringScan {
    static let limit: UInt64 = 96 << 20

    static func find(_ names: [String], in url: URL) throws -> Set<String> {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let patterns: [(String, Data)] = names.flatMap { name -> [(String, Data)] in
            let ascii = Array(name.utf8)
            return [(name, Data(ascii)), (name, Data(ascii.flatMap { [$0, 0] }))]
        }
        let overlap = max((patterns.map(\.1.count).max() ?? 1) - 1, 0)
        var found = Set<String>()
        var carry = Data()
        var read: UInt64 = 0
        while read < limit, let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            read += UInt64(chunk.count)
            var window = carry
            window.append(Data(chunk.map { $0 >= 0x41 && $0 <= 0x5A ? $0 | 0x20 : $0 }))
            for (name, pattern) in patterns where !found.contains(name) {
                if window.range(of: pattern) != nil { found.insert(name) }
            }
            carry = window.suffix(overlap)
        }
        return found
    }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 {
        UInt16(self[startIndex + at]) | UInt16(self[startIndex + at + 1]) << 8
    }
    func u32(_ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + at + $1]) << (8 * UInt32($1)) }
    }
    func u64(_ at: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + at + $1]) << (8 * UInt64($1)) }
    }
}
