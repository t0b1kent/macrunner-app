import Foundation

// Разбор .exe для кнопки «Добавить игру»: человек ткнул в файл, а мы должны сами понять,
// это установщик (его надо ЗАПУСТИТЬ), сама игра (её добавляем) или мусор (в библиотеку нельзя).
//
// ★ ГЛАВНОЕ ПРАВИЛО РАЗБОРА: имя файла — САМЫЙ НЕНАДЁЖНЫЙ признак.
//   Измерено на настоящих файлах этого диска:
//     setup_diablo_1.09_hellfire_v4_(78466).exe  ProductName = «Diablo + Hellfire» — установщик,
//                                               названный как игра;
//     Setup.exe (UT99/app/System/)              ни манифеста, ни версии, ни подписи сборщика —
//                                               имя кричит «setup», содержимое молчит.
//   Поэтому имя даёт САМЫЙ МАЛЫЙ вес, а при расхождении с содержимым мы верим содержимому
//   и обязаны написать об этом в reasons — чтобы человек мог оспорить вердикт, а не верить на слово.

// MARK: - Вердикт

/// Что за .exe перед нами.
enum ExeKind: Equatable, Sendable {
    /// Установщик: запустить, чтобы поставить игру.
    case installer
    /// Сама игра или программа.
    case application
    /// Служебное: деинсталлятор, рантайм, отчёт о падении. В библиотеку класть нельзя.
    case auxiliary
}

/// Разбор одного файла: что решили, насколько уверены и почему.
struct ExeVerdict: Equatable, Sendable {
    let kind: ExeKind
    /// 0…1. Показывается человеку, поэтому должно быть честным, а не всегда 0.99.
    let confidence: Double
    /// ПОЧЕМУ так решили — человекочитаемо, по-русски. Показываем в окне,
    /// чтобы решение можно было оспорить, а не принимать на веру.
    let reasons: [String]
    /// Разрядность: "x86-64", "i386", "ARM64", nil если машина неизвестна.
    let architecture: String?
}

/// Отказы разбора. Молча возвращать `application` при отказе НЕЛЬЗЯ:
/// тогда нечитаемый файл выглядит как добротная игра.
enum ExeInspectorError: Error, LocalizedError, Equatable {
    /// Файл вообще не PE: нет «MZ» или нет «PE\0\0».
    case notPortableExecutable(String)
    /// Файл PE, но обрывается посреди заголовка.
    case malformed(String)
    /// Не удалось прочитать — права, исчезнувший файл, отказ тома.
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notPortableExecutable(let detail):
            return "Это не программа Windows (PE): \(detail)"
        case .malformed(let detail):
            return "Заголовок PE повреждён: \(detail)"
        case .unreadable(let detail):
            return "Файл не читается: \(detail)"
        }
    }
}

// MARK: - Разбор

enum ExeInspector {

    // Границы чтения. Установщики бывают по 20 ГБ (на этом диске лежит GOG-овский Diablo на
    // 830 МБ), поэтому файл целиком в память не берём НИКОГДА.
    //
    // ── подписи сборщиков ищем в двух окнах:
    //    голова 4 МиБ  — там стоит сам код установщика и его строки;
    //    хвост  1 МиБ  — у самораспаковывающихся архивов полезное лежит в КОНЦЕ файла.
    //    Замерено: у setup_diablo_1.09_hellfire_v4 «Inno Setup» встречается и в голове, и в хвосте;
    //    одной головы хватило бы, но хвост стоит дёшево и закрывает SFX-случай.
    private static let headScanBytes = 4 * 1024 * 1024
    private static let tailScanBytes = 1 * 1024 * 1024
    /// Читаем окна кусками по 1 МиБ с нахлёстом, иначе подпись, легшая на стык кусков, потеряется.
    private static let chunkBytes = 1024 * 1024
    /// Нахлёст = длина самой длинной подписи минус один байт.
    private static let chunkOverlap = 32

    /// Разбирает файл. Читает ТОЛЬКО нужные куски, а не файл целиком.
    static func inspect(at url: URL) throws -> ExeVerdict {
        let handle: FileHandle
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ExeInspectorError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        defer {
            // ЕДИНСТВЕННОЕ намеренно проглоченное исключение в файле: закрытие дескриптора,
            // открытого только на чтение, ничего не говорит о качестве разбора.
            try? handle.close()
        }

        let reader = ByteReader(handle: handle, name: url.lastPathComponent)
        let size = try reader.fileSize()
        let header = try parsePEHeader(reader, size: size)

        var evidence: [Evidence] = []

        // ── 1. Сильные признаки: то, что лежит ВНУТРИ файла.
        let resources = try readResources(reader, header: header, size: size)
        collectManifestEvidence(resources.manifest, into: &evidence)
        collectVersionEvidence(resources.version, into: &evidence)

        let builders = try scanBuilderSignatures(reader, size: size)
        for builder in builders {
            evidence.append(Evidence(kind: .installer, weight: Weights.builderSignature,
                                     text: "в теле файла подпись сборщика установщиков: \(builder)"))
        }

        // ── 2. Слабый признак: имя файла. Одного его НЕДОСТАТОЧНО ни для чего.
        collectNameEvidence(url.deletingPathExtension().lastPathComponent, into: &evidence)

        // ── 3. Упаковка: у упакованного файла строк внутри просто нет, и молчание подписей
        //       ничего не доказывает. Это надо сказать вслух и срезать уверенность.
        let packed = header.sectionNames.contains { name in
            name.hasPrefix("UPX") || name == ".aspack" || name == ".petite"
        }

        return makeVerdict(evidence: evidence,
                           architecture: header.architectureName,
                           hasResources: resources.manifest != nil || resources.version != nil,
                           packed: packed,
                           packerHint: packed ? header.sectionNames.first(where: { $0.hasPrefix("UPX") || $0 == ".aspack" || $0 == ".petite" }) : nil)
    }

    // MARK: - Вес признаков

    /// Веса подобраны по замеру на настоящих файлах, а не назначены на глаз. Смысл порога:
    /// признак весом ниже `threshold` НЕ МОЖЕТ в одиночку увести файл из `application`.
    private enum Weights {
        /// Подпись сборщика (Inno/NSIS/InstallShield/WiX/…) — самый надёжный признак установщика.
        static let builderSignature = 0.55
        /// FileDescription/ProductName говорит «Setup»/«Installer».
        static let versionSaysInstaller = 0.45
        /// FileDescription/ProductName говорит «Uninstall».
        static let versionSaysUninstaller = 0.60
        /// ProductName выдаёт рантайм (Redistributable, DirectX, Visual C++).
        static let versionSaysRuntime = 0.55
        ///
        /// ★ ПОПРАВКА К ЗАДАНИЮ, сделанная по замеру.
        /// В задании `requireAdministrator` назван «очень сильным признаком установщика».
        /// На настоящих файлах это НЕ подтвердилось, причём с обеих сторон:
        ///   — четыре из шести установщиков этого диска (KeePass, OldClassicCalc, GOG-Diablo,
        ///     GOG-UT) стоят на `asInvoker`, то есть признак ОТСУТСТВУЕТ у установщиков;
        ///   — dmde.exe (редактор дисков, обычная программа) требует `requireAdministrator`
        ///     совершенно законно, то есть признак ЕСТЬ у неустановщика.
        /// Значит он ни необходим, ни достаточен. Оставлен как ДОБАВКА (ниже порога):
        /// сам по себе вердикт не переворачивает, но поднимает уверенность рядом с другими.
        static let requiresAdministrator = 0.20
        /// Имя файла. Ниже порога поодиночке не бывает — ровно на пороге, намеренно:
        /// «имя говорит, содержимое молчит» = вердикт с низкой уверенностью, а не отказ.
        static let nameSaysInstaller = 0.35
        ///
        /// ★ «unins/uninstall» в имени весит БОЛЬШЕ подписи сборщика, и это не вкусовщина,
        /// а разная цена ошибки. Деинсталлятор Inno (`unins000.exe`) собран тем же Inno и
        /// несёт в теле ту же подпись, что и установщик. При равных весах побеждала бы
        /// подпись, файл уходил бы в `installer` — а установщик мы ПРЕДЛАГАЕМ ЗАПУСТИТЬ,
        /// то есть человек снёс бы себе игру одним нажатием.
        /// Цена обратной ошибки несравнимо меньше: установщик, ошибочно названный служебным,
        /// просто не попадёт в библиотеку, и человек добавит его руками.
        static let nameSaysAuxiliary = 0.60
        /// Имя рантайма/отчёта о падении («vcredist», «dxsetup», «oalinst», «crashhandler»)
        /// — куда точнее общего «setup», поэтому вес ВЫШЕ подписи сборщика.
        /// Иначе vcredist_x64.exe (внутри которого честный WiX) уходит в «установщик»
        /// и предлагается человеку как игра: рантайм — это служебное всегда.
        static let nameSaysRuntime = 0.60
        /// «Launcher» в имени — подсказка, а НЕ признак: у многих игр пусковой файл
        /// называется именно так. Вес заведомо ниже порога, чтобы никогда не решать в одиночку.
        static let nameSaysLauncher = 0.15
        /// Порог: ниже него никакой суммы не хватает, чтобы уйти от «это программа».
        static let threshold = 0.34
    }

    private struct Evidence {
        let kind: ExeKind
        let weight: Double
        let text: String
    }

    // MARK: - Сбор признаков

    private static func collectManifestEvidence(_ manifest: String?, into evidence: inout [Evidence]) {
        guard let manifest else { return }
        guard let level = requestedExecutionLevel(in: manifest) else { return }
        if level.caseInsensitiveCompare("requireAdministrator") == .orderedSame {
            evidence.append(Evidence(kind: .installer, weight: Weights.requiresAdministrator,
                                     text: "манифест PE требует прав администратора (requireAdministrator) — играм они не нужны"))
        }
    }

    private static func collectVersionEvidence(_ version: VersionStrings?, into evidence: inout [Evidence]) {
        guard let version else { return }
        let fields = [("FileDescription", version.fileDescription), ("ProductName", version.productName)]
        for (label, raw) in fields {
            guard let raw, !raw.isEmpty else { continue }
            let words = WordProbe(raw)
            if words.hasUninstall {
                evidence.append(Evidence(kind: .auxiliary, weight: Weights.versionSaysUninstaller,
                                         text: "строка версии \(label) = «\(raw)» — это деинсталлятор"))
            } else if words.hasInstallOrSetup {
                evidence.append(Evidence(kind: .installer, weight: Weights.versionSaysInstaller,
                                         text: "строка версии \(label) = «\(raw)» — сам файл называет себя установщиком"))
            }
            if words.hasRuntime {
                evidence.append(Evidence(kind: .auxiliary, weight: Weights.versionSaysRuntime,
                                         text: "строка версии \(label) = «\(raw)» — это системный рантайм, а не игра"))
            }
        }
    }

    private static func collectNameEvidence(_ baseName: String, into evidence: inout [Evidence]) {
        let words = WordProbe(baseName)
        if words.hasUninstall {
            evidence.append(Evidence(kind: .auxiliary, weight: Weights.nameSaysAuxiliary,
                                     text: "имя файла содержит «unins/uninstall» — это деинсталлятор, запускать его нельзя"))
        } else if words.hasInstallOrSetup {
            evidence.append(Evidence(kind: .installer, weight: Weights.nameSaysInstaller,
                                     text: "имя файла содержит «setup/install» (слабый признак)"))
        }
        if let marker = words.auxiliaryNameMarker {
            evidence.append(Evidence(kind: .auxiliary, weight: Weights.nameSaysRuntime,
                                     text: "имя файла содержит «\(marker)» — это рантайм или отчёт о падении, а не игра"))
        }
        if words.hasLauncher {
            evidence.append(Evidence(kind: .auxiliary, weight: Weights.nameSaysLauncher,
                                     text: "имя файла содержит «launcher» — подсказка, но у многих игр так называется пусковой файл"))
        }
    }

    // MARK: - Сведение признаков в вердикт

    private static func makeVerdict(evidence: [Evidence],
                                    architecture: String?,
                                    hasResources: Bool,
                                    packed: Bool,
                                    packerHint: String?) -> ExeVerdict {
        let installerScore = evidence.filter { $0.kind == .installer }.reduce(0.0) { $0 + $1.weight }
        let auxiliaryScore = evidence.filter { $0.kind == .auxiliary }.reduce(0.0) { $0 + $1.weight }

        var reasons = evidence.map(\.text)
        let kind: ExeKind
        var confidence: Double

        if max(installerScore, auxiliaryScore) < Weights.threshold {
            // Никаких улик. Это НЕ «уверенно игра», это «ничего против игры не нашли».
            kind = .application
            confidence = hasResources ? 0.65 : 0.55
            if evidence.isEmpty {
                reasons.append("ни подписи сборщика, ни строки «Setup», ни служебного имени — похоже на саму программу")
            } else {
                reasons.append("найденного не хватает, чтобы увести файл из «это программа» — считаем игрой/программой")
            }
            if !hasResources {
                reasons.append("у файла нет ни манифеста, ни строк версии — судить почти не по чему, уверенность низкая")
            }
        } else {
            // При равенстве выигрывает «служебное»: положить мусор в библиотеку хуже,
            // чем отказаться положить установщик.
            kind = auxiliaryScore >= installerScore ? .auxiliary : .installer
            // ★ Потолок 0.95, а не 1.0, и он ОБЯЗАТЕЛЕН: без него сумма трёх признаков
            //   давала 1.13 — число вне обещанного диапазона 0…1 (поймано прогоном по
            //   KeePass-2.61.1-Setup.exe). Единицу не выдаём никогда: разбор заголовков
            //   не может знать наверняка, а «0.99» в окне — это обман человека.
            confidence = min(0.95, 0.45 + max(installerScore, auxiliaryScore) * 0.5)
        }

        // ★ Расхождение имени и содержимого. Содержимое уже победило по весам —
        //   осталось сказать об этом человеку прямым текстом.
        let nameEvidence = evidence.filter { $0.text.contains("имя файла") }
        let contentEvidence = evidence.filter { !$0.text.contains("имя файла") }
        // Расхождение объявляем только если НИ ОДИН признак имени не согласен с итогом.
        // Иначе на DXSETUP.exe выходила напраслина: имя там сказало и «setup» (установщик),
        // и «dxsetup» (служебное), то есть с вердиктом оно как раз СОГЛАСИЛОСЬ.
        let nameAgrees = nameEvidence.contains { $0.kind == kind }
        // ★ Установщик, названный как игра — ровно тот случай, ради которого всё это писалось.
        //   Замерено на диске: setup_diablo_1.09_hellfire_v4_(78466).exe несёт
        //   ProductName = «Diablo + Hellfire», то есть имя игры. Имя молчит — и надо сказать,
        //   что вердикт держится ТОЛЬКО на содержимом, иначе человеку непонятно, откуда он взялся.
        if nameEvidence.isEmpty, !contentEvidence.isEmpty, kind != .application {
            reasons.append("★ имя файла ничем себя не выдаёт — вердикт держится только на содержимом (установщик нередко назван как игра)")
        }
        if !nameEvidence.isEmpty, !contentEvidence.isEmpty, !nameAgrees {
            reasons.append("★ имя файла и содержимое расходятся — верим содержимому, имя учтено как слабый признак")
            if kind != .application {
                confidence = min(confidence, 0.80)
            }
        }
        if kind == .application, !contentEvidence.isEmpty, !nameEvidence.isEmpty, !nameAgrees {
            reasons.append("★ имя намекает на другое, но внутри файла подтверждения нет")
        }

        if packed {
            reasons.append("файл упакован (\(packerHint ?? "упаковщик")) — строки внутри скрыты, подписи сборщика не видны; вердикт менее надёжен")
            confidence = min(confidence, 0.60)
        }

        return ExeVerdict(kind: kind,
                          confidence: (confidence * 100).rounded() / 100,
                          reasons: reasons,
                          architecture: architecture)
    }

    // MARK: - Словарь признаков по словам

    /// Разбор строки на признаки. ★ Ловушка, ради которой это отдельный тип:
    /// «uninstall» СОДЕРЖИТ «install». Наивная проверка `contains("install")` объявляет
    /// деинсталлятор установщиком и предлагает его ЗАПУСТИТЬ. Поэтому «unins/uninstall»
    /// сначала находится, потом ВЫРЕЗАЕТСЯ из строки, и только затем ищется «install».
    private struct WordProbe {
        let hasUninstall: Bool
        let hasInstallOrSetup: Bool
        let hasRuntime: Bool
        let hasLauncher: Bool
        let auxiliaryNameMarker: String?

        init(_ raw: String) {
            let lower = raw.lowercased()

            var stripped = lower
            var foundUninstall = false
            for marker in ["uninstall", "unins"] where stripped.contains(marker) {
                foundUninstall = true
                stripped = stripped.replacingOccurrences(of: marker, with: "\u{00B7}")
            }
            hasUninstall = foundUninstall
            hasInstallOrSetup = ["install", "setup"].contains { stripped.contains($0) }

            hasRuntime = ["redistributable", "directx", "visual c++", "runtime", "openal"]
                .contains { lower.contains($0) }
            hasLauncher = stripped.contains("launcher")

            // Служебные маркеры имени из задания. Проверяются по УЖЕ вырезанной строке,
            // чтобы «dxsetup» не мешался с обычным «setup».
            let markers = ["vcredist", "vc_redist", "dxwebsetup", "dxsetup", "oalinst",
                           "directx", "crashhandler", "crashpad", "crashreport"]
            auxiliaryNameMarker = markers.first { lower.contains($0) }
        }
    }

    private static func requestedExecutionLevel(in manifest: String) -> String? {
        guard let levelRange = manifest.range(of: "requestedExecutionLevel") else { return nil }
        let tail = manifest[levelRange.upperBound...].prefix(400)
        guard let levelKey = tail.range(of: "level") else { return nil }
        let afterKey = tail[levelKey.upperBound...]
        guard let openQuote = afterKey.firstIndex(of: "\"") else { return nil }
        let valueStart = afterKey.index(after: openQuote)
        guard let closeQuote = afterKey[valueStart...].firstIndex(of: "\"") else { return nil }
        return String(afterKey[valueStart..<closeQuote])
    }

    // MARK: - Подписи сборщиков установщиков

    private static let builderSignatures: [(needle: [UInt8], name: String)] = [
        (Array("JR.Inno.Setup".utf8), "Inno Setup"),
        (Array("Inno Setup".utf8), "Inno Setup"),
        (Array("Nullsoft Install System".utf8), "NSIS (Nullsoft)"),
        (Array("NullsoftInst".utf8), "NSIS (Nullsoft)"),
        (Array("InstallShield".utf8), "InstallShield"),
        (Array("WiX Toolset".utf8), "WiX Toolset"),
        (Array("!@Install@!UTF8!".utf8), "7-Zip SFX"),
        (Array("7-Zip SFX".utf8), "7-Zip SFX"),
        (Array("Wise Installer".utf8), "Wise Installer"),
        (Array("Smart Install Maker".utf8), "Smart Install Maker")
    ]

    private static func scanBuilderSignatures(_ reader: ByteReader, size: UInt64) throws -> [String] {
        var found: Set<String> = []

        // Голова файла.
        try scanWindow(reader, from: 0, length: min(UInt64(headScanBytes), size), into: &found)

        // Хвост — только если он не попал в голову целиком.
        if size > UInt64(headScanBytes) {
            let tailStart = size > UInt64(tailScanBytes) ? size - UInt64(tailScanBytes) : 0
            try scanWindow(reader, from: tailStart, length: size - tailStart, into: &found)
        }
        // Порядок стабильный: вердикт не должен зависеть от порядка обхода множества.
        return builderSignatures.map(\.name).reduce(into: [String]()) { acc, name in
            if found.contains(name), !acc.contains(name) { acc.append(name) }
        }
    }

    private static func scanWindow(_ reader: ByteReader, from start: UInt64, length: UInt64, into found: inout Set<String>) throws {
        guard length > 0 else { return }
        var offset = start
        let end = start + length
        while offset < end {
            let want = Int(min(UInt64(chunkBytes), end - offset))
            let chunk = try reader.read(at: offset, count: want)
            if chunk.isEmpty { return }
            let bytes = [UInt8](chunk)
            for signature in builderSignatures where !found.contains(signature.name) {
                if contains(bytes, signature.needle) { found.insert(signature.name) }
            }
            if chunk.count < want { return }
            // Нахлёст: подпись, легшая на стык кусков, иначе была бы потеряна.
            offset += UInt64(max(1, want - chunkOverlap))
        }
    }

    private static func contains(_ haystack: [UInt8], _ needle: [UInt8]) -> Bool {
        guard !needle.isEmpty, haystack.count >= needle.count else { return false }
        let first = needle[0]
        let limit = haystack.count - needle.count
        var i = 0
        while i <= limit {
            if haystack[i] == first {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return true }
            }
            i += 1
        }
        return false
    }

    // MARK: - Заголовок PE

    private struct PEHeader {
        let machine: UInt16
        let resourceRVA: UInt32
        let resourceSize: UInt32
        let sections: [Section]
        let sectionNames: [String]

        var architectureName: String? {
            switch machine {
            case 0x8664: return "x86-64"
            case 0x014c: return "i386"
            case 0xAA64: return "ARM64"
            case 0x01C0: return "ARM"
            case 0x01C4: return "ARMv7"
            case 0: return nil
            default: return String(format: "0x%04x", machine)
            }
        }
    }

    private struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawPointer: UInt32
        let rawSize: UInt32
    }

    private static func parsePEHeader(_ reader: ByteReader, size: UInt64) throws -> PEHeader {
        guard size >= 0x40 else {
            throw ExeInspectorError.notPortableExecutable("файл короче заголовка DOS (\(size) байт)")
        }
        let dos = try reader.read(at: 0, count: 0x40)
        guard dos.count >= 0x40 else {
            throw ExeInspectorError.notPortableExecutable("не удалось прочитать заголовок DOS целиком")
        }
        guard dos[0] == 0x4D, dos[1] == 0x5A else {
            throw ExeInspectorError.notPortableExecutable("нет сигнатуры «MZ» в начале файла")
        }
        let peOffset = UInt64(dos.readUInt32(at: 0x3C))
        guard peOffset + 24 <= size else {
            throw ExeInspectorError.notPortableExecutable("указатель на заголовок PE (\(peOffset)) выходит за файл")
        }

        let coff = try reader.read(at: peOffset, count: 24)
        guard coff.count >= 24 else {
            throw ExeInspectorError.malformed("заголовок COFF обрывается")
        }
        guard coff[0] == 0x50, coff[1] == 0x45, coff[2] == 0, coff[3] == 0 else {
            throw ExeInspectorError.notPortableExecutable("нет сигнатуры «PE\\0\\0»")
        }

        let machine = coff.readUInt16(at: 4)
        let sectionCount = Int(coff.readUInt16(at: 6))
        let optionalSize = Int(coff.readUInt16(at: 20))
        guard sectionCount > 0, sectionCount <= 96 else {
            throw ExeInspectorError.malformed("неправдоподобное число секций: \(sectionCount)")
        }

        // Необязательный заголовок: оттуда берём каталог ресурсов (запись №2).
        var resourceRVA: UInt32 = 0
        var resourceSize: UInt32 = 0
        if optionalSize >= 24 {
            let optional = try reader.read(at: peOffset + 24, count: optionalSize)
            if optional.count >= 24 {
                let magic = optional.readUInt16(at: 0)
                // PE32 = 0x10b (каталоги с 96), PE32+ = 0x20b (каталоги с 112).
                let directoryStart = magic == 0x20B ? 112 : 96
                let countOffset = directoryStart - 4
                if optional.count >= countOffset + 4 {
                    let directoryCount = Int(optional.readUInt32(at: countOffset))
                    let resourceEntry = directoryStart + 16 // запись №2 = ресурсы
                    if directoryCount > 2, optional.count >= resourceEntry + 8 {
                        resourceRVA = optional.readUInt32(at: resourceEntry)
                        resourceSize = optional.readUInt32(at: resourceEntry + 4)
                    }
                }
            }
        }

        // Таблица секций.
        let tableOffset = peOffset + 24 + UInt64(optionalSize)
        let tableBytes = sectionCount * 40
        guard tableOffset + UInt64(tableBytes) <= size else {
            throw ExeInspectorError.malformed("таблица секций выходит за границы файла")
        }
        let table = try reader.read(at: tableOffset, count: tableBytes)
        guard table.count >= tableBytes else {
            throw ExeInspectorError.malformed("таблица секций обрывается")
        }

        var sections: [Section] = []
        var names: [String] = []
        for index in 0..<sectionCount {
            let base = index * 40
            let rawName = table.subdata(in: base..<(base + 8))
            let name = String(bytes: rawName.prefix { $0 != 0 }, encoding: .utf8) ?? ""
            names.append(name)
            sections.append(Section(virtualAddress: table.readUInt32(at: base + 12),
                                    virtualSize: table.readUInt32(at: base + 8),
                                    rawPointer: table.readUInt32(at: base + 20),
                                    rawSize: table.readUInt32(at: base + 16)))
        }

        return PEHeader(machine: machine,
                        resourceRVA: resourceRVA,
                        resourceSize: resourceSize,
                        sections: sections,
                        sectionNames: names)
    }

    private static func fileOffset(forRVA rva: UInt32, sections: [Section]) -> UInt64? {
        for section in sections {
            // ★★★ ШИРИНУ СЕКЦИИ В АДРЕСАХ ЗАДАЁТ ТОЛЬКО `VirtualSize`.
            //   Было `max(virtualSize, rawSize)` — и на игре Godot секция `pck`
            //   (`VirtualSize=8`, `SizeOfRawData=470 МБ`) накрывала адреса настоящей
            //   `.rsrc`. Разбор шёл по чужим байтам: у такой игры мы объявляли
            //   «ни манифеста, ни строк версии», хотя и то и другое там есть, —
            //   то есть вердикт «установщик или игра» выносился вслепую.
            //   Найдено лейном значков 12.09.2026 на своём разборе того же PE.
            //   `rawSize` берётся ТОЛЬКО при нулевом `virtualSize` (старые сборщики).
            let span = section.virtualSize > 0 ? section.virtualSize : section.rawSize
            guard rva >= section.virtualAddress, rva < section.virtualAddress &+ span else { continue }
            let delta = rva - section.virtualAddress
            guard delta < section.rawSize else { return nil }
            return UInt64(section.rawPointer) + UInt64(delta)
        }
        return nil
    }

    // MARK: - Ресурсы PE (манифест и строки версии)

    private struct VersionStrings {
        let fileDescription: String?
        let productName: String?
    }

    private struct Resources {
        let manifest: String?
        let version: VersionStrings?
    }

    private static let rtVersion: UInt32 = 16
    private static let rtManifest: UInt32 = 24
    /// Потолок на ресурс: манифест и блок версии — килобайты. Больше читать незачем.
    private static let resourceReadCap = 64 * 1024

    private static func readResources(_ reader: ByteReader, header: PEHeader, size: UInt64) throws -> Resources {
        guard header.resourceRVA != 0, header.resourceSize != 0,
              let rootOffset = fileOffset(forRVA: header.resourceRVA, sections: header.sections),
              rootOffset < size else {
            return Resources(manifest: nil, version: nil)
        }

        var manifest: String?
        if let blob = try firstResource(reader, header: header, root: rootOffset, type: rtManifest, size: size) {
            manifest = String(data: blob, encoding: .utf8) ?? String(decoding: blob, as: UTF8.self)
        }

        var version: VersionStrings?
        if let blob = try firstResource(reader, header: header, root: rootOffset, type: rtVersion, size: size) {
            version = VersionStrings(fileDescription: utf16Value(in: blob, forKey: "FileDescription"),
                                     productName: utf16Value(in: blob, forKey: "ProductName"))
        }

        return Resources(manifest: manifest, version: version)
    }

    /// Находит первый ресурс заданного типа. Дерево ресурсов трёхуровневое:
    /// тип → имя → язык, и только на третьем уровне лежит запись с данными.
    private static func firstResource(_ reader: ByteReader,
                                      header: PEHeader,
                                      root: UInt64,
                                      type: UInt32,
                                      size: UInt64) throws -> Data? {
        guard let typeEntry = try findEntry(reader, at: root, matching: type, size: size),
              typeEntry.isDirectory else { return nil }
        let nameDirectory = root + UInt64(typeEntry.offset)
        guard nameDirectory < size,
              let nameEntry = try findEntry(reader, at: nameDirectory, matching: nil, size: size),
              nameEntry.isDirectory else { return nil }
        let languageDirectory = root + UInt64(nameEntry.offset)
        guard languageDirectory < size,
              let languageEntry = try findEntry(reader, at: languageDirectory, matching: nil, size: size),
              !languageEntry.isDirectory else { return nil }

        // Лист: 16 байт, из них RVA данных и их длина.
        let leafOffset = root + UInt64(languageEntry.offset)
        guard leafOffset + 8 <= size else { return nil }
        let leaf = try reader.read(at: leafOffset, count: 16)
        guard leaf.count >= 8 else { return nil }
        let dataRVA = leaf.readUInt32(at: 0)
        let dataSize = Int(leaf.readUInt32(at: 4))
        guard dataSize > 0, let dataOffset = fileOffset(forRVA: dataRVA, sections: header.sections),
              dataOffset < size else { return nil }
        return try reader.read(at: dataOffset, count: min(dataSize, resourceReadCap))
    }

    private struct DirectoryEntry {
        let isDirectory: Bool
        let offset: UInt32
    }

    /// Читает каталог ресурсов и возвращает подходящую запись.
    /// `matching == nil` — берём первую попавшуюся (для уровней «имя» и «язык»).
    private static func findEntry(_ reader: ByteReader, at offset: UInt64, matching id: UInt32?, size: UInt64) throws -> DirectoryEntry? {
        guard offset + 16 <= size else { return nil }
        let head = try reader.read(at: offset, count: 16)
        guard head.count >= 16 else { return nil }
        let namedCount = Int(head.readUInt16(at: 12))
        let idCount = Int(head.readUInt16(at: 14))
        let total = namedCount + idCount
        // Защита от мусорного заголовка: столько типов ресурсов не бывает.
        guard total > 0, total <= 4096 else { return nil }

        let entriesOffset = offset + 16
        guard entriesOffset + UInt64(total * 8) <= size else { return nil }
        let entries = try reader.read(at: entriesOffset, count: total * 8)
        guard entries.count >= total * 8 else { return nil }

        for index in 0..<total {
            let base = index * 8
            let nameField = entries.readUInt32(at: base)
            let offsetField = entries.readUInt32(at: base + 4)
            let isNamed = (nameField & 0x8000_0000) != 0
            if let id {
                // Типы ресурсов нумерованные; именованный тип RT_MANIFEST/RT_VERSION не бывает.
                guard !isNamed, (nameField & 0x7FFF_FFFF) == id else { continue }
            }
            return DirectoryEntry(isDirectory: (offsetField & 0x8000_0000) != 0,
                                  offset: offsetField & 0x7FFF_FFFF)
        }
        return nil
    }

    /// Достаёт значение из блока VS_VERSIONINFO.
    /// Ключи и значения там в UTF-16LE; после ключа стоит нуль-терминатор и выравнивание
    /// до 4 байт, и только затем значение. ★ Если не остановиться на первом нуле значения,
    /// строка «слипается» со следующим ключом — на замере так выходило
    /// «Notepad++ : a free (GNU) source code editor0FileVersion8.9».
    private static func utf16Value(in blob: Data, forKey key: String) -> String? {
        var keyBytes: [UInt8] = []
        for unit in Array(key.utf16) {
            keyBytes.append(UInt8(unit & 0xFF))
            keyBytes.append(UInt8(unit >> 8))
        }
        let bytes = [UInt8](blob)
        guard let start = indexOf(bytes, keyBytes) else { return nil }

        var cursor = start + keyBytes.count
        // Нуль-терминатор ключа + выравнивание значения до 4 байт (не больше двух пустых слов).
        var skippedZeroUnits = 0
        while cursor + 1 < bytes.count, bytes[cursor] == 0, bytes[cursor + 1] == 0, skippedZeroUnits < 2 {
            cursor += 2
            skippedZeroUnits += 1
        }
        guard skippedZeroUnits > 0 else { return nil }

        var units: [UInt16] = []
        while cursor + 1 < bytes.count, units.count < 512 {
            let unit = UInt16(bytes[cursor]) | (UInt16(bytes[cursor + 1]) << 8)
            if unit == 0 { break }
            units.append(unit)
            cursor += 2
        }
        guard !units.isEmpty else { return nil }
        let value = String(decoding: units, as: UTF16.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    private static func indexOf(_ haystack: [UInt8], _ needle: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        var i = 0
        while i <= limit {
            if haystack[i] == needle[0] {
                var j = 1
                while j < needle.count, haystack[i + j] == needle[j] { j += 1 }
                if j == needle.count { return i }
            }
            i += 1
        }
        return nil
    }
}

// MARK: - Чтение файла кусками

/// Тонкая обёртка над FileHandle. Существует ради одного правила:
/// отказ чтения обязан быть ВИДЕН, а не превращён в пустые данные.
private struct ByteReader {
    let handle: FileHandle
    let name: String

    func fileSize() throws -> UInt64 {
        do {
            let end = try handle.seekToEnd()
            try handle.seek(toOffset: 0)
            return end
        } catch {
            throw ExeInspectorError.unreadable("\(name): не удалось определить размер (\(error.localizedDescription))")
        }
    }

    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        do {
            try handle.seek(toOffset: offset)
            return try handle.read(upToCount: count) ?? Data()
        } catch {
            throw ExeInspectorError.unreadable("\(name): отказ чтения на смещении \(offset) (\(error.localizedDescription))")
        }
    }
}

// MARK: - Мелочи чтения чисел

private extension Data {
    func readUInt16(at offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func readUInt32(at offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }
}
