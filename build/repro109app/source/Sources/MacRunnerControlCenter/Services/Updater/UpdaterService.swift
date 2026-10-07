import Foundation

enum UpdateChannel: String, Codable, CaseIterable, Identifiable {
    case stable
    case beta
    case nightly

    var id: String { rawValue }
    var allowedChannels: Set<String> {
        switch self {
        case .stable: return []
        case .beta: return ["beta"]
        case .nightly: return ["beta", "nightly"]
        }
    }
    var warning: String? { self == .nightly ? "Nightly builds may introduce instability." : nil }
}

struct UpdaterConfiguration: Codable, Equatable {
    var channel: UpdateChannel
    var appcastURL: URL?
    var sparkleEnabled: Bool
}

struct UpdaterService {
    func configuration(settings: AppSettings, info: [String: Any] = Bundle.main.infoDictionary ?? [:]) -> UpdaterConfiguration {
        let channel = UpdateChannel(rawValue: settings.updateChannel ?? "stable") ?? .stable
        let feed = Self.validatedFeed(info: info)
        return UpdaterConfiguration(channel: channel, appcastURL: feed, sparkleEnabled: feed != nil)
    }

    /// Only the signed bundle supplies the feed. Silent installation must be disabled:
    /// Windows programs can outlive the application's window and process.
    static func validatedFeed(info: [String: Any]) -> URL? {
        guard let text = info["SUFeedURL"] as? String,
              let parts = URLComponents(string: text), parts.scheme?.lowercased() == "https",
              let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.fragment == nil,
              let url = parts.url,
              let key = info["SUPublicEDKey"] as? String,
              let bytes = Data(base64Encoded: key), bytes.count == 32,
              info["SUAllowsAutomaticUpdates"] as? Bool == false,
              info["SUAutomaticallyUpdate"] as? Bool == false else { return nil }
        return url
    }
}
