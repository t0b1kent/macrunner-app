import CryptoKit
import Foundation

/// GOTHIC3 07.11.2026 — D3DX-A step 2 (0003): take Microsoft's `d3dx9_NN.dll` out of the game's OWN DirectX redist
/// cabinets (found by `GameRedist.cabinets`), prove what it is, and keep a validated copy for the bottle.
/// Nothing is downloaded; nothing comes from anywhere but the game's folder. Installing into the bottle is
/// `BottleSetup.applyGameRedist` (0004), the DLL override is `GameRedist.mergeOverrides` (0005).
///
/// ★ Why at all (measured 06.11, GOTHIC3 RESULT-2A): with Wine's builtin d3dx9_40 Gothic 3 draws a BLACK world
///   (HUD alive); with Microsoft's d3dx9_40 from the game's redist the world has sky and light. Same engine,
///   same bottle, the only difference is this one DLL.
extension GameRedist {
    /// Every d3dx9 DLL that Microsoft shipped in the DirectX redistributable — Feb2005 (d3dx9_24) to Jun2010
    /// (d3dx9_43, the last release; there will be no other). A finite, closed set, so it is pinned in full:
    /// "dll#bits" → SHA-256 and FileVersion. Census 07.11.2026 of the Jun2010 redist shipped in Gothic 3 GOG
    /// `__redist/DirectX` (40 of 40 cabinets): every file carries a valid embedded Authenticode signature
    /// (`Authenticode.verify`) by «Microsoft Corporation», chain to «Microsoft Root Authority» (openssl).
    /// This table is the publisher check; the signature check proves the bytes are the signed ones.
    static let microsoftReleases: [String: (sha256: String, version: String)] = [
        "d3dx9_24.dll#32": ("94ec67763f67932dd4273ef5cc12889a5cef090ffea3ee78a80c7b530272b1b5", "9.5.132.0"), // Feb2005_d3dx9_24_x86.cab
        "d3dx9_24.dll#64": ("1ec422bd6421c741eef57847260967f215913649901e21dd9c46eb1b3bb10906", "9.5.132.0"), // Feb2005_d3dx9_24_x64.cab
        "d3dx9_25.dll#32": ("4c54df27ce84d21b2924e64ff79b13e7876ce85d8e0c9c1d0abd8da73888187a", "9.6.168.0"), // Apr2005_d3dx9_25_x86.cab
        "d3dx9_25.dll#64": ("10b09474bfe4e2bb395472628646bc5f353fbfbec976575c45eeff49984ebaa6", "9.6.168.0"), // Apr2005_d3dx9_25_x64.cab
        "d3dx9_26.dll#32": ("8ea96fe01c3c86a36fcb3795ae03eb12034003e335ef475571efaeda17c5bc78", "9.7.239.0"), // Jun2005_d3dx9_26_x86.cab
        "d3dx9_26.dll#64": ("30b06dbbd202494bae3b87487e7273adcffd17a9d2c29977030fde0570aa841b", "9.7.239.0"), // Jun2005_d3dx9_26_x64.cab
        "d3dx9_27.dll#32": ("a70d571cd675c97c9eeb4a234dba1d667ffb54ec3bb14defb36b3e2f605ae257", "9.8.299.0"), // Aug2005_d3dx9_27_x86.cab
        "d3dx9_27.dll#64": ("f9dd288c9895973f8db1856d172779041c6dee173ad1ef53b1727fc85cb6b75f", "9.8.299.0"), // Aug2005_d3dx9_27_x64.cab
        "d3dx9_28.dll#32": ("f3e391b5f1c1f9637cabf2b812b6f5d65e4776c89d779f506f6b643cc563176d", "9.10.455.0"), // Dec2005_d3dx9_28_x86.cab
        "d3dx9_28.dll#64": ("a2870f86e2f1b11646ff3f404bdbde10520c481c1400b20d25fdf56e66fb0a17", "9.10.455.0"), // Dec2005_d3dx9_28_x64.cab
        "d3dx9_29.dll#32": ("c5e21c18f8c79bc517da59e3192c39ea73bdcaf85867628187f6b3cca07dd21f", "9.11.519.0"), // Feb2006_d3dx9_29_x86.cab
        "d3dx9_29.dll#64": ("d496c31a6b0f41398ecad7698987c55c2cb88eb6568976ba9b01a197879dd9dc", "9.11.519.0"), // Feb2006_d3dx9_29_x64.cab
        "d3dx9_30.dll#32": ("5edeed79f2359527a55b8189cfa8b9b121cd608d44eead905a0f3436938ad532", "9.12.589.0"), // Apr2006_d3dx9_30_x86.cab
        "d3dx9_30.dll#64": ("7d1374e3b921a70b5028472ab164d9e582e3c3525334235d642664189da9b157", "9.12.589.0"), // Apr2006_d3dx9_30_x64.cab
        "d3dx9_31.dll#32": ("e2065619fe6eb0034833b1dc0369deb4a6edc3110e38a1132eeafcf430c578a5", "9.15.779.0"), // OCT2006_d3dx9_31_x86.cab
        "d3dx9_31.dll#64": ("84167b7df7e97c63f0cc15c1d272cdc7bba942f6f36a8801aec9840825891d0d", "9.15.779.0"), // OCT2006_d3dx9_31_x64.cab
        "d3dx9_32.dll#32": ("e96693794daa05a75a83c11df2e7b42f2de61567c6ad0b69e353b50f6c88119f", "9.16.843.0"), // DEC2006_d3dx9_32_x86.cab
        "d3dx9_32.dll#64": ("7c723479e3720a52f286d2e9e044f19ed893a34e6819d53e4de6991048febad1", "9.16.843.0"), // DEC2006_d3dx9_32_x64.cab
        "d3dx9_33.dll#32": ("c6b7b2ad7742dde5dd8d1a35fdc1c185e586e551ad9c74d3fb21759cd8ca4da8", "9.18.904.15"), // APR2007_d3dx9_33_x86.cab
        "d3dx9_33.dll#64": ("7338b1d039d0c08e45f24874e4918ffa642ebfe5967c96035f66f509265fa33e", "9.18.904.15"), // APR2007_d3dx9_33_x64.cab
        "d3dx9_34.dll#32": ("b6f77f06518d35345fb61172b6a13159125ed60c469d28b1a2e07970e9ddf81d", "9.19.949.46"), // JUN2007_d3dx9_34_x86.cab
        "d3dx9_34.dll#64": ("715fa6d4931324cca594c4fdfc60274ed29d296bb4592d102b36bc976c8b8ada", "9.19.949.46"), // JUN2007_d3dx9_34_x64.cab
        "d3dx9_35.dll#32": ("2198022938156b790e9cfb0f7997494b66a11a1ad49b395be58251d635b66b26", "9.19.949.1104"), // AUG2007_d3dx9_35_x86.cab
        "d3dx9_35.dll#64": ("ca195b7ee7aee29e6417acf0e6c1736d9aac76890a622eb62ed137394fc6f2b9", "9.19.949.1104"), // AUG2007_d3dx9_35_x64.cab
        "d3dx9_36.dll#32": ("c12f0ab0338eb5031d3d04beaf7208ac848f7e037d21ff963d2af90221cbe935", "9.19.949.2111"), // Nov2007_d3dx9_36_x86.cab
        "d3dx9_36.dll#64": ("c683e8e543bdd678dfdea0b325a3de04a419eeb053e2f32702d8b472aaf54c6d", "9.19.949.2111"), // Nov2007_d3dx9_36_x64.cab
        "d3dx9_37.dll#32": ("c2ccb84c672a9d8966e82a28005a4269886ee304972ac3590c0b8a9c1622a3d8", "9.22.949.2248"), // Mar2008_d3dx9_37_x86.cab
        "d3dx9_37.dll#64": ("8c1d75b01208b59fcabfb389df296e00a58713322f00112fbe80aa7b6221708a", "9.22.949.2248"), // Mar2008_d3dx9_37_x64.cab
        "d3dx9_38.dll#32": ("743e77a228e7d75442263ad70051e44534f7972c6326fd34b505a9c2c245894b", "9.23.949.2378"), // JUN2008_d3dx9_38_x86.cab
        "d3dx9_38.dll#64": ("b54e832bd8d7e94772c680f49c31b86f9c5db456f8e5cac66720d533896f1cfe", "9.23.949.2378"), // JUN2008_d3dx9_38_x64.cab
        "d3dx9_39.dll#32": ("5d29988cad858f754ecc62c3d30de555f82cc21b5b26c448b890295e9b7bee82", "9.24.949.2307"), // Aug2008_d3dx9_39_x86.cab
        "d3dx9_39.dll#64": ("aecbe2965f7c9aa60257670114c06b21a3de914b03e20ff569c5cb44ec4807fd", "9.24.949.2307"), // Aug2008_d3dx9_39_x64.cab
        "d3dx9_40.dll#32": ("16fd909aeb68d0d1aca8529dc7f78880b97d6649d70ce8d03a2c858bc28e216b", "9.24.950.2656"), // Nov2008_d3dx9_40_x86.cab
        "d3dx9_40.dll#64": ("8a9ea8bc06786d342af4e7d171abbe6640cf31d9d01afb86dbf63f26302077db", "9.24.950.2656"), // Nov2008_d3dx9_40_x64.cab
        "d3dx9_41.dll#32": ("6ac4df203af419d3f3b7d9a99e14a3490ea3ad307c474bfe36baea642b1421f6", "9.26.952.2844"), // Mar2009_d3dx9_41_x86.cab
        "d3dx9_41.dll#64": ("33fd649d5b6e90bd7b7f51d1431ef3501772ae985e320442e5fd750e4368669a", "9.26.952.2844"), // Mar2009_d3dx9_41_x64.cab
        "d3dx9_42.dll#32": ("f8b9cfab7fffbc8f98e41aa439d72921dc180634a1febca2a9d41a0df35d3472", "9.27.952.3001"), // Aug2009_d3dx9_42_x86.cab
        "d3dx9_42.dll#64": ("1d6f5aa25ac2f1e55d3fd89cd5b33edd4de3709bf0353c75ab8645cebc087fa5", "9.27.952.3001"), // Aug2009_d3dx9_42_x64.cab
        "d3dx9_43.dll#32": ("0b28546be22c71834501f7d7185ede5d79742457331c7ee09efc14490dd64f5f", "9.29.952.3111"), // Jun2010_d3dx9_43_x86.cab
        "d3dx9_43.dll#64": ("84b900dbd7fa978d6e0caee26fc54f2f61d92c9c75d10b35f00e3e82cd1d67b4", "9.29.952.3111"), // Jun2010_d3dx9_43_x64.cab
    ]

    /// One validated Microsoft DLL for the bottle. Written to the bottle marker (0004), so it is Codable.
    struct Install: Codable, Sendable, Equatable, Hashable {
        let dll: String
        let bits: Int
        let sha256: String
        let version: String
        /// Provenance only: the cabinet's file name (never a path — the marker must not carry the player's folders).
        let cabinet: String

        /// Where DXSETUP puts it on 64-bit Windows (`d3dx9_NN_x86.inf`): x86 → SysWOW64, x64 → System32.
        var target: String { "drive_c/windows/\(bits == 32 ? "syswow64" : "system32")/\(dll)" }
        /// Name for WINEDLLOVERRIDES: `d3dx9_40`.
        var overrideName: String { dll.lowercased().hasSuffix(".dll") ? String(dll.dropLast(4)).lowercased() : dll.lowercased() }
        /// Stable identity for signatures and logs.
        var identity: String { "\(target)@\(sha256)" }
    }

    enum Rejection: Error, Equatable, CustomStringConvertible {
        case extraction(String)
        case notPE(String)
        case architecture(String)
        case versionResource(String)
        case signature(String)
        case unknownRelease(String)

        var description: String {
            switch self {
            case .extraction(let s): return "cabinet could not be read: \(s)"
            case .notPE(let s): return "not a Windows DLL: \(s)"
            case .architecture(let s): return "wrong architecture: \(s)"
            case .versionResource(let s): return "not a Microsoft DirectX file: \(s)"
            case .signature(let s): return "signature check failed: \(s)"
            case .unknownRelease(let s): return "not a known Microsoft release: \(s)"
            }
        }
    }

    // MARK: - Extraction (bsdtar reads Microsoft cabinets; no temporary files, no network)

    static let bsdtar = URL(fileURLWithPath: "/usr/bin/bsdtar")
    /// The largest d3dx9 DLL is 5.6 MB (d3dx9_40 x64); anything far larger is not one of them.
    static let extractionLimit = 32 << 20

    static func extract(_ cabinet: Cabinet, tool: URL = bsdtar) throws -> Data {
        let listing = try run(tool, ["-tf", cabinet.url.path])
        guard listing.status == 0 else { throw Rejection.extraction("listing exit \(listing.status)") }
        let members = String(decoding: listing.output, as: UTF8.self).split(whereSeparator: \.isNewline).map(String.init)
        let matching = members.filter { $0.lowercased() == cabinet.dll.lowercased() }
        guard matching.count == 1 else {
            throw Rejection.extraction("\(matching.count) members named \(cabinet.dll) in \(cabinet.url.lastPathComponent)")
        }
        let data = try run(tool, ["-xOf", cabinet.url.path, matching[0]])
        guard data.status == 0, !data.output.isEmpty else { throw Rejection.extraction("extract exit \(data.status)") }
        return data.output
    }

    private static func run(_ tool: URL, _ arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        process.executableURL = tool
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw Rejection.extraction("\(tool.lastPathComponent) did not start") }
        var output = Data()
        let reader = pipe.fileHandleForReading
        while let chunk = try? reader.read(upToCount: 1 << 20), !chunk.isEmpty {
            output.append(chunk)
            if output.count > extractionLimit {
                process.terminate()
                process.waitUntilExit()
                throw Rejection.extraction("output larger than \(extractionLimit) bytes")
            }
        }
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    // MARK: - Validation

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// PE (machine, DLL, optional-header kind) → version resource (Microsoft, DirectX) → embedded Authenticode
    /// signature by Microsoft Corporation → the pinned release table. Returns the FileVersion. Cheapest first,
    /// so a rejection names the first thing that is wrong.
    static func validate(_ data: Data, dll: String, bits: Int) throws -> String {
        let b = [UInt8](data)
        func u16(_ o: Int) throws -> Int {
            guard o >= 0, o + 2 <= b.count else { throw Rejection.notPE("truncated") }
            return Int(b[o]) | Int(b[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= b.count else { throw Rejection.notPE("truncated") }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        guard b.count > 0x40, b[0] == 0x4D, b[1] == 0x5A else { throw Rejection.notPE("no MZ header") }
        let pe = try u32(0x3C)
        guard pe + 24 <= b.count, Array(b[pe..<(pe + 4)]) == [0x50, 0x45, 0, 0] else { throw Rejection.notPE("no PE signature") }
        let machine = try u16(pe + 4)
        let wantedMachine = bits == 32 ? 0x014c : 0x8664
        guard machine == wantedMachine else {
            throw Rejection.architecture(String(format: "machine 0x%04x for a %d-bit cabinet", machine, bits))
        }
        guard try u16(pe + 22) & 0x2000 != 0 else { throw Rejection.notPE("not a DLL") }
        let optional = pe + 24
        let magic = try u16(optional)
        guard magic == (bits == 32 ? 0x10b : 0x20b) else { throw Rejection.notPE(String(format: "optional header 0x%x", magic)) }

        let version = try versionStrings(b, pe: pe, optional: optional, magic: magic)
        guard version.strings["CompanyName"] == "Microsoft Corporation" else {
            throw Rejection.versionResource("CompanyName \(version.strings["CompanyName"] ?? "missing")")
        }
        guard version.strings["ProductName"]?.contains("DirectX") == true else {
            throw Rejection.versionResource("ProductName \(version.strings["ProductName"] ?? "missing")")
        }

        let signature: Authenticode.Signature
        do { signature = try Authenticode.verify(data) }
        catch { throw Rejection.signature("\(error)") }
        guard signature.signerOrganization == "Microsoft Corporation" else {
            throw Rejection.signature("signed by \(signature.signerOrganization ?? signature.signerCommonName ?? "unknown")")
        }

        let digest = sha256(data)
        guard let known = microsoftReleases["\(dll.lowercased())#\(bits)"] else { throw Rejection.unknownRelease("\(dll) is not a d3dx9 release") }
        guard known.sha256 == digest else { throw Rejection.unknownRelease("\(dll) sha256 \(digest.prefix(16))") }
        guard known.version == version.fileVersion else {
            throw Rejection.versionResource("FileVersion \(version.fileVersion), release \(known.version)")
        }
        return version.fileVersion
    }

    /// RT_VERSION → VS_VERSIONINFO: FileVersion from VS_FIXEDFILEINFO, strings of the first StringTable.
    private static func versionStrings(_ b: [UInt8], pe: Int, optional: Int, magic: Int) throws
        -> (fileVersion: String, strings: [String: String]) {
        func u16(_ o: Int) throws -> Int {
            guard o >= 0, o + 2 <= b.count else { throw Rejection.versionResource("truncated") }
            return Int(b[o]) | Int(b[o + 1]) << 8
        }
        func u32(_ o: Int) throws -> Int {
            guard o >= 0, o + 4 <= b.count else { throw Rejection.versionResource("truncated") }
            return Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24
        }
        let sectionCount = try u16(pe + 6), optionalSize = try u16(pe + 20)
        let sections = optional + optionalSize
        func offset(_ rva: Int) throws -> Int {
            for i in 0..<sectionCount {
                let s = sections + i * 40
                let virtualAddress = try u32(s + 12), virtualSize = try u32(s + 8)
                let rawSize = try u32(s + 16), raw = try u32(s + 20)
                if rva >= virtualAddress, rva < virtualAddress + max(virtualSize, rawSize) {
                    let o = raw + (rva - virtualAddress)
                    guard o < b.count else { break }
                    return o
                }
            }
            throw Rejection.versionResource("RVA outside sections")
        }
        let directories = optional + (magic == 0x10b ? 96 : 112)
        let resourceRVA = try u32(directories + 2 * 8)
        guard resourceRVA != 0 else { throw Rejection.versionResource("no resources") }
        let base = try offset(resourceRVA)
        /// Entries of one resource directory: (id or nil for a named entry, offset, is a subdirectory).
        func entries(_ directory: Int) throws -> [(id: Int?, offset: Int, isDirectory: Bool)] {
            let named = try u16(directory + 12), ids = try u16(directory + 14)
            guard named + ids < 4096 else { throw Rejection.versionResource("resource directory") }
            return try (0..<(named + ids)).map { i in
                let e = directory + 16 + i * 8
                let name = try u32(e), target = try u32(e + 4)
                return (name & 0x8000_0000 == 0 ? name : nil, base + (target & 0x7fff_ffff), target & 0x8000_0000 != 0)
            }
        }
        guard let type = try entries(base).first(where: { $0.id == 16 && $0.isDirectory }),
              let name = try entries(type.offset).first(where: { $0.isDirectory }),
              let language = try entries(name.offset).first(where: { !$0.isDirectory }) else {
            throw Rejection.versionResource("no RT_VERSION")
        }
        let blobStart = try offset(try u32(language.offset)), blobSize = try u32(language.offset + 4)
        guard blobSize >= 92, blobStart + blobSize <= b.count else { throw Rejection.versionResource("version blob bounds") }
        let end = blobStart + blobSize

        struct Node { let key: String; let value: Range<Int>; let isText: Bool; let children: Range<Int> }
        func align(_ x: Int) -> Int { (x + 3) & ~3 }
        func node(_ start: Int, limit: Int) throws -> Node {
            let length = try u16(start), valueLength = try u16(start + 2), type = try u16(start + 4)
            guard length >= 6, start + length <= limit else { throw Rejection.versionResource("version node bounds") }
            var k = start + 6
            var units: [UInt16] = []
            while k + 1 < start + length {
                let unit = UInt16(try u16(k)); k += 2
                if unit == 0 { break }
                units.append(unit)
            }
            let valueStart = align(k)
            let valueBytes = type == 1 ? valueLength * 2 : valueLength
            let valueEnd = min(valueStart + valueBytes, start + length)
            return Node(key: String(decoding: units, as: UTF16.self), value: valueStart..<max(valueStart, valueEnd),
                        isText: type == 1, children: min(align(valueEnd), start + length)..<(start + length))
        }
        func children(_ range: Range<Int>) throws -> [Node] {
            var out: [Node] = [], i = range.lowerBound
            while i + 6 <= range.upperBound {
                let length = try u16(i)
                guard length >= 6 else { break }
                out.append(try node(i, limit: range.upperBound))
                i = align(i + length)
            }
            return out
        }
        func text(_ range: Range<Int>) throws -> String {
            var units: [UInt16] = []
            var k = range.lowerBound
            while k + 1 < range.upperBound {
                let unit = UInt16(try u16(k)); k += 2
                if unit == 0 { break }
                units.append(unit)
            }
            return String(decoding: units, as: UTF16.self)
        }
        let root = try node(blobStart, limit: end)
        guard root.key == "VS_VERSION_INFO", root.value.count >= 52, try u32(root.value.lowerBound) == 0xFEEF04BD else {
            throw Rejection.versionResource("no VS_FIXEDFILEINFO")
        }
        let ms = try u32(root.value.lowerBound + 8), ls = try u32(root.value.lowerBound + 12)
        let fileVersion = "\(ms >> 16).\(ms & 0xffff).\(ls >> 16).\(ls & 0xffff)"
        var strings: [String: String] = [:]
        for info in try children(root.children) where info.key == "StringFileInfo" {
            for table in try children(info.children) {
                for entry in try children(table.children) where strings[entry.key] == nil {
                    strings[entry.key] = try text(entry.value)
                }
            }
        }
        return (fileVersion, strings)
    }

    // MARK: - Store (content-addressed, in the app's data — never inside the game folder)

    static var defaultStore: URL { EnginePaths.base.appendingPathComponent("GameRedist", isDirectory: true) }

    static func storedFile(_ sha256: String, in store: URL) -> URL {
        store.appendingPathComponent("\(sha256).dll")
    }

    /// A stored copy that still is the pinned release, or nil.
    static func storedCopy(dll: String, bits: Int, in store: URL) -> URL? {
        guard let known = microsoftReleases["\(dll.lowercased())#\(bits)"] else { return nil }
        let url = storedFile(known.sha256, in: store)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe), sha256(data) == known.sha256 else { return nil }
        return url
    }

    @discardableResult
    static func store(_ data: Data, in store: URL) throws -> URL {
        let fm = FileManager.default
        try fm.createDirectory(at: store, withIntermediateDirectories: true)
        let digest = sha256(data)
        let url = storedFile(digest, in: store)
        if let existing = try? Data(contentsOf: url, options: .mappedIfSafe), sha256(existing) == digest { return url }
        let staged = store.appendingPathComponent(".staged-\(UUID().uuidString)")
        try data.write(to: staged)
        guard rename(staged.path, url.path) == 0 else {
            try? fm.removeItem(at: staged)
            throw CocoaError(.fileWriteUnknown)
        }
        return url
    }

    /// Cabinet → validated bytes → store. Reuses a stored copy of the same pinned release without extracting again.
    static func install(from cabinet: Cabinet, store: URL, tool: URL = bsdtar) throws -> Install {
        let key = "\(cabinet.dll.lowercased())#\(cabinet.bits)"
        if let known = microsoftReleases[key], storedCopy(dll: cabinet.dll, bits: cabinet.bits, in: store) != nil {
            return Install(dll: cabinet.dll.lowercased(), bits: cabinet.bits, sha256: known.sha256, version: known.version,
                           cabinet: cabinet.url.lastPathComponent)
        }
        let data = try extract(cabinet, tool: tool)
        let version = try validate(data, dll: cabinet.dll, bits: cabinet.bits)
        try Self.store(data, in: store)
        return Install(dll: cabinet.dll.lowercased(), bits: cabinet.bits, sha256: sha256(data), version: version,
                       cabinet: cabinet.url.lastPathComponent)
    }

    // MARK: - One launch

    /// An `Install` for a pinned release whose validated copy is already in `store` (hash re-checked on read).
    static func storedInstall(dll: String, bits: Int, store: URL) -> Install? {
        guard let known = microsoftReleases["\(dll.lowercased())#\(bits)"],
              storedCopy(dll: dll, bits: bits, in: store) != nil else { return nil }
        return Install(dll: dll.lowercased(), bits: bits, sha256: known.sha256, version: known.version, cabinet: "validated store")
    }

    struct Resolution: Sendable, Equatable {
        var installs: [Install] = []
        /// For the player (tile/result): what is missing and what it means.
        var warnings: [String] = []
        /// For the engine log.
        var notes: [String] = []
        /// D3DX-REDIST 17.11: d3dx9 DLLs the game needs that neither its own folder nor the store could supply.
        var missing: [String] = []
    }

    /// Import names of the exe and of its local import closure (depth 2, as GraphicsProbe follows it).
    static func importNames(of exe: URL) -> [String] {
        ([exe] + GraphicsProbe.localImportClosure(of: exe)).flatMap { file -> [String] in
            guard let pe = try? PEImportReader.read(file) else { return [] }
            return pe.imports + pe.delayImports
        }
    }

    /// What this game needs (d3dx9 imports of its own modules) from what it ships (cabinets near the exe).
    /// Needed but not found, or found but not a Microsoft release → a warning the player sees; never a guess.
    static func resolve(exe: URL, bits: Int, store: URL, importNames names: [String]? = nil, tool: URL = bsdtar,
                        knownRoots: [URL] = []) -> Resolution {
        var resolution = Resolution()
        let needed = neededD3DX(importNames: names ?? importNames(of: exe)).sorted()
        guard !needed.isEmpty else { return resolution }
        let found = cabinets(near: exe).filter { $0.bits == bits }
        var adopted = false
        for dll in needed {
            guard let cabinet = found.first(where: { $0.dll == dll }) else {
                // D3DX-REDIST: the same game unpacked earlier by the app (installer extraction) still has its cabinets.
                if !adopted, !knownRoots.isEmpty, storedInstall(dll: dll, bits: bits, store: store) == nil {
                    adopted = true
                    let part = adoptKnownCabinets(for: exe, roots: knownRoots, store: store, tool: tool)
                    if part.cabinetsSeen > 0 {
                        resolution.notes.append("redist: adopted \(part.installs.count) of \(part.cabinetsSeen) cabinets of the same game from its earlier extraction")
                    }
                }
                // D3DX-REDIST 17.11: a copy validated earlier (from any game's cabinet or from Microsoft's own
                // DirectX redistributable, DirectXRedist) serves a game that ships no cabinet.
                if let item = storedInstall(dll: dll, bits: bits, store: store) {
                    resolution.installs.append(item)
                    resolution.notes.append("redist: \(dll) \(bits)-bit \(item.version) sha256=\(item.sha256) from the validated store (\(item.cabinet))")
                    continue
                }
                resolution.missing.append(dll)
                resolution.notes.append("redist: \(dll) \(bits)-bit needed by \(exe.lastPathComponent): no Microsoft cabinet near the game")
                resolution.warnings.append(missingWarning(dll: dll))
                continue
            }
            do {
                let item = try install(from: cabinet, store: store, tool: tool)
                resolution.installs.append(item)
                resolution.notes.append("redist: \(dll) \(bits)-bit \(item.version) sha256=\(item.sha256) from \(item.cabinet)")
            } catch {
                resolution.notes.append("redist: \(dll) \(bits)-bit from \(cabinet.url.lastPathComponent) rejected: \(error)")
                resolution.warnings.append(String(format: L("The DirectX file %@ next to this game was not used: %@. The 3D picture may stay black."),
                                                  dll, "\(error)"))
            }
        }
        return resolution
    }
}
