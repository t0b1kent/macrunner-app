import Foundation
import Testing
@testable import MacRunnerControlCenter

struct RetinaDefaultTests {
    @Test func unsetGamesFollowPrimaryDisplayScale() {
        #expect(RetinaDefault.resolve(choice: nil, scaleFactor: 2, override: nil))
        #expect(!RetinaDefault.resolve(choice: nil, scaleFactor: 1, override: nil))
        #expect(!RetinaDefault.resolve(choice: nil, scaleFactor: 0, override: nil))
    }

    @Test func gameChoicesSurviveScreenChangesAndAutomaticOverrides() {
        for scale in [CGFloat(1), CGFloat(2)] {
            for setting in [nil, "0", "1"] as [String?] {
                #expect(RetinaDefault.resolve(choice: true, scaleFactor: scale, override: setting))
                #expect(!RetinaDefault.resolve(choice: false, scaleFactor: scale, override: setting))
            }
        }
    }

    @Test func automaticOverrideDoesNotInventRetinaOnAStandardDisplay() {
        #expect(!RetinaDefault.resolve(choice: nil, scaleFactor: 2, override: "0"))
        #expect(RetinaDefault.resolve(choice: nil, scaleFactor: 2, override: "1"))
        #expect(!RetinaDefault.resolve(choice: nil, scaleFactor: 1, override: "1"))
    }

    private func detection(_ items: [(GraphicsAPI, GraphicsDetection.Strength)]) -> GraphicsDetection {
        var value = GraphicsDetection()
        value.arch = .x86_64
        value.evidence = items.map { .init(api: $0.0, strength: $0.1, source: "probe.exe") }
        return value
    }

    @Test func automaticRetinaSkipsProgramsWithoutDeclaredGraphicsImports() {
        // steam.exe: only the string "opengl32.dll"; installers: nothing.
        #expect(!RetinaDefault.afterDetection(resolved: true, choice: nil, override: nil, detection: detection([])))
        #expect(!RetinaDefault.afterDetection(resolved: true, choice: nil, override: nil,
                                              detection: detection([(.opengl, .stringReference)])))
        // Games keep the full-screen Retina surface.
        #expect(RetinaDefault.afterDetection(resolved: true, choice: nil, override: nil,
                                             detection: detection([(.d3d12, .importTable)])))
        #expect(RetinaDefault.afterDetection(resolved: true, choice: nil, override: nil,
                                             detection: detection([(.d3d9, .delayImport)])))
    }

    @Test func explicitChoicesAndScreenStateAreNotReinterpreted() {
        let none = detection([])
        #expect(RetinaDefault.afterDetection(resolved: true, choice: true, override: nil, detection: none))
        #expect(RetinaDefault.afterDetection(resolved: true, choice: nil, override: "1", detection: none))
        #expect(!RetinaDefault.afterDetection(resolved: false, choice: nil, override: nil,
                                              detection: detection([(.d3d12, .importTable)])))
        #expect(!RetinaDefault.afterDetection(resolved: false, choice: false, override: nil,
                                              detection: detection([(.d3d12, .importTable)])))
    }
}
