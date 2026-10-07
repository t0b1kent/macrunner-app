import Foundation

/// Launch admission and update admission share one lock. A launch reserves its place
/// before preparation starts; an update keeps its reservation through installation.
final class UpdateSafetyGate: @unchecked Sendable {
    static let shared = UpdateSafetyGate()
    private let lock = NSLock()
    private var activities = Set<UUID>()
    private var updating = false

    func beginActivity() -> UUID? {
        lock.lock(); defer { lock.unlock() }
        guard !updating else { return nil }
        let token = UUID()
        activities.insert(token)
        return token
    }

    func endActivity(_ token: UUID) {
        lock.lock(); defer { lock.unlock() }
        activities.remove(token)
    }

    func beginUpdate(externalActivity: () -> Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard activities.isEmpty, !externalActivity() else { return false }
        updating = true
        return true
    }

    func endUpdate() {
        lock.lock(); defer { lock.unlock() }
        updating = false
    }

    var hasActivities: Bool {
        lock.lock(); defer { lock.unlock() }
        return !activities.isEmpty
    }

    var isUpdating: Bool {
        lock.lock(); defer { lock.unlock() }
        return updating
    }
}
