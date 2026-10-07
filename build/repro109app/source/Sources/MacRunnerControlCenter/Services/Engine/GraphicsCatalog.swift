import Foundation

/// Что умеет графика встроенного движка: слои модулей и маршруты «API × разрядность».
///
/// ★★★ ИСТОЧНИК ПРАВДЫ — ПАКЕТ ДВИЖКА, А НЕ ПРИЛОЖЕНИЕ (требование владельца, 23.09.2026,
///   reports/research/APP-AUTO-GRAPHICS-REQUIREMENT-20260923.md). Раздел `graphics` в
///   `ENGINE.json` пишется людьми в `release/engine-sources.json` вместе с доказательствами;
///   приложение только читает его. Поэтому новый комплект Astra (DX12) приносит свою
///   матрицу, и приложение не нужно переписывать под каждую версию движка.
///
///   Различаем честно: «файлы есть» ≠ «проверено на тестовых программах» ≠ «проверено в
///   играх». x64 не доказывает PE32, обычный DX12 не доказывает трассировку лучей.
enum GraphicsAPI: String, Codable, CaseIterable, Sendable, Comparable {
    case d3d8, d3d9, d3d10, d3d11, d3d12
    /// DirectX Raytracing — отдельная строка матрицы: DX12 без неё её не доказывает.
    case d3d12RT = "d3d12-rt"
    case opengl, vulkan, ddraw

    var title: String {
        switch self {
        case .d3d8: return "DirectX 8"
        case .d3d9: return "DirectX 9"
        case .d3d10: return "DirectX 10"
        case .d3d11: return "DirectX 11"
        case .d3d12: return "DirectX 12"
        case .d3d12RT: return "DirectX 12 Raytracing"
        case .opengl: return "OpenGL"
        case .vulkan: return "Vulkan"
        case .ddraw: return "DirectDraw"
        }
    }

    /// Чем выше, тем вероятнее это основной рендер игры, когда улики равны.
    ///
    /// ★ Замер 23.09: UnityPlayer.dll (Hollow Knight, Vampire Survivors) и AbzuGame (UE4)
    ///   статически импортируют И opengl32, И d3d11, а рисуют на Windows через D3D11.
    ///   Порядок перечисления ставил OpenGL «новее» DirectX, и Hollow Knight подписывался
    ///   как OpenGL. Поэтому порядок предпочтения — отдельный и явный.
    static let preference: [GraphicsAPI] = [.opengl, .vulkan, .ddraw, .d3d8, .d3d9, .d3d10, .d3d11, .d3d12, .d3d12RT]
    private var rank: Int { Self.preference.firstIndex(of: self) ?? 0 }
    static func < (a: GraphicsAPI, b: GraphicsAPI) -> Bool { a.rank < b.rank }
}

enum GuestArch: String, Codable, CaseIterable, Sendable {
    case x86_64, x86, arm64

    var title: String {
        switch self {
        case .x86_64: return L("64-bit")
        case .x86: return L("32-bit")
        case .arm64: return "ARM64"
        }
    }

    /// Машина из заголовка PE.
    init?(machine: UInt16) {
        switch machine {
        case 0x8664: self = .x86_64
        case 0x014c: self = .x86
        case 0xAA64: self = .arm64
        default: return nil
        }
    }
}

/// Насколько маршрут подтверждён. Порядок — от сильного к слабому.
enum RouteStatus: String, Codable, Sendable {
    /// Игры проверены на ЭТОМ пакете (доказательство в `evidence`).
    case verified
    /// Тестовые программы проходят на этом пакете, игры — нет.
    case fixtures
    /// Модули на месте и согласованы, но на этом пакете не проверено ничего.
    case experimental
    /// В этом пакете реализации нет.
    case unavailable
    /// Отложено решением владельца (например, трассировка лучей).
    case deferred

    var canLaunch: Bool { self == .verified || self == .fixtures || self == .experimental }

    var title: String {
        switch self {
        case .verified: return L("Verified in games")
        case .fixtures: return L("Tested on test programs")
        case .experimental: return L("Experimental, not verified")
        case .unavailable: return L("Not available yet")
        case .deferred: return L("Postponed")
        }
    }
}

/// Слой графики: ПОЛНЫЙ согласованный набор модулей одной сборки (фронтенды, мост
/// winemetal, преобразователь) — ставится и снимается только целиком.
struct GraphicsLayer: Codable, Sendable, Equatable {
    let id: String
    let title: String
    /// Каталог пакета (`graphics/x86_64-windows`) → имена модулей, кладутся в system32/syswow64.
    let modules: [String: [String]]
    /// Нативные части (unix-мост) — только для проверки полноты, в бутылку не копируются.
    let unix: [String]?
    /// Добавки к окружению движка для маршрутов этого слоя.
    let environment: [String: String]?
}

struct GraphicsRoute: Codable, Sendable, Equatable {
    let api: GraphicsAPI
    let arch: GuestArch
    /// `wine` — собственные модули Wine (всегда в бутылке); иначе id слоя; nil — нечем.
    let layer: String?
    let status: RouteStatus
    /// Чем подтверждено (путь к прогону/отчёту) — или почему недоступно.
    let evidence: String?
}

/// Разрядность целиком: 32 бита могут быть недоступны вне зависимости от графики
/// (нужны 4-КБ страницы и нижние 4 ГБ адресов). Тогда отказ один и понятный — в том
/// числе для установщиков, у которых графики нет вовсе.
struct ArchitectureSupport: Codable, Sendable, Equatable {
    let arch: GuestArch
    let status: RouteStatus
    let evidence: String?
}

struct GraphicsCatalog: Codable, Sendable, Equatable {
    let layers: [GraphicsLayer]
    let routes: [GraphicsRoute]
    var architectures: [ArchitectureSupport]? = nil

    func architecture(_ arch: GuestArch) -> ArchitectureSupport? {
        architectures?.first { $0.arch == arch }
    }

    static let wineLayer = "wine"
    static let legacyDirectory = "graphics/x86_64-windows"

    /// Куда в бутылке кладутся модули из каталога пакета: по архитектуре в имени каталога.
    static func bottleDirectory(forPackageDirectory dir: String) -> String? {
        if dir.hasSuffix("x86_64-windows") || dir.hasSuffix("aarch64-windows") { return "system32" }
        if dir.hasSuffix("i386-windows") { return "syswow64" }
        return nil
    }

    /// Модули слоя в бутылке: «system32/d3d11.dll» → путь в пакете.
    func placements(of layer: GraphicsLayer) -> [String: String] {
        var result: [String: String] = [:]
        for (dir, names) in layer.modules {
            guard let target = Self.bottleDirectory(forPackageDirectory: dir) else { continue }
            for name in names { result["\(target)/\(name.lowercased())"] = "\(dir)/\(name)" }
        }
        return result
    }

    /// Слои, которые могут стоять вместе: не претендуют на один и тот же модуль бутылки.
    func conflicts(_ a: GraphicsLayer, _ b: GraphicsLayer) -> Bool {
        !Set(placements(of: a).keys).isDisjoint(with: placements(of: b).keys)
    }

    func route(api: GraphicsAPI, arch: GuestArch) -> GraphicsRoute? {
        routes.first { $0.api == api && $0.arch == arch }
    }

    func layer(_ id: String?) -> GraphicsLayer? {
        guard let id else { return nil }
        return layers.first { $0.id == id }
    }

    /// Чтение раздела `graphics` из ENGINE.json. Нет раздела (пакет схемы 1) — матрица
    /// из одного слоя по каталогу `graphics/x86_64-windows` и ВСЕ маршруты «не проверено»:
    /// статусы без доказательств приложение не придумывает.
    static func load(manifest: [String: Any], engineRoot: URL) -> GraphicsCatalog {
        if let raw = manifest["graphics"],
           let data = try? JSONSerialization.data(withJSONObject: raw),
           let catalog = try? JSONDecoder().decode(GraphicsCatalog.self, from: data) {
            return catalog
        }
        let dir = engineRoot.appendingPathComponent(legacyDirectory)
        let modules = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
            .filter { $0.lowercased().hasSuffix(".dll") }.sorted()
        guard !modules.isEmpty else { return GraphicsCatalog(layers: [], routes: []) }
        let layer = GraphicsLayer(id: "legacy-graphics", title: legacyDirectory,
                                  modules: [legacyDirectory: modules], unix: nil, environment: nil)
        let routes = [GraphicsAPI.d3d10, .d3d11].map {
            GraphicsRoute(api: $0, arch: .x86_64, layer: layer.id, status: .experimental,
                          evidence: "ENGINE.json schema 1: no capability matrix")
        }
        return GraphicsCatalog(layers: [layer], routes: routes)
    }
}
