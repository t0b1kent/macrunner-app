import Foundation
import Testing
@testable import MacRunnerControlCenter

struct PathSafetyTests {
    @Test func subpathCheck() {
        let parent = "/fixture-home/user/Library/Application Support/MacRunner/bottles"
        let child = "/fixture-home/user/Library/Application Support/MacRunner/bottles/mybottle"
        let outside = "/fixture-home/user/Desktop"
        #expect(PathSafety.isSubpath(of: parent, path: child) == true)
        #expect(PathSafety.isSubpath(of: parent, path: outside) == false)
    }

    @Test func sanitizeBottle() {
        let base = "/fixture-home/user/Library/Application Support/MacRunner/bottles"
        let valid = "/fixture-home/user/Library/Application Support/MacRunner/bottles/a"
        let invalid = "/fixture-home/user/Desktop/a"
        #expect(PathSafety.sanitizeBottlePath(valid, base: base) == true)
        #expect(PathSafety.sanitizeBottlePath(invalid, base: base) == false)
    }

    @Test func identicalPathIsSubpath() {
        let path = "/fixture-home/user/Library/Application Support/MacRunner/bottles"
        #expect(PathSafety.isSubpath(of: path, path: path) == true)
    }
}
