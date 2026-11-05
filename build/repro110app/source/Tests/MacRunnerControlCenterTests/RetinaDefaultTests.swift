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
}
