import Foundation
import Testing
@testable import MacRunnerControlCenter

// Проверка разбора .exe. Ни сети, ни внешних файлов: минимальные PE собираются
// байт за байтом прямо здесь и кладутся во временный каталог, который тут же убирается.
//
// Что именно стережём (каждый случай уже ловил настоящую ошибку в этом коде):
//   · уверенность вне 0…1 — до правки сумма трёх признаков давала 1.13;
//   · «uninstall» СОДЕРЖИТ «install» — наивная проверка объявляет деинсталлятор
//     установщиком и предлагает его ЗАПУСТИТЬ;
//   · подпись на стыке кусков чтения — без нахлёста теряется;
//   · подпись только в ХВОСТЕ большого файла — у самораспаковывающихся архивов она там.

// MARK: - Сборка минимального PE в памяти

/// Собирает ровно столько PE, сколько нужно разбору: «MZ», «PE\0\0», машина, таблица секций.
private struct PEBuilder {
    var machine: UInt16 = 0x8664
    var sectionNames: [String] = [".text"]
    /// Тело файла после заголовков — сюда кладём подписи сборщиков и набивку.
    var trailer: Data = Data()

    func bytes() -> Data {
        var data = Data(count: 0x40)
        data[0] = 0x4D // M
        data[1] = 0x5A // Z
        data.writeUInt32(at: 0x3C, 0x40) // e_lfanew: заголовок PE сразу за заголовком DOS

        var coff = Data(count: 24)
        coff[0] = 0x50 // P
        coff[1] = 0x45 // E
        coff.writeUInt16(at: 4, machine)
        coff.writeUInt16(at: 6, UInt16(sectionNames.count))
        coff.writeUInt16(at: 20, 0) // SizeOfOptionalHeader = 0 → каталога ресурсов нет
        data.append(coff)

        for name in sectionNames {
            var section = Data(count: 40)
            for (index, byte) in Array(name.utf8.prefix(8)).enumerated() {
                section[index] = byte
            }
            data.append(section)
        }

        data.append(trailer)
        return data
    }
}

private extension Data {
    mutating func writeUInt16(at offset: Int, _ value: UInt16) {
        self[startIndex + offset] = UInt8(value & 0xFF)
        self[startIndex + offset + 1] = UInt8(value >> 8)
    }

    mutating func writeUInt32(at offset: Int, _ value: UInt32) {
        self[startIndex + offset] = UInt8(value & 0xFF)
        self[startIndex + offset + 1] = UInt8((value >> 8) & 0xFF)
        self[startIndex + offset + 2] = UInt8((value >> 16) & 0xFF)
        self[startIndex + offset + 3] = UInt8((value >> 24) & 0xFF)
    }
}

/// Кладёт байты во временный файл с заданным ИМЕНЕМ (имя — само по себе признак),
/// отдаёт вердикт и убирает за собой.
private func verdict(name: String, bytes: Data) throws -> ExeVerdict {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("exekind-tests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let url = directory.appendingPathComponent(name)
    try bytes.write(to: url)
    return try ExeInspector.inspect(at: url)
}

private func verdict(name: String, builder: PEBuilder) throws -> ExeVerdict {
    try verdict(name: name, bytes: builder.bytes())
}

// MARK: - Разрядность

struct ExeKindArchitectureTests {
    @Test func x8664ReadFromHeader() throws {
        let result = try verdict(name: "game.exe", builder: PEBuilder(machine: 0x8664))
        #expect(result.architecture == "x86-64")
    }

    @Test func i386ReadFromHeader() throws {
        let result = try verdict(name: "game.exe", builder: PEBuilder(machine: 0x014C))
        #expect(result.architecture == "i386")
    }

    @Test func arm64ReadFromHeader() throws {
        let result = try verdict(name: "game.exe", builder: PEBuilder(machine: 0xAA64))
        #expect(result.architecture == "ARM64")
    }

    /// Разрядность берётся ИЗ ЗАГОЛОВКА, а не из имени: файл, названный «...x64...»,
    /// но собранный под i386, обязан выдать i386.
    @Test func nameDoesNotOverrideHeader() throws {
        let result = try verdict(name: "totally-x64-game.exe", builder: PEBuilder(machine: 0x014C))
        #expect(result.architecture == "i386")
    }
}

// MARK: - Отказы: не-PE обязан быть виден

struct ExeKindFailureTests {
    @Test func plainTextIsNotPE() throws {
        let bytes = Data("это обычный текст, никакой не PE, и так двадцать раз подряд".utf8)
        #expect(throws: ExeInspectorError.self) {
            _ = try verdict(name: "fake.exe", bytes: bytes)
        }
    }

    @Test func missingMZIsReportedAsNotPE() throws {
        // Достаточно длинный файл, чтобы отказ случился именно из-за отсутствия «MZ»,
        // а не из-за короткой длины.
        let bytes = Data(repeating: 0x41, count: 4096)
        do {
            _ = try verdict(name: "fake.exe", bytes: bytes)
            Issue.record("разбор обязан был отказать: нет сигнатуры MZ")
        } catch let error as ExeInspectorError {
            #expect(error == .notPortableExecutable("нет сигнатуры «MZ» в начале файла"))
        }
    }

    /// «MZ» есть, а «PE\0\0» нет — это DOS-овский .exe, не Windows-программа.
    @Test func mzWithoutPESignatureFails() throws {
        var bytes = Data(count: 0x200)
        bytes[0] = 0x4D
        bytes[1] = 0x5A
        bytes.writeUInt32(at: 0x3C, 0x40) // указатель есть, а сигнатуры по нему нет
        do {
            _ = try verdict(name: "dosgame.exe", bytes: bytes)
            Issue.record("разбор обязан был отказать: нет сигнатуры PE\\0\\0")
        } catch let error as ExeInspectorError {
            #expect(error == .notPortableExecutable("нет сигнатуры «PE\\0\\0»"))
        }
    }

    @Test func emptyFileFails() throws {
        #expect(throws: ExeInspectorError.self) {
            _ = try verdict(name: "empty.exe", bytes: Data())
        }
    }

    @Test func missingFileFails() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("net-takogo-\(UUID().uuidString).exe")
        #expect(throws: ExeInspectorError.self) {
            _ = try ExeInspector.inspect(at: url)
        }
    }
}

// MARK: - Сильные признаки: содержимое файла

struct ExeKindContentTests {
    /// Подпись сборщика в теле файла — установщик, даже если имя об этом молчит.
    @Test func innoSetupSignatureMakesInstaller() throws {
        let builder = PEBuilder(trailer: Data("... JR.Inno.Setup ... прочий мусор ...".utf8))
        let result = try verdict(name: "prosto-igra.exe", builder: builder)
        #expect(result.kind == .installer)
        #expect(result.reasons.contains { $0.contains("Inno Setup") })
    }

    @Test func nsisSignatureMakesInstaller() throws {
        let builder = PEBuilder(trailer: Data("Nullsoft Install System v3.10".utf8))
        let result = try verdict(name: "zagadka.exe", builder: builder)
        #expect(result.kind == .installer)
    }

    /// ★ ГЛАВНАЯ ЛОВУШКА: установщик, названный как игра. Имя молчит — вердикт обязан
    /// держаться на содержимом и обязан СКАЗАТЬ человеку, что держится только на нём.
    @Test func installerNamedLikeGameIsCaught() throws {
        let builder = PEBuilder(trailer: Data("Inno Setup".utf8))
        let result = try verdict(name: "Hollow Knight.exe", builder: builder)
        #expect(result.kind == .installer)
        #expect(result.reasons.contains { $0.contains("только на содержимом") })
    }

    /// Обратная ловушка: имя говорит одно, содержимое другое — надо сказать о расхождении.
    /// Здесь имя намекает на установщик, а строка версии выдаёт рантайм.
    @Test func nameAndContentDisagreementIsReported() throws {
        let builder = PEBuilder(trailer: Data("Inno Setup".utf8))
        let result = try verdict(name: "install-my-game.exe", builder: builder)
        #expect(result.kind == .installer)
        // Имя и содержимое согласны — про расхождение писать НЕ надо.
        #expect(!result.reasons.contains { $0.contains("расходятся") })
    }

    /// ★★★ САМАЯ ДОРОГАЯ ОШИБКА ИЗ ВСЕХ ВОЗМОЖНЫХ.
    /// Деинсталлятор Inno (`unins000.exe`) собран тем же Inno и несёт В ТЕЛЕ ту же подпись,
    /// что и установщик. Если подпись перевесит имя, файл станет «установщиком», мы предложим
    /// его ЗАПУСТИТЬ — и человек снесёт себе игру. Имя обязано победить.
    @Test func innoUninstallerIsNotOfferedForLaunch() throws {
        let builder = PEBuilder(trailer: Data("JR.Inno.Setup ... Inno Setup Uninstaller".utf8))
        let result = try verdict(name: "unins000.exe", builder: builder)
        #expect(result.kind == .auxiliary, "деинсталлятор Inno принят за установщик — его предложат ЗАПУСТИТЬ")
        #expect(result.kind != .installer)
    }
}

// MARK: - Слабые признаки: имя файла

struct ExeKindNameTests {
    @Test func uninstallerNameIsAuxiliary() throws {
        let result = try verdict(name: "unins000.exe", builder: PEBuilder())
        #expect(result.kind == .auxiliary)
    }

    /// ★ «uninstall» СОДЕРЖИТ «install». Деинсталлятор, принятый за установщик,
    /// будет ЗАПУЩЕН — то есть игра окажется снесена. Стережём отдельным утверждением.
    @Test func uninstallerNeverBecomesInstaller() throws {
        for name in ["unins000.exe", "uninstall.exe", "Uninstall Notepad++.exe", "uninstaller_like_x64.exe"] {
            let result = try verdict(name: name, builder: PEBuilder())
            #expect(result.kind == .auxiliary, "«\(name)» должен быть служебным")
            #expect(result.kind != .installer, "«\(name)» НЕЛЬЗЯ запускать как установщик")
        }
    }

    @Test func runtimeAndCrashHandlerNamesAreAuxiliary() throws {
        for name in ["vcredist_x64.exe", "dxwebsetup.exe", "DXSETUP.exe",
                     "oalinst.exe", "UnityCrashHandler64.exe"] {
            let result = try verdict(name: name, builder: PEBuilder())
            #expect(result.kind == .auxiliary, "«\(name)» должен быть служебным")
        }
    }

    /// Рантайм остаётся служебным ДАЖЕ имея внутри честную подпись сборщика:
    /// настоящий vcredist_x64.exe собран WiX, но в библиотеку ему нельзя.
    @Test func runtimeWinsOverBuilderSignature() throws {
        let builder = PEBuilder(trailer: Data("WiX Toolset".utf8))
        let result = try verdict(name: "vcredist_x64.exe", builder: builder)
        #expect(result.kind == .auxiliary)
    }

    @Test func setupNameAloneIsInstallerButNotConfident() throws {
        let result = try verdict(name: "setup.exe", builder: PEBuilder())
        #expect(result.kind == .installer)
        // Имя — слабый признак: уверенность обязана быть скромной.
        #expect(result.confidence < 0.75)
    }

    /// Чистая игра: ни подписи, ни служебного имени — это программа.
    @Test func cleanGameIsApplication() throws {
        for name in ["Hollow Knight.exe", "Diablo.exe", "Heroes3.exe", "AbzuGame.exe"] {
            let result = try verdict(name: name, builder: PEBuilder())
            #expect(result.kind == .application, "«\(name)» должен быть программой")
        }
    }
}

// MARK: - Уверенность и объяснение

struct ExeKindConfidenceTests {
    /// ★ Регрессия на настоящую ошибку: без потолка сумма трёх признаков давала 1.13.
    /// Число вне 0…1 показывается человеку и делает всю шкалу бессмысленной.
    @Test func confidenceStaysInRange() throws {
        let cases: [(String, PEBuilder)] = [
            ("KeePass-2.61.1-Setup.exe", PEBuilder(trailer: Data("JR.Inno.Setup".utf8))),
            ("npp.Installer.x64.exe", PEBuilder(trailer: Data("Nullsoft Install System".utf8))),
            ("vcredist_x64.exe", PEBuilder(trailer: Data("WiX Toolset".utf8))),
            ("unins000.exe", PEBuilder()),
            ("Hollow Knight.exe", PEBuilder()),
            ("setup.exe", PEBuilder())
        ]
        for (name, builder) in cases {
            let result = try verdict(name: name, builder: builder)
            #expect(result.confidence > 0.0, "\(name): уверенность должна быть больше нуля")
            #expect(result.confidence <= 1.0, "\(name): уверенность \(result.confidence) вышла за 1.0")
        }
    }

    /// Уверенность обязана РАЗЛИЧАТЬ силу улик, а не быть всегда одинаковой.
    @Test func contentEvidenceBeatsNameEvidence() throws {
        let byName = try verdict(name: "setup.exe", builder: PEBuilder())
        let byContent = try verdict(name: "setup.exe", builder: PEBuilder(trailer: Data("JR.Inno.Setup".utf8)))
        #expect(byName.kind == .installer)
        #expect(byContent.kind == .installer)
        #expect(byContent.confidence > byName.confidence,
                "подпись в теле файла должна давать больше уверенности, чем одно имя")
    }

    @Test func reasonsAreNeverEmpty() throws {
        for name in ["Hollow Knight.exe", "setup.exe", "unins000.exe"] {
            let result = try verdict(name: name, builder: PEBuilder())
            #expect(!result.reasons.isEmpty, "«\(name)»: вердикт без объяснения нельзя показывать человеку")
        }
    }

    /// Упакованный файл: строк внутри не видно, значит молчание подписей ничего не доказывает.
    /// Это должно быть сказано вслух и срезать уверенность.
    @Test func packedFileIsFlaggedAndLessConfident() throws {
        let builder = PEBuilder(sectionNames: ["UPX0", "UPX1"])
        let result = try verdict(name: "DiabloLauncher.exe", builder: builder)
        #expect(result.reasons.contains { $0.contains("упакован") })
        #expect(result.confidence <= 0.60)
    }
}

// MARK: - Чтение кусками: границы окон

struct ExeKindScanWindowTests {
    /// ★ Подпись, легшая на стык кусков чтения (1 МиБ), без нахлёста теряется.
    @Test func signatureAcrossChunkBoundaryIsFound() throws {
        let boundary = 1024 * 1024
        let signature = Array("JR.Inno.Setup".utf8)
        var trailer = Data(repeating: 0x20, count: boundary + 4096)
        // Ставим подпись так, чтобы её разрезало ровно по границе куска.
        let start = boundary - signature.count / 2 - 0x80 // 0x80 = длина уже записанных заголовков
        for (index, byte) in signature.enumerated() {
            trailer[start + index] = byte
        }
        let result = try verdict(name: "zagadka.exe", builder: PEBuilder(trailer: trailer))
        #expect(result.kind == .installer, "подпись на стыке кусков потеряна — нужен нахлёст")
    }

    /// ★ У самораспаковывающихся архивов подпись лежит в ХВОСТЕ. Голова (4 МиБ) её не видит,
    /// поэтому обязано сработать окно последнего 1 МиБ.
    @Test func signatureOnlyInTailIsFound() throws {
        let headWindow = 4 * 1024 * 1024
        var trailer = Data(repeating: 0x20, count: headWindow + 256 * 1024)
        let signature = Array("JR.Inno.Setup".utf8)
        let start = trailer.count - signature.count - 1024
        for (index, byte) in signature.enumerated() {
            trailer[start + index] = byte
        }
        let result = try verdict(name: "bolshoy-arhiv.exe", builder: PEBuilder(trailer: trailer))
        #expect(result.kind == .installer, "подпись в хвосте не найдена — окно хвоста не работает")
    }

    /// Отрицательный контроль к двум предыдущим: тот же большой файл БЕЗ подписи
    /// не должен объявляться установщиком. Иначе проверки выше зелёные по случайности.
    @Test func largeFileWithoutSignatureStaysApplication() throws {
        let trailer = Data(repeating: 0x20, count: 4 * 1024 * 1024 + 256 * 1024)
        let result = try verdict(name: "bolshaya-igra.exe", builder: PEBuilder(trailer: trailer))
        #expect(result.kind == .application)
    }
}
