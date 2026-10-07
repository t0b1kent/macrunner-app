import CryptoKit
import Foundation
import IOKit
import Security

// ============================================================================
//  Лицензирование MacRunner — ПРОВЕРЯЮЩАЯ сторона.
//
//  В приложении лежит ТОЛЬКО открытый ключ. Подделать токен без закрытого ключа
//  нельзя, подставить свой сервер — тоже: его подпись не сойдётся.
//
//  Токен двухслойный, и это главное в схеме:
//
//      ПРАВО  (paidUntil)   «лицензия оплачена до <дата>»    длинный срок
//      АРЕНДА (leaseUntil)  «это устройство работает до ...»  45 дней, продлевается молча
//
//  Зачем два слоя: игры обязаны запускаться БЕЗ ИНТЕРНЕТА. Аренда обновляется
//  сама, когда связь есть, и человек её не замечает. Если владелец отвязал
//  устройство, новой аренды оно не получит и доживёт до конца текущей — то есть
//  отвязка действует без всякой связи с отвязанной машиной, просто не сразу.
//
//  Для пожизненной лицензии и для тех, кто живёт офлайн, аренда БЕССРОЧНАЯ
//  (leaseUntil == nil), но тогда и отвязать устройство нельзя (allowsUnbind).
//  Это честный обмен: либо отзыв, либо вечный офлайн — одновременно не бывает.
// ============================================================================

// MARK: - Разобранный и проверенный токен

/// Разобранный и ПРОВЕРЕННЫЙ токен.
///
/// Значение этого типа существует только после того, как подпись сошлась.
/// Непроверенных токенов в виде `LicenceToken` в программе не бывает —
/// единственный способ его получить — `LicenceVerifier.evaluate`.
struct LicenceToken: Equatable, Sendable {
    enum Plan: String, Codable, Sendable {
        case trial, monthly, yearly, lifetime, business
    }

    let licenceID: String
    let plan: Plan
    /// Право оплачено до этой даты. nil — бессрочно (пожизненная).
    let paidUntil: Date?
    /// Аренда устройства до этой даты. nil — бессрочная аренда (офлайн-лицензия).
    let leaseUntil: Date?
    /// Отпечаток устройства, которому выдан токен.
    let deviceFingerprint: String
    /// Сколько устройств позволяет тариф (для показа человеку).
    let deviceSlots: Int
    /// Можно ли отвязывать устройство. У офлайн-лицензии — false.
    let allowsUnbind: Bool
    let issuedAt: Date

    /// Нужно ли просить у сервера продление. Порог — четверть срока аренды,
    /// чтобы у человека была неделя-другая запаса на поездку без связи.
    /// Бессрочная аренда не продлевается никогда.
    func needsLeaseRenewal(now: Date, horizon: TimeInterval = 14 * 24 * 60 * 60) -> Bool {
        guard let leaseUntil else { return false }
        return leaseUntil.timeIntervalSince(now) < horizon
    }
}

// MARK: - Состояние

enum LicenceState: Equatable {
    case valid(LicenceToken)
    /// Право есть, аренда кончилась — нужна связь, чтобы продлить.
    case leaseExpired(LicenceToken)
    /// Срок оплаты кончился.
    case expired(LicenceToken)
    /// Токен есть, но выдан ДРУГОМУ устройству.
    /// `expected` — отпечаток из токена (кому он выдан),
    /// `actual` — отпечаток ЭТОЙ машины. Порядок назван здесь, потому что
    /// по именам его не угадать, а перепутанные местами значения выглядят
    /// как работающая проверка.
    case wrongDevice(expected: String, actual: String)
    /// Подпись не сходится — подделка или порча.
    case invalidSignature
    /// Токена нет вовсе.
    case absent

    /// Можно ли запускать игры. Единственная точка, которой следует спрашивать
    /// разрешение: перечислять случаи в видах — значит однажды забыть один.
    var allowsLaunch: Bool {
        if case .valid = self { return true }
        return false
    }

    /// ★★★ МЯГКОЕ ПРАВИЛО (решение владельца, 12.09.2026).
    ///
    ///   «Что у тебя есть — работает всегда. Всё новое — по подписке.»
    ///
    ///   ПЕРВЫЙ запуск требует действующей лицензии: при нём берётся профиль
    ///   совместимости с сервера, и сервер его без лицензии не отдаёт.
    ///   ПОСЛЕДУЮЩИЕ запуски — целиком местные, без сети и без проверок.
    ///
    ///   Это не доброта, а условие, без которого нельзя честно продавать
    ///   бессрочную лицензию: если приложение перестанет запускать установленное,
    ///   когда проекта не станет, обещание окажется обманом (см. reports/ЛИЦЕНЗИЯ-ПЛАН).
    ///
    ///   `hasRunBefore` берётся из записи библиотеки: у ни разу не запускавшейся
    ///   игры нет итога прошлого прогона.
    func allowsLaunch(hasRunBefore: Bool) -> Bool {
        if allowsLaunch { return true }
        return hasRunBefore
    }

    var token: LicenceToken? {
        switch self {
        case let .valid(token), let .leaseExpired(token), let .expired(token): return token
        case .wrongDevice, .invalidSignature, .absent: return nil
        }
    }
}

// MARK: - Отказы

enum LicenceError: LocalizedError, Equatable {
    /// В связке ключей токена нет.
    case absentToken
    /// Не похоже на токен: нет точки, пустая половина, лишние точки.
    case malformedToken(String)
    /// Половина токена не декодируется из base64url.
    case notBase64(String)
    /// Подпись СОШЛАСЬ, а полезная нагрузка не разобралась. Значит ошибся наш
    /// сервер: подделать подпись нельзя, поэтому сюда чужой токен не доходит.
    case malformedPayload(String)
    /// Зашитый в программу открытый ключ испорчен — сборка негодная.
    case badPublicKey
    /// IOKit не отдал IOPlatformUUID: отпечаток устройства не построить.
    case fingerprintUnavailable(String)
    /// Связка ключей отказала. Код OSStatus назван, а не проглочен.
    case keychain(OSStatus)
    /// Токен разобран, но принять его нельзя. Состояние названо, чтобы виду
    /// было что показать человеку, а не «ошибка лицензии».
    case rejected(LicenceState)

    var errorDescription: String? {
        switch self {
        case .absentToken:
            return L("No licence token on this device.")
        case let .malformedToken(detail):
            return L("The licence token is malformed.") + " (\(detail))"
        case let .notBase64(detail):
            return L("The licence token is not valid base64url.") + " (\(detail))"
        case let .malformedPayload(detail):
            return L("The licence token is signed but its contents are unreadable.") + " (\(detail))"
        case .badPublicKey:
            return L("The bundled licence public key is invalid; this build cannot check licences.")
        case let .fingerprintUnavailable(detail):
            return L("Could not read this Mac's hardware identifier.") + " (\(detail))"
        case let .keychain(status):
            return L("Keychain refused the licence operation.") + " (OSStatus \(status))"
        case let .rejected(state):
            switch state {
            case .invalidSignature:
                return L("This licence token is not signed by MacRunner.")
            case let .wrongDevice(expected, actual):
                return L("This licence token belongs to another Mac.")
                    + " (\(expected.prefix(12))… ≠ \(actual.prefix(12))…)"
            case .expired:
                return L("This licence has expired.")
            case .leaseExpired:
                return L("This device's licence lease has expired; connect to the internet to renew it.")
            case .absent:
                return L("No licence token on this device.")
            case .valid:
                return nil
            }
        }
    }
}

// MARK: - Открытый ключ

/// Открытый ключ проверки, зашитый в программу.
///
/// ★ Закрытая половина этой пары в репозитории НЕ ЛЕЖИТ и лежать не должна —
///   она нужна только серверу выдачи токенов. Ключ разработки создан
///   12.09.2026 через CryptoKit (`Curve25519.Signing.PrivateKey`).
enum LicencePublicKey {
    /// Ed25519, rawRepresentation, 32 байта, base64.
    static let embeddedBase64 = "z+PblMJEUH5ssC/Dc+PGuYfpQyF2tiGu5118jadrtPY="

    static func embedded() throws -> Curve25519.Signing.PublicKey {
        guard let raw = Data(base64Encoded: embeddedBase64) else { throw LicenceError.badPublicKey }
        do {
            return try Curve25519.Signing.PublicKey(rawRepresentation: raw)
        } catch {
            // Не `try?`: испорченный зашитый ключ — дефект сборки, и он обязан
            // быть назван, а не превратиться в «лицензия недействительна».
            throw LicenceError.badPublicKey
        }
    }
}

// MARK: - base64url

/// base64url без набивки — так токен переносится в URL и в заголовке без экранирования.
enum LicenceBase64URL {
    static func encode(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    /// nil — строка не base64url. Проверять возврат обязательно: молчаливый
    /// пустой `Data` здесь читался бы как «подпись пустая», а не как «мусор».
    static func decode(_ text: String) -> Data? {
        guard !text.isEmpty else { return nil }
        var s = text
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Восстанавливаем набивку до кратности четырём.
        let remainder = s.count % 4
        if remainder == 1 { return nil }  // такой длины base64 не бывает
        if remainder > 0 { s += String(repeating: "=", count: 4 - remainder) }
        return Data(base64Encoded: s)
    }
}

// MARK: - Формат передачи полезной нагрузки

/// То, что сервер кладёт в первую половину токена. Отдельный тип от
/// `LicenceToken` намеренно: здесь описан ФОРМАТ ПЕРЕДАЧИ (имена полей,
/// секунды Unix), и менять его нельзя, не сломав уже выданные токены.
/// Даты — целые секунды Unix: ни часовых поясов, ни локалей, ни разборщика
/// ISO-8601, который в каждом языке свой.
///
/// Отсутствующее поле и явный `null` значат одно и то же — «бессрочно».
struct LicencePayload: Codable, Equatable {
    var licenceID: String
    var plan: LicenceToken.Plan
    var paidUntil: Int?
    var leaseUntil: Int?
    var deviceFingerprint: String
    var deviceSlots: Int
    var allowsUnbind: Bool
    var issuedAt: Int

    enum CodingKeys: String, CodingKey {
        case licenceID = "licence_id"
        case plan
        case paidUntil = "paid_until"
        case leaseUntil = "lease_until"
        case deviceFingerprint = "device_fingerprint"
        case deviceSlots = "device_slots"
        case allowsUnbind = "allows_unbind"
        case issuedAt = "issued_at"
    }

    var token: LicenceToken {
        LicenceToken(
            licenceID: licenceID,
            plan: plan,
            paidUntil: paidUntil.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            leaseUntil: leaseUntil.map { Date(timeIntervalSince1970: TimeInterval($0)) },
            deviceFingerprint: deviceFingerprint,
            deviceSlots: deviceSlots,
            allowsUnbind: allowsUnbind,
            issuedAt: Date(timeIntervalSince1970: TimeInterval(issuedAt))
        )
    }
}

// MARK: - Проверка токена

enum LicenceVerifier {

    /// ★★★ ЧТО ИМЕННО ПОДПИСАНО.
    ///
    /// Токен: `<base64url(JSON)>.<base64url(подпись)>`.
    /// Подписаны РОВНО ASCII-байты ПЕРВОЙ ЧАСТИ — той самой строки base64url,
    /// как она пришла, — а НЕ раскодированный JSON. Так же устроен JWT.
    ///
    /// Почему так, а не «подписываем JSON»: раскодировать base64, разобрать
    /// JSON в структуру и снова его закодировать — значит получить ДРУГИЕ байты
    /// (порядок ключей, пробелы, форма чисел), и подпись перестанет сходиться.
    /// Отказ при этом выглядит как «неверный ключ» или «сервер сломался», и
    /// искать его будут где угодно, только не в перекодировке.
    ///
    /// Будущему серверу: подписывать надо именно эти байты —
    /// `base64url(json).utf8`, detached-подпись Ed25519, 64 байта.
    static func signedBytes(ofTokenPart part: String) -> Data {
        Data(part.utf8)
    }

    /// Отдельная функция на одну строку — ради проверяемости: тест ломает
    /// ИМЕННО её (заставляет всегда возвращать true) и убеждается, что набор
    /// краснеет. Проверка, чью поломку тесты не замечают, ничего не проверяет.
    static func signatureIsValid(signature: Data,
                                 over signed: Data,
                                 publicKey: Curve25519.Signing.PublicKey) -> Bool {
        publicKey.isValidSignature(signature, for: signed)
    }

    /// Разбирает и проверяет токен.
    ///
    /// Порядок шагов важен и выбран нарочно: **подпись проверяется ДО разбора
    /// JSON**. Во-первых, так мы никогда не разбираем неподписанные данные.
    /// Во-вторых, любая порча полезной нагрузки — хоть одна буква — даёт
    /// `.invalidSignature`, а не случайную ошибку разбора, которая зависела бы
    /// от того, куда попала испорченная буква.
    ///
    /// Бросает только на том, что токеном не является (нет точки, не base64,
    /// а после сошедшейся подписи — нечитаемый JSON). Смысловые отказы
    /// (подделка, чужое устройство, истёк срок) возвращаются состоянием.
    static func evaluate(rawToken: String,
                         publicKey: Curve25519.Signing.PublicKey,
                         expectedFingerprint: String,
                         now: Date) throws -> LicenceState {
        let trimmed = rawToken.trimmingCharacters(in: .whitespacesAndNewlines)
        // ★ Подробности отказов идут человеку в окно «Лицензия» дословно, поэтому
        //   переводятся (раньше были русскими при любом языке интерфейса).
        guard !trimmed.isEmpty else { throw LicenceError.malformedToken(L("empty string")) }

        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else {
            throw LicenceError.malformedToken(String(format: L("%d parts, expected 2 (payload.signature)"), parts.count))
        }
        guard !parts[0].isEmpty, !parts[1].isEmpty else {
            throw LicenceError.malformedToken(L("one half of the token is empty"))
        }

        guard let payloadData = LicenceBase64URL.decode(parts[0]) else {
            throw LicenceError.notBase64(L("payload"))
        }
        guard let signature = LicenceBase64URL.decode(parts[1]) else {
            throw LicenceError.notBase64(L("signature"))
        }

        // Подпись — ПЕРВЫМ делом, над исходными байтами первой части.
        // Неверная длина подписи — тоже негодная подпись, а не «испорченный
        // токен»: CryptoKit на ней просто отвечает false.
        guard signatureIsValid(signature: signature,
                               over: signedBytes(ofTokenPart: parts[0]),
                               publicKey: publicKey) else {
            return .invalidSignature
        }

        let payload: LicencePayload
        do {
            payload = try JSONDecoder().decode(LicencePayload.self, from: payloadData)
        } catch {
            throw LicenceError.malformedPayload(String(describing: error))
        }
        let token = payload.token

        // 1. Кому выдан. Проверяется раньше сроков: «чужая машина» — ответ
        //    полезнее, чем «истёк срок», если верно и то и другое.
        guard token.deviceFingerprint == expectedFingerprint else {
            return .wrongDevice(expected: token.deviceFingerprint, actual: expectedFingerprint)
        }
        // 2. Оплата. Раньше аренды: кончились деньги — продлевать аренду нечем,
        //    и показывать «нужна связь» было бы обманом.
        if let paidUntil = token.paidUntil, paidUntil < now {
            return .expired(token)
        }
        // 3. Аренда. Право ещё есть, нужна только связь.
        if let leaseUntil = token.leaseUntil, leaseUntil < now {
            return .leaseExpired(token)
        }
        return .valid(token)
    }

    /// То же, но с зашитым в программу ключом.
    static func evaluate(rawToken: String,
                         expectedFingerprint: String,
                         now: Date) throws -> LicenceState {
        try evaluate(rawToken: rawToken,
                     publicKey: try LicencePublicKey.embedded(),
                     expectedFingerprint: expectedFingerprint,
                     now: now)
    }
}

// MARK: - Часы

/// Часы у человека могут врать, а могут быть переведены назад нарочно —
/// чтобы истёкшая аренда снова стала действующей.
///
/// Защита простая и без сети: помним НАИБОЛЬШУЮ виденную дату. Если система
/// показывает время РАНЬШЕ неё больше чем на сутки — это перевод назад, и мы
/// берём запомненную дату. Сутки допуска, а не ноль: смена часового пояса,
/// поправка NTP и разряженная батарейка дают законные расхождения в часы,
/// и придираться к ним значило бы ломать лицензию честным людям.
///
/// Чего это НЕ умеет: перевод часов ВПЕРЁД. Он лицензию только сокращает,
/// поэтому играть на нём нечем — зато он навсегда поднимает нашу метку, и
/// человек, переставивший часы на 2040 год, останется без лицензии и после
/// возврата времени. Поэтому вперёд метку двигаем, но не дальше, чем на
/// разумный шаг за один запуск.
enum LicenceClock {
    /// Допуск на честные расхождения.
    static let backwardTolerance: TimeInterval = 24 * 60 * 60
    /// Насколько метке позволено прыгнуть вперёд за один запуск (год).
    /// Ограничение спасает от необратимой порчи метки случайным 2040-м.
    static let forwardLimit: TimeInterval = 366 * 24 * 60 * 60

    /// Время, по которому судим о сроках.
    static func effectiveNow(systemNow: Date, lastSeen: Date?) -> Date {
        guard let lastSeen else { return systemNow }
        if systemNow < lastSeen.addingTimeInterval(-backwardTolerance) {
            return lastSeen  // часы переведены назад — верим метке
        }
        return systemNow
    }

    /// Новое значение метки, если её надо переписать; nil — оставить как есть.
    static func advancedMark(systemNow: Date, lastSeen: Date?) -> Date? {
        guard let lastSeen else { return systemNow }
        guard systemNow > lastSeen else { return nil }
        guard systemNow <= lastSeen.addingTimeInterval(forwardLimit) else { return nil }
        return systemNow
    }
}

// MARK: - Отпечаток устройства

/// Отпечаток устройства.
enum DeviceFingerprint {
    /// Соль приложения. Версия в имени — чтобы смену соли было видно как смену
    /// схемы отпечатков, а не как «у всех разом сломалась лицензия».
    static let salt = "macrunner.licence.fingerprint.v1"

    /// Аппаратный UUID Mac (IOPlatformUUID), посоленный и захешированный.
    /// ★ СЫРОЙ UUID НАРУЖУ НЕ УХОДИТ НИКОГДА — только хеш.
    static func current() throws -> String {
        hash(platformUUID: try platformUUID())
    }

    /// SHA256 от `соль + UUID`, шестнадцатеричной строкой.
    ///
    /// Соль здесь не от подбора пароля (UUID не секрет и подбирается за
    /// секунды), а чтобы наш отпечаток нельзя было сверить с чужой базой
    /// таких же хешей: чужой сервис, хешировавший тот же UUID без нашей соли,
    /// получит другое число и связать одного человека в двух базах не сможет.
    static func hash(platformUUID uuid: String) -> String {
        let digest = SHA256.hash(data: Data((salt + uuid).utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }

    /// Сырой аппаратный UUID. Отдельно от `current()` ради проверяемости —
    /// и намеренно не публикуется дальше этого файла ни в токен, ни в сеть.
    static func platformUUID() throws -> String {
        // io_service_t — это mach_port_t, то есть UInt32; «ничего не нашлось»
        // здесь именно 0 (IO_OBJECT_NULL), макрос в Swift не импортируется.
        let service = IOServiceGetMatchingService(kIOMainPortDefault,
                                                 IOServiceMatching("IOPlatformExpertDevice"))
        guard service != 0 else {
            throw LicenceError.fingerprintUnavailable(L("IOPlatformExpertDevice not found"))
        }
        defer { IOObjectRelease(service) }

        // "IOPlatformUUID" — имя свойства в реестре; строкой, а не константой
        // kIOPlatformUUIDKey, чтобы не зависеть от того, как её импортирует
        // очередная версия SDK.
        guard let property = IORegistryEntryCreateCFProperty(service,
                                                            "IOPlatformUUID" as CFString,
                                                            kCFAllocatorDefault,
                                                            0) else {
            throw LicenceError.fingerprintUnavailable(L("IOPlatformExpertDevice has no IOPlatformUUID"))
        }
        guard let uuid = property.takeRetainedValue() as? String, !uuid.isEmpty else {
            throw LicenceError.fingerprintUnavailable(L("IOPlatformUUID is not a string or is empty"))
        }
        return uuid
    }
}

// MARK: - Хранение

/// Что умеет хранилище секретов. Протокол нужен не «для красоты»: он позволяет
/// тестам проверять переходы состояний, НЕ ТРОГАЯ настоящую связку ключей
/// человека, — а настоящую связку мы проверяем отдельно и своим служебным
/// ключом (см. `LicenceKeychain.testAccount`).
protocol LicenceSecretStorage: AnyObject {
    func read(account: String) throws -> String?
    func write(_ value: String, account: String) throws
    func delete(account: String) throws
}

/// Связка ключей macOS. Не файл и не UserDefaults: из файла токен уносится
/// копированием вместе с папкой, а UserDefaults вообще читает любой процесс.
final class LicenceKeychain: LicenceSecretStorage {
    /// Служба своя, отдельно от `app.macrunner.license` старого хранилища ключей.
    static let service = "app.macrunner.licence"
    static let tokenAccount = "token.v1"
    static let lastSeenAccount = "last-seen-date.v1"
    /// Только для живой проверки руками. Своё имя — чтобы не задеть настоящий токен.
    static let testAccount = "macrunner.licence.test"

    private let service: String

    init(service: String = LicenceKeychain.service) {
        self.service = service
    }

    func read(account: String) throws -> String? {
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess else { throw LicenceError.keychain(status) }
        guard let data = result as? Data, let text = String(data: data, encoding: .utf8) else {
            // Запись есть, а прочитать нечего — это порча, и молчать о ней нельзя.
            throw LicenceError.keychain(errSecInvalidData)
        }
        return text
    }

    func write(_ value: String, account: String) throws {
        // Сначала удаляем: SecItemAdd на существующую запись даёт errSecDuplicateItem,
        // а SecItemUpdate на отсутствующую — errSecItemNotFound. Удалить-и-добавить
        // короче и не зависит от того, есть запись или нет.
        let deleteStatus = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard deleteStatus == errSecSuccess || deleteStatus == errSecItemNotFound else {
            throw LicenceError.keychain(deleteStatus)
        }
        var attributes = baseQuery(account: account)
        attributes[kSecValueData as String] = Data(value.utf8)
        // После первой разблокировки: лицензию надо проверять и при запуске
        // игры из автозагрузки, когда человек ещё не вводил пароль.
        attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
        let status = SecItemAdd(attributes as CFDictionary, nil)
        guard status == errSecSuccess else { throw LicenceError.keychain(status) }
    }

    func delete(account: String) throws {
        let status = SecItemDelete(baseQuery(account: account) as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw LicenceError.keychain(status)
        }
    }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account
        ]
    }
}

/// Хранилище в памяти — для тестов. Живёт здесь, а не в тестах, чтобы
/// соблюдать протокол вместе с настоящей реализацией и ломаться вместе с ней,
/// если протокол поменяется.
final class LicenceMemoryStorage: LicenceSecretStorage {
    private var items: [String: String]
    /// Отказ, который хранилище обязано выдать вместо работы — проверяем, что
    /// отказ связки ключей виден, а не проглочен.
    var failure: LicenceError?

    init(items: [String: String] = [:]) {
        self.items = items
    }

    func read(account: String) throws -> String? {
        if let failure { throw failure }
        return items[account]
    }

    func write(_ value: String, account: String) throws {
        if let failure { throw failure }
        items[account] = value
    }

    func delete(account: String) throws {
        if let failure { throw failure }
        items.removeValue(forKey: account)
    }

    func peek(_ account: String) -> String? { items[account] }
}

// MARK: - Хранилище лицензии

@MainActor
final class LicenceStore: ObservableObject {
    static let shared = LicenceStore()

    @Published private(set) var state: LicenceState = .absent

    /// Последний отказ, названный по имени. Состояний в `LicenceState` нарочно
    /// немного, и отказ связки ключей или IOKit в них не укладывается — но
    /// проглотить его нельзя, поэтому он лежит здесь и виден виду.
    @Published private(set) var lastFailure: LicenceError?

    private let storage: LicenceSecretStorage
    private let tokenAccount: String
    private let lastSeenAccount: String
    private let fingerprintProvider: () throws -> String
    private let systemClock: () -> Date
    private let publicKeyProvider: () throws -> Curve25519.Signing.PublicKey

    init(storage: LicenceSecretStorage = LicenceKeychain(),
         tokenAccount: String = LicenceKeychain.tokenAccount,
         lastSeenAccount: String = LicenceKeychain.lastSeenAccount,
         fingerprintProvider: @escaping () throws -> String = DeviceFingerprint.current,
         systemClock: @escaping () -> Date = Date.init,
         publicKeyProvider: @escaping () throws -> Curve25519.Signing.PublicKey = LicencePublicKey.embedded) {
        self.storage = storage
        self.tokenAccount = tokenAccount
        self.lastSeenAccount = lastSeenAccount
        self.fingerprintProvider = fingerprintProvider
        self.systemClock = systemClock
        self.publicKeyProvider = publicKeyProvider
    }

    /// Прочитать токен из связки ключей и проверить его.
    ///
    /// Не бросает — вид обязан что-то показать в любом случае. Но и не молчит:
    /// всякий отказ попадает в `lastFailure` и в stderr. `try?` здесь нет
    /// нигде: проглоченная ошибка выглядела бы как «лицензии нет».
    func reload() {
        lastFailure = nil
        do {
            state = try evaluateStoredToken()
        } catch let error as LicenceError {
            record(error)
            state = fallbackState(for: error)
        } catch {
            let wrapped = LicenceError.malformedPayload(String(describing: error))
            record(wrapped)
            state = .invalidSignature
        }
    }

    /// Положить новый токен (пришёл от сервера). Проверяет ДО сохранения.
    ///
    /// Негодный токен не должен затирать годный: человек, которому сервер
    /// однажды ответил мусором, иначе остался бы без лицензии до следующей
    /// связи — а связи может не быть недели.
    func install(rawToken: String) throws {
        lastFailure = nil
        let fingerprint = try fingerprintProvider()
        let now = try effectiveNow()
        let candidate = try LicenceVerifier.evaluate(rawToken: rawToken,
                                                     publicKey: try publicKeyProvider(),
                                                     expectedFingerprint: fingerprint,
                                                     now: now)
        guard case .valid = candidate else {
            throw LicenceError.rejected(candidate)
        }
        try storage.write(rawToken.trimmingCharacters(in: .whitespacesAndNewlines),
                          account: tokenAccount)
        state = candidate
    }

    /// Убрать токен с этого устройства.
    ///
    /// Метку времени НЕ трогаем: иначе «удалить токен — перевести часы назад —
    /// поставить старый токен обратно» сбрасывало бы защиту от подкрутки.
    func remove() throws {
        lastFailure = nil
        try storage.delete(account: tokenAccount)
        state = .absent
    }

    // MARK: Внутреннее

    private func evaluateStoredToken() throws -> LicenceState {
        guard let raw = try storage.read(account: tokenAccount) else { return .absent }
        let fingerprint = try fingerprintProvider()
        let now = try effectiveNow()
        return try LicenceVerifier.evaluate(rawToken: raw,
                                            publicKey: try publicKeyProvider(),
                                            expectedFingerprint: fingerprint,
                                            now: now)
    }

    /// Время с поправкой на подкрутку часов + подъём метки.
    private func effectiveNow() throws -> Date {
        let systemNow = systemClock()
        let lastSeen = try storedLastSeen()
        let effective = LicenceClock.effectiveNow(systemNow: systemNow, lastSeen: lastSeen)
        if let advanced = LicenceClock.advancedMark(systemNow: systemNow, lastSeen: lastSeen) {
            try storage.write(String(advanced.timeIntervalSince1970), account: lastSeenAccount)
        }
        return effective
    }

    private func storedLastSeen() throws -> Date? {
        guard let text = try storage.read(account: lastSeenAccount) else { return nil }
        guard let seconds = TimeInterval(text) else {
            // Метка испорчена. Стереть её молча — значит открыть дорогу подкрутке
            // часов: достаточно испортить одну запись. Поэтому отказ называем.
            throw LicenceError.keychain(errSecInvalidData)
        }
        return Date(timeIntervalSince1970: seconds)
    }

    /// Какое состояние показать, если разбор вообще не состоялся.
    /// Порча и подделка по виду неотличимы — и то и другое `.invalidSignature`
    /// (так и описано в самом состоянии). А вот отказ оборудования или связки
    /// ключей — не повод объявлять лицензию поддельной: там нечего проверять.
    private func fallbackState(for error: LicenceError) -> LicenceState {
        switch error {
        case .absentToken:
            return .absent
        case .malformedToken, .notBase64, .malformedPayload:
            return .invalidSignature
        case let .rejected(state):
            return state
        case .badPublicKey, .fingerprintUnavailable, .keychain:
            return .absent
        }
    }

    private func record(_ error: LicenceError) {
        lastFailure = error
        // В stderr, а не через каналы логов: до наших журналов доходит только stderr.
        FileHandle.standardError.write(Data("macrunner-licence: \(error.errorDescription ?? "\(error)")\n".utf8))
    }
}
