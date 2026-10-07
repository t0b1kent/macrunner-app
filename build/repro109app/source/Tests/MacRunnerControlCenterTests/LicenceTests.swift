import CryptoKit
import Foundation
import Testing
@testable import MacRunnerControlCenter

// ============================================================================
//  Проверка клиентского слоя лицензирования. Без сети: сервера ещё нет, а пара
//  ключей создаётся здесь же и токены собираются на лету. Поэтому набор
//  проверяет ИМЕННО нашу проверяющую сторону, а не доступность чужой машины.
//
//  Правило проекта: прибор, который не доказан, считается врущим. Поэтому
//  почти у каждой проверки рядом стоит ОТРИЦАТЕЛЬНЫЙ КОНТРОЛЬ — показ того,
//  что без проверяемого механизма ответ был бы другим. Зелёный тест без такого
//  контроля не отличает «механизм работает» от «механизм не вызывался».
// ============================================================================

/// Сборщик токенов: делает то, что будет делать сервер. Живёт в тестах —
/// в приложении закрытого ключа нет и быть не должно.
private struct TokenMaker {
    let privateKey: Curve25519.Signing.PrivateKey

    init(privateKey: Curve25519.Signing.PrivateKey = Curve25519.Signing.PrivateKey()) {
        self.privateKey = privateKey
    }

    var publicKey: Curve25519.Signing.PublicKey { privateKey.publicKey }

    /// Подписываем РОВНО ASCII-байты первой части, как условлено в Licence.swift.
    func sign(payloadPart: String) throws -> String {
        let signature = try privateKey.signature(for: LicenceVerifier.signedBytes(ofTokenPart: payloadPart))
        return payloadPart + "." + LicenceBase64URL.encode(signature)
    }

    func token(_ payload: LicencePayload) throws -> String {
        try sign(payloadPart: LicenceBase64URL.encode(try JSONEncoder().encode(payload)))
    }

    func token(rawJSON: String) throws -> String {
        try sign(payloadPart: LicenceBase64URL.encode(Data(rawJSON.utf8)))
    }
}

/// Опора отсчёта: 15.01.2027, целыми секундами. Целые — чтобы `LicenceToken`
/// сравнивался на равенство: формат передачи несёт секунды, и `Date()` с
/// дробной частью после круга через токен перестаёт быть равным себе.
private let base = Date(timeIntervalSince1970: 1_800_000_000)
private let day: TimeInterval = 24 * 60 * 60
private let thisDevice = "fp-this-device"
private let otherDevice = "fp-another-mac"

private func payload(
    licenceID: String = "L-0001",
    plan: LicenceToken.Plan = .yearly,
    paidUntil: Date? = base.addingTimeInterval(300 * day),
    leaseUntil: Date? = base.addingTimeInterval(45 * day),
    fingerprint: String = thisDevice,
    slots: Int = 3,
    allowsUnbind: Bool = true,
    issuedAt: Date = base
) -> LicencePayload {
    LicencePayload(
        licenceID: licenceID,
        plan: plan,
        paidUntil: paidUntil.map { Int($0.timeIntervalSince1970) },
        leaseUntil: leaseUntil.map { Int($0.timeIntervalSince1970) },
        deviceFingerprint: fingerprint,
        deviceSlots: slots,
        allowsUnbind: allowsUnbind,
        issuedAt: Int(issuedAt.timeIntervalSince1970)
    )
}

// MARK: - Подпись

struct LicenceSignatureTests {

    @Test func goodTokenIsValid() throws {
        let maker = TokenMaker()
        let raw = try maker.token(payload())
        let state = try LicenceVerifier.evaluate(rawToken: raw,
                                                 publicKey: maker.publicKey,
                                                 expectedFingerprint: thisDevice,
                                                 now: base)
        let token = try #require(state.token)
        #expect(state == .valid(token))
        #expect(state.allowsLaunch)
        #expect(token.licenceID == "L-0001")
        #expect(token.plan == .yearly)
        #expect(token.deviceSlots == 3)
        #expect(token.allowsUnbind)
        #expect(token.paidUntil == base.addingTimeInterval(300 * day))
        #expect(token.leaseUntil == base.addingTimeInterval(45 * day))
    }

    /// ★★★ ГЛАВНЫЙ ТЕСТ НАБОРА. Он отвечает на вопрос «а подпись вообще
    /// проверяется?» — на который зелёный `goodTokenIsValid` не отвечает:
    /// проверка, которая всегда говорит «да», тоже пропустит годный токен.
    ///
    /// Первая написанная руками версия этого теста портила букву В СЕРЕДИНЕ
    /// строки — и краснела при выключенной проверке подписи не потому, что
    /// поймала подделку, а потому что испорченный JSON перестал разбираться
    /// (`.malformedPayload`, «не удалось перевести данные в строку, столбец
    /// 93»). Тест ловил СЛЕДСТВИЕ, а не проверку: ровно та ошибка, на которой
    /// набор выглядит доказанным, ничего не доказав.
    ///
    /// Поэтому подмену ИЩЕМ: нужна такая замена одной буквы, после которой
    /// нагрузка остаётся ПОЛНОСТЬЮ ЧИТАЕМОЙ — тот же base64, тот же JSON, те же
    /// поля, то же устройство и те же сроки, изменилось только значение. Такой
    /// токен без проверки подписи был бы ПРИНЯТ как годный, а значит его отказ
    /// доказывает работу подписи и ничего другого.
    @Test func oneFlippedLetterIsRejectedOnlyBecauseOfTheSignature() throws {
        let maker = TokenMaker()
        // Длинный licenceID — чтобы в нагрузке было вдоволь текста, подмена в
        // котором оставляет JSON читаемым.
        let intact = payload(licenceID: "L-AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA")
        let raw = try maker.token(intact)
        let parts = raw.split(separator: ".").map(String.init)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        let letters0 = Array(parts[0])

        var damagedPart: String?
        var damagedPayload: LicencePayload?
        search: for index in letters0.indices {
            for replacement in alphabet where letters0[index] != replacement {
                var letters = letters0
                letters[index] = replacement
                let candidate = String(letters)
                guard let bytes = LicenceBase64URL.decode(candidate),
                      let decoded = try? JSONDecoder().decode(LicencePayload.self, from: bytes),
                      decoded != intact,
                      // Устройство и сроки обязаны остаться прежними: иначе
                      // отказ мог бы прийти от них, а не от подписи.
                      decoded.deviceFingerprint == intact.deviceFingerprint,
                      decoded.paidUntil == intact.paidUntil,
                      decoded.leaseUntil == intact.leaseUntil
                else { continue }
                damagedPart = candidate
                damagedPayload = decoded
                break search
            }
        }

        let damaged = try #require(damagedPart, "не нашлось подмены, оставляющей нагрузку читаемой")
        let changed = try #require(damagedPayload)
        #expect(damaged != parts[0], "порча не состоялась — тест проверял бы сам себя")
        #expect(damaged.count == parts[0].count, "изменилась длина, а не буква")
        #expect(changed != intact, "нагрузка не изменилась")

        let state = try LicenceVerifier.evaluate(rawToken: damaged + "." + parts[1],
                                                 publicKey: maker.publicKey,
                                                 expectedFingerprint: thisDevice,
                                                 now: base)
        #expect(state == .invalidSignature)
        #expect(!state.allowsLaunch)
    }

    /// Тот же класс отказов ЦЕЛИКОМ, а не одним случаем (правило проекта:
    /// конечное множество перебирать разом). Меняем по одной букве в КАЖДОЙ
    /// позиции нагрузки и требуем, чтобы ни одна подмена не дала запуска.
    /// Заодно видно, сколько подмен отсеклось подписью, а сколько разбором —
    /// без этого счёта «ноль принятых» мог бы держаться на одном разборе.
    @Test func everySingleLetterChangeInPayloadIsRejected() throws {
        let maker = TokenMaker()
        let raw = try maker.token(payload())
        let parts = raw.split(separator: ".").map(String.init)
        let letters0 = Array(parts[0])

        var accepted: [Int] = []
        var bySignature = 0
        var byParsing = 0
        for index in letters0.indices {
            var letters = letters0
            letters[index] = letters0[index] == "a" ? "b" : "a"
            do {
                let state = try LicenceVerifier.evaluate(rawToken: String(letters) + "." + parts[1],
                                                         publicKey: maker.publicKey,
                                                         expectedFingerprint: thisDevice,
                                                         now: base)
                if state.allowsLaunch { accepted.append(index) } else { bySignature += 1 }
            } catch {
                byParsing += 1   // отказ разбора — тоже отказ, запуска не даёт
            }
        }

        #expect(accepted.isEmpty, "подмена одной буквы прошла в позициях \(accepted)")
        #expect(bySignature + byParsing == letters0.count)
        #expect(letters0.count > 100, "нагрузка коротка — перебор мало что доказывает")
        #expect(bySignature > 0, "ни одна подмена не дошла до проверки подписи")
    }

    @Test func signatureFromAnotherKeyIsRejected() throws {
        let ours = TokenMaker()
        let stranger = TokenMaker()
        #expect(ours.publicKey.rawRepresentation != stranger.publicKey.rawRepresentation)

        // Тот же самый JSON, подписанный чужим ключом.
        let part = LicenceBase64URL.encode(try JSONEncoder().encode(payload()))
        let strangerToken = try stranger.sign(payloadPart: part)
        let ourToken = try ours.sign(payloadPart: part)

        let rejected = try LicenceVerifier.evaluate(rawToken: strangerToken,
                                                    publicKey: ours.publicKey,
                                                    expectedFingerprint: thisDevice,
                                                    now: base)
        #expect(rejected == .invalidSignature)

        // Отрицательный контроль: полезная нагрузка ни при чём — под НАШЕЙ
        // подписью она же принимается. Различает только ключ.
        let accepted = try LicenceVerifier.evaluate(rawToken: ourToken,
                                                     publicKey: ours.publicKey,
                                                     expectedFingerprint: thisDevice,
                                                     now: base)
        #expect(accepted.allowsLaunch)
    }

    /// Подменённая подпись негодной длины — тоже негодная подпись, а не
    /// «испорченный токен»: бросать здесь нечего, состояние названо.
    @Test func truncatedSignatureIsInvalidNotThrown() throws {
        let maker = TokenMaker()
        let raw = try maker.token(payload())
        let parts = raw.split(separator: ".").map(String.init)
        let shortSignature = LicenceBase64URL.encode(Data(repeating: 0, count: 8))
        let state = try LicenceVerifier.evaluate(rawToken: parts[0] + "." + shortSignature,
                                                 publicKey: maker.publicKey,
                                                 expectedFingerprint: thisDevice,
                                                 now: base)
        #expect(state == .invalidSignature)
    }
}

// MARK: - Устройство и сроки

struct LicenceStateTests {

    @Test func tokenIssuedToAnotherDeviceIsRejected() throws {
        let maker = TokenMaker()
        let raw = try maker.token(payload(fingerprint: otherDevice))
        let state = try LicenceVerifier.evaluate(rawToken: raw,
                                                 publicKey: maker.publicKey,
                                                 expectedFingerprint: thisDevice,
                                                 now: base)
        #expect(state == .wrongDevice(expected: otherDevice, actual: thisDevice))
        #expect(!state.allowsLaunch)
        // Порядок значений в состоянии проверяем прямо: перепутанные местами,
        // они дали бы такое же зелёное равенство при обратном порядке полей.
        guard case let .wrongDevice(expected, actual) = state else {
            Issue.record("не то состояние")
            return
        }
        #expect(expected == otherDevice, "expected — отпечаток ИЗ ТОКЕНА")
        #expect(actual == thisDevice, "actual — отпечаток ЭТОЙ машины")
    }

    @Test func expiredLeaseWithLivePaymentAsksForConnection() throws {
        let maker = TokenMaker()
        let raw = try maker.token(payload(paidUntil: base.addingTimeInterval(300 * day),
                                          leaseUntil: base.addingTimeInterval(-1 * day)))
        let state = try LicenceVerifier.evaluate(rawToken: raw,
                                                 publicKey: maker.publicKey,
                                                 expectedFingerprint: thisDevice,
                                                 now: base)
        let token = try #require(state.token)
        #expect(state == .leaseExpired(token))
        #expect(!state.allowsLaunch)
        // Право не потеряно — именно поэтому состояние отдельное от `.expired`.
        #expect(token.paidUntil == base.addingTimeInterval(300 * day))
    }

    @Test func expiredPaymentWinsOverLease() throws {
        let maker = TokenMaker()
        // Оплата кончилась, аренда ещё жива: показать «нужна связь» было бы
        // обманом — продлевать нечем. Поэтому оплата проверяется раньше.
        let raw = try maker.token(payload(paidUntil: base.addingTimeInterval(-10 * day),
                                          leaseUntil: base.addingTimeInterval(20 * day)))
        let state = try LicenceVerifier.evaluate(rawToken: raw,
                                                 publicKey: maker.publicKey,
                                                 expectedFingerprint: thisDevice,
                                                 now: base)
        let token = try #require(state.token)
        #expect(state == .expired(token))
    }

    @Test func chargedButUnleasedTokenExpiresOnBothCounts() throws {
        let maker = TokenMaker()
        let raw = try maker.token(payload(paidUntil: base.addingTimeInterval(-10 * day),
                                          leaseUntil: base.addingTimeInterval(-20 * day)))
        let state = try LicenceVerifier.evaluate(rawToken: raw,
                                                 publicKey: maker.publicKey,
                                                 expectedFingerprint: thisDevice,
                                                 now: base)
        #expect(state.token != nil)
        if case .expired = state {} else { Issue.record("ожидалось .expired, получено \(state)") }
    }

    /// Пожизненная офлайн-лицензия: ни оплата, ни аренда не кончаются.
    /// Проверяем не «сейчас», а и через год — иначе тест прошёл бы и на
    /// лицензии со сроком, просто ещё не истёкшим.
    @Test func lifetimeOfflineTokenStaysValidForever() throws {
        let maker = TokenMaker()
        let raw = try maker.token(payload(plan: .lifetime,
                                          paidUntil: nil,
                                          leaseUntil: nil,
                                          slots: 5,
                                          allowsUnbind: false))
        for (label, now) in [("сейчас", base),
                             ("через год", base.addingTimeInterval(366 * day)),
                             ("через десять лет", base.addingTimeInterval(3660 * day))] {
            let state = try LicenceVerifier.evaluate(rawToken: raw,
                                                     publicKey: maker.publicKey,
                                                     expectedFingerprint: thisDevice,
                                                     now: now)
            #expect(state.allowsLaunch, "\(label): \(state)")
            let token = try #require(state.token)
            #expect(token.paidUntil == nil)
            #expect(token.leaseUntil == nil)
            // Обмен, на котором стоит вся схема: вечный офлайн — значит без отзыва.
            #expect(token.allowsUnbind == false)
            #expect(token.needsLeaseRenewal(now: now) == false, "бессрочную аренду продлевать не нужно")
        }
    }

    @Test func leaseRenewalIsAskedBeforeItRunsOut() throws {
        let maker = TokenMaker()
        let raw = try maker.token(payload(leaseUntil: base.addingTimeInterval(45 * day)))
        let token = try #require(try LicenceVerifier.evaluate(rawToken: raw,
                                                             publicKey: maker.publicKey,
                                                             expectedFingerprint: thisDevice,
                                                             now: base).token)
        #expect(token.needsLeaseRenewal(now: base) == false, "45 дней запаса — продлевать рано")
        #expect(token.needsLeaseRenewal(now: base.addingTimeInterval(40 * day)),
                "за 5 дней до конца аренды продление уже нужно")
    }
}

// MARK: - Формат передачи

/// Формат передачи закреплён РУКОПИСНЫМ JSON, а не круговым прогоном через
/// собственный кодировщик: круг сошёлся бы и после переименования поля, то есть
/// после поломки совместимости с уже выданными токенами.
struct LicenceWireFormatTests {

    @Test func handWrittenJSONDecodesAsExpected() throws {
        let maker = TokenMaker()
        let json = """
        {"licence_id":"L-WIRE","plan":"business","paid_until":1830000000,\
        "lease_until":1810000000,"device_fingerprint":"fp-this-device",\
        "device_slots":7,"allows_unbind":true,"issued_at":1790000000}
        """
        let state = try LicenceVerifier.evaluate(rawToken: try maker.token(rawJSON: json),
                                                 publicKey: maker.publicKey,
                                                 expectedFingerprint: thisDevice,
                                                 now: base)
        let token = try #require(state.token)
        #expect(state.allowsLaunch)
        #expect(token.licenceID == "L-WIRE")
        #expect(token.plan == .business)
        #expect(token.deviceSlots == 7)
        #expect(token.paidUntil == Date(timeIntervalSince1970: 1_830_000_000))
        #expect(token.leaseUntil == Date(timeIntervalSince1970: 1_810_000_000))
        #expect(token.issuedAt == Date(timeIntervalSince1970: 1_790_000_000))
    }

    /// Отсутствующее поле и явный null значат одно и то же — «бессрочно».
    /// Сервер на другом языке напишет либо так, либо так, и оба варианта
    /// обязаны работать.
    @Test func absentAndNullDatesBothMeanForever() throws {
        let maker = TokenMaker()
        let withoutKeys = """
        {"licence_id":"L-A","plan":"lifetime","device_fingerprint":"fp-this-device",\
        "device_slots":5,"allows_unbind":false,"issued_at":1790000000}
        """
        let withNulls = """
        {"licence_id":"L-A","plan":"lifetime","paid_until":null,"lease_until":null,\
        "device_fingerprint":"fp-this-device","device_slots":5,"allows_unbind":false,\
        "issued_at":1790000000}
        """
        for json in [withoutKeys, withNulls] {
            let state = try LicenceVerifier.evaluate(rawToken: try maker.token(rawJSON: json),
                                                     publicKey: maker.publicKey,
                                                     expectedFingerprint: thisDevice,
                                                     now: base.addingTimeInterval(3660 * day))
            #expect(state.allowsLaunch)
            #expect(state.token?.paidUntil == nil)
            #expect(state.token?.leaseUntil == nil)
        }
    }

    /// Подписанный, но нечитаемый JSON — ошибка НАШЕГО сервера, и она названа
    /// отдельно от подделки: подделать подпись нельзя, значит чужой сюда не дойдёт.
    @Test func signedButUnreadablePayloadIsNamedSeparately() throws {
        let maker = TokenMaker()
        let raw = try maker.token(rawJSON: "{это не json")
        #expect(throws: LicenceError.self) {
            _ = try LicenceVerifier.evaluate(rawToken: raw,
                                             publicKey: maker.publicKey,
                                             expectedFingerprint: thisDevice,
                                             now: base)
        }
        do {
            _ = try LicenceVerifier.evaluate(rawToken: raw,
                                             publicKey: maker.publicKey,
                                             expectedFingerprint: thisDevice,
                                             now: base)
            Issue.record("нечитаемая нагрузка принята")
        } catch let error as LicenceError {
            guard case .malformedPayload = error else {
                Issue.record("ожидался .malformedPayload, получено \(error)")
                return
            }
            #expect(error.errorDescription?.isEmpty == false, "у отказа нет текста для человека")
        }
    }

    @Test func base64URLSurvivesRoundTripAndRejectsJunk() throws {
        for length in 0...8 {
            let data = Data((0..<length).map { UInt8($0) })
            let text = LicenceBase64URL.encode(data)
            #expect(!text.contains("="), "набивка осталась: \(text)")
            #expect(!text.contains("+") && !text.contains("/"), "не base64url: \(text)")
            if length > 0 {
                #expect(LicenceBase64URL.decode(text) == data)
            }
        }
        #expect(LicenceBase64URL.decode("") == nil)
        #expect(LicenceBase64URL.decode("!!!!") == nil)
        #expect(LicenceBase64URL.decode("aaaaa") == nil, "остаток 1 — такой base64 невозможен")
    }
}

// MARK: - Мусор вместо токена

struct LicenceMalformedInputTests {

    /// Ни одно из этих значений не смеет дать `.valid`, и отказ обязан быть
    /// НАЗВАН: пустое состояние вместо названной ошибки — это и есть
    /// проглоченный отказ, из-за которого потом ищут «почему лицензии нет».
    @Test func junkIsNamedNotAccepted() throws {
        let cases: [(String, String)] = [
            ("пустая строка", ""),
            ("пробелы", "   \n\t "),
            ("без точки", "eyJsaWNlbmNlX2lkIjoiTC0xIn0"),
            ("три части", "aGVsbG8.aGVsbG8.aGVsbG8"),
            ("пустая первая половина", ".aGVsbG8"),
            ("пустая вторая половина", "aGVsbG8."),
            ("не base64", "!!!!.!!!!"),
            ("мусор", "чистый мусор, не токен"),
            ("одна точка", "."),
            ("обрезанный JWT-подобный", "eyJhbGciOiJFZERTQSJ9")
        ]
        let key = try LicencePublicKey.embedded()
        for (label, raw) in cases {
            do {
                let state = try LicenceVerifier.evaluate(rawToken: raw,
                                                         publicKey: key,
                                                         expectedFingerprint: thisDevice,
                                                         now: base)
                #expect(!state.allowsLaunch, "\(label): мусор принят как \(state)")
                Issue.record("\(label): отказ не назван, вернулось \(state)")
            } catch let error as LicenceError {
                #expect(error.errorDescription?.isEmpty == false,
                        "\(label): у отказа нет текста для человека")
            }
        }
    }

    /// Зашитый в программу ключ обязан читаться. Если сборка вышла с испорченным
    /// ключом, это дефект сборки, а не «лицензия недействительна».
    @Test func embeddedPublicKeyIsUsable() throws {
        let key = try LicencePublicKey.embedded()
        #expect(key.rawRepresentation.count == 32)
        #expect(Data(base64Encoded: LicencePublicKey.embeddedBase64)?.count == 32)
        // «Ключ читается» само по себе ничего не значит. Проверяем, что он
        // РАЗЛИЧАЕТ: токен, подписанный чужим ключом, зашитым не принимается.
        let stranger = TokenMaker()
        let state = try LicenceVerifier.evaluate(rawToken: try stranger.token(payload()),
                                                 publicKey: key,
                                                 expectedFingerprint: thisDevice,
                                                 now: base)
        #expect(state == .invalidSignature)
        // И негодная длина ключа обязана быть отказом, а не молчаливым приёмом.
        #expect(throws: (any Error).self) {
            _ = try Curve25519.Signing.PublicKey(rawRepresentation: Data([1, 2, 3]))
        }
    }
}

// MARK: - Часы

struct LicenceClockTests {

    /// Перевод часов назад на месяц НЕ улучшает состояние.
    /// Внутри — отрицательный контроль: без защиты тот же перевод часов
    /// действительно превратил бы `.leaseExpired` в `.valid`. Без этого показа
    /// зелёный тест не отличал бы «защита работает» от «аренда и так жива».
    @Test func clockTurnedBackAMonthDoesNotImproveState() throws {
        let maker = TokenMaker()
        let leaseUntil = base.addingTimeInterval(-10 * day)
        let raw = try maker.token(payload(paidUntil: base.addingTimeInterval(300 * day),
                                          leaseUntil: leaseUntil))
        let turnedBack = base.addingTimeInterval(-30 * day)

        // Без защиты: аренда в будущем относительно подкрученных часов.
        let naive = try LicenceVerifier.evaluate(rawToken: raw,
                                                  publicKey: maker.publicKey,
                                                  expectedFingerprint: thisDevice,
                                                  now: turnedBack)
        #expect(naive.allowsLaunch, "отрицательный контроль: без защиты подкрутка работала бы")

        // С защитой: берём наибольшую виденную дату.
        let effective = LicenceClock.effectiveNow(systemNow: turnedBack, lastSeen: base)
        #expect(effective == base)
        let guarded = try LicenceVerifier.evaluate(rawToken: raw,
                                                   publicKey: maker.publicKey,
                                                   expectedFingerprint: thisDevice,
                                                   now: effective)
        #expect(!guarded.allowsLaunch)
        if case .leaseExpired = guarded {} else { Issue.record("ожидалось .leaseExpired, получено \(guarded)") }
    }

    @Test func honestDriftWithinADayIsTolerated() {
        // Смена часового пояса и поправка NTP — законные расхождения, и
        // придираться к ним значило бы ломать лицензию честным людям.
        let drifted = base.addingTimeInterval(-6 * 60 * 60)
        #expect(LicenceClock.effectiveNow(systemNow: drifted, lastSeen: base) == drifted)
        // А ровно за границей допуска — уже подкрутка.
        let beyond = base.addingTimeInterval(-LicenceClock.backwardTolerance - 60)
        #expect(LicenceClock.effectiveNow(systemNow: beyond, lastSeen: base) == base)
    }

    @Test func markMovesForwardButNotIntoAbsurdFuture() {
        #expect(LicenceClock.advancedMark(systemNow: base, lastSeen: nil) == base)
        #expect(LicenceClock.advancedMark(systemNow: base.addingTimeInterval(day), lastSeen: base)
                == base.addingTimeInterval(day))
        #expect(LicenceClock.advancedMark(systemNow: base.addingTimeInterval(-day), lastSeen: base) == nil,
                "назад метку не двигаем")
        #expect(LicenceClock.advancedMark(systemNow: base.addingTimeInterval(4000 * day), lastSeen: base) == nil,
                "случайный 2040-й не должен необратимо портить метку")
    }
}

// MARK: - Отпечаток устройства

struct DeviceFingerprintTests {

    @Test func fingerprintIsAHashAndNeverLeaksTheRawUUID() {
        let uuid = "A1B2C3D4-1111-2222-3333-444455556666"
        let fingerprint = DeviceFingerprint.hash(platformUUID: uuid)

        #expect(fingerprint.count == 64, "SHA256 шестнадцатеричной строкой — 64 знака")
        #expect(fingerprint.allSatisfy { $0.isHexDigit })
        // ★ Главное здесь: сырой UUID наружу не уходит ни целиком, ни куском.
        #expect(!fingerprint.uppercased().contains(uuid.uppercased()))
        for piece in uuid.split(separator: "-") {
            #expect(!fingerprint.uppercased().contains(piece.uppercased()),
                    "в отпечатке видно кусок UUID: \(piece)")
        }
        #expect(!fingerprint.contains(DeviceFingerprint.salt))
    }

    @Test func fingerprintIsStableAndUnique() {
        let a = DeviceFingerprint.hash(platformUUID: "AAAA-0001")
        let b = DeviceFingerprint.hash(platformUUID: "AAAA-0002")
        #expect(a == DeviceFingerprint.hash(platformUUID: "AAAA-0001"), "один UUID — один отпечаток")
        #expect(a != b, "разные UUID — разные отпечатки")
        // Соль участвует: тот же UUID без соли дал бы другое число, поэтому
        // сверить наш отпечаток с чужой базой хешей не получится.
        let unsalted = SHA256.hash(data: Data("AAAA-0001".utf8)).map { String(format: "%02x", $0) }.joined()
        #expect(a != unsalted, "соль не применяется — отпечаток сверяется с чужой базой")
    }

    /// На этой машине отпечаток обязан строиться: IOPlatformUUID есть у любого
    /// Mac. Если тест покраснел — сломался путь через IOKit, и лицензия не
    /// проверится ни у кого.
    @Test func currentFingerprintIsAvailableOnThisMac() throws {
        let fingerprint = try DeviceFingerprint.current()
        #expect(fingerprint.count == 64)
        #expect(fingerprint == (try DeviceFingerprint.current()), "отпечаток должен быть устойчив")
        let uuid = try DeviceFingerprint.platformUUID()
        #expect(!uuid.isEmpty)
        #expect(fingerprint == DeviceFingerprint.hash(platformUUID: uuid))
    }
}

// MARK: - Хранилище

@MainActor
struct LicenceStoreTests {

    private func makeStore(maker: TokenMaker,
                           storage: LicenceMemoryStorage,
                           now: Date = base,
                           fingerprint: String = thisDevice) -> LicenceStore {
        LicenceStore(storage: storage,
                     tokenAccount: "token",
                     lastSeenAccount: "last-seen",
                     fingerprintProvider: { fingerprint },
                     systemClock: { now },
                     publicKeyProvider: { maker.publicKey })
    }

    @Test func installThenReloadThenRemove() throws {
        let maker = TokenMaker()
        let storage = LicenceMemoryStorage()
        let store = makeStore(maker: maker, storage: storage)

        #expect(store.state == .absent, "до установки токена нет")
        store.reload()
        #expect(store.state == .absent)
        #expect(store.lastFailure == nil, "отсутствие токена — не отказ")

        try store.install(rawToken: try maker.token(payload()))
        #expect(store.state.allowsLaunch)
        #expect(storage.peek("token") != nil, "токен не сохранён")

        // Перезапуск программы: состояние обязано подняться из связки ключей.
        let afterRestart = makeStore(maker: maker, storage: storage)
        afterRestart.reload()
        #expect(afterRestart.state.allowsLaunch)

        try store.remove()
        #expect(store.state == .absent)
        #expect(storage.peek("token") == nil)
        // Главное в C и здесь: после удаления состояние именно `.absent`.
        let afterRemoval = makeStore(maker: maker, storage: storage)
        afterRemoval.reload()
        #expect(afterRemoval.state == .absent)
    }

    @Test func installRejectsBadTokenAndKeepsTheGoodOne() throws {
        let maker = TokenMaker()
        let stranger = TokenMaker()
        let storage = LicenceMemoryStorage()
        let store = makeStore(maker: maker, storage: storage)

        let good = try maker.token(payload())
        try store.install(rawToken: good)

        // Негодный токен не смеет затирать годный: человек, которому сервер
        // однажды ответил мусором, иначе остался бы без лицензии до связи.
        let forged = try stranger.token(payload())
        #expect(throws: LicenceError.self) { try store.install(rawToken: forged) }
        #expect(storage.peek("token") == good, "годный токен затёрт негодным")
        #expect(store.state.allowsLaunch, "состояние испорчено чужим токеном")

        for junk in ["", "мусор", "aGVsbG8.aGVsbG8.aGVsbG8"] {
            #expect(throws: LicenceError.self) { try store.install(rawToken: junk) }
        }
        #expect(storage.peek("token") == good)
    }

    @Test func installRejectsTokenOfAnotherDevice() throws {
        let maker = TokenMaker()
        let storage = LicenceMemoryStorage()
        let store = makeStore(maker: maker, storage: storage)
        do {
            try store.install(rawToken: try maker.token(payload(fingerprint: otherDevice)))
            Issue.record("чужой токен принят")
        } catch let LicenceError.rejected(state) {
            #expect(state == .wrongDevice(expected: otherDevice, actual: thisDevice))
        }
        #expect(storage.peek("token") == nil)
    }

    /// Порча токена в самой связке ключей: состояние `.invalidSignature`
    /// («подделка ИЛИ порча»), и отказ назван, а не проглочен.
    @Test func damagedStoredTokenIsReportedNotIgnored() throws {
        let maker = TokenMaker()
        let storage = LicenceMemoryStorage(items: ["token": "испорчено до неузнаваемости"])
        let store = makeStore(maker: maker, storage: storage)
        store.reload()
        #expect(store.state == .invalidSignature)
        #expect(store.lastFailure != nil, "отказ проглочен")
        #expect(!store.state.allowsLaunch)
    }

    /// Отказ связки ключей обязан быть виден. Пустое состояние без названного
    /// отказа выглядело бы как «лицензии нет» — и искали бы её месяц.
    @Test func keychainFailureIsVisible() {
        let maker = TokenMaker()
        let storage = LicenceMemoryStorage()
        storage.failure = .keychain(errSecInteractionNotAllowed)
        let store = makeStore(maker: maker, storage: storage)
        store.reload()
        #expect(store.lastFailure == .keychain(errSecInteractionNotAllowed))
        #expect(!store.state.allowsLaunch)
    }

    /// Подкрутка часов через хранилище, целиком: метка лежит в связке ключей,
    /// часы переведены на месяц назад — состояние НЕ улучшается.
    @Test func clockTamperThroughStoreDoesNotRestoreLease() throws {
        let maker = TokenMaker()
        let raw = try maker.token(payload(paidUntil: base.addingTimeInterval(300 * day),
                                          leaseUntil: base.addingTimeInterval(-10 * day)))
        let storage = LicenceMemoryStorage(items: [
            "token": raw,
            "last-seen": String(base.timeIntervalSince1970)
        ])
        let store = makeStore(maker: maker, storage: storage, now: base.addingTimeInterval(-30 * day))
        store.reload()
        if case .leaseExpired = store.state {} else {
            Issue.record("подкрутка часов вернула лицензию: \(store.state)")
        }
        // Метка не сдвинулась назад — иначе следующая подкрутка сработала бы.
        #expect(storage.peek("last-seen") == String(base.timeIntervalSince1970))
    }

    @Test func markIsKeptAfterRemovalSoTamperingStaysBlocked() throws {
        let maker = TokenMaker()
        let storage = LicenceMemoryStorage()
        let store = makeStore(maker: maker, storage: storage)
        try store.install(rawToken: try maker.token(payload()))
        #expect(storage.peek("last-seen") != nil, "метка не записана")
        try store.remove()
        #expect(storage.peek("last-seen") != nil,
                "метка стёрта вместе с токеном — «удалить, перевести часы, вернуть» сбросит защиту")
    }

    /// Метка испорчена при живом токене. Стереть её молча значило бы открыть
    /// дорогу подкрутке часов: достаточно испортить одну запись. Поэтому отказ
    /// назван, и запуска не даём.
    @Test func corruptedClockMarkIsNamedNotSilentlyDropped() throws {
        let maker = TokenMaker()
        let storage = LicenceMemoryStorage(items: [
            "token": try maker.token(payload()),
            "last-seen": "это не число"
        ])
        let store = makeStore(maker: maker, storage: storage)
        store.reload()
        #expect(store.lastFailure == .keychain(errSecInvalidData))
        #expect(!store.state.allowsLaunch, "испорченная метка не должна давать запуск")
    }

    /// ЖИВАЯ проверка настоящей связки ключей macOS. По умолчанию выключена,
    /// чтобы `swift test` не зависел от связки ключей и не ловил окно запроса
    /// доступа. Включать так:
    ///   MACRUNNER_LICENCE_KEYCHAIN_TEST=1 swift test --no-parallel
    /// Работает СВОИМ служебным ключом `macrunner.licence.test` и убирает его
    /// за собой: чужие записи в связке ключей не трогаются ни при каких условиях.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["MACRUNNER_LICENCE_KEYCHAIN_TEST"] == "1"))
    func liveKeychainRoundTrip() throws {
        let keychain = LicenceKeychain()
        let account = LicenceKeychain.testAccount
        try keychain.delete(account: account)   // на случай хвоста прошлого прогона
        defer { try? keychain.delete(account: account) }

        #expect(try keychain.read(account: account) == nil, "до записи должно быть пусто")
        try keychain.write("токен-проба-\(UUID().uuidString)", account: account)
        let stored = try #require(try keychain.read(account: account))
        #expect(stored.hasPrefix("токен-проба-"))
        try keychain.write("перезапись", account: account)
        #expect(try keychain.read(account: account) == "перезапись", "повторная запись не прошла")
        try keychain.delete(account: account)
        #expect(try keychain.read(account: account) == nil, "после удаления запись осталась")
        // Повторное удаление не должно быть отказом: errSecItemNotFound — норма.
        try keychain.delete(account: account)

        // И то же через хранилище лицензии: после удаления состояние `.absent`.
        let maker = TokenMaker()
        let store = LicenceStore(storage: keychain,
                                 tokenAccount: account,
                                 lastSeenAccount: account + ".last-seen",
                                 fingerprintProvider: { thisDevice },
                                 systemClock: { base },
                                 publicKeyProvider: { maker.publicKey })
        defer { try? keychain.delete(account: account + ".last-seen") }
        try store.install(rawToken: try maker.token(payload()))
        #expect(store.state.allowsLaunch, "живая связка ключей не приняла годный токен")
        store.reload()
        #expect(store.state.allowsLaunch, "токен не поднялся из живой связки ключей")
        try store.remove()
        store.reload()
        #expect(store.state == .absent, "после удаления состояние не .absent")
    }
}

/// Мягкое правило: «что у тебя есть — работает всегда, всё новое — по подписке».
///
/// ★ Правило коммерческое, и именно на нём держится обещание бессрочной лицензии:
///   если приложение перестанет запускать установленное, когда проекта не станет,
///   обещание окажется обманом. Поэтому тест здесь обязателен — без него правило
///   можно молча сломать правкой в одну строку.
struct SoftLaunchRuleTests {

    private func token(paidUntil: Date?) -> LicenceToken {
        LicenceToken(licenceID: "L-TEST", plan: .yearly, paidUntil: paidUntil,
                     leaseUntil: nil, deviceFingerprint: "FP", deviceSlots: 1,
                     allowsUnbind: true, issuedAt: Date(timeIntervalSince1970: 0))
    }

    @Test("Действующая лицензия пускает и новую игру, и уже запускавшуюся")
    func validAllowsBoth() {
        let state = LicenceState.valid(token(paidUntil: Date(timeIntervalSinceNow: 86_400)))
        #expect(state.allowsLaunch(hasRunBefore: false))
        #expect(state.allowsLaunch(hasRunBefore: true))
    }

    @Test("★ Истёкшая лицензия ПУСКАЕТ уже запускавшуюся игру")
    func expiredStillRunsInstalled() {
        let state = LicenceState.expired(token(paidUntil: Date(timeIntervalSinceNow: -86_400)))
        #expect(state.allowsLaunch(hasRunBefore: true))
    }

    @Test("★ Истёкшая лицензия НЕ пускает игру, которая ни разу не запускалась")
    func expiredBlocksNewGame() {
        let state = LicenceState.expired(token(paidUntil: Date(timeIntervalSinceNow: -86_400)))
        #expect(!state.allowsLaunch(hasRunBefore: false))
    }

    @Test("Без лицензии новую игру не запустить")
    func absentBlocksNewGame() {
        #expect(!LicenceState.absent.allowsLaunch(hasRunBefore: false))
    }

    @Test("Чужое устройство и подделка не пускают новую игру")
    func wrongDeviceAndForgeryBlockNewGame() {
        #expect(!LicenceState.wrongDevice(expected: "A", actual: "B").allowsLaunch(hasRunBefore: false))
        #expect(!LicenceState.invalidSignature.allowsLaunch(hasRunBefore: false))
    }

    @Test("Кончившаяся аренда ведёт себя как истёкшая: старое идёт, новое нет")
    func leaseExpiredFollowsTheSameRule() {
        let state = LicenceState.leaseExpired(token(paidUntil: Date(timeIntervalSinceNow: 86_400)))
        #expect(state.allowsLaunch(hasRunBefore: true))
        #expect(!state.allowsLaunch(hasRunBefore: false))
    }
}
