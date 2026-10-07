import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import MacRunnerControlCenter

// Проверка извлечения значка из .exe. Ни сети, ни внешних файлов: минимальный PE вместе
// с деревом ресурсов собирается байт за байтом прямо здесь.
//
// ★ ПОЧЕМУ ПРОВЕРКИ ИМЕННО ТАКИЕ. «Значок разобрался» само по себе не значит ничего:
//   картинка, растянутая вдвое по вертикали (самая частая ошибка разбора DIB), тоже
//   прекрасно «разбирается». Поэтому каждая проверка смотрит на ЧИСЛА готовой картинки —
//   высоту, порядок строк, цвет конкретной точки, — а не на факт отсутствия отказа.
//
// Каждый случай ниже уже ловил настоящую ошибку — либо в этом коде, либо на настоящем файле:
//   · удвоенная высота DIB (biHeight учитывает маску) — без деления на два картинка вдвое выше;
//   · строки DIB идут СНИЗУ ВВЕРХ — без переворота картинка встаёт на голову;
//   · секция с VirtualSize=8 и SizeOfRawData=470 МБ («That's not my neighbor.exe», Godot)
//     накрывала собой .rsrc, и вместо значка читалось тело игрового архива;
//   · группа значков бывает ИМЕНОВАННОЙ («MAINICON» у сборок Delphi и Inno Setup).

// MARK: - Сборка значков

/// Классический значок: BITMAPINFOHEADER + XOR-картинка + маска AND.
///
/// ★ Точки задаются СВЕРХУ ВНИЗ, а в файл кладутся снизу вверх — как того требует формат.
///   Значит проверка «сверху красное» ловит потерянный переворот строк.
/// ★ Высота в заголовке пишется УДВОЕННОЙ, тоже как в настоящем файле.
private func dib32(width: Int,
                   height: Int,
                   pixels: (_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8),
                   maskedOut: ((_ x: Int, _ y: Int) -> Bool)? = nil) -> Data {
    var data = bitmapInfoHeader(width: width, height: height, bpp: 32)
    let rowBytes = width * 4
    for row in (0..<height).reversed() {            // снизу вверх
        var line = Data(count: rowBytes)
        for x in 0..<width {
            let point = pixels(x, row)
            line[x * 4] = point.b                   // в DIB порядок B, G, R, A
            line[x * 4 + 1] = point.g
            line[x * 4 + 2] = point.r
            line[x * 4 + 3] = point.a
        }
        data.append(line)
    }
    data.append(andMask(width: width, height: height, maskedOut: maskedOut))
    return data
}

/// Значок с палитрой (8, 4 или 1 бит на точку) либо 24-битный без палитры.
///
/// ★ У 24 бит палитры в файле НЕТ ВООБЩЕ — точки идут сразу за заголовком. Лишние
///   четыре байта здесь сдвигают всю картинку, и цвета «почти похожи» на верные.
/// ★ `padPalette` выбирает, каким из двух законных способов объявлена палитра:
///   полной (1<<bpp записей, biClrUsed=0) или укороченной (biClrUsed=число записей).
///   Разбор обязан понимать оба.
private func dibIndexed(width: Int,
                        height: Int,
                        bpp: Int,
                        palette: [(r: UInt8, g: UInt8, b: UInt8)],
                        padPalette: Bool = false,
                        index: (_ x: Int, _ y: Int) -> Int,
                        maskedOut: ((_ x: Int, _ y: Int) -> Bool)? = nil) -> Data {
    let hasPalette = bpp <= 8
    let entries = hasPalette && padPalette ? (1 << bpp) : palette.count
    var data = bitmapInfoHeader(width: width, height: height, bpp: bpp,
                                coloursUsed: hasPalette && !padPalette ? palette.count : 0)
    if hasPalette {
        for slot in 0..<entries {
            let colour = slot < palette.count ? palette[slot] : (r: UInt8(0), g: UInt8(0), b: UInt8(0))
            data.append(contentsOf: [colour.b, colour.g, colour.r, 0])   // RGBQUAD
        }
    }
    let rowBytes = ((width * bpp + 31) / 32) * 4
    for row in (0..<height).reversed() {
        var line = [UInt8](repeating: 0, count: rowBytes)
        for x in 0..<width {
            let value = index(x, row)
            switch bpp {
            case 8:
                line[x] = UInt8(value)
            case 4:
                let at = x / 2
                line[at] |= x % 2 == 0 ? UInt8(value << 4) : UInt8(value)
            case 24:
                line[x * 3] = palette[value].b
                line[x * 3 + 1] = palette[value].g
                line[x * 3 + 2] = palette[value].r
            default: // 1
                if value != 0 { line[x / 8] |= UInt8(0x80 >> (x % 8)) }
            }
        }
        data.append(contentsOf: line)
    }
    data.append(andMask(width: width, height: height, maskedOut: maskedOut))
    return data
}

private func bitmapInfoHeader(width: Int, height: Int, bpp: Int, coloursUsed: Int = 0) -> Data {
    var header = Data(count: 40)
    header.put32(0, 40)
    header.put32(4, UInt32(width))
    header.put32(8, UInt32(height * 2))     // ★ УДВОЕННАЯ высота — так лежит в настоящем файле
    header.put16(12, 1)                     // planes
    header.put16(14, UInt16(bpp))
    header.put32(16, 0)                     // BI_RGB
    header.put32(32, UInt32(coloursUsed))   // biClrUsed
    return header
}

/// Маска прозрачности: 1 бит на точку, строки по 4 байта, снизу вверх.
/// Единица означает «точка прозрачна».
private func andMask(width: Int, height: Int, maskedOut: ((Int, Int) -> Bool)?) -> Data {
    let rowBytes = ((width + 31) / 32) * 4
    var data = Data()
    for row in (0..<height).reversed() {
        var line = [UInt8](repeating: 0, count: rowBytes)
        for x in 0..<width where maskedOut?(x, row) == true {
            line[x / 8] |= UInt8(0x80 >> (x % 8))
        }
        data.append(contentsOf: line)
    }
    return data
}

/// Настоящий PNG заданного размера — им проверяется, что PNG-значок отдаётся КАК ЕСТЬ.
private func makePNG(width: Int, height: Int, red: UInt8) -> Data {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for index in 0..<(width * height) {
        bytes[index * 4] = red
        bytes[index * 4 + 1] = 0x20
        bytes[index * 4 + 2] = 0x40
        bytes[index * 4 + 3] = 0xFF
    }
    let provider = CGDataProvider(data: Data(bytes) as CFData)!
    let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                        bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                        provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
    let buffer = NSMutableData()
    let destination = CGImageDestinationCreateWithData(buffer, "public.png" as CFString, 1, nil)!
    CGImageDestinationAddImage(destination, image, nil)
    _ = CGImageDestinationFinalize(destination)
    return buffer as Data
}

// MARK: - Сборка минимального PE с деревом ресурсов

/// Одна запись GRPICONDIR.
private struct GroupItem {
    var width: UInt8
    var height: UInt8
    var colours: UInt8 = 0
    var bits: UInt16
    var iconID: UInt16
}

/// Группа значков: либо номер, либо имя (как «MAINICON» у Delphi).
private struct GroupSpec {
    var id: UInt16?
    var name: String?
    var items: [GroupItem]
}

/// Собирает PE ровно в том объёме, который нужен разбору значка.
private struct PEIconBuilder {
    /// PE32+ (0x20B) по умолчанию; 0x10B — PE32, у него каталоги данных на другом смещении.
    var magic: UInt16 = 0x20B
    var icons: [(id: UInt16, payload: Data)] = []
    var groups: [GroupSpec] = []
    /// Выкинуть каталог ресурсов из опционального заголовка.
    var withoutResourceDirectory = false
    /// Оставить ресурсы, но БЕЗ значков (вместо них — RT_VERSION).
    var resourcesWithoutIcons = false
    /// ★ Ловушка Godot: секция с крошечным VirtualSize и огромным SizeOfRawData ПЕРЕД .rsrc.
    var godotTrap = false

    static let resourceRVA: UInt32 = 0x4000

    func bytes() -> Data {
        let blob = resourceBlob()
        let optionalSize = magic == 0x20B ? 240 : 224
        let sectionCount = godotTrap ? 2 : 1
        let rawStart = 0x200                       // раздел данных начинается с ровного места

        var data = Data(count: 0x40)
        data[0] = 0x4D; data[1] = 0x5A             // MZ
        data.put32(0x3C, 0x40)                     // e_lfanew

        var coff = Data(count: 24)
        coff[0] = 0x50; coff[1] = 0x45             // PE\0\0
        coff.put16(4, 0x8664)
        coff.put16(6, UInt16(sectionCount))
        coff.put16(20, UInt16(optionalSize))
        data.append(coff)

        var optional = Data(count: optionalSize)
        optional.put16(0, magic)
        let directoryStart = magic == 0x20B ? 112 : 96
        optional.put32(directoryStart - 4, 16)     // NumberOfRvaAndSizes
        if !withoutResourceDirectory {
            optional.put32(directoryStart + 16, Self.resourceRVA)      // запись №2 — ресурсы
            optional.put32(directoryStart + 20, UInt32(blob.count))
        }
        data.append(optional)

        if godotTrap {
            // VirtualSize = 8 байт, а сырых данных — мегабайт. Настоящий случай: секция
            // «pck» у игр на Godot, к которой приклеено тело игры.
            data.append(section(name: "pck", virtualAddress: 0x1000, virtualSize: 8,
                                rawPointer: UInt32(rawStart), rawSize: 0x100000))
        }
        data.append(section(name: ".rsrc", virtualAddress: Self.resourceRVA,
                            virtualSize: UInt32(blob.count),
                            rawPointer: UInt32(rawStart), rawSize: UInt32(blob.count)))

        while data.count < rawStart { data.append(0) }
        data.append(blob)
        return data
    }

    private func section(name: String, virtualAddress: UInt32, virtualSize: UInt32,
                         rawPointer: UInt32, rawSize: UInt32) -> Data {
        var entry = Data(count: 40)
        for (index, byte) in Array(name.utf8.prefix(8)).enumerated() { entry[index] = byte }
        entry.put32(8, virtualSize)
        entry.put32(12, virtualAddress)
        entry.put32(16, rawSize)
        entry.put32(20, rawPointer)
        return entry
    }

    /// Дерево ресурсов: тип → имя → язык → лист. Смещения внутри дерева считаются
    /// от его НАЧАЛА, а RVA в листе — от начала образа.
    private func resourceBlob() -> Data {
        struct Leaf { var payload: Data; var offset: Int = 0 }

        var payloads: [Leaf] = []
        var iconLeaf: [UInt16: Int] = [:]
        var groupLeaf: [Int: Int] = [:]

        if resourcesWithoutIcons {
            payloads.append(Leaf(payload: Data([0x01, 0x02, 0x03, 0x04])))
        } else {
            for icon in icons {
                iconLeaf[icon.id] = payloads.count
                payloads.append(Leaf(payload: icon.payload))
            }
            for (index, group) in groups.enumerated() {
                groupLeaf[index] = payloads.count
                payloads.append(Leaf(payload: groupDirectory(group)))
            }
        }

        // Типы: RT_ICON(3) и RT_GROUP_ICON(14); при resourcesWithoutIcons — RT_VERSION(16).
        typealias NameEntry = (key: UInt32, named: Bool, name: String?, leaf: Int)
        var types: [(id: UInt32, names: [NameEntry])] = []
        if resourcesWithoutIcons {
            types = [(id: 16, names: [(key: 1, named: false, name: nil, leaf: 0)])]
        } else {
            if !icons.isEmpty {
                var names: [NameEntry] = []
                for icon in icons {
                    names.append((key: UInt32(icon.id), named: false, name: nil, leaf: iconLeaf[icon.id]!))
                }
                types.append((id: 3, names: names))
            }
            if !groups.isEmpty {
                // Именованные записи в каталоге идут ПЕРВЫМИ — так велит формат.
                var named: [NameEntry] = []
                var numbered: [NameEntry] = []
                for (index, group) in groups.enumerated() {
                    let leaf = groupLeaf[index]!
                    if let text = group.name {
                        named.append((key: 0, named: true, name: text, leaf: leaf))
                    } else {
                        numbered.append((key: UInt32(group.id ?? 1), named: false, name: nil, leaf: leaf))
                    }
                }
                types.append((id: 14, names: named + numbered))
            }
        }

        // Раскладка: каталог типов → каталоги имён → каталоги языков → листы → строки → данные.
        var cursor = 16 + 8 * types.count
        var nameDirectory: [Int: Int] = [:]
        for (index, type) in types.enumerated() {
            nameDirectory[index] = cursor
            cursor += 16 + 8 * type.names.count
        }
        var languageDirectory: [String: Int] = [:]
        for (typeIndex, type) in types.enumerated() {
            for (nameIndex, _) in type.names.enumerated() {
                languageDirectory["\(typeIndex).\(nameIndex)"] = cursor
                cursor += 16 + 8
            }
        }
        var leafOffset: [Int: Int] = [:]
        for index in payloads.indices {
            leafOffset[index] = cursor
            cursor += 16
        }
        var stringOffset: [String: Int] = [:]
        for type in types {
            for name in type.names where name.named {
                guard let text = name.name else { continue }
                stringOffset[text] = cursor
                cursor += 2 + 2 * text.utf16.count
                if cursor % 2 != 0 { cursor += 1 }
            }
        }
        for index in payloads.indices {
            if cursor % 4 != 0 { cursor += 4 - cursor % 4 }
            payloads[index].offset = cursor
            cursor += payloads[index].payload.count
        }

        var blob = Data(count: cursor)

        func directoryHeader(at offset: Int, named: Int, numbered: Int) {
            blob.put16(offset + 12, UInt16(named))
            blob.put16(offset + 14, UInt16(numbered))
        }

        directoryHeader(at: 0, named: 0, numbered: types.count)
        for (index, type) in types.enumerated() {
            let at = 16 + index * 8
            blob.put32(at, type.id)
            blob.put32(at + 4, UInt32(nameDirectory[index]!) | 0x8000_0000)   // это каталог
        }

        for (typeIndex, type) in types.enumerated() {
            let base = nameDirectory[typeIndex]!
            directoryHeader(at: base, named: type.names.filter(\.named).count,
                            numbered: type.names.filter { !$0.named }.count)
            for (nameIndex, name) in type.names.enumerated() {
                let at = base + 16 + nameIndex * 8
                if name.named, let text = name.name {
                    blob.put32(at, UInt32(stringOffset[text]!) | 0x8000_0000)
                } else {
                    blob.put32(at, name.key)
                }
                let language = languageDirectory["\(typeIndex).\(nameIndex)"]!
                blob.put32(at + 4, UInt32(language) | 0x8000_0000)

                directoryHeader(at: language, named: 0, numbered: 1)
                blob.put32(language + 16, 1033)                               // язык
                blob.put32(language + 20, UInt32(leafOffset[name.leaf]!))     // лист, не каталог

                let leaf = leafOffset[name.leaf]!
                blob.put32(leaf, Self.resourceRVA + UInt32(payloads[name.leaf].offset))
                blob.put32(leaf + 4, UInt32(payloads[name.leaf].payload.count))
            }
        }

        for (text, offset) in stringOffset {
            blob.put16(offset, UInt16(text.utf16.count))
            for (index, unit) in Array(text.utf16).enumerated() {
                blob.put16(offset + 2 + index * 2, unit)
            }
        }
        for item in payloads {
            blob.replaceSubrange(item.offset..<(item.offset + item.payload.count), with: item.payload)
        }
        return blob
    }

    /// GRPICONDIR: 6 байт заголовка, затем записи по 14 байт.
    private func groupDirectory(_ group: GroupSpec) -> Data {
        var data = Data(count: 6)
        data.put16(2, 1)                            // тип «значок»
        data.put16(4, UInt16(group.items.count))
        for item in group.items {
            var entry = Data(count: 14)
            entry[0] = item.width                   // ★ 0 здесь означает 256
            entry[1] = item.height
            entry[2] = item.colours
            entry.put16(4, 1)                       // planes
            entry.put16(6, item.bits)
            entry.put32(8, 0)                       // bytesInRes — разбору не нужен
            entry.put16(12, item.iconID)
            data.append(entry)
        }
        return data
    }
}

private extension Data {
    mutating func put16(_ offset: Int, _ value: UInt16) {
        self[startIndex + offset] = UInt8(value & 0xFF)
        self[startIndex + offset + 1] = UInt8(value >> 8)
    }

    mutating func put32(_ offset: Int, _ value: UInt32) {
        self[startIndex + offset] = UInt8(value & 0xFF)
        self[startIndex + offset + 1] = UInt8((value >> 8) & 0xFF)
        self[startIndex + offset + 2] = UInt8((value >> 16) & 0xFF)
        self[startIndex + offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

// MARK: - Оснастка

/// Кладёт байты во временный файл и отдаёт путь. Каталог убирается вызывающим.
private func temporaryFile(name: String, bytes: Data) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("exeicon-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try bytes.write(to: url)
    return url
}

private func withTemporaryFile<T>(name: String, bytes: Data, body: (URL) throws -> T) throws -> T {
    let url = try temporaryFile(name: name, bytes: bytes)
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    return try body(url)
}

/// Готовая картинка, разобранная обратно в точки: без этого «значок получился»
/// ничего не доказывает.
private struct DecodedPNG {
    let width: Int
    let height: Int
    private let bytes: [UInt8]

    init?(_ data: Data) {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        width = image.width
        height = image.height
        var buffer = [UInt8](repeating: 0, count: width * height * 4)
        guard let context = CGContext(data: &buffer, width: width, height: height,
                                      bitsPerComponent: 8, bytesPerRow: width * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        bytes = buffer
    }

    /// Точка в координатах СВЕРХУ ВНИЗ — как её видит человек.
    func pixel(_ x: Int, _ y: Int) -> (r: UInt8, g: UInt8, b: UInt8, a: UInt8) {
        let at = (y * width + x) * 4
        return (bytes[at], bytes[at + 1], bytes[at + 2], bytes[at + 3])
    }
}

/// Имя отказа словом — так падение проверки сразу говорит, ЧТО именно случилось.
private func kind(of error: ExeIconError?) -> String {
    switch error {
    case .notPE: return "notPE"
    case .noResourceDirectory: return "noResourceDirectory"
    case .noIconResource: return "noIconResource"
    case .unreadableIcon: return "unreadableIcon"
    case .unreadable: return "unreadable"
    case nil: return "отказа не было"
    }
}

/// Значок 32×32 в 32 битах: верхняя половина красная, нижняя синяя, слева направо
/// зелень нарастает. Асимметричен НАМЕРЕННО: симметричная картинка не замечает
/// ни переворота строк, ни удвоения высоты.
private func flagIcon(width: Int = 32, height: Int = 32) -> Data {
    dib32(width: width, height: height) { x, y in
        y < height / 2 ? (r: 0xFF, g: UInt8(x * 4), b: 0x00, a: 0xFF)
                       : (r: 0x00, g: UInt8(x * 4), b: 0xFF, a: 0xFF)
    }
}

private func builderWithFlag(width: UInt8 = 32, height: UInt8 = 32) -> PEIconBuilder {
    var builder = PEIconBuilder()
    builder.icons = [(id: 1, payload: flagIcon(width: Int(width), height: Int(height)))]
    builder.groups = [GroupSpec(id: 1, name: nil,
                                items: [GroupItem(width: width, height: height, bits: 32, iconID: 1)])]
    return builder
}

// MARK: - Вид содержимого

struct ExeIconPayloadTests {

    @Test("PNG-значок отдаётся байт в байт, без перекодирования")
    func pngPassesThrough() throws {
        let png = makePNG(width: 256, height: 256, red: 0xC0)
        var builder = PEIconBuilder()
        builder.icons = [(id: 7, payload: png)]
        builder.groups = [GroupSpec(id: 1, name: nil,
                                    items: [GroupItem(width: 0, height: 0, bits: 32, iconID: 7)])]

        try withTemporaryFile(name: "png.exe", bytes: builder.bytes()) { url in
            let probe = try ExeIcon.probe(at: url)
            #expect(probe.payload == .png)
            #expect(probe.png == png, "PNG обязан вернуться как есть, а не быть пересобран")
            #expect(probe.width == 256 && probe.height == 256)
        }
    }

    @Test("★ DIB: высота НЕ удвоена — biHeight учитывает маску, и её надо делить на два")
    func dibHeightIsHalvedNotDoubled() throws {
        try withTemporaryFile(name: "dib.exe", bytes: builderWithFlag().bytes()) { url in
            let probe = try ExeIcon.probe(at: url)
            #expect(probe.payload == .dib)
            #expect(probe.height == 32, "в заголовке стоит 64 (картинка + маска), настоящая высота 32")
            #expect(probe.width == 32)

            let picture = try #require(DecodedPNG(probe.png))
            #expect(picture.width == 32)
            #expect(picture.height == 32, "картинка вдвое выше — значит деление на два потеряно")
        }
    }

    @Test("★ DIB: строки идут снизу вверх — верх картинки обязан остаться верхом")
    func dibRowsAreFlipped() throws {
        try withTemporaryFile(name: "flip.exe", bytes: builderWithFlag().bytes()) { url in
            let picture = try #require(DecodedPNG(try ExeIcon.bestIcon(at: url)))
            let top = picture.pixel(0, 0)
            let bottom = picture.pixel(0, 31)
            #expect(top.r == 0xFF && top.b == 0x00, "сверху задумана красная половина, получено \(top)")
            #expect(bottom.b == 0xFF && bottom.r == 0x00, "снизу задумана синяя половина, получено \(bottom)")
        }
    }

    @Test("DIB 32 бита: цвет берётся из B,G,R, а не задом наперёд")
    func dib32KeepsChannelOrder() throws {
        var builder = PEIconBuilder()
        builder.icons = [(id: 1, payload: dib32(width: 4, height: 4) { _, _ in
            (r: 0x10, g: 0x80, b: 0xF0, a: 0xFF)
        })]
        builder.groups = [GroupSpec(id: 1, name: nil,
                                    items: [GroupItem(width: 4, height: 4, bits: 32, iconID: 1)])]
        try withTemporaryFile(name: "bgr.exe", bytes: builder.bytes()) { url in
            let picture = try #require(DecodedPNG(try ExeIcon.bestIcon(at: url)))
            let point = picture.pixel(1, 1)
            #expect(point.r == 0x10 && point.g == 0x80 && point.b == 0xF0,
                    "каналы перепутаны: получено \(point)")
        }
    }

    @Test("DIB 32 бита: своя альфа уважается")
    func dib32UsesOwnAlpha() throws {
        var builder = PEIconBuilder()
        builder.icons = [(id: 1, payload: dib32(width: 4, height: 4) { x, _ in
            (r: 0xFF, g: 0x00, b: 0x00, a: x < 2 ? 0x00 : 0xFF)
        })]
        builder.groups = [GroupSpec(id: 1, name: nil,
                                    items: [GroupItem(width: 4, height: 4, bits: 32, iconID: 1)])]
        try withTemporaryFile(name: "alpha.exe", bytes: builder.bytes()) { url in
            let picture = try #require(DecodedPNG(try ExeIcon.bestIcon(at: url)))
            #expect(picture.pixel(0, 0).a == 0x00, "левая половина задана прозрачной")
            #expect(picture.pixel(3, 0).a == 0xFF, "правая половина задана непрозрачной")
        }
    }

    @Test("Маска AND делает точку прозрачной у 24, 8, 4 и 1 бита",
          arguments: [24, 8, 4, 1])
    func maskWorksForEveryDepth(bpp: Int) throws {
        let palette: [(r: UInt8, g: UInt8, b: UInt8)] = bpp == 1
            ? [(0x00, 0x00, 0x00), (0xFF, 0xFF, 0x00)]
            : [(0x00, 0x00, 0x00), (0x20, 0xC0, 0x40)]
        var builder = PEIconBuilder()
        builder.icons = [(id: 1, payload: dibIndexed(width: 8, height: 8, bpp: bpp,
                                                     palette: palette,
                                                     index: { _, _ in 1 },
                                                     maskedOut: { x, _ in x < 4 }))]
        builder.groups = [GroupSpec(id: 1, name: nil,
                                    items: [GroupItem(width: 8, height: 8, bits: UInt16(bpp), iconID: 1)])]
        try withTemporaryFile(name: "mask\(bpp).exe", bytes: builder.bytes()) { url in
            let probe = try ExeIcon.probe(at: url)
            #expect(probe.bitCount == bpp)
            #expect(probe.width == 8 && probe.height == 8)
            let picture = try #require(DecodedPNG(probe.png))
            #expect(picture.pixel(0, 0).a == 0x00, "\(bpp) бит: маска не сработала")
            let visible = picture.pixel(7, 0)
            #expect(visible.a == 0xFF, "\(bpp) бит: непрозрачная точка потеряна")
            #expect(visible.g == palette[1].g, "\(bpp) бит: палитра прочитана неверно: \(visible)")
        }
    }

    @Test("Палитра объявляется двумя законными способами — разбор обязан понять оба",
          arguments: [false, true])
    func bothPaletteDeclarations(padded: Bool) throws {
        let palette: [(r: UInt8, g: UInt8, b: UInt8)] = [(0x00, 0x00, 0x00), (0xC0, 0x30, 0x90)]
        var builder = PEIconBuilder()
        builder.icons = [(id: 1, payload: dibIndexed(width: 8, height: 8, bpp: 8,
                                                     palette: palette, padPalette: padded,
                                                     index: { _, _ in 1 }))]
        builder.groups = [GroupSpec(id: 1, name: nil,
                                    items: [GroupItem(width: 8, height: 8, colours: 0, bits: 8, iconID: 1)])]
        try withTemporaryFile(name: "palette.exe", bytes: builder.bytes()) { url in
            let picture = try #require(DecodedPNG(try ExeIcon.bestIcon(at: url)))
            let point = picture.pixel(4, 4)
            #expect(point.r == 0xC0 && point.g == 0x30 && point.b == 0x90,
                    "палитра \(padded ? "полная" : "укороченная") прочитана неверно: \(point)")
        }
    }
}

// MARK: - Выбор лучшего

struct ExeIconChoiceTests {

    private func builder(sizes: [(UInt8, UInt16)]) -> PEIconBuilder {
        var builder = PEIconBuilder()
        var items: [GroupItem] = []
        for (index, size) in sizes.enumerated() {
            let id = UInt16(index + 1)
            let side = size.0 == 0 ? 256 : Int(size.0)
            builder.icons.append((id: id, payload: dib32(width: side, height: side) { x, _ in
                (r: UInt8(index * 30), g: UInt8(x % 256), b: 0x00, a: 0xFF)
            }))
            items.append(GroupItem(width: size.0, height: size.0, bits: size.1, iconID: id))
        }
        builder.groups = [GroupSpec(id: 1, name: nil, items: items)]
        return builder
    }

    @Test("Берётся ближайший СНИЗУ к запрошенному размеру")
    func picksNearestBelow() throws {
        let made = builder(sizes: [(16, 32), (32, 32), (48, 32), (0, 32)])   // 0 = 256
        try withTemporaryFile(name: "sizes.exe", bytes: made.bytes()) { url in
            let forty = try ExeIcon.probe(at: url, preferredSize: 40).width
            let fortyEight = try ExeIcon.probe(at: url, preferredSize: 48).width
            let twenty = try ExeIcon.probe(at: url, preferredSize: 20).width
            #expect(forty == 32)
            #expect(fortyEight == 48)
            #expect(twenty == 16)
        }
    }

    @Test("★ Ширина 0 в GRPICONDIR означает 256, а не «нулевой значок»")
    func zeroWidthMeans256() throws {
        let made = builder(sizes: [(16, 32), (0, 32)])
        try withTemporaryFile(name: "zero.exe", bytes: made.bytes()) { url in
            let big = try ExeIcon.probe(at: url, preferredSize: 256).width
            let small = try ExeIcon.probe(at: url, preferredSize: 32).width
            #expect(big == 256)
            #expect(small == 16, "запросили 32 — значок на 256 не подходит, берётся 16")
        }
    }

    @Test("При равном размере берётся тот, что глубже цветом")
    func deeperColourWinsOnTie() throws {
        var made = PEIconBuilder()
        let palette: [(r: UInt8, g: UInt8, b: UInt8)] = [(0, 0, 0), (0xFF, 0x00, 0x00)]
        made.icons = [(id: 1, payload: dibIndexed(width: 32, height: 32, bpp: 4,
                                                  palette: palette, index: { _, _ in 1 })),
                      (id: 2, payload: dib32(width: 32, height: 32) { _, _ in
                          (r: 0x00, g: 0xFF, b: 0x00, a: 0xFF)
                      })]
        made.groups = [GroupSpec(id: 1, name: nil, items: [
            GroupItem(width: 32, height: 32, colours: 16, bits: 4, iconID: 1),
            GroupItem(width: 32, height: 32, bits: 32, iconID: 2)
        ])]
        try withTemporaryFile(name: "tie.exe", bytes: made.bytes()) { url in
            let depth = try ExeIcon.probe(at: url, preferredSize: 32).bitCount
            #expect(depth == 32)
        }
    }

    @Test("Всё крупнее запрошенного — берём наименьший из крупных, а не отказ")
    func fallsBackToLargerWhenNothingFits() throws {
        let made = builder(sizes: [(64, 32), (0, 32)])
        try withTemporaryFile(name: "big.exe", bytes: made.bytes()) { url in
            let width = try ExeIcon.probe(at: url, preferredSize: 16).width
            #expect(width == 64)
        }
    }

    @Test("★ Группа бывает ИМЕНОВАННОЙ: «MAINICON» у сборок Delphi и Inno Setup")
    func namedGroupIsFound() throws {
        var made = PEIconBuilder()
        made.icons = [(id: 5, payload: flagIcon())]
        made.groups = [GroupSpec(id: nil, name: "MAINICON",
                                 items: [GroupItem(width: 32, height: 32, bits: 32, iconID: 5)])]
        try withTemporaryFile(name: "delphi.exe", bytes: made.bytes()) { url in
            let probe = try ExeIcon.probe(at: url)
            #expect(probe.groupLabel == "«MAINICON»")
            #expect(probe.width == 32 && probe.height == 32)
        }
    }

    @Test("Групп несколько — берётся с наименьшим номером, как в проводнике Windows")
    func lowestNumberedGroupWins() throws {
        var made = PEIconBuilder()
        made.icons = [(id: 1, payload: dib32(width: 16, height: 16) { _, _ in
                          (r: 0xFF, g: 0x00, b: 0x00, a: 0xFF) }),
                      (id: 2, payload: dib32(width: 64, height: 64) { _, _ in
                          (r: 0x00, g: 0x00, b: 0xFF, a: 0xFF) })]
        made.groups = [GroupSpec(id: 9, name: nil, items: [GroupItem(width: 64, height: 64, bits: 32, iconID: 2)]),
                       GroupSpec(id: 2, name: nil, items: [GroupItem(width: 16, height: 16, bits: 32, iconID: 1)])]
        try withTemporaryFile(name: "groups.exe", bytes: made.bytes()) { url in
            let probe = try ExeIcon.probe(at: url)
            #expect(probe.groupCount == 2)
            #expect(probe.groupLabel == "#2")
            #expect(probe.width == 16, "взята группа #9 вместо #2")
        }
    }
}

// MARK: - Заголовки PE

struct ExeIconHeaderTests {

    @Test("PE32 и PE32+ — каталог ресурсов лежит на РАЗНЫХ смещениях")
    func bothOptionalHeaderKinds() throws {
        for magic in [UInt16(0x10B), UInt16(0x20B)] {
            var made = builderWithFlag()
            made.magic = magic
            try withTemporaryFile(name: "magic.exe", bytes: made.bytes()) { url in
                let probe = try ExeIcon.probe(at: url)
                #expect(probe.width == 32, "magic 0x\(String(magic, radix: 16)) разобран неверно")
            }
        }
    }

    @Test("""
          ★ Секция с VirtualSize=8 и огромным SizeOfRawData не должна накрывать .rsrc \
          (поймано на «That's not my neighbor.exe», Godot, 556 МБ)
          """)
    func godotPckSectionDoesNotSwallowResources() throws {
        var made = builderWithFlag()
        made.godotTrap = true
        try withTemporaryFile(name: "godot.exe", bytes: made.bytes()) { url in
            let probe = try ExeIcon.probe(at: url)
            #expect(probe.width == 32 && probe.height == 32,
                    "ресурсы прочитались из чужой секции: ширину секции задаёт VirtualSize, не SizeOfRawData")
        }
    }
}

// MARK: - Отрицательный контроль

struct ExeIconRefusalTests {

    @Test("Не-PE файл даёт notPE, а не падение")
    func plainFileIsNotPE() throws {
        let script = Data("#!/bin/sh\necho привет\n".utf8)
        try withTemporaryFile(name: "script.sh", bytes: script) { url in
            let error = #expect(throws: ExeIconError.self) { try ExeIcon.bestIcon(at: url) }
            #expect(kind(of: error) == "notPE")
        }
    }

    @Test("Картинка вместо программы — тоже notPE")
    func pngFileIsNotPE() throws {
        try withTemporaryFile(name: "cover.png", bytes: makePNG(width: 8, height: 8, red: 0)) { url in
            let error = #expect(throws: ExeIconError.self) { try ExeIcon.bestIcon(at: url) }
            #expect(kind(of: error) == "notPE")
        }
    }

    @Test("Пустой файл не роняет разбор")
    func emptyFileIsNotPE() throws {
        try withTemporaryFile(name: "empty.exe", bytes: Data()) { url in
            let error = #expect(throws: ExeIconError.self) { try ExeIcon.bestIcon(at: url) }
            #expect(kind(of: error) == "notPE")
        }
    }

    @Test("Нет каталога ресурсов — noResourceDirectory")
    func withoutResourceDirectory() throws {
        var made = builderWithFlag()
        made.withoutResourceDirectory = true
        try withTemporaryFile(name: "bare.exe", bytes: made.bytes()) { url in
            #expect(throws: ExeIconError.noResourceDirectory) { try ExeIcon.bestIcon(at: url) }
        }
    }

    @Test("Ресурсы есть, значка нет — noIconResource (обычное дело у консольных утилит)")
    func resourcesWithoutIcons() throws {
        var made = PEIconBuilder()
        made.resourcesWithoutIcons = true
        try withTemporaryFile(name: "console.exe", bytes: made.bytes()) { url in
            #expect(throws: ExeIconError.noIconResource) { try ExeIcon.bestIcon(at: url) }
        }
    }

    @Test("Обрезанный файл даёт НАЗВАННЫЙ отказ, а не падение и не пустую картинку")
    func truncatedFileIsNamed() throws {
        let whole = builderWithFlag().bytes()
        for cut in [0x40, 0x80, 0x200, whole.count / 2] {
            try withTemporaryFile(name: "cut.exe", bytes: whole.prefix(cut)) { url in
                let error = #expect(throws: ExeIconError.self) { try ExeIcon.bestIcon(at: url) }
                #expect(error != nil, "обрезка на \(cut) Б прошла как успех")
                #expect(kind(of: error) != "отказа не было")
            }
        }
    }

    @Test("Мусор вместо содержимого значка — unreadableIcon, а не картинка из ничего")
    func garbageIconPayload() throws {
        var made = PEIconBuilder()
        made.icons = [(id: 1, payload: Data([0xFF, 0xFF, 0xFF, 0xFF, 0x01, 0x02]))]
        made.groups = [GroupSpec(id: 1, name: nil,
                                 items: [GroupItem(width: 32, height: 32, bits: 32, iconID: 1)])]
        try withTemporaryFile(name: "garbage.exe", bytes: made.bytes()) { url in
            let error = #expect(throws: ExeIconError.self) { try ExeIcon.bestIcon(at: url) }
            #expect(kind(of: error) == "unreadableIcon")
        }
    }

    @Test("Значок, на который нет данных, пропускается ради следующего по списку")
    func missingIconFallsToNextEntry() throws {
        var made = PEIconBuilder()
        made.icons = [(id: 2, payload: flagIcon(width: 16, height: 16))]
        // Запись на 32 точки ссылается на значок №9, которого в файле НЕТ.
        made.groups = [GroupSpec(id: 1, name: nil, items: [
            GroupItem(width: 32, height: 32, bits: 32, iconID: 9),
            GroupItem(width: 16, height: 16, bits: 32, iconID: 2)
        ])]
        try withTemporaryFile(name: "gap.exe", bytes: made.bytes()) { url in
            let width = try ExeIcon.probe(at: url, preferredSize: 32).width
            #expect(width == 16, "запись без данных обязана уступить следующей")
        }
    }
}

// MARK: - Кеш

@MainActor
struct ExeIconCacheTests {

    /// Кеш уводится во временный каталог: настоящий `~/Library/Caches` проверки не трогают.
    private func withTemporaryCache<T>(_ body: (URL) throws -> T) rethrows -> T {
        let previous = ExeIcon.cacheRoot
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("exeicon-cache-\(UUID().uuidString)", isDirectory: true)
        ExeIcon.cacheRoot = directory
        ExeIcon.forgetInMemoryCache()
        defer {
            ExeIcon.cacheRoot = previous
            ExeIcon.forgetInMemoryCache()
            try? FileManager.default.removeItem(at: directory)
        }
        return try body(directory)
    }

    @Test("Значок кладётся на диск и второй раз читается оттуда")
    func cacheKeepsPicture() throws {
        try withTemporaryCache { cache in
            try withTemporaryFile(name: "cached.exe", bytes: builderWithFlag().bytes()) { url in
                let first = ExeIcon.cachedIcon(at: url)
                #expect(first != nil)

                let files = try FileManager.default.contentsOfDirectory(atPath: cache.path)
                #expect(files.filter { $0.hasSuffix(".png") }.count == 1, "на диске ожидался один PNG: \(files)")

                ExeIcon.forgetInMemoryCache()             // память забыли, диск остался
                #expect(ExeIcon.cachedIcon(at: url) == first)
            }
        }
    }

    @Test("★ Отказ тоже запоминается: иначе каждая перерисовка списка разбирала бы файл заново")
    func refusalIsCachedToo() throws {
        try withTemporaryCache { cache in
            var made = PEIconBuilder()
            made.resourcesWithoutIcons = true
            try withTemporaryFile(name: "noicon.exe", bytes: made.bytes()) { url in
                #expect(ExeIcon.cachedIcon(at: url) == nil)
                let files = try FileManager.default.contentsOfDirectory(atPath: cache.path)
                #expect(files.contains { $0.hasSuffix(".none") }, "пометки об отказе нет: \(files)")
                #expect(ExeIcon.cachedIcon(at: url) == nil)
            }
        }
    }

    @Test("★ Ключ зависит от ВРЕМЕНИ ПРАВКИ: обновлённая игра не остаётся со старым значком")
    func keyFollowsModificationDate() throws {
        try withTemporaryCache { cache in
            let url = try temporaryFile(name: "update.exe", bytes: builderWithFlag(width: 32, height: 32).bytes())
            defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }

            let before = ExeIcon.cachedIcon(at: url)
            #expect(before != nil)

            // Тот же путь, другое содержимое и другое время правки.
            var made = PEIconBuilder()
            made.icons = [(id: 1, payload: dib32(width: 64, height: 64) { _, _ in
                (r: 0x00, g: 0x00, b: 0xFF, a: 0xFF)
            })]
            made.groups = [GroupSpec(id: 1, name: nil,
                                     items: [GroupItem(width: 64, height: 64, bits: 32, iconID: 1)])]
            try made.bytes().write(to: url)
            try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(60)],
                                                  ofItemAtPath: url.path)

            let after = ExeIcon.cachedIcon(at: url)
            #expect(after != nil)
            #expect(after != before, "значок не обновился — ключ кеша не учитывает время правки")
            let files = try FileManager.default.contentsOfDirectory(atPath: cache.path)
            #expect(files.filter { $0.hasSuffix(".png") }.count == 2, "ожидались две записи: \(files)")
        }
    }

    @Test("Ключ зависит и от запрошенного размера")
    func keyFollowsPreferredSize() throws {
        try withTemporaryCache { cache in
            var made = PEIconBuilder()
            for (index, side) in [16, 64].enumerated() {
                let id = UInt16(index + 1)
                made.icons.append((id: id, payload: dib32(width: side, height: side) { _, _ in
                    (r: UInt8(side), g: 0x00, b: 0x00, a: 0xFF)
                }))
                made.groups = [GroupSpec(id: 1, name: nil, items: (made.groups.first?.items ?? []) + [
                    GroupItem(width: UInt8(side), height: UInt8(side), bits: 32, iconID: id)
                ])]
            }
            try withTemporaryFile(name: "two.exe", bytes: made.bytes()) { url in
                let small = ExeIcon.cachedIcon(at: url, preferredSize: 16)
                let large = ExeIcon.cachedIcon(at: url, preferredSize: 64)
                #expect(small != nil && large != nil)
                #expect(small != large)
                let files = try FileManager.default.contentsOfDirectory(atPath: cache.path)
                #expect(files.filter { $0.hasSuffix(".png") }.count == 2, "ожидались две записи: \(files)")
            }
        }
    }

    @Test("Исчезнувший файл не роняет приложение")
    func missingFileReturnsNil() throws {
        withTemporaryCache { _ in
            let url = URL(fileURLWithPath: "/нет/такого/файла-\(UUID().uuidString).exe")
            #expect(ExeIcon.cachedIcon(at: url) == nil)
        }
    }
}
