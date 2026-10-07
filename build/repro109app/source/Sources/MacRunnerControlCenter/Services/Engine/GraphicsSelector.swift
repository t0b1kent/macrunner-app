import Foundation

/// Решение о графике для одного запуска: какой маршрут, почему и можно ли запускать.
///
/// ★★★ API ВЫБИРАЕТ ИГРА, А НЕ МЫ. Мы подбираем движку согласованный набор под то, что
///   игра будет вызывать. Нет маршрута для её API — отказ с объяснением, а не запуск
///   «через DX11 авось». Неизвестный API — запуск с обычной конфигурацией, но
///   «неизвестно» остаётся названным в плане, журнале и итоге.
struct GraphicsPlan: Sendable, Equatable {
    enum Decision: Sendable, Equatable {
        case launch
        /// Не запускать: текст объясняет почему.
        case refuse(String)
    }

    var arch: GuestArch?
    /// Основной API; nil — не определён.
    var api: GraphicsAPI?
    /// Все API, на которые есть улики, с силой.
    var candidates: [GraphicsAPI: GraphicsDetection.Strength] = [:]
    var route: GraphicsRoute?
    var layer: GraphicsLayer?
    var decision: Decision = .launch
    /// Ключи запуска из профиля (переключение рендера, если игра его документирует).
    var extraArguments: [String] = []
    var environment: [String: String] = [:]
    var emulateModeset: Bool? = nil
    var cdromDataFilename: String? = nil
    var overridden = false
    /// Для человека: предупреждения (другие API игры недоступны, маршрут не проверен).
    var warnings: [String] = []
    /// Для журнала: улики как есть.
    var evidence: [String] = []

    /// Строка для плитки и журнала: «DirectX 11 · 64-bit · Experimental, not verified».
    var summary: String {
        let apiText = api?.title ?? L("Graphics API not determined")
        let archText = arch?.title ?? L("unknown architecture")
        let statusText = route?.status.title ?? (api == nil ? L("standard configuration") : RouteStatus.unavailable.title)
        return "\(apiText) · \(archText) · \(statusText)"
    }
}

enum GraphicsSelector {
    /// `override` — API, заданный человеком или профилем разработчика вместо «Авто».
    static func plan(detection: GraphicsDetection, engine: BundledEngine, override: GraphicsAPI? = nil) -> GraphicsPlan {
        let catalog = engine.graphics
        var plan = GraphicsPlan()
        plan.arch = detection.arch
        plan.evidence = detection.evidence.map { "\($0.source) [\($0.strength)]" } + detection.notes

        guard let arch = detection.arch else {
            plan.decision = .refuse(L("MacRunner cannot tell which processor this program is built for."))
            return plan
        }
        // Разрядность раньше графики: без неё не стартует ничего, даже установщик.
        if let support = catalog.architecture(arch) {
            guard support.status.canLaunch else {
                plan.decision = .refuse(String(format: L("%@ Windows programs cannot run in this version of MacRunner yet."), arch.title)
                                        + (support.evidence.map { "\n" + $0 } ?? ""))
                return plan
            }
        }

        if let override {
            plan.overridden = true
            plan.candidates = [override: .profile]
        } else {
            plan.candidates = detection.candidates
        }
        // Трассировку лучей «Авто» не выбирает никогда (отложена владельцем): она попадает
        // в кандидаты только из профиля игры, которой она обязательна.
        if !plan.overridden, detection.profile?.apis.contains(.d3d12RT) != true {
            plan.candidates[.d3d12RT] = nil
        }

        guard let strongest = plan.candidates.values.max() else {
            // Ничего не нашли: лаунчер, динамическая загрузка, OpenGL через обёртку…
            plan.warnings.append(detection.dxgiOnly
                ? L("The game uses DXGI, but its Direct3D version could not be determined.")
                : L("The graphics API could not be determined from the game files."))
            return plan
        }

        // Одни упоминания строками, и API несколько — это не выбор, а шум: лаунчеры и
        // оверлеи (EasyAntiCheat, замер 23.09) называют d3d9, d3d11, OpenGL и Vulkan разом.
        // Выбрать из них «запускаемый» значило бы угадать молча.
        let mentioned = plan.candidates.filter { $0.value == strongest }.map(\.key)
        if strongest == .stringReference, mentioned.count > 1 {
            plan.warnings.append(String(format: L("The game files mention several graphics APIs (%@); the one the game uses could not be determined."),
                                        mentioned.sorted(by: >).map(\.title).joined(separator: ", ")))
            return plan
        }

        // Отказ — только если у игры НЕТ НИ ОДНОГО доступного API. Есть хотя бы один — игра
        // запускается и выбирает сама, а недоступные названы в предупреждении.
        // ★ Замер 23.09: hedon.exe (GZDoom) статически импортирует d3d9.dll, а рисует через
        //   OpenGL (он только строкой). Отказ по сильнейшей улике закрыл бы игру, которая
        //   работает. Главный API для подписи — доступный с самой сильной уликой, затем по
        //   предпочтению (`GraphicsAPI.preference`).
        func launchable(_ api: GraphicsAPI) -> Bool {
            guard let route = catalog.route(api: api, arch: arch), route.status.canLaunch else { return false }
            return engine.incompleteLayers[route.layer ?? ""] == nil
        }
        let ranked = plan.candidates.sorted {
            (launchable($0.key) ? 1 : 0, $0.value, $0.key) > (launchable($1.key) ? 1 : 0, $1.value, $1.key)
        }
        let api = ranked[0].key
        plan.api = api
        plan.route = catalog.route(api: api, arch: arch)

        for other in plan.candidates.keys.sorted(by: >) where other != api && !launchable(other) {
            plan.warnings.append(String(format: L("The game may also use %@, which is not available for %@ games. If it chooses it, it will not start."),
                                        other.title, arch.title))
        }

        guard let route = plan.route else {
            plan.decision = .refuse(String(format: L("This game uses %@ (%@). This version of MacRunner has no support for it yet."),
                                           api.title, arch.title))
            return plan
        }
        guard route.status.canLaunch else {
            let reason = route.status == .deferred ? L("Support is postponed.") : L("Support is not available yet.")
            plan.decision = .refuse(String(format: L("This game uses %@ (%@). %@"), api.title, arch.title, reason)
                                    + (route.evidence.map { "\n" + $0 } ?? ""))
            return plan
        }
        if let layerID = route.layer, layerID != GraphicsCatalog.wineLayer {
            guard let layer = catalog.layer(layerID) else {
                plan.decision = .refuse(String(format: L("The MacRunner engine is incomplete: %@ is missing. Reinstall MacRunner."), layerID))
                return plan
            }
            if let missing = engine.incompleteLayers[layerID] {
                plan.decision = .refuse(String(format: L("The MacRunner engine is incomplete: %@ is missing. Reinstall MacRunner."),
                                               missing.joined(separator: ", ")))
                return plan
            }
            plan.layer = layer
            plan.environment = (layer.environment ?? [:]).mapValues {
                $0.replacingOccurrences(of: "${ENGINE}", with: engine.root.path)
            }
        }
        if route.status == .experimental {
            plan.warnings.append(String(format: L("%@ for %@ games is experimental in this version: it has not been verified yet."),
                                        api.title, arch.title))
        }
        // Параметры процесса разрешены только точной записи из ресурсов приложения.
        // Применяем после всех отказов; настройки выбранного слоя остаются главнее.
        // EngineLauncher затем накладывает ручные параметры записи игры.
        if let profile = detection.profile, GraphicsProfile.bundled.contains(profile) {
            plan.environment = (profile.environment ?? [:]).merging(plan.environment) { _, layer in layer }
            plan.emulateModeset = profile.emulateModeset
            plan.cdromDataFilename = profile.cdromDataFilename
        }
        if let args = detection.profile?.renderArgs?[api.rawValue] { plan.extraArguments = args }
        return plan
    }
}
