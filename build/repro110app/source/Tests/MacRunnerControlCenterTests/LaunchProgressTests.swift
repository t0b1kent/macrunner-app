import Foundation
import Testing
@testable import MacRunnerControlCenter

struct LaunchProgressTests {
    @Test func delayedActiveCallbackCannotUndoUserStop() {
        let start = Date(timeIntervalSince1970: 100)
        var progress = LaunchProgress(now: start)
        let prepared = progress.advance(to: .preparing, now: start.addingTimeInterval(1))
        let stopped = progress.advance(to: .stopping, now: start.addingTimeInterval(2))
        let delayedActive = progress.advance(to: .active, now: start.addingTimeInterval(3))
        let delayedStarting = progress.advance(to: .starting, now: start.addingTimeInterval(4))
        #expect(prepared)
        #expect(stopped)
        #expect(!delayedActive)
        #expect(!delayedStarting)
        #expect(progress.phase == .stopping)
        #expect(progress.phaseStartedAt == start.addingTimeInterval(2))
    }

    @Test func delayedOrDuplicateEventsDoNotResetElapsedTime() {
        let start = Date(timeIntervalSince1970: 100)
        var progress = LaunchProgress(now: start)
        let active = progress.advance(to: .active, now: start.addingTimeInterval(10))
        let delayedPreparing = progress.advance(to: .preparing, now: start.addingTimeInterval(11))
        let duplicateActive = progress.advance(to: .active, now: start.addingTimeInterval(12))
        #expect(active)
        #expect(!delayedPreparing)
        #expect(!duplicateActive)
        #expect(progress.startedAt == start)
        #expect(progress.phaseStartedAt == start.addingTimeInterval(10))
    }

    @Test func longPreparationDoesNotTriggerActiveProcessGuidanceEarly() {
        let start = Date(timeIntervalSince1970: 100)
        var progress = LaunchProgress(now: start)
        _ = progress.advance(to: .preparing, now: start)
        _ = progress.advance(to: .active, now: start.addingTimeInterval(90))
        #expect(progress.guidance(at: start.addingTimeInterval(119)) ==
                L("The process is active. A game window or rendered frames have not been confirmed."))
        #expect(progress.guidance(at: start.addingTimeInterval(120)) ==
                L("If no game window appears or it stays black, stop and report this launch."))
        _ = progress.advance(to: .stopping, now: start.addingTimeInterval(121))
        #expect(progress.guidance(at: start.addingTimeInterval(200)) == nil)
    }

    @Test func failedProcessSpawnDoesNotEmitActiveEvent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = try EngineLog(url: directory.appendingPathComponent("test.log"))
        defer {
            log.close()
            try? FileManager.default.removeItem(at: directory)
        }
        var events = 0
        do {
            _ = try EngineProcess.run(directory.appendingPathComponent("missing-executable"), [],
                                      environment: [:], log: log, onStarted: { events += 1 })
            Issue.record("A missing executable unexpectedly launched")
        } catch {
            #expect(events == 0)
        }
    }

    @Test func successfulProcessSpawnEmitsOneEvent() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let log = try EngineLog(url: directory.appendingPathComponent("test.log"))
        defer {
            log.close()
            try? FileManager.default.removeItem(at: directory)
        }
        var events = 0
        let result = try EngineProcess.run(URL(fileURLWithPath: "/usr/bin/true"), [],
                                          environment: [:], log: log, onStarted: { events += 1 })
        #expect(result.status == 0)
        #expect(events == 1)
    }
}
