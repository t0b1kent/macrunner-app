import CoreGraphics
import Foundation
import SwiftUI

// Разбор контуров SVG в `Path` SwiftUI.
//
// Зачем в рантайме, а не генератором кода. В `Resources/program-icons/` лежат 54
// значка Simple Icons (CC0), у каждого РОВНО ОДИН контур в сетке 24×24. Тот же
// путь, что у `StoreBrandPaths` (генерация Swift-кода скриптом), дал бы здесь под
// 400 КБ исходника: только данные `d` этих 54 файлов — 132 КБ, а в виде вызовов
// `path.addCurve` каждая кривая раздувается втрое. Поэтому разбираем на месте, а
// результат кешируем — форма значка не меняется, второй раз разбирать нечего.
//
// Измерено по самому набору: дуги (`A`/`a`) есть у 39 из 54 контуров, встречаются
// команды M m L l H h V v C c S s A a Z z (`Q`/`T` в наборе нет, но поддержаны —
// иначе следующий добавленный значок отказал бы молча). Числа в настоящих файлах
// пишутся слитно: `.5.5` — в 51 файле из 54, `-.5` — в 50, слитные флаги дуги —
// в 5. Разбор обязан брать всё это, иначе съедет форма, а не упадёт разбор.
//
// `StoreBrandPaths` остаётся как есть: это ОРАКУЛ для здешнего разбора. Те же
// пять значков Simple Icons разобраны заранее питоновским скриптом
// `scripts/gen-store-brand-paths.py`, и тесты сверяют с ним рамку и число
// элементов. Замена оракула на собственное суждение была бы шагом назад.

// MARK: - отказы

/// Отказ разбора `d`.
///
/// Каждый случай назван отдельно и БРОСАЕТСЯ, а не проглатывается. Пустой `Path`
/// как признак отказа негоден: на экране он выглядит как «значок без формы», то
/// есть как оформительское решение, а не как поломка, и живёт так месяцами.
enum SVGPathError: LocalizedError, Equatable {
    /// Данных нет вовсе или в них только разделители.
    case emptyData
    /// Первая команда не `M`/`m` — у контура нет начальной точки.
    case contourDoesNotStartWithMove
    /// Буквы нет в наборе команд SVG. `at` — смещение буквы в байтах от начала `d`.
    case unknownCommand(Character, at: Int)
    /// Команде не хватило числа: данные оборваны или вместо числа мусор.
    case expectedNumber(at: Int)
    /// На месте флага дуги стоит не `0` и не `1`.
    case expectedArcFlag(at: Int)

    var errorDescription: String? {
        switch self {
        case .emptyData:
            return "данные контура пусты"
        case .contourDoesNotStartWithMove:
            return "контур начинается не с M/m — у него нет начальной точки"
        case .unknownCommand(let letter, let at):
            return "неизвестная команда «\(letter)» на смещении \(at)"
        case .expectedNumber(let at):
            return "ожидалось число на смещении \(at)"
        case .expectedArcFlag(let at):
            return "ожидался флаг дуги (0 или 1) на смещении \(at)"
        }
    }
}

// MARK: - разбор

/// Разбор данных атрибута `d` в `Path`.
enum SVGPathParser {

    /// Полный набор команд: M m L l H h V v C c S s Q q T t A a Z z.
    ///
    /// Бросает при неизвестной команде и при нехватке чисел — молча НЕ глотает.
    ///
    /// - Parameters:
    ///   - d: содержимое атрибута `d`.
    ///   - rect: куда вписать. Сторона берётся `min(width, height) / viewBox`,
    ///     сетка садится по ЦЕНТРУ — значок не растягивается.
    ///   - viewBox: сторона исходной сетки (у Simple Icons 24).
    static func path(fromPathData d: String, in rect: CGRect, viewBox: CGFloat = 24) throws -> Path {
        let scale = min(rect.width, rect.height) / viewBox
        let originX = rect.midX - viewBox / 2 * scale
        let originY = rect.midY - viewBox / 2 * scale
        // Вся арифметика разбора идёт в координатах viewBox, в экранные переводим
        // только при укладке в Path: так относительные команды и отражения опорных
        // точек считаются там же, где их задал автор значка.
        func screen(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: originX + x * scale, y: originY + y * scale)
        }
        func screen(_ point: CGPoint) -> CGPoint { screen(point.x, point.y) }

        var scanner = SVGNumberScanner(d)
        guard !scanner.isAtEnd() else { throw SVGPathError.emptyData }

        var path = Path()
        var current = CGPoint.zero          // текущая точка
        var subpathStart = CGPoint.zero     // начало подконтура — куда вернёт Z
        var lastCubicControl: CGPoint?      // вторая опорная предыдущей C/S — для S/s
        var lastQuadControl: CGPoint?       // опорная предыдущей Q/T — для T/t
        var lastCommand: UInt8?

        while !scanner.isAtEnd() {
            let command: UInt8
            if let letter = scanner.takeCommandLetter() {
                guard Self.commandLetters.contains(letter) else {
                    throw SVGPathError.unknownCommand(Character(UnicodeScalar(letter)),
                                                      at: scanner.offset - 1)
                }
                command = letter
            } else {
                // Пары чисел без повторения буквы: `L 1 2 3 4` — две линии.
                // Отдельно: лишние пары после `M` — это `L` (после `m` — `l`).
                // Классическая ловушка; без неё значок молча получает разрывы
                // вместо линий, и форма остаётся «почти похожей».
                guard var repeated = lastCommand else {
                    throw SVGPathError.contourDoesNotStartWithMove
                }
                if repeated == Self.upperM { repeated = Self.upperL }
                if repeated == Self.lowerM { repeated = Self.lowerL }
                command = repeated
            }

            if lastCommand == nil {
                guard command == Self.upperM || command == Self.lowerM else {
                    throw SVGPathError.contourDoesNotStartWithMove
                }
            }
            // Запоминаем ДЕЙСТВУЮЩУЮ команду: после `M 1 2 3 4` следующая неявная
            // пара обязана остаться `L`, а не снова стать `M`.
            lastCommand = command

            let relative = Self.isLower(command)
            let dx = relative ? current.x : 0
            let dy = relative ? current.y : 0

            switch Self.upper(command) {
            case Self.upperZ:
                path.closeSubpath()
                // Z возвращает в начало подконтура: команда без M продолжит оттуда.
                current = subpathStart
                lastCubicControl = nil
                lastQuadControl = nil

            case Self.upperM:
                let x = try scanner.number() + dx
                let y = try scanner.number() + dy
                path.move(to: screen(x, y))
                current = CGPoint(x: x, y: y)
                subpathStart = current
                lastCubicControl = nil
                lastQuadControl = nil

            case Self.upperL:
                let x = try scanner.number() + dx
                let y = try scanner.number() + dy
                path.addLine(to: screen(x, y))
                current = CGPoint(x: x, y: y)
                lastCubicControl = nil
                lastQuadControl = nil

            case Self.upperH:
                let x = try scanner.number() + dx
                path.addLine(to: screen(x, current.y))
                current.x = x
                lastCubicControl = nil
                lastQuadControl = nil

            case Self.upperV:
                let y = try scanner.number() + dy
                path.addLine(to: screen(current.x, y))
                current.y = y
                lastCubicControl = nil
                lastQuadControl = nil

            case Self.upperC:
                let c1x = try scanner.number() + dx
                let c1y = try scanner.number() + dy
                let c2x = try scanner.number() + dx
                let c2y = try scanner.number() + dy
                let endX = try scanner.number() + dx
                let endY = try scanner.number() + dy
                let c2 = CGPoint(x: c2x, y: c2y)
                let end = CGPoint(x: endX, y: endY)
                path.addCurve(to: screen(end), control1: screen(c1x, c1y), control2: screen(c2))
                lastCubicControl = c2
                lastQuadControl = nil
                current = end

            case Self.upperS:
                let c2x = try scanner.number() + dx
                let c2y = try scanner.number() + dy
                let endX = try scanner.number() + dx
                let endY = try scanner.number() + dy
                let c2 = CGPoint(x: c2x, y: c2y)
                let end = CGPoint(x: endX, y: endY)
                // Первая опорная — отражение предыдущей. Предыдущей C/S не было —
                // опорная совпадает с текущей точкой (постановка SVG, не догадка).
                let c1 = Self.reflect(lastCubicControl, about: current)
                path.addCurve(to: screen(end), control1: screen(c1), control2: screen(c2))
                lastCubicControl = c2
                lastQuadControl = nil
                current = end

            case Self.upperQ, Self.upperT:
                let quad: CGPoint
                let end: CGPoint
                if Self.upper(command) == Self.upperQ {
                    let qx = try scanner.number() + dx
                    let qy = try scanner.number() + dy
                    let endX = try scanner.number() + dx
                    let endY = try scanner.number() + dy
                    quad = CGPoint(x: qx, y: qy)
                    end = CGPoint(x: endX, y: endY)
                } else {
                    quad = Self.reflect(lastQuadControl, about: current)
                    let endX = try scanner.number() + dx
                    let endY = try scanner.number() + dy
                    end = CGPoint(x: endX, y: endY)
                }
                // Квадратичную поднимаем до кубической: перевод ТОЧНЫЙ (не
                // приближение), а оракул `StoreBrandPaths` сделан так же, значит
                // сверка по числу элементов остаётся осмысленной.
                let c1 = CGPoint(x: current.x + 2.0 / 3.0 * (quad.x - current.x),
                                 y: current.y + 2.0 / 3.0 * (quad.y - current.y))
                let c2 = CGPoint(x: end.x + 2.0 / 3.0 * (quad.x - end.x),
                                 y: end.y + 2.0 / 3.0 * (quad.y - end.y))
                path.addCurve(to: screen(end), control1: screen(c1), control2: screen(c2))
                lastQuadControl = quad
                lastCubicControl = nil
                current = end

            case Self.upperA:
                let rx = try scanner.number()
                let ry = try scanner.number()
                let rotation = try scanner.number()
                // ФЛАГИ ЧИТАЮТСЯ ПО ОДНОМУ ЗНАКУ. В `a1 1 0 01 5 5` подряд стоят
                // два флага `0` и `1` без разделителя; прочитанные как число, они
                // дадут 1 вместо двух флагов — и съедет КАЖДАЯ дуга набора сразу,
                // а форма останется «почти похожей» и на глаз не поймается.
                let largeArc = try scanner.arcFlag()
                let sweep = try scanner.arcFlag()
                let endX = try scanner.number() + dx
                let endY = try scanner.number() + dy
                let end = CGPoint(x: endX, y: endY)
                for piece in Self.arcPieces(from: current, rx: rx, ry: ry,
                                            rotationDegrees: rotation,
                                            largeArc: largeArc, sweep: sweep, to: end) {
                    switch piece {
                    case .line(let point):
                        path.addLine(to: screen(point))
                    case .curve(let c1, let c2, let point):
                        path.addCurve(to: screen(point), control1: screen(c1), control2: screen(c2))
                    }
                }
                current = end
                lastCubicControl = nil
                lastQuadControl = nil

            default:
                // Недостижимо: набор команд проверен выше. Оставлено, чтобы новая
                // буква в наборе без разбора дала отказ, а не тихий пропуск.
                throw SVGPathError.unknownCommand(Character(UnicodeScalar(command)),
                                                  at: scanner.offset - 1)
            }
        }
        return path
    }

    /// Контур в СОБСТВЕННОЙ сетке значка: `CGRect(0, 0, viewBox, viewBox)`.
    ///
    /// Это то, что кешируется: разбор один раз, а под конкретный `rect` контур
    /// доводится аффинным преобразованием. Преобразование опорных точек кривой
    /// Безье аффинной матрицей ТОЧНОЕ, поэтому результат совпадает с прямым
    /// разбором в тот же `rect` — это проверяется тестом, а не предполагается.
    static func unitPath(fromPathData d: String, viewBox: CGFloat = 24) throws -> Path {
        try path(fromPathData: d,
                 in: CGRect(x: 0, y: 0, width: viewBox, height: viewBox),
                 viewBox: viewBox)
    }

    /// Перевод из сетки значка в `rect`: та же сторона и та же центровка, что в
    /// `path(fromPathData:in:viewBox:)`.
    static func transform(for rect: CGRect, viewBox: CGFloat = 24) -> CGAffineTransform {
        let scale = min(rect.width, rect.height) / viewBox
        let originX = rect.midX - viewBox / 2 * scale
        let originY = rect.midY - viewBox / 2 * scale
        return CGAffineTransform(scaleX: scale, y: scale)
            .concatenating(CGAffineTransform(translationX: originX, y: originY))
    }

    // MARK: дуги

    /// Часть дуги после приведения к тому, что умеет `Path`.
    enum ArcPiece: Equatable {
        /// Вырожденная дуга (нулевой радиус) — по спецификации это прямая.
        case line(CGPoint)
        case curve(control1: CGPoint, control2: CGPoint, end: CGPoint)
    }

    /// Дуга SVG -> кубические кривые. Постановка по спецификации SVG, приложение F.6.2.
    ///
    /// Перенесено с рабочего образца `arc_to_cubics` из
    /// `scripts/gen-store-brand-paths.py` — того самого, которым разобран оракул
    /// `StoreBrandPaths`. Один и тот же алгоритм по обе стороны сверки; разойдись
    /// они, сверка рамок показала бы расхождение, а не согласие двух ошибок.
    static func arcPieces(from start: CGPoint,
                          rx rxRaw: CGFloat, ry ryRaw: CGFloat,
                          rotationDegrees: CGFloat,
                          largeArc: Bool, sweep: Bool,
                          to end: CGPoint) -> [ArcPiece] {
        // Порядок проверок как в образце: нулевой радиус — раньше взятия модуля.
        if rxRaw == 0 || ryRaw == 0 { return [.line(end)] }
        // Совпавшие концы: по спецификации дуга не рисуется вовсе.
        if start == end { return [] }

        let phi = rotationDegrees * .pi / 180
        let cosPhi = cos(phi), sinPhi = sin(phi)
        let dx = (start.x - end.x) / 2, dy = (start.y - end.y) / 2
        let x1p = cosPhi * dx + sinPhi * dy
        let y1p = -sinPhi * dx + cosPhi * dy

        var rx = abs(rxRaw), ry = abs(ryRaw)
        // Радиусы меньше нужного растягиваются до минимально достаточных (F.6.6).
        let lambda = x1p * x1p / (rx * rx) + y1p * y1p / (ry * ry)
        if lambda > 1 {
            let stretch = sqrt(lambda)
            rx *= stretch
            ry *= stretch
        }

        let numerator = rx * rx * ry * ry - rx * rx * y1p * y1p - ry * ry * x1p * x1p
        let denominator = rx * rx * y1p * y1p + ry * ry * x1p * x1p
        var coefficient = denominator == 0 ? 0 : sqrt(max(0, numerator / denominator))
        if largeArc == sweep { coefficient = -coefficient }
        let cxp = coefficient * rx * y1p / ry
        let cyp = -coefficient * ry * x1p / rx
        let cx = cosPhi * cxp - sinPhi * cyp + (start.x + end.x) / 2
        let cy = sinPhi * cxp + cosPhi * cyp + (start.y + end.y) / 2

        func angle(_ ux: CGFloat, _ uy: CGFloat, _ vx: CGFloat, _ vy: CGFloat) -> CGFloat {
            atan2(ux * vy - uy * vx, ux * vx + uy * vy)
        }
        let ux = (x1p - cxp) / rx, uy = (y1p - cyp) / ry
        let vx = (-x1p - cxp) / rx, vy = (-y1p - cyp) / ry
        let theta1 = angle(1, 0, ux, uy)
        var sweepAngle = angle(ux, uy, vx, vy)
        if !sweep && sweepAngle > 0 {
            sweepAngle -= 2 * .pi
        } else if sweep && sweepAngle < 0 {
            sweepAngle += 2 * .pi
        }

        // Квадрант на кривую: больше — и приближение Безье заметно врёт.
        // Вычет 1e-9 не косметика: ровно 90° иначе даёт из-за округления две
        // кривые вместо одной, и число элементов разошлось бы с оракулом.
        let count = max(1, Int(ceil(abs(sweepAngle) / (.pi / 2) - 1e-9)))
        let step = sweepAngle / CGFloat(count)
        let k = 4.0 / 3.0 * tan(step / 4)

        func onEllipse(_ u: CGFloat, _ v: CGFloat) -> CGPoint {
            let x = rx * u, y = ry * v
            return CGPoint(x: cosPhi * x - sinPhi * y + cx,
                           y: sinPhi * x + cosPhi * y + cy)
        }

        var pieces: [ArcPiece] = []
        pieces.reserveCapacity(count)
        for i in 0..<count {
            let a1 = theta1 + CGFloat(i) * step
            let a2 = a1 + step
            let c1 = onEllipse(cos(a1) - k * sin(a1), sin(a1) + k * cos(a1))
            let c2 = onEllipse(cos(a2) + k * sin(a2), sin(a2) - k * cos(a2))
            let point = onEllipse(cos(a2), sin(a2))
            pieces.append(.curve(control1: c1, control2: c2, end: point))
        }
        return pieces
    }

    // MARK: внутреннее

    /// Отражение опорной точки относительно текущей. Нет предыдущей опорной —
    /// опорная совпадает с текущей точкой (постановка SVG для S/T без пары).
    private static func reflect(_ control: CGPoint?, about point: CGPoint) -> CGPoint {
        guard let control else { return point }
        return CGPoint(x: 2 * point.x - control.x, y: 2 * point.y - control.y)
    }

    private static let commandLetters: Set<UInt8> = Set("MmLlHhVvCcSsQqTtAaZz".utf8)
    fileprivate static let upperM = UInt8(ascii: "M"), lowerM = UInt8(ascii: "m")
    fileprivate static let upperL = UInt8(ascii: "L"), lowerL = UInt8(ascii: "l")
    fileprivate static let upperH = UInt8(ascii: "H")
    fileprivate static let upperV = UInt8(ascii: "V")
    fileprivate static let upperC = UInt8(ascii: "C")
    fileprivate static let upperS = UInt8(ascii: "S")
    fileprivate static let upperQ = UInt8(ascii: "Q")
    fileprivate static let upperT = UInt8(ascii: "T")
    fileprivate static let upperA = UInt8(ascii: "A")
    fileprivate static let upperZ = UInt8(ascii: "Z")

    private static func isLower(_ c: UInt8) -> Bool { c >= 0x61 && c <= 0x7A }
    private static func upper(_ c: UInt8) -> UInt8 { isLower(c) ? c - 0x20 : c }
}

// MARK: - чтение чисел

/// Разбор потока чисел, флагов и букв-команд в `d`.
///
/// Работаем по БАЙТАМ: данные `d` — ASCII, а смещение в байтах прямо годится как
/// место отказа в сообщении. Своё чтение чисел, а не `Double(String)` по
/// разделителям, нужно затем, что в настоящих файлах числа пишутся слитно:
/// `.5.5` — это ДВА числа, и точка второго обрывает первое.
struct SVGNumberScanner {
    private let bytes: [UInt8]
    private var index: Int = 0

    init(_ text: String) { bytes = Array(text.utf8) }

    /// Текущее смещение в байтах — оно и попадает в текст отказа.
    var offset: Int { index }

    /// Пробелы, табуляции, переводы строк и запятые между числами равноправны.
    private mutating func skipSeparators() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x09, 0x0A, 0x0D, 0x0B, 0x0C, 0x2C:
                index += 1
            default:
                return
            }
        }
    }

    mutating func isAtEnd() -> Bool {
        skipSeparators()
        return index >= bytes.count
    }

    /// Буква на месте команды, либо nil — значит там число и команда повторяется.
    mutating func takeCommandLetter() -> UInt8? {
        skipSeparators()
        guard index < bytes.count else { return nil }
        let c = bytes[index]
        let isLetter = (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A)
        guard isLetter else { return nil }
        index += 1
        return c
    }

    /// Одно число. Берёт `-.5`, `1e-3`, `+1`, `1.`, а также `.5.5` — вторую точку
    /// НЕ съедает, отдавая два числа подряд.
    mutating func number() throws -> Double {
        skipSeparators()
        let start = index
        guard index < bytes.count else { throw SVGPathError.expectedNumber(at: start) }

        var end = index
        if bytes[end] == 0x2B || bytes[end] == 0x2D { end += 1 }   // + или -
        var digits = 0
        while end < bytes.count, Self.isDigit(bytes[end]) { end += 1; digits += 1 }
        if end < bytes.count, bytes[end] == 0x2E {                 // точка — ровно одна
            end += 1
            while end < bytes.count, Self.isDigit(bytes[end]) { end += 1; digits += 1 }
        }
        guard digits > 0 else { throw SVGPathError.expectedNumber(at: start) }

        // Порядок берём ТОЛЬКО если за e/E действительно стоят цифры: иначе `e`
        // осталась бы съеденной, и следующая команда прочиталась бы как число.
        if end < bytes.count, bytes[end] == 0x65 || bytes[end] == 0x45 {
            var probe = end + 1
            if probe < bytes.count, bytes[probe] == 0x2B || bytes[probe] == 0x2D { probe += 1 }
            var exponentDigits = 0
            while probe < bytes.count, Self.isDigit(bytes[probe]) { probe += 1; exponentDigits += 1 }
            if exponentDigits > 0 { end = probe }
        }

        let text = String(decoding: bytes[start..<end], as: UTF8.self)
        guard let value = Double(text) else { throw SVGPathError.expectedNumber(at: start) }
        index = end
        return value
    }

    /// Флаг дуги — РОВНО ОДИН знак `0` или `1`; см. пояснение на разборе `A`.
    mutating func arcFlag() throws -> Bool {
        skipSeparators()
        guard index < bytes.count else { throw SVGPathError.expectedArcFlag(at: index) }
        let c = bytes[index]
        guard c == 0x30 || c == 0x31 else { throw SVGPathError.expectedArcFlag(at: index) }
        index += 1
        return c == 0x31
    }

    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }
}

// MARK: - кеш разобранных контуров

/// Разобранные контуры в сетке значка. Ключ — сами данные `d`.
///
/// Замок, а не `@MainActor`: `Shape.path(in:)` вызывается вне изоляции акторов и
/// на каждом проходе раскладки, то есть десятки раз за прокрутку витрины. Разбор
/// дуги — тригонометрия на каждую из 280 дуг набора, повторять её незачем.
final class SVGUnitPathCache {
    static let shared = SVGUnitPathCache()

    private let lock = NSLock()
    private var store: [String: Path] = [:]
    private var parses = 0

    /// Сколько РАЗБОРОВ действительно случилось. Это прибор для проверки: без
    /// него «кеш работает» осталось бы впечатлением, а не числом.
    var parseCount: Int {
        lock.lock(); defer { lock.unlock() }
        return parses
    }

    func reset() {
        lock.lock(); defer { lock.unlock() }
        store.removeAll()
        parses = 0
    }

    func unitPath(for d: String, viewBox: CGFloat) throws -> Path {
        let key = "\(viewBox)|\(d)"
        lock.lock()
        if let hit = store[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()
        // Разбор вне замка: он чистый, а держать замок на тригонометрии незачем.
        // Гонка здесь безобидна — двое разберут одно и то же и запишут равное.
        let parsed = try SVGPathParser.unitPath(fromPathData: d, viewBox: viewBox)
        lock.lock()
        store[key] = parsed
        parses += 1
        lock.unlock()
        return parsed
    }
}

/// Печать отказов в stderr, по одному разу на сообщение.
///
/// `Shape.path(in:)` зовут на каждом проходе раскладки: без гашения повторов один
/// битый значок залил бы журнал и спрятал остальное. И печать именно в stderr —
/// в проекте это единственный канал, который доходит до журналов прогона.
enum SVGIconDiagnostics {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var seen: Set<String> = []

    static func reportOnce(_ message: String) {
        lock.lock()
        let isNew = seen.insert(message).inserted
        lock.unlock()
        guard isNew else { return }
        FileHandle.standardError.write(Data(("macr-svg: " + message + "\n").utf8))
    }
}

// MARK: - фигура

/// Разобранный документ SVG: единственный контур и сторона его сетки.
struct SVGIcon: Equatable {
    let pathData: String
    let viewBox: CGFloat
}

/// Готовая фигура: читает SVG из бандла и рисует.
///
/// Заполнение — правилом non-zero (умолчание SwiftUI). Simple Icons на него и
/// рассчитаны: внутренние вырезы в знаках (например в 7-Zip) заданы обходом в
/// обратную сторону, а не even-odd.
struct SVGIconShape: Shape {
    let pathData: String
    /// Сторона исходной сетки. У Simple Icons всегда 24.
    var viewBox: CGFloat = 24

    func path(in rect: CGRect) -> Path {
        do {
            let unit = try SVGUnitPathCache.shared.unitPath(for: pathData, viewBox: viewBox)
            return unit.applying(SVGPathParser.transform(for: rect, viewBox: viewBox))
        } catch {
            // Отказ ВИДЕН, а не проглочен: пустая фигура на экране неотличима от
            // оформительского решения, и так дефект живёт месяцами.
            SVGIconDiagnostics.reportOnce("контур не разобран: \(error.localizedDescription)")
            return Path()
        }
    }
}

// MARK: - загрузка из ресурсов

/// Загрузка и кеш разобранных контуров: один и тот же значок разбирается ОДИН раз.
@MainActor
enum SVGIconLoader {

    /// Подкаталог ресурсов, куда значки кладёт `scripts/gen-program-icons.py`.
    static let directory = "program-icons"

    /// Читает `Resources/program-icons/<slug>.svg`, достаёт единственный `d`.
    ///
    /// nil — если файла нет; ошибка разбора НЕ глотается, а печатается в stderr.
    static func pathData(slug: String) -> String? {
        icon(slug: slug)?.pathData
    }

    /// Тот же поиск, но с сеткой: масштаб без неё был бы угадан, а не взят.
    static func icon(slug: String, in bundle: Bundle = .appResources) -> SVGIcon? {
        if let cached = cache[slug] { return cached }
        let found = load(slug: slug, from: bundle)
        cache[slug] = found          // промах кешируем тоже: набор в бандле не меняется
        return found
    }

    /// Контур значка под `rect`. Разбор кеширован, на вызов остаётся только
    /// аффинное преобразование — это и есть «разбирается ОДИН раз».
    static func path(slug: String, in rect: CGRect) -> Path? {
        guard let icon = icon(slug: slug) else { return nil }
        do {
            let unit = try SVGUnitPathCache.shared.unitPath(for: icon.pathData,
                                                            viewBox: icon.viewBox)
            return unit.applying(SVGPathParser.transform(for: rect, viewBox: icon.viewBox))
        } catch {
            SVGIconDiagnostics.reportOnce("значок \(slug): \(error.localizedDescription)")
            return nil
        }
    }

    /// Готовая фигура значка, если он есть в ресурсах.
    static func shape(slug: String) -> SVGIconShape? {
        guard let icon = icon(slug: slug) else { return nil }
        return SVGIconShape(pathData: icon.pathData, viewBox: icon.viewBox)
    }

    /// Сброс кеша чтения. Нужен проверкам, чтобы мерить с чистого места.
    static func resetCache() { cache.removeAll() }

    private static var cache: [String: SVGIcon?] = [:]

    /// ★ ИЗМЕРЕНО, а не предположено: `resources: [.process("Resources")]`
    /// РАСПЛЮЩИВАЕТ дерево — все 54 файла лежат в КОРНЕ `…_MacRunnerControlCenter.bundle`,
    /// подкаталога `program-icons/` там нет вовсе (проверено `ls` по собранному
    /// бандлу; `.app` копирует этот же бандл целиком, так что в поставке то же).
    /// Поиск ТОЛЬКО по `subdirectory:` вернул бы nil на КАЖДОМ значке, и витрина
    /// молча осталась бы с монограммами — отказа при этом не видно нигде.
    /// Поэтому сначала плоско, потом в подкаталоге: второй случай наступит, если
    /// правило сборки когда-нибудь сменят на `.copy`, сохраняющее дерево.
    private static func load(slug: String, from bundle: Bundle) -> SVGIcon? {
        let url = bundle.url(forResource: slug, withExtension: "svg")
            ?? bundle.url(forResource: slug, withExtension: "svg", subdirectory: Self.directory)
        guard let url else {
            return nil   // значка просто нет — вызывающий сам решит, чем заменить
        }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            SVGIconDiagnostics.reportOnce("значок \(slug): файл есть, а прочитать не вышло")
            return nil
        }
        return SVGDocument.icon(fromSVG: text, name: "\(Self.directory)/\(slug).svg")
    }
}

/// Разбор самого документа SVG. Отдельно от чтения файла и от изоляции актора,
/// чтобы проверять его на тех же файлах, что лежат в дереве, без бандла.
enum SVGDocument {

    /// nil при любом отклонении от формы Simple Icons, и каждое названо в stderr:
    /// молча нарисованный не тем масштабом значок хуже отсутствующего.
    static func icon(fromSVG text: String, name: String = "<строка>") -> SVGIcon? {
        let contours = Self.captures(of: #"\sd="([^"]*)""#, in: text)
        guard contours.count == 1 else {
            SVGIconDiagnostics.reportOnce("\(name): контуров \(contours.count), ждали один")
            return nil
        }
        // `transform` здесь НЕ применяется. Молча его проигнорировать — значит
        // нарисовать значок сдвинутым или повёрнутым и не узнать об этом: форма
        // остаётся «почти похожей». Измерено: ни у одного из 54 файлов набора
        // этого атрибута нет, так что отказ никого не задевает, а мину снимает.
        if text.contains("transform=") {
            SVGIconDiagnostics.reportOnce("\(name): есть transform — он здесь не применяется")
            return nil
        }
        guard let box = Self.captures(of: #"\sviewBox="([^"]*)""#, in: text).first else {
            SVGIconDiagnostics.reportOnce("\(name): нет viewBox — масштаб был бы угадан")
            return nil
        }
        let numbers = box.split(whereSeparator: { $0 == " " || $0 == "," }).compactMap { Double($0) }
        guard numbers.count == 4 else {
            SVGIconDiagnostics.reportOnce("\(name): viewBox «\(box)» не из четырёх чисел")
            return nil
        }
        // Начало не в нуле или сетка не квадратная — здешний масштаб (одна сторона,
        // центровка) такое не выражает. Отказываем, а не рисуем приблизительно.
        guard numbers[0] == 0, numbers[1] == 0, numbers[2] == numbers[3], numbers[2] > 0 else {
            SVGIconDiagnostics.reportOnce("\(name): viewBox «\(box)» не квадрат из нуля")
            return nil
        }
        return SVGIcon(pathData: contours[0], viewBox: CGFloat(numbers[2]))
    }

    private static func captures(of pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return regex.matches(in: text, range: range).compactMap { match in
            guard match.numberOfRanges > 1,
                  let captured = Range(match.range(at: 1), in: text) else { return nil }
            return String(text[captured])
        }
    }
}
