import CoreGraphics
import Foundation
import SwiftUI
import Testing
@testable import MacRunnerControlCenter

/// Проверка разбора SVG в `Path`.
///
/// Правило проекта: прибор, который не доказан, считается врущим. Поэтому главная
/// проверка здесь — не «разобралось без отказа» (это выполнил бы и разборщик,
/// рисующий вместо дуг прямые), а СВЕРКА С ОРАКУЛОМ.
///
/// Оракул есть и он независимый: `StoreBrandPaths` — те же значки Simple Icons,
/// разобранные ЗАРАНЕЕ питоновским скриптом `scripts/gen-store-brand-paths.py`.
/// Сверяем рамку и число элементов. Дуги — самое опасное место набора (они есть у
/// 39 контуров из 54), и неверная дуга даёт «почти похожую» форму, которая на глаз
/// не ловится: рамка её ловит числом.
struct SVGPathTests {

    // MARK: пути к файлам

    /// Корень пакета. Считаем от самого файла теста: значки-образцы лежат в
    /// `scripts/brand-icons/`, то есть ВНЕ ресурсов, и через бандл не достаются.
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // MacRunnerControlCenterTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // macr-control-center

    static var brandIconsDir: URL { packageRoot.appendingPathComponent("scripts/brand-icons") }
    static var programIconsDir: URL {
        packageRoot.appendingPathComponent("Sources/MacRunnerControlCenter/Resources/program-icons")
    }

    /// Значок оракула: имя файла, функция готового контура и наше имя для таблицы.
    static let oracleIcons: [(name: String, file: String, oracle: (CGRect) -> Path)] = [
        ("steam", "steam.svg", StoreBrandPaths.steam(in:)),
        ("epic", "epicgames.svg", StoreBrandPaths.epic(in:)),
        ("gog", "gogdotcom.svg", StoreBrandPaths.gog(in:)),
        ("itch", "itchdotio.svg", StoreBrandPaths.itch(in:)),
        ("battlenet", "battledotnet.svg", StoreBrandPaths.battlenet(in:))
    ]

    static func pathData(at url: URL) throws -> SVGIcon {
        let text = try String(contentsOf: url, encoding: .utf8)
        let icon = try #require(SVGDocument.icon(fromSVG: text),
                                "файл \(url.lastPathComponent) не разобрался как документ SVG")
        return icon
    }

    static func elementCount(_ path: Path) -> Int {
        var count = 0
        path.forEach { _ in count += 1 }
        return count
    }

    /// ВСЕ точки контура — концы и опорные. Прибор точный, в отличие от
    /// `boundingRect`: тот считается приближённо (измерено: на координатах порядка
    /// 50 он врёт до 1e-5, что есть точность float32, а не наша ошибка). Там, где
    /// нужно сравнить два способа получить ОДИН И ТОТ ЖЕ путь, рамка негодна.
    static func points(_ path: Path) -> [CGPoint] {
        var out: [CGPoint] = []
        path.forEach { element in
            switch element {
            case .move(let to), .line(let to):
                out.append(to)
            case .quadCurve(let to, let control):
                out.append(contentsOf: [control, to])
            case .curve(let to, let control1, let control2):
                out.append(contentsOf: [control1, control2, to])
            case .closeSubpath:
                break
            }
        }
        return out
    }

    /// Наибольшее покоординатное расхождение двух путей, или nil если у них разный
    /// состав — тогда сравнивать числа уже незачем.
    static func maxPointDrift(_ a: Path, _ b: Path) -> CGFloat? {
        let pa = points(a), pb = points(b)
        guard pa.count == pb.count else { return nil }
        var worst: CGFloat = 0
        for (x, y) in zip(pa, pb) {
            worst = max(worst, max(abs(x.x - y.x), abs(x.y - y.y)))
        }
        return worst
    }

    // MARK: - A. сверка с готовым образцом

    /// Самое сильное доказательство: рамка и число элементов против `StoreBrandPaths`.
    ///
    /// Сверяем в ДВУХ рамках. Квадратная 24×24 проверяет сам разбор. Не квадратная
    /// 40×64 проверяет ещё и правило масштаба с центровкой: растяни разбор значок
    /// по длинной стороне — рамка разойдётся с оракулом, который растягивать не
    /// умеет по построению.
    @Test func boundingBoxMatchesPregeneratedOracle() throws {
        let rects = [CGRect(x: 0, y: 0, width: 24, height: 24),
                     CGRect(x: 7, y: 3, width: 40, height: 64)]
        var report = ["", "A. сверка с оракулом StoreBrandPaths (питоновский разбор тех же SVG)"]
        var failures: [String] = []

        for rect in rects {
            report.append("   рамка вывода \(Self.fmt(rect.width))×\(Self.fmt(rect.height))"
                + " при начале (\(Self.fmt(rect.minX)), \(Self.fmt(rect.minY)))")
            report.append("   значок      элем-тов  рамка своя                    "
                + "рамка оракула                 рамка Δ   все точки Δ")
            for icon in Self.oracleIcons {
                let parsed = try SVGPathParser.path(
                    fromPathData: try Self.pathData(at: Self.brandIconsDir
                        .appendingPathComponent(icon.file)).pathData,
                    in: rect)
                let expected = icon.oracle(rect)
                let mine = parsed.boundingRect, theirs = expected.boundingRect
                let drift = max(abs(mine.minX - theirs.minX), abs(mine.minY - theirs.minY),
                                abs(mine.maxX - theirs.maxX), abs(mine.maxY - theirs.maxY))
                let mineCount = Self.elementCount(parsed)
                let theirsCount = Self.elementCount(expected)
                // Рамка видит только четыре крайних числа: дуга, съехавшая ВНУТРЬ
                // знака, её не пошевелит. Поэтому сверяем ещё и КАЖДУЮ опорную
                // точку каждой кривой — состав элементов совпал, значит можно.
                let pointDrift = Self.maxPointDrift(parsed, expected)

                report.append("   \(icon.name.padding(toLength: 12, withPad: " ", startingAt: 0))"
                    + "\(mineCount)/\(theirsCount)".padding(toLength: 10, withPad: " ", startingAt: 0)
                    + Self.box(mine).padding(toLength: 30, withPad: " ", startingAt: 0)
                    + Self.box(theirs).padding(toLength: 30, withPad: " ", startingAt: 0)
                    + String(format: "%.5f   ", Double(drift))
                    + (pointDrift.map { String(format: "%.5f", Double($0)) } ?? "состав РАЗНЫЙ"))

                // Допуск 0.01 задан заданием. Он с большим запасом: оракул печатает
                // координаты с тремя знаками после запятой, то есть сам округляет до
                // 0.0005 — всё, что заметно больше, это уже РАЗНАЯ ГЕОМЕТРИЯ.
                if drift > 0.01 { failures.append("\(icon.name): рамка разошлась на \(drift)") }
                if mineCount != theirsCount {
                    failures.append("\(icon.name): элементов \(mineCount), у оракула \(theirsCount)")
                }
                guard let pointDrift else {
                    failures.append("\(icon.name): состав элементов не совпал с оракулом")
                    continue
                }
                // Тот же допуск 0.01 на каждую точку. Здесь он и ловит съехавшую
                // дугу: у оракула округление до 0.0005, помноженное на масштаб рамки.
                if pointDrift > 0.01 {
                    failures.append("\(icon.name): точки разошлись на \(pointDrift)")
                }
            }
        }
        print(report.joined(separator: "\n"))
        #expect(failures.isEmpty, "расхождение с оракулом:\n\(failures.joined(separator: "\n"))")
    }

    // MARK: - B. весь настоящий набор

    /// Все 54 значка витрины обязаны разобраться. Отказ ни у одного не допускается:
    /// значок, который «просто не нарисовался», на экране неотличим от замысла.
    @Test func everyProgramIconParses() throws {
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.programIconsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "svg" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        #expect(files.count == 54, "ожидали 54 значка, нашли \(files.count)")

        let grid = CGRect(x: 0, y: 0, width: 24, height: 24)
        var broken: [String] = []
        var outsideGrid: [String] = []
        var totalElements = 0
        var withArcs = 0
        var widest: (String, Int) = ("", 0)

        for file in files {
            let slug = file.deletingPathExtension().lastPathComponent
            do {
                let icon = try Self.pathData(at: file)
                #expect(icon.viewBox == 24, "\(slug): сетка \(icon.viewBox), а не 24")
                if icon.pathData.contains(where: { $0 == "A" || $0 == "a" }) { withArcs += 1 }

                let path = try SVGPathParser.path(fromPathData: icon.pathData, in: grid,
                                                  viewBox: icon.viewBox)
                let count = Self.elementCount(path)
                totalElements += count
                if count > widest.1 { widest = (slug, count) }
                #expect(count > 0, "\(slug): контур разобрался в ПУСТОЙ Path")

                // Допуск 0.5 по заданию: знаки Simple Icons рисуются вплотную к
                // сетке, и заметный вылет означает съехавший разбор, а не замысел.
                let box = path.boundingRect
                if box.minX < -0.5 || box.minY < -0.5 || box.maxX > 24.5 || box.maxY > 24.5 {
                    outsideGrid.append("\(slug) \(Self.box(box))")
                }
            } catch {
                broken.append("\(slug): \(error.localizedDescription)")
            }
        }

        print("""

        B. весь набор витрины
           файлов ............... \(files.count)
           разобралось .......... \(files.count - broken.count) из \(files.count)
           с дугами ............. \(withArcs)
           элементов всего ...... \(totalElements)
           самый крупный ........ \(widest.0), \(widest.1) элементов
           вылезло за 24×24 ..... \(outsideGrid.count) (допуск 0.5)
        """)
        if !outsideGrid.isEmpty { print("   вылеты: " + outsideGrid.joined(separator: ", ")) }
        if !broken.isEmpty { print("   отказы: " + broken.joined(separator: "\n           ")) }

        #expect(broken.isEmpty, "не разобрались:\n\(broken.joined(separator: "\n"))")
        #expect(outsideGrid.isEmpty, "вылезли за сетку:\n\(outsideGrid.joined(separator: "\n"))")
    }

    // MARK: - C. отрицательный контроль

    /// Ни один негодный вход не смеет дать пустой `Path` МОЛЧА: разбор обязан
    /// бросить, и именно тот отказ, который случился.
    @Test func badInputThrowsNamedError() {
        let grid = CGRect(x: 0, y: 0, width: 24, height: 24)
        let cases: [(d: String, expected: SVGPathError, why: String)] = [
            ("", .emptyData, "пустые данные"),
            ("   \n  ", .emptyData, "только разделители — те же пустые данные"),
            ("L 1 2", .contourDoesNotStartWithMove, "контур начинается не с M"),
            ("1 2 3 4", .contourDoesNotStartWithMove, "команды нет вовсе, сразу числа"),
            ("M 1 2 X 3", .unknownCommand("X", at: 6), "буквы X в наборе команд нет"),
            ("M 1", .expectedNumber(at: 3), "команде M не хватило второго числа"),
            ("M0 0 A 5 5 0 9 1 10 10", .expectedArcFlag(at: 13), "9 не флаг дуги"),
            ("M0 0 A 5 5 0", .expectedArcFlag(at: 12), "дуга оборвана на месте флага")
        ]
        var rows = ["", "C. отрицательный контроль"]
        for c in cases {
            var got: SVGPathError?
            var produced: Path?
            do {
                produced = try SVGPathParser.path(fromPathData: c.d, in: grid)
            } catch let error as SVGPathError {
                got = error
            } catch {
                got = nil
            }
            rows.append("   «\(c.d.replacingOccurrences(of: "\n", with: "\\n"))»"
                .padding(toLength: 30, withPad: " ", startingAt: 0)
                + " -> " + (got.map { "\($0)" } ?? "НИЧЕГО НЕ БРОСИЛ")
                + "   (\(c.why))")
            #expect(produced == nil, "«\(c.d)» вернул Path вместо отказа — это и есть молчаливая пустота")
            #expect(got == c.expected, "«\(c.d)»: ждали \(c.expected), получили \(String(describing: got))")
        }
        print(rows.joined(separator: "\n"))
    }

    // MARK: - требования к разбору

    /// Слитные флаги дуги. Прибор прямого действия: прочитай разборщик `01` как
    /// число, и слитная запись разошлась бы с раздельной (или отказала) — а на
    /// глаз это «почти похожая» форма. Такая запись есть в 5 файлах набора.
    @Test func arcFlagsWrittenWithoutSeparator() throws {
        let grid = CGRect(x: 0, y: 0, width: 24, height: 24)
        let glued = try SVGPathParser.path(fromPathData: "M5 5a1 1 0 015 5", in: grid)
        let spaced = try SVGPathParser.path(fromPathData: "M5 5a1 1 0 0 1 5 5", in: grid)
        #expect(glued.description == spaced.description, "слитные флаги разобраны иначе, чем раздельные")
        #expect(Self.elementCount(glued) > 1, "дуга не дала ни одной кривой")

        // И разные флаги обязаны давать РАЗНЫЕ дуги: иначе проверка выше прошла бы
        // и у разборщика, который оба флага просто игнорирует.
        let otherSweep = try SVGPathParser.path(fromPathData: "M5 5a1 1 0 005 5", in: grid)
        #expect(glued.description != otherSweep.description, "флаг направления ни на что не влияет")
    }

    /// Лишние пары после команды повторяют её, а после `M` превращаются в `L`.
    @Test func repeatedPairsAndImpliedLineAfterMove() throws {
        let grid = CGRect(x: 0, y: 0, width: 24, height: 24)
        func p(_ d: String) throws -> String {
            try SVGPathParser.path(fromPathData: d, in: grid).description
        }
        #expect(try p("M 1 2 3 4") == p("M 1 2 L 3 4"), "лишняя пара после M — это L")
        #expect(try p("m 1 2 3 4") == p("M 1 2 L 4 6"), "лишняя пара после m — это l")
        #expect(try p("M 0 0 L 1 2 3 4") == p("M 0 0 L 1 2 L 3 4"),
                "повторная пара после L — вторая линия")
        #expect(try p("M 1 2 3 4 5 6") == p("M 1 2 L 3 4 L 5 6"), "третья пара тоже L, а не M")
        // Повторение работает не только у L: шесть чисел после C — вторая кривая.
        #expect(try p("M0 0C1 0 2 1 3 1 4 1 5 2 6 2") == p("M0 0C1 0 2 1 3 1C4 1 5 2 6 2"),
                "повторная шестёрка после C — вторая кривая")
    }

    /// `S` и `T` отражают предыдущую опорную; без подходящей предыдущей команды
    /// опорная совпадает с текущей точкой.
    @Test func smoothCurvesReflectPreviousControl() throws {
        let grid = CGRect(x: 0, y: 0, width: 24, height: 24)
        func p(_ d: String) throws -> String {
            try SVGPathParser.path(fromPathData: d, in: grid).description
        }
        // Отражение (2,1) относительно (3,1) даёт (4,1).
        #expect(try p("M0 0C1 0 2 1 3 1S5 2 6 2") == p("M0 0C1 0 2 1 3 1C4 1 5 2 6 2"),
                "S не отразил опорную предыдущей C")
        // Предыдущей C не было — опорная равна текущей точке.
        #expect(try p("M0 0S1 1 2 2") == p("M0 0C0 0 1 1 2 2"),
                "S без предыдущей C взял опорную не из текущей точки")
        // Отражение (1,0) относительно (2,0) даёт (3,0).
        #expect(try p("M0 0Q1 0 2 0T4 0") == p("M0 0Q1 0 2 0Q3 0 4 0"),
                "T не отразил опорную предыдущей Q")
        #expect(try p("M0 0T2 2") == p("M0 0Q0 0 2 2"),
                "T без предыдущей Q взял опорную не из текущей точки")
        // После C опорная для T не годится, и наоборот: они хранятся отдельно.
        #expect(try p("M0 0C1 0 2 1 3 1T5 1") == p("M0 0C1 0 2 1 3 1Q3 1 5 1"),
                "T взял опорную от C — это разные опорные")
    }

    /// `Z` возвращает в начало подконтура, и следующая команда без `M` идёт оттуда.
    ///
    /// Взято относительной линией ВЛЕВО нарочно: уйди текущая точка в конец
    /// подконтура вместо его начала, рамка осталась бы прежней при абсолютной
    /// команде и при линии вправо — то есть проверка прошла бы, ничего не проверив.
    @Test func closeSubpathReturnsToItsStart() throws {
        let grid = CGRect(x: 0, y: 0, width: 24, height: 24)
        let path = try SVGPathParser.path(fromPathData: "M 10 10 L 20 10 Z l -5 0", in: grid)
        let box = path.boundingRect
        #expect(abs(box.minX - 5) < 1e-9,
                "после Z текущая точка не вернулась в начало подконтура: рамка \(Self.box(box))")
        #expect(abs(box.maxX - 20) < 1e-9, "рамка по X испорчена: \(Self.box(box))")
    }

    /// Числа в настоящих файлах пишутся слитно.
    @Test func numbersWrittenTheWayRealFilesWriteThem() throws {
        let grid = CGRect(x: 0, y: 0, width: 24, height: 24)
        func p(_ d: String) throws -> String {
            try SVGPathParser.path(fromPathData: d, in: grid).description
        }
        #expect(try p("M.5.5L-.5-.5") == p("M 0.5 0.5 L -0.5 -0.5"), "«.5.5» это два числа")
        #expect(try p("M1e1 1e-3") == p("M 10 0.001"), "порядок (1e-3) не прочитан")
        #expect(try p("M1,2L3,4") == p("M 1 2 L 3 4"), "запятая — такой же разделитель")
        #expect(try p("M+1+2") == p("M 1 2"), "явный плюс не прочитан")
        #expect(try p("M 5 5 h 3 v 2") == p("M 5 5 L 8 5 L 8 7"), "h/v относительные съехали")
        #expect(try p("M 5 5 H 3 V 2") == p("M 5 5 L 3 5 L 3 2"), "H/V абсолютные съехали")
    }

    /// Вырожденные дуги — по спецификации, а не «как получилось».
    @Test func degenerateArcsFollowTheSpec() {
        let zeroRadius = SVGPathParser.arcPieces(from: .zero, rx: 0, ry: 5, rotationDegrees: 0,
                                                 largeArc: false, sweep: true,
                                                 to: CGPoint(x: 10, y: 10))
        #expect(zeroRadius == [.line(CGPoint(x: 10, y: 10))], "нулевой радиус обязан дать прямую")

        let samePoint = SVGPathParser.arcPieces(from: CGPoint(x: 3, y: 4), rx: 5, ry: 5,
                                                rotationDegrees: 0, largeArc: true, sweep: true,
                                                to: CGPoint(x: 3, y: 4))
        #expect(samePoint.isEmpty, "дуга с совпавшими концами не рисуется вовсе")

        // Полукруг радиусом 1: ровно 90° на кривую, то есть две кривые, не три.
        let half = SVGPathParser.arcPieces(from: CGPoint(x: 0, y: 0), rx: 1, ry: 1,
                                           rotationDegrees: 0, largeArc: false, sweep: true,
                                           to: CGPoint(x: 2, y: 0))
        #expect(half.count == 2, "полукруг разбит на \(half.count) кривых вместо 2")
    }

    // MARK: - масштаб, центровка и кеш

    /// Значок не растягивается и садится по центру.
    @Test func iconIsCenteredAndNotStretched() throws {
        let icon = try Self.pathData(at: Self.brandIconsDir.appendingPathComponent("steam.svg"))
        // Широкая рамка: сторона по МЕНЬШЕЙ стороне, значок по центру по горизонтали.
        let wide = CGRect(x: 0, y: 0, width: 100, height: 40)
        let path = try SVGPathParser.path(fromPathData: icon.pathData, in: wide)
        let box = path.boundingRect
        let unit = try SVGPathParser.unitPath(fromPathData: icon.pathData).boundingRect
        let scale: CGFloat = 40.0 / 24.0

        // Допуск 1e-3, и он взят не на глаз: `boundingRect` считается приближённо и
        // на координатах порядка 50 расходится до 1e-5 (измерено). Силы проверка не
        // теряет — растянутый значок дал бы ширину 100/24 вместо 40/24, то есть
        // разницу в ДЕСЯТКИ единиц, а не в тысячные.
        #expect(abs(box.width - unit.width * scale) < 1e-3,
                "ширина не по меньшей стороне — значок растянут: \(Self.box(box))")
        #expect(abs(box.height - unit.height * scale) < 1e-3, "высота не по меньшей стороне")
        // Центр сетки обязан совпасть с центром рамки, а не её края.
        let gridCenterX = 30 + (unit.midX - 12) * scale + 20
        #expect(abs(box.midX - gridCenterX) < 1e-3,
                "сетка не по центру по X: \(box.midX) против \(gridCenterX)")

        // Тот же значок в рамке, повёрнутой на бок: сторона обязана СОВПАСТЬ, ведь
        // меньшая сторона у обеих одна и та же. Это ловит растяжение прямо.
        let tall = try SVGPathParser.path(fromPathData: icon.pathData,
                                          in: CGRect(x: 0, y: 0, width: 40, height: 100))
        #expect(abs(tall.boundingRect.width - box.width) < 1e-3,
                "в 100×40 и 40×100 значок вышел разного размера — сторона берётся не по меньшей")
    }

    /// Прямой разбор в `rect` и «разбор в сетке + аффинное преобразование» обязаны
    /// совпадать: иначе кешированный путь рисовал бы НЕ ТО, что проверено в A.
    ///
    /// ★ Допуск 1e-4, и он взят ИЗМЕРЕНИЕМ, а не на глаз: `Path` SwiftUI хранит
    /// координаты в ОДИНАРНОЙ точности. Доказано побитово — записанное `0.1`
    /// читается обратно как `Double(Float(0.1))`, ровно, а на координате 46.963
    /// расхождение 1.2512207163695166e-06 совпадает с float32-округлением до
    /// последнего знака. Отсюда потолок точности самого прибора ~1e-5 на
    /// координатах порядка 50; требовать 1e-9 значило бы мерить точность
    /// контейнера, а не разбора. Наблюдаемое расхождение двух путей — 3.1e-06,
    /// то есть три миллионные ЭКРАННОГО ПИКСЕЛЯ.
    @Test func cachedTransformMatchesDirectParse() throws {
        let rect = CGRect(x: 11, y: -4, width: 57, height: 33)
        var worst: (String, CGFloat) = ("", 0)
        let files = try FileManager.default
            .contentsOfDirectory(at: Self.programIconsDir, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "svg" }

        for file in files {
            let icon = try Self.pathData(at: file)
            let direct = try SVGPathParser.path(fromPathData: icon.pathData, in: rect,
                                                viewBox: icon.viewBox)
            let viaCache = try SVGPathParser.unitPath(fromPathData: icon.pathData,
                                                      viewBox: icon.viewBox)
                .applying(SVGPathParser.transform(for: rect, viewBox: icon.viewBox))
            // Сверяем ТОЧКИ, а не рамку: два способа обязаны дать одни и те же
            // числа, и приближённая рамка это скрыла бы (или выдумала расхождение).
            let drift = try #require(Self.maxPointDrift(direct, viaCache),
                                     "\(file.lastPathComponent): разный состав элементов")
            if drift > worst.1 { worst = (file.lastPathComponent, drift) }
            #expect(Self.elementCount(direct) == Self.elementCount(viaCache),
                    "\(file.lastPathComponent): разное число элементов")
        }
        print("\n   прямой разбор против «сетка + преобразование»: худшее расхождение "
            + String(format: "%.3e", Double(worst.1)) + " (\(worst.0))")
        #expect(worst.1 < 1e-4, "кешированный путь расходится с прямым разбором: \(worst)")

        // Прибор доказан и с другой стороны: ДВА прямых разбора одного контура
        // обязаны совпасть побитово. Не совпади они — 1e-4 выше прощал бы уже не
        // одинарную точность, а настоящую невоспроизводимость разбора.
        let twice = try Self.pathData(at: Self.programIconsDir
            .appendingPathComponent("blender.svg"))
        let first = try SVGPathParser.path(fromPathData: twice.pathData, in: rect)
        let second = try SVGPathParser.path(fromPathData: twice.pathData, in: rect)
        #expect(Self.maxPointDrift(first, second) == 0, "один и тот же разбор дал разные числа")
    }

    /// «Разбирается ОДИН раз» — это ЧИСЛО, а не впечатление. Считаем сами разборы.
    @Test func sameIconIsParsedOnlyOnce() throws {
        let icon = try Self.pathData(at: Self.brandIconsDir.appendingPathComponent("gogdotcom.svg"))
        SVGUnitPathCache.shared.reset()
        let before = SVGUnitPathCache.shared.parseCount

        let shape = SVGIconShape(pathData: icon.pathData)
        for i in 0..<20 {
            // Разные рамки: кеш обязан держать РАЗБОР, а не готовый путь под рамку.
            _ = shape.path(in: CGRect(x: 0, y: 0, width: 24 + CGFloat(i), height: 24))
        }
        let parses = SVGUnitPathCache.shared.parseCount - before
        print("   20 отрисовок в разных рамках -> разборов: \(parses)")
        #expect(parses == 1, "разборов \(parses) на 20 отрисовок — кеш не работает")
    }

    // MARK: - загрузка из ресурсов

    /// Значок обязан НАХОДИТЬСЯ в собранном бандле.
    ///
    /// ★ Ради этого теста: `.process("Resources")` РАСПЛЮЩИВАЕТ дерево, и поиск
    /// только по `subdirectory: "program-icons"` возвращал бы nil на каждом из 54
    /// значков. Витрина осталась бы с монограммами, а отказа не видно нигде —
    /// именно тот случай, когда «работает» и «молча ничего не делает» совпадают.
    @MainActor
    @Test func loaderFindsIconsInTheBuiltBundle() throws {
        SVGIconLoader.resetCache()
        let slugs = ["7zip", "blender", "python", "steam", "notepadplusplus"]
        var missing: [String] = []
        for slug in slugs where SVGIconLoader.pathData(slug: slug) == nil { missing.append(slug) }
        #expect(missing.isEmpty, "в бандле не нашлись значки: \(missing.joined(separator: ", "))")

        let icon = try #require(SVGIconLoader.icon(slug: "7zip"))
        #expect(icon.viewBox == 24)
        let path = try #require(SVGIconLoader.path(slug: "7zip",
                                                   in: CGRect(x: 0, y: 0, width: 32, height: 32)))
        #expect(Self.elementCount(path) > 0)
        // Несуществующий значок — это nil, а не отказ и не пустая фигура.
        #expect(SVGIconLoader.pathData(slug: "такого-значка-нет") == nil)
    }

    /// Документ не той формы отвергается, а не рисуется приблизительно.
    @Test func documentOutsideSimpleIconsShapeIsRejected() {
        let ok = #"<svg viewBox="0 0 24 24"><path d="M0 0h24v24H0z"/></svg>"#
        #expect(SVGDocument.icon(fromSVG: ok)?.viewBox == 24)

        let twoContours = #"<svg viewBox="0 0 24 24"><path d="M0 0h1"/><path d="M2 2h1"/></svg>"#
        #expect(SVGDocument.icon(fromSVG: twoContours) == nil, "два контура — здесь не поддержано")

        let noBox = #"<svg><path d="M0 0h1"/></svg>"#
        #expect(SVGDocument.icon(fromSVG: noBox) == nil, "без viewBox масштаб был бы угадан")

        let shifted = #"<svg viewBox="2 0 24 24"><path d="M0 0h1"/></svg>"#
        #expect(SVGDocument.icon(fromSVG: shifted) == nil, "начало не в нуле здесь не выражается")

        let oblong = #"<svg viewBox="0 0 32 24"><path d="M0 0h1"/></svg>"#
        #expect(SVGDocument.icon(fromSVG: oblong) == nil, "не квадратная сетка здесь не выражается")

        // transform молча проигнорировать — значит нарисовать сдвинутым и не узнать.
        let moved = #"<svg viewBox="0 0 24 24"><path transform="translate(3)" d="M0 0h1"/></svg>"#
        #expect(SVGDocument.icon(fromSVG: moved) == nil, "transform здесь не применяется — отказ")
    }

    /// Фигура при негодных данных отдаёт пустой `Path` — но это НЕ тихий отказ:
    /// разбор бросает, а `SVGIconShape` печатает причину в stderr. Проверяем, что
    /// пустота случается только на негодном входе, а на годном её нет.
    @Test func shapeIsEmptyOnlyForBadData() {
        let rect = CGRect(x: 0, y: 0, width: 24, height: 24)
        #expect(SVGIconShape(pathData: "нет такого контура").path(in: rect).isEmpty)
        #expect(!SVGIconShape(pathData: "M0 0h24v24H0z").path(in: rect).isEmpty)
    }

    // MARK: - оформление вывода

    static func fmt(_ v: CGFloat) -> String {
        String(format: "%g", Double(v))
    }

    static func box(_ r: CGRect) -> String {
        String(format: "x %7.3f..%7.3f y %7.3f..%7.3f",
               Double(r.minX), Double(r.maxX), Double(r.minY), Double(r.maxY))
    }
}
