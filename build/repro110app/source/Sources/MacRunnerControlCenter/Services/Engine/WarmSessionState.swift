import Foundation

/// One preparation per bottle generation. A click joins preparation already in flight.
/// The backend owns the actual server; this object owns readiness and program leases.
final class WarmSessionState: @unchecked Sendable {
    enum Failure: Error { case closed, busy, changedGeneration }
    private enum State { case cold, preparing, ready, failed(Error), closing, closed }
    private let condition = NSCondition()
    private var state: State = .cold
    private var activePrograms = 0
    private let prepare: () throws -> Void
    private let stop: () -> Void
    private let isAlive: () -> Bool
    private let idleTimeout: TimeInterval
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let idleDidClose: (WarmSessionState) -> Void
    private var idleGeneration: UInt64 = 0

    init(prepare: @escaping () throws -> Void, stop: @escaping () -> Void,
         isAlive: @escaping () -> Bool, idleTimeout: TimeInterval = 600,
         schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, work in
             DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay, execute: work)
         }, idleDidClose: @escaping (WarmSessionState) -> Void = { _ in }) {
        self.prepare = prepare
        self.stop = stop
        self.isAlive = isAlive
        self.idleTimeout = idleTimeout
        self.schedule = schedule
        self.idleDidClose = idleDidClose
    }

    /// Closed/failed backends have closed logs and cancellation state: create a fresh entry.
    var canReuse: Bool {
        condition.lock(); defer { condition.unlock() }
        switch state {
        case .cold, .preparing, .ready: return true
        case .failed, .closing, .closed: return false
        }
    }

    private func scheduleIdleLocked() {
        idleGeneration &+= 1
        let generation = idleGeneration
        schedule(idleTimeout) { [weak self] in self?.expireIdle(generation: generation) }
    }

    private func expireIdle(generation: UInt64) {
        condition.lock()
        guard generation == idleGeneration, activePrograms == 0, case .ready = state else {
            condition.unlock(); return
        }
        state = .closing
        idleGeneration &+= 1
        condition.unlock()
        stop()
        condition.lock()
        state = .closed
        condition.broadcast()
        condition.unlock()
        // Registry operations may wait for closing while holding their own lock.
        // Notify only for idle expiry and only after releasing the state lock.
        idleDidClose(self)
    }

    func ensureReady() throws {
        condition.lock()
        while true {
            switch state {
            case .preparing, .closing: condition.wait()
            case .closed: condition.unlock(); throw Failure.closed
            case .failed(let error): condition.unlock(); throw error
            case .ready:
                if isAlive() { condition.unlock(); return }
                state = .cold
            case .cold:
                state = .preparing
                condition.unlock()
                do {
                    try prepare()
                    guard isAlive() else { throw Failure.closed }
                    condition.lock()
                    state = .ready
                    scheduleIdleLocked()
                    condition.broadcast()
                    condition.unlock()
                    return
                } catch {
                    stop()
                    condition.lock()
                    state = .failed(error)
                    condition.broadcast()
                    condition.unlock()
                    throw error
                }
            }
        }
    }

    /// Reserve under the registry lock, before handing readiness to a caller.
    /// Idle expiry may retire an entry before reservation; the registry replaces it.
    func reserveProgramLease() throws -> Bool {
        condition.lock(); defer { condition.unlock() }
        switch state {
        case .closing, .closed, .failed: return false
        case .cold, .preparing, .ready: break
        }
        guard activePrograms == 0 else { throw Failure.busy }
        idleGeneration &+= 1
        activePrograms = 1
        return true
    }

    /// Serial programs in one namespace. Reserve before readiness/timer handoff.
    func beginProgram() throws {
        guard try reserveProgramLease() else { throw Failure.closed }
        do { try ensureReady() }
        catch { endProgram(); throw error }
    }

    func endProgram() {
        condition.lock(); defer { condition.unlock() }
        activePrograms = 0
        if case .ready = state { scheduleIdleLocked() }
        condition.broadcast()
    }

    /// Return false for an active program when an updater requests idle cleanup.
    @discardableResult
    func close(onlyIfIdle: Bool = false) -> Bool {
        condition.lock()
        while true {
            // A preparing program already owns its lease. Idle cleanup must not
            // hold the registry lock while waiting for its preparation to finish.
            if onlyIfIdle && activePrograms != 0 { condition.unlock(); return false }
            switch state {
            case .preparing, .closing: condition.wait()
            case .closed: condition.unlock(); return true
            default:
                state = .closing
                idleGeneration &+= 1
                condition.unlock()
                stop()
                condition.lock()
                state = .closed
                condition.broadcast()
                condition.unlock()
                return true
            }
        }
    }
}
