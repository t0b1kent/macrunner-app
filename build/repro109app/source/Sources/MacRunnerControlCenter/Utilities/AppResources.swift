import Foundation

extension Bundle {
    /// Ресурсы приложения (переводы, каталоги, значки).
    ///
    /// ★★★ НЕ `Bundle.module` НАПРЯМУЮ. Сгенерированный SwiftPM доступ ищет пакет
    ///   ресурсов в КОРНЕ `.app` (`Bundle.main.bundleURL`) или по абсолютному пути сборки
    ///   на машине разработчика. В корень `.app` класть нельзя — подпись отказывает
    ///   («unsealed contents»), а пути сборки у игрока нет: собранное приложение на чужом
    ///   Mac падало бы `fatalError` при первом же переводе. Поэтому сначала
    ///   `Contents/Resources`, куда кладёт `scripts/package-control-center.sh`, и только
    ///   потом `Bundle.module` (запуск из `swift run` и тесты).
    static let appResources: Bundle = {
        let name = "MacRunnerControlCenter_MacRunnerControlCenter.bundle"
        if let url = Bundle.main.resourceURL?.appendingPathComponent(name),
           let bundle = Bundle(url: url) {
            return bundle
        }
        return .module
    }()
}
