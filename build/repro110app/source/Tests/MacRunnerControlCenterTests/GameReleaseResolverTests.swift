import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Здесь проверяется ОТБОР ВЕРСИИ И ФАЙЛА, а не доступность GitHub.
///
/// Сети в этих проверках нет и быть не должно: ответы вставлены СТРОКАМИ, и две главные
/// подложки — куски НАСТОЯЩИХ ответов `api.github.com` по двум играм НАШЕГО каталога
/// (`OpenNox/OpenNox` и `bradharding/doomretro`, взяты 12.09.2026). Тест, который
/// зависит от сети, краснеет по чужим причинам и перестаёт быть прибором.
///
/// Живая проверка сетью — отдельным тестом внизу, и она включается ТОЛЬКО переменной
/// `MACRUNNER_GAMES_LIVE=1`: она печатает таблицу по всем одиннадцати играм каталога,
/// у которых `host_kind == "github"`, и расходует лимит GitHub (60 запросов в час).
struct GameReleaseResolverTests {

    // MARK: - Подложка: настоящий ответ api.github.com

    /// НАСТОЯЩИЙ ответ `/repos/OpenNox/OpenNox/releases?per_page=6` — записи ТРЕТЬЯ и
    /// ЧЕТВЁРТАЯ как есть (в полном ответе перед ними идут две более новые). Поля
    /// обрезаны до тех, что мы разбираем; значения не тронуты.
    ///
    /// ★ Ценность именно в порядке: сверху `v1.8.12-alpha11` с `"prerelease": true`,
    ///   под ней обычная `v1.8.12-alpha10`. «Взять первую» отдало бы предварительную
    ///   сборку — случай не выдуманный, а взятый с живого проекта ИЗ НАШЕГО каталога.
    ///
    /// ★ И второе, что здесь настоящее: в выпуске лежат `.AppImage`, `linux.tar.gz`,
    ///   `.exe` и `.zip` — то есть отбор обязан пройти мимо трёх файлов, чтобы взять
    ///   четвёртый.
    static let opennoxJSON = #"""
    [
      {
        "tag_name": "v1.8.12-alpha11",
        "name": "v1.8.12-alpha11",
        "draft": false,
        "prerelease": true,
        "published_at": "2023-11-23T20:58:39Z",
        "assets": [
          {
            "name": "opennox-bundle-i386.AppImage",
            "size": 68497456,
            "browser_download_url": "https://github.com/opennox/opennox/releases/download/v1.8.12-alpha11/opennox-bundle-i386.AppImage"
          },
          {
            "name": "OpenNox-linux-v1.8.12-alpha11.tar.gz",
            "size": 60480865,
            "browser_download_url": "https://github.com/opennox/opennox/releases/download/v1.8.12-alpha11/OpenNox-linux-v1.8.12-alpha11.tar.gz"
          },
          {
            "name": "OpenNox-v1.8.12-alpha11.exe",
            "size": 64249824,
            "browser_download_url": "https://github.com/opennox/opennox/releases/download/v1.8.12-alpha11/OpenNox-v1.8.12-alpha11.exe"
          },
          {
            "name": "OpenNox-v1.8.12-alpha11.zip",
            "size": 86749255,
            "browser_download_url": "https://github.com/opennox/opennox/releases/download/v1.8.12-alpha11/OpenNox-v1.8.12-alpha11.zip"
          }
        ]
      },
      {
        "tag_name": "v1.8.12-alpha10",
        "name": "v1.8.12-alpha10",
        "draft": false,
        "prerelease": false,
        "published_at": "2023-09-27T06:15:39Z",
        "assets": [
          {
            "name": "opennox-bundle-i386.AppImage",
            "size": 67489840,
            "browser_download_url": "https://github.com/opennox/opennox/releases/download/v1.8.12-alpha10/opennox-bundle-i386.AppImage"
          },
          {
            "name": "OpenNox-linux-v1.8.12-alpha10.tar.gz",
            "size": 59464668,
            "browser_download_url": "https://github.com/opennox/opennox/releases/download/v1.8.12-alpha10/OpenNox-linux-v1.8.12-alpha10.tar.gz"
          },
          {
            "name": "OpenNox-v1.8.12-alpha10.exe",
            "size": 63322468,
            "browser_download_url": "https://github.com/opennox/opennox/releases/download/v1.8.12-alpha10/OpenNox-v1.8.12-alpha10.exe"
          },
          {
            "name": "OpenNox-v1.8.12-alpha10.zip",
            "size": 85373650,
            "browser_download_url": "https://github.com/opennox/opennox/releases/download/v1.8.12-alpha10/OpenNox-v1.8.12-alpha10.zip"
          }
        ]
      }
    ]
    """#

    /// НАСТОЯЩИЙ ответ `/repos/bradharding/doomretro/releases?per_page=5` ЦЕЛИКОМ
    /// (12.09.2026), поля обрезаны до разбираемых.
    ///
    /// ★ Ценность в выпуске `v6.1`: там лежат ОБА файла, `win32` и `win64`. Это живой
    ///   случай для правила «32 бита только если 64-битного нет вовсе» — придумывать
    ///   его не понадобилось.
    static let doomretroJSON = #"""
    [
      {
        "tag_name": "v6.3",
        "name": "DOOM Retro v6.3",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-08-08T01:05:37Z",
        "assets": [
          {
            "name": "doomretro-6.3-win64.zip",
            "size": 4196567,
            "browser_download_url": "https://github.com/bradharding/doomretro/releases/download/v6.3/doomretro-6.3-win64.zip"
          }
        ]
      },
      {
        "tag_name": "v6.2",
        "name": "DOOM Retro v6.2",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-07-03T06:59:48Z",
        "assets": [
          {
            "name": "doomretro-6.2-win64.zip",
            "size": 4102087,
            "browser_download_url": "https://github.com/bradharding/doomretro/releases/download/v6.2/doomretro-6.2-win64.zip"
          }
        ]
      },
      {
        "tag_name": "v6.1.1",
        "name": "DOOM Retro v6.1.1",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-06-13T21:46:19Z",
        "assets": [
          {
            "name": "doomretro-6.1.1-win64.zip",
            "size": 4235282,
            "browser_download_url": "https://github.com/bradharding/doomretro/releases/download/v6.1.1/doomretro-6.1.1-win64.zip"
          }
        ]
      },
      {
        "tag_name": "v6.1",
        "name": "DOOM Retro v6.1",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-06-05T05:35:37Z",
        "assets": [
          {
            "name": "doomretro-6.1-win32.zip",
            "size": 3863515,
            "browser_download_url": "https://github.com/bradharding/doomretro/releases/download/v6.1/doomretro-6.1-win32.zip"
          },
          {
            "name": "doomretro-6.1-win64.zip",
            "size": 4213199,
            "browser_download_url": "https://github.com/bradharding/doomretro/releases/download/v6.1/doomretro-6.1-win64.zip"
          }
        ]
      },
      {
        "tag_name": "v6.0",
        "name": "DOOM Retro v6.0",
        "draft": false,
        "prerelease": false,
        "published_at": "2026-05-10T00:02:07Z",
        "assets": [
          {
            "name": "doomretro-6.0-win32.zip",
            "size": 3847749,
            "browser_download_url": "https://github.com/bradharding/doomretro/releases/download/v6.0/doomretro-6.0-win32.zip"
          },
          {
            "name": "doomretro-6.0-win64.zip",
            "size": 4205275,
            "browser_download_url": "https://github.com/bradharding/doomretro/releases/download/v6.0/doomretro-6.0-win64.zip"
          }
        ]
      }
    ]
    """#

    // MARK: - Свой набор ответов для матрицы файлов

    /// Ответ той же формы, что у GitHub, но с заданными именами файлов: матрицу
    /// «какой файл выбирается» надо гонять по многим наборам, а живых выпусков с
    /// нужными сочетаниями не бывает.
    static func releasesJSON(_ releases: [(tag: String, prerelease: Bool, draft: Bool, assets: [String])]) -> String {
        let bodies = releases.map { release -> String in
            let assets = release.assets.map { name -> String in
                let escaped = name.replacingOccurrences(of: " ", with: "%20")
                return """
                  {
                    "name": "\(name)",
                    "size": 4194304,
                    "browser_download_url": "https://github.com/acme/game/releases/download/\(release.tag)/\(escaped)"
                  }
                """
            }
            return """
            {
              "tag_name": "\(release.tag)",
              "name": "\(release.tag)",
              "draft": \(release.draft),
              "prerelease": \(release.prerelease),
              "published_at": "2026-09-01T10:00:00Z",
              "assets": [
            \(assets.joined(separator: ",\n"))
              ]
            }
            """
        }
        return "[\n" + bodies.joined(separator: ",\n") + "\n]"
    }

    private static func resolve(_ assets: [String], tag: String = "v2.0") throws -> GameRelease {
        let json = releasesJSON([(tag: tag, prerelease: false, draft: false, assets: assets)])
        return try GameReleaseResolver.release(fromReleasesJSON: json, repository: "acme/game")
    }

    // MARK: - Предварительные выпуски

    /// ★ ГЛАВНОЕ: предварительный выпуск пропускается, берётся СЛЕДУЮЩИЙ обычный.
    ///   На настоящем ответе OpenNox: сверху `v1.8.12-alpha11` с `"prerelease": true`,
    ///   годная — `v1.8.12-alpha10`.
    @Test func prereleaseIsSkippedAndTheNextStableIsTaken() throws {
        let releases = try GameReleaseResolver.decodeReleases(Data(Self.opennoxJSON.utf8))
        // Сначала показываем, что подложка настоящая и содержит именно тот случай:
        // иначе проверка «пропустили предварительный» прошла бы на пустом месте.
        #expect(releases.count == 2)
        #expect(releases[0].prerelease == true, "в подложке сверху должен лежать предварительный выпуск")
        #expect(releases[1].prerelease == false)

        let release = try GameReleaseResolver.release(from: releases, repository: "OpenNox/OpenNox")
        #expect(release.version == "v1.8.12-alpha10")
        #expect(release.version != releases[0].tagName)   // а вот что дало бы «взять первый»
        // И файл выбран мимо `.AppImage`, `linux.tar.gz` и `.zip` без пометки Windows.
        #expect(release.assetName == "OpenNox-v1.8.12-alpha10.exe")
        #expect(release.url.absoluteString
                == "https://github.com/opennox/opennox/releases/download/v1.8.12-alpha10/OpenNox-v1.8.12-alpha10.exe")
        #expect(release.sizeBytes == 63_322_468)
        #expect(release.publishedAt != nil)
    }

    /// Настоящий ответ doomretro целиком: форма разбирается, самая свежая — `v6.3`,
    /// дата и размер приезжают числами, а не «как-нибудь».
    @Test func parsesTheRealDoomretroAnswer() throws {
        let releases = try GameReleaseResolver.decodeReleases(Data(Self.doomretroJSON.utf8))
        #expect(releases.count == 5)
        #expect(releases.map(\.tagName) == ["v6.3", "v6.2", "v6.1.1", "v6.1", "v6.0"])

        let release = try GameReleaseResolver.release(from: releases, repository: "bradharding/doomretro")
        #expect(release.version == "v6.3")
        #expect(release.assetName == "doomretro-6.3-win64.zip")
        #expect(release.sizeBytes == 4_196_567)
        #expect(release.sizeMB == 4.0)
        // 2026-08-08T01:05:37Z — дата обязана разобраться, иначе «когда вышло» пропадёт.
        let stamp = try #require(release.publishedAt)
        #expect(abs(stamp.timeIntervalSince1970 - 1_786_151_137) < 1)
    }

    /// ★ ЖИВОЙ случай «в одном выпуске и 32, и 64 бита»: doomretro `v6.1` публиковал
    ///   `win32` и `win64` рядом. Придумывать этот набор не понадобилось.
    @Test func realReleaseWithBothBitnessesGivesWin64() throws {
        let releases = try GameReleaseResolver.decodeReleases(Data(Self.doomretroJSON.utf8))
        let v61 = try #require(releases.first { $0.tagName == "v6.1" })
        #expect(v61.assets.map(\.name) == ["doomretro-6.1-win32.zip", "doomretro-6.1-win64.zip"])
        #expect(GameReleaseResolver.bestAsset(among: v61.assets)?.name == "doomretro-6.1-win64.zip")
        // Порядок в ответе тут против нас: 32 бита лежат ПЕРВЫМИ. «Взять первый файл»
        // отдало бы именно их — то есть заведомо неработающую сборку.
        #expect(v61.assets.first?.name == "doomretro-6.1-win32.zip")
    }

    /// Черновик — тоже не выпуск. Проверяем отдельно от `prerelease`: это разные поля,
    /// и пропустить можно ровно одно из двух.
    @Test func draftIsSkippedToo() throws {
        let json = Self.releasesJSON([
            (tag: "v3.0", prerelease: false, draft: true, assets: ["game-3.0-win64.zip"]),
            (tag: "v2.9", prerelease: true, draft: false, assets: ["game-2.9-win64.zip"]),
            (tag: "v2.8", prerelease: false, draft: false, assets: ["game-2.8-win64.zip"])
        ])
        let release = try GameReleaseResolver.release(fromReleasesJSON: json, repository: "acme/game")
        #expect(release.version == "v2.8")
    }

    /// Отрицательный контроль прибора: если ВСЕ выпуски предварительные, ответ обязан
    /// быть отказом, а не «последним из того, что есть». Молча отдать предварительную
    /// сборку хуже, чем сказать «нет».
    @Test func allPrereleasesMeanNoReleases() {
        let json = Self.releasesJSON([
            (tag: "v3.0-rc1", prerelease: true, draft: false, assets: ["game-win64.zip"]),
            (tag: "v3.0-rc2", prerelease: true, draft: false, assets: ["game-win64.zip"])
        ])
        let thrown = #expect(throws: GameReleaseError.self) {
            _ = try GameReleaseResolver.release(fromReleasesJSON: json, repository: "acme/game")
        }
        #expect(thrown == .noReleases("acme/game"))
    }

    /// Пустой список выпусков — тоже отказ, а не пустой результат.
    @Test func emptyReleaseListMeansNoReleases() {
        let thrown = #expect(throws: GameReleaseError.self) {
            _ = try GameReleaseResolver.release(fromReleasesJSON: "[]", repository: "acme/game")
        }
        #expect(thrown == .noReleases("acme/game"))
    }

    // MARK: - Отбор файла

    /// ★ Набор из задания: {linux.tar.gz, win32.zip, win64.zip, Source code} -> win64.zip.
    @Test func picksWin64OutOfTheFullSet() throws {
        let release = try Self.resolve([
            "game-2.0-linux.tar.gz",
            "game-2.0-win32.zip",
            "game-2.0-win64.zip",
            "Source code (zip)"
        ])
        #expect(release.assetName == "game-2.0-win64.zip")
    }

    /// Порядок в ответе не должен ничего решать: тот же набор задом наперёд.
    @Test func orderInTheAnswerDoesNotDecide() throws {
        let release = try Self.resolve([
            "Source code (zip)",
            "game-2.0-win64.zip",
            "game-2.0-win32.zip",
            "game-2.0-linux.tar.gz"
        ])
        #expect(release.assetName == "game-2.0-win64.zip")
    }

    /// ★ 32 бита берём ТОЛЬКО когда 64-битного нет вовсе: {linux.tar.gz, win32.zip} -> win32.zip.
    @Test func takesWin32OnlyWhenThereIsNo64Bit() throws {
        let release = try Self.resolve(["game-2.0-linux.tar.gz", "game-2.0-win32.zip"])
        #expect(release.assetName == "game-2.0-win32.zip")
    }

    /// ★ Набор без единой сборки под Windows -> отказ СО СПИСКОМ ИМЁН. Список — не
    ///   украшение: без него причину отказа не разобрать.
    @Test func noWindowsBuildMeansNoSuitableAssetWithTheNames() {
        let json = Self.releasesJSON([(tag: "v2.0", prerelease: false, draft: false,
                                       assets: ["game-2.0-linux.tar.gz", "game-2.0-macos.dmg"])])
        let thrown = #expect(throws: GameReleaseError.self) {
            _ = try GameReleaseResolver.release(fromReleasesJSON: json, repository: "acme/game")
        }
        #expect(thrown == .noSuitableAsset(repo: "acme/game",
                                           version: "v2.0",
                                           available: ["game-2.0-linux.tar.gz", "game-2.0-macos.dmg"]))
        // Имена обязаны попасть в ТЕКСТ отказа — его читает человек, а не отладчик.
        let text = thrown?.errorDescription ?? ""
        #expect(text.contains("game-2.0-linux.tar.gz"))
        #expect(text.contains("game-2.0-macos.dmg"))
    }

    /// Разряды предпочтения по одному файлу — чтобы падение было адресным, а не
    /// «где-то в отборе».
    @Test func rankOrdersTheKindsOfNames() {
        // 0 — 64 бита с понятным расширением
        #expect(GameReleaseResolver.rank(ofAssetNamed: "doomretro-6.3-win64.zip") == 0)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "OpenApoc-x64-20260910.zip") == 0)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-x86_64-setup.exe") == 0)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "nblood_win64_20260826-r14387.7z") == 0)
        // 1 — Windows без разрядности
        #expect(GameReleaseResolver.rank(ofAssetNamed: "opensurge-0.6.1.3-windows.zip") == 1)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "OpenFodder-Installer.exe") == 1)
        // 4 — 32 бита, последний выбор
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-2.0-win32.zip") == 4)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-2.0-i386.zip") == 4)
        // nil — не берём вовсе
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-2.0-linux.tar.gz") == nil)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-2.0-macos.dmg") == nil)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-2.0.AppImage") == nil)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game_2.0_amd64.deb") == nil)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "Source code (tar.gz)") == nil)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-2.0-win64.zip.sha256") == nil)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-2.0-win64.zip.asc") == nil)
        // И чего быть не должно: имя вообще ни о чём — не Windows.
        #expect(GameReleaseResolver.rank(ofAssetNamed: "changelog.txt") == nil)
    }

    /// ★ `x86` внутри `x86_64` — ловушка, из-за которой 64-битная сборка объявлялась бы
    ///   32-битной и уезжала в последний разряд. Проверяем именно её.
    @Test func x86InsideX8664IsNotThirtyTwoBit() throws {
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-win-x86_64.zip") == 0)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-win-x86-64.zip") == 0)
        // И выбор между ними: 64 бита обязаны победить, даже если 32 идут первыми.
        let release = try Self.resolve(["game-win-x86.zip", "game-win-x86_64.zip"])
        #expect(release.assetName == "game-win-x86_64.zip")
    }

    /// ★ В слове `darwin` СОДЕРЖИТСЯ `win`. Без отдельного запрета сборка под macOS
    ///   опознавалась бы как Windows — и отбор выглядел бы работающим.
    @Test func darwinIsNotWindows() {
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-2.0-darwin-arm64.tar.gz") == nil)
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-2.0-darwin-x64.zip") == nil)
        // Контроль прибора: сам запрет не должен глотать нормальное имя с `win`.
        #expect(GameReleaseResolver.rank(ofAssetNamed: "game-2.0-win64.zip") == 0)
    }

    /// Отладочные и серверные сборки — того же разряда, но хуже обычной. Разряды это
    /// НЕ меняет: 64-битная отладочная всё равно лучше 32-битной обычной.
    @Test func debugAndServerBuildsLoseToTheNormalOne() throws {
        let release = try Self.resolve(["game-2.0-win64-debug.zip", "game-2.0-win64.zip"])
        #expect(release.assetName == "game-2.0-win64.zip")

        let onlyDebug = try Self.resolve(["game-2.0-win64-debug.zip", "game-2.0-win32.zip"])
        #expect(onlyDebug.assetName == "game-2.0-win64-debug.zip")
    }

    /// Файл без адреса брать нечем — запись пропускается, а не роняет весь выпуск.
    @Test func assetWithoutAUsableURLIsSkipped() {
        let assets = [
            GitHubReleaseAsset(name: "game-win64.zip", downloadURL: "", size: nil),
            GitHubReleaseAsset(name: "game-windows.zip",
                               downloadURL: "https://github.com/acme/game/releases/download/v1/game-windows.zip",
                               size: 10)
        ]
        #expect(GameReleaseResolver.bestAsset(among: assets)?.name == "game-windows.zip")
        #expect(GameReleaseResolver.bestAsset(among: []) == nil)
    }

    /// ★★★ ПЕРЕПИСЬ ПО ЖИВОМУ КАТАЛОГУ: каждое из одиннадцати имён, которые мы
    ///   публикуем СЕГОДНЯ, обязано получить разряд. Ноль здесь означал бы, что отбор
    ///   отказал бы игре, которая работает.
    @Test func everyAssetNameShippedInTheCatalogIsAccepted() {
        let shipped = [
            "doomretro-6.3-win64.zip",
            "inter-doom-9.0-win64.zip",
            "OpenApoc-x64-20260910.zip",
            "nblood_win64_20260826-r14387.7z",
            "RBDOOM-3-BFG-1.6.0.22-full-win64-20250510-git-ba39ba6.7z",
            "Beyond-All-Reason-1.2988.0.exe",
            "OpenFodder-Installer.exe",
            "rigs-of-rods-2026.01.exe",
            "StuntRally-2.7-installer.exe",
            "OpenNox-v1.9.0-alpha13.exe",
            "opensurge-0.6.1.3-windows.zip"
        ]
        let rejected = shipped.filter { GameReleaseResolver.rank(ofAssetNamed: $0) == nil }
        #expect(rejected.isEmpty, "отбор отверг рабочие имена: \(rejected.joined(separator: ", "))")
        // И ни одно из них не должно попасть в последний, 32-битный разряд.
        let demoted = shipped.filter { GameReleaseResolver.rank(ofAssetNamed: $0) == 4 }
        #expect(demoted.isEmpty, "рабочие имена приняты за 32-битные: \(demoted.joined(separator: ", "))")
    }

    // MARK: - Разбор адреса

    /// Настоящие адреса из `games-catalog.json` — все одиннадцать.
    @Test func parsesEveryRealDownloadURLInTheCatalog() {
        let cases: [(String, String)] = [
            ("https://github.com/bradharding/doomretro/releases/download/v6.3/doomretro-6.3-win64.zip",
             "bradharding/doomretro"),
            ("https://github.com/JNechaevsky/international-doom/releases/download/9.0/inter-doom-9.0-win64.zip",
             "JNechaevsky/international-doom"),
            ("https://github.com/OpenApoc/OpenApoc/releases/download/20260910/OpenApoc-x64-20260910.zip",
             "OpenApoc/OpenApoc"),
            ("https://github.com/nukeykt/NBlood/releases/download/r14387/nblood_win64_20260826-r14387.7z",
             "nukeykt/NBlood"),
            ("https://github.com/RobertBeckebans/RBDOOM-3-BFG/releases/download/v1.6.0/RBDOOM-3-BFG-1.6.0.22-full-win64-20250510-git-ba39ba6.7z",
             "RobertBeckebans/RBDOOM-3-BFG"),
            ("https://github.com/beyond-all-reason/BYAR-Chobby/releases/download/v1.2988.0/Beyond-All-Reason-1.2988.0.exe",
             "beyond-all-reason/BYAR-Chobby"),
            ("https://github.com/OpenFodder/openfodder/releases/download/2.0.0/OpenFodder-Installer.exe",
             "OpenFodder/openfodder"),
            ("https://github.com/RigsOfRods/rigs-of-rods/releases/download/2026.01/rigs-of-rods-2026.01.exe",
             "RigsOfRods/rigs-of-rods"),
            ("https://github.com/stuntrally/stuntrally/releases/download/2.7/StuntRally-2.7-installer.exe",
             "stuntrally/stuntrally"),
            ("https://github.com/OpenNox/OpenNox/releases/download/v1.9.0-alpha13/OpenNox-v1.9.0-alpha13.exe",
             "OpenNox/OpenNox"),
            ("https://github.com/alemart/opensurge/releases/download/v0.6.1.3/opensurge-0.6.1.3-windows.zip",
             "alemart/opensurge")
        ]
        for (url, expected) in cases {
            #expect(GameReleaseResolver.repository(from: url) == expected, "не разобран: \(url)")
        }
    }

    /// Короткие формы — тот же репозиторий: отказываться от разрешимого адреса из-за
    /// формы пути значит выдумывать себе стену.
    @Test func parsesShortFormsToo() {
        #expect(GameReleaseResolver.repository(from: "https://github.com/OpenNox/OpenNox") == "OpenNox/OpenNox")
        #expect(GameReleaseResolver.repository(from: "https://github.com/OpenNox/OpenNox/") == "OpenNox/OpenNox")
        #expect(GameReleaseResolver.repository(from: "https://github.com/OpenNox/OpenNox.git") == "OpenNox/OpenNox")
        #expect(GameReleaseResolver.repository(from: "https://www.github.com/alemart/opensurge/releases")
                == "alemart/opensurge")
        #expect(GameReleaseResolver.repository(from: "https://api.github.com/repos/alemart/opensurge/releases/latest")
                == "alemart/opensurge")
    }

    /// ★ ОТРИЦАТЕЛЬНЫЙ КОНТРОЛЬ: не-GitHub обязан дать `nil`, иначе мы бы спрашивали
    ///   у GitHub про чужие сайты и тратили лимит на заведомые промахи.
    @Test func rejectsEverythingThatIsNotAGitHubRepository() {
        let notOurs = [
            "https://locomalito.com/juegos/hydorah",                     // official из каталога
            "https://ukiuki.itch.io/blade-symphony",                     // itch из каталога
            "https://gitlab.com/acme/game/-/releases",
            "https://github.io/acme/game",
            "https://objects.githubusercontent.com/some/blob",           // перевалочный хост
            "https://github.com/alemart",                                // владелец без репозитория
            "https://github.com/features/actions",                       // раздел сайта
            "https://notgithub.com/acme/game/releases/download/v1/a.zip",
            "не адрес вовсе",
            ""
        ]
        for url in notOurs {
            #expect(GameReleaseResolver.repository(from: url) == nil, "принят за GitHub: \(url)")
        }
    }

    /// Тег из замороженного адреса — им и сверяем «устарела ли ссылка».
    @Test func readsTheFrozenTagOutOfTheCatalogURL() {
        #expect(GameReleaseResolver.tag(fromDownloadURL:
            "https://github.com/bradharding/doomretro/releases/download/v6.3/doomretro-6.3-win64.zip") == "v6.3")
        #expect(GameReleaseResolver.tag(fromDownloadURL:
            "https://github.com/nukeykt/NBlood/releases/download/r14387/nblood_win64.7z") == "r14387")
        #expect(GameReleaseResolver.tag(fromDownloadURL:
            "https://github.com/OpenNox/OpenNox/releases/tag/v1.9.0-alpha13") == "v1.9.0-alpha13")
        // Контроль: у адреса без выпуска тега нет, и выдумывать его нельзя.
        #expect(GameReleaseResolver.tag(fromDownloadURL: "https://github.com/OpenNox/OpenNox") == nil)
    }

    /// Пара «владелец/репо» негодного вида не должна уезжать в сеть.
    @Test func malformedRepositoryNeverReachesTheNetwork() async {
        for bad in ["", "openapoc", "openapoc/", "/openapoc", "a/b/c"] {
            await #expect(throws: GameReleaseError.notAGitHubURL(bad)) {
                _ = try await GameReleaseResolver(session: Self.deadSession()).latest(forRepository: bad)
            }
        }
    }

    /// Сессия, которая гарантированно никуда не дойдёт: если проверка выше всё-таки
    /// уедет в сеть, она упадёт по таймауту, а не пройдёт по-тихому.
    private static func deadSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 1
        configuration.protocolClasses = []
        return URLSession(configuration: configuration)
    }

    // MARK: - Живая проверка сетью (включается переменной)

    /// ★★★ ЭТО ОТВЕТ НА ВОПРОС ВЛАДЕЛЬЦА: по всем играм каталога с `host_kind == github`
    ///   печатается репозиторий, версия в каталоге, найденная последняя версия,
    ///   выбранный файл, код HEAD по найденной ссылке и вывод «устарела ли ссылка».
    ///
    /// Включается только так — иначе обычный `swift test` расходовал бы лимит GitHub
    /// (60 запросов в час) и краснел от чужой недоступности:
    /// ```
    /// MACRUNNER_GAMES_LIVE=1 swift test --no-parallel --filter liveTable
    /// ```
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACRUNNER_GAMES_LIVE"] == "1"))
    func liveTableForEveryGitHubGameInTheCatalog() async throws {
        let games = await MainActor.run { GameCatalog.shared.games }
        let failure = await MainActor.run { GameCatalog.shared.loadFailure }
        #expect(failure == nil, "каталог не прочитан: \(failure ?? "")")

        let github = games.filter { $0.download.hostKind == .github }
        #expect(github.count == 11, "игр с host_kind=github должно быть 11, а не \(github.count)")

        let resolver = GameReleaseResolver()
        var divergent: [String] = []
        var broken: [String] = []
        var lines: [String] = []

        for game in github {
            let repo = GameReleaseResolver.repository(from: game.download.url) ?? "—"
            let catalogTag = GameReleaseResolver.tag(fromDownloadURL: game.download.url) ?? "—"
            // Код по ЗАМОРОЖЕННОЙ ссылке каталога — отдельный факт: она может быть и
            // живой, и мёртвой независимо от того, совпали ли теги.
            let catalogStatus = await Self.headStatus(URL(string: game.download.url))
            do {
                let release = try await resolver.latest(forRepository: repo)
                let status = await Self.headStatus(release.url)
                // ★ ВЕРДИКТ ТОЛЬКО ФАКТОМ. «Устарела» здесь было бы ВЫВОДОМ, и на
                //   openapoc он оказался ложным: у них КАЖДАЯ сборка помечена
                //   `prerelease`, единственный обычный выпуск — от апреля, и найденный
                //   тег СТАРШЕ каталожного. Поэтому пишем «РАСХОЖДЕНИЕ», а направление
                //   разбираем глазами: сравнивать теги по номерам нам нечем — у пяти
                //   из одиннадцати проектов это даты и номера сборок, а не версии.
                let same = release.version == catalogTag
                if !same { divergent.append(game.id) }
                if status != 200 { broken.append("\(game.id):\(status)") }
                lines.append([game.id, repo, catalogTag, release.version, release.assetName,
                              "\(status)", "\(catalogStatus)", same ? "совпадает" : "РАСХОЖДЕНИЕ"]
                             .joined(separator: " | "))
            } catch {
                broken.append("\(game.id):отказ")
                lines.append([game.id, repo, catalogTag, "ОТКАЗ",
                              (error as? GameReleaseError)?.errorDescription ?? "\(error)",
                              "—", "\(catalogStatus)", "ОТКАЗ"]
                             .joined(separator: " | "))
            }
        }

        print("\n=== ЖИВАЯ ПРОВЕРКА: свежие версии игр с GitHub ===")
        print("игра | репозиторий | в каталоге | найдено | файл | HEAD найденного | HEAD каталожного | вывод")
        lines.forEach { print($0) }
        print("расхождений: \(divergent.count) из \(github.count) — \(divergent.isEmpty ? "нет" : divergent.joined(separator: ", "))")
        print("проблемные: \(broken.isEmpty ? "нет" : broken.joined(separator: ", "))")

        // ★ ОТРИЦАТЕЛЬНЫЙ КОНТРОЛЬ ТЕМ ЖЕ ПРИБОРОМ — иначе таблица выше ничего не
        //   доказывает: прибор, который всегда отвечает «нашёл», нашёл бы и небывшее.
        await #expect(throws: GameReleaseError.noReleases("zzz-net-takogo/zzz-net-takogo")) {
            _ = try await resolver.latest(forRepository: "zzz-net-takogo/zzz-net-takogo")
        }
        // Репозиторий, который существует, а выпусков не публикует вовсе.
        await #expect(throws: GameReleaseError.noReleases("github/gitignore")) {
            _ = try await resolver.latest(forRepository: "github/gitignore")
        }

        #expect(broken.isEmpty, "найденные ссылки, которые не отдают 200: \(broken.joined(separator: ", "))")
    }

    /// Код ответа по ссылке. `HEAD` — чтобы не тащить сотни мегабайт ради проверки.
    private static func headStatus(_ url: URL?) async -> Int {
        guard let url else { return -1 }
        var request = URLRequest(url: url)
        request.httpMethod = "HEAD"
        request.timeoutInterval = 20
        request.setValue(GameReleaseResolver.userAgent, forHTTPHeaderField: "User-Agent")
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode ?? -1
        } catch {
            return -1
        }
    }
}
