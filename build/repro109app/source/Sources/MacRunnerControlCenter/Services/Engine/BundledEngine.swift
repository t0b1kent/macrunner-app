import Foundation

/// Движок, встроенный в приложение: `MacRunner.app/Contents/Resources/engine`.
///
/// ★★★ ЗАЧЕМ (решение владельца 23.09.2026: бесплатный открытый выпуск на FEX).
///   До этого приложение запускало игры через `scripts/run-windows-app.sh` из корня
///   НАШЕГО репозитория и при первом запуске просило к нему путь. У игрока репозитория
///   нет, а сценарий требует `python3`, которого на обычном Mac нет. Поэтому выпускная
///   сборка несёт движок в себе, и запуск идёт напрямую из Swift (`EngineLauncher`).
///
///   Состав пакета собирает `scripts/release/assemble_engine.py` из
///   `release/engine-sources.json`; приложение читает ТОЛЬКО `ENGINE.json`: имя сборки
///   и шаблон окружения с подстановками `${ENGINE}` (корень пакета) и `${DATA}`
///   (каталог данных пользователя). Движок ведёт Astra: новая её сборка подкладывается
///   правкой списка источников, без правки приложения.
///
///   Нет пакета в бандле (сборка разработчика) — `current == nil`, и приложение
///   работает по-старому, через сценарий репозитория.
struct BundledEngine: Sendable {
    let root: URL
    let name: String
    let environmentTemplate: [String: String]
    /// Графика пакета: слои и маршруты с доказательствами (`GraphicsCatalog`).
    var graphics = GraphicsCatalog(layers: [], routes: [])
    /// Слои, у которых в пакете не хватает файлов: id → чего нет. Такой слой не ставится
    /// и его маршруты не запускаются — неполный набор хуже отсутствующего.
    var incompleteLayers: [String: [String]] = [:]

    var wine: URL { root.appendingPathComponent("wine/bin/wine") }
    var wineserver: URL { root.appendingPathComponent("wine/bin/wineserver") }

    /// Пакет в бандле приложения; `MACRUNNER_BUNDLED_ENGINE` подменяет путь для проверки
    /// пакета без пересборки приложения.
    static let current: BundledEngine? = {
        if let override = ProcessInfo.processInfo.environment["MACRUNNER_BUNDLED_ENGINE"], !override.isEmpty {
            return load(from: URL(fileURLWithPath: override, isDirectory: true))
        }
        guard let resources = Bundle.main.resourceURL else { return nil }
        return load(from: resources.appendingPathComponent("engine", isDirectory: true))
    }()

    static func load(from root: URL) -> BundledEngine? {
        let manifestURL = root.appendingPathComponent("ENGINE.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let environment = object["environment"] as? [String: String],
              FileManager.default.isExecutableFile(atPath: root.appendingPathComponent("wine/bin/wine").path)
        else { return nil }
        var engine = BundledEngine(root: root, name: object["name"] as? String ?? "engine", environmentTemplate: environment)
        engine.graphics = GraphicsCatalog.load(manifest: object, engineRoot: root)
        for layer in engine.graphics.layers {
            let files = layer.modules.flatMap { dir, names in names.map { "\(dir)/\($0)" } } + (layer.unix ?? [])
            let missing = files.filter { !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
            if !missing.isEmpty { engine.incompleteLayers[layer.id] = missing.sorted() }
        }
        return engine
    }

    /// Окружение движка для одной бутылки: шаблон с подставленными путями плюс префикс.
    func environment(prefix: URL, data: URL) -> [String: String] {
        var env: [String: String] = [:]
        for (key, value) in environmentTemplate {
            env[key] = value
                .replacingOccurrences(of: "${ENGINE}", with: root.path)
                .replacingOccurrences(of: "${DATA}", with: data.path)
        }
        env["WINEPREFIX"] = prefix.path
        return env
    }
}

/// Где движок хранит данные игрока. Всё — в Application Support, рядом с библиотекой
/// (`ConfigStore`): внутрь подписанного `.app` писать нельзя, а в домашний каталог
/// без спроса класть папки невежливо.
enum EnginePaths {
    static let base: URL = {
        // Isolated app-path acceptance uses the same bottle/run layout without
        // touching the player's library or default bottle.
        if let path = ProcessInfo.processInfo.environment["MACRUNNER_APP_DATA_ROOT"], path.hasPrefix("/") {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            return url
        }
        let url = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacRunnerControlCenter", isDirectory: true)
        return url
    }()

    static var bottles: URL { base.appendingPathComponent("Bottles", isDirectory: true) }
    static var runs: URL { base.appendingPathComponent("Runs", isDirectory: true) }
    static var data: URL { base.appendingPathComponent("EngineData", isDirectory: true) }

    /// Бутылка по умолчанию. Пока одна на все игры, как в рабочих прогонах.
    static var defaultBottle: URL { bottles.appendingPathComponent("Default", isDirectory: true) }
}
