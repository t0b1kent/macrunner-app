import Foundation
import SQLite3

/// Живой поиск по ВСЕМУ каталогу winget — 14 840 пакетов вместо ручного списка.
///
/// Скачивание установщика остаётся за `WingetResolver`: здесь мы только находим
/// идентификатор (`Notepad++.Notepad++`) и отдаём его наружу.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// ★ ОТКУДА ДАННЫЕ. Измерено запросами 12.09.2026, а не взято из документации:
///
///     https://cdn.winget.microsoft.com/cache/source2.msix  -> 200, 3 599 433 Б
///     https://cdn.winget.microsoft.com/cache/source.msix   -> 200, 20 306 692 Б
///     api.winget.microsoft.com                             -> имени не существует
///
///   Берём `source2.msix` — он в 5,6 раза меньше, а пакетов в нём столько же.
///   Это обычный ZIP; внутри 20 записей, из которых нужна ОДНА:
///   `Public/index.db` — база SQLite, **8 351 744 Б** (7,97 МиБ) в распакованном
///   виде. Порог «больше 100 МБ — хранить только index.db» не достигнут и близко,
///   но мы всё равно достаём из архива ровно одну запись (см. ниже): незачем
///   раскладывать на диск 15 иконок PNG, которые никто не откроет.
///
/// ★ РАСПАКОВКА — `/usr/bin/unzip`, А НЕ `ditto`. Это НЕ предпочтение, это замер:
///
///     /usr/bin/ditto -x -k source2.msix <каталог>   -> код возврата 1,
///                                                      распакована 1 запись из 20
///     то же после переименования в .zip             -> код возврата 1, так же
///     /usr/bin/unzip -o -j -q source2.msix 'Public/index.db' -d <каталог>
///                                                   -> код возврата 0, 8 351 744 Б
///
///   `ditto` на архивах MSIX отказывает ЧАСТИЧНО: успевает положить первый файл и
///   встаёт. Каталог при этом существует и непуст — то есть проверка «папка есть,
///   значит распаковалось» дала бы ложное «готово». Расширение тут не при чём,
///   дело в самом архиве. Поэтому инструмент — `unzip`, и он же умеет то, что нам
///   нужно: достать ОДНУ запись по имени (`-j` — без каталогов).
///
/// ★ ОТМЕТКА О ВРЕМЕНИ — ОТДЕЛЬНЫМ ФАЙЛОМ, А НЕ ПО mtime БАЗЫ. Тоже замер:
///   `unzip` ставит распакованному файлу дату ИЗ АРХИВА, а не «сейчас».
///
///     mtime распакованного index.db : 2026-09-11 23:56:36
///     фактическое время распаковки  : 2026-09-12 11:00:02
///
///   Разница 11 часов, и она произвольна — зависит от того, когда Microsoft
///   собрала снимок. Свежесть по mtime врала бы в обе стороны: только что
///   скачанный указатель мог бы считаться просроченным. Поэтому время загрузки
///   пишем сами, в `fetched-at.json`.
/// ─────────────────────────────────────────────────────────────────────────────

// MARK: - Что мы отдаём наружу

/// Один найденный пакет winget.
struct WingetHit: Equatable, Sendable, Identifiable {
    var id: String { packageID }

    /// Идентификатор для `WingetResolver`: `Microsoft.VisualStudioCode`.
    let packageID: String
    /// Отображаемое имя из каталога: `Microsoft Visual Studio Code`.
    let name: String
    /// ★ ГРАНИЦА: издатель здесь НОРМАЛИЗОВАННЫЙ — строчными и без знаков
    ///   препинания (`igorpavlov`, `notepadteam`, `thegitdevelopmentcommunity`).
    ///   Красивого имени издателя в схеме источника НЕТ ВОВСЕ: таблица `packages`
    ///   столбца издателя не содержит, он живёт только в `norm_publishers2` и
    ///   только в нормализованном виде (проверено `PRAGMA table_info`, см. разбор
    ///   схемы ниже). Пустая строка — если издателя в источнике нет.
    let publisher: String
    /// Последняя версия из каталога. `nil` — версии нет.
    ///
    /// ★ ГРАНИЦА: в снимке от 12.09.2026 столбец `latest_version` объявлен
    ///   NOT NULL и пустых значений ноль из 14 840 — то есть `nil` здесь пока
    ///   НЕ ВСТРЕЧАЕТСЯ. Тип оставлен необязательным намеренно: источник вправе
    ///   начать писать пустое, и тогда пустая строка в интерфейсе выглядела бы
    ///   как «версия 0».
    let latestVersion: String?
}

// MARK: - Отказы

/// ★ Ни один отказ НЕ превращается в пустой список. «Ничего не нашлось» и «мы не
///   смогли посмотреть» — разные вещи, и пустой массив вместо ошибки в этом
///   проекте уже стоил времени: тихий пустой ответ выглядит как настоящий ответ.
enum WingetIndexError: LocalizedError, Equatable {
    /// Поиск позвали, а указателя на диске нет. Сначала `prepare()`.
    case notPrepared
    /// Нет `/usr/bin/unzip` — распаковать нечем.
    case unzipMissing(String)
    /// `unzip` вернул ненулевой код.
    case unzipFailed(code: Int32, stderr: String)
    /// Ответ пришёл, но с неожиданным кодом.
    case httpStatus(Int)
    /// Сеть не дошла: обрыв, отсутствие доступа, таймаут.
    case network(String)
    /// Скачали не то: не ZIP или неправдоподобно мало байт.
    case archiveNotZip(bytes: Int)
    /// В архиве нет `Public/index.db`.
    case databaseEntryMissing
    /// Файл базы на месте, но SQLite его не открывает или в нём нет нужных
    /// столбцов. Ровно этот случай даёт порченый кеш.
    case databaseUnreadable(String)
    /// База открылась, а пакетов в ней ноль. Для каталога из 14 840 записей это
    /// признак обрезанного файла, а не «пусто по запросу».
    case databaseEmpty

    var errorDescription: String? {
        switch self {
        case .notPrepared:
            return L("The winget catalog has not been downloaded yet.")
        case .unzipMissing(let path):
            return L("Cannot unpack the winget catalog: no unzip tool at ") + path
        case .unzipFailed(let code, let stderr):
            return L("Unpacking the winget catalog failed with code ")
                + String(code) + (stderr.isEmpty ? "" : ": \(stderr)")
        case .httpStatus(let code):
            return L("The winget catalog answered with HTTP ") + String(code)
        case .network(let reason):
            return L("Could not reach the winget catalog: ") + reason
        case .archiveNotZip(let bytes):
            return L("The winget catalog download is not a ZIP archive: ")
                + String(bytes) + L(" bytes")
        case .databaseEntryMissing:
            return L("The winget catalog archive has no Public/index.db entry.")
        case .databaseUnreadable(let reason):
            return L("The winget catalog database is unreadable: ") + reason
        case .databaseEmpty:
            return L("The winget catalog database lists no packages at all.")
        }
    }
}

// MARK: - Указатель

/// Скачанный каталог winget и поиск по нему.
///
/// ─────────────────────────────────────────────────────────────────────────────
/// ★ НАСТОЯЩАЯ СХЕМА `Public/index.db`. Снята `PRAGMA table_info` на снимке от
///   12.09.2026 (`metadata`: majorVersion 2, minorVersion 0), а не угадана —
///   схема между версиями источника менялась, отсюда суффиксы `2` в именах.
///
///     packages           14 840   rowid INTEGER PK, id TEXT NOT NULL,
///                                 name TEXT NOT NULL, moniker TEXT,
///                                 latest_version TEXT NOT NULL,
///                                 arp_min_version, arp_max_version, hash BLOB
///     norm_names2        17 628   norm_name TEXT, package INT64   (PK, без rowid)
///     norm_publishers2   15 914   norm_publisher TEXT, package INT64
///     tags2 / tags2_map  21 317 / 89 736
///     commands2          2 029    productcodes2 104 567    pfns2 306
///     upgradecodes2      2 827    metadata 5
///
///   ★ ТРИ СЛЕДСТВИЯ, КОТОРЫЕ ВИДНЫ ТОЛЬКО ПО ФАКТУ:
///
///   1. **Столбца издателя в `packages` НЕТ.** Отсюда нормализованный издатель в
///      `WingetHit` и соединение с `norm_publishers2`. У 1 001 пакета издателей
///      несколько (у `Git.Git` — `johannesschindelin` и
///      `thegitdevelopmentcommunity`); берём первого по алфавиту, чтобы выдача
///      не плавала между прогонами.
///
///   2. **`norm_names2` искать НЕЛЬЗЯ** — там имена без знаков препинания:
///      `Notepad++` лежит как `notepad`, `7-Zip` как `7zip`. Запрос `7-zip` по
///      этой таблице не нашёл бы ничего. Ищем по `packages.name`, где имя
///      настоящее.
///
///   3. **`moniker` искать СТОИТ** — это короткое имя, которым пользуются в самом
///      winget: `vscode` -> `Microsoft.VisualStudioCode`, `vlc` -> `VideoLAN.VLC`.
///      Заполнен у 5 641 пакета из 14 840. Без него запрос `vscode` не нашёл бы
///      Visual Studio Code вовсе: ни в имени, ни в идентификаторе такой строки
///      нет.
///
///   Указателей (`CREATE INDEX`) в базе НЕТ НИ ОДНОГО — поиск по подстроке всё
///   равно читает таблицу целиком. На 14 840 строках это единицы миллисекунд.
/// ─────────────────────────────────────────────────────────────────────────────
actor WingetIndex {

    static let shared = WingetIndex()

    // MARK: Настройки

    /// Обновлять не чаще раза в сутки.
    private static let freshnessWindow: TimeInterval = 24 * 60 * 60
    /// 3,6 МБ; 60 с хватает с большим запасом даже на медленном канале.
    private static let requestTimeout: TimeInterval = 60
    /// Без него часть зеркал Microsoft отвечает отказом.
    private static let userAgent = "MacRunner/0.9"
    /// Запись в архиве, ради которой архив и качается.
    private static let databaseEntry = "Public/index.db"
    /// Ниже этого ZIP быть не может — значит прилетела страница с ошибкой.
    private static let minimumArchiveBytes = 1_000_000

    private let cacheDirectory: URL
    private let sourceURL: URL
    private let session: URLSession
    private let unzipTool: URL

    /// Открытая база. Живёт, пока живёт актор: открывать 8 МБ заново на каждую
    /// букву ввода незачем, а `actor` уже упорядочивает обращения.
    private var database: OpaquePointer?
    /// Идущая подготовка. Без неё два одновременных `prepare()` качали бы архив
    /// дважды: `await` внутри актора — точка, где второй вызов может войти.
    private var preparation: Task<Void, Error>?

    /// Сколько раз мы обращались к сети за время жизни объекта.
    ///
    /// ★ Это ПРИБОР для правила «при свежем кеше — ни одного запроса». Замер
    ///   свидетельствует сам о себе, поэтому в проверке он не единственный:
    ///   второй прогон гоняется ещё и с заведомо недостижимым адресом источника.
    private(set) var networkFetchCount = 0

    // MARK: Создание

    /// - Parameters:
    ///   - cacheDirectory: куда класть `index.db`. По умолчанию
    ///     `~/Library/Caches/MacRunner/winget/`.
    ///   - sourceURL: откуда качать. Подменяется в проверках, чтобы доказать,
    ///     что свежий кеш обходится без сети.
    ///   - session: своя сессия — тоже для проверок.
    init(cacheDirectory: URL? = nil,
         sourceURL: URL = URL(string: "https://cdn.winget.microsoft.com/cache/source2.msix")!,
         session: URLSession? = nil,
         unzipTool: URL = URL(fileURLWithPath: "/usr/bin/unzip")) {
        self.cacheDirectory = cacheDirectory ?? Self.defaultCacheDirectory()
        self.sourceURL = sourceURL
        self.unzipTool = unzipTool
        if let session {
            self.session = session
        } else {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.timeoutIntervalForRequest = Self.requestTimeout
            configuration.timeoutIntervalForResource = Self.requestTimeout
            configuration.httpAdditionalHeaders = ["User-Agent": Self.userAgent]
            self.session = URLSession(configuration: configuration)
        }
    }

    private static func defaultCacheDirectory() -> URL {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Caches")
        return caches.appendingPathComponent("MacRunner/winget", isDirectory: true)
    }

    /// Файл базы.
    var databaseURL: URL { cacheDirectory.appendingPathComponent("index.db") }
    /// Когда база скачана. Отдельно от базы — см. разбор про mtime в шапке файла.
    private var stampURL: URL { cacheDirectory.appendingPathComponent("fetched-at.json") }

    // MARK: Состояние

    /// Готов ли указатель к поиску (скачан и распакован).
    ///
    /// Свежесть здесь НЕ проверяется намеренно: указатель недельной давности для
    /// поиска вполне годен, а решение «пора обновить» принимает `prepare()`.
    func isReady() -> Bool {
        // Пустой файл (0 байт) остаётся после прерванной записи и базой не является.
        Self.fileSize(at: databaseURL) > 0
    }

    /// Скачан меньше суток назад.
    private func isFresh() -> Bool {
        guard isReady(),
              let data = try? Data(contentsOf: stampURL),
              let stamp = try? JSONDecoder().decode(Stamp.self, from: data) else { return false }
        let age = Date().timeIntervalSince(stamp.fetchedAt)
        // Отрицательный возраст = часы съехали назад; считаем просроченным.
        return age >= 0 && age < Self.freshnessWindow
    }

    /// Отметка о загрузке.
    private struct Stamp: Codable {
        let fetchedAt: Date
        /// Байты архива и базы — чтобы при разборе жалоб было видно, что качали.
        let archiveBytes: Int
        let databaseBytes: Int
    }

    // MARK: Подготовка

    /// Скачать и подготовить указатель.
    ///
    /// При свежем (моложе суток) указателе НЕ ДЕЛАЕТ НИ ОДНОГО сетевого запроса и
    /// возвращается сразу.
    func prepare() async throws {
        if isFresh() { return }

        // Уже качаем — присоединяемся, а не начинаем второй раз.
        if let preparation {
            try await preparation.value
            return
        }
        let task = Task { try await download() }
        preparation = task
        defer { preparation = nil }
        // Ошибка уходит наверх, а кеш при этом НЕ портится: `download()` заменяет
        // рабочую базу только после проверки распакованной. Несвежий указатель
        // лучше, чем никакой.
        try await task.value
    }

    private func download() async throws {
        guard FileManager.default.isExecutableFile(atPath: unzipTool.path) else {
            throw WingetIndexError.unzipMissing(unzipTool.path)
        }

        var request = URLRequest(url: sourceURL)
        request.timeoutInterval = Self.requestTimeout
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")

        networkFetchCount += 1
        let archive: Data
        let response: URLResponse
        do {
            (archive, response) = try await session.data(for: request)
        } catch {
            throw WingetIndexError.network(error.localizedDescription)
        }
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw WingetIndexError.httpStatus(http.statusCode)
        }
        // ZIP начинается с "PK". Дешёвая проверка, которая ловит страницу с
        // ошибкой, отданную с кодом 200.
        guard archive.count >= Self.minimumArchiveBytes,
              archive.starts(with: [0x50, 0x4B]) else {
            throw WingetIndexError.archiveNotZip(bytes: archive.count)
        }

        let fileManager = FileManager.default
        try fileManager.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)

        // Работаем в отдельном каталоге и заменяем рабочую базу ТОЛЬКО после
        // того, как распакованная проверена. Иначе сорванная подготовка оставила
        // бы на месте годного указателя обломок.
        let staging = cacheDirectory.appendingPathComponent("staging-\(UUID().uuidString)",
                                                            isDirectory: true)
        try fileManager.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fileManager.removeItem(at: staging) }

        let archiveURL = staging.appendingPathComponent("source2.msix")
        try archive.write(to: archiveURL)

        // `-j` — без каталогов из архива, `-o` — перезаписывать, дальше ИМЯ
        // единственной нужной записи. Остальные 19 записей на диск не попадают.
        try runUnzip(archive: archiveURL, entry: Self.databaseEntry, into: staging)

        let extracted = staging.appendingPathComponent("index.db")
        guard fileManager.fileExists(atPath: extracted.path) else {
            throw WingetIndexError.databaseEntryMissing
        }
        // Проверяем ДО установки: база должна открываться и содержать пакеты.
        let databaseBytes = try validate(databaseAt: extracted)

        closeDatabase()
        if fileManager.fileExists(atPath: databaseURL.path) {
            _ = try fileManager.replaceItemAt(databaseURL, withItemAt: extracted)
        } else {
            try fileManager.moveItem(at: extracted, to: databaseURL)
        }

        // Отметка — ПОСЛЕДНЕЙ. Сорвались раньше — отметка осталась старой, и
        // следующий запуск честно перекачает.
        let stamp = Stamp(fetchedAt: Date(),
                          archiveBytes: archive.count,
                          databaseBytes: databaseBytes)
        try JSONEncoder().encode(stamp).write(to: stampURL)
    }

    private func runUnzip(archive: URL, entry: String, into directory: URL) throws {
        let process = Process()
        process.executableURL = unzipTool
        process.arguments = ["-o", "-j", "-q", archive.path, entry, "-d", directory.path]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = Pipe()
        do {
            try process.run()
        } catch {
            throw WingetIndexError.unzipMissing(unzipTool.path)
        }
        // Читаем до ожидания, иначе полный канал остановит процесс насмерть.
        let stderrData = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let text = String(data: stderrData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            throw WingetIndexError.unzipFailed(code: process.terminationStatus, stderr: text)
        }
    }

    // MARK: Проверка базы

    /// Открыть базу и убедиться, что она НАСТОЯЩАЯ: есть таблица `packages`, есть
    /// все нужные столбцы, есть хотя бы одна запись.
    ///
    /// ★ Это тот самый прибор, из-за которого порченый кеш даёт ОШИБКУ, а не
    ///   пустой список. Проверка спрашивает ровно те столбцы, которыми потом
    ///   пользуется поиск, — иначе она проверяла бы не то, что нужно.
    @discardableResult
    private func validate(databaseAt url: URL) throws -> Int {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle, SQLITE_OPEN_READONLY, nil)
        defer { if handle != nil { sqlite3_close(handle) } }
        guard rc == SQLITE_OK, let handle else {
            throw WingetIndexError.databaseUnreadable(Self.message(rc, handle))
        }
        let probe = """
        SELECT p.id, p.name, p.moniker, p.latest_version,
               (SELECT np.norm_publisher FROM norm_publishers2 np
                 WHERE np.package = p.rowid LIMIT 1)
        FROM packages p LIMIT 1
        """
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, probe, -1, &statement, nil) == SQLITE_OK else {
            let reason = String(cString: sqlite3_errmsg(handle))
            throw WingetIndexError.databaseUnreadable(reason)
        }
        defer { sqlite3_finalize(statement) }
        switch sqlite3_step(statement) {
        case SQLITE_ROW:
            break
        case SQLITE_DONE:
            // Схема есть, записей ноль. Для каталога из 14 840 пакетов это
            // обрезанный файл, и молчать об этом нельзя.
            throw WingetIndexError.databaseEmpty
        default:
            throw WingetIndexError.databaseUnreadable(String(cString: sqlite3_errmsg(handle)))
        }
        return Self.fileSize(at: url)
    }

    /// Размер файла, 0 — если спросить не удалось.
    private static func fileSize(at url: URL) -> Int {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? Int else { return 0 }
        return size
    }

    private static func message(_ rc: Int32, _ handle: OpaquePointer?) -> String {
        if let handle { return String(cString: sqlite3_errmsg(handle)) }
        if let text = sqlite3_errstr(rc) { return String(cString: text) }
        return "sqlite rc=\(rc)"
    }

    /// Открытая база, при первом обращении — открыть и проверить.
    private func openedDatabase() throws -> OpaquePointer {
        if let database { return database }
        guard isReady() else { throw WingetIndexError.notPrepared }
        try validate(databaseAt: databaseURL)

        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(databaseURL.path, &handle, SQLITE_OPEN_READONLY, nil)
        guard rc == SQLITE_OK, let handle else {
            let reason = Self.message(rc, handle)
            if handle != nil { sqlite3_close(handle) }
            throw WingetIndexError.databaseUnreadable(reason)
        }
        database = handle
        return handle
    }

    /// Закрыть базу. Нужна перед подменой файла и в проверках.
    func closeDatabase() {
        if let database { sqlite3_close(database) }
        database = nil
    }

    // MARK: Поиск

    /// ★ ГРАНИЦА ПОИСКА, названная вслух: ищем ПОДСТРОКУ без учёта регистра —
    ///   и только так. Регистр SQLite складывает для ASCII, поэтому `NOTEPAD`
    ///   находит `Notepad++`, а вот 382 пакета с не-ASCII именами (`115浏览器`)
    ///   к регистру нечувствительны — для них ничего и не меняется.
    ///
    ///   **Русский запрос латинского имени НЕ НАЙДЁТ.** «фотошоп» не найдёт
    ///   `Adobe.Photoshop`, потому что в каталоге такой подстроки нет.
    ///   Транслитерацию мы не изобретаем: у неё нет однозначного ответа
    ///   («ph»/«ф», «дж»/«j»/«g»), проверить её нечем, и она стала бы
    ///   недоказуемым прибором. Кириллица в каталоге встречается только у
    ///   русских издателей, и такие запросы работают как обычно.
    ///
    /// - Parameters:
    ///   - query: что печатает человек. Пустой (или из одних пробелов) — пустой
    ///     ответ, а НЕ весь каталог: 14 840 строк в списке бесполезны.
    ///   - limit: сколько вернуть. `<= 0` — пустой ответ.
    func search(_ query: String, limit: Int) async throws -> [WingetHit] {
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !needle.isEmpty, limit > 0 else { return [] }

        let handle = try openedDatabase()
        let escaped = Self.escapeForLike(needle)

        // ★ СКЛЕЙКИ СТРОК НЕТ НИ ОДНОЙ: всё через `sqlite3_bind_text`. Это не
        //   предосторожность «на всякий случай» — в каталоге 31 пакет с
        //   одинарной кавычкой в имени (`Rocks'n'Diamonds`, `Beulea's EVE
        //   Contracts`), и склейка на них ломала бы запрос.
        //
        // Порядок выдачи, от лучшего к худшему:
        //   0 — имя РАВНО запросу
        //   1 — имя НАЧИНАЕТСЯ с запроса
        //   2 — идентификатор или короткое имя начинается с запроса
        //   3 — подстрока где-то ещё (имя, идентификатор, moniker, издатель)
        // Внутри разряда — короткое имя раньше (`Git` раньше `GitHub Desktop`),
        // затем по алфавиту: выдача обязана не плавать между прогонами.
        //
        // Подзапрос по издателю в WHERE — НЕ коррелированный (`IN (SELECT ...)`),
        // он считается один раз. Коррелированный `EXISTS` с `LIKE` дал бы
        // 14 840 × 15 914 сравнений. Издателя для показа достаём во ВНЕШНЕМ
        // запросе, после `LIMIT`, — чтобы эти чтения шли только по тем строкам,
        // которые реально вернём.
        let sql = """
        SELECT o.id, o.name, o.version,
               (SELECT np.norm_publisher FROM norm_publishers2 np
                 WHERE np.package = o.rid
                 ORDER BY np.norm_publisher LIMIT 1)
        FROM (
          SELECT p.rowid AS rid, p.id AS id, p.name AS name,
                 p.latest_version AS version,
                 CASE
                   WHEN p.name    LIKE ?1 ESCAPE '\\' THEN 0
                   WHEN p.name    LIKE ?2 ESCAPE '\\' THEN 1
                   WHEN p.id      LIKE ?2 ESCAPE '\\' THEN 2
                   WHEN p.moniker LIKE ?2 ESCAPE '\\' THEN 2
                   ELSE 3
                 END AS rank
          FROM packages p
          WHERE p.name    LIKE ?3 ESCAPE '\\'
             OR p.id      LIKE ?3 ESCAPE '\\'
             OR p.moniker LIKE ?3 ESCAPE '\\'
             OR p.rowid IN (SELECT package FROM norm_publishers2
                             WHERE norm_publisher LIKE ?3 ESCAPE '\\')
          ORDER BY rank, length(p.name), p.name
          LIMIT ?4
        ) o
        """

        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK else {
            throw WingetIndexError.databaseUnreadable(String(cString: sqlite3_errmsg(handle)))
        }
        defer { sqlite3_finalize(statement) }

        sqlite3_bind_text(statement, 1, escaped, -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 2, escaped + "%", -1, SQLITE_TRANSIENT)
        sqlite3_bind_text(statement, 3, "%" + escaped + "%", -1, SQLITE_TRANSIENT)
        sqlite3_bind_int(statement, 4, Int32(clamping: limit))

        var hits: [WingetHit] = []
        while true {
            let step = sqlite3_step(statement)
            if step == SQLITE_DONE { break }
            guard step == SQLITE_ROW else {
                throw WingetIndexError.databaseUnreadable(String(cString: sqlite3_errmsg(handle)))
            }
            guard let packageID = Self.text(statement, 0),
                  let name = Self.text(statement, 1) else { continue }
            let version = Self.text(statement, 2)
            hits.append(WingetHit(packageID: packageID,
                                  name: name,
                                  publisher: Self.text(statement, 3) ?? "",
                                  latestVersion: (version?.isEmpty == false) ? version : nil))
        }
        return hits
    }

    private static func text(_ statement: OpaquePointer?, _ column: Int32) -> String? {
        guard let raw = sqlite3_column_text(statement, column) else { return nil }
        return String(cString: raw)
    }

    /// Обезвредить символы, которые для `LIKE` означают «любой».
    ///
    /// ★ Без этого запрос `100%` нашёл бы всё, что начинается на `100`, а `C_`
    ///   совпал бы с `CX`: `%` и `_` — подстановочные знаки самого `LIKE`, и
    ///   человек, печатающий их как текст, получил бы чужую выдачу. Экранирующий
    ///   знак — обратная косая, поэтому её саму экранируем ПЕРВОЙ.
    nonisolated static func escapeForLike(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count + 4)
        for character in text {
            switch character {
            case "\\", "%", "_": out.append("\\"); out.append(character)
            default: out.append(character)
            }
        }
        return out
    }
}

/// SQLite требует сказать, что строку надо скопировать: по умолчанию он запомнил
/// бы указатель на временный буфер Swift, которого к моменту `step` уже нет.
private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
