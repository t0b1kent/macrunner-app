import Foundation

/// Ключ SteamGridDB. Хранится в связке ключей, как и ключ Steam, — в файле настроек
/// ему не место: он даёт доступ к квоте пользователя на их API.
///
/// Ключ бесплатный, человек берёт его сам в профиле на steamgriddb.com. Без ключа
/// служба молча возвращает `nil`, и обложка остаётся нарисованной заглушкой —
/// отсутствие ключа не должно ломать библиотеку.
struct SteamGridDBKeyStore {
    static let service = "app.macrunner.steamgriddb"
    private let apiKeyAccount = "api-key"

    func saveAPIKey(_ key: String) throws {
        try KeychainSecretStore(service: Self.service).save(key, account: apiKeyAccount)
    }

    func loadAPIKey() -> String? {
        KeychainSecretStore(service: Self.service).load(account: apiKeyAccount)
    }

    func deleteAPIKey() throws {
        try KeychainSecretStore(service: Self.service).delete(account: apiKeyAccount)
    }
}
