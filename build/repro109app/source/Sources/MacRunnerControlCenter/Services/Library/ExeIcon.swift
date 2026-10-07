import CoreGraphics
import CryptoKit
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Значок для плитки библиотеки берём ИЗ САМОГО .exe — из ресурсов PE.
//
// ★ ЗАЧЕМ ИМЕННО ТАК. Ручной каталог «игра → картинка» задачу не решает в принципе:
//   установленные сегодня можно подставить руками, а те, что человек поставит завтра,
//   в каталоге не окажутся и снова дадут серый прямоугольник. Значок же лежит ВНУТРИ
//   исполняемого файла у любой виндовой программы — оттуда он подтягивается сам,
//   без каталога, без сети и без чужих ключей.
//
// ★ ЧЕГО ЗДЕСЬ НЕТ (границы честные, см. также отчёт):
//   · значок, лежащий в отдельном .dll рядом с игрой, — мы смотрим только в сам .exe;
//   · однофайловые сборки .NET — там настоящий образ распаковывается в рантайме;
//   · ресурсы со сжатием (biCompression != BI_RGB: BI_JPEG/BI_PNG/BI_BITFIELDS);
//   · упакованный файл, у которого ресурсы УБРАНЫ в сжатый образ.
//   Каждый случай даёт НАЗВАННЫЙ отказ, а не тихую пустую картинку.
//
// ★ А вот «упакованные .exe не поддерживаются» — НЕВЕРНО, и это ИЗМЕРЕНО, а не предположено.
//   Упаковщики оставляют `.rsrc` нетронутой, чтобы значок показывал сам проводник Windows.
//   На этом диске единственный упакованный файл — `DiabloLauncher.exe` (секции UPX0, UPX1,
//   .rsrc), и значок из него достаётся штатно: 256×256, группа «IDI_ICON1».
//   Отказ будет только у того упаковщика, который ресурсы всё же прячет.

// MARK: - Ошибки

/// Отказы извлечения. Каждый НАЗВАН по имени: серый прямоугольник в библиотеке обязан
/// объясняться строкой, иначе «значка нет» не отличить от «разбор сломался».
enum ExeIconError: LocalizedError, Equatable {
    /// Файл вообще не PE: нет «MZ», нет «PE\0\0», неизвестный вид опционального заголовка.
    case notPE(String)
    /// PE разобран, но каталога ресурсов (запись №2) в нём нет.
    case noResourceDirectory
    /// Ресурсы есть, значка среди них нет. Обычное дело для консольных утилит.
    case noIconResource
    /// Значок найден, но содержимое разобрать не удалось (битый DIB, чужое сжатие).
    case unreadableIcon(String)
    /// Файл не читается: права, исчез, отказ тома.
    case unreadable(String)

    var errorDescription: String? {
        switch self {
        case .notPE(let detail):
            return "Это не программа Windows (PE): \(detail)"
        case .noResourceDirectory:
            return "В файле нет таблицы ресурсов — значку негде лежать"
        case .noIconResource:
            return "В ресурсах файла нет значка"
        case .unreadableIcon(let detail):
            return "Значок найден, но не разобран: \(detail)"
        case .unreadable(let detail):
            return "Файл не читается: \(detail)"
        }
    }
}

/// Вид содержимого записи RT_ICON. Их ровно два, и путь разбора у них РАЗНЫЙ.
enum ExeIconPayload: String, Equatable, Sendable {
    /// Vista и новее: внутри ресурса лежит готовый PNG (обычно 256×256).
    case png = "PNG"
    /// Классика: BITMAPINFOHEADER + XOR-картинка + AND-маска.
    case dib = "DIB"
}

/// Что именно нашли и выбрали. Нужен для проверки прибора: без этих чисел
/// «значок разобрался» ничего не доказывает — удвоенная высота тоже «разбирается».
struct ExeIconProbe: Equatable, Sendable {
    /// Сколько групп значков (RT_GROUP_ICON) в файле.
    var groupCount: Int
    /// Какую группу взяли: «#1» или ««MAINICON»».
    var groupLabel: String
    /// Сколько размеров в выбранной группе.
    var entryCount: Int
    /// Размеры ГОТОВОЙ картинки, а не заявленные в GRPICONDIR.
    var width: Int
    var height: Int
    /// Бит на точку у исходного значка.
    var bitCount: Int
    var payload: ExeIconPayload
    var png: Data
}

// MARK: - Извлечение

enum ExeIcon {

    /// Достаёт лучший значок из `.exe` и отдаёт PNG.
    /// Ничего не найдено → `noIconResource`, а НЕ пустая картинка.
    static func bestIcon(at url: URL, preferredSize: Int = 256) throws -> Data {
        try probe(at: url, preferredSize: preferredSize).png
    }

    /// То же, но с кешем на диске: ключ — путь + запрошенный размер + время правки файла.
    /// Кеш в `~/Library/Caches/MacRunner/exe-icons/`.
    ///
    /// ★ ОТКАЗ ТОЖЕ КЛАДЁТСЯ В КЕШ (пустой файл `.none`). Без этого список библиотеки на
    ///   каждой перерисовке заново разбирал бы восьмисотмегабайтный установщик, чтобы
    ///   снова узнать, что значка в нём нет.
    @MainActor static func cachedIcon(at url: URL, preferredSize: Int = 256) -> Data? {
        let key = cacheKey(url: url, preferredSize: preferredSize)
        if let hit = memoryHits[key] { return hit }
        if memoryMisses.contains(key) { return nil }

        let picture = cacheRoot.appendingPathComponent(key + ".png")
        let refusal = cacheRoot.appendingPathComponent(key + ".none")

        if let cached = readCachedPNG(at: picture) {
            memoryHits[key] = cached
            return cached
        }
        if FileManager.default.fileExists(atPath: refusal.path) {
            memoryMisses.insert(key)
            return nil
        }

        do {
            let data = try bestIcon(at: url, preferredSize: preferredSize)
            store(data, at: picture)
            memoryHits[key] = data
            return data
        } catch {
            // Причину печатаем ВСЕГДА: «значка нет» и «разбор сломался» с виду одинаковы.
            complain("\(url.lastPathComponent): \(error.localizedDescription)")
            store(Data(), at: refusal)
            memoryMisses.insert(key)
            return nil
        }
    }

    /// Разбор с подробностями — им пользуются и `bestIcon`, и проверки.
    static func probe(at url: URL, preferredSize: Int = 256) throws -> ExeIconProbe {
        let wanted = min(max(preferredSize, 1), 1024)
        let reader = try IconReader(url: url)
        defer { reader.close() }

        let image = try parseHeader(reader)
        guard image.resourceRVA != 0, image.resourceSize != 0 else {
            throw ExeIconError.noResourceDirectory
        }
        // Таблица ОБЪЯВЛЕНА, но её байтов в файле нет — это не «значка нет», а обрезанный
        // либо упакованный файл (у UPX и сородичей ресурсы лежат в сжатом образе).
        // Путать эти два случая нельзя: у них разные причины и разные последствия.
        guard let root = image.fileOffset(forRVA: image.resourceRVA), root < reader.size else {
            throw ExeIconError.unreadableIcon(
                "таблица ресурсов объявлена по адресу 0x\(String(image.resourceRVA, radix: 16)), "
                + "но её байтов в файле нет — файл обрезан или упакован")
        }

        // Уровень «имя» под каждым из двух нужных типов.
        let groups = try nameLevel(reader, root: root, type: rtGroupIcon)
        let icons = try nameLevel(reader, root: root, type: rtIcon)
        guard !icons.isEmpty else { throw ExeIconError.noIconResource }

        // Номер значка из группы ищется среди RT_ICON по числовому id.
        var byID: [UInt32: ResEntry] = [:]
        for icon in icons where icon.name == nil { byID[icon.id] = icon }

        var candidates: [GroupEntry]
        var label: String
        if let group = mainGroup(groups) {
            label = group.name.map { "«\($0)»" } ?? "#\(group.id)"
            candidates = try groupEntries(reader, root: root, entry: group, image: image)
        } else {
            // Запасной путь: группы нет, а сами значки есть. Тогда размер и глубину
            // читаем из ЗАГОЛОВКА каждого значка — по 40 байт на запись, это дёшево.
            label = "без группы"
            candidates = try measuredEntries(reader, root: root, icons: icons, image: image)
        }
        guard !candidates.isEmpty else { throw ExeIconError.noIconResource }

        // Идём по предпочтению вниз: если у лучшей записи нет RT_ICON (бывает у битых
        // файлов), берём следующую, а не сдаёмся.
        var lastFailure: ExeIconError?
        for candidate in ranked(candidates, preferredSize: wanted) {
            guard let entry = byID[candidate.id],
                  let blob = try blob(reader, root: root, entry: entry, image: image) else { continue }
            let payload = try reader.read(at: blob.offset, count: blob.size)
            do {
                let picture = try decode(payload)
                return ExeIconProbe(groupCount: groups.count,
                                    groupLabel: label,
                                    entryCount: candidates.count,
                                    width: picture.width,
                                    height: picture.height,
                                    bitCount: picture.bitCount,
                                    payload: picture.kind,
                                    png: picture.png)
            } catch let error as ExeIconError {
                lastFailure = error
                continue
            }
        }
        throw lastFailure ?? ExeIconError.noIconResource
    }

    // MARK: - Заголовки PE

    private static let rtIcon: UInt32 = 3
    private static let rtGroupIcon: UInt32 = 14
    /// Потолок на один ресурс. 256×256 при 32 битах — 262 КБ вместе с маской,
    /// PNG-значок ещё меньше. Восемь мегабайт с запасом, но битый размер не пустит.
    private static let maxIconBytes = 8 * 1024 * 1024
    /// GRPICONDIR: 6 байт заголовка плюс 14 на запись. 64 КБ хватит на 4680 размеров.
    private static let maxGroupBytes = 64 * 1024
    /// Потолок на кешированный PNG: больше — считаем кеш битым.
    private static let maxCachedBytes = 8 * 1024 * 1024

    private struct Section {
        let virtualAddress: UInt32
        let virtualSize: UInt32
        let rawPointer: UInt32
        let rawSize: UInt32
    }

    private struct PEImage {
        let resourceRVA: UInt32
        let resourceSize: UInt32
        let sections: [Section]

        /// Адрес в образе → смещение в файле. В файле секции лежат по `PointerToRawData`,
        /// а RVA считается от `VirtualAddress` — без этого перевода читались бы чужие байты.
        ///
        /// ★★★ ЛОВУШКА, ПОЙМАННАЯ НА НАСТОЯЩЕЙ ИГРЕ («That's not my neighbor.exe», Godot,
        ///   556 МБ). Ширину секции в АДРЕСАХ задаёт ТОЛЬКО `VirtualSize`. Взять
        ///   `max(VirtualSize, SizeOfRawData)` — и секция `pck` с `VirtualSize=8`, но
        ///   `SizeOfRawData=0x1c1f2a10` (470 МБ данных игры, приклеенных к файлу)
        ///   накрывает собой весь остаток образа, включая настоящий `.rsrc` на
        ///   0x51a7000. Ресурсы тогда читаются из тела архива игры, и получается
        ///   «каталог ресурсов заявил 64450 записей» вместо значка.
        ///   `SizeOfRawData` берётся ТОЛЬКО когда `VirtualSize` равен нулю — так делали
        ///   старые компоновщики.
        func fileOffset(forRVA rva: UInt32) -> UInt64? {
            for section in sections {
                let span = section.virtualSize > 0 ? section.virtualSize : section.rawSize
                guard rva >= section.virtualAddress, rva < section.virtualAddress &+ span else { continue }
                let delta = rva - section.virtualAddress
                // Хвост секции, которого в файле нет (набивка нулями) — читать нечего.
                guard delta < section.rawSize else { return nil }
                return UInt64(section.rawPointer) + UInt64(delta)
            }
            return nil
        }
    }

    private static func parseHeader(_ reader: IconReader) throws -> PEImage {
        guard reader.size >= 0x40 else {
            throw ExeIconError.notPE("файл короче заголовка DOS (\(reader.size) Б)")
        }
        let dos = try reader.read(at: 0, count: 0x40)
        guard dos[dos.startIndex] == 0x4D, dos[dos.startIndex + 1] == 0x5A else {
            throw ExeIconError.notPE("нет сигнатуры «MZ» в начале файла")
        }

        let peOffset = UInt64(dos.u32(0x3C))
        guard peOffset >= 4, peOffset &+ 24 <= reader.size else {
            throw ExeIconError.notPE("указатель на заголовок PE (\(peOffset)) выходит за файл")
        }
        let coff = try reader.read(at: peOffset, count: 24)
        let base = coff.startIndex
        guard coff[base] == 0x50, coff[base + 1] == 0x45, coff[base + 2] == 0, coff[base + 3] == 0 else {
            throw ExeIconError.notPE("нет сигнатуры «PE\\0\\0» по указателю \(peOffset)")
        }

        let sectionCount = Int(coff.u16(6))
        let optionalSize = Int(coff.u16(20))
        guard sectionCount > 0, sectionCount <= 96 else {
            throw ExeIconError.notPE("неправдоподобное число секций: \(sectionCount)")
        }
        // Каталог данных живёт в опциональном заголовке. Нет его — нет и ресурсов.
        guard optionalSize >= 96 else { throw ExeIconError.noResourceDirectory }

        let optional = try reader.read(at: peOffset + 24, count: optionalSize)
        let magic = optional.u16(0)
        // ★ PE32 (0x10B) и PE32+ (0x20B) отличаются РАЗМЕРОМ полей адресов, поэтому
        //   таблица каталогов данных у них начинается на РАЗНЫХ смещениях. Спутать —
        //   значит прочитать чужую запись и объявить «ресурсов нет».
        let directoryStart: Int
        switch magic {
        case 0x10B: directoryStart = 96
        case 0x20B: directoryStart = 112
        default: throw ExeIconError.notPE("неизвестный вид опционального заголовка 0x\(String(magic, radix: 16))")
        }

        var resourceRVA: UInt32 = 0
        var resourceSize: UInt32 = 0
        let countOffset = directoryStart - 4              // NumberOfRvaAndSizes
        let resourceEntry = directoryStart + 16           // запись №2 = IMAGE_DIRECTORY_ENTRY_RESOURCE
        if optionalSize >= countOffset + 4 {
            let directoryCount = Int(optional.u32(countOffset))
            if directoryCount > 2, optionalSize >= resourceEntry + 8 {
                resourceRVA = optional.u32(resourceEntry)
                resourceSize = optional.u32(resourceEntry + 4)
            }
        }

        let tableOffset = peOffset + 24 + UInt64(optionalSize)
        let tableBytes = sectionCount * 40
        guard tableOffset + UInt64(tableBytes) <= reader.size else {
            throw ExeIconError.notPE("таблица секций выходит за границы файла")
        }
        let table = try reader.read(at: tableOffset, count: tableBytes)

        var sections: [Section] = []
        sections.reserveCapacity(sectionCount)
        for index in 0..<sectionCount {
            let entry = index * 40
            sections.append(Section(virtualAddress: table.u32(entry + 12),
                                    virtualSize: table.u32(entry + 8),
                                    rawPointer: table.u32(entry + 20),
                                    rawSize: table.u32(entry + 16)))
        }
        return PEImage(resourceRVA: resourceRVA, resourceSize: resourceSize, sections: sections)
    }

    // MARK: - Дерево ресурсов

    /// Запись каталога ресурсов. Дерево трёхуровневое: тип → имя → язык,
    /// и только на третьем уровне лежит лист с данными.
    private struct ResEntry {
        let id: UInt32
        /// Заполнено, если запись ИМЕНОВАННАЯ. У приложений Delphi группа значков
        /// называется «MAINICON» — считать имена обязательно, иначе их значок не найдётся.
        let name: String?
        let isDirectory: Bool
        /// Смещение от НАЧАЛА дерева ресурсов, не от начала файла.
        let offset: UInt32
    }

    private struct Blob {
        let offset: UInt64
        let size: Int
    }

    private static func directory(_ reader: IconReader, root: UInt64, at offset: UInt64) throws -> [ResEntry] {
        guard offset &+ 16 <= reader.size else { return [] }
        let head = try reader.read(at: offset, count: 16)
        let named = Int(head.u16(12))
        let numbered = Int(head.u16(14))
        let total = named + numbered
        guard total > 0 else { return [] }
        guard total <= 4096 else {
            throw ExeIconError.unreadableIcon("каталог ресурсов заявил \(total) записей — это мусор")
        }
        guard offset + 16 + UInt64(total * 8) <= reader.size else { return [] }
        let raw = try reader.read(at: offset + 16, count: total * 8)

        var result: [ResEntry] = []
        result.reserveCapacity(total)
        for index in 0..<total {
            let entry = index * 8
            let nameField = raw.u32(entry)
            let offsetField = raw.u32(entry + 4)
            let isNamed = (nameField & 0x8000_0000) != 0
            let value = nameField & 0x7FFF_FFFF
            var name: String?
            if isNamed { name = try resourceName(reader, root: root, offset: value) }
            result.append(ResEntry(id: value,
                                   name: name,
                                   isDirectory: (offsetField & 0x8000_0000) != 0,
                                   offset: offsetField & 0x7FFF_FFFF))
        }
        return result
    }

    /// IMAGE_RESOURCE_DIR_STRING_U: длина в символах (2 байта), затем UTF-16LE без нуля.
    private static func resourceName(_ reader: IconReader, root: UInt64, offset: UInt32) throws -> String? {
        let at = root + UInt64(offset)
        guard at &+ 2 <= reader.size else { return nil }
        let lengthBytes = try reader.read(at: at, count: 2)
        let length = Int(lengthBytes.u16(0))
        guard length > 0, length <= 256, at + 2 + UInt64(length * 2) <= reader.size else { return nil }
        let raw = try reader.read(at: at + 2, count: length * 2)
        var units: [UInt16] = []
        units.reserveCapacity(length)
        for index in 0..<length { units.append(raw.u16(index * 2)) }
        return String(decoding: units, as: UTF16.self)
    }

    /// Записи уровня «имя» под заданным типом ресурса.
    private static func nameLevel(_ reader: IconReader, root: UInt64, type: UInt32) throws -> [ResEntry] {
        let types = try directory(reader, root: root, at: root)
        // Тип ресурса всегда нумерованный: RT_ICON/RT_GROUP_ICON именем не бывают.
        guard let match = types.first(where: { $0.name == nil && $0.id == type }), match.isDirectory else {
            return []
        }
        return try directory(reader, root: root, at: root + UInt64(match.offset))
    }

    /// Главной оболочка Windows считает группу с НАИМЕНЬШИМ номером — берём её же,
    /// иначе на плитке окажется не тот значок, что в проводнике.
    private static func mainGroup(_ groups: [ResEntry]) -> ResEntry? {
        let numbered = groups.filter { $0.name == nil }.sorted { $0.id < $1.id }
        if let first = numbered.first { return first }
        return groups.sorted { ($0.name ?? "") < ($1.name ?? "") }.first
    }

    /// Спускается от уровня «имя» к данным. Лист IMAGE_RESOURCE_DATA_ENTRY — 16 байт,
    /// в первых восьми RVA данных и их длина.
    private static func blob(_ reader: IconReader, root: UInt64, entry: ResEntry, image: PEImage) throws -> Blob? {
        var leafOffset = root + UInt64(entry.offset)
        if entry.isDirectory {
            let languages = try directory(reader, root: root, at: leafOffset)
            guard let language = languages.first, !language.isDirectory else { return nil }
            leafOffset = root + UInt64(language.offset)
        }
        guard leafOffset &+ 16 <= reader.size else { return nil }
        let leaf = try reader.read(at: leafOffset, count: 16)
        let size = Int(leaf.u32(4))
        guard size > 0 else { return nil }
        guard size <= maxIconBytes else {
            throw ExeIconError.unreadableIcon("ресурс неправдоподобно велик: \(size) Б")
        }
        guard let offset = image.fileOffset(forRVA: leaf.u32(0)) else { return nil }
        return Blob(offset: offset, size: size)
    }

    // MARK: - Группа значков

    /// Одна запись GRPICONDIR (14 байт).
    private struct GroupEntry: Equatable {
        /// 0 в файле означает 256 — размер 256 в один байт не влез.
        let width: Int
        let height: Int
        let colorCount: Int
        let bitCount: Int
        let id: UInt32

        var pixels: Int { max(width, height) }

        /// Глубина для сравнения. У старых сборщиков `wBitCount` бывает нулём —
        /// тогда её приходится выводить из числа цветов.
        var depth: Int {
            if bitCount > 0 { return bitCount }
            switch colorCount {
            case 2: return 1
            case 16: return 4
            case 256: return 8
            default: return 0
            }
        }
    }

    private static func groupEntries(_ reader: IconReader,
                                     root: UInt64,
                                     entry: ResEntry,
                                     image: PEImage) throws -> [GroupEntry] {
        guard let blob = try blob(reader, root: root, entry: entry, image: image) else { return [] }
        let data = try reader.read(at: blob.offset, count: min(blob.size, maxGroupBytes))
        guard data.count >= 6 else {
            throw ExeIconError.unreadableIcon("GRPICONDIR короче заголовка (\(data.count) Б)")
        }
        let count = Int(data.u16(4))
        guard count > 0 else { return [] }
        var result: [GroupEntry] = []
        result.reserveCapacity(count)
        for index in 0..<count {
            let at = 6 + index * 14
            guard at + 14 <= data.count else { break }
            // ★ width/height здесь ОДНОБАЙТОВЫЕ, и ноль означает 256.
            let width = Int(data.u8(at))
            let height = Int(data.u8(at + 1))
            result.append(GroupEntry(width: width == 0 ? 256 : width,
                                     height: height == 0 ? 256 : height,
                                     colorCount: Int(data.u8(at + 2)),
                                     bitCount: Int(data.u16(at + 6)),
                                     id: UInt32(data.u16(at + 12))))
        }
        return result
    }

    /// Запасной путь для файлов без RT_GROUP_ICON: размер и глубину читаем из
    /// заголовка самого значка — 40 байт на запись.
    private static func measuredEntries(_ reader: IconReader,
                                        root: UInt64,
                                        icons: [ResEntry],
                                        image: PEImage) throws -> [GroupEntry] {
        var result: [GroupEntry] = []
        for icon in icons where icon.name == nil {
            guard let blob = try blob(reader, root: root, entry: icon, image: image) else { continue }
            let head = try reader.read(at: blob.offset, count: min(blob.size, 40))
            guard let shape = measure(head) else { continue }
            result.append(GroupEntry(width: shape.width,
                                     height: shape.height,
                                     colorCount: 0,
                                     bitCount: shape.bitCount,
                                     id: icon.id))
        }
        return result
    }

    /// Размер и глубина по первым байтам содержимого — для обоих видов.
    private static func measure(_ head: Data) -> (width: Int, height: Int, bitCount: Int)? {
        if isPNG(head), let size = pngShape(head) {
            return (size.width, size.height, size.bitCount)
        }
        guard head.count >= 16 else { return nil }
        guard head.u32(0) >= 40 else { return nil }
        let width = Int(Int32(bitPattern: head.u32(4)))
        let declared = Int(Int32(bitPattern: head.u32(8)))
        let bits = Int(head.u16(14))
        guard width > 0, declared != 0 else { return nil }
        let height = abs(declared)
        return (width, height % 2 == 0 ? height / 2 : height, bits)
    }

    /// Порядок предпочтения: сперва ближайший СНИЗУ к запрошенному (при равенстве —
    /// глубже цветом), затем остальные подходящие по убыванию, и только после них
    /// те, что крупнее запрошенного — от меньшего к большему. Крупнее приходится брать,
    /// когда мельче запрошенного в файле нет вообще: вернуть что-то лучше, чем ничего.
    private static func ranked(_ entries: [GroupEntry], preferredSize: Int) -> [GroupEntry] {
        entries.sorted { lhs, rhs in
            let lhsFits = lhs.pixels <= preferredSize
            let rhsFits = rhs.pixels <= preferredSize
            if lhsFits != rhsFits { return lhsFits }
            if lhs.pixels != rhs.pixels {
                return lhsFits ? lhs.pixels > rhs.pixels : lhs.pixels < rhs.pixels
            }
            return lhs.depth > rhs.depth
        }
    }

    // MARK: - Содержимое значка

    private struct Picture {
        let png: Data
        let width: Int
        let height: Int
        let bitCount: Int
        let kind: ExeIconPayload
    }

    private static func decode(_ payload: Data) throws -> Picture {
        if isPNG(payload) {
            // Vista и новее кладут в ресурс готовый PNG — отдаём как есть, не перекодируя.
            guard let shape = pngShape(payload) else {
                throw ExeIconError.unreadableIcon("PNG-значок без разбираемого IHDR")
            }
            return Picture(png: payload, width: shape.width, height: shape.height,
                           bitCount: shape.bitCount, kind: .png)
        }
        return try decodeDIB(payload)
    }

    private static func isPNG(_ data: Data) -> Bool {
        guard data.count >= 8 else { return false }
        let base = data.startIndex
        return data[base] == 0x89 && data[base + 1] == 0x50
            && data[base + 2] == 0x4E && data[base + 3] == 0x47
    }

    /// IHDR: ширина и высота — big-endian на смещениях 16 и 20, затем глубина и вид цвета.
    private static func pngShape(_ data: Data) -> (width: Int, height: Int, bitCount: Int)? {
        guard data.count >= 26 else { return nil }
        let width = Int(data.u32be(16))
        let height = Int(data.u32be(20))
        guard width > 0, height > 0, width <= 4096, height <= 4096 else { return nil }
        let depth = Int(data.u8(24))
        let channels: Int
        switch data.u8(25) {
        case 0: channels = 1          // серый
        case 2: channels = 3          // RGB
        case 3: channels = 1          // палитра
        case 4: channels = 2          // серый с альфой
        case 6: channels = 4          // RGBA
        default: return nil
        }
        return (width, height, depth * channels)
    }

    /// Классический значок: BITMAPINFOHEADER, за ним XOR-картинка, за ней AND-маска.
    ///
    /// ★★★ ГЛАВНАЯ ЛОВУШКА ФОРМАТА: `biHeight` здесь ВДВОЕ БОЛЬШЕ настоящей высоты,
    ///   потому что учитывает и маску прозрачности. Кто про это не знает, получает
    ///   картинку, растянутую вдвое по вертикали, — и она «разбирается» без ошибок,
    ///   то есть отчёт «всё работает» ничего не значит без взгляда на картинку.
    ///
    /// ★ Второе: строки DIB идут СНИЗУ ВВЕРХ, а PNG ждёт их сверху вниз.
    private static func decodeDIB(_ blob: Data) throws -> Picture {
        guard blob.count >= 40 else {
            throw ExeIconError.unreadableIcon("DIB короче BITMAPINFOHEADER (\(blob.count) Б)")
        }
        let headerSize = Int(blob.u32(0))
        // Заголовок бывает и длиннее 40 (BITMAPV4/V5) — палитра идёт за ним, а не за 40 байтами.
        guard headerSize >= 40, headerSize <= blob.count else {
            throw ExeIconError.unreadableIcon("неправдоподобный размер заголовка DIB: \(headerSize)")
        }
        let width = Int(Int32(bitPattern: blob.u32(4)))
        let declaredHeight = Int(Int32(bitPattern: blob.u32(8)))
        let bpp = Int(blob.u16(14))
        let compression = blob.u32(16)
        let colorsUsed = Int(blob.u32(32))

        guard width > 0, width <= 1024 else {
            throw ExeIconError.unreadableIcon("неправдоподобная ширина значка: \(width)")
        }
        guard declaredHeight != 0 else {
            throw ExeIconError.unreadableIcon("нулевая высота значка")
        }
        guard compression == 0 else {
            throw ExeIconError.unreadableIcon("сжатие DIB \(compression) не поддержано")
        }
        guard [1, 4, 8, 24, 32].contains(bpp) else {
            throw ExeIconError.unreadableIcon("\(bpp) бит на точку не поддержано")
        }

        // Отрицательная высота у DIB означает строки СВЕРХУ ВНИЗ.
        let topDown = declaredHeight < 0
        let fullHeight = abs(declaredHeight)
        // ★ Вот оно, деление на два. Нечётная высота маску вместить не может —
        //   такой значок читаем как есть, без маски.
        let height = fullHeight % 2 == 0 ? fullHeight / 2 : fullHeight
        guard height > 0, height <= 1024 else {
            throw ExeIconError.unreadableIcon("неправдоподобная высота значка: \(height)")
        }

        let paletteCount = bpp <= 8 ? (colorsUsed > 0 ? min(colorsUsed, 1 << bpp) : 1 << bpp) : 0
        let pixelStart = headerSize + paletteCount * 4
        // Строки DIB выровнены по 4 байта — и у картинки, и у маски.
        let rowBytes = ((width * bpp + 31) / 32) * 4
        let maskRowBytes = ((width + 31) / 32) * 4
        let xorBytes = rowBytes * height
        let maskBytes = maskRowBytes * height

        guard pixelStart + xorBytes <= blob.count else {
            throw ExeIconError.unreadableIcon(
                "данных значка не хватает: нужно \(pixelStart + xorBytes) Б, есть \(blob.count) Б")
        }
        let maskPresent = pixelStart + xorBytes + maskBytes <= blob.count

        var palette: [(r: UInt8, g: UInt8, b: UInt8)] = []
        if paletteCount > 0 {
            palette.reserveCapacity(paletteCount)
            for index in 0..<paletteCount {
                let at = headerSize + index * 4
                guard at + 3 < blob.count else { break }
                // RGBQUAD лежит как B, G, R, 0.
                palette.append((r: blob.u8(at + 2), g: blob.u8(at + 1), b: blob.u8(at)))
            }
        }
        if paletteCount > 0, palette.count < paletteCount {
            throw ExeIconError.unreadableIcon("палитра обрывается: \(palette.count) из \(paletteCount)")
        }

        let bytes = [UInt8](blob)
        var rgba = [UInt8](repeating: 0, count: width * height * 4)

        // ★ У части 32-битных значков альфа в DIB нулевая целиком (так делали старые
        //   сборщики). Брать её как есть — получить полностью прозрачный значок,
        //   то есть тот же серый прямоугольник. Поэтому сначала смотрим, есть ли она.
        var alphaInDIB = false
        if bpp == 32 {
            for row in 0..<height {
                let rowStart = pixelStart + row * rowBytes
                for column in 0..<width where bytes[rowStart + column * 4 + 3] != 0 {
                    alphaInDIB = true
                    break
                }
                if alphaInDIB { break }
            }
        }

        for y in 0..<height {
            // PNG ждёт строки сверху вниз, DIB отдаёт снизу вверх.
            let sourceRow = topDown ? y : (height - 1 - y)
            let rowStart = pixelStart + sourceRow * rowBytes
            let maskStart = pixelStart + xorBytes + sourceRow * maskRowBytes
            for x in 0..<width {
                var r: UInt8 = 0
                var g: UInt8 = 0
                var b: UInt8 = 0
                var a: UInt8 = 255

                switch bpp {
                case 32:
                    let at = rowStart + x * 4
                    b = bytes[at]; g = bytes[at + 1]; r = bytes[at + 2]
                    a = alphaInDIB ? bytes[at + 3] : 255
                case 24:
                    let at = rowStart + x * 3
                    b = bytes[at]; g = bytes[at + 1]; r = bytes[at + 2]
                case 8:
                    let index = Int(bytes[rowStart + x])
                    guard index < palette.count else { break }
                    (r, g, b) = (palette[index].r, palette[index].g, palette[index].b)
                case 4:
                    let byte = bytes[rowStart + x / 2]
                    let index = Int(x % 2 == 0 ? (byte >> 4) : (byte & 0x0F))
                    guard index < palette.count else { break }
                    (r, g, b) = (palette[index].r, palette[index].g, palette[index].b)
                default: // 1
                    let byte = bytes[rowStart + x / 8]
                    let index = Int((byte >> (7 - UInt8(x % 8))) & 1)
                    guard index < palette.count else { break }
                    (r, g, b) = (palette[index].r, palette[index].g, palette[index].b)
                }

                // Прозрачность: у 32 бит своя альфа, у остальных — только маска AND,
                // где единичный бит значит «точка прозрачна».
                if maskPresent, bpp != 32 || !alphaInDIB {
                    let bit = (bytes[maskStart + x / 8] >> (7 - UInt8(x % 8))) & 1
                    if bit == 1 { a = 0 }
                }

                let at = (y * width + x) * 4
                rgba[at] = r; rgba[at + 1] = g; rgba[at + 2] = b; rgba[at + 3] = a
            }
        }

        return Picture(png: try encodePNG(rgba: rgba, width: width, height: height),
                       width: width, height: height, bitCount: bpp, kind: .dib)
    }

    private static func encodePNG(rgba: [UInt8], width: Int, height: Int) throws -> Data {
        guard let provider = CGDataProvider(data: Data(rgba) as CFData) else {
            throw ExeIconError.unreadableIcon("не удалось обернуть точки в поставщика данных")
        }
        // Альфа НЕ домножена на цвет (.last, а не .premultipliedLast) — так она и лежит
        // в DIB; объявить её домноженной значит получить тёмную бахрому по краю.
        guard let image = CGImage(width: width,
                                 height: height,
                                 bitsPerComponent: 8,
                                 bitsPerPixel: 32,
                                 bytesPerRow: width * 4,
                                 space: CGColorSpaceCreateDeviceRGB(),
                                 bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                 provider: provider,
                                 decode: nil,
                                 shouldInterpolate: false,
                                 intent: .defaultIntent) else {
            throw ExeIconError.unreadableIcon("CGImage \(width)×\(height) не создался")
        }
        let buffer = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(buffer, UTType.png.identifier as CFString, 1, nil) else {
            throw ExeIconError.unreadableIcon("PNG-кодировщик недоступен")
        }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else {
            throw ExeIconError.unreadableIcon("PNG не закодировался")
        }
        return buffer as Data
    }

    // MARK: - Кеш

    @MainActor private static var memoryHits: [String: Data] = [:]
    @MainActor private static var memoryMisses: Set<String> = []

    /// Куда складываем добытое. Переменная, а не константа, ровно по одной причине:
    /// проверки обязаны уводить кеш во временный каталог и не трогать настоящий.
    @MainActor static var cacheRoot: URL = FileManager.default
        .urls(for: .cachesDirectory, in: .userDomainMask).first!
        .appendingPathComponent("MacRunner/exe-icons", isDirectory: true)

    /// Забыть всё, что помним в памяти процесса. Нужно проверкам и смене каталога кеша.
    @MainActor static func forgetInMemoryCache() {
        memoryHits.removeAll()
        memoryMisses.removeAll()
    }

    /// Ключ обязан меняться вместе с файлом, иначе обновлённая игра навсегда останется
    /// со старым значком: путь + запрошенный размер + ВРЕМЯ ПРАВКИ и размер файла.
    private static func cacheKey(url: URL, preferredSize: Int) -> String {
        // ★★★ ТОЛЬКО `FileManager.attributesOfItem`, и НИКОГДА `url.resourceValues`.
        //   URL запоминает однажды прочитанные значения внутри себя, и при повторном
        //   запросе отдаёт СТАРЫЕ: время правки не меняется, ключ остаётся прежним,
        //   а игра, обновившаяся при живом приложении, навсегда остаётся со старым
        //   значком. Поймано проверкой «ключ зависит от времени правки» — глазами
        //   такое не находится, потому что после перезапуска всё работает.
        //   `try?` здесь ошибку НЕ прячет: у исчезнувшего файла ключ выйдет нулевым,
        //   и тут же `bestIcon` откажет НАЗВАННОЙ ошибкой, которую `cachedIcon` напечатает.
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let stamp = (attributes?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attributes?[.size] as? Int) ?? 0
        let material = "\(url.path)|\(preferredSize)|\(stamp)|\(size)"
        let digest = SHA256.hash(data: Data(material.utf8))
        return digest.map { String(format: "%02x", $0) }.joined().prefix(32).description
    }

    /// ★ Своё, кешированное читаем тоже через FileHandle: `Data(contentsOf:)` в этом файле
    ///   не используется НИГДЕ, чтобы правило «файл целиком в память не берём» нельзя было
    ///   нарушить случайной правкой.
    private static func readCachedPNG(at url: URL) -> Data? {
        // Отсутствие файла кеша — это НЕ ошибка, а обычное «ещё не считали»; всё
        // остальное (битый размер, обрыв чтения) ниже печатается, а не проглатывается.
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }   // закрытие на чтение о качестве разбора не говорит
        do {
            let size = try handle.seekToEnd()
            guard size > 0, size <= UInt64(maxCachedBytes) else {
                complain("кеш \(url.lastPathComponent) размером \(size) Б — считаю битым")
                return nil
            }
            try handle.seek(toOffset: 0)
            guard let data = try handle.read(upToCount: Int(size)), data.count == Int(size) else {
                return nil
            }
            return data
        } catch {
            complain("кеш \(url.lastPathComponent) не прочитался: \(error.localizedDescription)")
            return nil
        }
    }

    private static func store(_ data: Data, at url: URL) {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            try data.write(to: url, options: .atomic)
        } catch {
            // Кеш — ускорение, а не условие работы: значок мы уже добыли и вернём.
            // Но отказ записи ПЕЧАТАЕМ: иначе «кеш не работает» никак не обнаружить.
            complain("кеш \(url.lastPathComponent) не записался: \(error.localizedDescription)")
        }
    }

    private static func complain(_ text: String) {
        FileHandle.standardError.write(Data("MacRunner/ExeIcon: \(text)\n".utf8))
    }
}

// MARK: - Чтение файла кусками

/// Тонкая обёртка над FileHandle. Существует ради двух правил:
/// файл целиком в память НЕ берём (установщики бывают по гигабайту), а отказ чтения
/// обязан быть ВИДЕН, а не превращён в пустые данные.
private struct IconReader {
    let handle: FileHandle
    let name: String
    let size: UInt64

    init(url: URL) throws {
        do {
            handle = try FileHandle(forReadingFrom: url)
        } catch {
            throw ExeIconError.unreadable("\(url.lastPathComponent): \(error.localizedDescription)")
        }
        name = url.lastPathComponent
        do {
            size = try handle.seekToEnd()
        } catch {
            try? handle.close()
            throw ExeIconError.unreadable("\(url.lastPathComponent): размер не определился (\(error.localizedDescription))")
        }
    }

    /// Закрытие дескриптора, открытого только на чтение, о качестве разбора не говорит
    /// ничего — это единственное намеренно проглоченное исключение.
    func close() { try? handle.close() }

    /// Читает РОВНО `count` байт. Выход за границу файла и недочитанный хвост —
    /// названный отказ: битый .exe не должен ронять приложение, но и не должен
    /// выглядеть как файл без значка.
    func read(at offset: UInt64, count: Int) throws -> Data {
        guard count > 0 else { return Data() }
        guard offset <= size, UInt64(count) <= size - offset else {
            throw ExeIconError.unreadableIcon(
                "\(name): чтение \(count) Б на смещении \(offset) выходит за файл (\(size) Б)")
        }
        do {
            try handle.seek(toOffset: offset)
            guard let data = try handle.read(upToCount: count), data.count == count else {
                throw ExeIconError.unreadableIcon("\(name): файл оборвался на смещении \(offset)")
            }
            return data
        } catch let error as ExeIconError {
            throw error
        } catch {
            throw ExeIconError.unreadable("\(name): отказ чтения на \(offset) (\(error.localizedDescription))")
        }
    }
}

// MARK: - Мелочи чтения чисел

/// Все читалки возвращают ноль при выходе за границу буфера. Это безопасно ровно потому,
/// что длина буфера проверена ДО обращения — на каждом месте вызова.
private extension Data {
    func u8(_ offset: Int) -> UInt8 {
        guard offset >= 0, offset < count else { return 0 }
        return self[startIndex + offset]
    }

    func u16(_ offset: Int) -> UInt16 {
        guard offset >= 0, offset + 2 <= count else { return 0 }
        let base = startIndex + offset
        return UInt16(self[base]) | (UInt16(self[base + 1]) << 8)
    }

    func u32(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return UInt32(self[base])
            | (UInt32(self[base + 1]) << 8)
            | (UInt32(self[base + 2]) << 16)
            | (UInt32(self[base + 3]) << 24)
    }

    /// PNG — единственное место, где числа лежат старшим байтом вперёд.
    func u32be(_ offset: Int) -> UInt32 {
        guard offset >= 0, offset + 4 <= count else { return 0 }
        let base = startIndex + offset
        return (UInt32(self[base]) << 24)
            | (UInt32(self[base + 1]) << 16)
            | (UInt32(self[base + 2]) << 8)
            | UInt32(self[base + 3])
    }
}
