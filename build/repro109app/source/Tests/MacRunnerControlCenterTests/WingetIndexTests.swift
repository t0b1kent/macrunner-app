import Foundation
import SQLite3
import Testing
@testable import MacRunnerControlCenter

/// Проверяем поиск по каталогу winget БЕЗ СЕТИ: база собирается тут же, руками, по
/// настоящей схеме источника (снята `PRAGMA table_info` со `source2.msix`
/// 12.09.2026, majorVersion 2).
///
/// Что именно здесь ловится — то, что ломается молча:
/// * порядок выдачи (сломанная сортировка выдачу не опустошает, а лишь путает);
/// * экранирование подстановочных знаков `LIKE` (без него `_` вернул бы ВСЁ);
/// * подстановка параметров (имя с кавычкой);
/// * отказы: порченая база обязана давать ОШИБКУ, а не пустой список.
struct WingetIndexTests {

    // MARK: - Оснастка

    /// Каталог под кеш; удаляется вызывающим.
    private static func makeCacheDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("winget-index-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Выполнить SQL в новой базе по указанному пути.
    private static func makeDatabase(at url: URL, sql: String) throws {
        var handle: OpaquePointer?
        let rc = sqlite3_open_v2(url.path, &handle,
                                 SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil)
        try #require(rc == SQLITE_OK)
        defer { sqlite3_close(handle) }
        var error: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(handle, sql, nil, nil, &error) != SQLITE_OK {
            let text = error.map { String(cString: $0) } ?? "неизвестно"
            sqlite3_free(error)
            Issue.record("не удалось собрать пробную базу: \(text)")
            throw WingetIndexError.databaseUnreadable(text)
        }
    }

    /// Схема ровно как у источника: `packages` без столбца издателя, издатель
    /// отдельной таблицей и только нормализованный.
    private static let schema = """
    CREATE TABLE packages(rowid INTEGER PRIMARY KEY, id TEXT NOT NULL, name TEXT NOT NULL,
      moniker TEXT, latest_version TEXT NOT NULL, arp_min_version TEXT,
      arp_max_version TEXT, hash BLOB);
    CREATE TABLE norm_publishers2(norm_publisher TEXT NOT NULL, package INT64 NOT NULL,
      PRIMARY KEY(norm_publisher, package)) WITHOUT ROWID;
    """

    /// Пробный каталог. Подобран так, чтобы каждая строка проверяла свой разряд
    /// сортировки, а не просто «что-то нашлось».
    ///
    ///   Git                разряд 0 — имя РАВНО запросу «git»
    ///   GitHub Desktop     разряд 1 — имя НАЧИНАЕТСЯ с «git»
    ///   Kraken Client      разряд 2 — moniker «gitkraken» начинается с «git»
    ///   Zed                разряд 3 — «git» только у ИЗДАТЕЛЯ (gitpublisher)
    ///   Legit Tool         разряд 3 — «git» внутри имени
    /// Внутри разряда 3: «Zed» (3 знака) раньше «Legit Tool» (10 знаков).
    ///
    /// ★ Одинарная кавычка в `Rocks'n'Diamonds` — не украшение: в настоящем
    ///   каталоге таких имён 31, и на склейке строк запрос сломался бы.
    /// ★ `Under_Score` — буквальное подчёркивание, знак подстановки `LIKE`.
    /// ★ У `BIGNAME` версия пустая: проверяем, что наружу уходит nil.
    /// ★ У `Git` издателей ДВА: берём первого по алфавиту, иначе выдача плавает.
    private static let fixture = schema + """
    INSERT INTO packages(rowid,id,name,moniker,latest_version) VALUES
      (1,'Foo.Legit','Legit Tool',NULL,'1.0'),
      (2,'GitHub.GitHubDesktop','GitHub Desktop',NULL,'3.4.5'),
      (3,'Git.Git','Git','git','2.55.0.3'),
      (4,'Axosoft.GitKraken','Kraken Client','gitkraken','10.1'),
      (5,'Zed.Editor','Zed',NULL,'0.9'),
      (6,'Artsoft.RocksNDiamonds','Rocks''n''Diamonds',NULL,'1.0'),
      (7,'Big.Corp','BIGNAME',NULL,''),
      (8,'Some.UnderScore','Under_Score',NULL,'2.0');
    INSERT INTO norm_publishers2(norm_publisher,package) VALUES
      ('foocorp',1),('github',2),
      ('zzzlatecommunity',3),('gitdevelopers',3),
      ('axosoft',4),('gitpublisher',5),('artsoft',6),('bigcorp',7),('somecorp',8);
    """

    /// Готовый к поиску указатель на пробной базе. Сети не касается.
    private static func makeIndex(sql: String? = nil) throws -> (WingetIndex, URL) {
        let directory = try makeCacheDirectory()
        try makeDatabase(at: directory.appendingPathComponent("index.db"),
                         sql: sql ?? fixture)
        // Адрес источника заведомо недостижим: если поиск полезет в сеть — упадёт.
        let index = WingetIndex(
            cacheDirectory: directory,
            sourceURL: URL(string: "https://nedostupno.macrunner.invalid/source2.msix")!
        )
        return (index, directory)
    }

    // MARK: - Порядок выдачи

    @Test func ordersExactThenPrefixThenSubstring() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hits = try await index.search("git", limit: 50)
        // Пять записей соответствуют «git»; `Rocks'n'Diamonds`, `BIGNAME` и
        // `Under_Score` — нет, и попасть в выдачу не должны.
        #expect(hits.map(\.packageID) == [
            "Git.Git",                  // разряд 0: имя равно запросу
            "GitHub.GitHubDesktop",     // разряд 1: имя начинается с запроса
            "Axosoft.GitKraken",        // разряд 2: moniker начинается с запроса
            "Zed.Editor",               // разряд 3, имя короче
            "Foo.Legit"                 // разряд 3, имя длиннее
        ])
    }

    @Test func prefixMatchOutranksSubstringMatch() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hits = try await index.search("git", limit: 50)
        let prefix = try #require(hits.firstIndex { $0.packageID == "GitHub.GitHubDesktop" })
        let substring = try #require(hits.firstIndex { $0.packageID == "Foo.Legit" })
        #expect(prefix < substring, "совпадение в начале имени обязано быть выше")
    }

    // MARK: - Регистр

    @Test func searchIgnoresCase() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        for probe in ["BIGNAME", "bigname", "BigName", "bIgNaMe"] {
            let hits = try await index.search(probe, limit: 10)
            #expect(hits.map(\.packageID) == ["Big.Corp"], "запрос '\(probe)'")
        }
    }

    @Test func searchMatchesIdentifierAndPublisherIgnoringCase() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Только в идентификаторе: ни в имени, ни у издателя «axosoft» нет...
        // впрочем, издатель как раз axosoft — поэтому берём то, что есть только в id.
        let byIdentifier = try await index.search("ZED.EDITOR", limit: 10)
        #expect(byIdentifier.map(\.packageID) == ["Zed.Editor"])

        // Только у издателя: строки «foocorp» нет ни в имени, ни в идентификаторе.
        let byPublisher = try await index.search("FOOCORP", limit: 10)
        #expect(byPublisher.map(\.packageID) == ["Foo.Legit"])
    }

    // MARK: - Пустой запрос и предел

    @Test func emptyQueryReturnsNothingRatherThanWholeCatalog() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        for probe in ["", " ", "   ", "\n", "\t "] {
            #expect(try await index.search(probe, limit: 50).isEmpty,
                    "пустой запрос обязан давать пусто, а не весь каталог")
        }
    }

    @Test func limitCapsTheAnswerAndKeepsTheBestRanked() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        #expect(try await index.search("git", limit: 1).map(\.packageID) == ["Git.Git"])
        #expect(try await index.search("git", limit: 2).map(\.packageID)
                == ["Git.Git", "GitHub.GitHubDesktop"])
        #expect(try await index.search("git", limit: 50).count == 5)
        // Предел больше числа совпадений ничего не ломает.
        #expect(try await index.search("git", limit: 10_000).count == 5)
        // Ноль и отрицательный предел — пусто, а не «весь каталог».
        #expect(try await index.search("git", limit: 0).isEmpty)
        #expect(try await index.search("git", limit: -5).isEmpty)
    }

    // MARK: - Подстановка параметров

    @Test func nameWithSingleQuoteIsFoundWhichProvesParameterBinding() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        // ★ Склейка строк дала бы здесь синтаксическую ошибку SQL, то есть бросок
        //   или пустой список. Находка доказывает, что строка ушла параметром.
        let hits = try await index.search("Rocks'n'Diamonds", limit: 10)
        #expect(hits.map(\.packageID) == ["Artsoft.RocksNDiamonds"])

        // Частичное совпадение с кавычкой внутри — тоже.
        #expect(try await index.search("s'n'D", limit: 10).map(\.packageID)
                == ["Artsoft.RocksNDiamonds"])
    }

    @Test func sqlInjectionAttemptFindsNothingAndDoesNotThrow() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Попытка закрыть строку и дописать своё. Если бы склейка была, мы бы
        // получили ошибку разбора SQL; при подстановке это просто текст, которого
        // в каталоге нет.
        let hits = try await index.search("'; DROP TABLE packages; --", limit: 10)
        #expect(hits.isEmpty)
        // Таблица на месте — запрос после «покушения» по-прежнему работает.
        #expect(try await index.search("git", limit: 50).count == 5)
    }

    // MARK: - Знаки подстановки LIKE

    @Test func likeWildcardsInTheQueryAreTreatedAsPlainText() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        // ★ Без экранирования `_` означает «любой знак» и вернул бы ВСЕ 8 записей.
        //   Экранированный — только ту, где подчёркивание настоящее.
        #expect(try await index.search("_", limit: 50).map(\.packageID) == ["Some.UnderScore"])
        #expect(try await index.search("Under_Score", limit: 50).map(\.packageID)
                == ["Some.UnderScore"])
        // `Under?Score` с чужим знаком не совпадает ни с чем.
        #expect(try await index.search("UnderXScore", limit: 50).isEmpty)
        // ★ Без экранирования `%` вернул бы весь каталог.
        #expect(try await index.search("%", limit: 50).isEmpty)
        #expect(try await index.search("%git%", limit: 50).isEmpty)
        // Обратная косая — сам экранирующий знак; в каталоге её нет.
        #expect(try await index.search("\\", limit: 50).isEmpty)
    }

    @Test func escapeForLikeShieldsEveryWildcard() {
        #expect(WingetIndex.escapeForLike("git") == "git")
        #expect(WingetIndex.escapeForLike("100%") == "100\\%")
        #expect(WingetIndex.escapeForLike("a_b") == "a\\_b")
        // Обратная косая экранируется САМА, иначе она съела бы следующий знак.
        #expect(WingetIndex.escapeForLike("a\\b") == "a\\\\b")
        #expect(WingetIndex.escapeForLike("%_\\") == "\\%\\_\\\\")
        // Кавычки к LIKE отношения не имеют и обязаны остаться как есть.
        #expect(WingetIndex.escapeForLike("Rocks'n'Diamonds") == "Rocks'n'Diamonds")
    }

    // MARK: - Поля выдачи

    @Test func emptyVersionBecomesNilNotEmptyString() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        let hit = try #require(try await index.search("BIGNAME", limit: 10).first)
        #expect(hit.latestVersion == nil, "пустая версия обязана стать nil")

        let versioned = try #require(try await index.search("GitHub Desktop", limit: 10).first)
        #expect(versioned.latestVersion == "3.4.5")
    }

    @Test func publisherIsTheAlphabeticallyFirstOfSeveral() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        // У `Git.Git` издателя два: `gitdevelopers` и `zzzlatecommunity`.
        // Берём первого по алфавиту — иначе выдача плавала бы между прогонами.
        let hit = try #require(try await index.search("Git.Git", limit: 10).first)
        #expect(hit.publisher == "gitdevelopers")
    }

    @Test func hitIdentityIsThePackageIdentifier() {
        let hit = WingetHit(packageID: "Microsoft.VisualStudioCode",
                            name: "Microsoft Visual Studio Code",
                            publisher: "microsoft",
                            latestVersion: "1.137.0")
        #expect(hit.id == "Microsoft.VisualStudioCode")
    }

    // MARK: - Отказы: пустой список запрещён

    @Test func missingCatalogThrowsNotPrepared() async throws {
        let directory = try Self.makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let index = WingetIndex(cacheDirectory: directory)
        #expect(await index.isReady() == false)
        await #expect(throws: WingetIndexError.notPrepared) {
            _ = try await index.search("git", limit: 10)
        }
    }

    @Test func corruptCatalogThrowsInsteadOfAnsweringEmpty() async throws {
        let directory = try Self.makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("это не база SQLite, а мусор".utf8)
            .write(to: directory.appendingPathComponent("index.db"))

        let index = WingetIndex(cacheDirectory: directory)
        // Файл на месте, поэтому «готов» — и тем опаснее тихий пустой ответ.
        #expect(await index.isReady() == true)
        await #expect(throws: (any Error).self) {
            _ = try await index.search("git", limit: 10)
        }
        // Убеждаемся, что отказ ИМЕННО про нечитаемую базу, а не что-то ещё.
        do {
            _ = try await index.search("git", limit: 10)
            Issue.record("порченый кеш обязан бросать, а не отвечать пустым списком")
        } catch let error as WingetIndexError {
            guard case .databaseUnreadable = error else {
                Issue.record("ожидали .databaseUnreadable, получили \(error)")
                return
            }
        }
    }

    @Test func foreignSchemaThrowsDatabaseUnreadable() async throws {
        let directory = try Self.makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        // Настоящая база SQLite, но нашей таблицы в ней нет.
        try Self.makeDatabase(at: directory.appendingPathComponent("index.db"),
                              sql: "CREATE TABLE sovsem_ne_to(a TEXT); INSERT INTO sovsem_ne_to VALUES('x');")

        let index = WingetIndex(cacheDirectory: directory)
        do {
            _ = try await index.search("git", limit: 10)
            Issue.record("чужая схема обязана бросать")
        } catch let error as WingetIndexError {
            guard case .databaseUnreadable = error else {
                Issue.record("ожидали .databaseUnreadable, получили \(error)")
                return
            }
        }
    }

    @Test func emptyCatalogThrowsRatherThanLookingLikeNoMatches() async throws {
        let (index, directory) = try Self.makeIndex(sql: Self.schema)  // схема без строк
        defer { try? FileManager.default.removeItem(at: directory) }

        // ★ Обрезанная база даёт ровно тот же ответ, что «ничего не нашлось».
        //   Поэтому ноль пакетов — отказ, а не выдача.
        await #expect(throws: WingetIndexError.databaseEmpty) {
            _ = try await index.search("git", limit: 10)
        }
    }

    // MARK: - Свежесть и отсутствие сети

    @Test func preparedCatalogIsReportedReady() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }
        #expect(await index.isReady() == true)
    }

    @Test func searchDoesNotTouchTheNetwork() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Адрес источника у этого указателя недостижим (см. makeIndex). Значит
        // успешный поиск сам по себе доказывает, что в сеть не ходили.
        #expect(try await index.search("git", limit: 50).count == 5)
        #expect(await index.networkFetchCount == 0)
    }

    @Test func prepareWithoutStampGoesToTheNetworkAndFailsOnUnreachableSource() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        // База есть, а отметки о загрузке НЕТ -> указатель считается несвежим и
        // обязан попробовать скачать. Источник недостижим, поэтому ждём отказ.
        // ★ Это доказывает, что предыдущая проверка не «просто не качает никогда»:
        //   прибор различает свежий кеш и его отсутствие.
        await #expect(throws: (any Error).self) { try await index.prepare() }
        #expect(await index.networkFetchCount == 1)
    }

    @Test func freshStampMeansPrepareMakesNoRequest() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Отметка «скачано только что» — той же формы, что пишет download().
        let stamp = ["fetchedAt": Date().timeIntervalSinceReferenceDate,
                     "archiveBytes": 3_599_433, "databaseBytes": 8_351_744]
        try JSONSerialization.data(withJSONObject: stamp)
            .write(to: directory.appendingPathComponent("fetched-at.json"))

        // Источник недостижим: если бы prepare() полез в сеть, вылетел бы отказ.
        try await index.prepare()
        #expect(await index.networkFetchCount == 0)
    }

    @Test func staleStampMakesPrepareTryTheNetworkAgain() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Отметке двое суток — окно свежести сутки, значит пора обновляться.
        let old = Date().addingTimeInterval(-2 * 24 * 60 * 60)
        let stamp = ["fetchedAt": old.timeIntervalSinceReferenceDate,
                     "archiveBytes": 1, "databaseBytes": 1]
        try JSONSerialization.data(withJSONObject: stamp)
            .write(to: directory.appendingPathComponent("fetched-at.json"))

        await #expect(throws: (any Error).self) { try await index.prepare() }
        #expect(await index.networkFetchCount == 1)
        // ★ Неудачное обновление НЕ портит рабочий указатель: поиск по-прежнему идёт.
        #expect(try await index.search("git", limit: 50).count == 5)
    }

    @Test func stampFromTheFutureCountsAsStale() async throws {
        let (index, directory) = try Self.makeIndex()
        defer { try? FileManager.default.removeItem(at: directory) }

        // Часы съехали вперёд: возраст отметки отрицательный. Считать такую
        // отметку свежей — значит не обновляться, пока часы не догонят.
        let future = Date().addingTimeInterval(365 * 24 * 60 * 60)
        let stamp = ["fetchedAt": future.timeIntervalSinceReferenceDate,
                     "archiveBytes": 1, "databaseBytes": 1]
        try JSONSerialization.data(withJSONObject: stamp)
            .write(to: directory.appendingPathComponent("fetched-at.json"))

        await #expect(throws: (any Error).self) { try await index.prepare() }
        #expect(await index.networkFetchCount == 1)
    }

    // MARK: - Отсутствие распаковщика

    @Test func missingUnzipToolIsNamedExplicitly() async throws {
        let directory = try Self.makeCacheDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let index = WingetIndex(
            cacheDirectory: directory,
            sourceURL: URL(string: "https://nedostupno.macrunner.invalid/source2.msix")!,
            unzipTool: URL(fileURLWithPath: "/usr/bin/takogo-nyet-unzip")
        )
        // Проверка распаковщика идёт ДО сети: отказ обязан быть про инструмент,
        // а не про недостижимый адрес.
        await #expect(throws: WingetIndexError.unzipMissing("/usr/bin/takogo-nyet-unzip")) {
            try await index.prepare()
        }
        #expect(await index.networkFetchCount == 0)
    }

    // MARK: - Тексты отказов

    @Test func everyErrorHasReadableText() {
        let errors: [WingetIndexError] = [
            .notPrepared,
            .unzipMissing("/usr/bin/unzip"),
            .unzipFailed(code: 1, stderr: "плохой архив"),
            .httpStatus(503),
            .network("время вышло"),
            .archiveNotZip(bytes: 412),
            .databaseEntryMissing,
            .databaseUnreadable("file is not a database"),
            .databaseEmpty
        ]
        for error in errors {
            let text = error.errorDescription ?? ""
            #expect(!text.isEmpty, "у отказа \(error) нет текста")
        }
    }
}
