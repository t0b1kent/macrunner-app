import Foundation

/// Что именно произойдёт, если нажать корзину.
///
/// ★★★★ ГЛАВНОЕ ПРАВИЛО: МЫ УДАЛЯЕМ ТОЛЬКО ТО, ЧТО САМИ ПОСТАВИЛИ.
///
///   Владелец, 12.09.2026: «нажатие после предупреждения должно вести к деинсталляции
///   игры, а не просто удалению из библиотеки». Верно — но буквальное исполнение
///   этого стирало бы и ЧУЖИЕ файлы.
///
///   Игру можно добавить, указав свой `.exe` где угодно на диске: в папке с играми,
///   на внешнем томе, в рабочем каталоге. Мы его не ставили — значит и удалять не
///   вправе. У владельца прямо сейчас в библиотеке записи, указывающие в
///   `/fixture-mount/MacOS/MacRunner/artifacts/…`: снести их означало бы уничтожить
///   рабочие артефакты проекта по нажатию корзины в лаунчере.
///
///   Поэтому решение принимается по ПУТИ, а не по желанию:
///
/// ```
/// внутри наших папок + рядом деинсталлятор -> запустить деинсталлятор (путь Windows)
/// внутри наших папок, деинсталлятора нет   -> папку игры В КОРЗИНУ macOS
/// снаружи (файл человека)                  -> только убрать запись
/// ```
///
/// ★★ И удаляем МЫ В КОРЗИНУ, а не насовсем. Корзина обратима, `rm` — нет.
///   Ошибка распознавания «внутри/снаружи» тогда стоит одного восстановления,
///   а не потерянной игры.
enum RemovalPlan: Equatable {
    /// Есть родной деинсталлятор — правильный путь для Windows-программы:
    /// он уберёт и файлы, и записи реестра в бутылке.
    /// ★ Пути — СТРОКАМИ, а не `URL`. `URL(fileURLWithPath:)` молча дописывает
    ///   завершающий слэш существующему каталогу, а собранный из составляющих —
    ///   не дописывает; два URL на одну папку тогда НЕ РАВНЫ. Поймано собственным
    ///   тестом 12.09.2026. В сравнении путей это мина, и проще её не заводить.
    case runUninstaller(uninstaller: String, game: String)
    /// Своего деинсталлятора нет: отправляем папку игры в корзину macOS.
    case trashFolder(String)
    /// Файл не наш — трогать его нельзя, убираем только запись.
    case libraryOnly(reason: LibraryOnlyReason)

    enum LibraryOnlyReason: Equatable {
        /// Файл лежит вне наших папок — значит человек указал свой.
        case outsideOurFolders
        /// Файла уже нет на диске.
        case fileMissing
    }
}

enum GameRemoval {
    /// Имена, под которыми прячется деинсталлятор. Берём ТОЛЬКО их и только рядом
    /// с игрой: искать «что-нибудь похожее» по всему диску — верный способ запустить
    /// не то.
    static let uninstallerNames = ["unins000.exe", "uninstall.exe", "uninstaller.exe",
                                   "unins001.exe", "Uninstall.exe"]

    /// Решает, что делать. Пути наших папок передаются снаружи — так их видно
    /// в тестах, и решение не зависит от состояния приложения.
    static func plan(exePath: String,
                     ourFolders: [String],
                     fileManager: FileManager = .default) -> RemovalPlan {
        guard !exePath.isEmpty, fileManager.fileExists(atPath: exePath) else {
            return .libraryOnly(reason: .fileMissing)
        }
        let game = URL(fileURLWithPath: exePath).standardizedFileURL.path
        let folder = (game as NSString).deletingLastPathComponent

        guard isInside(folder, ourFolders: ourFolders) else {
            return .libraryOnly(reason: .outsideOurFolders)
        }
        for name in uninstallerNames {
            let candidate = (folder as NSString).appendingPathComponent(name)
            if fileManager.fileExists(atPath: candidate) {
                return .runUninstaller(uninstaller: candidate, game: game)
            }
        }
        return .trashFolder(folder)
    }

    /// Выполняет решение, принятое `plan`.
    ///
    /// ★ Возвращает путь к деинсталлятору, если его надо ЗАПУСТИТЬ. Сам запуск
    ///   здесь не делается намеренно: `.exe` идёт через движок, а эта служба о
    ///   движке не знает и знать не должна — иначе её нельзя было бы проверить
    ///   тестами на настоящей файловой системе.
    ///
    /// ★★ Удаляем ТОЛЬКО в корзину (`trashItem`), никогда `removeItem`. Корзина
    ///   обратима: если распознавание «наше/чужое» однажды ошибётся, цена ошибки —
    ///   одно восстановление, а не потерянная игра.
    @discardableResult
    static func execute(_ plan: RemovalPlan,
                        fileManager: FileManager = .default) throws -> String? {
        switch plan {
        case .libraryOnly:
            return nil
        case .trashFolder(let folder):
            var restored: NSURL?
            try fileManager.trashItem(at: URL(fileURLWithPath: folder),
                                      resultingItemURL: &restored)
            return nil
        case .runUninstaller(let uninstaller, _):
            return uninstaller
        }
    }

    /// ★ Сравниваем по ГРАНИЦЕ СОСТАВЛЯЮЩЕЙ пути, а не по началу строки.
    ///   Иначе `/fixture-home/user/Games-прочее` считался бы «внутри» `/fixture-home/user/Games`,
    ///   и мы отправили бы в корзину чужую папку с похожим именем.
    static func isInside(_ path: String, ourFolders: [String]) -> Bool {
        let target = URL(fileURLWithPath: path).standardizedFileURL.path
        for folder in ourFolders where !folder.isEmpty {
            let base = URL(fileURLWithPath: folder).standardizedFileURL.path
            if target == base { return true }
            if target.hasPrefix(base.hasSuffix("/") ? base : base + "/") { return true }
        }
        return false
    }
}
