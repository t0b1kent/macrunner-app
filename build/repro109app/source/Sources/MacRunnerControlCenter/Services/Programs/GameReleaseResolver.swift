import Foundation

/// Поиск САМОЙ СВЕЖЕЙ версии игры — там, где её можно найти машинно.
///
/// ★ ЗАЧЕМ. В `games-catalog.json` у каждой игры лежит ЗАМОРОЖЕННАЯ ссылка с номером
///   версии внутри: `doomretro v6.3`, `inter-doom 9.0`, `BAR v1.2988.0`. Выйдет новая
///   версия — ссылка отдаст старьё или умрёт, и человек скачает не то, о чём мы ему
///   написали. Вопрос владельца был прямым: «как он выбирает версию? надо чтобы брал
///   самую свежую».
///
/// ★ ГРАНИЦА ЭТОГО ФАЙЛА — ТОЛЬКО GITHUB, и это не лень, а измеренная разбивка
///   источников каталога (52 игры): **itch 20, official 21, github 11**.
///   * `itch` (20) трогать НЕ НАДО вовсе: ссылка ведёт на страницу игры, автор
///     обновляет её сам, и протухнуть там нечему;
///   * `official` (21) — двадцать один разный сайт, общего машинного способа нет,
///     это отдельная работа, и здесь её НЕТ;
///   * `github` (11) — вот они и разрешаются здесь.
///
/// ★ ЗАГОЛОВОК `User-Agent` ОБЯЗАТЕЛЕН. Измерено на api.github.com: без него ответ
///   **403**, и снаружи это читается как «выпусков нет», хотя они есть.
///
/// ★ ЛИМИТ. Без ключа GitHub даёт **60 запросов в час на адрес**. Отсюда кеш в памяти:
///   одна игра — ОДИН запрос за весь сеанс работы приложения, повтор — ноль запросов.
///   Одиннадцать игр каталога = одиннадцать запросов из шестидесяти.
///
/// ★ ПОЧЕМУ НЕ ОДИН `/releases/latest`. У части проектов «latest» не выставлен вовсе
///   (метку ставят руками), и тогда этот путь отвечает 404 при живых выпусках. Поэтому
///   порядок такой: сперва `/releases/latest`, при 404 — список `/releases` и первый
///   выпуск, у которого `prerelease` и `draft` оба `false`.
///
/// ★★★ ИЗМЕРЕННАЯ ГРАНИЦА ПРАВИЛА «ПРОПУСКАТЬ ПРЕДВАРИТЕЛЬНЫЕ» (12.09.2026, живой
///   прогон по всем одиннадцати играм). У `OpenApoc/OpenApoc` предварительной помечена
///   КАЖДАЯ сборка: восемь верхних выпусков подряд `"prerelease": true`, а единственный
///   обычный — `20260408` от апреля. То есть здесь правило отдаёт версию СТАРШЕ той, что
///   стоит в каталоге (`20260910`), и это не поломка отбора, а прямое следствие правила.
///   Обратный случай — `OpenNox`: выпуск `v1.9.0-alpha13` НАЗВАН альфой, но помечен
///   обычным, и мы его берём. Вывод: решает ПОМЕТКА автора, а не вид имени; угадывать по
///   имени нельзя — OpenNox остался бы без единой версии. Выбор «брать ли свежую
///   предварительную, когда обычных давно нет» — за владельцем, а не за этим файлом.

// MARK: - Что отдаём наружу

/// Найденный выпуск: версия, выбранный файл и его адрес.
struct GameRelease: Equatable, Sendable {
    /// Метка выпуска как её написал автор (`v6.3`, `9.0`, `r14387`, `20260910`).
    /// Мы НЕ приводим её к «правильному» виду: именно эта строка стоит в адресе
    /// загрузки, и подмена вида сделала бы адрес несобираемым.
    let version: String
    let assetName: String
    let url: URL
    /// Размер по данным GitHub. `nil` — поля в ответе не было.
    let sizeBytes: Int?
    let publishedAt: Date?

    /// Размер в мегабайтах — в том же виде, в каком его показывает каталог.
    var sizeMB: Double? {
        guard let sizeBytes else { return nil }
        return (Double(sizeBytes) / 1_048_576 * 10).rounded() / 10
    }
}

// MARK: - Отказы

/// ★ Ни один отказ не превращается в пустоту: «годного файла нет» и «мы не смогли
///   спросить» — разные вещи. Пустой результат в этом проекте уже стоил часов
///   (правило про врущие приборы), поэтому у каждого случая своё имя.
enum GameReleaseError: LocalizedError, Equatable {
    /// Адрес не ведёт на GitHub — разрешать здесь нечего (и пробовать не нужно).
    case notAGitHubURL(String)
    /// Репозитория нет, или в нём нет НИ ОДНОГО обычного выпуска (только черновики
    /// и предварительные).
    case noReleases(String)
    /// Выпуск есть, а файла под Windows в нём нет. `available` — ВСЁ, что там лежало:
    /// без этого списка причину отказа не разобрать, и это не украшение.
    case noSuitableAsset(repo: String, version: String, available: [String])
    /// Лимит GitHub исчерпан. Отдельный случай: лечится ожиданием, а не другой игрой.
    case rateLimited
    case httpStatus(Int)
    /// Сеть не дошла ЛИБО ответ не разобрался. Второе слипается с первым не по
    /// небрежности: набор отказов задан снаружи и расширять его нельзя, поэтому
    /// нечитаемый ответ идёт сюда с явным текстом «ответ не разобран» — спутать
    /// его с обрывом связи нельзя.
    case network(String)

    var errorDescription: String? {
        switch self {
        case .notAGitHubURL(let url):
            return L("Not a GitHub download link: ") + url
        case .noReleases(let repo):
            return L("No published releases on GitHub for ") + repo
        case .noSuitableAsset(let repo, let version, let available):
            return L("No Windows build in the latest release of ") + "\(repo) \(version)"
                + " (" + available.joined(separator: ", ") + ")"
        case .rateLimited:
            return L("GitHub is rate-limiting us (60 requests per hour without a token). Try again later.")
        case .httpStatus(let code):
            return L("GitHub answered with HTTP ") + String(code)
        case .network(let reason):
            return L("Could not reach GitHub: ") + reason
        }
    }
}

// MARK: - Сырой ответ api.github.com

/// Один файл выпуска. Отдельно от `GameRelease`, потому что это ЧУЖАЯ схема: пусть
/// её изменения ломаются здесь, а не расходятся по приложению.
struct GitHubReleaseAsset: Decodable, Equatable, Sendable {
    let name: String
    /// Строкой, а не `URL`: один неразбираемый адрес не должен ронять весь выпуск —
    /// такую запись мы просто пропускаем при выборе.
    let downloadURL: String
    let size: Int?

    enum CodingKeys: String, CodingKey {
        case name
        case downloadURL = "browser_download_url"
        case size
    }
}

/// Один выпуск из списка `/releases`.
struct GitHubReleaseEntry: Decodable, Equatable, Sendable {
    let tagName: String
    let name: String?
    /// ★ Эти два поля и есть весь смысл разбора списка. `api.github.com` присылает их
    ///   ВСЕГДА, поэтому они обязательные: запись без них — это сломанный ответ, и
    ///   молча счесть предварительный выпуск обычным было бы хуже отказа.
    let prerelease: Bool
    let draft: Bool
    let publishedAt: Date?
    let assets: [GitHubReleaseAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name
        case prerelease
        case draft
        case publishedAt = "published_at"
        case assets
    }

    /// Обычный выпуск: не черновик и не предварительный.
    var isStable: Bool { !prerelease && !draft }
}

// MARK: - Резолвер

actor GameReleaseResolver {
    static let shared = GameReleaseResolver()

    /// ★ Без него api.github.com отвечает 403. Измерено, не предположено.
    static let userAgent = "MacRunner/0.9"

    private let session: URLSession
    /// Кеш на время работы приложения: требование «одна игра — один запрос».
    /// Срока жизни нет намеренно — сутки работы приложения против выпуска раз в месяц
    /// не стоят лишнего расхода из шестидесяти запросов в час. Ручной сброс —
    /// `invalidate()`, его зовёт кнопка «обновить».
    private var cache: [String: GameRelease] = [:]
    /// Задачи в полёте: два нажатия подряд по одной игре не должны дать два запроса.
    private var inFlight: [String: Task<GameRelease, Error>] = [:]

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

    // MARK: Разбор адреса

    /// Разбирает адрес вида `https://github.com/<владелец>/<репо>/releases/download/<тег>/<файл>`
    /// и возвращает `"владелец/репо"`. `nil` — если это не GitHub.
    ///
    /// Берём и короткие формы (`https://github.com/<владелец>/<репо>`, `/releases/tag/...`,
    /// `/archive/...`): репозиторий в них тот же, а отказываться от разрешимого адреса
    /// из-за формы пути — значит выдумывать себе стену.
    nonisolated static func repository(from url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = URL(string: trimmed), let host = parsed.host?.lowercased() else { return nil }

        var segments = parsed.path.split(separator: "/").map(String.init)
        switch host {
        case "github.com", "www.github.com":
            break
        case "api.github.com":
            // `/repos/<владелец>/<репо>/...` — та же пара, просто через API.
            guard segments.first == "repos" else { return nil }
            segments.removeFirst()
        default:
            // `objects.githubusercontent.com` и прочие перевалочные хосты владельца и
            // репозитория в пути НЕ несут, поэтому для них ответ честно `nil`.
            return nil
        }

        guard segments.count >= 2 else { return nil }
        let owner = segments[0]
        var repo = segments[1]
        if repo.hasSuffix(".git") { repo = String(repo.dropLast(4)) }
        guard !owner.isEmpty, !repo.isEmpty else { return nil }
        // Служебные разделы сайта владельцами не бывают.
        let reserved: Set<String> = ["features", "about", "pricing", "topics", "collections",
                                     "sponsors", "settings", "login", "join", "orgs", "apps",
                                     "marketplace", "explore", "trending", "notifications"]
        guard !reserved.contains(owner.lowercased()) else { return nil }
        return "\(owner)/\(repo)"
    }

    /// Тег из замороженного адреса загрузки — то, что стоит в каталоге СЕЙЧАС.
    /// Нужен, чтобы ответить на вопрос «а ссылка-то устарела?»: без тега сравнивать
    /// найденную версию не с чем.
    nonisolated static func tag(fromDownloadURL url: String) -> String? {
        guard let parsed = URL(string: url.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        let segments = parsed.path.split(separator: "/").map(String.init)
        // .../releases/download/<тег>/<файл>  или  .../releases/tag/<тег>
        guard let releases = segments.firstIndex(of: "releases"), segments.count > releases + 2 else { return nil }
        let kind = segments[releases + 1]
        guard kind == "download" || kind == "tag" else { return nil }
        return segments[releases + 2].removingPercentEncoding ?? segments[releases + 2]
    }

    // MARK: Наружу

    /// Последний НЕ предварительный выпуск и лучший файл под Windows.
    func latest(forRepository repo: String) async throws -> GameRelease {
        let cleaned = repo.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = cleaned.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
            throw GameReleaseError.notAGitHubURL(repo)
        }
        // Имена репозиториев на GitHub регистронезависимы — ключ кеша тоже, иначе
        // `OpenApoc/OpenApoc` и `openapoc/openapoc` дали бы два запроса из шестидесяти.
        let key = cleaned.lowercased()

        if let cached = cache[key] { return cached }
        if let running = inFlight[key] { return try await running.value }

        let task = Task<GameRelease, Error> { [session] in
            try await Self.fetch(repo: cleaned, session: session)
        }
        inFlight[key] = task
        defer { inFlight[key] = nil }

        let release = try await task.value
        cache[key] = release
        return release
    }

    /// Последний выпуск по адресу из каталога. Удобный вход для интерфейса: там на
    /// руках именно `download.url`, а не пара «владелец/репо».
    func latest(forDownloadURL url: String) async throws -> GameRelease {
        guard let repo = Self.repository(from: url) else {
            throw GameReleaseError.notAGitHubURL(url)
        }
        return try await latest(forRepository: repo)
    }

    /// Сбросить кеш — например, когда человек жмёт «обновить».
    func invalidate(_ repo: String? = nil) {
        if let repo { cache[repo.lowercased()] = nil } else { cache.removeAll() }
    }

    // MARK: - Выбор файла (без сети — чтобы проверялось тестом)

    /// Признаки, по которым файл НЕ БЕРЁМ НИКОГДА. Проверяются ПЕРВЫМИ, до всего
    /// остального: иначе `linux` или `macos` проскочат по совпадению внутри имени.
    ///
    /// ★ `darwin` в этом списке — НЕ перестраховка: в слове `darwin` содержится `win`,
    ///   и без запрета файл `…-darwin-arm64.tar.gz` был бы опознан как сборка под
    ///   Windows. Это ровно тот класс ошибки, который выглядит как работающий отбор.
    static let bannedMarkers = [
        // чужие системы
        "linux", "macos", "mac-os", "osx", "darwin", "freebsd", "android", "ios-",
        // чужие упаковки
        ".tar.gz", ".tar.xz", ".tar.bz2", ".tar.zst", ".tgz", ".appimage", ".deb", ".rpm",
        ".dmg", ".pkg", ".flatpak", ".snap",
        // не сборка, а подпись/сумма/исходники/отладочные данные
        "source code", "-source", "_source", "source.", ".asc", ".sig", ".sha256", ".sha512",
        ".sha1", ".md5", ".pdb", "symbols", "debuginfo"
    ]

    /// 64 бита. Список ШИРЕ, чем «win64/windows-x64/win-x64/x86_64», и это измерено на
    /// нашем же каталоге: у `OpenApoc` файл называется `OpenApoc-x64-20260910.zip` —
    /// в нём нет ни `win`, ни `x86_64`, и по узкому списку рабочая сборка была бы
    /// отвергнута. Недоопознать 64 бита опаснее, чем перестараться: это прямая дорога
    /// подсунуть человеку 32-битный файл, который у нас сегодня не пойдёт.
    static let markers64 = ["win64", "windows-x64", "windows_x64", "win-x64", "win_x64",
                            "x86_64", "x86-64", "x64", "amd64", "64bit", "64-bit"]

    /// 32 бита. Ищутся ТОЛЬКО когда 64-битных признаков в имени нет вовсе — иначе
    /// `x86` внутри `x86_64` объявил бы 64-битную сборку 32-битной.
    static let markers32 = ["win32", "windows-x86", "win-x86", "i386", "i686", "ia32",
                            "32bit", "32-bit", "x86"]

    /// Слова «это для Windows» без указания разрядности.
    static let markersWindows = ["windows", "win"]

    /// Расширения, которые мы умеем скачать и распаковать.
    static let goodExtensions = [".zip", ".7z", ".exe", ".msi", ".rar"]

    /// Место файла в порядке предпочтения. Меньше — лучше; `nil` — не берём вовсе.
    ///
    /// Порядок ровно тот, что задан правилом отбора:
    /// ```
    /// 0  64 бита + понятное расширение          doomretro-6.3-win64.zip
    /// 1  Windows без разрядности + расширение   opensurge-0.6.1.3-windows.zip, Setup.exe
    /// 2  64 бита, расширение необычное
    /// 3  Windows без разрядности, расширение необычное
    /// 4  32 бита — ТОЛЬКО если ничего выше нет
    /// ```
    /// ★ Почему `.exe` сам по себе считается признаком Windows: из одиннадцати игр
    ///   каталога ПЯТЬ публикуют установщик без слова `win` в имени
    ///   (`OpenFodder-Installer.exe`, `rigs-of-rods-2026.01.exe`,
    ///   `StuntRally-2.7-installer.exe`, `OpenNox-v1.9.0-alpha13.exe`,
    ///   `Beyond-All-Reason-1.2988.0.exe`). Требовать слово `win` значило бы отказать
    ///   почти половине каталога при живых и правильных файлах.
    static func rank(ofAssetNamed name: String) -> Int? {
        let lower = name.lowercased()
        guard !bannedMarkers.contains(where: { lower.contains($0) }) else { return nil }

        let extensionIsGood = goodExtensions.contains { lower.hasSuffix($0) }
        let isExecutable = lower.hasSuffix(".exe") || lower.hasSuffix(".msi")
        let has64 = markers64.contains { lower.contains($0) }
        // 32 бита ищем только при отсутствии 64-битных признаков — см. выше.
        let has32 = !has64 && markers32.contains { lower.contains($0) }
        let saysWindows = isExecutable || markersWindows.contains { lower.contains($0) }

        if has64 { return extensionIsGood ? 0 : 2 }
        if saysWindows && !has32 { return extensionIsGood ? 1 : 3 }
        if has32 { return 4 }
        return nil
    }

    /// Внутри одного разряда предпочтения: сборка с отладочными данными или ради
    /// сервера — тот же разряд, но хуже обычной. Порядок разрядов это НЕ меняет.
    private static func penalty(ofAssetNamed name: String) -> Int {
        let lower = name.lowercased()
        let secondary = ["debug", "dedicated", "server", "sdk", "devkit", "tools", "editor"]
        return secondary.contains(where: { lower.contains($0) }) ? 1 : 0
    }

    /// Лучший файл из готового списка. Отдельно от сети — чтобы правило отбора
    /// проверялось тестом без единого запроса.
    static func bestAsset(among assets: [GitHubReleaseAsset]) -> GitHubReleaseAsset? {
        assets.enumerated()
            .compactMap { pair -> (asset: GitHubReleaseAsset, key: (Int, Int, Int))? in
                // Адрес обязателен: файл, который нечем скачать, — не выбор.
                guard URL(string: pair.element.downloadURL) != nil else { return nil }
                guard let rank = rank(ofAssetNamed: pair.element.name) else { return nil }
                return (pair.element, (rank, penalty(ofAssetNamed: pair.element.name), pair.offset))
            }
            .min { $0.key < $1.key }?
            .asset
    }

    /// Первый обычный выпуск — в том порядке, в каком их отдал GitHub (новые сверху).
    static func firstStable(in releases: [GitHubReleaseEntry]) -> GitHubReleaseEntry? {
        releases.first(where: \.isStable)
    }

    // MARK: - Разбор ответа

    private static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Ответ `/releases` (список) ИЛИ `/releases/latest` (один объект) — одним входом.
    ///
    /// Вид ответа различаем ПО ПЕРВОМУ значащему знаку, а не попыткой-и-ошибкой:
    /// проглоченная ошибка разбора означала бы «выпусков нет» при сломанном ответе,
    /// а это разные вещи, и путать их нельзя.
    static func decodeReleases(_ data: Data) throws -> [GitHubReleaseEntry] {
        let whitespace: Set<UInt8> = [0x20, 0x09, 0x0A, 0x0D]
        let firstByte = data.first { !whitespace.contains($0) }
        do {
            if firstByte == UInt8(ascii: "[") {
                return try decoder().decode([GitHubReleaseEntry].self, from: data)
            }
            return [try decoder().decode(GitHubReleaseEntry.self, from: data)]
        } catch {
            throw GameReleaseError.network("ответ api.github.com не разобран: \(error)")
        }
    }

    /// Весь путь от текста ответа до выбранного файла. Тестам нужен именно он: так
    /// проверяется то, чем пользуется приложение, а не отдельно живущая копия правил.
    static func release(fromReleasesJSON json: String, repository repo: String) throws -> GameRelease {
        try release(from: try decodeReleases(Data(json.utf8)), repository: repo)
    }

    static func release(from releases: [GitHubReleaseEntry], repository repo: String) throws -> GameRelease {
        guard let stable = firstStable(in: releases) else {
            throw GameReleaseError.noReleases(repo)
        }
        guard let asset = bestAsset(among: stable.assets), let url = URL(string: asset.downloadURL) else {
            // ★ Здесь НЕЛЬЗЯ уйти искать файл в выпуске постарше: это молча отдало бы
            //   не самую свежую версию — ровно то, ради устранения чего всё написано.
            //   Честный отказ со списком имён лучше тихой подмены.
            throw GameReleaseError.noSuitableAsset(repo: repo,
                                                   version: stable.tagName,
                                                   available: stable.assets.map(\.name))
        }
        return GameRelease(version: stable.tagName,
                           assetName: asset.name,
                           url: url,
                           sizeBytes: asset.size,
                           publishedAt: stable.publishedAt)
    }

    // MARK: - Сеть

    private static func fetch(repo: String, session: URLSession) async throws -> GameRelease {
        let escaped = repo.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? repo

        // Шаг 1: `/releases/latest`. GitHub сам пропускает черновики и предварительные,
        // и это ОДИН запрос вместо списка.
        let latestURL = URL(string: "https://api.github.com/repos/\(escaped)/releases/latest")!
        do {
            let releases = try decodeReleases(try await get(latestURL, session: session))
            // Метки проверяем САМИ, хотя этот путь обещает их учитывать: обещание —
            // не измерение, а стоимость проверки ноль.
            if let stable = firstStable(in: releases) {
                return try release(from: [stable], repository: repo)
            }
        } catch GameReleaseError.httpStatus(404) {
            // Либо метки «latest» нет (её ставят руками), либо репозитория нет вовсе.
            // Различит это шаг 2: у несуществующего репозитория и список даст 404.
        }

        // Шаг 2: список. `per_page=30` — одним запросом хватает всем нашим проектам,
        // даже тем, кто публикует предварительные выпуски пачками.
        let listURL = URL(string: "https://api.github.com/repos/\(escaped)/releases?per_page=30")!
        do {
            let data = try await get(listURL, session: session)
            return try release(from: try decodeReleases(data), repository: repo)
        } catch GameReleaseError.httpStatus(404) {
            // 404 на самом списке — репозитория нет (или он закрыт). Для вызывающего
            // это одно и то же: свежей версии здесь не найти.
            throw GameReleaseError.noReleases(repo)
        }
    }

    private static func get(_ url: URL, session: URLSession) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw GameReleaseError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else { return data }
        switch http.statusCode {
        case 200...299:
            return data
        case 404:
            throw GameReleaseError.httpStatus(404)
        case 429:
            throw GameReleaseError.rateLimited
        case 403:
            // ★ 403 — НЕ всегда лимит: без `User-Agent` GitHub отвечает тем же кодом.
            //   Назвать это лимитом значит отправить себя ждать час из-за ошибки,
            //   которая правится одной строкой. Отличаем по счётчику в заголовке.
            let remaining = http.value(forHTTPHeaderField: "x-ratelimit-remaining")
            throw remaining == "0" ? GameReleaseError.rateLimited : GameReleaseError.httpStatus(403)
        default:
            throw GameReleaseError.httpStatus(http.statusCode)
        }
    }
}
