import Foundation

/// Откуда взять установщик Windows по идентификатору winget (`Notepad++.Notepad++`).
///
/// ★ ПОЧЕМУ ИМЕННО GITHUB, А НЕ «ОФИЦИАЛЬНЫЙ REST WINGET». Проверено запросами
///   11.09.2026, а не предположением:
///
///   * `api.winget.microsoft.com` — NXDOMAIN, такого имени нет вовсе;
///   * `cdn.winget.microsoft.com/cache/packageManifests/<id>` -> 404 `BlobNotFound`,
///     `/cache/information` -> 404, POST `/cache/manifestSearch` -> 405
///     `UnsupportedHttpVerb`. Это обычное хранилище больших двоичных объектов Azure,
///     а НЕ служба запросов: там лежит `source.msix` (20,3 МБ) и `source2.msix`
///     (3,6 МБ) — заранее собранный указатель для самого `winget.exe`. Скачивать
///     3,6 МБ ради одного идентификатора дороже двух наших запросов по 4–11 КБ,
///     и внутри всё равно лежит база SQLite в архиве, из которой пришлось бы
///     доставать ПУТЬ к тому же YAML на GitHub.
///
///   Значит прямого источника нет, и дешевле всего каталог GitHub:
///   * список версий — `api.github.com/repos/microsoft/winget-pkgs/contents/<путь>`;
///   * сам манифест — `raw.githubusercontent.com` (он НЕ расходует лимит API).
///
/// ★ ЛИМИТ. Без ключа GitHub даёт **60 запросов в час на адрес** (заголовок
///   `x-ratelimit-limit: 60`). Отсюда кеш в памяти: одно нажатие = один запрос
///   к API, повтор по тому же пакету — ноль запросов.
///
/// ★ ЗАГОЛОВОК `User-Agent` ОБЯЗАТЕЛЕН. Измерено: без него api.github.com отвечает
///   **403**, и это выглядит как «пакета нет», хотя пакет есть.

// MARK: - Что мы отдаём наружу

/// Один установщик из манифеста winget.
struct WingetInstaller: Equatable, Sendable {
    let url: URL
    /// Всегда в ВЕРХНЕМ регистре и ровно 64 шестнадцатеричных знака: манифесты
    /// пишут по-разному, а сверять сумму придётся нам, и разный регистр даст
    /// ложное «не совпало».
    let sha256: String
    /// `x64`, `x86`, `arm64`, `arm`, `neutral` — строчными, как в манифесте.
    let architecture: String
    /// `exe`, `msi`, `inno`, `nullsoft`, `wix`, `burn`, `zip`, `portable`, `msix`...
    /// `nil` — тип не указан ни у установщика, ни в корне манифеста.
    let type: String?
    let version: String
    /// `user` / `machine`, если указан.
    let scope: String?
}

// MARK: - Отказы

/// ★ Ни один отказ не превращается в пустой список: «установщиков нет» и «мы не
///   смогли спросить» — разные вещи, и путать их нельзя. Пустой массив в этом
///   проекте уже стоил часов (см. правило про врущие приборы).
enum WingetError: LocalizedError, Equatable {
    /// Идентификатор не похож на winget-овский: нужна хотя бы одна точка.
    case malformedID(String)
    /// Каталога пакета в microsoft/winget-pkgs нет (HTTP 404 на список версий).
    case packageNotFound(String)
    /// Каталог есть, но ни одного каталога-версии в нём не нашлось.
    case noVersions(String)
    /// Версия известна, а файла манифеста по ожидаемому пути нет.
    case manifestMissing(id: String, version: String)
    /// Манифест прочитан, но разобрать его не вышло.
    case manifestUnreadable(id: String, reason: String)
    /// Разобрали, а годных установщиков ноль (нет URL/суммы у всех записей).
    case noInstallers(id: String, version: String)
    /// Лимит GitHub исчерпан (403/429). Отдельный случай: лечится ожиданием,
    /// а не другим пакетом.
    case rateLimited
    /// Ответ пришёл, но с неожиданным кодом.
    case httpStatus(Int)
    /// Сеть не дошла: обрыв, отсутствие доступа, таймаут.
    case network(String)

    var errorDescription: String? {
        switch self {
        case .malformedID(let id):
            return L("Not a winget package ID: ") + id
        case .packageNotFound(let id):
            return L("No such package in the winget catalog: ") + id
        case .noVersions(let id):
            return L("The winget catalog lists no versions for ") + id
        case .manifestMissing(let id, let version):
            return L("The winget manifest is missing for ") + "\(id) \(version)"
        case .manifestUnreadable(let id, let reason):
            return L("Could not read the winget manifest for ") + "\(id): \(reason)"
        case .noInstallers(let id, let version):
            return L("The winget manifest lists no usable installer for ") + "\(id) \(version)"
        case .rateLimited:
            return L("GitHub is rate-limiting us (60 requests per hour without a token). Try again later.")
        case .httpStatus(let code):
            return L("The catalog answered with HTTP ") + String(code)
        case .network(let reason):
            return L("Could not reach the winget catalog: ") + reason
        }
    }
}

// MARK: - Сравнение версий

/// Версия пакета, сравнимая ПО ЧИСЛАМ.
///
/// ★ Алфавитный порядок здесь врёт, и это не теория: у `Microsoft.VisualStudioCode`
///   в каталоге 189 версий, последняя по алфавиту — `1.99.3`, а настоящая последняя —
///   **`1.137.0`** (измерено 11.09.2026). Разница в 38 выпусков.
///
/// Правила:
/// * сравниваем кусками между точками, число к числу (`8.8.10` > `8.8.9`);
/// * недостающие куски считаем нулями (`2.55.0.3` > `2.55.0`);
/// * нечисловой хвост делает версию СТАРШЕ ровного выпуска (`1.2.3` > `1.2.3-beta`),
///   потому что такой хвост у winget всегда предрелиз: `-beta`, `-rc1`, `-preview`.
struct WingetVersion: Comparable, CustomStringConvertible, Sendable {
    /// Кусок между точками: ведущее число и всё, что за ним.
    private struct Part: Equatable {
        let number: Int
        let suffix: String
    }

    let raw: String
    private let parts: [Part]

    init(_ raw: String) {
        self.raw = raw
        self.parts = raw.split(separator: ".", omittingEmptySubsequences: false).map { segment in
            var digits = ""
            var rest = ""
            var stillDigits = true
            for character in segment {
                if stillDigits, character.isASCII, character.isNumber {
                    digits.append(character)
                } else {
                    stillDigits = false
                    rest.append(character)
                }
            }
            // prefix(18) — чтобы абсурдно длинное число не переполнило Int и не
            // обнулило весь кусок.
            return Part(number: Int(digits.prefix(18)) ?? 0, suffix: rest.lowercased())
        }
    }

    var description: String { raw }

    static func < (lhs: WingetVersion, rhs: WingetVersion) -> Bool {
        let count = max(lhs.parts.count, rhs.parts.count)
        for index in 0..<count {
            let left = index < lhs.parts.count ? lhs.parts[index] : Part(number: 0, suffix: "")
            let right = index < rhs.parts.count ? rhs.parts[index] : Part(number: 0, suffix: "")
            if left.number != right.number { return left.number < right.number }
            if left.suffix != right.suffix {
                // Пустой хвост — это релиз, он НОВЕЕ любого предрелиза.
                if left.suffix.isEmpty { return false }
                if right.suffix.isEmpty { return true }
                return left.suffix < right.suffix
            }
        }
        return false
    }

    static func == (lhs: WingetVersion, rhs: WingetVersion) -> Bool {
        !(lhs < rhs) && !(rhs < lhs)
    }

    /// Похоже ли имя каталога на версию.
    ///
    /// ★ Это не придирка: в каталоге пакета рядом с версиями лежат ПОДПАКЕТЫ.
    ///   У `Microsoft/VisualStudioCode` это `CLI` и `Insiders`, у `VideoLAN/VLC` —
    ///   `Nightly`. Без отсева «последней версией» стал бы `Nightly`.
    static func looksLikeVersion(_ name: String) -> Bool {
        var text = Substring(name)
        if text.first == "v" || text.first == "V" { text = text.dropFirst() }
        guard let first = text.first else { return false }
        return first.isASCII && first.isNumber
    }
}

// MARK: - Узкий разбор YAML

/// Разбор `*.installer.yaml` из winget-pkgs.
///
/// ★★★ ЭТО НЕ YAML-РАЗБОРЩИК. Это разбор ровно того подмножества, которым записаны
///   манифесты winget, и его границы названы честно, чтобы никто не принял его за
///   общий:
///
///   ОСИЛИВАЕТ:
///   * вложенность пробелами, пары `Ключ: значение`;
///   * списки `- ` как на нулевом отступе, так и с отступом;
///   * значения в одинарных и двойных кавычках (`PackageVersion: "26.03"`);
///   * концевые комментарии (`MinimumOSVersion: 6.1.7600.0 # Windows 7`);
///   * наследование корневых `InstallerType`/`Scope`/`Architecture` записями
///     установщиков — так записан, например, `Git.Git` (тип `inno` только в корне);
///   * вложенные внутрь установщика отображения и списки (`InstallerSwitches`,
///     `ExpectedReturnCodes`, `AppsAndFeaturesEntries`) — они пропускаются, а не
///     сбивают разбор.
///
///   НЕ ОСИЛИВАЕТ (и в манифестах установщиков не встречается):
///   * блочные скаляры `|` и `>` (они бывают в `*.locale.yaml`, в `installer.yaml` — нет);
///   * поточную запись `{a: 1}` / `[a, b]` — вернётся сырой строкой;
///   * якоря `&`, ссылки `*`, слияние `<<`;
///   * табуляцию как отступ (в YAML она и так запрещена);
///   * escape-последовательности в двойных кавычках сверх `\"` и `\\`;
///   * запись, у которой дефис стоит на ОТДЕЛЬНОЙ строке (`-` и ключи следующей
///     строкой): такая запись будет пропущена. В winget-pkgs эта форма не
///     встречается, но если появится — увидим «установщиков нет», а не поломку.
enum WingetManifestParser {

    /// Что нам вообще нужно из манифеста. Всё остальное читать незачем.
    private static let installerKeys: Set<String> = [
        "Architecture", "InstallerUrl", "InstallerSha256", "InstallerType", "Scope",
        "PackageVersion", "NestedInstallerType"
    ]

    /// Разобранная строка файла.
    private struct Line {
        let indent: Int
        let text: Substring   // без отступа и без завершающего \r
        var isItemStart: Bool { text.hasPrefix("- ") || text == "-" }
    }

    /// Установщики из текста манифеста. Версия берётся из самого манифеста
    /// (`PackageVersion`), чтобы разбор был проверяем без сети.
    static func parse(_ text: String, packageID: String? = nil) throws -> [WingetInstaller] {
        let lines = scan(text)

        // 1. Корневые пары. Берём ПЕРВОЕ вхождение: ключи в корне не повторяются,
        //    а строки внутри списка установщиков сюда не попадают — они либо
        //    начинаются с `- `, либо имеют отступ.
        var root: [String: String] = [:]
        var installersLine: Int?
        for (index, line) in lines.enumerated() where line.indent == 0 && !line.isItemStart {
            guard let (key, value) = splitPair(line.text) else { continue }
            if key == "Installers", value == nil {
                if installersLine == nil { installersLine = index }
                continue
            }
            if let value, root[key] == nil { root[key] = value }
        }

        let id = packageID ?? root["PackageIdentifier"] ?? "?"
        let version = root["PackageVersion"] ?? ""
        guard let start = installersLine else {
            throw WingetError.manifestUnreadable(id: id, reason: L("no Installers: block"))
        }

        // 2. Записи установщиков.
        var installers: [WingetInstaller] = []
        var skipped = 0
        var index = start + 1
        var itemIndent: Int?

        while index < lines.count {
            let line = lines[index]
            if itemIndent == nil {
                // Первый `- ` после `Installers:` задаёт отступ всего списка.
                guard line.isItemStart else { break }
                itemIndent = line.indent
            }
            guard let listIndent = itemIndent else { break }
            if line.indent < listIndent { break }
            if line.indent == listIndent && !line.isItemStart { break }
            guard line.isItemStart else { index += 1; continue }

            // Ключи записи стоят в том столбце, где начался текст после дефиса.
            let dashWidth = line.text.prefix { $0 == "-" || $0 == " " }.count
            let keyIndent = listIndent + dashWidth
            var fields: [String: String] = [:]

            if let (key, value) = splitPair(line.text.dropFirst(dashWidth)), let value,
               installerKeys.contains(key) {
                fields[key] = value
            }

            index += 1
            while index < lines.count {
                let child = lines[index]
                if child.indent < keyIndent { break }
                if child.indent == keyIndent {
                    // Дефис на уровне ключей — это вложенный список
                    // (`ExpectedReturnCodes`), а не поле записи.
                    if child.isItemStart { index += 1; continue }
                    if let (key, value) = splitPair(child.text), let value,
                       installerKeys.contains(key), fields[key] == nil {
                        fields[key] = value
                    }
                }
                // Всё, что глубже, — внутренности вложенных отображений: пропускаем.
                index += 1
            }

            // 3. Корневые умолчания. Именно так записан Git.Git: тип `inno` стоит
            //    один раз в корне, у записей его нет вовсе.
            let architecture = (fields["Architecture"] ?? root["Architecture"] ?? "neutral").lowercased()
            let type = (fields["InstallerType"] ?? root["InstallerType"])?.lowercased()
            let scope = (fields["Scope"] ?? root["Scope"])?.lowercased()

            guard let rawURL = fields["InstallerUrl"], let url = URL(string: rawURL),
                  let rawSha = fields["InstallerSha256"], isSHA256(rawSha)
            else {
                // Запись без адреса или с непохожей суммой поставить нельзя.
                // Считаем её, чтобы не выдать «установщиков нет» при живом манифесте.
                skipped += 1
                continue
            }

            installers.append(WingetInstaller(
                url: url,
                sha256: rawSha.uppercased(),
                architecture: architecture,
                type: type,
                version: fields["PackageVersion"] ?? version,
                scope: scope
            ))
        }

        guard !installers.isEmpty else {
            if skipped > 0 {
                throw WingetError.manifestUnreadable(
                    id: id, reason: L("all installer entries lack a URL or a SHA256"))
            }
            throw WingetError.noInstallers(id: id, version: version)
        }
        return installers
    }

    // MARK: Мелочи разбора

    /// ★★★ РАЗБИВКА НА СТРОКИ ТОЛЬКО ЧЕРЕЗ `isNewline`, И ЭТО НЕ ПРИДИРКА.
    ///
    ///   В Swift `"\r\n"` — ОДИН `Character` (кластер графем), поэтому
    ///   `split(separator: "\n")` на файле с CRLF не делит НИЧЕГО и отдаёт одну
    ///   строку на весь файл. Снаружи это выглядит как «в манифесте нет
    ///   `Installers:`», хотя блок там есть.
    ///
    ///   Измерено 11.09.2026 на живых манифестах: `Notepad++` и `Git.Git` идут с LF
    ///   и разбирались, а `7zip.7zip`, `Microsoft.VisualStudioCode` и `VideoLAN.VLC`
    ///   идут с CRLF — три отказа из пяти пакетов. Обрезание концевого `\r` от этого
    ///   НЕ спасает: делить уже нечего.
    private static func scan(_ text: String) -> [Line] {
        var result: [Line] = []
        for rawLine in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline) {
            var line = rawLine
            if line.hasSuffix("\r") { line = line.dropLast() }  // одиночный CR в конце
            let indent = line.prefix { $0 == " " }.count
            let body = line.dropFirst(indent)
            if body.isEmpty { continue }
            if body.hasPrefix("#") { continue }           // строка-комментарий
            if body == "---" || body == "..." { continue } // границы документа
            result.append(Line(indent: indent, text: body))
        }
        return result
    }

    /// `Ключ: значение` -> (`Ключ`, значение). Значение `nil` — за ключом идёт блок.
    ///
    /// Двоеточие ищем ПЕРВОЕ, за которым пробел или конец строки: иначе
    /// `InstallerUrl: https://...` разошёлся бы по `https:`.
    private static func splitPair(_ text: Substring) -> (String, String?)? {
        var index = text.startIndex
        while let colon = text[index...].firstIndex(of: ":") {
            let next = text.index(after: colon)
            if next == text.endIndex {
                return (String(text[..<colon]), nil)
            }
            if text[next] == " " {
                let key = String(text[..<colon])
                guard !key.isEmpty else { return nil }
                let value = unquote(text[next...].drop { $0 == " " })
                return (key, value.isEmpty ? nil : value)
            }
            index = next
            if index >= text.endIndex { break }
        }
        return nil
    }

    /// Снимаем кавычки, а у значений без кавычек — концевой комментарий.
    private static func unquote(_ raw: Substring) -> String {
        let text = raw.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("'") {
            let body = text.dropFirst()
            if let end = body.firstIndex(of: "'") {
                return body[..<end].replacingOccurrences(of: "''", with: "'")
            }
            return String(body)
        }
        if text.hasPrefix("\"") {
            let body = text.dropFirst()
            var out = ""
            var escaped = false
            for character in body {
                if escaped { out.append(character); escaped = false; continue }
                if character == "\\" { escaped = true; continue }
                if character == "\"" { return out }
                out.append(character)
            }
            return out
        }
        // Концевой комментарий отрезаем только по « #» — по правилу YAML и чтобы
        // не покалечить ссылку с якорем вида `...#install`.
        if let hash = text.range(of: " #") {
            return String(text[..<hash.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return text
    }

    private static func isSHA256(_ text: String) -> Bool {
        text.count == 64 && text.allSatisfy(\.isHexDigit)
    }
}

// MARK: - Резолвер

actor WingetResolver {
    static let shared = WingetResolver()

    /// Сколько живёт запись кеша. Приложение может работать сутками, а выпуски
    /// выходят каждый день — вечный кеш начал бы отдавать вчерашнюю версию.
    private static let cacheTTL: TimeInterval = 6 * 3600

    /// Сколько каталогов-версий пробуем, если у самой свежей манифеста не оказалось.
    /// Каталог-версия без `installer.yaml` встречается: там может лежать манифест
    /// старой, ЕДИНОЙ схемы (`<id>.yaml`) — его пробуем тем же разбором.
    private static let versionAttempts = 3

    private struct CacheEntry {
        let installers: [WingetInstaller]
        let stamp: Date
    }

    private let session: URLSession
    private var cache: [String: CacheEntry] = [:]
    /// Задачи в полёте: два нажатия подряд по одному пакету не должны давать
    /// два запроса к GitHub — лимит всего 60 в час.
    private var inFlight: [String: Task<[WingetInstaller], Error>] = [:]

    init(session: URLSession? = nil) {
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = 15
            configuration.timeoutIntervalForResource = 30
            configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
            self.session = URLSession(configuration: configuration)
        }
    }

    /// ★ Без него api.github.com отвечает 403. Измерено, не предположено.
    static let userAgent = "MacRunner/0.9"

    // MARK: Наружу

    /// Все установщики последней версии пакета.
    func installers(for packageID: String) async throws -> [WingetInstaller] {
        let id = packageID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard id.contains("."), !id.hasPrefix("."), !id.hasSuffix(".") else {
            throw WingetError.malformedID(packageID)
        }

        if let entry = cache[id], Date().timeIntervalSince(entry.stamp) < Self.cacheTTL {
            return entry.installers
        }
        if let running = inFlight[id] { return try await running.value }

        let task = Task<[WingetInstaller], Error> { [session] in
            try await Self.fetch(id: id, session: session)
        }
        inFlight[id] = task
        defer { inFlight[id] = nil }

        let installers = try await task.value
        cache[id] = CacheEntry(installers: installers, stamp: Date())
        return installers
    }

    /// Лучший установщик под наш случай.
    func bestInstaller(for packageID: String) async throws -> WingetInstaller {
        let all = try await installers(for: packageID)
        guard let best = Self.best(among: all) else {
            throw WingetError.noInstallers(id: packageID, version: all.first?.version ?? "?")
        }
        return best
    }

    /// Сбросить кеш — например, когда человек жмёт «обновить каталог».
    func invalidate(_ packageID: String? = nil) {
        if let packageID { cache[packageID] = nil } else { cache.removeAll() }
    }

    // MARK: Выбор

    /// ★★★ ГЛАВНОЕ ПРАВИЛО ВЫБОРА: мы переводим x86-64 и i386, а нативные
    ///   arm64-приложения Windows НЕ запускаем вовсе. Поэтому порядок предпочтений
    ///   x64 -> x86 -> neutral, а arm64/arm берём ТОЛЬКО когда другого нет:
    ///   пусть лучше человек увидит честный отказ на заведомо неподходящем файле,
    ///   чем мы молча скачаем 200 МБ, которые не запустятся.
    private static func architectureRank(_ architecture: String) -> Int {
        switch architecture.lowercased() {
        case "x64": return 0
        case "x86": return 1
        case "neutral": return 2
        case "arm64": return 3
        case "arm": return 4
        default: return 5
        }
    }

    /// Второстепенный порядок — ВНУТРИ одной разрядности. Разрядность всегда важнее:
    /// правильный тип на неподходящей разрядности бесполезен.
    private static func typeRank(_ type: String?) -> Int {
        switch type?.lowercased() {
        case "exe", "inno", "nullsoft", "wix", "msi", "burn": return 0
        case nil: return 1               // тип не указан — обычный exe, ставим следом
        case "portable": return 2
        case "zip": return 3
        case "msix", "appx", "msstore": return 4  // в бутылку Wine не ставится
        default: return 1
        }
    }

    /// `machine` ставит в Program Files — это то, чего ждёт бутылка. `user` тоже
    /// работает, но кладёт в профиль, и потом файл ищут глазами.
    private static func scopeRank(_ scope: String?) -> Int {
        switch scope?.lowercased() {
        case "machine": return 0
        case nil: return 1
        case "user": return 2
        default: return 1
        }
    }

    /// Выбор из готового списка — отдельно от сети, чтобы его можно было проверить
    /// тестом без единого запроса.
    static func best(among installers: [WingetInstaller]) -> WingetInstaller? {
        installers.enumerated().min { left, right in
            let a = (architectureRank(left.element.architecture),
                     typeRank(left.element.type),
                     scopeRank(left.element.scope),
                     left.offset)
            let b = (architectureRank(right.element.architecture),
                     typeRank(right.element.type),
                     scopeRank(right.element.scope),
                     right.offset)
            return a < b
        }?.element
    }

    // MARK: Сеть

    /// Путь пакета в репозитории: `manifests/<первый знак>/<часть>/<часть>/...`.
    /// Каждая точка идентификатора — отдельный каталог: `Microsoft.VisualStudioCode`
    /// лежит в `m/Microsoft/VisualStudioCode`, а `Microsoft.VisualStudioCode.Insiders`
    /// — в `m/Microsoft/VisualStudioCode/Insiders` (проверено, оба дают 200).
    static func manifestPath(for packageID: String) -> String {
        let parts = packageID.split(separator: ".").map(String.init)
        let letter = String(packageID.prefix(1)).lowercased()
        return (["manifests", letter] + parts).joined(separator: "/")
    }

    private static func escape(_ path: String) -> String {
        // `+` разрешён в пути и НЕ означает пробел (это правило строки запроса),
        // поэтому `Notepad++` уезжает как есть — проверено, 200.
        path.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? path
    }

    private static func fetch(id: String, session: URLSession) async throws -> [WingetInstaller] {
        let path = manifestPath(for: id)
        let versions = try await versionDirectories(path: path, id: id, session: session)
        guard !versions.isEmpty else { throw WingetError.noVersions(id) }

        var lastFailure: WingetError = .noVersions(id)
        for version in versions.prefix(versionAttempts) {
            // Сперва раздельная схема, затем единая (`<id>.yaml`) — так записаны
            // старые пакеты, и отдельный отказ на них был бы выдуманным.
            for fileName in ["\(id).installer.yaml", "\(id).yaml"] {
                let url = URL(string: "https://raw.githubusercontent.com/microsoft/winget-pkgs/master/"
                              + escape("\(path)/\(version.raw)/\(fileName)"))!
                do {
                    let data = try await get(url, session: session, id: id)
                    let text = String(decoding: data, as: UTF8.self)
                    return try WingetManifestParser.parse(text, packageID: id)
                } catch let error as WingetError {
                    // 404 на ФАЙЛ — это «у этой версии манифест назван иначе»,
                    // пробуем следующее имя и следующую версию. Всё остальное
                    // (лимит, сеть, нечитаемый манифест) прятать нельзя: такой
                    // отказ надо показать человеку как есть.
                    if case .packageNotFound = error {
                        lastFailure = .manifestMissing(id: id, version: version.raw)
                        continue
                    }
                    throw error
                }
            }
        }
        throw lastFailure
    }

    /// Каталоги-версии, от самой новой к старой.
    private static func versionDirectories(
        path: String, id: String, session: URLSession
    ) async throws -> [WingetVersion] {
        let url = URL(string: "https://api.github.com/repos/microsoft/winget-pkgs/contents/"
                      + escape(path))!
        let data = try await get(url, session: session, id: id)

        struct Entry: Decodable {
            let name: String
            let type: String
        }
        guard let entries = try? JSONDecoder().decode([Entry].self, from: data) else {
            // Каталог существует, но это ФАЙЛ, а не список: API отдаёт объект.
            throw WingetError.noVersions(id)
        }
        return entries
            .filter { $0.type == "dir" && WingetVersion.looksLikeVersion($0.name) }
            .map { WingetVersion($0.name) }
            .sorted(by: >)
    }

    private static func get(_ url: URL, session: URLSession, id: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        if url.host == "api.github.com" {
            request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        }

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            throw WingetError.network(error.localizedDescription)
        } catch {
            throw WingetError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200...299:
            return data
        case 404:
            throw WingetError.packageNotFound(id)
        case 403, 429:
            throw WingetError.rateLimited
        default:
            throw WingetError.httpStatus(http.statusCode)
        }
    }
}
