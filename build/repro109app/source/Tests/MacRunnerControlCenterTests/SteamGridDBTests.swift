import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Проверяем разбор ответов SteamGridDB и выбор обложки — то есть части, которые
/// ломаются молча. Сеть здесь не нужна: ответ подан как есть, из настоящих полей API.
struct SteamGridDBTests {

    // MARK: - Разбор ответа

    @Test func gameDecodesFromAutocompleteShape() throws {
        let json = Data("""
        {"id": 1234, "name": "Hollow Knight", "types": ["steam"], "verified": true}
        """.utf8)
        let game = try JSONDecoder().decode(SteamGridDBService.Game.self, from: json)
        #expect(game.id == 1234)
        #expect(game.name == "Hollow Knight")
    }

    @Test func artworkDecodesAndKeepsDimensions() throws {
        let json = Data("""
        {"id": 77, "url": "https://cdn2.steamgriddb.com/grid/abc.png",
         "thumb": "https://cdn2.steamgriddb.com/thumb/abc.jpg", "width": 600, "height": 900}
        """.utf8)
        let art = try JSONDecoder().decode(SteamGridDBService.Artwork.self, from: json)
        #expect(art.id == 77)
        #expect(art.width == 600)
        #expect(art.height == 900)
        #expect(art.url.host() == "cdn2.steamgriddb.com")
    }

    /// В ответе размеры бывают пустыми — это не должно ронять разбор всего списка.
    @Test func artworkDecodesWithoutDimensions() throws {
        let json = Data("""
        {"id": 5, "url": "https://cdn2.steamgriddb.com/grid/x.png"}
        """.utf8)
        let art = try JSONDecoder().decode(SteamGridDBService.Artwork.self, from: json)
        #expect(art.width == nil)
        #expect(art.thumb == nil)
    }

    // MARK: - Выбор обложки

    @Test func pickBestPrefersPortraitTwoToThree() {
        let service = SteamGridDBService()
        let wide = SteamGridDBService.Artwork(
            id: 1, url: URL(string: "https://x/1.png")!, thumb: nil, width: 920, height: 430)
        let portrait = SteamGridDBService.Artwork(
            id: 2, url: URL(string: "https://x/2.png")!, thumb: nil, width: 600, height: 900)
        let square = SteamGridDBService.Artwork(
            id: 3, url: URL(string: "https://x/3.png")!, thumb: nil, width: 512, height: 512)
        #expect(service.pickBest([wide, portrait, square])?.id == 2)
    }

    /// Обложка без размеров годится, но встаёт ПОСЛЕ любой измеримой:
    /// иначе одна битая запись перебила бы правильную.
    @Test func pickBestPutsUnmeasuredLast() {
        let service = SteamGridDBService()
        let unknown = SteamGridDBService.Artwork(
            id: 9, url: URL(string: "https://x/9.png")!, thumb: nil, width: nil, height: nil)
        let portrait = SteamGridDBService.Artwork(
            id: 2, url: URL(string: "https://x/2.png")!, thumb: nil, width: 600, height: 900)
        #expect(service.pickBest([unknown, portrait])?.id == 2)
        #expect(service.pickBest([unknown])?.id == 9)
    }

    @Test func pickBestOnEmptyListIsNil() {
        #expect(SteamGridDBService().pickBest([]) == nil)
    }

    // MARK: - Границы

    /// Пустое название в сеть не ходит вовсе — иначе каждая безымянная запись
    /// библиотеки тратила бы квоту пользователя.
    @Test func searchIgnoresEmptyTitle() async throws {
        let service = SteamGridDBService()
        #expect(try await service.search(title: "   ").isEmpty)
    }

    /// Имя файла в кеше считается ОДНИМ правилом для магазинов и SteamGridDB.
    /// Разъедься они — уже скачанная обложка перестала бы находиться.
    @Test func cacheIdentifierIsShared() {
        #expect(CoverCache.safeIdentifier("Hollow Knight: Silksong") == "Hollow-Knight--Silksong")
        #expect(CoverCache.safeIdentifier("abzu_2016") == "abzu_2016")
    }

    @Test func gridDBHasItsOwnProviderFolder() {
        #expect(CoverCache.gridDBProvider == "steamgriddb")
    }

    /// ★ Скачанное `download` находит `downloadedCover` — тем же путём и с тем же
    ///   расширением. Витрина искала в другой папке, и кэш не срабатывал ни разу:
    ///   обложки качались заново при каждом открытии (23.09.2026).
    @Test func downloadedCoverIsFoundWhereDownloadPutIt() async throws {
        let sandbox = try TemporaryCoverRoot()
        let art = try sandbox.writeFakeArtwork(named: "cover.jpg")
        let cache = CoverCache(root: sandbox.root, limitBytes: 8 * 1024 * 1024)
        #expect(cache.downloadedCover(for: art, id: "game/doom-retro") == nil)
        let saved = try await cache.download(art, id: "game/doom-retro")
        #expect(saved.pathExtension == "jpg")
        #expect(cache.downloadedCover(for: art, id: "game/doom-retro") == saved)
    }

    // MARK: - Цепочка источников

    /// Наш посредник идёт ПЕРВЫМ: от человека он ничего не требует, а прямое обращение
    /// к SteamGridDB нуждается в ключе. Перепутай порядок — и обложек не будет ни у кого,
    /// кто ключ не завёл, то есть почти у всех.
    @Test func proxyComesBeforeDirectAccess() {
        let sources = CoverCache.defaultSources()
        #expect(sources.count == 2)
        #expect(sources[0] is MacRunnerCoverAPI)
        #expect(sources[1] is SteamGridDBService)
    }

    private struct SilentSource: CoverArtSource {
        func artworkURL(title: String) async -> URL? { nil }
    }

    private struct FixedSource: CoverArtSource {
        let url: URL
        func artworkURL(title: String) async -> URL? { url }
    }

    /// Молчащий источник не должен обрывать поиск — берём следующий.
    @Test func fallsThroughSilentSourceToTheNextOne() async throws {
        let sandbox = try TemporaryCoverRoot()
        let art = try sandbox.writeFakeArtwork(named: "cover.png")
        let cache = CoverCache(root: sandbox.root, limitBytes: 8 * 1024 * 1024)

        let resolved = await cache.resolvedCover(
            provider: "manual", id: "abzu", title: "ABZU",
            sources: [SilentSource(), FixedSource(url: art)]
        )

        #expect(resolved.deletingLastPathComponent().lastPathComponent == CoverCache.gridDBProvider)
        #expect(FileManager.default.fileExists(atPath: resolved.path))
    }

    /// Все молчат — рисуем заглушку, но кладём её под провайдером МАГАЗИНА.
    /// Так следующий заход снова сходит в сеть: под `steamgriddb` файла нет.
    @Test func drawnPlaceholderIsTheLastResortAndNotFinal() async throws {
        let sandbox = try TemporaryCoverRoot()
        let cache = CoverCache(root: sandbox.root, limitBytes: 8 * 1024 * 1024)

        let resolved = await cache.resolvedCover(
            provider: "manual", id: "unknown-game", title: "Игра без обложки",
            sources: [SilentSource()]
        )

        #expect(resolved.deletingLastPathComponent().lastPathComponent == "manual")
        #expect(cache.cachedCover(provider: CoverCache.gridDBProvider, id: "unknown-game") == nil)
    }

    /// Уже скачанное в сеть не ходит повторно.
    @Test func cachedArtworkShortCircuitsTheChain() async throws {
        let sandbox = try TemporaryCoverRoot()
        let art = try sandbox.writeFakeArtwork(named: "cover.png")
        let cache = CoverCache(root: sandbox.root, limitBytes: 8 * 1024 * 1024)

        let first = await cache.resolvedCover(
            provider: "manual", id: "wrath", title: "WRATH",
            sources: [FixedSource(url: art)]
        )
        let second = await cache.resolvedCover(
            provider: "manual", id: "wrath", title: "WRATH",
            sources: [SilentSource()]
        )
        #expect(first == second)
    }
}

/// Свой корень кеша на каждый тест: иначе тесты писали бы в настоящий
/// `~/Library/Caches` пользователя и мешали друг другу.
private struct TemporaryCoverRoot {
    let root: URL

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("macrunner-cover-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    /// Настоящий PNG 1×1 — источник отдаёт на него адрес `file://`,
    /// и загрузка проверяется без сети.
    func writeFakeArtwork(named name: String) throws -> URL {
        let url = root.appendingPathComponent(name)
        let png = Data(base64Encoded: """
        iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==
        """)!
        try png.write(to: url)
        return url
    }
}
