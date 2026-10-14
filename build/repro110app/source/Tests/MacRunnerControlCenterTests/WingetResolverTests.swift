import Foundation
import Testing
@testable import MacRunnerControlCenter

/// Проверяем три вещи, которые ломаются МОЛЧА и выглядят как рабочие:
/// разбор манифеста, порядок версий и выбор разрядности.
///
/// Сети здесь нет и быть не должно: манифесты вставлены КУСКАМИ НАСТОЯЩИХ файлов
/// из microsoft/winget-pkgs (взяты 11.09.2026), поэтому тест проверяет наш разбор,
/// а не доступность GitHub. Живая проверка сетью — отдельной командой, вручную.
struct WingetResolverTests {

    // MARK: - Разбор манифеста

    /// Настоящий `Notepad++.Notepad++` 8.9.8: три разрядности, пять типов,
    /// вложенные списки (`ExpectedReturnCodes`, `NestedInstallerFiles`) и
    /// вложенные отображения (`InstallationMetadata`) внутри записей.
    static let notepadManifest = """
    # Created with YamlCreate.ps1 Dumplings Mod
    # yaml-language-server: $schema=https://aka.ms/winget-manifest.installer.1.12.0.schema.json

    PackageIdentifier: Notepad++.Notepad++
    PackageVersion: 8.9.8
    ReleaseDate: 2026-08-23
    Installers:
    - Architecture: x64
      InstallerType: nullsoft
      Scope: machine
      InstallerUrl: https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.8/npp.8.9.8.Installer.x64.exe
      InstallerSha256: 7B2A949BF460FB37A3888C9048698F43222A185A48323023DF1C51E78A3CA1C2
      ExpectedReturnCodes:
      - InstallerReturnCode: 5
        ReturnResponse: packageInUse
      UpgradeBehavior: install
      ProductCode: Notepad++
      InstallationMetadata:
        DefaultInstallLocation: '%ProgramFiles%\\Notepad++'
    - Architecture: x86
      InstallerType: nullsoft
      Scope: machine
      InstallerUrl: https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.8/npp.8.9.8.Installer.exe
      InstallerSha256: 9753E2EBA8F0FF056D60C52A917F7760EA81227E41B1786260E1AC76DB398434
      UpgradeBehavior: install
    - Architecture: arm64
      InstallerType: nullsoft
      Scope: machine
      InstallerUrl: https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.8/npp.8.9.8.Installer.arm64.exe
      InstallerSha256: 3AC2C91245E980C4FD0991E5C1971439E234C0713E994D1DAE532C70B7528587
    - Architecture: x64
      InstallerType: zip
      NestedInstallerType: portable
      NestedInstallerFiles:
      - RelativeFilePath: notepad++.exe
        PortableCommandAlias: notepad++
      InstallerUrl: https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.8/npp.8.9.8.portable.x64.zip
      InstallerSha256: B269383239464A945D17CFABFCCF53935B83D80D907922310FDFD50D80274C66
      ArchiveBinariesDependOnPath: true
    ManifestType: installer
    ManifestVersion: 1.12.0
    """

    @Test func parsesEveryInstallerOfARealManifest() throws {
        let installers = try WingetManifestParser.parse(Self.notepadManifest)
        #expect(installers.count == 4)

        let first = installers[0]
        #expect(first.architecture == "x64")
        #expect(first.type == "nullsoft")
        #expect(first.scope == "machine")
        #expect(first.version == "8.9.8")
        #expect(first.sha256 == "7B2A949BF460FB37A3888C9048698F43222A185A48323023DF1C51E78A3CA1C2")
        #expect(first.url.absoluteString
                == "https://github.com/notepad-plus-plus/notepad-plus-plus/releases/download/v8.9.8/npp.8.9.8.Installer.x64.exe")

        #expect(installers.map(\.architecture) == ["x64", "x86", "arm64", "x64"])
        #expect(installers.map(\.type) == ["nullsoft", "nullsoft", "nullsoft", "zip"])
        // Вложенный список `NestedInstallerFiles` не должен был утащить разбор
        // в чужие ключи: адрес у последней записи именно её.
        #expect(installers[3].url.absoluteString.hasSuffix("npp.8.9.8.portable.x64.zip"))
    }

    /// Настоящий `Git.Git`: тип `inno` указан ТОЛЬКО в корне, у записей его нет.
    /// Без наследования корневых ключей тип был бы `nil` у всех четырёх.
    @Test func inheritsRootLevelTypeAndScope() throws {
        let manifest = """
        PackageIdentifier: Git.Git
        PackageVersion: 2.55.0.3
        InstallerType: inno
        InstallerSwitches:
          Silent: /SP- /VERYSILENT /SUPPRESSMSGBOXES /NORESTART
          SilentWithProgress: /SP- /SILENT /SUPPRESSMSGBOXES /NORESTART
        Commands:
        - git
        FileExtensions:
        - gitattributes
        - sh
        ReleaseDate: 2026-07-14
        Installers:
        - Architecture: x64
          Scope: user
          InstallerUrl: https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/Git-2.55.0.3-64-bit.exe
          InstallerSha256: AF12577D0FDFF74243A5988197AA49B957D5044EDC17004F6DDF0768996F1DCA
        - Architecture: x64
          Scope: machine
          InstallerUrl: https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/Git-2.55.0.3-64-bit.exe
          InstallerSha256: AF12577D0FDFF74243A5988197AA49B957D5044EDC17004F6DDF0768996F1DCA
        - Architecture: arm64
          Scope: machine
          InstallerUrl: https://github.com/git-for-windows/git/releases/download/v2.55.0.windows.3/Git-2.55.0.3-arm64.exe
          InstallerSha256: E3D7F5A2214F214F0A93CF0D8915DAB236A0E91C7DE6DE70A7DBDE9A61C794DB
        ManifestType: installer
        ManifestVersion: 1.12.0
        """
        let installers = try WingetManifestParser.parse(manifest)
        #expect(installers.count == 3)
        #expect(installers.allSatisfy { $0.type == "inno" })
        #expect(installers.map(\.scope) == ["user", "machine", "machine"])
        // Списки `Commands`/`FileExtensions` в корне не должны считаться установщиками.
        #expect(installers.allSatisfy { $0.version == "2.55.0.3" })

        // Из двух x64 берём machine: он ставит в Program Files, как ждёт бутылка.
        let best = try #require(WingetResolver.best(among: installers))
        #expect(best.architecture == "x64")
        #expect(best.scope == "machine")
    }

    /// `7zip.7zip` пишет версию В КАВЫЧКАХ (`"26.03"`), а `VideoLAN.VLC` вешает
    /// концевой комментарий (`6.1.7600.0 # Windows 7`). И то, и другое молча
    /// уехало бы в значение целиком.
    @Test func stripsQuotesAndTrailingComments() throws {
        let manifest = """
        PackageIdentifier: 7zip.7zip
        PackageVersion: "26.03"
        Scope: machine
        MinimumOSVersion: 6.1.7600.0 # Windows 7
        Installers:
        - Architecture: x64
          InstallerType: exe
          InstallerUrl: https://www.7-zip.org/a/7z2603-x64.exe
          InstallerSha256: 0859C524B8A63551848F0C246ABDDCB1D0B7B656B0FBFE879F8D85E61A9E6EDD
          InstallerSwitches:
            Silent: /S
            InstallLocation: /D="<INSTALLPATH>"
          ProductCode: '{23170F69-40C1-2702-2603-000001000000}'
        ManifestType: installer
        """
        let installers = try WingetManifestParser.parse(manifest)
        #expect(installers.count == 1)
        #expect(installers[0].version == "26.03")
        #expect(installers[0].scope == "machine")   // унаследован из корня
        #expect(installers[0].type == "exe")
    }

    /// Список установщиков с ОТСТУПОМ — тоже законный YAML, и он встречается.
    @Test func parsesIndentedInstallerList() throws {
        let manifest = """
        PackageIdentifier: Some.Package
        PackageVersion: 1.0.0
        Installers:
          - Architecture: x86
            InstallerType: msi
            InstallerUrl: https://example.invalid/setup.msi
            InstallerSha256: aaaabbbbccccddddeeeeffff00001111aaaabbbbccccddddeeeeffff00001111
        ManifestType: installer
        """
        let installers = try WingetManifestParser.parse(manifest)
        #expect(installers.count == 1)
        #expect(installers[0].architecture == "x86")
        // Сумму приводим к верхнему регистру: иначе сверка даст ложное «не совпало».
        #expect(installers[0].sha256 == "AAAABBBBCCCCDDDDEEEEFFFF00001111AAAABBBBCCCCDDDDEEEEFFFF00001111")
    }

    /// ★★★ CRLF. Не выдуманный случай, а ПОЙМАННЫЙ ОТКАЗ: живая проверка 11.09.2026
    ///   дала три отказа из пяти пакетов. `Notepad++` и `Git.Git` лежат с LF и
    ///   разбирались, а `7zip.7zip`, `Microsoft.VisualStudioCode` и `VideoLAN.VLC`
    ///   лежат с CRLF — и разборщик заявлял «в манифесте нет Installers:», хотя блок
    ///   там был. Причина: в Swift `"\r\n"` — ОДИН Character, и `split(separator: "\n")`
    ///   не делит такой файл вообще.
    @Test func parsesManifestWithWindowsLineEndings() throws {
        let crlf = Self.notepadManifest.replacingOccurrences(of: "\n", with: "\r\n")
        // Сначала показываем, что подложка настоящая: в Swift это ОДИН Character.
        #expect("\r\n".count == 1)
        let installers = try WingetManifestParser.parse(crlf)
        #expect(installers.count == 4)
        #expect(installers.map(\.architecture) == ["x64", "x86", "arm64", "x64"])
        #expect(installers[0].version == "8.9.8")
        #expect(installers[0].sha256 == "7B2A949BF460FB37A3888C9048698F43222A185A48323023DF1C51E78A3CA1C2")
    }

    /// Отрицательный контроль разборщика: манифест без `Installers:` обязан дать
    /// ОТКАЗ, а не пустой список, который читается как «установщиков нет».
    @Test func manifestWithoutInstallersThrows() {
        let manifest = """
        PackageIdentifier: Some.Package
        PackageVersion: 1.0.0
        ManifestType: version
        """
        #expect(throws: WingetError.self) {
            _ = try WingetManifestParser.parse(manifest)
        }
    }

    /// Запись без адреса или с непохожей суммой ставить нельзя — и молчать об этом
    /// тоже нельзя, если негодны ВСЕ записи.
    @Test func entriesWithoutURLOrShaAreRejected() {
        let manifest = """
        PackageIdentifier: Some.Package
        PackageVersion: 1.0.0
        Installers:
        - Architecture: x64
          InstallerType: exe
          InstallerSha256: NOTAHASH
        ManifestType: installer
        """
        #expect(throws: WingetError.self) {
            _ = try WingetManifestParser.parse(manifest)
        }
    }

    // MARK: - Порядок версий

    /// Ровно те случаи, на которых алфавитная сортировка врёт.
    @Test func versionsCompareByNumbersNotLetters() {
        #expect(WingetVersion("8.8.10") > WingetVersion("8.8.9"))
        #expect(WingetVersion("1.10.0") > WingetVersion("1.9.99"))
        #expect(WingetVersion("1.2.3") > WingetVersion("1.2.3-beta"))
        #expect(WingetVersion("2.55.0.3") > WingetVersion("2.55.0"))
        #expect(WingetVersion("26.03") > WingetVersion("26.01"))
        // Прибор обязан уметь и ЛОЖЬ: иначе «всё больше всего» прошло бы как успех.
        #expect(WingetVersion("8.8.9") < WingetVersion("8.8.10"))
        #expect(!(WingetVersion("1.2.3") < WingetVersion("1.2.3")))
    }

    /// Настоящий случай, стоивший бы «устаревшей версии навсегда»: у
    /// `Microsoft.VisualStudioCode` алфавит даёт `1.99.3`, а число — `1.137.0`.
    @Test func latestOfRealVisualStudioCodeDirectoryIsNotAlphabetical() {
        let names = ["1.96.0", "1.98.2", "1.99.0", "1.99.3", "1.100.0", "1.137.0", "CLI", "Insiders"]
        let versions = names.filter(WingetVersion.looksLikeVersion).map(WingetVersion.init)
        #expect(versions.count == 6)                       // CLI и Insiders отсеяны
        #expect(versions.max()?.raw == "1.137.0")
        #expect(names.max() == "Insiders")                 // а вот что дал бы алфавит
    }

    /// Подпакеты и каналы рядом с версиями — не версии.
    @Test func channelDirectoriesAreNotVersions() {
        #expect(!WingetVersion.looksLikeVersion("Nightly"))
        #expect(!WingetVersion.looksLikeVersion("Insiders"))
        #expect(!WingetVersion.looksLikeVersion("CLI"))
        #expect(WingetVersion.looksLikeVersion("3.0.23"))
        #expect(WingetVersion.looksLikeVersion("26.03"))
        #expect(WingetVersion.looksLikeVersion("v1.2.3"))
    }

    // MARK: - Выбор разрядности

    private func installer(_ architecture: String, type: String? = "exe") -> WingetInstaller {
        WingetInstaller(
            url: URL(string: "https://example.invalid/\(architecture).exe")!,
            sha256: String(repeating: "A", count: 64),
            architecture: architecture,
            type: type,
            version: "1.0.0",
            scope: nil)
    }

    /// ★ Мы переводим x86-64 и i386; нативные arm64-приложения Windows не запускаем.
    ///   Значит arm64 — последний выбор, а не первый по алфавиту.
    @Test func prefersX64ThenX86AndTakesArm64Last() throws {
        let full = [installer("arm64"), installer("x64"), installer("x86")]
        #expect(WingetResolver.best(among: full)?.architecture == "x64")

        let noX64 = [installer("arm64"), installer("x86")]
        #expect(WingetResolver.best(among: noX64)?.architecture == "x86")

        let onlyArm = [installer("arm64")]
        #expect(WingetResolver.best(among: onlyArm)?.architecture == "arm64")

        #expect(WingetResolver.best(among: []) == nil)
    }

    /// Разрядность ВАЖНЕЕ типа: x64 в архиве лучше, чем arm64 обычным установщиком,
    /// потому что arm64 у нас не пойдёт вовсе.
    @Test func architectureOutranksInstallerType() throws {
        let mixed = [installer("arm64", type: "exe"), installer("x64", type: "zip")]
        #expect(WingetResolver.best(among: mixed)?.architecture == "x64")
    }

    /// А внутри ОДНОЙ разрядности обычный установщик лучше архива и msix.
    @Test func withinOneArchitectureRealInstallerWins() throws {
        let sameArch = [
            installer("x64", type: "msix"),
            installer("x64", type: "zip"),
            installer("x64", type: "inno")
        ]
        #expect(WingetResolver.best(among: sameArch)?.type == "inno")
    }

    /// На настоящем Notepad++ выбор обязан дать x64 nullsoft, а не x64 zip
    /// и не arm64.
    @Test func bestOfRealNotepadManifestIsX64Installer() throws {
        let installers = try WingetManifestParser.parse(Self.notepadManifest)
        let best = try #require(WingetResolver.best(among: installers))
        #expect(best.architecture == "x64")
        #expect(best.type == "nullsoft")
        #expect(best.url.absoluteString.hasSuffix("npp.8.9.8.Installer.x64.exe"))
    }

    // MARK: - Путь в репозитории

    /// Точки идентификатора — это каталоги; первый знак задаёт букву. У `7zip.7zip`
    /// «буква» — цифра, и это нормально.
    @Test func buildsRepositoryPathFromIdentifier() {
        #expect(WingetResolver.manifestPath(for: "Notepad++.Notepad++")
                == "manifests/n/Notepad++/Notepad++")
        #expect(WingetResolver.manifestPath(for: "7zip.7zip") == "manifests/7/7zip/7zip")
        #expect(WingetResolver.manifestPath(for: "Microsoft.VisualStudioCode")
                == "manifests/m/Microsoft/VisualStudioCode")
        #expect(WingetResolver.manifestPath(for: "Microsoft.VisualStudioCode.Insiders")
                == "manifests/m/Microsoft/VisualStudioCode/Insiders")
    }

    /// Идентификатор без точки — не winget-овский, и сеть на него дёргать незачем.
    @Test func rejectsMalformedIdentifierWithoutNetwork() async {
        await #expect(throws: WingetError.malformedID("notapackage")) {
            _ = try await WingetResolver().installers(for: "notapackage")
        }
    }
}
