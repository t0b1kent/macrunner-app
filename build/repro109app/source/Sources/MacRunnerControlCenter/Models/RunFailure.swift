import Foundation

/// Почему игра не запустилась — словами, а не значком «FAILED».
///
/// ★★★ ПРАВИЛО: НИЧЕГО НЕ ПРИДУМЫВАЕМ. Заголовок строится только из того, что
///   вернул сценарий запуска (`status` в last-run.json), а подробность — дословный
///   текст движка (`error` или хвост stderr). Нет текста — подробности нет, и мы
///   не подставляем «правдоподобную» причину.
enum RunFailure {
    /// Итоги прогона, которые считаются отказом. Список — из run-windows-app.sh.
    /// UNSUPPORTED — встроенный движок не запускал игру: для её графики нет маршрута.
    static let failureStatuses: Set<String> = ["FAIL", "CRASH", "TIMEOUT", "INVALID_EXE", "MISSING_DLL", "UNSUPPORTED", "EARLY_EXIT"]

    static func isFailure(status: String?) -> Bool {
        guard let status else { return false }
        return failureStatuses.contains(status)
    }

    /// Заголовок отказа на языке человека. nil — отказа нет.
    static func headline(status: String?) -> String? {
        // STOPPED — игру остановил сам человек кнопкой; это не отказ.
        guard let status, status != "PASS", status != "STOPPED" else { return nil }
        switch status {
        case "INVALID_EXE": return L("The file is missing or is not a Windows program.")
        case "CRASH": return L("The game crashed.")
        case "TIMEOUT": return L("The game hit its time limit and was stopped.")
        case "MISSING_DLL": return L("The game needs a Windows library (DLL) that is missing.")
        case "UNSUPPORTED": return L("MacRunner cannot run this program yet.")
        case "FAIL": return L("The game exited with an error.")
        case "EARLY_EXIT": return L("The game closed immediately after launch.")
        default: return String(format: L("The run ended with status %@."), status)
        }
    }

    /// Улика из результата движка: его собственное сообщение об ошибке, а если
    /// его нет — последняя непустая строка stderr. Длинное обрезаем: это подпись,
    /// а не журнал.
    static func detail(from result: LauncherResult?) -> String? {
        guard let result else { return nil }
        // Отказ по графике или разрядности — наш разбор, а не текст движка.
        // Доказательство (пути, отчёты) остаётся в last-run.json, человеку — первая строка.
        if result.status == "UNSUPPORTED", let error = result.error, !error.isEmpty {
            return error.split(whereSeparator: \.isNewline).first.map(String.init)
        }
        let candidates = [result.error, result.stderrTail]
        for text in candidates.compactMap({ $0 }) {
            let line = text
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .last { !$0.isEmpty }
            if let line {
                return line.count > 300 ? String(line.prefix(300)) + "…" : line
            }
        }
        return nil
    }

    // MARK: - Движок

    /// Сценарий, через который идёт КАЖДЫЙ запуск (`RunAppViewModel.run`).
    static func launcherScript(settings: AppSettings) -> String {
        "\(settings.macRunnerRoot)/scripts/run-windows-app.sh"
    }

    /// ★ Без сценария запуска не стартует ничего. Раньше отказ `Process.run`
    ///   превращался в «FAIL» на плитке, и человек не узнавал, что сломана
    ///   не игра, а установка MacRunner.
    ///
    ///   Встроенный движок (`BundledEngine`) сценария не требует: он проверен при
    ///   загрузке (`ENGINE.json` читается, `wine` исполняем).
    static func engineMissing(settings: AppSettings) -> Bool {
        if BundledEngine.current != nil { return false }
        return !FileManager.default.isExecutableFile(atPath: launcherScript(settings: settings))
    }

    static var engineMissingMessage: String {
        L("MacRunner engine not found. Reinstall MacRunner.")
    }
}
